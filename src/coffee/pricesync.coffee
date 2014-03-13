_ = require('underscore')._
InventoryUpdater = require('sphere-node-sync').InventoryUpdater
CommonUpdater = require('sphere-node-sync').CommonUpdater
SphereClient = require 'sphere-node-client'
Q = require 'q'

class PriceSync extends CommonUpdater

  CUSTOMER_GROUP_SALE = 'specialPrice'

  constructor: (options = {}) ->
    super options
    throw new Error 'No base configuration in options!' unless options.baseConfig
    throw new Error 'No master configuration in options!' unless options.master
    throw new Error 'No retailer configuration in options!' unless options.retailer

    masterOpts = _.clone options.baseConfig
    masterOpts.config = options.master
    retailerOpts = _.clone options.baseConfig
    retailerOpts.config = options.retailer

    @masterClient = new SphereClient masterOpts
    @retailerClient = new SphereClient retailerOpts

    @logger = options.baseConfig.logConfig.logger
    @retailerProjectKey = options.retailer.project_key

    @inventoryUpdater = new InventoryUpdater masterOpts

  run: (callback) ->
    channelRoles = ['InventorySupply', 'OrderExport', 'OrderImport']
    Q.all([
      @inventoryUpdater.ensureChannelByKey(@masterClient._rest, @retailerProjectKey, channelRoles)
      @getCustomerGroup(@masterClient, CUSTOMER_GROUP_SALE)
      @getCustomerGroup(@retailerClient, CUSTOMER_GROUP_SALE)
      @getPublishedProducts(@retailerClient)
    ]).spread (retailerChannelInMaster, masterCustomerGroup, retailerCustomerGroup, retailerProducts) =>
      @logger.debug "Retailer products: #{_.size retailerProducts.results}" if @logger

      if _.size(retailerProducts.results) is 0
        @returnResult true, "Nothing to do.", callback
      else
        updates = []
        for retailerProduct in retailerProducts.results
          retailerProduct.variant or= []
          variants = [retailerProduct.masterVariant].concat retailerProduct.variants
          for retailerVariant in variants
            updates.push @syncVariantPrices(retailerVariant, retailerCustomerGroup, masterCustomerGroup, retailerChannelInMaster)

        Q.all(updates).then (msg) =>
          @returnResult true, msg, callback
        .fail (msg) =>
          @returnResult false, msg, callback
    .fail (msg) =>
      @returnResult false, msg, callback

  syncVariantPrices: (retailerVariant, retailerCustomerGroup, masterCustomerGroup, retailerChannelInMaster) ->
    deferred = Q.defer()
    @getPublishedVariantByMasterSku(@masterClient, retailerVariant)
    .then (variantData) =>
      variantInMaster =  variantData.variant

      prices = @_filterPrices(retailerVariant, variantInMaster, retailerCustomerGroup, masterCustomerGroup, retailerChannelInMaster)
      actions = @_updatePrices(prices.retailerPrices, prices.masterPrices, retailerChannelInMaster.id, variantInMaster)
      
      data =
        version: variantData.productVersion
        variantId: variantInMaster.id
        actions: actions

      @masterClient.products.byId(variantData.productId).save(data).then ->
        deferred.resolve "Prices updated."
      .fail (error) ->
        if error.statusCode is 409
          # TODO: retrigger it
          deferred.resolve "Price update postponed." # will be done at next interation
        else
          deferred.reject error # This one is really bad as the price couldn't update

    .fail (msg) ->
      # We will resolve here as the problems on getting the data from master should not influence the other updates
      deferred.resolve msg

    deferred.promise

  getPublishedProducts: (client) ->
    # TODO: get only modified products
    # date = new Date()
    # date.setDate(date.getDate - 1)
    # client.productProjections.where("modifiedAt > \"#{date.toISOString()}\"").fetch()
    client.productProjections.fetch()

  getCustomerGroup: (client, name) ->
    client.customerGroups.where("name=\"#{name}\"").fetch()

  getPublishedVariantByMasterSku: (client, variant) ->
    deferred = Q.defer()
    variant.attributes or= []
    attribute = _.find variant.attributes, (attribute) ->
      attribute.name is 'mastersku'
    unless attribute
      deferred.reject "No mastersku attribute!"
    else
      masterSku = attribute.value
      unless masterSku
        deferred.reject 'No mastersku set!'
      else
        query = encodeURIComponent "masterVariant(sku = \"#{masterSku}\") or variants(sku = \"#{masterSku.toLowerCase()}\")"
        client._rest.GET "/product-projections?where=#{query}", (error, response, body) ->
          if body.total isnt 1
            deferred.reject "There is no product in master for sku '#{masterSku}'."
          else
            product = body.results[0]
            variants = [product.masterVariant].concat(product.variants)
            match = _.find variants, (v) ->
              v.sku is masterSku
            if match
              data =
                productId: product.id
                productVersion: product.version
                variant: match
              deferred.resolve data
            else
              deferred.reject "Can't find matching variant"

    deferred.promise

  _filterPrices: (retailerVariant, variantInMaster, retailerCustomerGroup, masterCustomerGroup, retailerChannel) ->
    retailerPrices = _.select retailerVariant.prices, (price) ->
      not _.has(price, 'customerGroup') or price.customerGroup.id is retailerCustomerGroup.id

    masterPricesWithRetailerChannel = _.select variantInMaster.prices, (price) ->
      _.has(price, 'channel') and price.channel.id is retailerChannel.id
    
    masterPrices = _.select masterPricesWithRetailerChannel, (price) ->
      not _.has(price, 'customerGroup') or price.customerGroup.id is masterCustomerGroup.id

    data =
      retailerPrices: retailerPrices
      masterPrices: masterPrices


  _updatePrices: (retailerPrices, masterPrices, channelId, variantInMaster) ->
    actions = []
    syncAmountOrCreate = (retailerPrice, masterPrice, priceType = 'normal') ->
      if masterPrice and retailerPrice
        if masterPrice.value.currencyCode isnt retailerPrice.value.currencyCode
          console.error "SKU #{variantInMaster.sku}: There are #{priceType} prices with different currencyCodes. R: #{retailerPrice.value.currencyCode} -> M: #{masterPrice.value.currencyCode}"
        else
          if masterPrice.value.centAmount isnt retailerPrice.value.centAmount
            # Update the price's amount
            masterPrice.value.centAmount = retailerPrice.value.centAmount
            data =
              action: 'changePrice'
              variantId: variantInMaster.id
              price: masterPrice
              staged: false
      else if retailerPrice
        # Add new price
        retailerPrice.channel =
          typeId: 'channel'
          id: channelId
        data =
          action: 'addPrice'
          variantId: variantInMaster.id
          price: retailerPrice
          staged: false
      else if priceType is 'normal'
        console.error "SKU #{variantInMaster.sku}: There are NO #{priceType} prices at all."

    action = syncAmountOrCreate(@_normalPrice(retailerPrices), @_normalPrice(masterPrices))
    actions.push action if action

    # TODO: check customer group
    action = syncAmountOrCreate(@_salesPrice(retailerPrices), @_salesPrice(masterPrices), CUSTOMER_GROUP_SALE)
    actions.push action if action

    actions

  _normalPrice: (prices) ->
    _.find prices, (p) ->
      not _.has p, 'customerGroup'

  _salesPrice: (prices) ->
    _.find prices, (p) ->
      _.has p, 'customerGroup'
      
module.exports = PriceSync
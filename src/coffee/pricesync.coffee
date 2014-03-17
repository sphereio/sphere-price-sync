_ = require('underscore')._
InventoryUpdater = require('sphere-node-sync').InventoryUpdater
CommonUpdater = require('sphere-node-sync').CommonUpdater
SphereClient = require 'sphere-node-client'
Q = require 'q'

class PriceSync extends CommonUpdater

  CHANNEL_ROLES = ['InventorySupply', 'OrderExport', 'OrderImport']
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
    Q.all([
      @inventoryUpdater.ensureChannelByKey(@masterClient._rest, @retailerProjectKey, CHANNEL_ROLES)
      @getCustomerGroup(@masterClient, CUSTOMER_GROUP_SALE)
      @getCustomerGroup(@retailerClient, CUSTOMER_GROUP_SALE)
      @getPublishedProducts(@retailerClient)
    ]).spread (retailerChannelInMaster, masterCustomerGroup, retailerCustomerGroup, retailerProducts) =>
      @logger.debug "Retailer products: #{_.size retailerProducts.results}" if @logger

      if _.size(retailerProducts) is 0
        @returnResult true, "Nothing to do.", callback
      else
        updates = []
        _.each retailerProducts, (retailerProduct) =>
          current = retailerProduct.masterData.current
          current.variant or= []
          variants = [current.masterVariant].concat current.variants
          _.each variants, (retailerVariant) =>
            updates.push @syncVariantPrices(retailerVariant, retailerCustomerGroup, masterCustomerGroup, retailerChannelInMaster)

        @processInBatches updates, callback
    .fail (msg) =>
      @returnResult false, msg, callback
    .done()

  processInBatches: (posts, callback, numberOfParallelRequest = 20, acc = []) =>
    current = _.take posts, numberOfParallelRequest
    Q.all(current).then (msg) =>
      messages = acc.concat(msg)
      if _.size(current) < numberOfParallelRequest
        @returnResult true, messages, callback
      else
        @processInBatches _.tail(posts, numberOfParallelRequest), callback, numberOfParallelRequest, messages
    .fail (msg) =>
      @returnResult false, msg, callback

  syncVariantPrices: (retailerVariant, retailerCustomerGroup, masterCustomerGroup, retailerChannelInMaster) ->
    deferred = Q.defer()
    @getPublishedVariantByMasterSku(@masterClient, retailerVariant)
    .then (variantData) =>
      variantInMaster =  variantData.variant

      prices = @_filterPrices(retailerVariant, variantInMaster, retailerCustomerGroup, masterCustomerGroup, retailerChannelInMaster)
      actions = @_updatePrices(prices.retailerPrices, prices.masterPrices, retailerChannelInMaster.id, variantInMaster, retailerCustomerGroup.id, masterCustomerGroup.id)
      
      data =
        version: variantData.productVersion
        variantId: variantInMaster.id
        actions: actions

      @masterClient.products.byId(variantData.productId).save(data)
      .then ->
        deferred.resolve "Prices updated."
      .fail (error) ->
        if error.statusCode is 409
          # TODO: retrigger it
          deferred.resolve "Price update postponed." # will be done at next interation
        else
          deferred.reject error # This one is really bad as the price couldn't update
      .done()

    .fail (msg) ->
      # We will resolve here as the problems on getting the data from master should not influence the other updates
      deferred.resolve msg
    .done()

    deferred.promise

  getPublishedProducts: (client, offsetInDays = 2) ->
    deferred = Q.defer()

    date = new Date()
    date.setDate(date.getDate() - offsetInDays)
    offSet = "#{date.toISOString().substring(0,10)}T00:00:00.000Z"

    pageProducts = (page = 0, perPage = 50, total, acc = []) ->
      if total? and page * perPage > total
        deferred.resolve acc
      else
        client.products.page(page).perPage(perPage).fetch()
        .then (payload) ->
          pageProducts page + 1, perPage, payload.total, acc.concat(payload.results)
        .fail (error) ->
          deferred.reject error
        .done()

    pageProducts()
    deferred.promise

  getCustomerGroup: (client, name) ->
    deferred = Q.defer()
    client.customerGroups.where("name=\"#{name}\"").fetch()
    .then (result) ->
      if _.size(result.results) is 1
        deferred.resolve result.results[0]
      else
        deferred.reject "Can not find cutomer group '#{name}'."
    .fail (error) ->
      deferred.reject error
    .done()

    deferred.promise

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
        query = encodeURIComponent "masterVariant(sku = \"#{masterSku}\") or variants(sku = \"#{masterSku}\")"
        client._rest.GET "/product-projections?where=#{query}", (error, response, body) ->
          if body.total isnt 1
            deferred.reject "There is no published product in master for sku '#{masterSku}'."
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


  _updatePrices: (retailerPrices, masterPrices, channelId, variantInMaster, retailerCustomerGroupId, masterCustomerGroupId) ->
    actions = []
    syncAmountOrCreate = (retailerPrice, masterPrice, priceType = 'normal') ->
      if masterPrice and retailerPrice
        if masterPrice.value.currencyCode isnt retailerPrice.value.currencyCode
          console.error "SKU #{variantInMaster.sku}: There are #{priceType} prices with different currencyCodes. R: #{retailerPrice.value.currencyCode} -> M: #{masterPrice.value.currencyCode}"
        else
          if masterPrice.value.centAmount isnt retailerPrice.value.centAmount
            # Update the price's amount
            price = _.clone masterPrice
            price.value.centAmount = retailerPrice.value.centAmount
            data =
              action: 'changePrice'
              variantId: variantInMaster.id
              price: price
      else if retailerPrice
        # Add new price
        price = _.clone retailerPrice
        # add channel for retailer in master
        price.channel =
          typeId: 'channel'
          id: channelId
        # If the price has a customerGroup set, we have to update the id with the one from master
        if _.has price, 'customerGroup'
          price.customerGroup.id = masterCustomerGroupId

        data =
          action: 'addPrice'
          variantId: variantInMaster.id
          price: price
      else if priceType is CUSTOMER_GROUP_SALE and masterPrice
        data =
          action: 'removePrice'
          variantId: variantInMaster.id
          price: masterPrice
      else if priceType isnt CUSTOMER_GROUP_SALE
        console.error "SKU #{variantInMaster.sku}: There are NO #{priceType} prices at all."

    action = syncAmountOrCreate(@_normalPrice(retailerPrices), @_normalPrice(masterPrices))
    if action
      #actions.push action
      liveAction = _.clone action
      liveAction.staged = false
      actions.push liveAction

    action = syncAmountOrCreate(@_salesPrice(retailerPrices, retailerCustomerGroupId), @_salesPrice(masterPrices, masterCustomerGroupId), CUSTOMER_GROUP_SALE)
    if action
      #actions.push action
      liveAction = _.clone action
      liveAction.staged = false
      actions.push liveAction

    actions

  _normalPrice: (prices) ->
    _.find prices, (p) ->
      not _.has p, 'customerGroup'

  _salesPrice: (prices, customerGroupId) ->
    _.find prices, (p) ->
      _.has(p, 'customerGroup') and p.customerGroup.id is customerGroupId
      
module.exports = PriceSync

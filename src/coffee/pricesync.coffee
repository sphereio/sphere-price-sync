_ = require('underscore')._
InventoryUpdater = require('sphere-node-sync').InventoryUpdater
CommonUpdater = require('sphere-node-sync').CommonUpdater
SphereClient = require 'sphere-node-client'
TaskQueue = require './taskqueue'
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

    @taskQueue = new TaskQueue()

  run: ->
    Q.all([
      @inventoryUpdater.ensureChannelByKey(@masterClient._rest, @retailerProjectKey, CHANNEL_ROLES)
      @getCustomerGroup(@masterClient, CUSTOMER_GROUP_SALE)
      @getCustomerGroup(@retailerClient, CUSTOMER_GROUP_SALE)
    ]).spread (retailerChannelInMaster, masterCustomerGroup, retailerCustomerGroup) =>
      console.error "retailerChannelInMaster %j", retailerChannelInMaster
      console.error "masterCustomerGroup %j", masterCustomerGroup
      console.error "retailerCustomerGroup %j", retailerCustomerGroup

      @getPublishedProducts @retailerClient, ((page, count) -> console.error "Page #{page} processed - #{count} price update(s) done."), (retailerProduct) =>
        current = retailerProduct.masterData.current
        current.variants or= []
        variants = [current.masterVariant].concat(current.variants)
        stagedVariants = [retailerProduct.masterData.staged.masterVariant].concat(retailerProduct.masterData.staged.variants)

        console.error "C %j", _.map(variants, (a) -> a.sku)
        console.error "S %j", _.map(stagedVariants, (a) -> a.sku)

        v = _.map variants, (retailerVariant) =>
          @taskQueue.addTask _.bind(@_processVariant, this, retailerVariant, retailerCustomerGroup, masterCustomerGroup, retailerChannelInMaster)
        Q.all(v)
        .then (infos) ->
          _.reduce infos, ((acc, info) -> acc + info.updates), 0

  _processVariant: (retailerVariant, retailerCustomerGroup, masterCustomerGroup, retailerChannelInMaster) ->
    @getPublishedVariantByMasterSku(@masterClient, retailerVariant)
    .then (variantDataInMaster) =>
      @syncVariantPrices(variantDataInMaster, retailerVariant, retailerCustomerGroup, masterCustomerGroup, retailerChannelInMaster)
    .fail (msg) =>
      console.warn msg
      Q({ updates: 0 })

  syncVariantPrices: (variantDataInMaster, retailerVariant, retailerCustomerGroup, masterCustomerGroup, retailerChannelInMaster) ->
    prices = @_filterPrices(retailerVariant, variantDataInMaster.variant, retailerCustomerGroup, masterCustomerGroup, retailerChannelInMaster)
    actions = @_updatePrices(prices.retailerPrices, prices.masterPrices, retailerChannelInMaster.id, variantDataInMaster.variant, retailerCustomerGroup.id, masterCustomerGroup.id)
      
    if _.isEmpty(actions)
      Q({ updates: 0 })

    else
      data =
        version: variantDataInMaster.productVersion
        variantId: variantDataInMaster.productId
        actions: actions

      @masterClient.products.byId(variantDataInMaster.productId).save(data)
      .then ->
        Q({ updates: _.size(actions) })

  getPublishedProducts: (client, pageProcessedCb, processFn) ->
    deferred = Q.defer()

    pageProducts = (page = 1, perPage = 50, total, acc = 0) ->
      if total? and page * perPage > total
        deferred.resolve acc
      else
        client.products.page(page).perPage(perPage).sort("id").fetch()
        .then (payload) ->
          processes = _.map payload.results, (elem) ->
            processFn(elem)
          Q.all(processes)
          .then (counts) ->
            [_.reduce(counts, ((acc, count) -> acc + count), 0), payload]
        .then ([count, payload]) ->
          pageProcessedCb(page, count)
          pageProducts page + 1, perPage, payload.total, count + acc
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
        deferred.reject new Error("Can not find cutomer group '#{name}'.")
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
      deferred.reject new Error("No mastersku attribute!")
    else
      masterSku = attribute.value
      unless masterSku
        deferred.reject new Error('No mastersku set!')
      else
        query = encodeURIComponent "masterVariant(sku = \"#{masterSku}\") or variants(sku = \"#{masterSku}\")"
        client._rest.GET "/product-projections?where=#{query}", (error, response, body) ->
          if body.total isnt 1
            deferred.reject new Error("There is no published product in master for sku '#{masterSku}'.")
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
              deferred.reject new Error("Can't find matching variant")

    deferred.promise

  _filterPrices: (retailerVariant, variantInMaster, retailerCustomerGroup, masterCustomerGroup, retailerChannel) ->
    console.error "f retailerVariant %j", retailerVariant
    console.error "f variantInMaster %j", variantInMaster
    console.error "f retailerCustomerGroup %j", retailerCustomerGroup
    console.error "f masterCustomerGroup %j", masterCustomerGroup
    console.error "f retailerChannel %j", retailerChannel

    retailerPrices = _.select retailerVariant.prices, (price) ->
      not _.has(price, 'customerGroup') or price.customerGroup.id is retailerCustomerGroup.id

    masterPricesWithRetailerChannel = _.select variantInMaster.prices, (price) ->
      _.has(price, 'channel') and price.channel.id is retailerChannel.id
    
    masterPrices = _.select masterPricesWithRetailerChannel, (price) ->
      not _.has(price, 'customerGroup') or price.customerGroup.id is masterCustomerGroup.id

    data =
      retailerPrices: retailerPrices
      masterPrices: masterPrices

    console.error "f data %j", data
    data


  _updatePrices: (retailerPrices, masterPrices, channelId, variantInMaster, retailerCustomerGroupId, masterCustomerGroupId) ->
    actions = []
    syncAmountOrCreate = (retailerPrice, masterPrice, priceType = 'normal') ->
      console.error "Comparing %j", priceType, retailerPrice, masterPrice
      if masterPrice? and retailerPrice?
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
      else if retailerPrice?
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

    console.error "ACTIONS %j", actions
    actions

  _normalPrice: (prices) ->
    _.find prices, (p) ->
      not _.has(p, 'customerGroup')

  _salesPrice: (prices, customerGroupId) ->
    _.find prices, (p) ->
      _.has(p, 'customerGroup') and p.customerGroup.id is customerGroupId
      
module.exports = PriceSync

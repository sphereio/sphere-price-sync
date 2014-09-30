_ = require 'underscore'
_.mixin require 'underscore-mixins'
Promise = require 'bluebird'
{SphereClient, TaskQueue} = require 'sphere-node-sdk'

CHANNEL_ROLES = ['InventorySupply', 'OrderExport', 'OrderImport']
CUSTOMER_GROUP_SALE = 'specialPrice'

class PriceSync

  constructor: (@logger, options = {}) ->
    throw new Error 'No base configuration in options!' unless options.baseConfig
    throw new Error 'No master configuration in options!' unless options.master
    throw new Error 'No retailer configuration in options!' unless options.retailer

    globalTaskQueue = new TaskQueue
    @masterClient = new SphereClient _.extend {}, _.deepClone(options.baseConfig),
      config: options.master
      task: globalTaskQueue
    @retailerClient = new SphereClient _.extend {}, _.deepClone(options.baseConfig),
      config: options.retailer
      task: globalTaskQueue

    @retailerProjectKey = options.retailer.project_key
    @fetchHours = options.baseConfig.fetchHours or 24
    @_resetSummary()

  _resetSummary: ->
    @summary =
      toUpdate: 0
      toCreate: 0
      toRemove: 0
      synced: 0
      failed: 0

  run: ->
    @_resetSummary()

    Promise.all([
      @masterClient.channels.ensure(@retailerProjectKey, CHANNEL_ROLES)
      @masterClient.customerGroups.where("name = \"#{CUSTOMER_GROUP_SALE}\"").fetch()
      @retailerClient.customerGroups.where("name = \"#{CUSTOMER_GROUP_SALE}\"").fetch()
    ]).spread (resultMasterChannel, resultMasterCustomerGroup, resultRetailerCustomerGroup) =>
      retailerChannelInMaster = resultMasterChannel.body
      masterCustomerGroup = resultMasterCustomerGroup.body.results[0]
      retailerCustomerGroup = resultRetailerCustomerGroup.body.results[0]
      throw new Error "Cannot find customer group '#{CUSTOMER_GROUP_SALE}' in master" unless masterCustomerGroup
      throw new Error "Cannot find customer group '#{CUSTOMER_GROUP_SALE}' in retailer" unless retailerCustomerGroup

      @retailerClient.products
      .sort('id')
      .last("#{@fetchHours}h")
      .where("masterData(published=\"true\")")
      .perPage(100)
      .process (payload) =>
        retailerProductsBatch = payload.body.results

        Promise.map retailerProductsBatch, (retailerProduct) =>
          @logger?.debug retailerProduct, 'Processing retailer product'
          current = retailerProduct.masterData.current
          current.variants or= []
          variants = [current.masterVariant].concat(current.variants)

          Promise.map variants, (retailerVariant) =>
            @_processVariant retailerVariant, retailerCustomerGroup, masterCustomerGroup, retailerChannelInMaster, retailerProduct.id
          , {concurrency: 1}
          .then -> Promise.resolve() # continue with next batch
        , {concurrency: 1}
        .then -> Promise.resolve() # continue with next batch
      , {accumulate: false}

    .then =>
      if @summary.toUpdate is 0 and @summary.toCreate is 0 and @summary.toRemove is 0
        message = 'Summary: 0 unsynced prices, everything is fine'
      else
        message = "Summary: there were #{@summary.toUpdate + @summary.toCreate + @summary.toRemove} " +
          "unsynced prices, (#{@summary.toUpdate} were updates, #{@summary.toCreate} were new and " +
          "#{@summary.toRemove} were deletions) and #{@summary.synced} products in master " +
          "were successfully synced (#{@summary.failed} failed)"
      Promise.resolve message

  _processVariant: (retailerVariant, retailerCustomerGroup, masterCustomerGroup, retailerChannelInMaster, retailerProductId) ->
    @_getVariantByMasterSku(retailerVariant, retailerProductId)
    .then (variantDataInMaster) =>
      if variantDataInMaster
        @_syncVariantPrices(variantDataInMaster, retailerVariant, retailerCustomerGroup, masterCustomerGroup, retailerChannelInMaster)
      else # not able to match prices with master, skipping...
        Promise.resolve()

  _getVariantByMasterSku: (variant, retailerProductId) ->
    @logger?.debug "Processing variant #{variant.id} (sku: #{variant.sku}) for retailer product #{retailerProductId}"
    variant.attributes or= []
    attribute = _.find variant.attributes, (attribute) -> attribute.name is 'mastersku'
    if attribute
      masterSku = attribute.value
      if masterSku
        @masterClient.productProjections
        .staged(true) # always get the staged version from master
        .where("masterVariant(sku = \"#{masterSku}\") or variants(sku = \"#{masterSku}\")")
        .fetch()
        .then (result) =>
          body = result.body
          if body.total isnt 1
            @logger?.warn "Found #{body.total} matching products in master for sku '#{masterSku}' " +
              "(variant #{variant.id}) while processing retailer product #{retailerProductId}"
            Promise.resolve()
          else
            product = body.results[0]
            variants = [product.masterVariant].concat(product.variants)
            match = _.find variants, (v) ->
              v.sku is masterSku
            if match?
              data =
                productVersion: product.version
                productId: product.id
                isPublished: product.published is true
                variant: match
              @logger?.debug data, 'Matched data'
              Promise.resolve data
            else
              @logger?.warn "Cannot find matching variant in master for sku '#{masterSku}' " +
                "(variant #{variant.id}) while processing retailer product #{retailerProductId}"
              Promise.resolve()
      else
        @logger?.warn "No 'mastersku' set for variant #{variant.id} while processing retailer " +
          "product #{retailerProductId}"
        Promise.resolve()
    else
      @logger?.warn "No 'mastersku' attribute for variant #{variant.id} while processing retailer " +
        "product #{retailerProductId}"
      Promise.resolve()

  _syncVariantPrices: (variantDataInMaster, retailerVariant, retailerCustomerGroup, masterCustomerGroup, retailerChannelInMaster) ->
    prices = @_filterPrices(retailerVariant, variantDataInMaster.variant, retailerCustomerGroup, masterCustomerGroup, retailerChannelInMaster)
    actions = @_updatePrices(prices.retailerPrices, prices.masterPrices, retailerChannelInMaster.id, variantDataInMaster.variant, variantDataInMaster.isPublished, retailerCustomerGroup.id, masterCustomerGroup.id)

    if _.isEmpty(actions)
      @logger?.debug prices, "No available update actions for prices in product #{variantDataInMaster.productId}"
      Promise.resolve()
    else
      data =
        version: variantDataInMaster.productVersion
        variantId: variantDataInMaster.productId
        actions: actions
      @logger?.debug data, "About to update product #{variantDataInMaster.productId} in master"
      @masterClient.products.byId(variantDataInMaster.productId).update(data)
      .then =>
        @summary.synced++
        Promise.resolve()
      .catch (error) =>
        @summary.failed++
        # TODO: log or accumulate error and continue with sync
        Promise.reject error

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

    data


  _updatePrices: (retailerPrices, masterPrices, channelId, variantInMaster, isPublished, retailerCustomerGroupId, masterCustomerGroupId) ->
    actions = []
    syncAmountOrCreate = (retailerPrice, masterPrice, priceType = 'normal') =>
      if masterPrice? and retailerPrice?
        if masterPrice.value.currencyCode isnt retailerPrice.value.currencyCode
          @logger?.error "SKU #{variantInMaster.sku}: There are #{priceType} prices with different currencyCodes. R: #{retailerPrice.value.currencyCode} -> M: #{masterPrice.value.currencyCode}"
        else
          if masterPrice.value.centAmount isnt retailerPrice.value.centAmount
            # Update the price's amount
            price = _.clone masterPrice
            price.value.centAmount = retailerPrice.value.centAmount
            @summary.toUpdate++
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
        # when the price has a customerGroup set, we have to update the id with the one from master
        if _.has price, 'customerGroup'
          price.customerGroup.id = masterCustomerGroupId

        @summary.toCreate++
        data =
          action: 'addPrice'
          variantId: variantInMaster.id
          price: price
      else if priceType is CUSTOMER_GROUP_SALE and masterPrice
        @summary.toRemove++
        data =
          action: 'removePrice'
          variantId: variantInMaster.id
          price: masterPrice
      else if priceType isnt CUSTOMER_GROUP_SALE
        @logger?.warn "SKU #{variantInMaster.sku}: There are NO normal prices at all."

    action = syncAmountOrCreate(@_normalPrice(retailerPrices), @_normalPrice(masterPrices))
    if action?
      liveAction = _.clone action
      liveAction.staged = not isPublished
      actions.push liveAction

    action = syncAmountOrCreate(@_salesPrice(retailerPrices, retailerCustomerGroupId), @_salesPrice(masterPrices, masterCustomerGroupId), CUSTOMER_GROUP_SALE)

    if action?
      liveAction = _.clone action
      liveAction.staged = not isPublished
      actions.push liveAction

    actions

  _normalPrice: (prices) ->
    _.find prices, (p) ->
      not _.has(p, 'customerGroup')

  _salesPrice: (prices, customerGroupId) ->
    _.find prices, (p) ->
      _.has(p, 'customerGroup') and p.customerGroup.id is customerGroupId

module.exports = PriceSync

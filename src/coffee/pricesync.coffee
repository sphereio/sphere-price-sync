_ = require 'underscore'
Q = require 'q'
SphereClient = require 'sphere-node-client'
{Qutils} = require 'sphere-node-utils'

CHANNEL_ROLES = ['InventorySupply', 'OrderExport', 'OrderImport']
CUSTOMER_GROUP_SALE = 'specialPrice'

class DataIssue
  constructor: (@msg) ->

class PriceSync

  constructor: (@logger, options = {}) ->
    throw new Error 'No base configuration in options!' unless options.baseConfig
    throw new Error 'No master configuration in options!' unless options.master
    throw new Error 'No retailer configuration in options!' unless options.retailer

    masterOpts = _.clone options.baseConfig
    masterOpts.config = options.master
    retailerOpts = _.clone options.baseConfig
    retailerOpts.config = options.retailer

    @masterClient = new SphereClient masterOpts
    @retailerClient = new SphereClient retailerOpts

    @retailerProjectKey = options.retailer.project_key

    @fetchHours = options.baseConfig.fetchHours or 24

  run: ->
    Q.all([
      @masterClient.channels.ensure(@retailerProjectKey, CHANNEL_ROLES)
      @getCustomerGroup(@masterClient, CUSTOMER_GROUP_SALE)
      @getCustomerGroup(@retailerClient, CUSTOMER_GROUP_SALE)
    ]).spread (retailerChannelInMaster, masterCustomerGroup, retailerCustomerGroup) =>
      @retailerClient.products
      .sort('id')
      .last("#{@fetchHours}h")
      .where("masterData(published=\"true\")")
      .perPage(1) # one product at a time
      .process (retailerProduct) =>
        @logger.debug retailerProduct, 'Processing retailer product'
        return Q() if retailerProduct.body.total is 0
        @logger.debug "Processing product #{retailerProduct.body.results[0].id}"
        current = retailerProduct.body.results[0].masterData.current
        current.variants or= []
        variants = [current.masterVariant].concat(current.variants)

        Qutils.processList variants, (retailerVariant) =>
          @_processVariant retailerVariant, retailerCustomerGroup, masterCustomerGroup, retailerChannelInMaster.body
    .then (results) =>
      compacted = _.compact(results)
      if _.isEmpty compacted
        summary = "[#{@retailerProjectKey}] There are no products to sync prices for."
      else
        reduced = _.reduce compacted, ((acc, info) -> acc + info.updates), 0
        summary = "[#{@retailerProjectKey}] #{reduced} price updates were synced."
      Q(summary)

  _processVariant: (retailerVariant, retailerCustomerGroup, masterCustomerGroup, retailerChannelInMaster) ->
    @getVariantByMasterSku(retailerVariant)
    .then (variantDataInMaster) =>
      @syncVariantPrices(variantDataInMaster, retailerVariant, retailerCustomerGroup, masterCustomerGroup, retailerChannelInMaster)
    .fail (error) =>
      if error instanceof DataIssue
        @logger.warn error.msg
      else
        @logger.error error
      Q({ updates: 0 })

  syncVariantPrices: (variantDataInMaster, retailerVariant, retailerCustomerGroup, masterCustomerGroup, retailerChannelInMaster) ->
    prices = @_filterPrices(retailerVariant, variantDataInMaster.variant, retailerCustomerGroup, masterCustomerGroup, retailerChannelInMaster)
    actions = @_updatePrices(prices.retailerPrices, prices.masterPrices, retailerChannelInMaster.id, variantDataInMaster.variant, variantDataInMaster.isPublished, retailerCustomerGroup.id, masterCustomerGroup.id)

    if _.isEmpty(actions)
      @logger.debug prices, "No available update actions for prices in product #{variantDataInMaster.productId}"
      Q({ updates: 0 })
    else
      data =
        version: variantDataInMaster.productVersion
        variantId: variantDataInMaster.productId
        actions: actions

      @logger.debug data, "About to update product #{variantDataInMaster.productId} in master"
      @masterClient.products.byId(variantDataInMaster.productId).update(data)
      .then -> Q({ updates: _.size(actions) })

  getCustomerGroup: (client, name) ->
    client.customerGroups.where("name=\"#{name}\"").fetch()
    .then (result) =>
      if _.size(result.body.results) is 1
        Q result.body.results[0]
      else
        Q.reject new Error("[#{@retailerProjectKey}] Can not find cutomer group '#{name}'.")

  getVariantByMasterSku: (variant) ->
    @logger.debug "Processing variant #{variant.id} (sku: #{variant.sku})"
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
            Q.reject new DataIssue("[#{@retailerProjectKey}] There are #{body.total} products in master for sku '#{masterSku}'.")
          else
            product = body.results[0]
            variants = [product.masterVariant].concat(product.variants)
            match = _.find variants, (v) ->
              v.sku is masterSku
            if match?
              data =
                productId: product.id
                productVersion: product.version
                isPublished: product.published is true
                variant: match
              @logger.debug data, 'Matched data'
              Q data
            else
              Q.reject new Error("[#{@retailerProjectKey}] Can't find matching variant")
      else
        Q.reject new DataIssue("[#{@retailerProjectKey}] No mastersku set!")
    else
      Q.reject new DataIssue("[#{@retailerProjectKey}] No mastersku attribute!")

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
          @logger.error "[#{@retailerProjectKey}] SKU #{variantInMaster.sku}: There are #{priceType} prices with different currencyCodes. R: #{retailerPrice.value.currencyCode} -> M: #{masterPrice.value.currencyCode}"
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
        # when the price has a customerGroup set, we have to update the id with the one from master
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
        @logger.warn "[#{@retailerProjectKey}] SKU #{variantInMaster.sku}: There are NO normal prices at all."

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

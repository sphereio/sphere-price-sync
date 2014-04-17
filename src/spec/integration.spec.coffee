_ = require 'underscore'
_.mixin require('sphere-node-utils')._u
Q = require 'q'
Config = require '../config'
Logger = require '../lib/logger'
PriceSync = require '../lib/pricesync'

uniqueId = (prefix) ->
  _.uniqueId "#{prefix}#{new Date().getTime()}_"

updateUnpublish = (version) ->
  version: version
  actions: [
    {action: 'unpublish'}
  ]

cleanup = (client, logger) ->
  logger.debug 'Unpublishing all products'
  client.products.sort('id').where('masterData(published = "true")').process (payload) ->
    Q.all _.map payload.body.results, (product) ->
      client.products.byId(product.id).update(updateUnpublish(product.version))
  .then (results) ->
    logger.info "Unpublished #{results.length} products"
    logger.debug 'About to delete all products'
    client.products.perPage(0).fetch()
  .then (payload) ->
    logger.debug "Deleting #{payload.body.total} products"
    Q.all _.map payload.body.results, (product) ->
      client.products.byId(product.id).delete(product.version)
  .then (results) ->
    logger.info "Deleted #{results.length} products"
    logger.debug 'About to delete all product types'
    client.productTypes.perPage(0).fetch()
  .then (payload) ->
    logger.debug "Deleting #{payload.body.total} product types"
    Q.all _.map payload.body.results, (productType) ->
      client.productTypes.byId(productType.id).delete(productType.version)
  .then (results) ->
    logger.debug "Deleted #{results.length} product types"
    Q()

describe '#run', ->
  beforeEach (done) ->

    @logger = new Logger
      streams: [
        { level: 'info', stream: process.stdout }
      ]

    options =
      baseConfig:
        logConfig:
          logger: @logger
      master:
        project_key: Config.config.project_key
        client_id: Config.config.client_id
        client_secret: Config.config.client_secret
      retailer:
        project_key: Config.config.project_key
        client_id: Config.config.client_id
        client_secret: Config.config.client_secret

    @priceSync = new PriceSync options
    @client = @priceSync.masterClient

    cleanup(@client, @logger)
    .then =>
      @client.customerGroups.where('name = \"specialPrice\"').fetch()
      .then (result) =>
        if _.size(result.body.results) is 1
          Q body: result.body.results[0]
        else
          @logger.info "No customerGroup 'specialPrice' found. Creating a new one"
          @client.customerGroups.save(groupName: 'specialPrice')
    .then (customerGroup) =>
      @logger.debug 'Fetched customGroup "specialPrice"'
      @customerGroupId = customerGroup.body.id
      @client.channels.where("key = \"#{Config.config.project_key}\"").fetch()
    .then (channels) =>
      @logger.debug "Fetched #{channels.body.total} channels"
      @channelId = _.first(channels.body.results).id
      productType =
        name: uniqueId 'PT'
        description: 'bla'
        attributes: [{
          name: 'mastersku'
          label:
            de: 'Master SKU'
          type:
            name: 'text'
          isRequired: false
          inputHint: 'SingleLine'
        }]
      @client.productTypes.save(productType)
    .then (result) =>
      @logger.debug 'ProductType created'
      @productType = result.body
      @product =
        productType:
          typeId: 'product-type'
          id: @productType.id
        name:
          en: uniqueId 'P'
        slug:
          en: uniqueId 'p'
        masterVariant:
          sku: uniqueId 'mastersku1-'
        variants: [
          { sku: uniqueId('mastersku2-'), attributes: [ { name: 'mastersku', value: 'We add some content here in order to create the variant' } ] }
          {
            sku: uniqueId('mastersku3-')
            prices: [
              { value: { currencyCode: 'EUR', centAmount: 99 }, channel: { typeId: 'channel', id: @channelId } }
              { value: { currencyCode: 'EUR', centAmount: 66 }, customerGroup: { id: @customerGroupId, typeId: 'customer-group' }, channel: { typeId: 'channel', id: @channelId } }
            ]
            attributes: [ { name: 'mastersku', value: 'We add some content here in order to create another variant' } ]
          }
        ]
      @client.products.save(@product)
    .then (result) =>
      @logger.debug result, 'Product created'
      @masterProductId = result.body.id
      @masterProductVersion = result.body.version
      done()
    .fail (error) -> done _.prettify error
    .done()
  , 20000 # 20sec

  afterEach (done) ->
    cleanup(@client, @logger)
    .then -> done()
    .fail (error) -> done(_.prettify(error))
  , 30000 # 30sec

  it 'do nothing', (done) ->
    @priceSync.run()
    .then (msg) ->
      expect(msg).toBe "[#{Config.config.project_key}] There are no products to sync prices for."
      done()
    .fail (error) -> done _.prettify error
    .done()


  # workflow
  # - create a product for the retailer with the mastersku attribute
  # - run sync twice
  # - check price updates
  _.each [{isPublished: true}, {isPublished: false}], (productState) ->
    it "sync prices in masterVariant / variants (master product published: #{productState.isPublished})", (done) ->
      @logger.info 'Syncing prices...'
      fakeRetailerProduct =
        productType:
          typeId: 'product-type'
          id: @productType.id
        name:
          en: uniqueId 'P'
        slug:
          en: uniqueId 'p-'
        masterVariant:
          sku: uniqueId 'retailer1-'
          attributes: [
            { name: 'mastersku', value: @product.masterVariant.sku }
          ]
          prices: [
            { value: { currencyCode: 'EUR', centAmount: 9999 } }
            { value: { currencyCode: 'EUR', centAmount: 8999 }, customerGroup: { id: @customerGroupId, typeId: 'customer-group' } }
          ]
        variants: [
          {
            sku: uniqueId 'retailer2-'
            prices: [
              { value: { currencyCode: 'EUR', centAmount: 20000 } }
              { value: { currencyCode: 'EUR', centAmount: 15000 }, customerGroup: { id: @customerGroupId, typeId: 'customer-group' } }
            ]
            attributes: [ { name: 'mastersku', value: @product.variants[0].sku } ]
          },
          {
            sku: uniqueId 'retailer3-'
            prices: [
              { value: { currencyCode: 'EUR', centAmount: 99 } }
            ]
            attributes: [ { name: 'mastersku', value: @product.variants[1].sku } ]
          }
        ]
      @logger.debug fakeRetailerProduct, 'About to create a product'
      @client.products.save(fakeRetailerProduct)
      .then (result) =>
        @logger.debug 'New retailer product created'
        data =
          actions: [
            { action: 'publish' }
          ]
          version: result.body.version

        @client.products.byId(result.body.id).update(data)
      .then (result) =>
        @logger.debug 'Retailer product published'
        data =
          actions: [
            { action: 'setAttribute', staged: (not productState.isPublished), variantId: 1, name: 'mastersku', value: "We want to be sure it works also for 'hasStagedChanges'." }
          ]
          version: @masterProductVersion
        if productState.isPublished
          @logger.info 'Publishing product'
          data.actions.push action: 'publish'
        @logger.debug data, 'Updating master product'
        @client.products.byId(@masterProductId).update(data)
      .then (result) =>
        @logger.debug 'Master product updated (mastersku)'
        @priceSync.run()
      .then (msg) =>
        expect(msg).toBe "[#{Config.config.project_key}] 5 price updates were synced."
        @client.products.byId(@masterProductId).fetch()
      .then (result) =>
        @logger.debug result, 'Master product fetched'
        product = result.body

        if productState.isPublished
          # current masterVariant
          expect(product.masterData.current.masterVariant.sku).toBe @product.masterVariant.sku
          expect(_.size product.masterData.current.masterVariant.prices).toBe 2
          expect(_.size product.masterData.current.variants[0].prices).toBe 2
          expect(_.size product.masterData.current.variants[1].prices).toBe 1
        else
          expect(product.masterData.current.masterVariant.sku).toBe @product.masterVariant.sku
          expect(_.size product.masterData.current.masterVariant.prices).toBe 0
          expect(_.size product.masterData.current.variants[0].prices).toBe 0
          expect(_.size product.masterData.current.variants[1].prices).toBe 2
        # staged masterVariant
        expect(product.masterData.staged.masterVariant.sku).toBe @product.masterVariant.sku
        expect(_.size product.masterData.staged.masterVariant.prices).toBe 2
        expect(_.size product.masterData.staged.variants[0].prices).toBe 2
        expect(_.size product.masterData.staged.variants[1].prices).toBe 1

        # current masterVariant (price 0)
        price = product.masterData.current.masterVariant.prices[0]
        if productState.isPublished
          expect(price.value.currencyCode).toBe 'EUR'
          expect(price.value.centAmount).toBe 9999
          expect(price.channel.typeId).toBe 'channel'
          expect(price.channel.id).toBeDefined()
          expect(price.customerGroup).toBeUndefined()
        else
          expect(price).not.toBeDefined()
        # staged masterVariant (price 0)
        price = product.masterData.staged.masterVariant.prices[0]
        expect(price.value.currencyCode).toBe 'EUR'
        expect(price.value.centAmount).toBe 9999
        expect(price.channel.typeId).toBe 'channel'
        expect(price.channel.id).toBeDefined()
        expect(price.customerGroup).toBeUndefined()

        # current masterVariant (price 1)
        price = product.masterData.current.masterVariant.prices[1]
        if productState.isPublished
          expect(price.value.currencyCode).toBe 'EUR'
          expect(price.value.centAmount).toBe 8999
          expect(price.channel.typeId).toBe 'channel'
          expect(price.channel.id).toBeDefined()
          expect(price.customerGroup.typeId).toBe 'customer-group'
          expect(price.customerGroup.id).toBeDefined()
        else
          expect(price).not.toBeDefined()
        # staged masterVariant (price 1)
        price = product.masterData.staged.masterVariant.prices[1]
        expect(price.value.currencyCode).toBe 'EUR'
        expect(price.value.centAmount).toBe 8999
        expect(price.channel.typeId).toBe 'channel'
        expect(price.channel.id).toBeDefined()
        expect(price.customerGroup.typeId).toBe 'customer-group'
        expect(price.customerGroup.id).toBeDefined()

        # current variant 0 (price 0)
        price = product.masterData.current.variants[0].prices[0]
        if productState.isPublished
          expect(price.value.currencyCode).toBe 'EUR'
          expect(price.value.centAmount).toBe 20000
          expect(price.channel.typeId).toBe 'channel'
          expect(price.channel.id).toBeDefined()
          expect(price.customerGroup).toBeUndefined()
        else
          expect(price).not.toBeDefined()
        # staged variant 0 (price 0)
        price = product.masterData.staged.variants[0].prices[0]
        expect(price.value.currencyCode).toBe 'EUR'
        expect(price.value.centAmount).toBe 20000
        expect(price.channel.typeId).toBe 'channel'
        expect(price.channel.id).toBeDefined()
        expect(price.customerGroup).toBeUndefined()

        # current variant 0 (price 1)
        price = product.masterData.current.variants[0].prices[1]
        if productState.isPublished
          expect(price.value.currencyCode).toBe 'EUR'
          expect(price.value.centAmount).toBe 15000
          expect(price.channel.typeId).toBe 'channel'
          expect(price.channel.id).toBeDefined()
          expect(price.customerGroup.typeId).toBe 'customer-group'
          expect(price.customerGroup.id).toBeDefined()
        else
          expect(price).not.toBeDefined()
        # staged variant 0 (price 1)
        price = product.masterData.staged.variants[0].prices[1]
        expect(price.value.currencyCode).toBe 'EUR'
        expect(price.value.centAmount).toBe 15000
        expect(price.channel.typeId).toBe 'channel'
        expect(price.channel.id).toBeDefined()
        expect(price.customerGroup.typeId).toBe 'customer-group'
        expect(price.customerGroup.id).toBeDefined()

        # current variant 1 (price 0)
        price = product.masterData.current.variants[1].prices[0]
        expect(price.value.currencyCode).toBe 'EUR'
        expect(price.value.centAmount).toBe 99
        expect(price.channel.typeId).toBe 'channel'
        expect(price.channel.id).toBeDefined()
        expect(price.customerGroup).toBeUndefined()
        # staged variant 1 (price 0)
        price = product.masterData.staged.variants[1].prices[0]
        expect(price.value.currencyCode).toBe 'EUR'
        expect(price.value.centAmount).toBe 99
        expect(price.channel.typeId).toBe 'channel'
        expect(price.channel.id).toBeDefined()
        expect(price.customerGroup).toBeUndefined()

        # current variant 1 (price 1)
        price = product.masterData.current.variants[1].prices[1]
        if productState.isPublished
          expect(price).not.toBeDefined()
        else
          expect(price).toBeDefined()

        done()

      .fail (error) -> done _.prettify error
      .done()
    , 30000 # 30sec

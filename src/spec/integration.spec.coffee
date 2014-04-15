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

# Increase timeout
jasmine.getEnv().defaultTimeoutInterval = 20000

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

    @logger.info 'Unpublishing all products'
    @client.products.sort('id').where('masterData(published = "true")').process (payload) =>
      Q.all _.map payload.body.results, (product) =>
        @client.products.byId(product.id).update(updateUnpublish(product.version))
    .then (results) =>
      @logger.info "Unpublished #{results.length} products"
      @logger.info 'About to delete all products'
      @client.products.perPage(0).fetch()
    .then (payload) =>
      @logger.info "Deleting #{payload.body.total} products"
      Q.all _.map payload.body.results, (product) =>
        @client.products.byId(product.id).delete(product.version)
    .then =>
      @logger.info 'All products deleted'
      @client.customerGroups.where('name = \"specialPrice\"').fetch()
      .then (result) =>
        if _.size(result.body.results) is 1
          Q body: result.body.results[0]
        else
          @logger.info "No customerGroup 'specialPrice' found. Creating a new one"
          @client.customerGroups.save(groupName: 'specialPrice')
    .then (customerGroup) =>
      @logger.info 'Fetched customGroup "specialPrice"'
      @customerGroupId = customerGroup.body.id
      @client.channels.where("key = \"#{Config.config.project_key}\"").fetch()
    .then (channels) =>
      @logger.info "Fetched #{channels.body.total} channels"
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
      @logger.info 'ProductType created'
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
      @logger.info 'Product created'
      @masterProductId = result.body.id
      @masterProductVersion = result.body.version
      done()
    .fail (error) -> done _.prettify error
    .done()

  xit 'do nothing', (done) ->
    @priceSync.run()
    .then (msg) ->
      expect(msg).toBe 'Nothing to do.'
      done()

  # workflow
  # - create a product for the retailer with the mastersku attribute
  # - run sync twice
  # - check price updates
  it 'sync prices on masterVariant and in variants', (done) ->
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
      @logger.info 'New product created'
      data =
        actions: [
          { action: 'publish' }
        ]
        version: result.body.version

      @client.products.byId(result.body.id).update(data)
    .then (result) =>
      @logger.info 'Product published'
      data =
        actions: [
          { action: 'setAttribute', variantId: 1, name: 'mastersku', value: "We want to be sure it works also for 'hasStagedChanges'." }
        ]
        version: @masterProductVersion
      @client.products.byId(@masterProductId).update(data)
    .then (result) =>
      @logger.info 'Product updated (mastersku)'
      @priceSync.run()
    .then (msg) =>
      @logger.info msg, "SYNC RESULT"
      @client.products.byId(@masterProductId).fetch()
    .then (result) =>
      @logger.info 'Master product fetched'
      product = result.body
      expect(product.masterData.current.masterVariant.sku).toBe @product.masterVariant.sku
      expect(_.size product.masterData.current.masterVariant.prices).toBe 2
      expect(_.size product.masterData.current.variants[0].prices).toBe 2
      expect(_.size product.masterData.current.variants[1].prices).toBe 1

      price = product.masterData.current.masterVariant.prices[0]
      expect(price.value.currencyCode).toBe 'EUR'
      expect(price.value.centAmount).toBe 9999
      expect(price.channel.typeId).toBe 'channel'
      expect(price.channel.id).toBeDefined()
      expect(price.customerGroup).toBeUndefined()

      price = product.masterData.staged.masterVariant.prices[0]
      expect(price.value.currencyCode).toBe 'EUR'
      expect(price.value.centAmount).toBe 9999
      expect(price.channel.typeId).toBe 'channel'
      expect(price.channel.id).toBeDefined()
      expect(price.customerGroup).toBeUndefined()

      price = product.masterData.current.masterVariant.prices[1]
      expect(price.value.currencyCode).toBe 'EUR'
      expect(price.value.centAmount).toBe 8999
      expect(price.channel.typeId).toBe 'channel'
      expect(price.channel.id).toBeDefined()
      expect(price.customerGroup.typeId).toBe 'customer-group'
      expect(price.customerGroup.id).toBeDefined()

      price = product.masterData.staged.masterVariant.prices[1]
      expect(price.value.currencyCode).toBe 'EUR'
      expect(price.value.centAmount).toBe 8999
      expect(price.channel.typeId).toBe 'channel'
      expect(price.channel.id).toBeDefined()
      expect(price.customerGroup.typeId).toBe 'customer-group'
      expect(price.customerGroup.id).toBeDefined()

      price = product.masterData.current.variants[0].prices[0]
      expect(price.value.currencyCode).toBe 'EUR'
      expect(price.value.centAmount).toBe 20000
      expect(price.channel.typeId).toBe 'channel'
      expect(price.channel.id).toBeDefined()
      expect(price.customerGroup).toBeUndefined()

      price = product.masterData.staged.variants[0].prices[0]
      expect(price.value.currencyCode).toBe 'EUR'
      expect(price.value.centAmount).toBe 20000
      expect(price.channel.typeId).toBe 'channel'
      expect(price.channel.id).toBeDefined()
      expect(price.customerGroup).toBeUndefined()

      price = product.masterData.current.variants[0].prices[1]
      expect(price.value.currencyCode).toBe 'EUR'
      expect(price.value.centAmount).toBe 15000
      expect(price.channel.typeId).toBe 'channel'
      expect(price.channel.id).toBeDefined()
      expect(price.customerGroup.typeId).toBe 'customer-group'
      expect(price.customerGroup.id).toBeDefined()

      price = product.masterData.staged.variants[0].prices[1]
      expect(price.value.currencyCode).toBe 'EUR'
      expect(price.value.centAmount).toBe 15000
      expect(price.channel.typeId).toBe 'channel'
      expect(price.channel.id).toBeDefined()
      expect(price.customerGroup.typeId).toBe 'customer-group'
      expect(price.customerGroup.id).toBeDefined()

      price = product.masterData.current.variants[1].prices[0]
      expect(price.value.currencyCode).toBe 'EUR'
      expect(price.value.centAmount).toBe 99
      expect(price.channel.typeId).toBe 'channel'
      expect(price.channel.id).toBeDefined()
      expect(price.customerGroup).toBeUndefined()

      price = product.masterData.staged.variants[1].prices[0]
      expect(price.value.currencyCode).toBe 'EUR'
      expect(price.value.centAmount).toBe 99
      expect(price.channel.typeId).toBe 'channel'
      expect(price.channel.id).toBeDefined()
      expect(price.customerGroup).toBeUndefined()

      done()

    .fail (error) -> done _.prettify error
    .done()

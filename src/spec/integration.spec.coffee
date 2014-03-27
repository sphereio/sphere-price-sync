_ = require('underscore')._
Config = require '../config'
PriceSync = require '../lib/pricesync'
Logger = require '../lib/logger'
Q = require 'q'

# Increase timeout
jasmine.getEnv().defaultTimeoutInterval = 20000

describe '#run', ->
  beforeEach (done) ->

    logger = new Logger
      streams: [
        { level: 'warn', stream: process.stderr }
      ]

    options =
      baseConfig:
        logConfig:
          logger: logger
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
    @rest = @priceSync.masterClient._rest

    @unique = new Date().getTime()

    delProducts = (id, version) =>
      data =
        actions: [
          { action: 'unpublish' }
        ]
        version: version
      @client.products.byId(id).save(data).then (result) =>
        @client.products.byId(id).delete(result.version)
      .fail (err) =>
        if err.statusCode is 400
          # delete also already unpublished products
          @client.products.byId(id).delete(version)
        else
          console.error err
          done err

    @priceSync.masterClient.products.perPage(0).fetch()
    .then (products) ->
      console.log 0
      deletions = _.map products.results, (product) ->
        delProducts product.id, product.version
      Q.all(deletions)
    .then =>
      console.log 1
      @priceSync.getCustomerGroup(@client, 'specialPrice')
    .then (result) =>
      console.log 2
      @customerGroupId = result.id
      @client.channels.where("key = \"#{Config.config.project_key}\"").fetch()
    .then (result) =>
      console.log 3
      @channelId = result.results[0].id
      productType =
        name: "PT-#{@unique}"
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
      console.log 4
      @productType = result
      @product =
        productType:
          typeId: 'product-type'
          id: @productType.id
        name:
          en: "P-#{@unique}"
        slug:
          en: "p-#{@unique}"
        masterVariant:
          sku: "mastersku#{@unique}"
        variants: [
          { sku: "masterSKU2-#{@unique}", attributes: [ { name: 'mastersku', value: 'We add some content here in order to create the variant' } ] }
          { sku: "MasterSku3/#{@unique}", prices: [
            { value: { currencyCode: 'EUR', centAmount: 99 }, channel: { typeId: 'channel', id: @channelId } }
            { value: { currencyCode: 'EUR', centAmount: 66 }, customerGroup: { id: @customerGroupId, typeId: 'customer-group' }, channel: { typeId: 'channel', id: @channelId } }
          ], attributes: [ { name: 'mastersku', value: 'We add some content here in order to create another variant' } ] }
        ]
      @client.products.save(@product)
    .then (result) =>
      console.log 5
      @masterProductId = result.id
      @masterProductVersion = result.version
      data =
        actions: [
          { action: 'publish' }
        ]
        version: result.version
      @client.products.byId(@masterProductId).save(data)
    .then (result) =>
      console.log 6
      done()
    .fail (error) ->
      console.log error
      done error
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
    @product.slug.en = "p-#{@unique}1"
    @product.masterVariant.sku = "retailer-#{@unique}"
    @product.masterVariant.attributes = [
      { name: 'mastersku', value: "mastersku#{@unique}" }
    ]
    @product.masterVariant.prices = [
      { value: { currencyCode: 'EUR', centAmount: 9999 } }
      { value: { currencyCode: 'EUR', centAmount: 8999 }, customerGroup: { id: @customerGroupId, typeId: 'customer-group' } }
    ]
    @product.variants = [
      { sku: "retailer1-#{@unique}", prices: [
        { value: { currencyCode: 'EUR', centAmount: 20000 } }
        { value: { currencyCode: 'EUR', centAmount: 15000 }, customerGroup: { id: @customerGroupId, typeId: 'customer-group' } }
      ], attributes: [ { name: 'mastersku', value: "masterSKU2-#{@unique}" } ] }
      { sku: "retailer2-#{@unique}", prices: [
        { value: { currencyCode: 'EUR', centAmount: 99 } }
      ], attributes: [ { name: 'mastersku', value: "MasterSku3/#{@unique}" } ] }
    ]
    @client.products.save(@product)
    .then (result) =>
      console.log 7
      data =
        actions: [
          { action: 'publish' }
        ]
        version: result.version

      @client.products.byId(result.id).save(data)
    .then (result) =>
      console.log 7.5
      data =
        actions: [
          { action: 'setAttribute', variantId: 1, name: 'mastersku', value: 'alksvbkl;jsdvn' }
        ]
        version: @masterProductVersion
      @client.products.byId(@masterProductId).save(data)
    .then (result) =>
      console.log 8
      @priceSync.run()
    .then (msg) =>
      console.log "SYNC RESULT", msg

      @client.products.byId(@masterProductId).fetch()
    .then (result) ->
      expect(_.size result.masterData.current.masterVariant.prices).toBe 2
      expect(_.size result.masterData.current.variants[0].prices).toBe 2
      expect(_.size result.masterData.current.variants[1].prices).toBe 1

      price = result.masterData.current.masterVariant.prices[0]
      expect(price.value.currencyCode).toBe 'EUR'
      expect(price.value.centAmount).toBe 9999
      expect(price.channel.typeId).toBe 'channel'
      expect(price.channel.id).toBeDefined()
      expect(price.customerGroup).toBeUndefined()

      price = result.masterData.staged.masterVariant.prices[0]
      expect(price.value.currencyCode).toBe 'EUR'
      expect(price.value.centAmount).toBe 9999
      expect(price.channel.typeId).toBe 'channel'
      expect(price.channel.id).toBeDefined()
      expect(price.customerGroup).toBeUndefined()

      price = result.masterData.current.masterVariant.prices[1]
      expect(price.value.currencyCode).toBe 'EUR'
      expect(price.value.centAmount).toBe 8999
      expect(price.channel.typeId).toBe 'channel'
      expect(price.channel.id).toBeDefined()
      expect(price.customerGroup.typeId).toBe 'customer-group'
      expect(price.customerGroup.id).toBeDefined()

      price = result.masterData.staged.masterVariant.prices[1]
      expect(price.value.currencyCode).toBe 'EUR'
      expect(price.value.centAmount).toBe 8999
      expect(price.channel.typeId).toBe 'channel'
      expect(price.channel.id).toBeDefined()
      expect(price.customerGroup.typeId).toBe 'customer-group'
      expect(price.customerGroup.id).toBeDefined()

      price = result.masterData.current.variants[0].prices[0]
      expect(price.value.currencyCode).toBe 'EUR'
      expect(price.value.centAmount).toBe 20000
      expect(price.channel.typeId).toBe 'channel'
      expect(price.channel.id).toBeDefined()
      expect(price.customerGroup).toBeUndefined()

      price = result.masterData.staged.variants[0].prices[0]
      expect(price.value.currencyCode).toBe 'EUR'
      expect(price.value.centAmount).toBe 20000
      expect(price.channel.typeId).toBe 'channel'
      expect(price.channel.id).toBeDefined()
      expect(price.customerGroup).toBeUndefined()

      price = result.masterData.current.variants[0].prices[1]
      expect(price.value.currencyCode).toBe 'EUR'
      expect(price.value.centAmount).toBe 15000
      expect(price.channel.typeId).toBe 'channel'
      expect(price.channel.id).toBeDefined()
      expect(price.customerGroup.typeId).toBe 'customer-group'
      expect(price.customerGroup.id).toBeDefined()

      price = result.masterData.staged.variants[0].prices[1]
      expect(price.value.currencyCode).toBe 'EUR'
      expect(price.value.centAmount).toBe 15000
      expect(price.channel.typeId).toBe 'channel'
      expect(price.channel.id).toBeDefined()
      expect(price.customerGroup.typeId).toBe 'customer-group'
      expect(price.customerGroup.id).toBeDefined()

      price = result.masterData.current.variants[1].prices[0]
      expect(price.value.currencyCode).toBe 'EUR'
      expect(price.value.centAmount).toBe 99
      expect(price.channel.typeId).toBe 'channel'
      expect(price.channel.id).toBeDefined()
      expect(price.customerGroup).toBeUndefined()

      price = result.masterData.staged.variants[1].prices[0]
      expect(price.value.currencyCode).toBe 'EUR'
      expect(price.value.centAmount).toBe 99
      expect(price.channel.typeId).toBe 'channel'
      expect(price.channel.id).toBeDefined()
      expect(price.customerGroup).toBeUndefined()

      done()

    .fail (error) ->
      console.log error
      done error
    .done()

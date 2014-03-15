_ = require('underscore')._
Config = require '../config'
PriceSync = require '../lib/pricesync'
Q = require 'q'

# Increase timeout
jasmine.getEnv().defaultTimeoutInterval = 20000

describe '#run', ->
  beforeEach (done) ->
    options =
      baseConfig:
        logConfig: {}
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
      deferred = Q.defer()
      data =
        actions: [
          { action: 'unpublish' }
        ]
        version: version
      @client.products.byId(id).save(data).then (result) =>
        @rest.DELETE "/products/#{id}?version=#{result.version}", (error, response, body) ->
          if error
            deferred.reject error
          else
            if response.statusCode is 200
              deferred.resolve body
            else
              deferred.reject body
      deferred.promise

    @priceSync.masterClient.products.perPage(0).fetch()
    .then (products) ->
      deletions = _.map products.results, (product) ->
        delProducts product.id, product.version
      Q.all(deletions)
    .then =>
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
          { sku: "mastersku2#{@unique}", attributes: [ { name: 'mastersku', value: 'We add some content here in order to create the variant' } ] }
        ]
      @client.products.save(@product)
    .then (result) =>
      @masterProductId = result.id
      data =
        actions: [
          { action: 'publish' }
        ]
        version: result.version
      @client.products.byId(@masterProductId).save(data)
    .then (result) =>
      @priceSync.getCustomerGroup(@client, 'specialPrice')
    .then (result) =>
      @customerGroupId = result.id
      done()
    .fail (error) ->
      console.log error
      done error
    .done()

  xit 'do nothing', (done) ->
    @priceSync.run (msg) ->
      done(msg) unless msg.status
      expect(msg.status).toBe true
      expect(msg.message).toBe 'Nothing to do.'
      done()

  # workflow
  # - create a product for the retailer with the mastersku attribute
  # - run sync twice
  # - check price updates
  it 'sync normal price on masterVariant and in variant', (done) ->
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
      { sku: 'retailer1-#{@unique}', prices: [
        { value: { currencyCode: 'EUR', centAmount: 20000 } }
        { value: { currencyCode: 'EUR', centAmount: 15000 }, customerGroup: { id: @customerGroupId, typeId: 'customer-group' } }
      ], attributes: [ { name: 'mastersku', value: "mastersku2#{@unique}" } ] }
    ]
    @client.products.save(@product)
    .then (result) =>
      data =
        actions: [
          { action: 'publish' }
        ]
        version: result.version

      @client.products.byId(result.id).save(data)
    .then (result) =>
      @priceSync.run (msg) =>
        unless msg.status
          console.log msg
          done(msg)

        expect(msg.status).toBe true
        expect(_.size msg.message).toBe 4
        expect(msg.message['No mastersku attribute!']).toBe 1
        expect(msg.message['Prices updated.']).toBe 1
        expect(msg.message['Price update postponed.']).toBe 1
        expect(msg.message['There is no product in master for sku \'We add some content here in order to create the variant\'.']).toBe 1

        @priceSync.run (msg) =>
          unless msg.status
            console.log msg
            done()

          expect(msg.status).toBe true
          expect(_.size msg.message).toBe 3
          expect(msg.message['No mastersku attribute!']).toBe 1
          expect(msg.message['Prices updated.']).toBe 2
          expect(msg.message['There is no product in master for sku \'We add some content here in order to create the variant\'.']).toBe 1

          @client.products.byId(@masterProductId).fetch().then (result) ->
            expect(_.size result.masterData.current.masterVariant.prices).toBe 2
            expect(_.size result.masterData.current.variants[0].prices).toBe 2

            price = result.masterData.current.masterVariant.prices[0]
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

            price = result.masterData.current.variants[0].prices[0]
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

            done()
          .fail (error) ->
            console.log error
            done error
          .done()
    .fail (error) ->
      console.log error
      done error
    .done()
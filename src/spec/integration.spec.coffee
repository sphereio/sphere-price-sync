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
    @rest = @priceSync.masterClient._rest

    delProducts = (id, version) =>
      deferred = Q.defer()
      data =
        actions: [
          { action: 'unpublish' }
        ]
        version: version
      @rest.POST "/products/#{id}", data, (error, response, body) =>
        @rest.DELETE "/products/#{id}?version=#{body.version}", (error, response, body) ->
          if error
            deferred.reject error
          else
            if response.statusCode is 200 or response.statusCode is 400
              deferred.resolve true
            else
              deferred.reject body
      deferred.promise

    @priceSync.masterClient.products.perPage(0).fetch().then (products) ->
      dels = []
      for p in products.results
        dels.push delProducts(p.id, p.version)

      Q.all(dels).then (v) ->
        done()
      .fail (err) ->
        done(err)

  it 'do nothing', (done) ->
    @priceSync.run (msg) ->
      done(msg) unless msg.status
      expect(msg.status).toBe true
      expect(msg.message).toBe 'Nothing to do.'
      done()

  # workflow
  # - create a product type
  # - create a product for the master
  # - create a product for the retailer with the mastersku attribute
  # - run sync
  # - check price updates
  it 'sync a price', (done) ->
    unique = new Date().getTime()
    productType =
      name: "PT-#{unique}"
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
    @rest.POST '/product-types', productType, (error, response, body) =>
      expect(response.statusCode).toBe 201
      product =
        productType:
          typeId: 'product-type'
          id: body.id
        name:
          en: "P-#{unique}"
        slug:
          en: "p-#{unique}"
        masterVariant:
          sku: "mastersku#{unique}"
        variants: [
          { sku: "mastersku2#{unique}", attributes: [ { name: 'mastersku', value: 'We add some content here in order to create the variant' } ] }
        ]
      @rest.POST "/products", product, (error, response, body) =>
        masterProductId = body.id
        expect(response.statusCode).toBe 201
        data =
          actions: [
            { action: 'publish' }
          ]
          version: body.version
        @rest.POST "/products/#{body.id}", data, (error, response, body) =>
          expect(response.statusCode).toBe 200
          product.slug.en = "p-#{unique}1"
          product.masterVariant.sku = "retailer-#{unique}"
          product.masterVariant.attributes = [
            { name: 'mastersku', value: "mastersku#{unique}" }
          ]
          product.masterVariant.prices = [
            { value: { currencyCode: 'EUR', centAmount: 1 } }
          ]
          product.variants = [
            { sku: 'retailer1-#{unique}', prices: [ { value: { currencyCode: 'EUR', centAmount: 2 } } ], attributes: [ { name: 'mastersku', value: "mastersku2#{unique}" } ] }
          ]
          @rest.POST "/products", product, (error, response, body) =>
            expect(response.statusCode).toBe 201
            data =
              actions: [
                { action: 'publish' }
              ]
              version: body.version
            @rest.POST "/products/#{body.id}", data, (error, response, body) =>
              expect(response.statusCode).toBe 200
              @priceSync.run (msg) =>
                unless msg.status
                  console.log msg
                  done()

                expect(msg.status).toBe true
                expect(_.size msg.message).toBe 4
                expect(msg.message['No mastersku attribute!']).toBe 1
                expect(msg.message['Prices updated.']).toBe 1
                expect(msg.message['Price update postponed.']).toBe 1
                expect(msg.message['There is no product in master for sku \'We add some content here in order to create the variant\'.']).toBe 1

                @rest.GET "/products/#{masterProductId}", (error, response, body) =>
                  expect(response.statusCode).toBe 200
                  expect(_.size(body.masterData.current.masterVariant.prices) + _.size(body.masterData.current.variants[0].prices)).toBe 1
                  price = body.masterData.current.masterVariant.prices[0]
                  price or= body.masterData.current.variants[0].prices[0]
                  expect(price.value.currencyCode).toBe 'EUR'
                  expect(price.channel.typeId).toBe 'channel'
                  expect(price.channel.id).toBeDefined()
                  @priceSync.run (msg) =>
                    unless msg.status
                      console.log msg
                      done()

                    expect(msg.message['No mastersku attribute!']).toBe 1
                    expect(msg.message['Prices updated.']).toBe 2
                    expect(msg.message['There is no product in master for sku \'We add some content here in order to create the variant\'.']).toBe 1

                    @rest.GET "/products/#{masterProductId}", (error, response, body) =>
                      expect(response.statusCode).toBe 200
                      expect(_.size(body.masterData.current.masterVariant.prices) + _.size(body.masterData.current.variants[0].prices)).toBe 2
                      expect(price.channel.id).toBeDefined()

                      done()
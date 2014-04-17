_ = require 'underscore'
Q = require 'q'
Logger = require '../lib/logger'
PriceSync = require '../lib/pricesync'

describe 'PriceSync', ->

  beforeEach ->
    @logger = new Logger
      streams: [
        { level: 'error', stream: process.stderr }
      ]

    options =
      baseConfig:
        logConfig:
          logger: @logger
      master:
        project_key: 'x'
        client_id: 'y'
        client_secret: 'z'
      retailer:
        project_key: 'a'
        client_id: 'b'
        client_secret: 'c'

    @priceSync = new PriceSync options

  describe '#_filterPrices', ->
    it 'should work for no variants', ->
      data = @priceSync._filterPrices [], [], {}, {}
      expect(data.retailerPrices).toEqual []
      expect(data.masterPrices).toEqual []

    it 'should filter prices with unknown customer groups', ->
      rVariant =
        prices: [
          {}
          { customerGroup: { id: 'wanted' } }
        ]
      mVariant =
        prices: [
          {}
          { channel: { id: 'retailerX' } }
          { customerGroup: { id: 'unwanted' }, channel: { id: 'retailerX' } }
          { customerGroup: { id: 'foo' }, channel: { id: 'retailerX' } }
        ]
      data = @priceSync._filterPrices rVariant, mVariant, { id: 'wanted' }, { id: 'foo' }, { id: 'retailerX' }
      expect(_.size data.retailerPrices).toBe 2
      expect(_.size data.masterPrices).toBe 2
      expect(data.masterPrices[0]).toEqual { channel: { id: 'retailerX' } }
      expect(data.masterPrices[1]).toEqual { customerGroup: { id: 'foo' }, channel: { id: 'retailerX' } }

  describe '#_updatePrices', ->

    it 'should complain when there are no prices at retailer', ->
      updates = @priceSync._updatePrices [], [], 'bla', 'sku1'
      expect(_.size updates).toBe 0

    it 'should add a normal price', ->
      retailerPrice =
        value:
          currencyCode: 'EUR'
          centAmount: 9999
      updates = @priceSync._updatePrices [retailerPrice], [], 'retailerA', { id: 3, sku: 's3' }, true
      expect(_.size updates).toBe 1
      expectedAction =
        action: 'addPrice'
        variantId: 3
        price:
          value:
            currencyCode: 'EUR'
            centAmount: 9999
          channel:
            typeId: 'channel'
            id: 'retailerA'
        staged: false
      expect(updates[0]).toEqual expectedAction

    it 'should do nothing on wrong currencyCodes', ->
      retailerPrice =
        value:
          currencyCode: 'EUR'
          centAmount: 10000
      masterPrice =
        value:
          currencyCode: 'YEN'
          centAmount: 9999
        channel:
          typeId: 'channel'
          id: 'foo'
      updates = @priceSync._updatePrices [retailerPrice], [masterPrice], 'foo', { sku: 'sku1' }, true
      expect(_.size updates).toBe 0

    it 'should change a normal price', ->
      retailerPrice =
        value:
          currencyCode: 'EUR'
          centAmount: 10000
      masterPrice =
        value:
          currencyCode: 'EUR'
          centAmount: 9999
        channel:
          typeId: 'channel'
          id: 'retailerB'
      updates = @priceSync._updatePrices [retailerPrice], [masterPrice], 'retailerB', { id: 7, sku: 's7' }, false
      expect(_.size updates).toBe 1
      expectedAction =
        action: 'changePrice'
        variantId: 7
        price:
          value:
            currencyCode: 'EUR'
            centAmount: 10000
          channel:
            typeId: 'channel'
            id: 'retailerB'
        staged: true
      expect(updates[0]).toEqual expectedAction


    it 'should add a special price', ->
      retailerPrice =
        value:
          currencyCode: 'EUR'
          centAmount: 9999
        customerGroup:
          typeId: 'customer-group'
          id: 'cgR'
      updates = @priceSync._updatePrices [retailerPrice], [], 'retailerA', { id: 3, sku: 's3' }, true, 'cgR', 'cgM'
      expect(_.size updates).toBe 1
      expectedAction =
        action: 'addPrice'
        variantId: 3
        price:
          value:
            currencyCode: 'EUR'
            centAmount: 9999
          channel:
            typeId: 'channel'
            id: 'retailerA'
          customerGroup:
            typeId: 'customer-group'
            id: 'cgM'
        staged: false
      expect(updates[0]).toEqual expectedAction

    it 'should change a special price', ->
      retailerPrice =
        value:
          currencyCode: 'EUR'
          centAmount: 10000
        customerGroup:
          typeId: 'customer-group'
          id: 'cgRetailer'
      masterPrice =
        value:
          currencyCode: 'EUR'
          centAmount: 9999
        channel:
          typeId: 'channel'
          id: 'retailerB'
        customerGroup:
          typeId: 'customer-group'
          id: 'cgMaster'

      updates = @priceSync._updatePrices [retailerPrice], [masterPrice], 'retailerB', { id: 7, sku: 's7' }, true, 'cgRetailer', 'cgMaster'
      expect(_.size updates).toBe 1
      expectedAction =
        action: 'changePrice'
        variantId: 7
        price:
          value:
            currencyCode: 'EUR'
            centAmount: 10000
          channel:
            typeId: 'channel'
            id: 'retailerB'
          customerGroup:
            typeId: 'customer-group'
            id: 'cgMaster'
        staged: false
      expect(updates[0]).toEqual expectedAction

    it 'should remove a special price', ->
      masterPrice =
        value:
          currencyCode: 'EUR'
          centAmount: 777
        channel:
          typeId: 'channel'
          id: 'retailerB'
        customerGroup:
          typeId: 'customer-group'
          id: 'cgMaster'

      updates = @priceSync._updatePrices [], [masterPrice], 'retailerB', { id: 3, sku: 's7' }, true, 'cgRetailer', 'cgMaster'
      expect(_.size updates).toBe 1
      expectedAction =
        action: 'removePrice'
        variantId: 3
        price:
          value:
            currencyCode: 'EUR'
            centAmount: 777
          channel:
            typeId: 'channel'
            id: 'retailerB'
          customerGroup:
            typeId: 'customer-group'
            id: 'cgMaster'
        staged: false
      expect(updates[0]).toEqual expectedAction

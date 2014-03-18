package_json = require '../package.json'
Config = require '../config'
Logger = require './logger'
PriceSync = require '../lib/pricesync'

argv = require('optimist')
  .usage('Usage: $0 --projectKey key --clientId id --clientSecret secret --logDir dir --logLevel level --timeout timeout')
  .describe('projectKey', 'Sphere.io project key (required if you use sphere-specific value transformers).')
  .describe('clientId', 'Sphere.io HTTP API client id (required if you use sphere-specific value transformers).')
  .describe('clientSecret', 'Sphere.io HTTP API client secret (required if you use sphere-specific value transformers).')
  .describe('sphereHost', 'Sphere.io host.')
  .default('logLevel', 'info')
  .default('logDir', '.')
  .default('timeout', 60000)
  .demand(['projectKey','clientId', 'clientSecret'])
  .argv

logger = new Logger
  streams: [
    { level: 'error', stream: process.stderr }
    { level: argv.logLevel, path: "#{argv.logDir}/sphere-price-sync_#{argv.projectKey}.log" }
  ]

options =
  baseConfig:
    timeout: argv.timeout
    user_agent: "#{package_json.name} - #{package_json.version}"
    logConfig:
      logger: logger
  master: Config.config
  retailer:
    project_key: argv.projectKey
    client_id: argv.clientId
    client_secret: argv.clientSecret

options.baseConfig.host = argv.sphereHost if argv.sphereHost?

updater = new PriceSync options
updater.run()
.then (msg) ->
  logger.info message: msg
  process.exit 0
.fail (msg) ->
  logger.error error: msg
  process.exit 1
.done()

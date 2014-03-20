package_json = require '../package.json'
Config = require '../config'
Logger = require './logger'
PriceSync = require '../lib/pricesync'

argv = require('optimist')
  .usage('Usage: $0 --projectKey key --clientId id --clientSecret secret --logDir dir --logLevel level --timeout timeout')
  .describe('projectKey', 'your SPHERE.IO project-key')
  .describe('clientId', 'your SPHERE.IO OAuth client id')
  .describe('clientSecret', 'your SPHERE.IO OAuth client secret')
  .describe('timeout', 'timeout for requests')
  .describe('sphereHost', 'SPHERE.IO API host to connecto to')
  .describe('logLevel', 'log level for file logging')
  .describe('logDir', 'directory to store logs')
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

process.on 'SIGUSR2', ->
  logger.reopenFileStreams()

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
  logger.info info: msg, msg
  process.exit 0
.fail (msg) ->
  logger.error error: msg, msg
  process.exit 1
.done()

Q = require 'q'
_ = require 'underscore'

class TaskQueue
  constructor: ->
    @_queue = []
    @_active = false

  addTask: (taskFun) ->
    d = Q.defer()

    @_queue.push
      taskFun: taskFun
      defer: d
    @_maybeExecute()

    d.promise

  _maybeExecute: ->
    if not @_active and @_queue.length > 0
      @_startTasks @_queue.shift()

  _startTasks: (task) ->
    @_active = true

    task.taskFun()
    .then (result) ->
      task.defer.resolve result
    .fail (error) ->
      task.defer.reject error
    .finally =>
      @_active = false
      @_maybeExecute()
    .done()

module.exports = TaskQueue
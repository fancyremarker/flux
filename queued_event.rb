require 'json'
require 'logger'
require 'redis'

require './mql_translator.rb'
require './hyperloglog.rb'

class QueuedEvent
  @queue = :events
  schema = JSON.parse(File.open('config/schema.json').read)
  redis = Redis.new
  counter = HyperLogLog.new(redis, 10)
  @translator = MQLTranslator.new(redis, counter, schema)

  def self.perform(event_name, attrs)
    @translator.process_event(event_name, attrs)
  end
end

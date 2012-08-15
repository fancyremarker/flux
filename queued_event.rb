require 'json'
require 'logger'
require 'redis'

require './mql_translator.rb'

class QueuedEvent
  @queue = :events
  schema = JSON.parse(File.open('config/schema.json').read)
  @translator = MQLTranslator.new(Redis.new, schema)

  def self.perform(event_name, attrs)
    @translator.process_event(event_name, attrs)
  end
end

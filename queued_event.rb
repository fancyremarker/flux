require './mql_translator.rb'

class QueuedEvent
  @queue = :events

  def self.perform(config, schema_id, event_name, attrs)
    MQLTranslator.load(config).process_event(schema_id, event_name, attrs)
  end
end

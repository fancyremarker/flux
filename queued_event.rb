require './mql_translator.rb'

class QueuedEvent
  @queue = :events

  def self.perform(config, event_name, attrs)
    MQLTranslator.load(config).process_event(event_name, attrs)
  end
end

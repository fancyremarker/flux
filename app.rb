require 'json'
require 'logger'
require 'redis'
require 'resque'
require 'sinatra'

require './mql_translator.rb'
require './queued_event.rb'

schema = JSON.parse(File.open('config/schema.json').read)
log = Logger.new(STDOUT)
log.level = Logger::DEBUG
translator = MQLTranslator.new(Redis.new, schema, {logger: log})


# Receive an event
get '/event/:event' do
  event_name = params.delete('event')
  Resque.enqueue(QueuedEvent, event_name, params)
end

# Run a query
get '/query/:key' do
  content_type :json
  key = params['key']
  max_results = params['max_results'].to_i
  max_results = 50 if max_results < 1 or max_results > 50 
  cursor = params['cursor']
  translator.run_query(key, max_results, cursor).to_json
end

# Get a count
get '/count/:key' do
  content_type :json
  { 'count' => translator.get_count(params['key']) }.to_json
end

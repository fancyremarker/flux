require 'json'
require 'resque'
require 'sinatra'

require './mql_translator.rb'
require './queued_event.rb'
require './always_request_body.rb'
require './sync_database.rb'

use AlwaysRequestBody

config = YAML.load(File.read('config/app.yml'))[ENV['RACK_ENV'] || 'development']
translator = MQLTranslator.load(config)

get '/schemas' do
  content_type :json
  translator.all_schema_ids.map{ |id| { 'id' => id, 'uri' => "/schema/#{id}" } }.to_json
end

get '/schema/:schemaId' do
  content_type :json
  schema = translator.get_schema(params['schemaId'])
  halt 404 unless schema
  { 'id' => params['schemaId'], 'schema' => schema }.to_json
end

post '/schema' do
  content_type :json
  schema_id = translator.add_schema(request.body.read.to_s)
  { 'id' => schema_id, 'uri' => "/schema/#{schema_id}" }.to_json
end

# Events are sent in the body of the POST, in a list of pairs of the form [event, params]
post '/schema/:schemaId/events' do
  content_type :json
  if ENV['READ_ONLY'] =~ /1|yes|true/
    halt 501, { error: "This Flux server is read-only" }.to_json
  end

  schema_id = params['schemaId']
  events = JSON.parse(request.body.read.to_s)
  events.each do |event_name, event_params|
    Resque.enqueue(QueuedEvent, config, schema_id, event_name, event_params)
  end
  nil
end

# Run a query
get '/query' do
  content_type :json
  keys = params['keys'] || []
  max_results = params['maxResults'].to_i
  max_results = 50 if max_results < 1 or max_results > 50
  translator.run_query(keys, max_results, params['cursor'], [params['minScore'], params['maxScore']]).to_json
end

# Get a distinct add count
get '/distinct' do
  content_type :json
  halt 400, { error: "maxScore not supported" }.to_json if params['maxScore']
  { 'count' => translator.get_distinct_count(params['keys'], params['op'], params['minScore']) }.to_json
end

# Store a distinct add count to a temporary key
post '/distinct' do
  content_type :json
  halt 400, { error: "maxScore not supported" }.to_json if params['maxScore']
  halt 400, { error: "intersection not supported" }.to_json if params['op'] == 'intersection'
  translator.store_distinct_count(params['keys'], params['op'], params['minScore']).to_json
end

# Get a gross add count
get '/gross' do
  content_type :json
  halt 400, { error: "maxScore not supported" }.to_json if params['maxScore']
  halt 400, { error: "intersection not supported" }.to_json if params['op'] == 'intersection'
  { 'count' => translator.get_gross_count(params['keys'], params['minScore']) }.to_json
end

# Get an estimate of the top k leaderboard candidates for a key
get '/top' do
  content_type :json
  translator.leaderboard(params['key'], params['maxResults']).to_json
end

get '/up' do
  content_type :json
  { 'redis' => translator.redis_up? }.to_json
end

if ENV['SYNC_URL']
  # Sync the app database with another redis database
  get '/sync' do
    Resque.enqueue(SyncDatabase, config, ENV['SYNC_URL'])
  end
end

not_found do
  content_type :json
  { 'error' => 'Not Found' }.to_json
end

require 'redis'
require 'json'
require 'logger'

require './hyperloglog.rb'

class MQLTranslator

  def initialize(redis, counter, schema, options={})
    @redis = redis
    @counter = counter
    @schema = schema
    if options[:logger]
      @log = options[:logger]
    else
      @log = Logger.new(STDOUT)
      @log.level = Logger::FATAL
    end
  end

  def self.load(settings)
    schema = JSON.parse(File.open('config/schema.json').read)
    log = Logger.new(STDOUT)
    log.level = Logger.const_get settings['log_level']
    app_redis = Redis.connect(url: settings['app_redis_url'])
    resque_redis = Redis.connect(url: settings['resque_redis_url'])
    Resque.redis = resque_redis
    counter = HyperLogLog.new(app_redis, settings['hyperloglog_precision'])
    MQLTranslator.new(app_redis, counter, schema, {logger: log})
  end

  def process_event(event_name, args)
    @schema.each_pair do |event_filter, handlers|
      next unless event_name.start_with?(event_filter)
      handlers.each do |handler|
        sorted_sets = resolve_keys(handler['targets'], event_name, args)
        op_counter = @redis.incrby('flux:op_counter', sorted_sets.length) - sorted_sets.length
        sorted_sets.each_with_index do |set_name, i|
          value_definition = handler['add'] || handler['remove']
          raise "Must specify either an add or remove handler" unless value_definition
          value = resolve_id(value_definition, event_name, args)
          store_values = handler['maxStoredValues'] != 0
          if handler['add']
            if store_values
              @log.debug { "Appending '#{value}' to #{set_name}" }
              @redis.zadd(set_name, op_counter + i, value)
            end
            if handler['maxStoredValues'] && store_values
              @log.debug { "Trimming the stored set to hold at most #{handler['maxStoredValues']} values" }
              @redis.zremrangebyrank(set_name, 0, -1 - handler['maxStoredValues'])
            end
            @log.debug { "Incrementing distinct count for #{set_name}" }
            @counter.add("flux:distinct:#{set_name}", value)
            @log.debug { "Incrementing gross count for #{set_name}" }
            @redis.incr("flux:gross:#{set_name}")
          elsif handler['remove']
            @log.debug { "Removing '#{value}' from #{set_name}" }
            @redis.zrem(set_name, value)
          end
        end
      end
    end
  end    

  def get_distinct_count(query)
    @counter.count("flux:distinct:#{query}")
  end

  def get_gross_count(query)
    @redis.get("flux:gross:#{query}").to_i
  end

  def run_query(query, max_results, start)
    start ||= "inf"
    raw_results = @redis.zrevrangebyscore(query, "(#{start}", "-inf", {withscores: true, limit: [0, max_results]})    
    results = raw_results.map{ |result| result.first }
    if results.length < max_results
      { 'results' => results }
    else
      { 'results' => results, 'next' => raw_results.last.last }
    end
  end

  def resolve_id(id, event_name, args)
    if id.start_with?('@')
      case id[1..-1]
      when 'eventName'
        event_name
      when 'day'
        "123"
      when 'week'
        "20"
      when 'month'
        "5"
      when 'requestIP'
        '192.168.0.1'
      when 'geoState'
        'NY'
      when 'geoCity'
        'NY-NY'
      when 'uniqueId'
        "#{(Time.now.to_f * 1000).to_i}"
      else
        raise "Unknown identifier #{id}"
      end
    elsif id.start_with?("'") and id.end_with?("'")
      id[1...-1]
    else
      value = args[id]
      raise "Unknown attribute #{id}" unless value
      value
    end
  end

  def resolve_keys(targets, event_name, args)
    multiplicands = targets.map do |target|
      components = target.split('.').reverse
      entries = components.pop[1...-1].split(',').map{ |x| resolve_id(x.strip, event_name, args) }
      while !components.empty? do
        key = components.pop
        entries = entries.map do |entry|
          sorted_set = "#{entry}:#{key}"
          components.empty? ? sorted_set : @redis.zrevrange(sorted_set, 0, -1)
        end.flatten
      end
      entries
    end
    multiplicands.first.product(*multiplicands[1..-1]).map{ |x| x.join(':') }
  end

end

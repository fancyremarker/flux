require 'cartesian-product'
require 'hyperloglog-redis'
require 'json'
require 'logger'
require 'redis'

class MQLTranslator

  def initialize(redis, counter, schema, options={})
    @redis = redis
    @counter = counter
    @schema = schema
    @op_counter_lower_bits = 0
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
    app_redis = Redis.connect(url: (ENV['APP_REDIS_URL'] || settings['app_redis_url']))
    resque_redis = Redis.connect(url: (ENV['RESQUE_REDIS_URL'] || settings['resque_redis_url']))
    Resque.redis = resque_redis
    counter = HyperLogLog.new(app_redis, settings['hyperloglog_precision'])
    MQLTranslator.new(app_redis, counter, schema, {logger: log})
  end

  def process_event(event_name, args)
    @schema.each_pair do |event_filter, handlers|
      next unless event_name.start_with?(event_filter)
      handlers.each do |handler|
        execute_handler(handler, event_name, args)
      end
    end

    if args['@target']
      # Explicitly enumerate accepted runtime args, to be safe
      runtime_args = {
        'targets'         => [args['@target']],
        'add'             => args['@add'],
        'remove'          => args['@remove'],
        'maxStoredValues' => args['@maxStoredValues']
      }
      execute_handler(runtime_args, event_name, args)
    end
  end

  def execute_handler(handler, event_name, args)
    sorted_sets = resolve_keys(handler['targets'], event_name, args)
    sorted_sets.each_with_index do |set_name_components, i|
      set_name = set_name_components.join(':')
      value_definition = handler['add'] || handler['remove']
      raise "Must specify either an add or remove handler" unless value_definition
      value = resolve_id(value_definition, event_name, args)
      store_values = handler['maxStoredValues'] != 0
      if handler['add']
        if store_values
          @log.debug { "Appending '#{value}' to #{set_name}" }
          timestamp = (Integer(args['@time']) rescue nil)
          @redis.zadd("flux:set:#{set_name}", op_counter(timestamp), value)
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
        @redis.zrem("flux:set:#{set_name}", value)
      end
    end
  end

  def get_distinct_count(query)
    @counter.count("flux:distinct:#{query}")
  end

  def get_gross_count(query)
    @redis.get("flux:gross:#{query}").to_i
  end

  def op_counter(seconds_since_the_epoch = nil)
    seconds_since_the_epoch ||= Time.now.to_f
    @op_counter_lower_bits = (@op_counter_lower_bits + 1) % 1024
    ((seconds_since_the_epoch * 1000).to_i << 10) + @op_counter_lower_bits
  end

  def run_query(query, max_results, start)
    start ||= "inf"
    raw_results = @redis.zrevrangebyscore("flux:set:#{query}", "(#{start}", "-inf", {withscores: true, limit: [0, max_results]})    
    results = raw_results.map{ |result| result.first }
    if results.length < max_results
      { 'results' => results }
    else
      { 'results' => results, 'next' => raw_results.last.last }
    end
  end

  def resolve_id(id, event_name, args)
    if id.start_with?('@')
      return args[id] if args[id]
      case id[1..-1]
      when 'eventName'
        event_name
      when 'uniqueId'
        op_counter.to_s
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
          components.empty? ? sorted_set : @redis.zrevrange("flux:set:#{sorted_set}", 0, -1)
        end.flatten
      end
      entries
    end
    CartesianProduct.new(*multiplicands)
  end

  def redis_up?
    time = Time.now.to_i
    @redis.set("flux:system:pingtime", time)
    @redis.get("flux:system:pingtime") == time.to_s
  end

end

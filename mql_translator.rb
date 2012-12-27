require 'cartesian-product'
require 'hyperloglog-redis'
require 'json'
require 'logger'
require 'murmurhash3'
require 'redis'
require 'securerandom'
require 'space-saver-redis'

class MQLTranslator

  def initialize(redis, counter, schema, options={})
    @redis = redis
    @counter = counter
    @schema = schema
    @op_counter_lower_bits = 0
    @stored_query_ttl = (ENV['STORED_QUERY_TTL'] || 300).to_i
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
    app_redis.slaveof('no', 'one') if ENV['UNLINK_APP_REDIS'] || settings['unlink_app_redis']
    resque_redis = Redis.connect(url: (ENV['RESQUE_REDIS_URL'] || settings['resque_redis_url']))
    Resque.redis = resque_redis
    counter = HyperLogLog::TimeSeriesCounter.new(app_redis, settings['hyperloglog_precision'])
    MQLTranslator.new(app_redis, counter, schema, {logger: log})
  end

  def process_event(event_name, args)
    @schema.each_pair do |event_filter, handlers|
      next unless event_name.start_with?(event_filter)
      handlers.each do |handler|
        begin
          execute_handler(handler, event_name, args)
        rescue Exception => e
          throw e unless e.message =~ /^Undefined attribute/
        end
      end
    end

    if args['@targets']
      # Explicitly enumerate accepted runtime args, to be safe
      runtime_args = {
        'targets'         => args['@targets'],
        'add'             => args['@add'],
        'remove'          => args['@remove'],
        'countFrequency'  => args['@countFrequency'],
        'maxStoredValues' => (args['@maxStoredValues'].to_i if args['@maxStoredValues'])
      }
      execute_handler(runtime_args, event_name, args)
    end
  end

  def execute_handler(handler, event_name, args)
    sorted_sets = resolve_keys(handler['targets'], event_name, args)
    sorted_sets.each do |set_name_components|
      set_name = set_name_components.join(':')
      value_definition = handler['add'] || handler['remove'] || handler['countFrequency']
      raise "Must specify either an add, remove, or countFrequency handler" unless value_definition
      value = resolve_id(value_definition, event_name, args)
      next unless value
      store_values = handler['maxStoredValues'] != 0
      timestamp = (Integer(args['@score']) rescue nil)

      if handler['add']
        if store_values
          @log.debug { "Appending '#{value}' to #{set_name}" }
          @redis.zadd("flux:set:#{set_name}", op_counter(timestamp, value), value)
        end
        if handler['maxStoredValues'] && store_values
          @log.debug { "Trimming the stored set to hold at most #{handler['maxStoredValues']} values" }
          @redis.zremrangebyrank(set_name, 0, -1 - handler['maxStoredValues'])
        end
        count_timestamp = timestamp || Time.now.to_i
        @log.debug { "Incrementing distinct count for #{set_name} using score #{count_timestamp}" }
        @counter.add("flux:distinct:#{set_name}", value, count_timestamp)
        @log.debug { "Incrementing gross count for #{set_name} using score #{count_timestamp}" }
        @counter.add("flux:gross:#{set_name}", op_counter(timestamp, value).to_s, count_timestamp)
      elsif handler['remove']
        @log.debug { "Removing '#{value}' from #{set_name}" }
        @redis.zrem("flux:set:#{set_name}", value)
      elsif handler['countFrequency']
        @log.debug { "Updating leaderboard for #{set_name} with #{value}" }
        leaderboard = SpaceSaver.new(@redis, handler['maxStoredValues'] || 10)
        leaderboard.increment("flux:leaderboard:#{set_name}", value)
      end

    end
  end

  def get_distinct_count(keys, op, min_score = nil)
    namespaced_keys = keys.map { |key| "flux:distinct:#{key}" }
    if op.to_s == 'intersection'
      @counter.intersection(namespaced_keys, (min_score || 0).to_i)
    else
      @counter.union(namespaced_keys, (min_score || 0).to_i)
    end
  end

  def store_distinct_count(keys, op, min_score = nil)
    key = SecureRandom.uuid
    namespaced_keys = keys.map { |key| "flux:distinct:#{key}" }
    target_key = "flux:distinct:#{key}"
    @counter.union_store(target_key, namespaced_keys, (min_score || 0).to_i)
    @redis.expire(target_key, @stored_query_ttl)
    { 'key' => key, 'ttl' => @stored_query_ttl }
  end

  def get_gross_count(keys, min_score = nil)
    namespaced_keys = keys.map { |key| "flux:gross:#{key}" }
    @counter.union(namespaced_keys, (min_score || 0).to_i)
  end

  def op_counter(score = nil, value = nil)
    if score && score.to_i > 0 && score.to_i < 2147483648 # 2**31
      # Client has provided their own score; use it. Append a hash of the
      # value to break ties.
      value_bits = value ? MurmurHash3::V32.murmur3_32_str_hash(value) % 1048576 : 0
      (score.to_i << 20) + value_bits
    else
      # Client did not provide a score, generate one from the current time,
      # to the millisecond, plus the value of a rotating 10-bit counter.
      seconds_since_the_epoch = Time.now.to_f
      milliseconds_part = (seconds_since_the_epoch * 1000).to_i % 1000
      @op_counter_lower_bits = (@op_counter_lower_bits + 1) % 1024
      (seconds_since_the_epoch.to_i << 20) + (milliseconds_part << 10) + @op_counter_lower_bits
    end
  end

  def run_query(keys, max_results, cursor, score_range = [nil, nil])
    min_score, max_score = score_range
    start, stop = "inf", "-inf"

    if min_score && !min_score.empty?
      stop = op_counter(min_score.to_i + 1)
    end

    if cursor && !cursor.empty?
      start = cursor
    elsif max_score && !max_score.empty?
      start = op_counter(max_score.to_i + 1)
    end

    all_results = keys.map { |key| @redis.zrevrangebyscore("flux:set:#{key}", "(#{start}", "#{stop}", { withscores: true, limit: [0, max_results] }).reverse }
    raw_results = max_results.times.map { (all_results.max_by { |results| (results.last || [nil,-1]).last } || []).pop }.compact

    results = raw_results.map { |result| result.first }.uniq
    if raw_results.length < max_results
      { 'results' => results }
    else
      { 'results' => results, 'next' => raw_results.last.last }
    end
  end

  def leaderboard(key, max_results)
    SpaceSaver.new(@redis, max_results || 100).leaders("flux:leaderboard:#{key}")
  end

  def resolve_id(id, event_name, args)
    if id.start_with?('@')
      return args[id] if args[id]
      case id[1..-1]
      when 'eventName'
        event_name
      when 'uniqueId'
        op_counter.to_s
      when 'daily'
        Time.at(args['@score'] || Time.now).utc.strftime("daily-%d-%m-%y")
      when 'weekly'
        Time.at(args['@score'] || Time.now).utc.strftime("weekly-%U-%y")
      when 'monthly'
        Time.at(args['@score'] || Time.now).utc.strftime("monthly-%m-%y")
      else
        raise "Unknown identifier #{id}"
      end
    elsif id.start_with?("'") and id.end_with?("'")
      id[1...-1]
    else
      args[id]
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
    @redis.set("flux:system:pingtime", time) == "OK"
  end

end

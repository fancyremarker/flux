require 'redis'
require 'json'
require 'logger'

class MQLTranslator

  def initialize(redis, schema, logger=nil)
    @redis = redis
    @schema = schema
    if logger
      @log = logger
    else
      @log = Logger.new(STDOUT)
      @log.level = Logger::FATAL
    end
  end

  def process_event(event_name, args)
    @schema.each_pair do |event_filter, handlers|
      next unless event_name.start_with?(event_filter)
      handlers.each do |handler|
        sorted_sets = resolve_keys(handler['targets'], event_name, args)
        sorted_sets.each do |set_name|
          value_definition = handler['add'] || handler['remove'] || handler['replaceWith']
          raise "Must specify either an add, remove, or replaceWith handler" unless value_definition
          value = resolve_id(value_definition, event_name, args)
          if handler['add']
            @log.debug { "* Appending '#{value}' to #{set_name}" }
            @redis.zadd(set_name, Time.now.to_i, value)
          elsif handler['remove']
            @log.debug { "* Removing '#{value}' from #{set_name}" }
            @redis.zrem(set_name, value)
          else
            @log.debug { "* Clearing out the set #{set_name} and adding the value #{value}" }
            @redis.del(set_name)
            @redis.zadd(set_name, Time.now.to_i, value)
          end
        end
      end
    end
  end

  def run_query(query)
    query.start_with?("#") ? @redis.zcard(query[1..-1]) : @redis.zrevrange(query, 0, -1)
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

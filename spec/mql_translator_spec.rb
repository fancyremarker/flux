require './mql_translator.rb'

describe MQLTranslator do

  before :each do
    @redis = Object.new
    @counter = Object.new
    @counter.stub(:add) {}
    @counter.stub(:count) {}

    @mock_schemas = {}
    @redis.stub(:hkeys).with('flux:schemas') { @mock_schemas.keys }
    @redis.stub(:hget).with('flux:schemas', anything()) { |schema_key, key| @mock_schemas[key] }
    @redis.stub(:hset).with('flux:schemas', anything(), anything()) { |schema_key, key, value| @mock_schemas[key] = value }
  end

  describe "identifier resolution" do
    before :each do
      @translator = MQLTranslator.new(@redis, @counter)
    end
    it "should recognize server-defined reserved ids" do
      @translator.resolve_id("@eventName", "foo.bar", {}).should == "foo.bar"
    end
    it "should raise an error on an unknown reserved id" do
      lambda { @translator.resolve_id("@UNDEFINED", "foo.bar", {}) }.should raise_error
    end
    it "should recognize literals" do
      @translator.resolve_id("'literal'", "foo.bar", {"literal" => "it's-a-trap!"}).should == "literal" 
    end
    it "should allow keys from the args hash as ids" do
      @translator.resolve_id("baz", "foo.bar", {"baz" => "foo"}).should == "foo"
    end
    it "should create a UTC-based daily bucket from the @daily id" do
      @translator.resolve_id("@daily", "foo.bar", {"@score" => Time.utc(2012,1,7).to_i}).should == "daily-07-01-12"
      @translator.resolve_id("@daily", "foo.bar", {"@score" => Time.utc(2012,1,7,11,59).to_i}).should == "daily-07-01-12"
      @translator.resolve_id("@daily", "foo.bar", {"@score" => Time.utc(2012,1,8).to_i}).should == "daily-08-01-12"
    end
    it "should create a UTC-based weekly bucket from the @daily id" do
      @translator.resolve_id("@weekly", "foo.bar", {"@score" => Time.utc(2012,2,7).to_i}).should == "weekly-06-12" # Tuesday
      @translator.resolve_id("@weekly", "foo.bar", {"@score" => Time.utc(2012,2,7,11,59).to_i}).should == "weekly-06-12"
      @translator.resolve_id("@weekly", "foo.bar", {"@score" => Time.utc(2012,2,6).to_i}).should == "weekly-06-12" # Monday
      @translator.resolve_id("@weekly", "foo.bar", {"@score" => Time.utc(2012,2,5).to_i}).should == "weekly-06-12" # Sunday
      @translator.resolve_id("@weekly", "foo.bar", {"@score" => Time.utc(2012,2,4).to_i}).should == "weekly-05-12" # Saturday
    end
    it "should create a UTC-based monthly bucket from the @daily id" do
      @translator.resolve_id("@monthly", "foo.bar", {"@score" => Time.utc(2012,1,31).to_i}).should == "monthly-01-12"
      @translator.resolve_id("@monthly", "foo.bar", {"@score" => Time.utc(2012,2,1).to_i}).should == "monthly-02-12"
    end
    it "should raise an error on a non-literal, non-server-defined id that isn't in the args hash" do
      lambda { @translator.resolve_id("baz", "foo.bar", {"bar" => "foo"}) }.should raise_error
    end
  end

  describe "key resolution" do
    before :each do
      @translator = MQLTranslator.new(@redis, @counter)
    end
    it "resolves a singleton id into itself" do
      @translator.resolve_keys(["['foobar']"], 'mock.event.name', {'mock' => 'args'}).map{ |x| x.join(':') }.should == ['foobar']
    end
    it "resolves a list of singleton ids into a single colon-delimited key" do
      @translator.resolve_keys(["['foo']", "['bar']", "['baz']"], 'mock.event.name', {'mock' => 'args'}).map{ |x| x.join(':') }.should == ['foo:bar:baz']
    end
    it "resolves a list of lists into their cartesian product" do
      input = ["['a','b']", "['c']", "['d','e','f']"]
      output = ['a:c:d', 'a:c:e', 'a:c:f', 'b:c:d', 'b:c:e', 'b:c:f']
      @translator.resolve_keys(input, 'mock.event.name', {'mock' => 'args'}).map{ |x| x.join(':') }.should == output
    end
    it "translates identifiers that occur in targets correctly" do
      expected_output = ['foo:mock.event.name', 'bar:mock.event.name']
      @translator.resolve_keys(["['foo', baz]", "[@eventName]"], 'mock.event.name', {'baz' => 'bar'}).map{ |x| x.join(':') }.should == expected_output
    end
    it "resolves a single join correctly" do
      @translator.resolve_keys(["[foo].bar"], 'mock.event.name', {'foo' => 'FOO'}).map{ |x| x.join(':') }.should == ["FOO:bar"]
    end
    it "resolves a sequence of joins correctly" do
      @redis.should_receive(:zrevrange).with('flux:set:FOO:baz', 0, -1).and_return(['item1', 'item2'])
      @redis.should_receive(:zrevrange).with('flux:set:BAR:baz', 0, -1).and_return(['item3', 'item4'])
      expected_output = ['item1:biz', 'item2:biz', 'item3:biz', 'item4:biz']
      @translator.resolve_keys(["[foo, bar].baz.biz"], 'mock.event.name', {'foo' => 'FOO', 'bar' => 'BAR'}).map{ |x| x.join(':') }.should == expected_output
    end
    it "resolves a combination of joins and literal sets correctly" do
      @redis.should_receive(:zrevrange).with('flux:set:mock.event.name:foo', 0, -1).and_return(['item1', 'item2'])
      expected_output = ['item1:bar:a:C', 'item1:bar:b:C', 'item2:bar:a:C', 'item2:bar:b:C']
      @translator.resolve_keys(["[@eventName].foo.bar", "['a','b']", "[c]"], "mock.event.name", {'c' => 'C'}).map{ |x| x.join(':') }.should == expected_output
    end
  end

  describe "event processing" do
    before(:each) do
      @redis.stub(:incrby) { 1000 }
      @redis.stub(:pipelined) { |&block| block.call }
      @redis.stub(:zremrangebyrank) { 0 }
      @redis.stub(:incr) { }
    end
    it "translates an add event to a redis zadd" do
      schema = {'myevent' => [{'targets' => ["['mydata']"], 'add' => 'id'}]}
      translator = MQLTranslator.new(@redis, @counter)
      schema_id = translator.add_schema(schema.to_json)
      @redis.should_receive(:zadd).with('flux:set:mydata', anything(), 'foobar')
      translator.process_event(schema_id, 'myevent', {'id' => 'foobar'})
    end
    it "translates a remove event to a redis zrem" do
      schema = {'myevent' => [{'targets' => ["['mydata']"], 'remove' => 'id'}]}
      translator = MQLTranslator.new(@redis, @counter)
      schema_id = translator.add_schema(schema.to_json)
      @redis.should_receive(:zrem).with('flux:set:mydata', 'foobar')
      translator.process_event(schema_id, 'myevent', {'id' => 'foobar'})
    end
    it "respects maxStoredValues directives by removing least recently added values from sets" do
      schema = {'myevent' => [{'targets' => ["['mydata']"], 'add' => 'id', 'maxStoredValues' => 3}]}
      translator = MQLTranslator.new(@redis, @counter)
      schema_id = translator.add_schema(schema.to_json)
      @redis.stub(:zadd) { }
      @redis.unstub(:zremrangebyrank)
      @redis.should_receive(:zremrangebyrank).with('mydata', 0, -4).exactly(8).times
      8.times { |i| translator.process_event(schema_id, 'myevent', {'id' => "foobar#{i}"}) }
    end
    it "triggers exactly the handlers that are keyed by prefixes of the event name" do
      schema = { 
        'a' => [{'targets' => ["['counter:a']"], 'add' => 'id'}],
        'a.b' => [{'targets' => ["['counter:a:b']"], 'add' => 'id'}],
        'a.b.c' => [{'targets' => ["['counter:a:b:c']"], 'add' => 'id'}],
        'a.d.c' => [{'targets' => ["['counter:a:d:c']"], 'add' => 'id'}],
        'a.b.c.d.e' => [{'targets' => ["['counter:a:b:c:d:e']"], 'add' => 'id'}]
      }
      translator = MQLTranslator.new(@redis, @counter)
      schema_id = translator.add_schema(schema.to_json)
      @redis.should_receive(:zadd).with('flux:set:counter:a', anything(), 'foobar')
      @redis.should_receive(:zadd).with('flux:set:counter:a:b', anything(), 'foobar')
      @redis.should_receive(:zadd).with('flux:set:counter:a:b:c', anything(), 'foobar')
      translator.process_event(schema_id, 'a.b.c.d', {'id' => 'foobar'})
    end
    it "triggers all handlers associated with a single key in sequence" do
      schema = { 
        'a' => [{'targets' => ["['counter:a']"], 'add' => 'id'},
                {'targets' => ["['counter:b']"], 'add' => 'id'},
                {'targets' => ["['counter:c']"], 'add' => 'id'}]
      }
      translator = MQLTranslator.new(@redis, @counter)
      schema_id = translator.add_schema(schema.to_json)
      @redis.should_receive(:zadd).with('flux:set:counter:a', anything(), 'foobar').ordered
      @redis.should_receive(:zadd).with('flux:set:counter:b', anything(), 'foobar').ordered
      @redis.should_receive(:zadd).with('flux:set:counter:c', anything(), 'foobar').ordered
      translator.process_event(schema_id, 'a.b', {'id' => 'foobar'})
    end
    it "accept a single handler specified in the event params" do
      schema = {}
      translator = MQLTranslator.new(@redis, @counter)
      schema_id = translator.add_schema(schema.to_json)
      @redis.should_receive(:zadd).with('flux:set:counter:a', anything(), 'foobar').ordered
      translator.process_event(schema_id, 'a.b', {'id' => 'foobar', '@targets' => ["['counter:a']"], '@add' => 'id' })
    end
    it "triggers leaderboard increments when countFrequency is specified" do
      schema = { 'a' => [{'targets' => ["['foobar']"], 'countFrequency' => 'id'}] }
      translator = MQLTranslator.new(@redis, @counter)
      schema_id = translator.add_schema(schema.to_json)
      SpaceSaver.any_instance.should_receive(:increment).with('flux:leaderboard:foobar', 'foobar_id')
      translator.process_event(schema_id, 'a.b.c', {'id' => 'foobar_id'})      
    end
  end

  describe "schema management" do
    before(:each) do
      @translator = MQLTranslator.new(@redis, @counter)
    end
    it "should return nil if asked for a schema it doesn't know about" do
      @translator.get_schema('foobar').should be_nil
    end
    it "should be able to retrieve registered schemas by id" do
      schema = { 'foo' => 'bar' }
      schema_id = @translator.add_schema(schema.to_json)
      @translator.get_schema(schema_id).should == schema
    end
    it "should be able to return all schema ids" do
      schema_ids = [{'foo' => 'bar'}, {'foo' => 'baz'}, {'biz' => 'baz'}].map do |schema|
        @translator.add_schema(schema.to_json)
      end
      @translator.all_schema_ids.sort.should == schema_ids.sort
    end
    it "should aggressively cache known schemas" do
      translator = MQLTranslator.new(@redis, @counter)
      schema = {'foo' => 'barbaz'}
      schema_id = translator.add_schema(schema.to_json)

      # Out of all of the following get_schema calls, only one (the call to
      # a lookup of a non-existent schema) should result in a lookup in Redis
      @redis.unstub(:hget)
      @redis.should_receive(:hget).exactly(1).times do |schema_key, key|
        @mock_schemas[key]
      end
      10.times { translator.get_schema(schema_id) }
      translator.get_schema('unknown schema id').should be_nil
    end
  end

  describe "op_counter" do
    before(:each) do
      @redis = Object.new
      @counter = Object.new
    end
    it "should return a sequence of distinct ascending ids when called repeatedly" do
      translator = MQLTranslator.new(@redis, @counter)
      ids = 1000.times.map { translator.op_counter }
      ids.sort.should == ids
      ids[0..-2].zip(ids[1..-1]).each { |x,y| x.should < y }
    end
    it "should generate ids that can be expressed in at most 52 bits" do
      # These ids are used as scores in Redis sorted sets. Scores are stored
      # as double-precision floating point numbers, which use only 52 bits for
      # the significand. So, to make sure that we get the same integer out of
      # Redis that we insert, we have to keep our ids expressable in <= 52 bits. 

      translator = MQLTranslator.new(@redis, @counter)
      1000.times.map { Math.log(translator.op_counter, 2) }.max.should <= 52
    end
    it "should allow you to generate unique ids based on a specified score" do
      translator = MQLTranslator.new(@redis, @counter)
      first_counts = 10.times.map { translator.op_counter }
      sleep 1
      score = Time.now.to_i
      sleep 1
      last_counts = 10.times.map { translator.op_counter }
      middle_counts = 100.times.map{ |x| translator.op_counter(score, 'id') }
      ids = first_counts + middle_counts + last_counts
      ids.sort.should == ids
      ids[0..-2].zip(ids[1..-1]).each { |x,y| x.should <= y }
    end
    it "should generate unique ids for different values with the same score" do
      translator = MQLTranslator.new(@redis, @counter)
      score = Time.now.to_i
      id1a_counter = translator.op_counter(score, 'id1')
      id1b_counter = translator.op_counter(score, 'id1')
      id2_counter = translator.op_counter(score, 'id2')
      id1a_counter.should == id1b_counter
      id1a_counter.should_not == id2_counter
    end
    it "should store the score (or seconds and milliseconds) in bit-aligned compartments" do
      translator = MQLTranslator.new(@redis, @counter)
      time = Time.now
      Time.stub(:now) { time }
      seconds = time.to_i
      milliseconds = (time.to_f * 1000).to_i % 1000
      explicit_counter = translator.op_counter(seconds, 'id')
      implicit_counter = translator.op_counter
      (explicit_counter >> 20).should == seconds
      (implicit_counter >> 20).should == seconds
      ((implicit_counter >> 10) % 1024).should == milliseconds
    end
    it "should reject non-positive or out-of-range scores" do
      translator = MQLTranslator.new(@redis, @counter)
      time = Time.now
      Time.stub(:now) { time }
      implicit_counter = translator.op_counter
      counter1 = translator.op_counter(1, 'id')
      counter2 = translator.op_counter(0, 'id')
      counter3 = translator.op_counter(-1, 'id')
      counter4 = translator.op_counter(2**32, 'id')
      (counter1 >> 10).should_not == (implicit_counter >> 10)
      (counter2 >> 10).should == (implicit_counter >> 10)
      (counter3 >> 10).should == (implicit_counter >> 10)
      (counter4 >> 10).should == (implicit_counter >> 10)
    end
  end

end

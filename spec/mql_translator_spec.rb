require './mql_translator.rb'

describe MQLTranslator do

  before :each do
    @redis = Object.new
    @counter = Object.new
    @counter.stub(:add) {}
    @counter.stub(:count) {}
  end

  describe "identifier resolution" do
    before :each do
      @translator = MQLTranslator.new(@redis, @counter, {})
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
    it "should raise an error on a non-literal, non-server-defined id that isn't in the args hash" do
      lambda { @translator.resolve_id("baz", "foo.bar", {"bar" => "foo"}) }.should raise_error
    end
  end

  describe "key resolution" do
    before :each do
      @translator = MQLTranslator.new(@redis, @counter, {})
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
      schema = { 
        'myevent' => [{'targets' => ["['mydata']"], 'add' => 'id'}]
      }
      translator = MQLTranslator.new(@redis, @counter, schema)
      @redis.should_receive(:zadd).with('flux:set:mydata', anything(), 'foobar')
      translator.process_event('myevent', {'id' => 'foobar'})
    end
    it "translates a remove event to a redis zrem" do
      schema = { 
        'myevent' => [{'targets' => ["['mydata']"], 'remove' => 'id'}]
      }
      translator = MQLTranslator.new(@redis, @counter, schema)
      @redis.should_receive(:zrem).with('flux:set:mydata', 'foobar')
      translator.process_event('myevent', {'id' => 'foobar'})
    end
    it "respects maxStoredValues directives by removing least recently added values from sets" do
      schema = { 
        'myevent' => [{'targets' => ["['mydata']"], 'add' => 'id', 'maxStoredValues' => 3}]
      }
      translator = MQLTranslator.new(@redis, @counter, schema)
      @redis.stub(:zadd) { }
      @redis.unstub(:zremrangebyrank)
      @redis.should_receive(:zremrangebyrank).with('mydata', 0, -4).exactly(8).times
      8.times { |i| translator.process_event('myevent', {'id' => "foobar#{i}"}) }
    end
    it "triggers exactly the handlers that are keyed by prefixes of the event name" do
      schema = { 
        'a' => [{'targets' => ["['counter:a']"], 'add' => 'id'}],
        'a.b' => [{'targets' => ["['counter:a:b']"], 'add' => 'id'}],
        'a.b.c' => [{'targets' => ["['counter:a:b:c']"], 'add' => 'id'}],
        'a.d.c' => [{'targets' => ["['counter:a:d:c']"], 'add' => 'id'}],
        'a.b.c.d.e' => [{'targets' => ["['counter:a:b:c:d:e']"], 'add' => 'id'}]
      }
      translator = MQLTranslator.new(@redis, @counter, schema)
      @redis.should_receive(:zadd).with('flux:set:counter:a', anything(), 'foobar')
      @redis.should_receive(:zadd).with('flux:set:counter:a:b', anything(), 'foobar')
      @redis.should_receive(:zadd).with('flux:set:counter:a:b:c', anything(), 'foobar')
      translator.process_event('a.b.c.d', {'id' => 'foobar'})
    end
    it "triggers all handlers associated with a single key in sequence" do
      schema = { 
        'a' => [{'targets' => ["['counter:a']"], 'add' => 'id'},
                {'targets' => ["['counter:b']"], 'add' => 'id'},
                {'targets' => ["['counter:c']"], 'add' => 'id'}]
      }
      translator = MQLTranslator.new(@redis, @counter, schema)
      @redis.should_receive(:zadd).with('flux:set:counter:a', anything(), 'foobar').ordered
      @redis.should_receive(:zadd).with('flux:set:counter:b', anything(), 'foobar').ordered
      @redis.should_receive(:zadd).with('flux:set:counter:c', anything(), 'foobar').ordered
      translator.process_event('a.b', {'id' => 'foobar'})
    end
  end

  describe "op_counter" do
    before(:each) do
      @redis = Object.new
      @counter = Object.new
      @schema = Object.new      
    end
    it "should return a sequence of distinct ascending ids when called repeatedly" do
      translator = MQLTranslator.new(@redis, @counter, @schema)
      ids = 1000.times.map { translator.op_counter }
      ids.sort.should == ids
      ids[0..-2].zip(ids[1..-1]).each { |x,y| x.should < y }
    end
    it "should generate ids that can be expressed in at most 52 bits" do
      # These ids are used as scores in Redis sorted sets. Scores are stored
      # as double-precision floating point numbers, which use only 52 bits for
      # the significand. So, to make sure that we get the same integer out of
      # Redis that we insert, we have to keep our ids expressable in <= 52 bits. 

      translator = MQLTranslator.new(@redis, @counter, @schema)
      1000.times.map { Math.log(translator.op_counter, 2) }.max.should <= 52
    end
    it "should allow you to generate unique ids based on a given time" do
      translator = MQLTranslator.new(@redis, @counter, @schema)
      first_counts = 10.times.map { translator.op_counter }
      sleep 1
      time = Time.now.to_f
      sleep 1
      last_counts = 10.times.map { translator.op_counter }
      middle_counts = 100.times.map{ |x| translator.op_counter(time) }
      ids = first_counts + middle_counts + last_counts
      ids.sort.should == ids
      ids[0..-2].zip(ids[1..-1]).each { |x,y| x.should < y }
    end
  end

end

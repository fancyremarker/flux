require './mql_translator.rb'

describe MQLTranslator do

  before :each do
    @redis = Object.new
  end

  describe "identifier resolution" do
    before :each do
      @translator = MQLTranslator.new(@redis, {})
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
      @translator = MQLTranslator.new(@redis, {})
    end
    it "resolves a singleton id into itself" do
      @translator.resolve_keys(["['foobar']"], 'mock.event.name', {'mock' => 'args'}).should == ['foobar']
    end
    it "resolves a list of singleton ids into a single colon-delimited key" do
      @translator.resolve_keys(["['foo']", "['bar']", "['baz']"], 'mock.event.name', {'mock' => 'args'}).should == ['foo:bar:baz']
    end
    it "resolves a list of lists into their cartesian product" do
      input = ["['a','b']", "['c']", "['d','e','f']"]
      output = ['a:c:d', 'a:c:e', 'a:c:f', 'b:c:d', 'b:c:e', 'b:c:f']
      @translator.resolve_keys(input, 'mock.event.name', {'mock' => 'args'}).should == output
    end
    it "translates identifiers that occur in targets correctly" do
      expected_output = ['foo:mock.event.name', 'bar:mock.event.name']
      @translator.resolve_keys(["['foo', baz]", "[@eventName]"], 'mock.event.name', {'baz' => 'bar'}).should == expected_output
    end
    it "resolves a single join correctly" do
      @translator.resolve_keys(["[foo].bar"], 'mock.event.name', {'foo' => 'FOO'}).should == ["FOO:bar"]
    end
    it "resolves a sequence of joins correctly" do
      @redis.should_receive(:zrevrange).with('FOO:baz', 0, -1).and_return(['item1', 'item2'])
      @redis.should_receive(:zrevrange).with('BAR:baz', 0, -1).and_return(['item3', 'item4'])
      expected_output = ['item1:biz', 'item2:biz', 'item3:biz', 'item4:biz']
      @translator.resolve_keys(["[foo, bar].baz.biz"], 'mock.event.name', {'foo' => 'FOO', 'bar' => 'BAR'}).should == expected_output
    end
    it "resolves a combination of joins and literal sets correctly" do
      @redis.should_receive(:zrevrange).with('mock.event.name:foo', 0, -1).and_return(['item1', 'item2'])
      expected_output = ['item1:bar:a:C', 'item1:bar:b:C', 'item2:bar:a:C', 'item2:bar:b:C']
      @translator.resolve_keys(["[@eventName].foo.bar", "['a','b']", "[c]"], "mock.event.name", {'c' => 'C'}).should == expected_output
    end
  end

  describe "event processing" do
    before(:each) do
      @redis.stub(:incrby) { 1000 }
      @redis.stub(:pipelined) { |&block| block.call }
      @redis.stub(:zremrangebyscore) { 0 }
    end
    it "translates an add event to a redis zadd" do
      schema = { 
        'myevent' => [{'targets' => ["['mydata']"], 'add' => 'id'}]
      }
      translator = MQLTranslator.new(@redis, schema)
      @redis.should_receive(:zadd).with('mydata', anything(), 'foobar')
      translator.process_event('myevent', {'id' => 'foobar'})
    end
    it "translates a remove event to a redis zrem" do
      schema = { 
        'myevent' => [{'targets' => ["['mydata']"], 'remove' => 'id'}]
      }
      translator = MQLTranslator.new(@redis, schema)
      @redis.should_receive(:zrem).with('mydata', 'foobar')
      translator.process_event('myevent', {'id' => 'foobar'})
    end
    it "translates a replaceWith event to a redis rem, followed by a zadd" do
      schema = { 
        'myevent' => [{'targets' => ["['mydata']"], 'replaceWith' => 'id'}]
      }
      translator = MQLTranslator.new(@redis, schema)
      @redis.should_receive(:del).with('mydata')
      @redis.should_receive(:zadd).with('mydata', anything(), 'foobar')
      translator.process_event('myevent', {'id' => 'foobar'})
    end
    it "manages memory taken up by events kept in sets by keeping only the most recent entries" do
      schema = { 
        'myevent' => [{'targets' => ["['mydata']"], 'add' => 'id'}]
      }
      translator = MQLTranslator.new(@redis, schema, {max_transient_values: 5})
      i = 0
      @redis.stub(:incrby) { i = i+1 }
      @redis.stub(:zadd) { 0 }
      @redis.stub(:zremrangebyscore) { 0 }
      6.times { |i| translator.process_event('myevent', {'id' => "foobar #{i}"}) }
      @redis.unstub(:zadd)
      @redis.unstub(:zremrangebyscore)
      @redis.should_receive(:zadd).with('mydata', anything(), 'foobar 6').ordered
      @redis.should_receive(:zremrangebyscore).with('mydata', '-inf', '(1').ordered
      @redis.should_receive(:zadd).with('mydata', anything(), 'foobar 7').ordered
      @redis.should_receive(:zremrangebyscore).with('mydata', '-inf', '(2').ordered
      2.times { |i| translator.process_event('myevent', {'id' => "foobar #{6 + i}"}) }
    end
    it "doesn't run any deletions on a set if a handler declares expires: false" do
      schema = { 
        'myevent' => [{'targets' => ["['mydata']"], 'add' => 'id', 'expires' => false}]
      }
      translator = MQLTranslator.new(@redis, schema, {max_transient_values: 5})
      i = 0
      @redis.stub(:incrby) { i = i+1 }
      @redis.stub(:zadd) { 0 }
      @redis.stub(:zremrangebyscore) { 0 }
      6.times { |i| translator.process_event('myevent', {'id' => "foobar #{i}"}) }
      @redis.unstub(:zadd)
      @redis.unstub(:zremrangebyscore)
      @redis.should_receive(:zadd).with('mydata', anything(), 'foobar 6').ordered
      @redis.should_receive(:zadd).with('mydata', anything(), 'foobar 7').ordered
      @redis.should_not_receive(:zremrangebyscore)
      2.times { |i| translator.process_event('myevent', {'id' => "foobar #{6 + i}"}) }
    end
    it "triggers exactly the handlers that are keyed by prefixes of the event name" do
      schema = { 
        'a' => [{'targets' => ["['counter:a']"], 'add' => 'id'}],
        'a.b' => [{'targets' => ["['counter:a:b']"], 'add' => 'id'}],
        'a.b.c' => [{'targets' => ["['counter:a:b:c']"], 'add' => 'id'}],
        'a.d.c' => [{'targets' => ["['counter:a:d:c']"], 'add' => 'id'}],
        'a.b.c.d.e' => [{'targets' => ["['counter:a:b:c:d:e']"], 'add' => 'id'}]
      }
      translator = MQLTranslator.new(@redis, schema)
      @redis.should_receive(:zadd).with('counter:a', anything(), 'foobar')
      @redis.should_receive(:zadd).with('counter:a:b', anything(), 'foobar')
      @redis.should_receive(:zadd).with('counter:a:b:c', anything(), 'foobar')
      translator.process_event('a.b.c.d', {'id' => 'foobar'})
    end
    it "triggers all handlers associated with a single key in sequence" do
      schema = { 
        'a' => [{'targets' => ["['counter:a']"], 'add' => 'id'},
                {'targets' => ["['counter:b']"], 'add' => 'id'},
                {'targets' => ["['counter:c']"], 'add' => 'id'}]
      }
      translator = MQLTranslator.new(@redis, schema)
      @redis.should_receive(:zadd).with('counter:a', anything(), 'foobar').ordered
      @redis.should_receive(:zadd).with('counter:b', anything(), 'foobar').ordered
      @redis.should_receive(:zadd).with('counter:c', anything(), 'foobar').ordered
      translator.process_event('a.b', {'id' => 'foobar'})
    end
  end

end

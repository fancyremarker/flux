require 'json'
require 'rack/test'

require './app.rb'


describe 'Flux' do
  include Rack::Test::Methods

  def app
    Sinatra::Application
  end

  before(:each) do
    @schema = {
      "client:gravity:action:follow" => [{
                                           "targets" => ["[followee].followers"],
                                           "add" => "follower"
                                         },
                                         {
                                           "targets" => ["[follower].sources"],
                                           "add" => "followee"
                                         }],
      "client:gravity:action:unfollow" => [{
                                             "targets" => ["[followee].followers"],
                                             "remove" => "follower"
                                           },
                                           {
                                             "targets" => ["[follower].sources"],
                                             "remove" => "followee"
                                           }]
    }
    post "/schema", @schema.to_json
    @schema_id = JSON.parse(last_response.body)['id']
  end

  describe "query paging" do
    before(:each) do
      100.times { |i| post "/schema/#{@schema_id}/events", [['client:gravity:action:follow:user', {followee: 'user0', follower: "user#{i+1}"}]].to_json }
    end
    it "returns a cursor as part of the result set if results aren't exhausted" do
      get "/query?keys[]=user0:followers&max_results=10"
      JSON.parse(last_response.body)['next'].should_not be_nil
    end
    it "allows paging through results by passing the cursor back in" do
      accumulated_results = []
      result_set_size = 1

      get "/query?keys[]=user0:followers&max_results=#{result_set_size}"
      result = JSON.parse(last_response.body)
      next_cursor = result['next']
      accumulated_results += result['results']

      while result['next'] do
        get "/query?keys[]=user0:followers&max_results=#{result_set_size}&cursor=#{next_cursor}"
        result = JSON.parse(last_response.body)
        accumulated_results += result['results']
        next_cursor = result['next']
        result_set_size += 1
      end

      accumulated_results.should == 100.times.map{ |i| "user#{100-i}" }
    end
    it "properly returns and pages the union of multiple sets" do
      accumulated_results = []
      result_set_size = 1

      5.times do |i|
        post "/schema/#{@schema_id}/events",
             [['client:gravity:action:follow:user', {follower: "user#{3*i+1}", followee: 'user1', '@score' => 3*i+1}],
              ['client:gravity:action:follow:user', {follower: "user#{3*i+2}", followee: 'user2', '@score' => 3*i+2}],
              ['client:gravity:action:follow:user', {follower: "user#{3*i+3}", followee: 'user3', '@score' => 3*i+3}],
              ['client:gravity:action:follow:user', {follower: "user#{3*i+3}", followee: 'user1', '@score' => 3*i+3}]].to_json
      end

      get "/query?keys[]=user1:followers&keys[]=user2:followers&keys[]=user3:followers&max_results=#{result_set_size}"
      result = JSON.parse(last_response.body)
      next_cursor = result['next']
      accumulated_results += result['results']

      while result['next'] do
        get "/query?keys[]=user1:followers&keys[]=user2:followers&keys[]=user3:followers&max_results=#{result_set_size}&cursor=#{next_cursor}"
        result = JSON.parse(last_response.body)
        accumulated_results += result['results']
        next_cursor = result['next']
        result_set_size += 1
      end

      accumulated_results.should == 15.times.map{ |i| "user#{15-i}" }
    end

    it "returns at most 50 results if you don't pass a max_results parameter" do
      get "/query?keys[]=user0:followers"
      response_json = JSON.parse(last_response.body)
      response_json['next'].should_not be_nil
      response_json['results'].length.should == 50
    end
    it "returns at most 50 results if you ask for too many results" do
      get "/query?keys[]=user0:followers&max_results=100"
      response_json = JSON.parse(last_response.body)
      response_json['next'].should_not be_nil
      response_json['results'].length.should == 50
    end

    describe "score ranges" do
      before(:each) do
        post "/schema/#{@schema_id}/events",
             [['client:gravity:action:follow:user', {follower: "user2", followee: 'user1', '@score' => 8}],
              ['client:gravity:action:follow:user', {follower: "user3", followee: 'user1', '@score' => 9}],
              ['client:gravity:action:follow:user', {follower: "user4", followee: 'user1', '@score' => 10}],
              ['client:gravity:action:follow:user', {follower: "user5", followee: 'user1', '@score' => 11}],
              ['client:gravity:action:follow:user', {follower: "user6", followee: 'user1', '@score' => 12}]].to_json
      end
      it "accepts a max_score argument to restrict results" do
        get "/query?keys[]=user1:followers&max_score=10"
        response_json = JSON.parse(last_response.body)
        response_json['results'].sort.should == ['user2', 'user3', 'user4'].sort
      end
      it "accepts a min_score argument to restrict results" do
        get "/query?keys[]=user1:followers&min_score=10"
        response_json = JSON.parse(last_response.body)
        response_json['results'].sort.should == ['user5', 'user6'].sort
      end
      it "accepts both a min_score and max_score to define a range of scores" do
        get "/query?keys[]=user1:followers&min_score=9&max_score=11"
        response_json = JSON.parse(last_response.body)
        response_json['results'].sort.should == ['user4', 'user5'].sort
      end
      it "doesn't get confused when an empty range is specified by min_score and max_score" do
        get "/query?keys[]=user1:followers&min_score=11&max_score=9"
        response_json = JSON.parse(last_response.body)
        response_json['results'].should be_empty
      end
    end
  end

  describe "schemas" do
    it "accepts new schemas via POST" do
      post "/schema", {'foo' => 'bar'}.to_json
      last_response.status.should == 200
      JSON.parse(last_response.body).keys.should == ['id', 'uri']
    end
    it "allows you to repost a schema and get the same id back" do
      post "/schema", {'foo' => 'bar'}.to_json
      last_response.status.should == 200
      first_id = JSON.parse(last_response.body)['id']
      post "/schema", {'foo' => 'bar'}.to_json
      last_response.status.should == 200
      JSON.parse(last_response.body)['id'].should == first_id
    end
    it "returns a valid URI from a POST to /schema" do
      my_schema = { 'foo' => 'bar' }
      post "/schema", my_schema.to_json
      last_response.status.should == 200
      get JSON.parse(last_response.body)['uri']
      JSON.parse(last_response.body)['schema'].should == my_schema
    end
    it "allows schemas to be retrieved by id" do
      get "/schema/#{@schema_id}"
      last_response.status.should == 200
      schema_data = JSON.parse(last_response.body)
      schema_data['id'].should == @schema_id
      schema_data['schema'].should == @schema
    end
    it "can return a list of all registered schema ids" do
      known_ids = [@schema_id]
      post "/schema", {'foo' => 'bar'}.to_json
      known_ids << JSON.parse(last_response.body)['id']
      post "/schema", {'bar' => 'baz'}.to_json
      known_ids << JSON.parse(last_response.body)['id']
      get "/schemas"
      JSON.parse(last_response.body).map{ |x| x['id'] }.sort.should == known_ids.sort
    end
    it "returns a valid URI in calls to /schemas" do
      my_schema = { 'foo' => 'bar' }
      post "/schema", my_schema.to_json
      last_response.status.should == 200
      schema_id = JSON.parse(last_response.body)['id']
      get "/schemas"
      last_response.status.should == 200
      get JSON.parse(last_response.body).select{ |x| x['id'] == schema_id }.first['uri']
      JSON.parse(last_response.body)['schema'].should == my_schema
    end
  end

  describe "distinct counts" do
    it "returns a decent correct distinct add event count for a set" do
      10.times { 50.times { |i| post "/schema/#{@schema_id}/events", [['client:gravity:action:follow:user', {follower: "user#{i+1}", followee: 'user0'}]].to_json } }
      get "/distinct?keys[]=user0:followers"
      JSON.parse(last_response.body)['count'].should be_within(10).of(50)
    end
    it "returns 0 if the set doesn't exist" do
      get "/distinct?keys[]=bad_user:followers"
      JSON.parse(last_response.body)['count'].should == 0
    end
    it "returns a correct union count for sets" do
      10.times { 50.times { |i| post "/schema/#{@schema_id}/events", [['client:gravity:action:follow:user', {follower: "user#{i+1}", followee: 'user0'}]].to_json } }
      10.times { 50.times { |i| post "/schema/#{@schema_id}/events", [['client:gravity:action:follow:user', {follower: "user#{i+31}", followee: 'user1'}]].to_json } }
      get "/distinct?keys[]=user0:followers&keys[]=user1:followers&op=union"
      JSON.parse(last_response.body)['count'].should be_within(10).of(80)
    end
    it "returns a correct intersection count for sets" do
      10.times { 50.times { |i| post "/schema/#{@schema_id}/events", [['client:gravity:action:follow:user', {follower: "user#{i+1}", followee: 'user0'}]].to_json } }
      10.times { 50.times { |i| post "/schema/#{@schema_id}/events", [['client:gravity:action:follow:user', {follower: "user#{i+21}", followee: 'user1'}]].to_json } }
      get "/distinct?keys[]=user0:followers&keys[]=user1:followers&op=intersection"
      JSON.parse(last_response.body)['count'].should be_within(10).of(30)
    end
    it "accepts a min_score argument to restrict results" do
      10.times do
        50.times { |i| post "/schema/#{@schema_id}/events", [['client:gravity:action:follow:user', {follower: "user#{i+1}", followee: 'user0', '@score' => i+1}]].to_json }
      end
      get "/distinct?keys[]=user0:followers&min_score=40"
      JSON.parse(last_response.body)['count'].should be_within(5).of(10)
    end
    it "raises an error if max_score is passed" do
      get "/distinct?keys[]=user0:followers&max_score=9000"
      last_response.status.should == 400
    end
    it "returns a valid temporary key and ttl from a POST" do
      5.times { 20.times { |i| post "/schema/#{@schema_id}/events", [['client:gravity:action:follow:user', {follower: "user#{i+1}", followee: 'user0'}]].to_json } }
      5.times { 20.times { |i| post "/schema/#{@schema_id}/events", [['client:gravity:action:follow:user', {follower: "user#{i+100}", followee: 'user1'}]].to_json } }
      post "/distinct?keys[]=user0:followers&keys[]=user1:followers"
      last_response.status.should == 200
      response = JSON.parse(last_response.body)
      response['ttl'].should > 0
      get "/distinct?keys[]=#{response['key']}"
      last_response.status.should == 200
      JSON.parse(last_response.body)['count'].should be_within(5).of(40)
    end
    it "doesn't allow intersection in POST queries" do
      post "/distinct?keys[]=user0:followers&keys[]=user1:followers&op=intersection"
      last_response.status.should == 400
    end
  end

  describe "gross counts" do
    it "returns a correct gross add event count for a set" do
      17.times { |i| post "/schema/#{@schema_id}/events", [['client:gravity:action:follow:user', {follower: "user#{i+1}", followee: 'user0'}]].to_json }
      17.times { |i| post "/schema/#{@schema_id}/events", [['client:gravity:action:unfollow:user', {follower: "user#{i+1}", followee: 'user0'}]].to_json }
      get "/gross?keys[]=user0:followers"
      JSON.parse(last_response.body)['count'].should be_within(5).of(17)
    end
    it "returns 0 if the set doesn't exist" do
      get "/gross?keys[]=bad_user:followers"
      JSON.parse(last_response.body)['count'].should == 0
    end
    it "returns a correct concatenated count for sets" do
      17.times { |i| post "/schema/#{@schema_id}/events", [['client:gravity:action:follow:user', {follower: "user#{i+1}", followee: 'user0'}]].to_json }
      17.times { |i| post "/schema/#{@schema_id}/events", [['client:gravity:action:unfollow:user', {follower: "user#{i+1}", followee: 'user0'}]].to_json }
      17.times { |i| post "/schema/#{@schema_id}/events", [['client:gravity:action:follow:user', {follower: "user#{i+1}", followee: 'user1'}]].to_json }
      17.times { |i| post "/schema/#{@schema_id}/events", [['client:gravity:action:unfollow:user', {follower: "user#{i+1}", followee: 'user1'}]].to_json }
      get "/gross?keys[]=user0:followers&keys[]=user1:followers"
      JSON.parse(last_response.body)['count'].should be_within(10).of(34)
    end
    it "counts keys added with the same op counter to be identical" do
      5.times do
        17.times { |i| post "/schema/#{@schema_id}/events", [['client:gravity:action:follow:user', {follower: "user#{i+1}", followee: 'user0', '@score' => 1}]].to_json }
        17.times { |i| post "/schema/#{@schema_id}/events", [['client:gravity:action:unfollow:user', {follower: "user#{i+1}", followee: 'user0', '@score' => 1}]].to_json }
      end
      17.times { |i| post "/schema/#{@schema_id}/events", [['client:gravity:action:follow:user', {follower: "user#{i+1}", followee: 'user0'}]].to_json }
      17.times { |i| post "/schema/#{@schema_id}/events", [['client:gravity:action:unfollow:user', {follower: "user#{i+1}", followee: 'user0'}]].to_json }
      get "/gross?keys[]=user0:followers&keys[]=user1:followers"
      JSON.parse(last_response.body)['count'].should be_within(10).of(34)
    end
    it "accepts a min_score argument to restrict results" do
      50.times { |i| post "/schema/#{@schema_id}/events", [['client:gravity:action:follow:user', {follower: "user#{i+1}", followee: 'user0', '@score' => i+1}]].to_json }
      get "/distinct?keys[]=user0:followers&min_score=40"
      JSON.parse(last_response.body)['count'].should be_within(5).of(10)
    end
    it "raises an error if max_score is passed" do
      get "/gross?keys[]=user0:followers&max_score=9000"
      last_response.status.should == 400
    end
    it "raises an error if op=intersection is passed" do
      get "/gross?keys[]=user0:followers&keys[]=user1:followers&op=intersection"
      last_response.status.should == 400
    end
  end

  describe "frequencies" do
    it "returns approximate frequency counts" do
      freq_schema = { '@targets' => ["['user:followed']"], '@count_frequency' => 'followee', '@max_stored_values' => 3 }
      20.times do |i|
        10.times { |j| post "/schema/#{@schema_id}/events", [['client:gravity:action:follow', {follower: "u#{i}:#{j}", followee: 'u3'}.merge(freq_schema)]].to_json }
        2.times { |j| post "/schema/#{@schema_id}/events", [['client:gravity:action:follow', {follower: "u#{i}:#{j}", followee: 'u0'}.merge(freq_schema)]].to_json }
        7.times { |j| post "/schema/#{@schema_id}/events", [['client:gravity:action:follow', {follower: "u#{i}:#{j}", followee: 'u1'}.merge(freq_schema)]].to_json }
        4.times { |j| post "/schema/#{@schema_id}/events", [['client:gravity:action:follow', {follower: "u#{i}:#{j}", followee: 'u2'}.merge(freq_schema)]].to_json }
      end
      get "/top?key=user:followed"
      last_response.status.should == 200
      json_response = JSON.parse(last_response.body)
      scores = json_response.map{ |x| x.last }
      scores.sort.reverse.should == scores
      json_response.map{ |x| x.first }.should == ['u3', 'u1', 'u2']
    end
  end

  describe "up" do
    it "returns 'redis': true if Redis is up" do
      get "/up"
      JSON.parse(last_response.body)['redis'].should == true
    end
    it "returns 'redis': false if Redis is down" do
      MQLTranslator.any_instance.stub(:redis_up?) { false }
      get "/up"
      JSON.parse(last_response.body)['redis'].should == false
    end
  end

  describe "read-only mode" do
    before do
      ENV['READ_ONLY'] = "1"
    end
    after do
      ENV['READ_ONLY'] = nil
    end
    it "rejects events if the READ_ONLY environment variable is set" do
      get "/query?keys[]=user1:followers&max_results=10"
      last_response.status.should == 200
      post "/schema/#{@schema_id}/events", [['client:gravity:action:follow:user', {follower: "user2", followee: 'user1'}]].to_json
      last_response.status.should == 501
    end
  end

end

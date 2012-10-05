require 'json'
require 'rack/test'

require './app.rb'


describe 'Flux' do
  include Rack::Test::Methods

  def app
    Sinatra::Application
  end

  describe "query paging" do
    before(:each) do
      100.times { |i| get "/event/client:gravity:action:follow:user?followed=user0&follower=user#{i+1}" }
    end
    it "returns a cursor as part of the result set if results aren't exhausted" do
      get "/query?keys[]=user0:followers&maxResults=10"
      JSON.parse(last_response.body)['next'].should_not be_nil
    end
    it "allows paging through results by passing the cursor back in" do
      accumulated_results = []
      result_set_size = 1

      get "/query?keys[]=user0:followers&maxResults=#{result_set_size}"
      result = JSON.parse(last_response.body)
      next_cursor = result['next']
      accumulated_results += result['results']

      while result['next'] do
        get "/query?keys[]=user0:followers&maxResults=#{result_set_size}&cursor=#{next_cursor}"
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
        get "/event/client:gravity:action:follow:user?followed=user1&follower=user#{3*i+1}&@score=#{3*i+1}"
        get "/event/client:gravity:action:follow:user?followed=user2&follower=user#{3*i+2}&@score=#{3*i+2}"
        get "/event/client:gravity:action:follow:user?followed=user3&follower=user#{3*i+3}&@score=#{3*i+3}"
        get "/event/client:gravity:action:follow:user?followed=user1&follower=user#{3*i+3}&@score=#{3*i+3}"
      end

      get "/query?keys[]=user1:followers&keys[]=user2:followers&keys[]=user3:followers&maxResults=#{result_set_size}"
      result = JSON.parse(last_response.body)
      next_cursor = result['next']
      accumulated_results += result['results']

      while result['next'] do
        get "/query?keys[]=user1:followers&keys[]=user2:followers&keys[]=user3:followers&maxResults=#{result_set_size}&cursor=#{next_cursor}"
        result = JSON.parse(last_response.body)
        accumulated_results += result['results']
        next_cursor = result['next']
        result_set_size += 1
      end

      accumulated_results.should == 15.times.map{ |i| "user#{15-i}" }
    end

    it "returns at most 50 results if you don't pass a maxResults parameter" do
      get "/query?keys[]=user0:followers"
      response_json = JSON.parse(last_response.body)
      response_json['next'].should_not be_nil
      response_json['results'].length.should == 50
    end
    it "returns at most 50 results if you ask for too many results" do
      get "/query?keys[]=user0:followers&maxResults=100"
      response_json = JSON.parse(last_response.body)
      response_json['next'].should_not be_nil
      response_json['results'].length.should == 50
    end
    it "accepts a maxScore argument to restrict results" do
      get "/event/client:gravity:action:follow:user?followed=user1&follower=user2&@score=9"
      get "/event/client:gravity:action:follow:user?followed=user1&follower=user3&@score=10"
      get "/event/client:gravity:action:follow:user?followed=user1&follower=user4&@score=11"
      get "/query?keys[]=user1:followers&maxScore=10"
      response_json = JSON.parse(last_response.body)
      response_json['results'].should == ['user3', 'user2']
    end
  end

  describe "distinct counts" do
    it "returns a decent correct distinct add event count for a set" do
      10.times { 50.times { |i| get "/event/client:gravity:action:follow:user?followed=user0&follower=user#{i+1}" } }
      get "/distinct?keys[]=user0:followers"
      (JSON.parse(last_response.body)['count'] - 50).abs.should < 10
    end
    it "returns 0 if the set doesn't exist" do
      get "/distinct?keys[]=badUser:followers"
      JSON.parse(last_response.body)['count'].should == 0
    end
    it "returns a correct union count for sets" do
      10.times { 50.times { |i| get "/event/client:gravity:action:follow:user?followed=user0&follower=user#{i+1}" } }
      10.times { 50.times { |i| get "/event/client:gravity:action:follow:user?followed=user1&follower=user#{i+31}" } }
      get "/distinct?keys[]=user0:followers&keys[]=user1:followers&op=union"
      (JSON.parse(last_response.body)['count'] - 80).abs.should < 10
    end
    it "returns a correct intersection count for sets" do
      10.times { 50.times { |i| get "/event/client:gravity:action:follow:user?followed=user0&follower=user#{i+1}" } }
      10.times { 50.times { |i| get "/event/client:gravity:action:follow:user?followed=user1&follower=user#{i+21}" } }
      get "/distinct?keys[]=user0:followers&keys[]=user1:followers&op=intersection"
      (JSON.parse(last_response.body)['count'] - 30).abs.should < 10
    end
  end

  describe "gross counts" do
    it "returns a correct gross add event count for a set" do
      17.times { |i| get "/event/client:gravity:action:follow:user?followed=user0&follower=user#{i+1}" }
      17.times { |i| get "/event/client:gravity:action:unfollow:user?followed=user0&follower=user#{i+1}" }
      get "/gross?keys[]=user0:followers"
      JSON.parse(last_response.body)['count'].should == 17
    end
    it "returns 0 if the set doesn't exist" do
      get "/gross?keys[]=badUser:followers"
      JSON.parse(last_response.body)['count'].should == 0
    end
    it "returns a correct union count for sets" do
      17.times { |i| get "/event/client:gravity:action:follow:user?followed=user0&follower=user#{i+1}" }
      17.times { |i| get "/event/client:gravity:action:unfollow:user?followed=user0&follower=user#{i+1}" }
      17.times { |i| get "/event/client:gravity:action:follow:user?followed=user1&follower=user#{i+1}" }
      17.times { |i| get "/event/client:gravity:action:unfollow:user?followed=user1&follower=user#{i+1}" }
      get "/gross?keys[]=user0:followers&keys[]=user1:followers"
      JSON.parse(last_response.body)['count'].should == 34
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
      get "/query?keys[]=user1:followers&maxResults=10"
      last_response.status.should == 200
      get "/event/client:gravity:action:follow:user?follower=user2&followed=user1"
      last_response.status.should == 501
    end
  end

end

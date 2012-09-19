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
      get "/query/user0:followers?max_results=10"
      JSON.parse(last_response.body)['next'].should_not be_nil
    end
    it "allows paging through results by passing the cursor back in" do
      accumulated_results = []
      result_set_size = 1

      get "/query/user0:followers?max_results=#{result_set_size}"
      result = JSON.parse(last_response.body)
      next_cursor = result['next']
      accumulated_results += result['results']

      while result['next'] do
        get "/query/user0:followers?max_results=#{result_set_size}&cursor=#{next_cursor}"
        result = JSON.parse(last_response.body)
        accumulated_results += result['results']
        next_cursor = result['next']
        result_set_size += 1
      end

      accumulated_results.should == 100.times.map{ |i| "user#{100-i}" }
    end
    it "returns at most 50 results if you don't pass a max_results parameter" do
      get "/query/user0:followers"
      response_json = JSON.parse(last_response.body)
      response_json['next'].should_not be_nil
      response_json['results'].length.should == 50
    end
    it "returns at most 50 results if you ask for too many results" do
      get "/query/user0:followers?max_results=100"
      response_json = JSON.parse(last_response.body)
      response_json['next'].should_not be_nil
      response_json['results'].length.should == 50
    end
  end

  describe "distinct counts" do
    it "returns a decent correct distinct add event count for a set" do
      10.times { 50.times { |i| get "/event/client:gravity:action:follow:user?followed=user0&follower=user#{i+1}" } }
      get "/distinct/user0:followers"
      (JSON.parse(last_response.body)['count'] - 50).abs.should < 10
    end
    it "returns 0 if the set doesn't exist" do
      get "/distinct/badUser:followers"
      JSON.parse(last_response.body)['count'].should == 0
    end
  end

  describe "gross counts" do
    it "returns a correct gross add event count for a set" do
      17.times { |i| get "/event/client:gravity:action:follow:user?followed=user0&follower=user#{i+1}" }
      17.times { |i| get "/event/client:gravity:action:unfollow:user?followed=user0&follower=user#{i+1}" }
      get "/gross/user0:followers"
      JSON.parse(last_response.body)['count'].should == 17
    end
    it "returns 0 if the set doesn't exist" do
      get "/gross/badUser:followers"
      JSON.parse(last_response.body)['count'].should == 0
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
      get "/query/user1:followers?max_results=10"
      last_response.status.should == 200
      get "/event/client:gravity:action:follow:user?follower=user2&followed=user1"
      last_response.status.should == 501
    end
  end

end

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
      100.times { |i| get "/event/client.gravity.actions.follow.user?followedId=user0&followerId=user#{i+1}" }
    end
    it "returns a cursor as part of the result set if results aren't exhausted" do
      get "/query/user0:followerIds?max_results=10"
      JSON.parse(last_response.body)['next'].should_not be_nil
    end
    it "allows paging through results by passing the cursor back in" do
      accumulated_results = []
      result_set_size = 1

      get "/query/user0:followerIds?max_results=#{result_set_size}"
      result = JSON.parse(last_response.body)
      next_cursor = result['next']
      accumulated_results += result['results']

      while result['next'] do
        get "/query/user0:followerIds?max_results=#{result_set_size}&cursor=#{next_cursor}"
        result = JSON.parse(last_response.body)
        accumulated_results += result['results']
        next_cursor = result['next']
        result_set_size += 1
      end

      accumulated_results.should == 100.times.map{ |i| "user#{100-i}" }
    end
    it "returns at most 50 results if you don't pass a max_results parameter" do
      get "/query/user0:followerIds"
      response_json = JSON.parse(last_response.body)
      response_json['next'].should_not be_nil
      response_json['results'].length.should == 50
    end
    it "returns at most 50 results if you ask for too many results" do
      get "/query/user0:followerIds?max_results=100"
      response_json = JSON.parse(last_response.body)
      response_json['next'].should_not be_nil
      response_json['results'].length.should == 50
    end
  end

  describe "distinct counts" do
    it "returns a decent correct distinct add event count for a set" do
      10.times { 50.times { |i| get "/event/client.gravity.actions.follow.user?followedId=user0&followerId=user#{i+1}" } }
      get "/distinct_add_count/user0:followerIds"
      (JSON.parse(last_response.body)['count'] - 50).abs.should < 10
    end
    it "returns 0 if the set doesn't exist" do
      get "/distinct_add_count/badUser:followerIds"
      JSON.parse(last_response.body)['count'].should == 0
    end
  end

  describe "gross counts" do
    it "returns a correct gross add event count for a set" do
      17.times { |i| get "/event/client.gravity.actions.follow.user?followedId=user0&followerId=user#{i+1}" }
      17.times { |i| get "/event/client.gravity.actions.unfollow.user?followedId=user0&followerId=user#{i+1}" }
      get "/gross_add_count/user0:followerIds"
      JSON.parse(last_response.body)['count'].should == 17
    end
    it "returns 0 if the set doesn't exist" do
      get "/gross_add_count/badUser:followerIds"
      JSON.parse(last_response.body)['count'].should == 0
    end
  end

  describe "following" do
    it "updates followerIds on the followed user" do
      get "/query/user1:followerIds?max_results=10"
      JSON.parse(last_response.body).should == { 'results' => [] }
      get "/event/client.gravity.actions.follow.user?followerId=user2&followedId=user1"
      get "/query/user1:followerIds?max_results=10"
      JSON.parse(last_response.body)['results'].should == ['user2']
    end
    it "doesn't add duplicates to the followed list even if the event fires multiple times" do
      get "/query/user1:followerIds?max_results=10"
      JSON.parse(last_response.body)['results'].should == []
      10.times do
        get "/event/client.gravity.actions.follow.user?followerId=user2&followedId=user1"
        get "/event/client.gravity.actions.follow.user?followerId=user3&followedId=user1"
      end
      get "/query/user1:followerIds?max_results=10"
      JSON.parse(last_response.body)['results'].sort.should == ['user2', 'user3']
    end
  end

  describe "unfollowing" do
    before(:each) do
      get "/event/client.gravity.actions.follow.user?followerId=user2&followedId=user1"
      get "/event/client.gravity.actions.follow.user?followerId=user3&followedId=user1"
      get "/query/user1:followerIds?max_results=10"
      JSON.parse(last_response.body)['results'].sort.should == ['user2', 'user3']
    end
    it "updates followerIds on the unfollowed user" do
      get "/event/client.gravity.actions.unfollow.user?followerId=user3&followedId=user1"
      get "/query/user1:followerIds?max_results=10"
      JSON.parse(last_response.body)['results'].sort.should == ['user2']
    end
    it "is a no-op if the user isn't following the user they're trying to unfollow in the first place" do
      get "/event/client.gravity.actions.unfollow.user?followerId=user4&followedId=user1"
      get "/query/user1:followerIds?max_results=10"
      JSON.parse(last_response.body)['results'].sort.should == ['user2', 'user3']      
    end
  end

  describe "posting" do
    before(:each) do
      # 4 users, each user follows every user less than him/her.
      get "/event/client.gravity.actions.follow.user?followerId=user2&followedId=user1"
      get "/event/client.gravity.actions.follow.user?followerId=user3&followedId=user1"
      get "/event/client.gravity.actions.follow.user?followerId=user3&followedId=user2"
      get "/event/client.gravity.actions.follow.user?followerId=user4&followedId=user1"
      get "/event/client.gravity.actions.follow.user?followerId=user4&followedId=user2"
      get "/event/client.gravity.actions.follow.user?followerId=user4&followedId=user3"
    end
    it "updates the feed of all users following the poster" do
      get "/event/client.gravity.actions.post?id=user1&postId=post1"
      ['user2', 'user3', 'user4'].each do |user|
        get "/query/#{user}:feedIds?max_results=10"
        JSON.parse(last_response.body)['results'].should == ['post1']
      end
    end
    it "sends a sequence of posts to the correct subscribers" do
      4.times { |i| get "/event/client.gravity.actions.post?id=user#{i+1}&postId=post#{i+1}" }
      get "/query/user1:feedIds?max_results=10"
      JSON.parse(last_response.body)['results'].sort.should == []
      get "/query/user2:feedIds?max_results=10"
      JSON.parse(last_response.body)['results'].sort.should == ['post1']
      get "/query/user3:feedIds?max_results=10"
      JSON.parse(last_response.body)['results'].sort.should == ['post1', 'post2']
      get "/query/user4:feedIds?max_results=10"
      JSON.parse(last_response.body)['results'].sort.should == ['post1', 'post2', 'post3']
    end
    it "returns most recently posted posts first" do
      get "/event/client.gravity.actions.post?id=user1&postId=post1"
      get "/event/client.gravity.actions.post?id=user2&postId=post2"
      get "/event/client.gravity.actions.post?id=user3&postId=post3"
      get "/event/client.gravity.actions.post?id=user1&postId=post4"
      get "/query/user4:feedIds?max_results=10"
      JSON.parse(last_response.body)['results'].should == ['post4', 'post3', 'post2', 'post1']
    end
  end

end

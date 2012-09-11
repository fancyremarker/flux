require './sync_database.rb'

describe 'SyncDatabase' do
  before :each do
    @redis = Object.new
    Redis.stub(:connect) { @redis }
  end
  it "should exit normally when master_sync_in_progress transitions from 1 to 0" do
    times = 5
    @redis.stub(:info) do
      times -= 1
      if times <= 0
        { 'master_sync_in_progress' => '0' }
      else
        { 'master_sync_in_progress' => '1' }
      end
    end
    @redis.should_receive(:slaveof).with("www.example.com", 1000).ordered
    @redis.should_receive(:slaveof).with(nil, nil).ordered
    SyncDatabase.perform({}, "redis://www.example.com:1000", {sleep_time: 0}) 
  end
  it "should raise an error if the master link is down for 10 consecutive polls" do
    times = 5
    @redis.stub(:info) do
      times -= 1
      if times <= 0
        { 'master_sync_in_progress' => '0', 'master_link_status' => 'down' }
      else
        { 'master_sync_in_progress' => '1' }
      end
    end
    @redis.should_receive(:slaveof).with("www.example.com", 1000).ordered
    @redis.should_receive(:slaveof).with(nil, nil).ordered
    lambda { SyncDatabase.perform({}, "redis://www.example.com:1000", {sleep_time: 0}) }.should raise_error
  end
end

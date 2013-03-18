require './restore_from_backup.rb'

describe 'RestoreFromBackup' do
  before :each do
    @redis = double('redis')
    @redis.stub(:shutdown)
    @redis.stub(:config) do |*args|
      case args
      when [ 'get', 'dbfilename' ]
        [ 'dbfilename', 'dump.rdb' ]
      when [ 'get', 'dir' ]
        [ 'dir', '/path/to/redis' ]
      when [ 'get', 'save' ]
        [ 'save', '900 1 300 10 60 10000' ]
      else
        []
      end
    end
    Redis.stub(:connect) { @redis }

    @s3 = double('s3_interface')
    @s3.stub(:get)
    RightAws::S3Interface.stub(:new) { @s3 }

    @file = double('file')
    @file.stub(:write)
    @file.stub(:close)
    File.stub(:open) { @file }
  end
  it "should take no action if S3_ACCESS_KEY_ID and S3_SECRET_ACCESS_KEY are not defined" do
    set_env('S3_ACCESS_KEY_ID', nil) do
      set_env('S3_SECRET_ACCESS_KEY', nil) do
        @s3.should_not_receive :get
        lambda {
          RestoreFromBackup.perform({}, 's3://example-bucket/dump.rdb')
        }.should raise_error
      end
    end
  end
  it "should get the file from S3, copy it to localhost, and restart the server" do
    set_env('S3_ACCESS_KEY_ID', 'access_key') do
      set_env('S3_SECRET_ACCESS_KEY', 'secret') do
        client = double('redis_client')
        client.stub(:call)
        @redis.stub(:client) { client }

        @redis.should_receive(:config).with('set', 'save', '')
        File.should_receive(:open).with('/path/to/redis/dump.rdb', 'w').and_return(@file)
        @s3.should_receive(:get) do |*args, &block|
          args[0].should == 'example-bucket'
          args[1].should == 'dump.rdb'
        end
        @file.should_receive(:close)
        @redis.should_receive(:config).with('set', 'save', '900 1 300 10 60 10000')
        @redis.client.should_receive(:call).with([ :shutdown, 'nosave' ])
        RestoreFromBackup.perform({}, 's3://example-bucket/dump.rdb')
      end
    end

  end
end

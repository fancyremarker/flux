require 'resque'

ENV['REDIS_URL'] = "redis://localhost:6379/15"
Resque.inline = true

RSpec.configure do |config|
  config.before(:each) do
    Redis.new.flushdb
  end
end

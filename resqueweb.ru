require 'resque'

Resque.redis = ENV['RESQUE_REDIS_URL'] || 'redis://localhost:6379/1'
require 'resque/server'

mount_at = ENV['RESQUEWEB_MOUNT_PATH'] || '/'
mount_at = "/#{mount_at}" unless mount_at[0] == '/'
run Rack::URLMap.new \
  mount_at => Resque::Server.new

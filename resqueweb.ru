require 'resque'
require 'yaml'

Resque.redis = ENV['RESQUE_REDIS_URL'] || YAML.load(File.read('config/app.yml'))[ENV['RACK_ENV'] || 'development']['resque_redis_url']
require 'resque/server'

mount_at = ENV['RESQUEWEB_MOUNT_PATH'] || '/'
mount_at = "/#{mount_at}" unless mount_at[0] == '/'
run Rack::URLMap.new \
  mount_at => Resque::Server.new

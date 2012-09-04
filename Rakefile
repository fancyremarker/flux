require 'resque/tasks'
require './queued_event.rb'

task "resque:setup" do
  ENV['QUEUE'] = '*'
  ENV['REDIS_URL'] ||= YAML.load(File.read('config/app.yml'))[ENV['RACK_ENV'] || 'development']['resque_redis_url']
end

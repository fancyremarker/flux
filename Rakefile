require 'resque/tasks'
require 'yaml'
require './queued_event.rb'
require './sync_database.rb'
require './restore_from_backup.rb'

task "resque:setup" do
  ENV['QUEUE'] = '*'
  ENV['INTERVAL'] = '0.2' # = 200 ms
  ENV['REDIS_URL'] ||= ENV['RESQUE_REDIS_URL'] || YAML.load(File.read('config/app.yml'))[ENV['RACK_ENV'] || 'development']['resque_redis_url']
end

desc "Restore a database backup (.rdb) from S3"
task "db:restore", [:s3_file] do |t, args|
  require 'progressbar'
  config = YAML.load(File.read('config/app.yml'))[ENV['RACK_ENV'] || 'development']
  backup_file = args[:s3_file] || ENV['S3_BACKUP_FILE']
  RestoreFromBackup.perform(config, backup_file, { :progressbar => ProgressBar })
end

require 'rspec/core'
require 'rspec/core/rake_task'

RSpec::Core::RakeTask.new(:spec) do |spec|
  spec.pattern = FileList['spec/**/*_spec.rb']
end

task :default => :spec

require 'redis'
require 'uri'

class SyncDatabase
  @queue = :sync

  def self.perform(settings, sync_url, options={})
    max_consecutive_failures = options[:max_consecutive_failures] || 10
    sleep_time = options[:sleep_time] || 5
    sync_uri = URI.parse(sync_url)
    app_redis = Redis.connect(url: (ENV['APP_REDIS_URL'] || settings['app_redis_url']))
    app_redis.flushdb
    app_redis.slaveof(sync_uri.host, sync_uri.port)
    consecutive_failed_attempts = 0
    while consecutive_failed_attempts < max_consecutive_failures do
      sleep sleep_time
      info = app_redis.info
      if info['master_link_status'] == 'down'
        consecutive_failed_attempts += 1
        next
      end
      consecutive_failed_attempts = 0
      break if info['master_sync_in_progress'] == '0'
    end
    app_redis.slaveof('no', 'one')
    raise "Sync failed, too many failures to connect to master" if consecutive_failed_attempts >= max_consecutive_failures
  end
end

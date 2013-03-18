require 'redis'
require 'right_aws'
require 'uri'

class RestoreFromBackup
  @queue = :restore

  def self.perform(settings, s3_backup_file_uri, options={})
    raise "Must specify S3 backup file URI" unless s3_backup_file_uri
    md = s3_backup_file_uri.match(/(?:s3:\/)?\/([^\/]+)\/(.+)/)
    raise "Invalid S3 URI: #{s3_backup_file_uri}" unless md
    s3_bucket = md[1]
    s3_file = md[2]

    s3_access_key_id = ENV['S3_ACCESS_KEY_ID'] || settings['s3_access_key_id']
    s3_secret_access_key = ENV['S3_SECRET_ACCESS_KEY'] || settings['s3_secret_access_key']
    raise "Must specify S3 access key ID and secret access key" unless s3_access_key_id && s3_secret_access_key

    app_redis = Redis.connect(url: (ENV['APP_REDIS_URL'] || settings['app_redis_url']))
    original_save_settings = app_redis.config('get', 'save').last
    app_redis.config('set', 'save', '')

    begin
      s3_interface = RightAws::S3Interface.new(s3_access_key_id, s3_secret_access_key)
      dbfile_basedir = app_redis.config('get', 'dir').last
      dbfile_name = app_redis.config('get', 'dbfilename').last
      dbfile = File.open(File.join(dbfile_basedir, dbfile_name), 'w')
      if options[:progressbar]
        dbfile_size = s3_interface.head(s3_bucket, s3_file)['content-length'].to_i
        pbar = options[:progressbar].new("S3 GET", dbfile_size)
      end
      s3_interface.get(s3_bucket, s3_file) do |chunk|
        dbfile.write(chunk)
        pbar.set([File.size(dbfile), dbfile_size].min) if pbar
      end
      pbar.finish if pbar
      dbfile.close
    ensure
      app_redis.config('set', 'save', original_save_settings)
    end
    begin
      # TODO: Replace with wrapped command once redis-rb gem supports SHUTDOWN modifiers
      # app_redis.shutdown('nosave')
      app_redis.client.call([ :shutdown, 'nosave' ])
    rescue Exception
      # Expected: server has shut down
    end
  end
end

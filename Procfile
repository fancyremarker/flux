web: bundle exec ruby app.rb -o localhost -p $PORT
resqueweb: bundle exec resque-web --foreground -o localhost -p $PORT -r ${RESQUE_REDIS_URL:-redis://localhost:6379/0}
resqueworker: bundle exec rake resque:work

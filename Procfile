web: bundle exec ruby app.rb -o localhost -p $PORT
resqueweb: bundle exec resque-web --foreground -o localhost -p $PORT
resque: bundle exec rake resque:work

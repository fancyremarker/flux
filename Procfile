web: bundle exec ruby app.rb -o localhost -p $PORT
resqueweb: bundle exec resque-web --foreground -o localhost -p $PORT
resqueworker: bundle exec rake resque:work

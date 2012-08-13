task :repl do
  require './app/mql_translator.rb'

  redis = Redis.new
  schema = JSON.parse(File.open('config/schema.json').read)
  log = Logger.new(STDOUT)
  log.level = Logger::DEBUG
  translator = MQLTranslator.new(redis, schema, log)
  while true do
    print "> "
    input = STDIN.gets.chomp.split
    if input[0] == 'q'
      puts translator.run_query(input[1])
    elsif input[0] == 'e'
      translator.process_event(input[1], JSON.parse(input[2..-1].join(' ').gsub("'","\"")))
    end
  end  
end
# Accepts a key/value pair or hash of new env vars. E.g.:
#   set_env 'OPT', '100' { ... }
#   set_end 'OPT' => '100', 'LINE' => '2' { ... }
def set_env(*args, &block)
  hash = args.first.is_a?(Hash) ? args.first : Hash[*args]
  old_values = Hash[hash.map{|k,v| [k, ENV[k]] }]
  begin
    hash.each{|k,v| ENV[k] = v }
    yield
  ensure
    old_values.each{|k,v| ENV[k] = v }
  end
end

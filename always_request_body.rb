# From http://www.songkick.com/devblog/2012/11/27/a-second-here-a-second-there/,
# Rack middleware to respond correctly to the header "Expect: 100-continue",
# which requires the server to respond immediately with status 100 (Continue)
# or respond with a final status code. Since Sinatra doesn't respect these
# headers but many clients send them, the end result is a client that hangs
# for a second or so any time a body over the length of a packet size is sent.
# Inserting this Rack middleware makes us do the right thing and avoid the
# hang on requests that span more than a packet.

class AlwaysRequestBody
  def initialize(app)
    @app = app
  end

  def call(env)
    if env["HTTP_EXPECT"] =~ /100-continue/
      [100, {}, [""]]
    else
      @app.call(env)
    end
  end
end

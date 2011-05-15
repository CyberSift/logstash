require "logstash/inputs/base"
require "logstash/namespace"

# Read events from a redis using BLPOP
#
# For more information about redis, see <http://redis.io/>
class LogStash::Inputs::Redis < LogStash::Inputs::Base

  config_name "redis"
  
  # The hostname of your redis server.
  config :host, :validate => :string, :default => "127.0.0.1"

  # The port to connect on.
  config :port, :validate => :number, :default => 6379

  # The redis database number.
  config :db, :validate => :number, :default => 0

  # Initial connection timeout in seconds.
  config :timeout, :validate => :number, :default => 5

  # Password to authenticate with. There is no authentication by default.
  config :password, :validate => :password

  # The name of a redis list or channel. Dynamic names are
  # valid here, for example "logstash-%{@type}".
  config :key, :validate => :string, :required => true

  # Either list or channel.  If redis_type is list, then we will BLPOP the 
  # key.  If redis_type is channel, then we will SUBSCRIBE to the key.
  config :data_type, :validate => [ "list", "channel" ], :required => true

  # Maximum number of retries on a read before we give up.
  config :retries, :validate => :number, :default => 5

  public
  def initialize(params)
    super

    @format ||= ["json_event"]
  end # def initialize

  public
  def register
    require 'redis'
    @redis = nil
    @redis_url = "redis://#{@password}@#{@host}:#{@port}/#{@db}"
    @logger.info "Registering redis #{identity}"
  end # def register

  # A string used to identify a redis instance in log messages
  private
  def identity
    "#{@redis_url} #{@data_type}:#{@key}"
  end

  private
  def connect
    Redis.new(
      :host => @host,
      :port => @port,
      :timeout => @timeout,
      :db => @db,
      :password => @password
    )
  end # def connect

  private
  def queue_event msg, output_queue
    begin
      e = LogStash::Event.new(JSON.parse(msg))
      output_queue << e if e
    rescue => e # parse or event creation error
      @logger.error(["Failed to create event with '#{msg}'", e])
      @logger.debug(["Backtrace",  e.backtrace])
    end
  end
  
  private
  def list_listener redis, output_queue
    response = redis.blpop @key, 0
    yield
    queue_event response[1], output_queue
  end

  private
  def channel_listener redis, output_queue
    redis.subscribe @key do |on|
      on.subscribe do |ch, count|
        @logger.info "Subscribed to #{ch} (#{count})"
        yield
      end

      on.message do |ch, message|
        queue_event message, output_queue
      end

      on.unsubscribe do |ch, count|
        @logger.info "Unsubscribed from #{ch} (#{count})"
      end
    end
  end

  # Since both listeners have the same basic loop, we've abstracted the outer
  # loop.  The only problem is that we need to reset retries on a successful
  # connection, even though the listener might not return (ever).  So we've
  # implement an "onsuccess" callback as a yield.
  private 
  def listener_loop listener, output_queue
    loop do
      retries = @retries
      begin
        # we need seperate instances of redis for each listener
        @redis ||= connect
        self.send listener, @redis, output_queue do
          retries = @retries
        end
      rescue => e # redis error
        @logger.warn(["Failed to get event from redis #{@name}. " +
                     "Will retry #{retries} times.", e])
        @logger.debug(["Backtrace", e.backtrace])
        if retries <= 0
          raise RuntimeError, "Redis connection failed too many times"
        end
        @redis = nil
        retries -= 1
        sleep(1)
        retry
      end
    end # loop
  end # listener_loop

  public
  def run(output_queue)
    if @data_type == 'list'
      listener_loop :list_listener, output_queue
    else
      listener_loop :channel_listener, output_queue
    end
  end # def run

  public
  def teardown
    if @data_type == 'channel' and @redis
      @redis.unsubscribe
    end
  end
end # class LogStash::Inputs::Redis

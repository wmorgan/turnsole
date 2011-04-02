require 'thread'

module Turnsole

## simple thread-safe logger with multiple output sinks. outputs to multiple
## sinks by calling << on them. keeps the last few lines of log output in
## memory and can copy that to a newly-added sink if necessary.
class Logger
  LEVELS = %w(debug info warn error) # in order!
  DEFAULT_KEEP_LINES = 10

  def initialize level=nil, opts={}
    self.level = level || ENV["TURNSOLE_LOG_LEVEL"] || "info"
    @keep_lines = opts[:keep_lines] || DEFAULT_KEEP_LINES
    @buf = []
    @sinks = []
    @mutex = Mutex.new
  end

  def level_index; @level end
  def level; LEVELS[@level] end
  def level= level
    @level = LEVELS.index level
    raise ArgumentError, "invalid log level #{level.inspect}: should be one of #{LEVELS * ', '}" unless @level
  end

  def is_at_finest_logging_level?; @level == 0 end
  def next_finest_logging_level; LEVELS[[@level - 1, 0].max] end

  def add_sink s, opts={}
    @sinks << s
    @buf.each { |l| s << l } if opts[:copy_current]
    s
  end

  def remove_sink s; @mutex.synchronize { @sinks.delete s } end
  def remove_all_sinks!; @mutex.synchronize { @sinks.clear } end
  def clear!; @mutex.synchronize { @buf.clear } end

  LEVELS.each_with_index do |l, method_level|
    define_method(l) do |s|
      send_message(format_message(l, Time.now, s)) if method_level >= @level
    end
  end

  ## send a message regardless of the current logging level
  def force_message m; send_message format_message(nil, Time.now, m) end

private

  ## level can be nil!
  def format_message level, time, msg
    prefix = case level
      when "warn"; "WARNING: "
      when "error"; "ERROR: "
      else ""
    end
    "[#{time.to_s}] #{prefix}#{msg.rstrip}\n"
  end

  ## actually distribute the message
  def send_message m
    @mutex.synchronize do
      @sinks.each { |sink| sink << m }
      @buf << m
      @buf = @buf[[(@buf.length - @keep_lines), 0].max .. -1]
      m
    end
  end
end

## include me to have top-level #debug, #info, etc. methods.
## requires you to define a #log method
module LogsStuff
  Logger::LEVELS.each { |l| define_method(l) { |s| log.send(l, s) } }
end

end

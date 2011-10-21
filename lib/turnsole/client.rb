require 'thread'
require 'heliotrope-client'

## all the methods here are asynchronous, except for ping!
## requests are queued and dispatched by the thread here. results are queued
## into the main turnsole ui thread, and dispatched there.
module Turnsole
class Client
  include LogsStuff

  def initialize context, url
    @context = context
    @client = HeliotropeClient.new url
    @client_mutex = Mutex.new # we sometimes access client from the main thread, for synchronous calls
    @q = Queue.new
  end

  def url; @client.url end

  def start!
    @thread = start_thread!
  end

  def stop!
    @thread.kill if @thread
  end

  ## the one method in here that is synchronous---good for pinging.
  def server_info; @client_mutex.synchronize { @client.info } end

  ## returns an array of ThreadSummary objects
  def search query, num, offset
    threads = perform :search, query, num, offset
    threads.map { |t| ThreadSummary.new t }
  end

  def threadinfo thread_id
    result = perform :threadinfo, thread_id
    ThreadSummary.new result
  end

  ## returns an array of [MessageSummary, depth] pairs
  def load_thread thread_id
    results = perform :thread, thread_id
    results.map { |m, depth| [MessageSummary.new(m), depth] }
  end

  def load_message message_id
    result = perform :message, message_id
    Message.new result
  end

  def thread_state thread_id
    result = perform :thread_state, thread_id
    Set.new result
  end

  def set_labels! thread_id, labels
    result = perform :set_labels!, thread_id, labels
    ThreadSummary.new result
  end

  def set_state! message_id, state
    result = perform :set_state!, message_id, state
    MessageSummary.new result
  end

  def set_thread_state! thread_id, state
    result = perform :set_thread_state!, thread_id, state
    ThreadSummary.new result
  end

  ## some methods we relay without change
  %w(message_part raw_message send_message bounce_message count size).each do |m|
    define_method(m) { |*a| perform(m.to_sym, *a) }
  end

  ## some methods we relay and set-ify the results
  %w(contacts labels prune_labels!).each do |m|
    define_method(m) { Set.new perform(m.to_sym) }
  end

private

  def perform cmd, *args
    @q.push [cmd, args, Fiber.current]
    val = Fiber.yield
    raise val if val.is_a? Exception
    val
  end

  def log; @context.log end

  def start_thread!
    Thread.new do
      while true
        cmd, args, fiber = @q.pop
        pretty = "#{cmd}#{args.inspect}"[0, 50]
        debug "sending to server: #{pretty}"
        @context.ui.enqueue :redraw

        #say_id = @context.screen.minibuf.say "loading #{pretty} ..."
        #@context.ui.enqueue :redraw

        startt = Time.now
        results = begin
          results = @client_mutex.synchronize { @client.send cmd, *args }
          extra = case results
            when Array; " and returned #{results.size} results"
            when String; " and returned #{results.size} bytes"
            else ""
          end
          info sprintf("remote call #{pretty} took %d ms#{extra}", (Time.now - startt) * 1000)
          results
        rescue Exception => e
          e
        end

        @context.ui.enqueue :server_response, results, fiber
      end
    end
  end
end
end

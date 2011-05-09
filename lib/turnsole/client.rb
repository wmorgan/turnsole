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
  def search query, num, offset, opts={}, &callback
    callback ||= opts[:callback]
    perform :search, opts.merge(:args => [query, num, offset], :callback => lambda { |threads| callback.call threads.map { |t| ThreadSummary.new(t) } })
  end

  def threadinfo thread_id, opts={}, &callback
    callback ||= opts[:callback]
    perform :threadinfo, opts.merge(:args => [thread_id], :callback => lambda { |r| callback.call ThreadSummary.new(r) })
  end

  ## returns an array of [MessageSummary, depth] pairs
  def load_thread thread_id, opts={}, &callback
    callback ||= opts[:callback]
    perform :thread, opts.merge(:args => [thread_id], :callback => lambda { |results| callback.call results.map { |m, depth| [MessageSummary.new(m), depth] } })
  end

  def load_message message_id, opts={}, &callback
    callback ||= opts[:callback]
    perform :message, opts.merge(:args => [message_id], :callback => lambda { |result| callback.call Message.new(result) })
  end

  def load_part message_id, part_id, opts={}, &callback
    callback ||= opts[:callback]
    perform :message_part, opts.merge(:args => [message_id, part_id], :callback => lambda { |result| callback.call result })
  end

  def thread_state thread_id, opts={}, &callback
    callback ||= opts[:callback]
    perform :thread_state, opts.merge(:args => [thread_id], :callback => lambda { |result| callback.call Set.new(result) })
  end

  ## get the element out of the hash for your convenience
  def count query, opts={}, &callback
    callback ||= opts[:callback]
    perform :count, opts.merge(:args => [query], :callback => lambda { |result| callback.call result["count"] })
  end

  ## get the element out of the hash for your convenience
  def size opts={}, &callback
    callback ||= opts[:callback]
    perform :size, opts.merge(:callback => lambda { |result| callback.call result["size"] })
  end

  ## for all other methods, we just send them to the client as is
  def method_missing m, *a, &callback
    opts = a.last.is_a?(Hash) ? a.pop : {}
    callback ||= opts[:callback]
    perform m, opts.merge(:args => a, :callback => callback)
  end

private

  def perform cmd, opts={}
    @q.push [cmd, opts]
  end

  def log; @context.log end

  def start_thread!
    Thread.new do
      while true
        cmd, opts = @q.pop
        args = opts[:args]
        pretty = "#{cmd}#{args.inspect}"[0, 50]
        debug "sending to server: #{pretty}"
        @context.ui.enqueue :redraw

        #say_id = @context.screen.minibuf.say "loading #{pretty} ..."
        #@context.ui.enqueue :redraw

        startt = Time.now
        begin
          results = @client_mutex.synchronize { @client.send(cmd, *args) }
          extra = results.is_a?(Array) ? " and returned #{results.size} results" : ""
          info sprintf("remote call #{pretty} took %d ms#{extra}", (Time.now - startt) * 1000)
          @context.ui.enqueue :server_results, [results], opts[:callback] if opts[:callback]
        rescue HeliotropeClient::Error => e
          message = "heliotrope client error: #{e.class.name}: #{e.message}"
          warn [message, e.backtrace[0..10].map { |l| "  "  + l }].flatten.join("\n")
          @context.ui.enqueue :server_results, [results], opts[:on_error] if opts[:on_error]
          @context.screen.minibuf.flash "Error: #{message}. See log for details."
          @context.ui.enqueue :redraw
        rescue StandardError => e
          @context.ui.enqueue :server_results, [e], opts[:on_error] if opts[:on_error]
        ensure
          @context.ui.enqueue :server_results, [], opts[:ensure] if opts[:ensure]

        end
      end
    end
  end
end
end

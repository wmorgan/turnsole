require 'thread'
require 'open3'
require 'set'

module Turnsole

## the user interface controller. maintains the event loop for the
## entire program. dispatches events to the appropriate fibers.
class UI
  include LogsStuff

  def initialize context
    @context = context
    @q = Queue.new # the main event queue
    @quit = false

    @event_listeners = Set.new

    ## a stack of input-drinking threads. topmost always gets it.
    @input_fibers = []
  end

  def log; @context.log end

  ## these methods are all globally-callable. go crazy
  def sigwinch_happened!; enqueue :sigwinch end
  def quit!
    @quit = true
    enqueue :noop
  end
  def quit?; @quit end
  def redraw!; enqueue :redraw end
  def flash message; enqueue :flash, message end
  def enqueue event, *args; @q.push [event, args] end

  ## event pub/sub stuff
  def add_event_listener l; @event_listeners << l end
  def remove_event_listener l; @event_listeners.delete l end
  def broadcast source, event, *args; enqueue :broadcast, source, event, *args end

  ## the main event loop. blocks. keep calling this until quit?
  def step
    @context.screen.draw!

    event, args = begin
      @q.pop
    rescue Interrupt
      [:interrupt, nil]
    end

    case event
    when :interrupt
      f = spawn_fiber do
        if @context.input.ask_yes_or_no "Die ungracefully now?"
          raise "O, I die, Horatio; The potent poison quite o'er-crows my spirit!"
        end
      end

      @input_fibers.push f
      f.resume
      @input_fibers.delete fiber unless fiber.alive?
    when :sigwinch
      @context.screen.resize_screen!
    when :keypress
      @context.screen.minibuf.clear_flash!
      key = args.first

      if @input_fibers.empty?
        ## spawn a fiber
        f = spawn_fiber { @context.input.handle key }
        @input_fibers.push f
      end

      fiber = @input_fibers.last
      fiber.resume key
      ## now remove it if it's done
      @input_fibers.delete fiber unless fiber.alive?
    when :server_response
      results, fiber = args
      fiber.resume results
      ## this guy might (probably!) is on the input thread stack, having been
      ## triggered by an input. so let's remove him from there if he's done.
      @input_fibers.delete fiber unless fiber.alive?
    when :broadcast
      source, event, *args = args
      method = "handle_#{event}_update"
      @event_listeners.each do |l|
        next if l == source
        l.send(method, source, *args) if l.respond_to?(method)
      end
    when :redraw
      # nothing to do
    when :noop
      # nothing to do
    else
      raise "unknown event: #{event.inspect}"
    end
  end

  def spawn_fiber
    Fiber.new do
      begin
        yield
      rescue HeliotropeClient::Error => e
        message = "heliotrope server error: #{e.class.name}: #{e.message}"
        warn [message, e.backtrace[0..10].map { |l| "  "  + l }].flatten.join("\n")
        @context.screen.minibuf.flash "Error: #{e.message}. See log for details."
      end
    end
  end

  def shell_out cmd
    @context.screen.with_cursing_paused { system cmd }
  end

  def save_to_file fn, talk=true
    if File.exists? fn
      return unless @context.input.ask_yes_or_no "File \"#{fn}\" exists. Overwrite?"
    end

    begin
      File.open(fn, "w") { |f| yield f }
      @context.screen.minibuf.flash "Successfully wrote #{fn}." if talk
      true
    rescue SystemCallError, IOError => e
      m = "Error writing file: #{e.message}"
      info m
      @context.screen.minibuf.flash m
      false
    end
  end

  def pipe_to_process command
    Open3.popen3(command) do |input, output, error|
      err, data, * = IO.select [error], [input], nil

      unless err.empty?
        message = err.first.read
        if message =~ /^\s*$/
          warn "error running #{command} (but no error message)"
          @context.screen.minibuf.flash "Error running #{command}!"
        else
          warn "error running #{command}: #{message}"
          @context.screen.minibuf.flash "Error: #{message}"
        end
        return
      end

      data = data.first
      data.sync = false # buffer input

      yield data
      data.close # output will block unless input is closed

      ## BUG?: shows errors or output but not both....
      data, * = IO.select [output, error], nil, nil
      data = data.first

      if data.eof
        @context.screen.minibuf.flash "'#{command}' done!"
        nil
      else
        data.read
      end
    end
  rescue SystemCallError => e
    warn "error running #{command}: #{e.message}"
    @context.screen.minibuf.flash "Error: #{e.message}"
    nil
  end
end

end

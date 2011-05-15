require 'thread'
require 'open3'

## handles starting and stopping ncurses, taking input from the keyboard, the
## main event loop, and the broadcast/listen stuff
module Turnsole
class UI
  include LogsStuff

  def initialize context
    @context = context
    @cursing = false
    @input_thread = nil
    @q = Queue.new
    @quit = false
    @event_listeners = []
    Console.init_locale!
  end

  def log; @context.log end

  def start!
    @input_thread = start_input_thread!
  end

  def stop!
    @input_thread.kill if @input_thread
    @input_thread = nil
  end

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

  ## call this from the main thread
  def step
    @context.screen.draw!

    event, args = begin
      @q.pop
    rescue Interrupt
      [:interrupt, nil]
    end

    case event
    when :interrupt
      ## we might be interrupted in the middle of asking a question. if so,
      ## then just cancel it.
      @context.input.cancel_current_question!
      @context.screen.minibuf.deactivate_textfield!
      @context.input.asking do
        if @context.input.ask_yes_or_no "Die ungracefully now?"
          raise "O, I die, Horatio; The potent poison quite o'er-crows my spirit!"
        end
      end
    when :sigwinch
      @context.screen.resize_screen!
    when :keypress
      @context.screen.minibuf.clear_flash!
      key = args.first
      action = @context.input.handle key
    when :server_results
      results, callback = args
      callback.call(*results) if callback
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

  def shell_out command
    Ncurses.endwin
    stop!
    success = system command
    Ncurses.stdscr.keypad 1
    Ncurses.refresh
    Ncurses.curs_set 0
    start!
    success
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

private

  def start_input_thread!
    Thread.new do
      while true
        case(c = Ncurses.threadsafe_blocking_getch)
        when nil
          ## timeout -- don't think this actually happens
        when 410
          ## ncurses's way of telling us it's detected a refresh.  since we
          ## have our own sigwinch handler, we get this AFTER we've already processed
          ## the event, so we don't need to do anything.
        else
          enqueue :keypress, c
        end
      end
    end
  end
end

end

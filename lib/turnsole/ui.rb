require 'thread'

## handles starting and stopping ncurses, taking input from the keyboard, the
## main event loop, and the broadcast/listen stuff
module Turnsole
class UI
  def initialize context
    @context = context
    @cursing = false
    @input_thread = nil
    @q = Queue.new
    @quit = false
    @event_listeners = []
    Console.init_locale!
  end

  def start!
    @input_thread = start_input_thread!
  end

  def stop!
    @input_thread.kill if @input_thread
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
      callback.call(results) if callback
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
    success = system command
    Ncurses.stdscr.keypad 1
    Ncurses.refresh
    Ncurses.curs_set 0
    success
  end

private

  def start_input_thread!
    Thread.new do
      while true
        begin
          case(c = Ncurses.threadsafe_blocking_getch)
          ## see comments in http://all-thing.net/ruby-ncurses-and-thread-blocking
          ## for why these next two are possible outputs of threadsafe_blocking_getch
          when nil
            ## timeout -- don't think this actually happens
          when 410
            ## ncurses's way of telling us it's detected a refresh.  since we
            ## have our own sigwinch handler, we get this AFTER we've already processed
            ## the event, so we don't need to do anything.
          else
            enqueue :keypress, c
          end
        rescue Interrupt
          raise "we don't seem to see this here. am i wrong?"
          #enqueue :keypress, :interrupt
        end
      end
    end
  end
end

end

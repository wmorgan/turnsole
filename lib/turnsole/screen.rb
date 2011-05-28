require 'console/string' # String#display_width, String#display_slice

module Turnsole
class Screen
  include LogsStuff

  HookManager.register "status-bar-text", <<EOS
Sets the status bar. The default status bar contains the mode name, the buffer
title, and the mode status. Note that this will be called at least once per
keystroke, so excessive computation is discouraged.

Variables:
         num_inbox: number of messages in inbox
  num_inbox_unread: total number of messages marked as unread
         num_total: total number of messages in the index
          num_spam: total number of messages marked as spam
             title: title of the current buffer
              mode: current mode name (string)
            status: current mode status (string)
Return value: a string to be used as the status bar.
EOS

  HookManager.register "terminal-title-text", <<EOS
Sets the title of the current terminal, if applicable. Note that this will be
called at least once per keystroke, so excessive computation is discouraged.

Variables: the same as status-bar-text hook.
Return value: a string to be used as the terminal title.
EOS

  HookManager.register "extra-contact-addresses", <<EOS
A list of extra addresses to propose for tab completion, etc. when the
user is entering an email address. Can be plain email addresses or can
be full "User Name <email@domain.tld>" entries.

Variables: none
Return value: an array of email address strings.
EOS

  def initialize context
    @context = context

    @focus_buf = nil
    @bufs_by_title = {}
    @buffers = []

    @minibuf = Minibuf.new context

    @in_x = ENV["TERM"] =~ /(xterm|rxvt|screen)/

    @dirty = true
    @cursing = false

    Console.init_locale!
  end

  attr_reader :focus_buf, :minibuf, :buffers
  def log; @context.log end

  def mark_dirty!; @dirty = true end

  def start_cursing!
    return if @cursing
    debug "starting curses"
    Ncurses.initscr
    Ncurses.noecho
    Ncurses.cbreak
    Ncurses.stdscr.keypad 1
    Ncurses.use_default_colors
    Ncurses.curs_set 0
    Ncurses.start_color
    @dirty = true
    @cursing = true
  end

  def stop_cursing!
    return unless @cursing
    Ncurses.curs_set 1
    Ncurses.echo
    Ncurses.endwin
    @dirty = true
    @cursing = false
  end

  def start_input_thread!
    @input_thread ||= Thread.new do
      while true
        case(c = Ncurses.threadsafe_blocking_getch)
        when nil
          ## timeout -- don't think this actually happens
        when 410
          ## ncurses's way of telling us it's detected a refresh.  since
          ## we have our own sigwinch handler, we get this AFTER we've
          ## already processed the event, so we don't need to do
          ## anything.
        else
          @context.ui.enqueue :keypress, c
        end
      end
    end
  end

  def stop_input_thread!
    @input_thread.kill if @input_thread
    @input_thread = nil
  end

  def with_cursing_paused
    Ncurses.endwin
    stop_input_thread!
    ret = yield
    Ncurses.stdscr.keypad 1
    Ncurses.refresh
    Ncurses.curs_set 0
    start_input_thread!
    ret
  end

  def focus_on buf
    return unless @buffers.member? buf
    return if buf == @focus_buf
    @focus_buf.blur! if @focus_buf
    @focus_buf = buf
    @focus_buf.focus!
  end

  def raise_to_front buf
    @buffers.delete(buf) or return

    ## don't put something in front of another buffer marked force_to_top
    if @buffers.length > 0 && @buffers.last.force_to_top?
      @buffers.insert(-2, buf)
    else
      @buffers.push buf
    end

    focus_on @buffers.last
    @dirty = true
  end

  ## we reset force_to_top when rolling buffers. this is so that the
  ## human can actually still move buffers around, while still
  ## programmatically being able to pop stuff up in the middle of
  ## drawing a window without worrying about covering it up.
  ##
  ## if we ever start calling roll_buffers programmatically, we will
  ## have to change this. but it's not clear that we will ever actually
  ## do that.
  def roll_buffers
    bufs = rollable_buffers
    bufs.last.force_to_top = false
    raise_to_front bufs.first
  end

  def roll_buffers_backwards
    bufs = rollable_buffers
    return unless bufs.length > 1
    bufs.last.force_to_top = false
    raise_to_front bufs[bufs.length - 2]
  end

  def rollable_buffers
    @buffers.select { |b| !b.system? || @buffers.last == b }
  end

  def exists? title; @bufs_by_title.member? title end

  def resize_screen!
    ## this magic apparently makes Ncurses get the new size of the screen
    Ncurses.endwin
    Ncurses.stdscr.keypad 1
    Ncurses.curs_set 0
    Ncurses.refresh
    debug "new screen size is #{Ncurses.rows} x #{Ncurses.cols}"
    @dirty = true
    Ncurses.clear
  end

  def draw!
    ## layout:
    ##
    ## -- top --
    ## buffer at the top, N lines
    ## one line of buffer status next
    ## minibuf lines
    ## -- end --

    Ncurses.clear if @dirty

    buf_rows = Ncurses.rows - [@minibuf.height, 1].max - 1
    buf_cols = Ncurses.cols

    return unless buf_rows > 4 && buf_cols > 30 # don't draw this small

    buf = @buffers.last
    buf.set_size buf_rows, buf_cols # could've changed due to screen resize, or minibuf add/remove

    if @dirty
      buf.force_draw!
      @minibuf.force_draw!(buf_rows + 1)

      ## http://rtfm.etla.org/xterm/ctlseq.html (see Operating System Controls)
      if @in_x
        title = title_for buf
        print "\033]0;#{title}\07" if title
      end
    else
      buf.draw!
      @minibuf.draw!(buf_rows + 1)
    end

    ## always do these things
    draw_buf_statusline! buf, buf_rows
    @minibuf.position_cursor!

    @dirty = false
    Ncurses.refresh
  end

  def draw_buf_statusline! buf, y
    string = buf.status_bar_text || ""
    swidth = string.display_width
    if swidth > Ncurses.cols
      swidth = Ncurses.cols
      string = string.display_slice(0, swidth)
    end

    clearwidth = Ncurses.cols - swidth

    Ncurses.attrset @context.colors.color_for(:status)
    Ncurses.mvaddstr y, 0, string
    Ncurses.mvaddstr y, swidth, " " * clearwidth
  end

  ## if the named buffer already exists, pops it to the front without
  ## calling the block. otherwise, gets the mode from the block and
  ## creates a new buffer. returns two things: the buffer, and a boolean
  ## indicating whether it's a new buffer or not.
  def spawn_unless_exists title, opts={}
    if(buf = @bufs_by_title[title])
      raise_to_front buf unless opts[:hidden]
      [false, buf]
    else
      mode = yield
      buf = spawn title, mode, opts
      [true, buf]
    end
  end

  def spawn title, mode, opts={}
    raise ArgumentError, "title must be a string" unless title.is_a? String
    realtitle = title
    num = 2
    while @bufs_by_title.member? realtitle
      realtitle = "#{title} <#{num}>"
      num += 1
    end

    width = opts[:width] || Ncurses.cols
    height = opts[:height] || Ncurses.rows - [@minibuf.height, 1].max - 1

    ## since we are currently only doing multiple full-screen modes,
    ## use stdscr for each window. once we become more sophisticated,
    ## we may need to use a new Ncurses::WINDOW
    ##
    ## w = Ncurses::WINDOW.new(height, width, (opts[:top] || 0),
    ## (opts[:left] || 0))
    w = Ncurses.stdscr
    b = Buffer.new @context, w, mode, width, height, :title => realtitle, :force_to_top => opts[:force_to_top], :system => opts[:system]
    mode.buffer = @bufs_by_title[realtitle] = b

    @buffers.unshift b
    if opts[:hidden]
      focus_on b unless @focus_buf
    else
      raise_to_front b
    end
    b
  end

  ## requires the mode to have #done? and #value methods
  def spawn_modal title, mode, opts={}
    b = spawn title, mode, opts

    TODO IMPLEMENT ME

    draw_screen

    until mode.done?
      c = Ncurses.safe_nonblocking_getch
      next unless c # getch timeout
      break if c == Ncurses::KEY_CANCEL
      begin
        mode.handle_input c
      rescue InputSequenceAborted # do nothing
      end
      draw_screen
      erase_flash
    end

    kill_buffer b
    mode.value
  end

  def kill_all_buffers_safely
    until @buffers.empty?
      ## inbox mode always claims it's unkillable. we'll ignore it.
      return false unless @buffers.last.mode.is_a?(InboxMode) || @buffers.last.mode.killable?
      kill_buffer @buffers.last
    end
    true
  end

  def kill_buffer_safely buf
    return false unless buf.mode.killable?
    kill_buffer buf
    true
  end

  def kill_all_buffers
    kill_buffer @buffers.first until @buffers.empty?
  end

  def kill_buffer buf
    raise ArgumentError, "buffer not on stack: #{buf}: #{buf.title.inspect}" unless @buffers.member? buf

    buf.mode.cleanup!
    buf.mode.buffer = nil

    @buffers.delete buf
    @bufs_by_title.delete buf.title
    @focus_buf = nil if @focus_buf == buf
    if @buffers.empty?
      ## TODO: something intelligent here
      ## for now I will simply prohibit killing the inbox buffer.
    else
      raise_to_front @buffers.last
    end
  end

private

  def title_for buf
    "Turnsole #{::Turnsole::VERSION} :: #{buf.title}"
  end

  def get_status_and_title buf
    return [default_status_bar(buf), default_terminal_title(buf)]

    TODO implement this stuff
    opts = {
      :num_inbox => lambda { Index.num_results_for :label => :inbox },
      :num_inbox_unread => lambda { Index.num_results_for :labels => [:inbox, :unread] },
      :num_total => lambda { Index.size },
      :num_spam => lambda { Index.num_results_for :label => :spam },
      :title => buf.title,
      :mode => buf.mode.name,
      :status => buf.mode.status
    }

    statusbar_text = HookManager.run("status-bar-text", opts) || default_status_bar(buf)
    term_title_text = HookManager.run("terminal-title-text", opts) || default_terminal_title(buf)

    [statusbar_text, term_title_text]
  end
end
end

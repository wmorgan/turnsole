module Curses
  COLOR_DEFAULT = -1

  NUM_COLORS = `tput colors`.to_i
  MAX_PAIRS = `tput pairs`.to_i

  def self.add_color! name, value
    const_set "COLOR_#{name.to_s.upcase}", value
  end

  ## numeric colors
  Curses::NUM_COLORS.times { |x| add_color! x, x }

  if Curses::NUM_COLORS == 256
    ## xterm 6x6x6 color cube
    6.times { |x| 6.times { |y| 6.times { |z| add_color! "c#{x}#{y}#{z}", 16 + z + (6*y) + (36*x) } } }

    ## xterm 24-shade grayscale
    24.times { |x| add_color! "g#{x}", 16 + (6*6*6) + x }
  end
end

module Ncurses
  def rows
    lame, lamer = [], []
    stdscr.getmaxyx lame, lamer
    lame.first
  end

  def cols
    lame, lamer = [], []
    stdscr.getmaxyx lame, lamer
    lamer.first
  end

  def curx
    lame, lamer = [], []
    stdscr.getyx lame, lamer
    lamer.first
  end

  def threadsafe_blocking_getch
    ## workaround for buggy ncurses gems.
    ## see http://all-thing.net/ruby-ncurses-and-thread-blocking. some
    if IO.select([$stdin], nil, nil, 0.5)
      #if Redwood::BufferManager.shelled?
        # If we get input while we're shelled, we'll ignore it for the
        # moment and use Ncurses.sync to wait until the shell_out is done.
      #  Ncurses.sync { nil }
      #else
        Ncurses.getch
      #end
    end
  end

  ## pretends ctrl-c's are ctrl-g's
  def safe_threadsafe_blocking_getch
    nonblocking_getch
  rescue Interrupt
    KEY_CANCEL
  end

  module_function :rows, :cols, :curx, :threadsafe_blocking_getch, :safe_threadsafe_blocking_getch

  ## WHYYYYY must i redefine these?
  remove_const :KEY_ENTER
  remove_const :KEY_CANCEL

  KEY_ENTER = 10
  KEY_CANCEL = 7 # ctrl-g
  KEY_TAB = 9
end

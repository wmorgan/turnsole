module Turnsole

## a buffer holds onto an ncurses window and provides all the mechanics for
## writing to it that the underlying mode uses. modes should not use ncurses
## directly.
class Buffer
  attr_reader :mode, :x, :y, :width, :height, :title, :atime
  bool_reader :system, :dirty
  bool_accessor :force_to_top

  def initialize context, window, mode, width, height, opts={}
    @context = context
    @w = window
    @mode = mode
    @have_focus = false
    @title = opts[:title] || ""
    @force_to_top = opts[:force_to_top] || false
    @x, @y, @width, @height = 0, 0, width, height
    @system = opts[:system] || false
    @dirty = true
    @atime = Time.at 0
  end

  def mark_dirty!; @dirty = true end
  def content_height; @height end
  def content_width; @width end

  def set_size rows, cols
    return if cols == @width && rows == @height
    @width = cols
    @height = rows
    mode.set_size rows, cols
    @dirty = true
  end

  def status_bar_text
    " [#{mode.name}] #{title}   #{mode.status_bar_text}"
  end

  def draw!
    force_draw! if @dirty
  end

  def force_draw! # draw even if dirty
    @mode.draw!
    @dirty = false
  end

  def focus!
    @mode.focus!
    @atime = Time.now
  end

  def blur!; @mode.blur! end

  ## s nil means a blank line!
  def write y, x, string, opts={}
    return if x >= @width || y >= @height

    string ||= ""
    swidth = string.display_width
    if swidth > Ncurses.cols - x
      swidth = Ncurses.cols - x
      string = string.display_slice(0, swidth)
    end

    clearwidth = Ncurses.cols - x - swidth

    @w.attrset @context.colors.color_for(opts[:color] || :default, :highlight => opts[:highlight])
    @w.mvaddstr y, x, string
    @w.mvaddstr y, x + swidth, " " * clearwidth
  end

  def clear!
    @w.clear
  end
end
end

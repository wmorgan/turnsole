module Turnsole

## extends ScrollMode to have a line-based cursor, and to run arbitrary
## callbacks to load more lines when the user scrolls down.

class LineCursorMode < ScrollMode
  LOAD_MORE_CALLBACKS_DEFAULT_SIZE = 20

  register_keymap do |k|
    ## overwrite scrollmode binding on arrow keys for cursor movement
    ## but j and k still scroll!
    k.add :cursor_down, "Move cursor down one line", :down, 'j'
    k.add :cursor_up, "Move cursor up one line", :up, 'k'
    k.add :select, "Select this item", :enter
  end

  attr_reader :curpos

  def initialize context, opts={}
    @context = context
    @cursor_top = @curpos = opts.delete(:skip_top_rows) || 0
    @load_more_callbacks = []
    super
  end

  def load_more_if_necessary!
    if (topline + buffer.content_height > num_lines) ||         # there's empty space to fill
      @curpos >= num_lines - [buffer.content_height / 2, 1].max # the cursor is near the bottom

      num = [topline + buffer.content_height - num_lines, LOAD_MORE_CALLBACKS_DEFAULT_SIZE].max
      @load_more_callbacks.each { |cb| cb.call(num) }
    end
  end

  def status_bar_text
    l = num_lines
    @status = l > 0 ? "line #{@curpos + 1} of #{l}" : "empty"
  end

protected

  ## callbacks when the cursor is asked to go beyond the bottom
  def to_load_more &b
    @load_more_callbacks << b
  end

  def draw_line ln, opts={}
    if ln == @curpos
      super ln, :highlight => true, :debug => opts[:debug]
    else
      super
    end
  end

  def ensure_mode_validity!
    super
    c = @curpos.clamp topline, botline
    c = @cursor_top if c < @cursor_top
    buffer.mark_dirty! unless c == @curpos
    @curpos = c
  end

  def set_cursor_pos p
    return if @curpos == p
    @curpos = p.clamp @cursor_top, num_lines
    buffer.mark_dirty!
  end

  ## override search behavior to be cursor-based. this is a stupid
  ## implementation and should be made better. TODO: improve.
  def search_goto_line line
    page_down while line >= botline
    page_up while line < topline
    set_cursor_pos line
  end

  def search_start_line; @curpos end

  def line_down # overrides ScrollMode#line_down
    super
    load_more_if_necessary!
    set_cursor_pos topline if @curpos < topline
  end

  def line_up # overwrite scrollmode
    super
    set_cursor_pos botline if @curpos > botline
  end

  def cursor_down
    load_more_if_necessary!
    return false unless @curpos < num_lines - 1

    if @curpos >= botline
      page_down
      set_cursor_pos topline
    else
      @curpos += 1
      unless buffer.dirty?
        draw_line @curpos - 1
        draw_line @curpos
      end
    end
    true
  end

  def cursor_up
    return false unless @curpos > @cursor_top
    if @curpos == topline
      old_topline = topline
      page_up
      set_cursor_pos [old_topline - 1, topline].max
    else
      @curpos -= 1
      unless buffer.dirty?
        draw_line @curpos + 1
        draw_line @curpos
      end
    end
    true
  end

  def page_up # overwrite
    if topline <= @cursor_top
      set_cursor_pos @cursor_top
    else
      relpos = @curpos - topline
      super
      set_cursor_pos topline + relpos
    end
  end

  ## more complicated than one might think. three behaviors.
  def page_down
    ## if we're on the last page, and it's not a full page, just move
    ## the cursor down to the bottom.
    if topline > num_lines - buffer.content_height
      set_cursor_pos(num_lines - 1)

    ## if we're on the last page, and it's a full page, shift the page down
    elsif topline == num_lines - buffer.content_height
      super

    ## otherwise, just move down
    else
      relpos = @curpos - topline
      super
      set_cursor_pos [topline + relpos, num_lines - 1].min
    end

    load_more_if_necessary!
  end

  def jump_to_start
    super
    set_cursor_pos @cursor_top
  end

  def jump_to_end
    super if topline < (num_lines - buffer.content_height)
    set_cursor_pos(num_lines - 1)
  end
end

end

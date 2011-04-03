require 'thread'

module Turnsole

## a little horizontal region that lets you say and flash messages, and lets
## you ask a question.
##
## something that is said will be displayed until it is explicitly cleared.
## something that is flashed will be displayed until the next keystroke
## happens.
##
## saying and flashing is threadsafe; question-asking is not.
class Minibuf
  include LogsStuff

  class StateError < StandardError; end

  attr_reader :textfield
  def initialize context
    @context = context

    ## the say_stack may have nils in it because we return the index as the id,
    ## and we don't want to disrupt other ids.
    @say_stack = []
    @flash_stack = []
    @dirty = true

    ## protects @say_stack, @flash_stack and @dirty
    @mutex = Mutex.new

    ## question stuff

    @textfields = {} # keep them around for context-aware history
    @textfield = nil # but only one active one is allowed at a time

    ## a short question y/n question. just a string and not a whole textfield.
    @shortq = nil
  end

  def log; @context.log end

  def height
    @mutex.synchronize { @say_stack.compact.size + @flash_stack.size + (@textfield ? 1 : 0) + (@shortq ? 1 : 0) }
  end

  def draw! start_row
    return unless @mutex.synchronize { @dirty }
    force_draw! start_row
  end

  def mark_dirty!; @mutex.synchronize { @dirty = true } end

  def force_draw! start_row
    Ncurses.attrset @context.colors.color_for(:default)

    width = Ncurses.cols
    things = @mutex.synchronize { @say_stack.compact + @flash_stack + [@shortq].compact }
    things << "" if things.empty? # always have one blank line at the bottom
    things.each_with_index do |string, i|
      Ncurses.mvaddstr start_row + i, 0, string + (" " * [width - string.display_width, 0].max)
    end

    if @shortq
      @curpos_y = start_row + things.size - 1
      @curpos_x = @shortq.display_width + 1
    elsif @textfield
      @textfield.draw!
    end

    mark_dirty!
  end

  def position_cursor!
    if @shortq
      Ncurses.curs_set 1
      Ncurses.move @curpos_y, @curpos_x
    elsif @textfield
      Ncurses.curs_set 1
      @textfield.position_cursor!
    else
      Ncurses.curs_set 0
    end
  end

  def say what, id=nil
    @mutex.synchronize do
      @dirty = true
      id ||= @say_stack.size
      @say_stack[id] = what
      id
    end
  end

  def flash what
    @mutex.synchronize do
      @flash_stack << what
      @dirty = true
    end
  end

  def clear_flash!
    @mutex.synchronize do
      return if @flash_stack.empty?
      @flash_stack = []
      @dirty = true
    end
  end

  def clear id
    @mutex.synchronize do
      @say_stack[id] = nil
      ## clear all nils at the end of the stack
      id.downto(0) do |i|
        break if @say_stack[i]
        @say_stack.delete_at i
      end
      @dirty = true
    end
  end

  def set_shortq q
    raise StateError, "already have a textfield active" if @textfield
    @shortq = q
    mark_dirty!
  end

  def clear_shortq!
    @shortq = nil
    mark_dirty!
  end

  def activate_textfield! domain, question, default, completion_block
    raise StateError, "already have a short question active" if @shortq

    @textfield = (@textfields[domain] ||= TextField.new(@context))
    @textfield.activate! Ncurses.stdscr, Ncurses.rows - 1, 0, Ncurses.cols, question, default, &completion_block
    @context.screen.mark_dirty! # for some reason activation blanks the whole fucking screen
    mark_dirty!
    @textfield
  end

  def deactivate_textfield!
    return unless @textfield
    @textfield.deactivate!
    @textfield = nil
    mark_dirty!
  end
end
end

module Turnsole

## a fully-functional text field supporting completions, expansions,
## history--everything!
##
## i tried to use the ncurses forms stuff, but it's insane. you can
## see the result in sup---it's MORE code than this reimplementation
## using strings.
##
## completion comments: completion is done emacs-style, and mostly
## depends on outside support, as we merely signal the existence of a
## new set of completions to show (#new_completions?)  or that the
## current list of completions should be rolled if they're too large
## to fill the screen (#roll_completions?).
##
## in turnsole, completion support is implemented through Screen#ask
## and CompletionMode.
class TextField
  def initialize context
    @context = context

    @history_index = nil
    @history = []
  end

  attr_reader :completions

  def answer; @answer.strip if @answer end

  def activate! window, y, x, width, question, default=nil, &block
    @w, @y, @x, @width = window, y, x, width
    @question = question
    @answer = default || ""

    ## important! curpos is the position in characters, not in bytes or display
    ## characters. @answer.length is the rightmost position.
    @curpos = @answer.length

    ## a horrible thing we use to clean up after intermediate states where we
    ## have partial sequences of a multibyte character
    @curpos_excess = 0

    @completion_block = block
    @completion_state = nil
    @completions = []
  end

  def draw!
    @w.attrset @context.colors.color_for(:default)
    @w.mvaddstr @y, @x, (@question + @answer)
  end

  def position_cursor!
    begin
      Ncurses.move @y, @x + (@question + @answer[0 ... @curpos]).display_width
    rescue ArgumentError
      ## we see this if we have a partial multibyte character in the answer.
      ## we'll just ignore the issue and not move the cursor, assuming that
      ## successive bytes are coming soon!
    end
  end

  def deactivate!
  end

  def new_completions?; @completion_state == :new end
  def roll_completions?; @completion_state == :roll end
  def clear_completions?; @completion_state == :clear end

  def handle_input c
    ## first, some short-circuit exit paths
    case c
    when Ncurses::KEY_ENTER # submit!
      @history.push @answer unless @answer =~ /^\s*$/
      @history_index = @history.size
      return false
    when Ncurses::KEY_CANCEL # cancel
      @answer = nil
      return false
    when Ncurses::KEY_TAB # completion
      return true unless @completion_block

      @answer.strip!

      if @completions.empty?
        c = @completion_block.call @answer
        if c.size > 0
          @answer = c.map { |full, short| full }.shared_prefix(true)
          if c.size == 1 # exact match!
            @answer += " "
            @completion_state = :clear
          end
          @curpos = @answer.length # to the end
          position_cursor!
        end
        if c.size > 1
          @completions = c
          @completion_state = :new
        end
      else # roll!
        @completion_state = :roll
      end

      return true
    end

    ## done with short-ciruits

    @completions = []
    @completion_state = nil

    case c
    when Ncurses::KEY_LEFT, ?\C-b.ord; @curpos = [0, @curpos - 1].max
    when Ncurses::KEY_RIGHT, ?\C-f.ord; @curpos = [@curpos + 1, @answer.length].min
    when Ncurses::KEY_DC, ?\C-d.ord; @answer = @answer[0 ... @curpos] + (@answer[(@curpos + 1) .. -1] || "")
    when Ncurses::KEY_BACKSPACE, 127
      if @curpos > 0
        @answer = @answer[0 ... (@curpos - 1)] + (@answer[@curpos .. -1] || "")
        @curpos -= 1
      end
    when ?\C-a.ord, Ncurses::KEY_HOME; @curpos = 0
    when ?\C-e.ord, Ncurses::KEY_END; @curpos = @answer.length
    when ?\C-k.ord; @answer = @answer[0 ... @curpos]
    when ?\C-u.ord
      @answer = (@answer[@curpos .. -1] || "")
      @curpos = 0
    when ?\C-w.ord
      space_pos = @answer.rindex(/\s/, @curpos) || 0
      @answer = @answer[0 ... space_pos] + (@answer[@curpos .. -1] || "")
      @curpos = space_pos
      #Ncurses::Form.form_driver @form, Ncurses::Form::REQ_PREV_CHAR
      #Ncurses::Form.form_driver @form, Ncurses::Form::REQ_DEL_WORD
    when Ncurses::KEY_UP, Ncurses::KEY_DOWN
      unless @history_index.nil? || @history.empty?
        #debug "history before #{@history.inspect}"
        @history[@history_index] = @answer
        @history_index = @history_index + (c == Ncurses::KEY_UP ? -1 : 1)
        @history_index = 0 if @history_index < 0
        @history_index = @history.size if @history_index > @history.size
        @answer = @history[@history_index] || ''
        #debug "history after #{@history.inspect}"
      end
    else
      ch = c.chr.safely_mark_encoding! @context.encoding
      @answer = @answer[0 ... @curpos] + ch + (@answer[@curpos .. -1] || "")
      @answer.safely_mark_encoding! @context.encoding
      @curpos += 1

      ## here is a terrible hack, due to the fact that curses gives us
      ## multibyte characters one character at a time.
      ##
      ## if we can't calculate the display_width of the
      ## answer, then we probably have just added a partial character to the
      ## string. (we could do this more elegantly in ruby 1.9, but this should
      ## be 1.8-compatible.)
      ##
      ## in this case, we will advance curpos anyways, so that later bytes of
      ## the same character end up in the right place, but we will record how
      ## much excess we have. if the string has a display_width, then we assume
      ## we have the full character, and we remove any excess.

      begin
        @answer.display_width
        @curpos -= @curpos_excess
        @curpos_excess = 0
      rescue ArgumentError
        @curpos_excess += 1
      end
    end

    true
  end
end
end

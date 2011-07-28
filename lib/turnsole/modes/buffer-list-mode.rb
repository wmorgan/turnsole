module Turnsole

class BufferListMode < LineCursorMode
  register_keymap do |k|
    k.add :jump_to_buffer, "Jump to selected buffer", :enter
    k.add :reload!, "Reload buffer list", "@"
    k.add :kill_selected_buffer, "Kill selected buffer", "X"
  end

  def initialize context
    @context = context
    regen_text!
    super
  end

  def num_lines; @text.length end
  def [] i; @text[i] end

  def focus!
    reload! # buffers may have been killed or created since last view
    set_cursor_pos 0
  end

protected

  def reload!
    regen_text!
    buffer.mark_dirty!
  end

  def regen_text!
    @bufs = @context.screen.buffers.reject { |buf| buf.mode == self }.sort_by { |buf| buf.atime }.reverse
    width = @bufs.max_of { |buf| buf.mode.name.display_width }
    @text = @bufs.map do |buf|
      base_color = buf.system? ? :system_buf : :regular_buf
      [[base_color, sprintf("%#{width}s ", buf.mode.name)],
       [:modified_buffer, (buf.mode.unsaved? ? '*' : ' ')],
       [base_color, " " + buf.title]]
    end
  end

  def jump_to_buffer
    @context.screen.raise_to_front @bufs[curpos]
  end

  def kill_selected_buffer
    reload! if @context.screen.kill_buffer_safely(@bufs[curpos])
  end
end

end

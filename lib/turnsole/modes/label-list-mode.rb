module Turnsole

class LabelListMode < LineCursorMode
  register_keymap do |k|
    k.add :select_label, "Search by label", :enter
    k.add :reload!, "Discard label list and reload", '@'
    k.add :jump_to_next_new, "Jump to next new thread", :tab
    k.add :toggle_show_unread_only, "Toggle between showing all labels and those with unread mail", 'u'
  end

  def initialize context
    super

    @context = context
    @labels = []
    @counts = {}
    @unread_counts = {}
    @text = ["Loading..."]
    @unread_only = false

    @context.ui.add_event_listener self
  end

  def cleanup!
    @context.ui.remove_event_listener self
  end

  def reload!
    buffer.mark_dirty!
    load!
  end

  def load!
    @context.labels.load!
    @context.labels.all_labels.each do |l|
      @counts[l] = @context.client.count "~#{l}"
      regen_text!
      buffer.mark_dirty! if buffer

      @unread_counts[l] = @context.client.count "~#{l} ~unread"
      regen_text!
      buffer.mark_dirty! if buffer
    end
    regen_text!
  end

  def num_lines; @text.length end
  def [] i; @text[i] end

  def jump_to_next_new
    n = ((curpos + 1) ... num_lines).find { |i| @unread_counts[@labels[i]] && @unread_counts[@labels[i]] > 0 } ||
      (0 ... curpos).find { |i| @unread_counts[@labels[i]] && @unread_counts[@labels[i]] > 0 }

    if n
      ## jump there if necessary
      jump_to_line n unless n >= topline && n <= botline
      set_cursor_pos n
    else
      @context.screen.minibuf.flash "No labels messages with unread messages."
    end
  end

protected

  def toggle_show_unread_only
    @unread_only = !@unread_only
    regen_text!
    buffer.mark_dirty!
  end

  def regen_text!
    @labels = @context.labels.all_labels.sort
    @labels.delete_if { |l| @unread_counts[l].nil? || @unread_counts[l] == 0 } if @unread_only

    width = @labels.max_of { |l| l.display_width }

    @text = if @labels.empty?
      @context.screen.minibuf.flash "No labels with unread messages!" if @labels.empty? && @unread_only
      []
    else
      @labels.map do |label|
        total = @counts[label]
        total_s = total ? sprintf("%5d", total) : sprintf("%5s", "?")

        unread = @unread_counts[label]
        unread_s = unread ? sprintf("%5d", unread) : sprintf("%5s", "?")

        what = total == 1 ? " message" : "messages"

        [[(unread.nil? || unread == 0 ? :labellist_old : :labellist_new),
          sprintf("%#{width + 1}s #{total_s} #{what}, #{unread_s} unread", label)]]
      end
    end
  end

  def select_label
    label, count, num_unread = @labels[curpos]
    return unless label
    SearchResultsMode.spawn_from_query @context, "~#{label}"
  end
end

end

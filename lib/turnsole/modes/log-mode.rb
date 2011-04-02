module Turnsole

## a variant of text mode that allows the user to automatically follow text,
## and respawns when << is called if necessary.

class LogMode < TextMode
  register_keymap do |k|
    k.add :toggle_follow, "Toggle follow mode", 'f'
  end

  ## devious little mode that will re-spawn itself whenever it
  ## receives a message
  def initialize context
    @context = context
    @follow = true
    @on_kill = []
    super()
  end

  ## register callbacks for when the buffer is killed
  def on_kill &b; @on_kill << b end

  def toggle_follow
    @follow = !@follow
    if @follow
      jump_to_line(num_lines - buffer.content_height + 1) # leave an empty line at bottom
    end
    buffer.mark_dirty
  end

  def << s
    if buffer.nil?
      @context.screen.spawn "turnsole log", self, :hidden => true
    end

    s.split("\n").each { |l| super(l + "\n") } # insane. different << semantics.

    if @follow
      follow_top = num_lines - buffer.content_height + 1
      jump_to_line follow_top if topline < follow_top
    end
  end

  def status_bar_text
    super + " (follow: #@follow)"
  end

  def cleanup!
    @on_kill.each { |cb| cb.call self }
    @text = ""
    super
  end
end

end

module Turnsole

class TextMode < ScrollMode
  attr_reader :text
  register_keymap do |k|
    k.add :save_to_disk, "Save to disk", 's'
    k.add :pipe, "Pipe to process", '|'
  end

  def initialize context, text, default_filename=nil
    @context = context
    @text = text
    @default_filename = default_filename
    update_lines!
    super(context)
  end

  def save_to_disk
    fn = @context.input.ask_for_filename :filename, "Save to file: ", @default_filename
    @context.ui.save_to_file(fn) { |f| f.puts text } if fn
  end

  def pipe
    command = @context.input.ask(:shell, "pipe command: ")
    return if command.nil? || command.empty?

    output = @context.ui.pipe_to_process(command) do |stream|
      @text.each_line { |l| stream.puts l }
    end

    if output
      @context.screen.spawn "Output of '#{command}'", TextMode.new(@context, output.force_to_ascii)
    end
  end

  def text= t
    @text = t
    update_lines!
    buffer.mark_dirty!
  end

  def << line
    @lines = [0] if @text.empty?
    @text << line
    @lines << @text.length
    buffer.mark_dirty!
  end

  def num_lines; @lines.length - 1 end

  def [] i
    return nil unless i < @lines.length
    @text[@lines[i] ... (i + 1 < @lines.length ? @lines[i + 1] - 1 : @text.length)].normalize_whitespace
#    (@lines[i] ... (i + 1 < @lines.length ? @lines[i + 1] - 1 : @text.length)).inspect
  end

private

  def update_lines!
    pos = @text.find_all_positions("\n")
    pos.push @text.length unless pos.last == @text.length - 1
    @lines = [0] + pos.map { |x| x + 1 }
  end
end

end

module Turnsole

class CompletionMode < ScrollMode
  INTERSTITIAL = "  "

  def initialize context, list, opts={}
    @list = list
    @header = opts[:header] or raise ArgumentError, "need :header"
    @match = opts[:match] or raise ArgumentError, "need :match"
    @lines = nil
    super context, :slip_rows => 1, :twiddles => false
  end

  def num_lines
    update_lines unless @lines
    @lines.length
  end

  def [] i
    update_lines unless @lines
    @lines[i]
  end

  def roll!; at_bottom? ? jump_to_start! : page_down end

private

  def update_lines
    width = buffer.content_width
    max_length = @list.max_of { |s| s.length } || 0
    max_width = @list.max_of { |s| s.display_width } || 0
    num_per = [1, buffer.content_width / (max_width + INTERSTITIAL.display_width)].max

    completions = @list.map do |s|
      idx = s.downcase.index @match.downcase
      if idx
        prefix = s[0 ... idx]
        suffix = s[(idx + @match.length) .. -1]

         [[:default, sprintf("%#{max_length - suffix.length - @match.length}s", prefix)],
          [:completion_character, s[idx ... (idx + @match.length)]],
          [:default, suffix + INTERSTITIAL]]
      else
         [[:default, sprintf("%#{max_length}s#{INTERSTITIAL}", s)]]
      end
    end

    @lines = completions.each_slice(num_per).map { |x| x.flatten(1) }
  end
end

end

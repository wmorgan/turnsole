require 'console/string'
class String
  alias_method :console_display_width, :display_width

  def display_width
    console_display_width rescue length
  end
end

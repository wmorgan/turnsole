require 'open3'

module Turnsole

class Mode
  attr_accessor :buffer
  @@keymaps = {}

  def self.register_keymap keymap=nil, &b
    keymap ||= Keymap.new(&b)
    @@keymaps[self] = keymap
  end

  def self.keymap; @@keymaps[self] || register_keymap end
  def self.keymaps; @@keymaps end

  def initialize
    @buffer = nil
  end

  def self.make_name s; s.gsub(/.*::/, "").camel_to_hyphy end
  def name; Mode.make_name self.class.name end

  def killable?; true; end
  def unsaved?; false end

  def draw!; end
  def focus!; end
  def blur!; end
  def cleanup!; end

  def cancel_search!; end
  def in_search?; false end

  def status; ""; end
  def set_size rows, cols; end

  def help_text
    used_keys = {}
    ancestors.map do |klass|
      km = @@keymaps[klass] or next
      title = "Keybindings from #{Mode.make_name klass.name}"
      s = <<EOS
#{title}
#{'-' * title.display_width}

#{km.help_text used_keys}
EOS
      begin
        used_keys.merge! km.keysyms.to_boolean_h
      rescue ArgumentError
        raise km.keysyms.inspect
      end
      s
    end.compact.join "\n"
  end
end

end

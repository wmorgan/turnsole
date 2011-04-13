require 'benchmark'
require 'iconv'
require 'set'

class Set
  def to_json; to_a.to_json end # otherwise you get nonsense
end

## time for some monkeypatching!
class Symbol
  ## backport ruby 1.8.7 &:magic
  unless method_defined? :to_proc
    def to_proc; proc { |obj, *args| obj.send(self, *args) } end
  end
end

class Pathname
  def human_size
    begin
      size.to_human_size
    rescue SystemCallError
      "?"
    end
  end

  def human_time
    begin
      ctime.strftime("%Y-%m-%d %H:%M")
    rescue SystemCallError
      "?"
    end
  end
end

## more monkeypatching!
module RMail
  class EncodingUnsupportedError < StandardError; end

  class Message
    def self.make_file_attachment fn
      bfn = File.basename fn
      t = MIME::Types.type_for(bfn).first || MIME::Types.type_for("exe").first
      make_attachment IO.read(fn), t.content_type, t.encoding, bfn.to_s
    end

    def self.make_attachment payload, mime_type, encoding, filename
      a = Message.new
      a.header.add "Content-Disposition", "attachment; filename=#{filename.inspect}"
      a.header.add "Content-Type", "#{mime_type}; name=#{filename.inspect}"
      a.header.add "Content-Transfer-Encoding", encoding if encoding
      a.body = case encoding
      when "base64"
        [payload].pack "m"
      when "quoted-printable"
        [payload].pack "M"
      when "7bit", "8bit", nil
        payload
      else
        raise EncodingUnsupportedError, encoding.inspect
      end
      a
    end
  end

  class Serialize
    ## Don't add MIME-Version headers on serialization. Sup sometimes wants to
    ## serialize message parts where these headers are not needed and messing
    ## with the message on serialization breaks gpg signatures. The commented
    ## section shows the original RMail code.
    def calculate_boundaries(message)
      calculate_boundaries_low(message, [])
      # unless message.header['MIME-Version']
      #   message.header['MIME-Version'] = "1.0"
      # end
    end
  end
end

class Module
  def bool_reader *args
    args.each { |sym| class_eval %{ def #{sym}?; @#{sym}; end } }
  end
  def bool_writer *args; attr_writer(*args); end
  def bool_accessor *args
    bool_reader(*args)
    bool_writer(*args)
  end
end

class Object
  def ancestors
    ret = []
    klass = self.class

    until klass == Object
      ret << klass
      klass = klass.superclass
    end
    ret
  end

  unless method_defined? :tap
    def tap; yield self; self end
  end

  def benchmark s, &b
    ret = nil
    times = Benchmark.measure { ret = b.call }
    debug "benchmark #{s}: #{times}"
    ret
  end
end

class String
  def has_prefix? prefix
    self[0, prefix.length].downcase == prefix.downcase
  end

  def camel_to_hyphy
    self.gsub(/([a-z])([A-Z0-9])/, '\1-\2').downcase
  end

  def find_all_positions x
    ret = []
    start = 0
    while start < length
      pos = index x, start
      break if pos.nil?
      ret << pos
      start = pos + 1
    end
    ret
  end

  ## a very complicated regex found on teh internets to split on
  ## commas, unless they occurr within double quotes.
  def split_on_commas
    normalize_whitespace().split(/,\s*(?=(?:[^"]*"[^"]*")*(?![^"]*"))/)
  end

  ## ok, here we do it the hard way. got to have a remainder for purposes of
  ## tab-completing full email addresses
  def split_on_commas_with_remainder
    ret = []
    state = :outstring
    pos = 0
    region_start = 0
    while pos <= length
      newpos = case state
        when :escaped_instring, :escaped_outstring then pos
        else index(/[,"\\]/, pos)
      end

      if newpos
        char = self[newpos]
      else
        char = nil
        newpos = length
      end

      case char
      when ?"
        state = case state
          when :outstring then :instring
          when :instring then :outstring
          when :escaped_instring then :instring
          when :escaped_outstring then :outstring
        end
      when ?,, nil
        state = case state
          when :outstring, :escaped_outstring then
            ret << self[region_start ... newpos].gsub(/^\s+|\s+$/, "")
            region_start = newpos + 1
            :outstring
          when :instring then :instring
          when :escaped_instring then :instring
        end
      when ?\\
        state = case state
          when :instring then :escaped_instring
          when :outstring then :escaped_outstring
          when :escaped_instring then :instring
          when :escaped_outstring then :outstring
        end
      end
      pos = newpos + 1
    end

    remainder = case state
      when :instring
        self[region_start .. -1].gsub(/^\s+/, "")
      else
        nil
      end

    [ret, remainder]
  end

  def wrap len
    ret = []
    s = self
    while s.length > len
      cut = s[0 ... len].rindex(/\s/)
      if cut
        ret << s[0 ... cut]
        s = s[(cut + 1) .. -1]
      else
        ret << s[0 ... len]
        s = s[len .. -1]
      end
    end
    ret << s
  end

  def normalize_whitespace
    gsub(/\t/, "    ").gsub(/\r/, "")
  end

  def ord; self[0] end unless method_defined? :ord

  def in_ruby19_hell?
    @in_ruby19_hell = "".respond_to?(:encoding) if @in_ruby19_hell.nil?
    @in_ruby19_hell
  end

  def safely_mark_encoding! encoding
    if in_ruby19_hell?
      s = frozen? ? dup : self
      s.force_encoding encoding
    else
      self
    end
  end

  def safely_mark_ascii
    if in_ruby19_hell?
      s = frozen? ? dup : self
      s.force_encoding Encoding::ASCII
    else
      self
    end
  end

  def safely_mark_binary
    if in_ruby19_hell?
      s = frozen? ? dup : self
      s.force_encoding Encoding::BINARY
    else
      self
    end
  end

  def force_to_ascii
    out = ""
    each_byte do |b|
      if (b & 128) != 0
        out << "\\x#{b.to_s 16}"
      else
        out << b.chr
      end
    end
    safely_mark_ascii
  end

  def ascii_only?
    size.times { |i| return false if self[i] & 128 != 0 }
    return true
  end unless method_defined? :ascii_only?
end

class Numeric
  def clamp min, max
    if self < min; min
    elsif self > max; max
    else self
    end
  end

  def to_human_size
    if self < 1024
      to_s + "b"
    elsif self < (1024 * 1024)
      (self / 1024).to_s + "k"
    elsif self < (1024 * 1024 * 1024)
      (self / 1024 / 1024).to_s + "m"
    else
      (self / 1024 / 1024 / 1024).to_s + "g"
    end
  end
end

class Fixnum
  def to_character
    if self < 128 && self >= 0
      chr
    else
      "<#{self}>"
    end
  end

  #unless method_defined?(:ord)
    #def ord
      #self
    #end
  #end

  ## hacking the english language
  def pluralize s
    to_s + " " + if self == 1
      s
    else
      if s =~ /(.*)y$/
        $1 + "ies"
      else
        s + "s"
      end
    end
  end
end

module Enumerable
  def uniq_by
    s = Set.new
    select do |x|
      v = yield x
      unless s.member?(v)
        s << v
        true
      end
    end
  end

  def map_with_index
    ret = []
    each_with_index { |x, i| ret << yield(x, i) }
    ret
  end

  def sum; inject(0) { |x, y| x + y }; end

  # like find, except returns the value of the block rather than the
  # element itself.
  def argfind
    ret = nil
    find { |e| ret ||= yield(e) }
    ret
  end

  def find_with_index
    each_with_index { |x, i| return [x, i] if yield(x) }
    nil
  end

  ## returns the maximum shared prefix of an array of strings
  ## optinally excluding a prefix
  def shared_prefix caseless=false, exclude=""
    return "" if empty?
    prefix = ""
    (0 ... first.length).each do |i|
      c = (caseless ? first.downcase : first)[i]
      break unless all? { |s| (caseless ? s.downcase : s)[i] == c }
      next if exclude[i] == c
      prefix += first[i].chr
    end
    prefix
  end

  def max_of
    map { |e| yield e }.max
  end
end

#unless Object.const_defined? :Enumerator
  #Enumerator = Enumerable::Enumerator
#end

class Array
  def to_h; Hash[*flatten]; end
  #def rest; self[1..-1]; end

  def to_boolean_h; Hash[*map { |x| [x, true] }.flatten]; end

  #def last= e; self[-1] = e end
  #def nonempty?; !empty? end
end

class Hash
  def - o # subtract keys
    keyset = Set.new(o)
    reject { |k, v| keyset.include?(k) }
  end
end

class Time
  def to_indexable_s
    sprintf "%012d", self
  end

  def nearest_hour
    if min < 30
      self
    else
      self + (60 - min) * 60
    end
  end

  def midnight # within a second
    self - (hour * 60 * 60) - (min * 60) - sec
  end

  def is_the_same_day? other
    (midnight - other.midnight).abs < 1
  end

  def is_the_day_before? other
    other.midnight - midnight <=  24 * 60 * 60 + 1
  end

  def to_nice_distance_s from=Time.now
    later_than = (self < from)
    diff = (self.to_i - from.to_i).abs.to_f
    text =
      [ ["second", 60],
        ["minute", 60],
        ["hour", 24],
        ["day", 7],
        ["week", 4.345], # heh heh
        ["month", 12],
        ["year", nil],
      ].argfind do |unit, size|
        if diff.round <= 1
          "one #{unit}"
        elsif size.nil? || diff.round < size
          "#{diff.round} #{unit}s"
        else
          diff /= size.to_f
          false
        end
      end
    if later_than
      text + " ago"
    else
      "in " + text
    end
  end

  TO_NICE_S_MAX_LEN = 9 # e.g. "Yest.10am"
  def to_nice_s from=Time.now
    if year != from.year
      strftime "%b %Y"
    elsif month != from.month
      strftime "%b %e"
    else
      if is_the_same_day? from
        strftime("%l:%M%p").downcase # emulate %P (missing on ruby 1.8 darwin)
      elsif is_the_day_before? from
        "Yest."  + nearest_hour.strftime("%l%p").downcase # emulate %P
      else
        strftime "%b %e"
      end
    end
  end
end

class Iconv
  # TODO make this less painful, e.g. adapt heliotrope version
  def self.easy_decode target, orig_charset, text
    text = text.safely_mark_binary
    charset = case orig_charset
      when /UTF[-_ ]?8/i then "utf-8"
      when /(iso[-_ ])?latin[-_ ]?1$/i then "ISO-8859-1"
      when /iso[-_ ]?8859[-_ ]?15/i then 'ISO-8859-15'
      when /unicode[-_ ]1[-_ ]1[-_ ]utf[-_]7/i then "utf-7"
      when /^euc$/i then 'EUC-JP' # XXX try them all?
      when /^(x-unknown|unknown[-_ ]?8bit|ascii[-_ ]?7[-_ ]?bit)$/i then 'ASCII'
      else orig_charset
    end

    begin
      s = Iconv.iconv(target + "//IGNORE", charset, text + " ").join[0 .. -2]
      s.check
      s
    rescue Errno::EINVAL, Iconv::InvalidEncoding, Iconv::InvalidCharacter, Iconv::IllegalSequence, String::CheckError
      debug "couldn't transcode text from #{orig_charset} (#{charset}) to #{target} (#{text[0 ... 20].inspect}...): got #{$!.class} (#{$!.message})"
      text.force_to_ascii
    end
  end
end

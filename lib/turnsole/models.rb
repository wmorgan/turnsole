require 'set'

module Turnsole

## some simple struct-like objects (POROs?) for wrapping the json return values
## from Heliotrope.
class Person
  def initialize name, email, handle
    @name = name
    @email = email
    @handle = handle
  end

  def hash; @email.hash end
  def eql? o; o.email == @email end

  attr_reader :name, :email, :handle

  def shortname
    case @name
    when /\S+, (\S+)/; $1
    when /(\S+) \S+/; $1
    when nil; @handle
    else @name
    end
  end

  def longname
    if @name && @email
      "#@name <#@email>"
    else
      @email
    end
  end

  def mediumname; @name || @handle || @email end

  def email_ready_address
    if @name && @email
      if @name =~ /[",@]/
        "#{@name.inspect} <#{@email}>" # escape quotes
      else
        "#{@name} <#{@email}>"
      end
    else
      @email
    end
  end

  ## copied and pasted from heliotrope. oh yeahhhhhh
  ##
  ## takes a string, returns a [name, email, emailnodomain] combo
  ## e.g. for William Morgan <wmorgan@example.com>, returns
  ##  ["William Morgan", wmorgan@example.com, wmorgan]
  def self.from_string string # ripped from sup
    return if string.nil? || string.empty?

    name, email, handle = case string
    when /^(["'])(.*?[^\\])\1\s*<((\S+?)@\S+?)>/
      a, b, c = $2, $3, $4
      a = a.gsub(/\\(["'])/, '\1')
      [a, b, c]
    when /(.+?)\s*<((\S+?)@\S+?)>/
      [$1, $2, $3]
    when /<((\S+?)@\S+?)>/
      [nil, $1, $2]
    when /((\S+?)@\S+)/
      [nil, $1, $2]
    else
      [nil, string, nil] # i guess...
    end

    Person.new name, email, handle
  end
end

module HasState
  def starred?; has_state?("starred") end
  def attachment?; has_state?("attachment") end
  def unread?; has_state?("unread") end
  def draft?; has_state?("draft") end
end

class ThreadSummary
  include HasState

  def initialize hash
    @subject = hash["subject"]
    @participants = hash["participants"].map { |p| Person.from_string(p) }
    @unread_participants = hash["unread_participants"].map { |p| Person.from_string(p) }
    @date = Time.at hash["date"]
    @size = hash["size"]
    @state = Set.new hash["state"]
    @labels = Set.new hash["labels"]
    @snippet = hash["snippet"]
    @thread_id = hash["thread_id"]

    @direct_recipients = hash["direct_recipients"].map { |p| Person.from_string(p) }
    @indirect_recipients = hash["indirect_recipients"].map { |p| Person.from_string(p) }
  end

  attr_reader :subject, :participants, :unread_participants, :direct_recipients, :indirect_recipients, :date, :size, :snippet, :thread_id
  attr_accessor :labels, :state

  def has_state? s; @state.member?(s) end
  def has_label? s; @labels.member?(s) end
end

class MessageSummary
  include HasState

  def initialize hash
    if hash["type"] == "fake"
      @fake = true
    else
      @fake = false
      @subject = hash["subject"]
      @from = Person.from_string hash["from"]
      @date = Time.at hash["date"]
      @to = hash["to"].map { |p| Person.from_string p }
      @thread_id = hash["thread_id"]
      @message_id = hash["message_id"]
      @state = Set.new hash["state"]
      @snippet = hash["snippet"]
    end
  end

  bool_reader :fake
  attr_reader :subject, :from, :date, :to, :thread_id, :message_id, :state, :snippet
  def recipients; to end

  def has_state? s; @state.member?(s) end
end

class Message
  def initialize hash
    @from = Person.from_string hash["from"]
    @to = Set.new hash["to"].map { |p| Person.from_string p }
    @cc = Set.new hash["cc"].map { |p| Person.from_string p }
    @bcc = Set.new hash["bcc"].map { |p| Person.from_string p }
    @subject = hash["subject"]
    @date = Time.at hash["date"]
    @parts = hash["parts"]
    @message_id = hash["message_id"]
    @state = Set.new hash["state"]
    @recipient_email = hash["recipient_email"]
  end

  attr_reader :subject, :from, :date, :to, :cc, :bcc, :thread_id, :message_id, :state, :parts, :recipient_email

  def has_state? s; @state.member?(s) end

  def recipients; to + cc + bcc end
end

end

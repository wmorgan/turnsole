require 'set'
require 'cgi'
require 'tempfile'
require 'uri'

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
    @unread_participants = Set.new hash["unread_participants"].map { |p| Person.from_string(p) }

    @date = Time.at hash["date"]
    @size = hash["size"]
    @state = Set.new hash["state"]
    @labels = Set.new hash["labels"]
    @snippet = hash["snippet"]
    @thread_id = hash["thread_id"]

    @direct_recipients = Set.new hash["direct_recipients"].map { |p| Person.from_string(p) }
    @indirect_recipients = Set.new hash["indirect_recipients"].map { |p| Person.from_string(p) }
  end

  attr_reader :subject, :participants, :unread_participants, :direct_recipients, :indirect_recipients, :date, :size, :snippet, :thread_id, :state
  attr_accessor :labels

  def has_state? s; @state.member?(s) end
  def has_label? s; @labels.member?(s) end

  ## here we simulate the server-side logic of replicating certain bits of
  ## state as labels. this is so that we can make modifications and have
  ## the ui do the right thing without having to wait for a server round-trip.
  def state= s
    @state = Set.new s
    HeliotropeClient::MESSAGE_MUTABLE_STATE.each do |s|
      if @state.member? s
        @labels << s
      else
        @labels.delete s
      end
    end
  end
end

class MessageSummary
  include HasState

  def initialize hash
    if hash["type"] == "fake"
      @fake = true
      @state = Set.new
    else
      @fake = false
      @subject = hash["subject"]
      @from = Person.from_string hash["from"]
      @date = Time.at hash["date"]
      @to = (hash["to"] + hash["cc"]).map { |p| Person.from_string p }
      @thread_id = hash["thread_id"]
      @message_id = hash["message_id"]
      @state = Set.new hash["state"]
      @snippet = hash["snippet"]
    end
  end

  bool_reader :fake
  attr_reader :subject, :from, :date, :to, :thread_id, :message_id, :snippet
  attr_accessor :state

  def recipients; to end

  def has_state? s; @state.member?(s) end
end

class Message
  include HasState

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
    @refs = hash["refs"]
    @email_message_id = hash["email_message_id"]

    @recipient_email = hash["recipient_email"]
    @list_post = hash["list_post"]
    @list_subscribe = hash["list_subscribe"]
    @list_unsubscribe = hash["list_unsubscribe"]
    @reply_to = hash["reply_to"].empty? ? nil : Person.from_string(hash["reply_to"])
  end

  def parse! context
    @chunks ||= ChunkParser.new(context).chunks_for(self)
  end

  attr_reader :subject, :from, :date, :to, :cc, :bcc, :thread_id, :message_id, :parts, :recipient_email, :list_post, :list_unsubscribe, :list_subscribe, :chunks, :refs, :email_message_id, :reply_to
  attr_accessor :state

  def has_state? s; @state.member?(s) end

  def recipients; to + cc + bcc end

  def quotable_body_lines
    chunks.select(&:quotable?).map(&:lines).flatten
  end

  def quotable_header_lines
    ["From: #{@from.email_ready_address}"] +
      (@to.empty? ? [] : ["To: " + @to.map { |p| p.email_ready_address }.join(", ")]) +
      (@cc.empty? ? [] : ["Cc: " + @cc.map { |p| p.email_ready_address }.join(", ")]) +
      (@bcc.empty? ? [] : ["Bcc: " + @bcc.map { |p| p.email_ready_address }.join(", ")]) +
      ["Date: #{@date.rfc822}",
       "Subject: #{@subject}"]
  end

  def dump_to_html! context, file_prefix
    parse! context

    attachment_files = {}
    cid_files = {}
    ts = Time.now.to_i

    ## write out attachment files and record filenames
    chunks.each do |c|
      next unless c.is_a? Chunk::Attachment
      f = File.new "/tmp/#{file_prefix}-#{$$}-#{ts}-#{c.part_id}", "w"
      f.write c.content
      f.close
      attachment_files[c] = f
      cid_files[c.cid] = f
    end

    s = <<EOS
<html>
<head><title>#{escape_html subject}</title>
<meta http-equiv="Content-type" content="text/html;charset=UTF-8"/>
<meta charset="utf-8"/>
</head>
<body>
<div><b>From</b>: #{escape_html from.email_ready_address}</div>
<div><b>To</b>: #{escape_html to.map { |p| p.email_ready_address }.join(", ")}</div>
<div><b>Cc</b>: #{escape_html cc.map { |p| p.email_ready_address }.join(", ")}</div>
<div><b>Bcc</b>: #{escape_html bcc.map { |p| p.email_ready_address }.join(", ")}</div>
<div><b>Date</b>: #{escape_html Time.at(date)}</div>
<div><b>Subject</b>: #{escape_html subject}</div>
<hr/>
EOS
    s << chunks.map do |c|
      %{<div style="padding-top: 1em">} + case c
      when Chunk::Attachment
        attachment_url = "file://" + attachment_files[c].path
        %{<hr/><a href="#{attachment_url}">[attachment: #{c.filename} (#{c.content_type})]</a>} +
          if c.content_type =~ /^image\//
            %{<img src="#{attachment_url}"/>}
          else
            ""
          end
      when Chunk::HTML
        ## substitute cid values
        cid_files.inject(c.to_html) { |content, (cid, file)| content.gsub("cid:#{cid}", "file://#{file.path}") }
      else
        link_urls c.to_html
      end
    end.join

    s << <<EOS
</body>
</html>
EOS

    f = File.new "/tmp/#{file_prefix}-#{$$}-#{ts}.html", "w"
    f.write s
    f.close
    [f, attachment_files.values]
  end

private

  def escape_html html; CGI.escapeHTML html.to_s end

  URL_REGEXP = /(#{URI.regexp(%w(http https))})/
  def link_urls text; text.gsub(URL_REGEXP, "<a href=\"\\1\">\\1</a>") end

end

end

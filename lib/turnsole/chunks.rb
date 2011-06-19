require 'tempfile'

## Here we define all the "chunks" that a message is parsed into. Chunks are
## used by ThreadViewMode to render a message. Chunks are used for both MIME
## stuff like attachments, for Turnsole's parsing of the message body into
## text, quote, and signature regions, and for notices like "this message was
## decrypted" or "this message contains a valid signature"---basically,
## anything we want to differentiate at display time.
##
## A chunk can be inlineable, expandable, or viewable. If it's inlineable,
## #color and #lines are called and the output is treated as part of the
## #message text. This is how Text and one-line Quotes and Signatures work.
##
## If it's not inlineable but is expandable, #patina_color and
## #patina_text are called to generate a "patina" (a one-line widget,
## basically), and the user can press enter to toggle the display of the chunk
## content, which is generated from #color and #lines as above. This is how
## Quote, Signature, and most widgets work. Exandable chunks additionally
## define #initial_state to be :open if they want to start expanded (default is
## to start collapsed).
##
## If it's not expandable but is viewable, a patina is displayed using
## #patina_color and #patina_text, but no toggling is allowed. Instead,
## if #view! is defined, pressing enter on the widget calls view! and (if that
## returns false) #to_s. Otherwise, enter does nothing. This is how
## non-inlineable attachments work.
##
## Independent of all that, a chunk can be quotable, in which case it's
## included as quoted text during a reply. Text, Quotes, and mime-parsed
## attachments are quotable; Signatures are not.

## monkey-patch time: make temp files have the right extension
## Backport from Ruby 1.9.2 for versions lower than 1.8.7
if RUBY_VERSION < '1.8.7'
  class Tempfile
    def make_tmpname(prefix_suffix, n)
      case prefix_suffix
      when String
        prefix = prefix_suffix
        suffix = ""
      when Array
        prefix = prefix_suffix[0]
        suffix = prefix_suffix[1]
      else
        raise ArgumentError, "unexpected prefix_suffix: #{prefix_suffix.inspect}"
      end
      t = Time.now.strftime("%Y%m%d")
      path = "#{prefix}#{t}-#{$$}-#{rand(0x100000000).to_s(36)}"
      path << "-#{n}" if n
      path << suffix
    end
  end
end

module Turnsole
module Chunk
  class Attachment
    HookManager.register "mime-decode", <<EOS
Decodes a MIME attachment into text form. The text will be displayed directly
in Turnsole. For attachments that you wish to use a separate program to view
(e.g. images), you should use the mime-view hook instead.

Variables:
   content_type: the content-type of the attachment
        charset: the charset of the attachment, if applicable
       filename: the filename of the attachment as saved to disk
  sibling_types: if this attachment is part of a multipart MIME attachment,
                 an array of content-types for all attachments. Otherwise,
                 the empty array.
Return value:
  The decoded text of the attachment, or nil if not decoded.
EOS

    HookManager.register "mime-view", <<EOS
Views a non-text MIME attachment. This hook allows you to run
third-party programs for attachments that require such a thing (e.g.
images). To instead display a text version of the attachment directly in
Turnsole, use the mime-decode hook instead.

Note that by default (at least on systems that have a run-mailcap command),
Turnsole uses the default mailcap handler for the attachment's MIME type. If
you want a particular behavior to be global, you may wish to change your
mailcap instead.

Variables:
   content_type: the content-type of the attachment
       filename: the filename of the attachment as saved to disk
Return value:
  True if the viewing was successful, false otherwise. If false, calling
  /usr/bin/run-mailcap will be tried.
EOS

    attr_reader :message_id, :part_id, :content_type, :filename, :size, :lines, :content
    bool_reader :quotable

    def initialize context, message_id, part_id, content_type, filename, size, content=nil
      @context = context
      @message_id = message_id
      @part_id = part_id

      ## we need to decompose the charset a bit
      @charset = content_type =~ /charset="?(.*?)"?(;|$)/i ? $1 : nil
      @content_type = content_type =~ /^(.+?)(;|$)/ ? $1 : content_type

      @filename = filename
      @size = size

      @quotable = false # changed to true if we can parse it through the
                        # mime-decode hook, or if it's plain text
      @content = nil
      @lines = nil

      receive_content content if content # if we happen to have it already...
    end

    def content
      @content ||= begin
        say_id = @context.screen.minibuf.say "downloading attachment #{@filename}..."
        receive_content @context.client.message_part(@message_id, @part_id)
      ensure
        @context.screen.minibuf.clear say_id
      end
    end

    def receive_content content
      @content = content
      text_version = case @content_type
      when /^text\/plain\b/
        @content
      else
        @context.hooks.run "mime-decode", :content_type => @content_type,
                           :filename => lambda { write_to_disk },
                           :charset => @charset
      end

      if text_version
        text_version = Iconv.easy_decode(@context.encoding, @charset, text_version) if @charset
        @lines = text_version.gsub("\r\n", "\n").gsub(/\t/, "        ").gsub(/\r/, "").split("\n")
        @quotable = true
      end
      @content
    end

    def color; :default end
    def patina_color; :attachment end
    def patina_text
      if expandable?
        "Attachment: #{filename} (#{lines.length} lines)"
      else
        "Attachment: #{filename} (#{content_type}; #{@size.to_human_size})"
      end
    end

    ## an attachment is exapndable if we've managed to decode it into
    ## something we can display inline. otherwise, it's viewable.
    def inlineable?; false end
    def expandable?; !viewable? end
    def initial_state; :open end
    def viewable?; @lines.nil? end
    def view_default! path
      cmd = case ::Config::CONFIG["arch"]
      when /darwin/; "open '#{path}'"
      else; "/usr/bin/run-mailcap --action=view '#{@content_type}:#{path}'"
      end
      @context.logger.debug "running: #{cmd.inspect}"
      @context.ui.shell_out(cmd) || begin
        @context.screen.minibuf.flash "View command failed! Displaying as text."
        @context.screen.spawn filename, TextMode.new(@context, content.force_to_ascii)
      end
    end

    def view!
      path = write_to_disk
      ret = @context.hooks.run "mime-view", :content_type => @content_type,
                                            :filename => path
      ret || view_default!(path)
    end

    def write_to_disk
      file = Tempfile.new(["sup", @filename.gsub("/", "_") || "sup-attachment"])
      file.write content
      file.close
      file.path
    end

    ## used when viewing the attachment as text
    def to_s
      @lines || @content
    end
  end

  class Text
    attr_reader :lines
    def initialize lines
      @lines = lines
      ## trim off all empty lines except one
      @lines.pop while @lines.length > 1 && @lines[-1] =~ /^\s*$/ && @lines[-2] =~ /^\s*$/
    end

    def inlineable?; true end
    def quotable?; true end
    def expandable?; false end
    def viewable?; false end
    def color; :default end
  end

  class Quote
    attr_reader :lines
    def initialize lines
      @lines = lines
    end

    def inlineable?; @lines.length == 1 end
    def quotable?; true end
    def expandable?; !inlineable? end
    def initial_state; :closed end
    def viewable?; false end

    def patina_color; :quote_patina end
    def patina_text; "(#{lines.length} quoted lines)" end
    def color; :quote end
  end

  class Signature
    attr_reader :lines
    def initialize lines
      @lines = lines
    end

    def inlineable?; @lines.length == 1 end
    def quotable?; false end
    def expandable?; !inlineable? end
    def initial_state; :closed end
    def viewable?; false end

    def patina_color; :sig_patina end
    def patina_text; "(#{lines.length}-line signature)" end
    def color; :sig end
  end

  class EnclosedMessage
    attr_reader :lines
    def initialize from, to, cc, date, subj
      @from = from ? "unknown sender" : from.full_adress
      @to = to ? "" : to.map { |p| p.email_ready_address }.join(", ")
      @cc = cc ? "" : cc.map { |p| p.email_ready_address }.join(", ")
      if date
        @date = date.rfc822
      else
        @date = ""
      end

      @subj = subj

      @lines = "\nFrom: #{from}\n"
      @lines += "To: #{to}\n"
      if !cc.empty?
        @lines += "Cc: #{cc}\n"
      end
      @lines += "Date: #{date}\n"
      @lines += "Subject: #{subj}\n\n"
    end

    def inlineable?; false end
    def quotable?; false end
    def expandable?; true end
    def initial_state; :closed end
    def viewable?; false end

    def patina_color; :generic_notice_patina end
    def patina_text; "Begin enclosed message sent on #{@date}" end

    def color; :quote end
  end

  class CryptoNotice
    attr_reader :lines, :status, :patina_text

    def initialize status, description, lines=[]
      @status = status
      @patina_text = description
      @lines = lines
    end

    def patina_color
      case status
      when :valid then :cryptosig_valid
      when :valid_untrusted then :cryptosig_valid_untrusted
      when :invalid then :cryptosig_invalid
      else :cryptosig_unknown
      end
    end
    def color; patina_color end

    def inlineable?; false end
    def quotable?; false end
    def expandable?; !@lines.empty? end
    def viewable?; false end
  end
end

class ChunkParser
  QUOTE_PATTERN = /^\s{0,4}[>|\}]/
  BLOCK_QUOTE_PATTERN = /^-----\s*Original Message\s*----+$/
  SIG_PATTERN = /(^(- )*-- ?$)|(^\s*----------+\s*$)|(^\s*_________+\s*$)|(^\s*--~--~-)|(^\s*--\+\+\*\*==)/

  GPG_SIGNED_START = "-----BEGIN PGP SIGNED MESSAGE-----"
  GPG_SIGNED_END = "-----END PGP SIGNED MESSAGE-----"
  GPG_START = "-----BEGIN PGP MESSAGE-----"
  GPG_END = "-----END PGP MESSAGE-----"
  GPG_SIG_START = "-----BEGIN PGP SIGNATURE-----"
  GPG_SIG_END = "-----END PGP SIGNATURE-----"

  MAX_SIG_DISTANCE = 15 # lines from the end

  def initialize context
    @context = context
  end

  def chunks_for message
    message.parts.map_with_index do |hash, i|
      case hash["type"]
      when /^text\//
        text_to_chunks(hash["content"].normalize_whitespace.split("\n"))
      else
        Chunk::Attachment.new @context, message.message_id, i, hash["type"], hash["filename"], hash["size"], hash["content"]
      end
    end.flatten
  end

  ## parse the lines of text into chunk objects.  the heuristics here
  ## need tweaking in some nice manner. TODO: move these heuristics
  ## into the classes themselves.
  def text_to_chunks lines
    state = :text # one of :text, :quote, or :sig
    chunks = []
    chunk_lines = []
    nextline_index = -1

    lines.each_with_index do |line, i|
      if i >= nextline_index
        # look for next nonblank line only when needed to avoid O(n²)
        # behavior on sequences of blank lines
        if nextline_index = lines[(i+1)..-1].index { |l| l !~ /^\s*$/ } # skip blank lines
          nextline_index += i + 1
          nextline = lines[nextline_index]
        else
          nextline_index = lines.length
          nextline = nil
        end
      end

      case state
      when :text
        newstate = nil

        ## the following /:$/ followed by /\w/ is an attempt to detect the
        ## start of a quote. this is split into two regexen because the
        ## original regex /\w.*:$/ had very poor behavior on long lines
        ## like ":a:a:a:a:a" that occurred in certain emails.
        if line =~ QUOTE_PATTERN || (line =~ /:$/ && line =~ /\w/ && nextline =~ QUOTE_PATTERN)
          newstate = :quote
        elsif line =~ SIG_PATTERN && (lines.length - i) < MAX_SIG_DISTANCE
          newstate = :sig
        elsif line =~ BLOCK_QUOTE_PATTERN
          newstate = :block_quote
        end

        if newstate
          chunks << Chunk::Text.new(chunk_lines) unless chunk_lines.empty?
          chunk_lines = [line]
          state = newstate
        else
          chunk_lines << line
        end

      when :quote
        newstate = nil

        if line =~ QUOTE_PATTERN || (line =~ /^\s*$/ && nextline =~ QUOTE_PATTERN)
          chunk_lines << line
        elsif line =~ SIG_PATTERN && (lines.length - i) < MAX_SIG_DISTANCE
          newstate = :sig
        else
          newstate = :text
        end

        if newstate
          if chunk_lines.empty?
            # nothing
          else
            chunks << Chunk::Quote.new(chunk_lines)
          end
          chunk_lines = [line]
          state = newstate
        end

      when :block_quote, :sig
        chunk_lines << line
      end
    end

    ## final object
    case state
    when :quote, :block_quote
      chunks << Chunk::Quote.new(chunk_lines) unless chunk_lines.empty?
    when :text
      chunks << Chunk::Text.new(chunk_lines) unless chunk_lines.empty?
    when :sig
      chunks << Chunk::Signature.new(chunk_lines) unless chunk_lines.empty?
    end
    chunks
  end
end

end

require 'tempfile'
require 'socket' # just for gethostname!
require 'pathname'
require 'rmail'

module Turnsole

class EditMessageMode < LineCursorMode
  FORCE_HEADERS = %w(From To Cc Bcc Subject)
  MULTI_HEADERS = %w(To Cc Bcc)
  NON_EDITABLE_HEADERS = %w(Message-id Date)

  HookManager.register "signature", <<EOS
Generates a message signature.
Variables:
      header: an object that supports string-to-string hashtable-style access
              to the raw headers for the message. E.g., header["From"],
              header["To"], etc.
  from_email: the email part of the From: line, or nil if empty
Return value:
  A string (multi-line ok) containing the text of the signature, or nil to
  use the default signature, or :none for no signature.
EOS

  HookManager.register "before-edit", <<EOS
Modifies message body and headers before editing a new message. Variables
should be modified in place.
Variables:
  header: a hash of headers. See 'signature' hook for documentation.
  body: an array of lines of body text.
Return value:
  none
EOS

  HookManager.register "mentions-attachments", <<EOS
Detects if given message mentions attachments the way it is probable
that there should be files attached to the message.
Variables:
  header: a hash of headers. See 'signature' hook for documentation.
  body: an array of lines of body text.
Return value:
  True if attachments are mentioned.
EOS

  HookManager.register "crypto-mode", <<EOS
Modifies cryptography settings based on header and message content, before
editing a new message. This can be used to set, for example, default cryptography
settings.
Variables:
    header: a hash of headers. See 'signature' hook for documentation.
    body: an array of lines of body text.
    crypto_selector: the UI element that controls the current cryptography setting.
Return value:
     none
EOS

  attr_reader :status
  attr_accessor :body, :header
  bool_reader :edited

  register_keymap do |k|
    k.add :send_message, "Send message", 'y'
    k.add :edit_message_or_field, "Edit selected field", 'e'
    k.add :edit_to, "Edit To:", 't'
    k.add :edit_cc, "Edit Cc:", 'c'
    k.add :edit_subject, "Edit Subject", 's'
    k.add :edit_message!, "Edit message", :enter
    k.add :save_as_draft, "Save as draft", 'P'
    k.add :attach_file, "Attach a file", 'a'
    k.add :delete_attachment, "Delete an attachment", 'd'
    k.add :move_cursor_right, "Move selector to the right", :right, 'l'
    k.add :move_cursor_left, "Move selector to the left", :left, 'h'
  end

  def initialize context, opts={}
    super

    @context = context
    @header = opts.delete(:header) || {}
    @header_lines = []

    @body = opts.delete(:body) || []
    @body += sig_lines

    if opts[:attachments]
      @attachments = opts[:attachments].values
      @attachment_names = opts[:attachments].keys
    else
      @attachments = []
      @attachment_names = []
    end

    begin
      hostname = File.open("/etc/mailname", "r").gets.chomp
    rescue
      nil
    end
    hostname = Socket.gethostname if hostname.nil? or hostname.empty?

    @message_id = "<#{Time.now.to_i}-turnsole-#{rand 100000}@#{hostname}>"
    @edited = false
    @selectors = []
    @selector_label_width = 0

    @crypto_selector = if @context.crypto.have_crypto?
      HorizontalSelector.new "Crypto:", [:none] + CryptoManager::OUTGOING_MESSAGE_OPERATIONS.keys, ["None"] + CryptoManager::OUTGOING_MESSAGE_OPERATIONS.values
    end
    if @crypto_selector
      add_selector @crypto_selector
      @context.hooks.run "crypto-mode", :header => @header, :body => @body, :crypto_selector => @crypto_selector
    end

    @context.hooks.run "before-edit", :header => @header, :body => @body

    regen_text!
  end

  ## if we have at least one horizontal selector, we'll add a space as well
  def num_selector_lines; @selectors.empty? ? 0 : (@selectors.length + 1) end
  def num_lines; @text.length + num_selector_lines end

  def [] i
    if @selectors.empty?
      @text[i]
    elsif i < @selectors.length
      @selectors[i].line @selector_label_width
    elsif i == @selectors.length
      ""
    else
      @text[i - num_selector_lines]
    end
  end

  ## hook for subclasses. i hate this style of programming.
  def handle_new_text header, body; end

  def edit_message_or_field
    line = curpos - num_selector_lines
    if line < 0 # no editing on these things
      return
    elsif line < @header_lines.length
      edit_field @header_lines[line]
    else
      edit_message!
    end
  end

  def edit_to; edit_field "To" end
  def edit_cc; edit_field "Cc" end
  def edit_subject; edit_field "Subject" end

  def edit_message!
    @file = Tempfile.new "turnsole.#{self.class.name.gsub(/.*::/, '').camel_to_hyphy}"
    @file.puts format_headers(@header - NON_EDITABLE_HEADERS).first
    @file.puts
    @file.puts @body.join("\n")
    @file.close

    editor = @context.config.editor || ENV['EDITOR'] || "/usr/bin/vi"

    mtime = File.mtime @file.path
    @context.ui.shell_out "#{editor} #{@file.path}"
    @edited ||= File.mtime(@file.path) > mtime

    if @edited
      header, @body = parse_file @file.path
      @header = header - NON_EDITABLE_HEADERS
      handle_new_text @header, @body
      update!
    end

    @edited
  end

  def killable?
    !edited? || @context.input.ask_yes_or_no("Discard message?")
  end

  def unsaved?; edited? end

  def attach_file
    fn = @context.input.ask_for_filename :attachment, "File name (enter for browser): "
    return unless fn
    begin
      Dir[fn].each do |f|
        @attachments << RMail::Message.make_file_attachment(f)
        @attachment_names << f
      end
      update!
    rescue SystemCallError => e
      @context.screen.minibuf.flash "Can't read #{fn}: #{e.message}"
    end
  end

  def delete_attachment
    i = curpos - @attachment_lines_offset
    if i >= 0 && i < @attachments.size && @context.input.ask_yes_or_no("Remove attachment #{@attachment_names[i]}?")
      @attachments.delete_at i
      @attachment_names.delete_at i
      update!
    end
  end

protected

  def rfc2047_encode string
    string = [string].pack('M') # basic quoted-printable
    string.gsub!(/=\n/,'')      # .. remove trailing newline
    string.gsub!(/_/,'=5F')     # .. encode underscores
    string.gsub!(/\?/,'=3F')    # .. encode question marks
    string.gsub!(/ /,'_')       # .. translate space to underscores
    "=?#{@context.encoding.downcase}?q?#{string}?="
  end

  def rfc2047_encode_subject string
    return string if string.ascii_only?
    rfc2047_encode string
  end

  RE_ADDRESS = /(.+)( <.*@.*>)/

  # Encode "bælammet mitt <user@example.com>" into
  # "=?utf-8?q?b=C3=A6lammet_mitt?= <user@example.com>
  def rfc2047_encode_address string
    return string if string.ascii_only?
    string.sub(RE_ADDRESS) { |match| rfc2047_encode($1) + $2 }
  end

  def move_cursor_left
    if curpos < @selectors.length
      @selectors[curpos].roll_left
      buffer.mark_dirty!
    else
      col_left
    end
  end

  def move_cursor_right
    if curpos < @selectors.length
      @selectors[curpos].roll_right
      buffer.mark_dirty!
    else
      col_right
    end
  end

  def add_selector s
    @selectors << s
    @selector_label_width = [@selector_label_width, s.label.length].max
  end

  def update!
    regen_text!
    buffer.mark_dirty!
  end

  def regen_text!
    header, @header_lines = format_headers(@header - NON_EDITABLE_HEADERS)
    @text = header + [""] + @body

    @attachment_lines_offset = 0

    unless @attachments.empty?
      @text += [""]
      @attachment_lines_offset = @text.length
      @text += (0 ... @attachments.size).map { |i| [[:attachment, "+ Attachment: #{@attachment_names[i]} (#{@attachments[i].body.size.to_human_size})"]] }
    end
  end

  def parse_file fn
    begin
      m = RMail::Parser.read IO.read(fn).safely_mark_binary
      headers = m.header.to_a.to_h - NON_EDITABLE_HEADERS # bleargh!!
      headers.map { |name, text| headers[name] = parse_header name, text.safely_mark_utf8 }
      [headers, m.body.to_s.safely_mark_utf8.split("\n")]
    end
  end

  def parse_header k, v
    return v unless MULTI_HEADERS.include?(k)
    v.split_on_commas.map do |name|
      if(p = @context.contacts.contact_with_alias(name))
        p.email_ready_address
      else
        name
      end
    end
  end

  def format_headers header
    header_lines = []
    headers = (FORCE_HEADERS + (header.keys - FORCE_HEADERS)).map do |h|
      lines = make_lines "#{h}:", header[h]
      lines.length.times { header_lines << h }
      lines
    end.flatten.compact
    [headers, header_lines]
  end

  def make_lines header, things
    case things
    when nil, []
      [header + " "]
    when String
      [header + " " + things]
    else
      if things.empty?
        [header]
      else
        things.map_with_index do |name, i|
          raise "an array: #{name.inspect} (things #{things.inspect})" if Array === name
          if i == 0
            header + " " + name
          else
            (" " * (header.display_width + 1)) + name
          end + (i == things.length - 1 ? "" : ",")
        end
      end
    end
  end

  def send_message
    return false if !edited? && !@context.input.ask_yes_or_no("Message unedited. Really send?")
    return false if @context.config.confirm_no_attachments && mentions_attachments? && @attachments.size == 0 && !@context.input.ask_yes_or_no("You haven't added any attachments. Really send?")
    return false if @context.config.confirm_top_posting && top_posting? && !@context.input.ask_yes_or_no("You're top-posting. That makes you a bad person. Really send?")

    from_email = if @header["From"] =~ /<?(\S+@(\S+?))>?$/
      $1
    else
      @context.accounts.default_account.email
    end

    acct = @context.accounts.account_for(from_email) || @context.accounts.default_account

    begin
      m = build_message
    rescue Crypto::Error => e
      warn "Problem sending mail: #{e.message}"
      @context.screen.minibuf.flash "Problem sending mail: #{e.message}"
      return
    end

    say_id = @context.screen.minibuf.say "Sending message..."
    begin
      ret = @context.client.send_message m, :labels => %w(inbox)
      @context.screen.minibuf.flash "Message sent!"

      if ret["thread_id"] # was new, not old...
        thread = @context.client.threadinfo ret["thread_id"]
        @context.ui.broadcast :thread, thread # inform everyone
      end

      @context.screen.kill_buffer buffer
    ensure
      @context.screen.minibuf.clear say_id
    end
  end

  def save_as_draft
    DraftManager.write_draft { |f| write_message f, false }
    BufferManager.kill_buffer buffer
    BufferManager.flash "Saved for later editing."
  end

  def build_message
    m = RMail::Message.new
    m.body = @body.join "\n"
    ## body must end in a newline or GPG signatures will be WRONG!
    m.body += "\n" unless m.body =~ /\n\Z/
    m.header["Content-Type"] = "text/plain; charset=#{@context.encoding}"

    ## there are attachments, so wrap body in an attachment of its own
    unless @attachments.empty?
      body_m = m
      #body_m.header["Content-Disposition"] = "inline"
      m = RMail::Message.new

      m.add_part body_m
      @attachments.each { |a| m.add_part a }
    end

    ## do whatever crypto transformation is necessary
    if @crypto_selector && @crypto_selector.val != :none
      from_email = Person.from_string(@header["From"]).email
      to_email = [@header["To"], @header["Cc"], @header["Bcc"]].flatten.compact.map { |p| Person.from_string(p).email }
      if m.multipart?
        m.each_part {|p| p = transfer_encode p}
      else
        m = transfer_encode m
      end

      m = @context.crypto.send @crypto_selector.val, from_email, to_email, m
    end

    ## finally, set the top-level headers
    @header.each do |k, v|
      next if v.nil? || v.empty?
      m.header[k] =
        case v
        when String
          k.match(/subject/i) ? rfc2047_encode_subject(v) : rfc2047_encode_address(v)
        when Array
          v.map { |v| rfc2047_encode_address v }.join ", "
        end
    end

    m.header["Date"] = Time.now.rfc2822
    m.header["Message-Id"] = @message_id
    m.header["User-Agent"] = "turnsole, a heliotrope client v.#{VERSION}"
    #m.header["Content-Transfer-Encoding"] ||= '8bit'
    #m.header["MIME-Version"] = "1.0" if m.multipart?
    m
  end

  ## TODO: remove this. redundant with write_full_message_to.
  ##
  ## this is going to change soon: draft messages (currently written
  ## with full=false) will be output as yaml.
  def write_message f, full=true, date=Time.now
    raise ArgumentError, "no pre-defined date: header allowed" if @header["Date"]
    f.puts format_headers(@header).first
    f.puts <<EOS
Date: #{date.rfc2822}
Message-Id: #{@message_id}
EOS
    if full
      f.puts <<EOS
Mime-Version: 1.0
Content-Type: text/plain; charset=us-ascii
Content-Disposition: inline
User-Agent: Redwood/#{Redwood::VERSION}
EOS
    end

    f.puts
    f.puts sanitize_body(@body.join("\n"))
    f.puts sig_lines if full
  end

protected

  def edit_field field
    case field
    when "Subject"
      text = @context.input.ask :subject, "Subject: ", @header[field]
      if text
        @header[field] = parse_header field, text
        update!
      end
    else
      default = case field
      when *MULTI_HEADERS
        @header[field] ||= []
        @header[field].join(", ") + ","
      else
        @header[field]
      end

      contacts = @context.input.ask_for_contacts :people, "#{field}: ", default
      if contacts
        text = contacts.map { |s| s.email_ready_address }.join(", ")
        @header[field] = parse_header field, text
        update!
      end
    end
  end

private

  def sanitize_body body
    body.gsub(/^From /, ">From ")
  end

  def mentions_attachments?
    if @context.hooks.enabled? "mentions-attachments"
      @context.hooks.run "mentions-attachments", :header => @header, :body => @body
    else
      @body.any? {  |l| l =~ /^[^>]/ && l =~ /\battach(ment|ed|ing|)\b/i }
    end
  end

  def top_posting?
    @body.join("\n") =~ /(\S+)\s*Excerpts from.*\n(>.*\n)+\s*\Z/
  end

  def sig_lines
    p = Person.from_string(@header["From"])
    from_email = p && p.email

    ## first run the hook
    hook_sig = @context.hooks.run "signature", :header => @header, :from_email => from_email

    return [] if hook_sig == :none
    return ["", "-- "] + hook_sig.split("\n") if hook_sig

    ## no hook, do default signature generation based on config.yaml
    return [] unless from_email
    sigfn = (@context.accounts.account_for(from_email) ||
             @context.accounts.default_account).signature

    if sigfn && File.exists?(sigfn)
      ["", "-- "] + File.readlines(sigfn).map { |l| l.chomp }
    else
      []
    end
  end

  def transfer_encode msg_part
    ## return the message unchanged if it's already encoded
    if (msg_part.header["Content-Transfer-Encoding"] == "base64" ||
        msg_part.header["Content-Transfer-Encoding"] == "quoted-printable")
      return msg_part
    end

    ## encode to quoted-printable for all text/* MIME types,
    ## use base64 otherwise
    if msg_part.header["Content-Type"] =~ /text\/.*/
      msg_part.header["Content-Transfer-Encoding"] = 'quoted-printable'
      msg_part.body = [msg_part.body].pack('M')
    else
      msg_part.header["Content-Transfer-Encoding"] = 'base64'
      msg_part.body = [msg_part.body].pack('m')
    end
    msg_part
  end
end

end

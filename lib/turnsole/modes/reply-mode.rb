module Turnsole

class ReplyMode < EditMessageMode
  REPLY_TYPES = [:sender, :recipient, :list, :all, :user]
  TYPE_DESCRIPTIONS = {
    :sender => "Sender",
    :recipient => "Recipient",
    :all => "All",
    :list => "Mailing list",
    :user => "Custom"
  }

  HookManager.register "attribution", <<EOS
Generates an attribution ("Excerpts from Joe Bloggs's message of Fri Jan 11 09:54:32 -0500 2008:").
Variables:
  message: a message object representing the message being replied to
    (useful values include message.from.name and message.date)
Return value:
  A string containing the text of the quote line (can be multi-line)
EOS

  HookManager.register "reply-from", <<EOS
Selects a default address for the From: header of a new reply.
Variables:
  message: a message object representing the message being replied to
    (useful values include message.recipient_email, message.to, and message.cc)
Return value:
  A Person to be used as the default for the From: header, or nil to use the
  default behavior.
EOS

  HookManager.register "reply-to", <<EOS
Set the default reply-to mode.
Variables:
  modes: array of valid modes to choose from, which will be a subset of
             [:#{REPLY_TYPES * ', :'}]
         The default behavior is equivalent to
             ([:list, :sender, :recipent] & modes)[0]
Return value:
  The reply mode you desire, or nil to use the default behavior.
EOS

  def initialize context, message, type_arg=nil
    @context = context
    @m = message
    @edited = false

    ## determine the from address. try and find an account somewhere in
    ## the list of to's and cc's and look up the corresponding name form
    ## the list of accounts. if this does not succeed, use the
    ## recipient_email (=envelope-to) instead. this is for the case
    ## where mail is received from a mailing lists (so the To: is the
    ## list id itself). if the user subscribes via a particular alias,
    ## we want to use that alias in the reply.
    from_addr = (@m.to + @m.cc).map(&:email)
    from = (from_addr + [@m.recipient_email]).argfind { |p| @context.accounts.account_for(p) }
    hook_reply_from = @context.hooks.run "reply-from", :message => @m
    from = hook_reply_from || from || @context.accounts.default_account

    ## now, determine to: and cc: addressess. we ignore reply-to for list
    ## messages because it's typically set to the list address, which we
    ## explicitly treat with reply type :list
    to = @m.list_post ? @m.from : (@m.reply_to || @m.from)

    ## next, cc:
    cc = @m.to + @m.cc - Set.new([from, to])

    ## one potential reply type is "reply to recipient". this only
    ## happens in certain cases.  if there's no cc, then the sender is
    ## the person you want to reply to. if it's a list message, then the
    ## list address is. otherwise, the cc contains a recipient.
    useful_recipient = !(cc.empty? || @m.list_post)

    @headers = {}
    @headers[:recipient] = {
      "To" => cc.map { |p| p.email_ready_address },
    } if useful_recipient

    ## typically we don't want to have a reply-to-sender option if the sender
    ## is a user account. however, if the cc is empty, it's a message to
    ## ourselves, so for the lack of any other options, we'll add it.
    @headers[:sender] = { "To" => [to.email_ready_address] } if !@context.accounts.is_account?(to) || !useful_recipient

    @headers[:user] = {}

    not_me_ccs = cc.select { |p| !@context.accounts.is_account?(p) }
    @headers[:all] = {
      "To" => [to.email_ready_address],
      "Cc" => not_me_ccs.map { |p| p.email_ready_address },
    } unless not_me_ccs.empty?

    if @m.list_post
      list_address = if @m.list_post =~ /<mailto:(.*?)(\?subject=(.*?))?>/
        $1
      else
        @m.list_post
      end

      @headers[:list] = { "To" => [list_address] }
    end

    refs = gen_references

    @headers.each do |k, v|
      @headers[k] = {
               "From" => from.email_ready_address,
               "To" => [],
               "Cc" => [],
               "Bcc" => [],
               "In-reply-to" => "<#{@m.email_message_id}>",
               "Subject" => @m.subject,
               "References" => refs,
             }.merge v
    end

    types = REPLY_TYPES.select { |t| @headers.member?(t) }
    @type_selector = HorizontalSelector.new "Reply to:", types, types.map { |x| TYPE_DESCRIPTIONS[x] }

    hook_reply = @context.hooks.run "reply-to", :modes => types

    @type_selector.set_to(
      if types.include? type_arg
        type_arg
      elsif types.include? hook_reply
        hook_reply
      elsif @m.list_post
        :list
      elsif @headers.member? :sender
        :sender
      else
        :recipient
      end)

    body = reply_body_lines_for message

    @bodies = {}
    @headers.each do |k, v|
      @bodies[k] = body
      @context.hooks.run "before-edit", :header => v, :body => @bodies[k]
    end

    super @context, :header => @headers[@type_selector.val], :body => @bodies[@type_selector.val], :twiddles => false
    add_selector @type_selector
  end

protected

  def move_cursor_right
    super
    if @headers[@type_selector.val] != self.header
      self.header = @headers[@type_selector.val]
      self.body = @bodies[@type_selector.val] unless @edited
      update!
    end
  end

  def move_cursor_left
    super
    if @headers[@type_selector.val] != self.header
      self.header = @headers[@type_selector.val]
      self.body = @bodies[@type_selector.val] unless @edited
      update!
    end
  end

  def reply_body_lines_for m
    quotable_body_lines = m.chunks.select(&:quotable?).map(&:lines).flatten
    attribution = @context.hooks.run("attribution", :message => m) || default_attribution(m)
    lines = attribution.split("\n") + quotable_body_lines.map { |l| "> #{l}" }
    lines.pop while lines.last =~ /^\s*$/
    lines
  end

  def default_attribution m
    "Excerpts from #{@m.from.name}'s message of #{@m.date}:"
  end

  def handle_new_text new_header, new_body
    if new_body != @bodies[@type_selector.val]
      @bodies[@type_selector.val] = new_body
      @edited = true
    end
    old_header = @headers[@type_selector.val]
    if (new_header.size != old_header.size) || old_header.any? { |k, v| new_header[k] != v }
      @type_selector.set_to :user
      self.header = @headers[:user] = new_header
      update!
    end
  end

  def gen_references
    (@m.refs + [@m.email_message_id]).map { |x| "<#{x}>" }.join(" ")
  end

  def edit_field field
    edited_field = super
    if edited_field && edited_field != "Subject"
      @type_selector.set_to :user
      update!
    end
  end
end

end

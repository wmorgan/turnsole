module Turnsole

class ForwardMode < EditMessageMode
  ## TODO: share some of this with reply-mode
  def initialize context, opts={}
    @context = context

    header = {}
    header["From"] = (opts[:from] || context.accounts.default_account).email_ready_address

    header["Subject"] = if opts[:message]
      "Fwd: " + opts[:message].subject
    elsif opts[:attachments]
      "Fwd: " + opts[:attachments].keys.join(", ")
    end

    header["To"] = (opts[:to] || []).map { |p| p.email_ready_address }
    header["Cc"] = (opts[:cc] || []).map { |p| p.email_ready_address }
    header["Bcc"] = (opts[:bcc] || []).map { |p| p.email_ready_address }

    body = if opts[:message]
      forward_body_lines(opts[:message])
    elsif opts[:attachments]
      ["Note: #{opts[:attachments].size.pluralize 'attachment'}."]
    end

    super context, :header => header, :body => body, :attachments => opts[:attachments]
  end

  def self.spawn_nicely context, opts={}
    to = opts[:to] || if context.config.ask_for_to != false
      context.input.ask_for_contacts :people, "To: ", [opts[:to_default]] or return
    end

    cc = opts[:cc] || if context.config.ask_for_cc
      context.input.ask_for_contacts :people, "Cc: " or return
    end

    bcc = opts[:bcc] || if context.config.ask_for_bcc
      context.input.ask_for_contacts :people, "Bcc: " or return
    end

    attachment_hash = {}
    attachments = opts[:attachments] || []

    if(m = opts[:message])
      m.parse! context
      attachments += m.chunks.select { |c| c.is_a?(Chunk::Attachment) && !c.quotable? }
    end

    attachments.each do |c|
      mime_type = MIME::Types[c.content_type].first || MIME::Types["application/octet-stream"].first
      attachment_hash[c.filename] = RMail::Message.make_attachment c.content, mime_type.content_type, mime_type.encoding, c.filename
    end

    mode = ForwardMode.new context, :message => opts[:message], :to => to, :cc => cc, :bcc => bcc, :attachments => attachment_hash

    title = "Forwarding " + if opts[:message]
      opts[:message].subject
    elsif attachments
      attachment_hash.keys.join(", ")
    else
      "something"
    end

    context.screen.spawn title, mode
    mode.edit_message!
  end

protected

  def forward_body_lines m
    ["--- Begin forwarded message from #{m.from.mediumname} ---"] +
      m.quotable_header_lines + [""] + m.quotable_body_lines +
      ["--- End forwarded message ---"]
  end
end

end

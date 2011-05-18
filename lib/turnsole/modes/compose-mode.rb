module Turnsole

class ComposeMode < EditMessageMode
  def initialize context, opts={}
    @context = context
    header = {}
    header["From"] = (opts[:from] || context.accounts.default_account).email_ready_address
    header["To"] = opts[:to].map { |p| p.email_ready_address }.join(", ") if opts[:to]
    header["Cc"] = opts[:cc].map { |p| p.email_ready_address }.join(", ") if opts[:cc]
    header["Bcc"] = opts[:bcc].map { |p| p.email_ready_address }.join(", ") if opts[:bcc]
    header["Subject"] = opts[:subj] if opts[:subj]
    header["References"] = opts[:refs].map { |r| "<#{r}>" }.join(" ") if opts[:refs]
    header["In-Reply-To"] = opts[:replytos].map { |r| "<#{r}>" }.join(" ") if opts[:replytos]

    super context, :header => header, :body => (opts[:body] || [])
  end

  def edit_message!
    edited = super
    @context.screen.kill_buffer buffer unless edited
    edited
  end

  def self.spawn_nicely context, opts={}
    from = opts[:from] || if context.config.ask_for_from
      context.input.ask_for_account :account, "From (default #{context.accounts.default_account.email}): " or return
    end

    to = opts[:to] || if context.config.ask_for_to != false
      context.input.ask_for_contacts :people, "To: ", [opts[:to_default]] or return
    end

    cc = opts[:cc] || if context.config.ask_for_cc
      context.input.ask_for_contacts :people, "Cc: " or return
    end

    bcc = opts[:bcc] || if context.config.ask_for_bcc
      context.input.ask_for_contacts :people, "Bcc: " or return
    end

    subj = opts[:subj] || if context.config.ask_for_subject
      context.input.ask :subject, "Subject: " or return
    end

    mode = ComposeMode.new context, :from => from, :to => to, :cc => cc, :bcc => bcc, :subj => subj
    context.screen.spawn "New Message", mode
    mode.edit_message!
  end
end

end

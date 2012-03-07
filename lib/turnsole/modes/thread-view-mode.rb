module Turnsole

class ThreadViewMode < LineCursorMode
  include CanUndo
  include ModeHelper

  ## this holds all info we need to lay out a message
  class MessageLayout
    attr_accessor :top, :bot, :prev, :next, :depth, :width, :state, :color, :star_color, :orig_new, :toggled_state

    def initialize message
      @state = if message.fake?
        :closed
      elsif message.unread?
        :open
      else
        :closed
      end
      @toggled_state = false
    end
  end

  class ChunkLayout
    attr_accessor :state, :wrapped

    def initialize chunk
      @state = chunk.expandable? ? chunk.initial_state : :closed
      @wrapped = true
    end
  end

  DATE_FORMAT = "%B %e %Y %l:%M%p"
  INDENT_SPACES = 2 # how many spaces to indent child messages

  HookManager.register "detailed-headers", <<EOS
Add or remove headers from the detailed header display of a message.
Variables:
  message: The message whose headers are to be formatted.
  headers: A hash of header (name, value) pairs, initialized to the default
           headers.
Return value:
  None. The variable 'headers' should be modified in place.
EOS

  HookManager.register "publish", <<EOS
Executed when a message or a chunk is requested to be published.
Variables:
     chunk: Redwood::Message or Redwood::Chunk::* to be published.
Return value:
  None.
EOS

  register_keymap do |k|
    k.add :toggle_detailed_header, "Toggle detailed header", 'h'
    k.add :show_raw_message, "Show full message (raw form)", 'V'
    k.add :activate_chunk, "Expand/collapse or activate item", :enter
    k.add :expand_all_messages, "Expand/collapse all messages", 'E'
    k.add :edit_draft, "Edit draft", 'e'
    k.add :send_draft, "Send draft", 'y'
    k.add :edit_labels, "Edit or add labels for a thread", 'l'
    k.add :expand_all_quotes, "Expand/collapse all quotes in a message", 'o'
    k.add :jump_to_next_open, "Jump to next open message", 'n'
    k.add :jump_to_next_and_open, "Jump to next message and open", "\C-n"
    k.add :jump_to_prev_open, "Jump to previous open message", 'p'
    k.add :jump_to_prev_and_open, "Jump to previous message and open", "\C-p"
    k.add :align_current_message, "Align current message in buffer", 'z'
    k.add :toggle_starred, "Star or unstar message", '*'
    k.add :toggle_new, "Toggle unread/read status of message", 'N'
#    k.add :collapse_non_new_messages, "Collapse all but unread messages", 'N'
    k.add :reply, "Reply to a message", 'r'
    k.add :reply_all, "Reply to all participants of this message", 'G'
    k.add :forward, "Forward a message or attachment", 'f'
    k.add :bounce, "Bounce message to other recipient(s)", '!'
    k.add :alias, "Edit alias/nickname for a person", 'i'
    k.add :edit_as_new, "Edit message as new", 'D'
    k.add :save_to_disk, "Save message/attachment to disk", 's'
    k.add :save_all_to_disk, "Save all attachments to disk", 'A'
    k.add :publish, "Publish message/attachment using publish-hook", 'P'
    k.add :view_in_browser, "View message in browser", 'H'
    k.add :search, "Search for messages from particular people", 'S'
    k.add :compose, "Compose message to person", 'm'
    k.add :subscribe_to_list, "Subscribe to/unsubscribe from mailing list", "("
    k.add :unsubscribe_from_list, "Subscribe to/unsubscribe from mailing list", ")"
    k.add :pipe_message_or_attachment, "Pipe message or attachment to a shell command", '|'

    #k.add :archive_and_next, "Archive this thread, kill buffer, and view next", 'a'
    #k.add :delete_and_next, "Delete this thread, kill buffer, and view next", 'd'
    k.add :toggle_wrap, "Toggle wrapping of text", 'w'

    ## now the two-pass actions that allow us to skip the thread-index-mode
    k.add_multi "(a)rchive/(d)elete/mark as (s)pam/mark as u(N)read:", '.' do |kk|
      kk.add :archive_and_kill, "Archive this thread and kill buffer", 'a'
      kk.add :delete_and_kill, "Delete this thread and kill buffer", 'd'
      kk.add :spam_and_kill, "Mark this thread as spam and kill buffer", 's'
      kk.add :unread_and_kill, "Mark this thread as unread and kill buffer", 'N'
      kk.add :do_nothing_and_kill, "Just kill this buffer", '.'
    end

    k.add_multi "(a)rchive/(d)elete/mark as (s)pam/mark as u(N)read/do (n)othing:", ',' do |kk|
      kk.add :archive_and_next, "Archive this thread, kill buffer, and view next", 'a'
      kk.add :delete_and_next, "Delete this thread, kill buffer, and view next", 'd'
      kk.add :spam_and_next, "Mark this thread as spam, kill buffer, and view next", 's'
      kk.add :unread_and_next, "Mark this thread as unread, kill buffer, and view next", 'N'
      kk.add :do_nothing_and_next, "Kill buffer, and view next", 'n', ','
    end

    k.add_multi "(a)rchive/(d)elete/mark as (s)pam/mark as u(N)read/do (n)othing:", ']' do |kk|
      kk.add :archive_and_prev, "Archive this thread, kill buffer, and view previous", 'a'
      kk.add :delete_and_prev, "Delete this thread, kill buffer, and view previous", 'd'
      kk.add :spam_and_prev, "Mark this thread as spam, kill buffer, and view previous", 's'
      kk.add :unread_and_prev, "Mark this thread as unread, kill buffer, and view previous", 'N'
      kk.add :do_nothing_and_prev, "Kill buffer, and view previous", 'n', ']'
    end

    k.add :undo!, "Undo the previous action", 'u'
  end

  ## there are a couple important instance variables we hold to format
  ## the thread and to provide line-based functionality.
  ##
  ## - @layouts: a map from MessageSummary objects to MessageLayout objects
  ## - @chunk_layouts: a map from Chunks to ChunkLayouts.
  ## - @message_lines: a map from row #s to ## MessageSumary objects
  ## - @chunk_lines: a map from row #s to Chunk objects
  ## - @person_lines: a map from row #s to Person objects

  def initialize context, threadinfo, parent_mode
    super context
    @threadinfo = threadinfo
    @context = context

    ## loaded later from the server
    @thread = nil
    @messages = {}

    ## used for dispatch-and-next
    @parent_mode = parent_mode

    ## layout stuff
    @layouts = {}
    @chunk_layouts = {}

    ## the display
    @text = []
    @chunk_lines = []
    @message_lines = []
    @person_lines = []

    @context.ui.add_event_listener self
  end

  def num_lines; @text.length end
  def [] i; @text[i] end

  def load!
    receive_thread @context.client.load_thread(@threadinfo.thread_id)
  end

  def cleanup!
    @context.ui.remove_event_listener self
  end

  def toggle_wrap
    chunk = @chunk_lines[curpos] or return
    layout = @chunk_layouts[chunk] or return
    layout.wrapped = !layout.wrapped
    regen_text!
  end

  def draw_line ln, opts={}
    if ln == curpos
      super ln, :highlight => true
    else
      super
    end
  end

  def show_raw_message
    m = @message_lines[curpos] or return
    rawbody = @context.client.raw_message m.message_id
    mode = TextMode.new @context, rawbody.force_to_ascii
    @context.screen.spawn "Raw message", mode
  end

  def toggle_detailed_header
    m = @message_lines[curpos] or return
    @layouts[m].state = (@layouts[m].state == :detailed ? :open : :detailed)

    get_message_from_messageinfo m # ensure we have it
    regen_text!
  end

  def reply type_arg=nil
    messageinfo = @message_lines[curpos] or return
    message = get_message_from_messageinfo messageinfo
    mode = ReplyMode.new @context, message, type_arg
    @context.screen.spawn "Reply to #{message.subject}", mode
  end

  def reply_all; reply :all; end

  def subscribe_to_list
    m = @message_lines[curpos] or return
    m = @messages[m.message_id] or return
    if (m.list_subscribe || "") =~ /<mailto:(.*?)(\?subject=(.*?))?>/
      ComposeMode.spawn_nicely @context, :from => @context.accounts.account_for(m.recipient_email), :cc => [], :bcc => [], :to => [Person.from_string($1)], :subj => ($3 || "subscribe")
    else
      @context.screen.minibuf.flash "Couldn't find a List-Subscribe header for this message."
    end
  end

  def unsubscribe_from_list
    m = @message_lines[curpos] or return
    m = @messages[m.message_id] or return
    if (m.list_unsubscribe || "") =~ /<mailto:(.*?)(\?subject=(.*?))?>/
      ComposeMode.spawn_nicely @context, :from => @context.accounts.account_for(m.recipient_email), :cc => [], :bcc => [], :to => [Person.from_string($1)], :subj => ($3 || "unsubscribe")
    else
      @context.screen.minibuf.flash "Couldn't find a List-Unsubscribe header for this message."
    end
  end

  def forward
    if(chunk = @chunk_lines[curpos]) && chunk.is_a?(Chunk::Attachment)
      ForwardMode.spawn_nicely @context, :attachments => [chunk]
    elsif(messageinfo = @message_lines[curpos])
      message = get_message_from_messageinfo messageinfo
      ForwardMode.spawn_nicely @context, :message => message
    end
  end

  def bounce
    m = @message_lines[curpos] or return
    to = @context.input.ask_for_contacts(:people, "Bounce To: ") or return
    bt = to.size > 1 ? "#{to.size} recipients" : to.first.email

    if @context.input.ask_yes_or_no "Really bounce to #{bt}?"
      @context.screen.minibuf.with_message "Bouncing message..." do
        rawbody = @context.client.raw_message m.message_id
        @context.client.bounce_message rawbody, :force_recipients => to.map { |p| p.email }
        @context.screen.minibuf.flash "Bounced!"
      end
    end
  end

  #include CanAliasContacts
  def alias
    p = @person_lines[curpos] or return
    alias_contact p
    update
  end

  def search
    p = @person_lines[curpos] or return
    SearchResultsMode.spawn_from_query @context, p.email
  end

  def compose
    p = @person_lines[curpos]
    if p
      ComposeMode.spawn_nicely @context, :to_default => p.email_ready_address
    else
      ComposeMode.spawn_nicely @context
    end
  end

  def edit_labels
    old_labels = @threadinfo.labels
    speciall = @context.labels.reserved_labels
    keepl, modifyl = old_labels.partition { |t| speciall.member? t }.map { |x| Set.new x }

    user_labels = @context.input.ask_for_labels :label, "Labels for thread: ", modifyl, @hidden_labels
    return unless user_labels

    modify_thread_labels [@threadinfo], [keepl + user_labels]
  end

  def toggle_starred
    m = @message_lines[curpos] or return
    toggle_state m, "starred"
  end

  def toggle_new
    m = @message_lines[curpos] or return
    toggle_state m, "unread"
  end

  def toggle_state m, state
    new_state = if m.has_state? state
      m.state - [state]
    else
      m.state + [state]
    end

    messageinfo = @context.client.set_state! m.message_id, new_state
    @context.ui.broadcast :message, messageinfo

    ## threadinfo may have changed as well
    threadinfo = @context.client.threadinfo @threadinfo.thread_id
    @context.ui.broadcast :thread, threadinfo
  end

  def handle_message_update new_message
    @thread.each_with_index do |(message, depth), i|
      if message.message_id == new_message.message_id
        @thread[i] = [new_message, depth]
        @layouts[new_message] = @layouts[message] # hacky
        @layouts.delete message # hacky
        regen_text!
        break
      end
    end
  end

  def handle_thread_update new_thread
    if new_thread.thread_id == @threadinfo.thread_id
      @threadinfo = new_thread
      regen_text!
    end
  end

  ## called when someone presses enter when the cursor is highlighting
  ## a chunk. for expandable chunks (including messages) we toggle
  ## open/closed state; for viewable chunks (like attachments) we
  ## view.
  def activate_chunk
    chunk = @chunk_lines[curpos] or return
    if chunk.is_a? Chunk::Text
      ## if the cursor is over a text region, expand/collapse the
      ## entire message
      chunk = @message_lines[curpos]
    end

    layout = if chunk.is_a?(MessageSummary)
      @layouts[chunk]
    elsif chunk.expandable?
      @chunk_layouts[chunk]
    end

    if layout
      layout.state = (layout.state != :closed ? :closed : :open)

      ## if we're opening an inlineable attachment, start downlading it in the background
      if (layout.state == :open) && chunk.is_a?(Chunk::Attachment)
        chunk.load_content_async! :on_success => lambda { regen_text! }
      end

      load_any_open_messages!
      regen_text!
    elsif chunk.viewable?
      view chunk
    end

    if chunk.is_a?(Message) && @context.config.jump_to_open_message
      jump_to_message chunk
      jump_to_next_open if layout.state == :closed
    end
  end

  def edit_as_new
    m = @message_lines[curpos] or return
    m = get_message_from_messageinfo m
    mode = ComposeMode.new(@context, :body => m.quotable_body_lines, :to => m.to, :cc => m.cc, :subj => m.subject, :bcc => m.bcc, :refs => m.refs, :reply_to => m.reply_to)
    @context.screen.spawn "edit as new", mode
    mode.edit_message!
  end

  def save_to_disk
    chunk = @chunk_lines[curpos] or return

    default_dir = @context.config.default_attachment_save_dir || ENV["HOME"]
    case chunk
    when Chunk::Attachment
      default_fn = File.expand_path File.join(default_dir, chunk.filename)
      fn = @context.input.ask_for_filename :filename, "Save attachment to file: ", default_fn
      return unless fn
      @context.ui.save_to_file(fn) { |f| f.write chunk.content }
    else
      m = @message_lines[curpos]
      fn = @context.input.ask_for_filename :filename, "Save message to file: "
      return unless fn

      rawbody = @context.client.raw_message m.message_id
      @context.ui.save_to_file(fn) { |s| s.write rawbody }
    end
  end

  def save_all_to_disk
    m = @message_lines[curpos] or return
    message = get_message_from_messageinfo m
    default_dir = @context.config.default_attachment_save_dir || ENV["HOME"]
    dir = @context.input.ask_for_directory :directory, "Save all attachments to directory: ", default_dir
    return unless dir

    num = 0
    num_errors = 0
    message.chunks.each do |chunk|
      next unless chunk.is_a?(Chunk::Attachment)
      fn = File.join dir, chunk.filename
      num_errors += 1 unless @context.ui.save_to_file(fn, false) { |f| f.write chunk.content }
      num += 1
    end

    @context.screen.minibuf.flash(if num == 0
      "No attachments found!"
    else
      if num_errors == 0
        "Wrote #{num.pluralize 'attachment'} to #{dir}."
      else
        "Wrote #{(num - num_errors).pluralize 'attachment'} to #{dir}; couldn't write #{num_errors} of them (see log)."
      end
    end)
  end

  def view_in_browser
    m = @message_lines[curpos] or return
    message = @context.client.load_message m.message_id, "text/html"
    message.parse! @context

    file, attachment_files = message.dump_to_html! @context, "turnsole.view-in-browser"
    if @context.hooks.enabled? "view-in-browser"
      @context.hooks.run "view-in-browser", :filename => file.path
    else
      cmd = case RUBY_PLATFORM
      when /darwin/
        "open #{file.path}"
      else
        "xdg-open file://#{file.path}"
      end

      success = @context.ui.shell_out "#{cmd} > /dev/null 2> /dev/null"
      unless success
        @context.screen.minibuf.flash "Couldn't view in browser. Try writing a view-in-browser hook."
      end
    end
    sleep 3 # lame hack... try and give enough time before unlinking files
    ([file] + attachment_files).each { |f| File.unlink f.path }
  end

  def publish
    chunk = @chunk_lines[curpos] or return
    if @context.hooks.enabled? "publish"
      @context.hooks.run "publish", :chunk => chunk
    else
      @context.screen.minibuf.flash "Publishing hook not defined."
    end
  end

  def edit_draft
    message_summary = @message_lines[curpos] or return
    if message_summary.draft?
      mode = ResumeMode.new message
      @context.screen.spawn "Edit message", mode
      @context.screen.kill_buffer buffer
      mode.edit_message
    else
      @context.screen.minibuf.flash "Not a draft message!"
    end
  end

  def send_draft
    m = @message_lines[curpos] or return
    if m.is_draft?
      mode = ResumeMode.new m
      BufferManager.spawn "Send message", mode
      BufferManager.kill_buffer self.buffer
      mode.send_message
    else
      BufferManager.flash "Not a draft message!"
    end
  end

  def jump_to_first_open
    m = @message_lines[0] or return
    if @layouts[m].state != :closed
      jump_to_message m#, true
    else
      jump_to_next_open #true
    end
  end

  def jump_to_next_and_open
    return continue_search_in_buffer if in_search? # err.. don't know why im doing this

    m = (curpos ... @message_lines.length).argfind { |i| @message_lines[i] }
    return unless m

    if @layouts[m].toggled_state == true
      @layouts[m].state = :closed
      @layouts[m].toggled_state = false
      update
    end

    nextm = @layouts[m].next
    if @layouts[nextm].state == :closed
      @layouts[nextm].state = :open
      @layouts[nextm].toggled_state = true
    end

    jump_to_message nextm if nextm

    update if @layouts[nextm].toggled_state
  end

  def jump_to_next_open force_alignment=nil
    return continue_search_in_buffer if in_search? # hack: allow 'n' to apply to both operations
    m = (curpos ... @message_lines.length).argfind { |i| @message_lines[i] }
    return unless m
    while nextm = @layouts[m].next
      break if @layouts[nextm].state != :closed
      m = nextm
    end
    jump_to_message nextm, force_alignment if nextm
  end

  def align_current_message
    m = @message_lines[curpos] or return
    jump_to_message m, true
  end

  def jump_to_prev_and_open force_alignment=nil
    m = (0 .. curpos).to_a.reverse.argfind { |i| @message_lines[i] }
    return unless m

    if @layouts[m].toggled_state == true
      @layouts[m].state = :closed
      @layouts[m].toggled_state = false
      update
    end

    nextm = @layouts[m].prev
    if @layouts[nextm].state == :closed
      @layouts[nextm].state = :open
      @layouts[nextm].toggled_state = true
    end

    jump_to_message nextm if nextm
    update if @layouts[nextm].toggled_state
  end

  def jump_to_prev_open
    m = (0 .. curpos).to_a.reverse.argfind { |i| @message_lines[i] } # bah, .to_a
    return unless m
    ## jump to the top of the current message if we're in the body;
    ## otherwise, to the previous message

    top = @layouts[m].top
    if curpos == top
      while(prevm = @layouts[m].prev)
        break if @layouts[prevm].state != :closed
        m = prevm
      end
      jump_to_message prevm if prevm
    else
      jump_to_message m
    end
  end

  def jump_to_message m, force_alignment=false
    l = @layouts[m]

    ## boundaries of the message
    message_left = l.depth * INDENT_SPACES
    message_right = message_left + l.width

    ## calculate leftmost colum
    left = if force_alignment # force mode: align exactly
      message_left
    else # regular: minimize cursor movement
      ## leftmost and rightmost are boundaries of all valid left-column
      ## alignments.
      leftmost = [message_left, message_right - buffer.content_width + 1].min
      rightmost = message_left
      leftcol.clamp(leftmost, rightmost)
    end

    jump_to_line l.top    # move vertically
    jump_to_col left      # move horizontally
    set_cursor_pos l.top  # set cursor pos
  end

  def expand_all_messages
    @global_message_state ||= :closed
    @global_message_state = (@global_message_state == :closed ? :open : :closed)
    @layouts.each { |m, l| l.state = @global_message_state }
    regen_text!
    load_any_open_messages!
  end

  def collapse_non_new_messages
    @layouts.each { |m, l| l.state = l.orig_new ? :open : :closed }
    regen_text!
  end

  def expand_all_quotes
    m = @message_lines[curpos] or return
    message = @messages[m.message_id] or return

    quotes = message.chunks.select { |c| (c.is_a?(Chunk::Quote) || c.is_a?(Chunk::Signature)) && c.lines.length > 1 }
    numopen = quotes.inject(0) { |s, c| s + (@chunk_layouts[c].state == :open ? 1 : 0) }
    newstate = numopen > quotes.length / 2 ? :closed : :open
    quotes.each { |c| @chunk_layouts[c].state = newstate }
    regen_text!
  end

  ## two-pass actions
  %w(archive spam delete unread do_nothing).each do |action|
    %w(kill next prev).each do |finisher|
      define_method("#{action}_and_#{finisher}") { perform_two_pass_action action, finisher }
    end
  end

  def perform_two_pass_action action, finisher
    case action
    when "archive"; apply_label_change "archiving one thread", (@threadinfo.labels - ["inbox"])
    when "spam"; apply_label_change "marking one thread as spam", (@threadinfo.labels + ["spam"])
    when "delete"; apply_label_change "deleting one thread", (@threadinfo.labels + ["deleted"])
    when "unread"; apply_label_change "marking one thread as unread", (@threadinfo.labels + ["unread"])
    when "do_nothing"; # do nothing
    end

    case finisher
    when "next"; @parent_mode.launch_next_thread_after @threadinfo
    when "prev"; @parent_mode.launch_prev_thread_before @threadinfo
    end

    @context.screen.kill_buffer_safely buffer
  end

  def apply_label_change name, newlabels
    oldlabels = @threadinfo.labels
    modify_thread_labels [@threadinfo], [newlabels]
    to_undo(name) { modify_thread_labels [@threadinfo], [oldlabels] }
  end

  def pipe_message_or_attachment
    chunk = @chunk_lines[curpos]
    message = @message_lines[curpos]

    ## if the cursor isn't on an attachment, use the whole message
    if chunk.nil? || !chunk.is_a?(Chunk::Attachment)
      chunk = nil
      message = @messages[message.message_id]
    end

    return unless chunk || message

    question = "Pipe #{chunk ? "attachment" : "raw message"} to command: "

    command = @context.input.ask :shell, question
    return if command.nil? || command.empty?

    if chunk
      pipe_chunk chunk, command
    else
      pipe_message message, command
    end
  end

  ## download the raw message, then pipe it
  def pipe_message message, command
    rawbody = @context.client.raw_message message.message_id
    output = @context.ui.pipe_to_process(command) do |stream|
      stream.write rawbody
    end
    handle_pipe_output command, output
  end

  ## pipe the chunk (we already have the content)
  def pipe_chunk chunk, command
    content = chunk.content
    output = @context.ui.pipe_to_process(command) do |stream|
      stream.write content
    end

    handle_pipe_output command, output
  end

  def handle_pipe_output command, output
    if output
      output = output.force_to_ascii
      @context.screen.spawn "Output of '#{command}'", TextMode.new(@context, output.force_to_ascii)
    else
      @context.screen.minibuf.flash "'#{command}' done!"
    end
  end

private

  def receive_thread thread
    return unless buffer # die unless i'm still actually being displayed

    @thread = thread
    @initially_unread_messages = Set.new @thread.select { |m, depth| m.unread? }.map { |m, d| m }
    latest = init_message_layout!
    regen_text!
    #jump_to_message latest # nah, don't like this
    load_any_open_messages!
  end

  def load_any_open_messages!
    open = @thread.select { |m, depth| !m.fake? && @messages[m.message_id].nil? && @layouts[m].state != :closed }
    num_loaded = 0
    open.each do |m, depth|
      break unless buffer # hack -- if the window's been closed, don't bother to continue downloading stuff
      next if @messages[m.message_id] # we alrady have it
      num_loaded += 1
      get_message_from_messageinfo m
      regen_text!
    end

    ## since we've potentially changed some message state, let's rebroadcast
    ## the thread state out to everyone
    if num_loaded > 0
      @context.client.async_load_threadinfo @threadinfo.thread_id, :on_success => lambda { |threadinfo| @context.ui.broadcast :thread, threadinfo }
    end
  end

  ## load message if necessary
  def get_message_from_messageinfo m
    return nil if m.fake?
    @messages[m.message_id] ||= begin
      message = @context.client.load_message m.message_id
      message.parse! @context
      message.chunks.each { |c| @chunk_layouts[c] = ChunkLayout.new c }

      message.state -= ["unread"]
      @context.client.async_set_state! message.message_id, message.state
      @context.ui.broadcast :message_state, message.message_id

      message
    end
  end

  def init_message_layout!
    earliest, latest = nil, nil
    latest_date = nil
    altcolor = false

    @thread.each do |message, depth|
      @layouts[message] = MessageLayout.new message
      @layouts[message].color = altcolor ? :alternate_patina : :message_patina
      @layouts[message].star_color = altcolor ? :alternate_starred_patina : :starred_patina
      altcolor = !altcolor

      unless message.fake?
        earliest ||= message
        if latest_date.nil? || (message.date > latest_date)
          latest_date = message.date
          latest = message
        end
      end
    end

    @layouts[latest].state = :open if @layouts[latest].state == :closed
    @layouts[earliest].state = :detailed if earliest.unread? || @thread.size == 1

    latest
  end

  ## generate the actual content lines. we accumulate everything into @text,
  ## we set @chunk_lines and @message_lines, and update @layouts.
  def regen_text!
    return unless buffer # die unless i'm still actually being displayed

    @chunk_lines = []
    @text = []
    @message_lines = []
    @person_lines = []

    prevm = nil
    @thread.each do |message, depth|
      layout = @layouts[message]

      ## is this still necessary?
      #next unless @layouts[m].state # skip discarded drafts

      text = message_patina_lines message, depth, layout, @text.length

      layout.top = @text.length
      layout.bot = @text.length + text.length # potentially updated below
      layout.prev = prevm
      layout.next = nil
      layout.depth = depth
      # layout.state is unmodified here
      layout.width = 0 # updated below
      @layouts[layout.prev].next = message if layout.prev

      ## record what each lines points to (so that when the user does something
      ## with the line cursor, we know what he's acting on)
      (0 ... text.length).each do |i|
        @chunk_lines[@text.length + i] = message
        @message_lines[@text.length + i] = message
        #lw = text[i].flatten.select { |x| x.is_a? String }.map { |x| x.display_width }.sum
      end

      @text += text
      prevm = message

      if layout.state != :closed
        actual_message = @messages[message.message_id]
        chunks = (actual_message ? actual_message.chunks : []) # no chunks if we haven't loaded it yet
        chunks.each do |chunk|
          layout = @chunk_layouts[chunk]

          text = chunk_to_lines chunk, layout, @text.length, depth
          (0 ... text.length).each do |i|
            @chunk_lines[@text.length + i] = chunk
            @message_lines[@text.length + i] = message
            #lw = text[i].flatten.select { |x| x.is_a? String }.map { |x| x.display_width }.sum - (depth * INDENT_SPACES)
            #l.width = lw if lw > l.width
          end
          @text += text
        end

        @layouts[message].bot = @text.length
      end
    end

    buffer.mark_dirty!
  end

  def message_patina_lines message, depth, layout, start
    prefix = " " * INDENT_SPACES * depth

    ## shortcut for pseudo-roots
    return [[[:missing_message, prefix + "<an unreceived message>"]]] if message.fake?

    prefix_widget = [layout.color, prefix]

    open_widget = [layout.color, (layout.state == :closed ? "+ " : "- ")]
    new_widget = [layout.color, (message.unread? ? "N" : " ")]
    starred_widget = message.starred? ? [layout.star_color, "*"] : [layout.color, " "]
    attach_widget = [layout.color, (message.attachment? ? "@" : " ")]

    full_message = @messages[message.message_id] # can be nil if not yet loaded

    @person_lines[start] = message.from
    patina = case layout.state
    when :closed, :open
      from = message.from.nil? ? "?" : message.from.mediumname
      to = case message.to.size
        when 0; "no one"
        when 1; message.to.first.mediumname
        when 2; message.to.first.mediumname + " and one other"
        else; message.to.first.mediumname + " and #{message.to.size - 1} others"
      end

      [[prefix_widget, open_widget, new_widget, attach_widget, starred_widget,
        [layout.color,
        "#{from} to #{to}, #{message.date.to_nice_s} (#{message.date.to_nice_distance_s})  #{message.snippet}"]]]

    when :detailed
      from_line = [[prefix_widget, open_widget, new_widget, attach_widget, starred_widget,
          [layout.color, "From: #{format_person message.from}"]]]

      addressee_lines = []
      unless full_message.nil?
        unless full_message.to.empty?
          full_message.to.each_with_index { |p, i| @person_lines[start + addressee_lines.length + from_line.length + i] = p }
          addressee_lines += format_person_list "   To: ", full_message.to
        end
        unless full_message.cc.empty?
          full_message.cc.each_with_index { |p, i| @person_lines[start + addressee_lines.length + from_line.length + i] = p }
          addressee_lines += format_person_list "   Cc: ", full_message.cc
        end
        unless full_message.bcc.empty?
          full_message.bcc.each_with_index { |p, i| @person_lines[start + addressee_lines.length + from_line.length + i] = p }
          addressee_lines += format_person_list "   Bcc: ", full_message.bcc
        end
      end

      headers = []
      headers << ["Date", "#{message.date.strftime DATE_FORMAT} (#{message.date.to_nice_distance_s})"]
      headers << ["Subject", message.subject]

      unless @threadinfo.labels.empty?
        headers << ["Labels", @threadinfo.labels.sort.join(', ')]
      end
      #if parent
        #headers["In reply to"] = "#{parent.from.mediumname}'s message of #{parent.date.strftime DATE_FORMAT}"
      #end

      @context.hooks.run "detailed-headers", :message => full_message, :headers => headers if full_message

      from_line + (addressee_lines + headers.map { |k, v| "   #{k}: #{v}" }).map { |l| [[layout.color, prefix + "  " + l]] }
    end

    if layout.state != :closed
      patina += if message.draft?
        [[[:draft_notification, prefix + " >>> This message is a draft. Hit 'e' to edit, 'y' to send. <<<"]]]
      elsif full_message.nil?
        [[[:default, prefix + "loading..."]]]
      else
        []
      end
    end

    patina
  end

  def format_person_list prefix, people
    ptext = people.map { |p| format_person p }
    pad = " " * prefix.display_width
    [prefix + ptext.first + (ptext.length > 1 ? "," : "")] +
      ptext[1 .. -1].map_with_index do |e, i|
        pad + e + (i == ptext.length - 1 ? "" : ",")
      end
  end

  def format_person p
    p.nil? ? "?" : p.longname# + (ContactManager.is_aliased_contact?(p) ? " (#{ContactManager.alias_for p})" : "")
  end

  ## todo: check arguments on this overly complex function
  def chunk_to_lines chunk, layout, start, depth
    prefix = " " * INDENT_SPACES * depth

    if chunk.inlineable?
      lines = chunk.lines
      if layout.wrapped
        config_width = 78 # TODO figure out what to do with this
        #width = config_width.clamp(0, buffer.content_width)
        width = buffer.content_width.clamp(0, config_width)
        lines = lines.map { |l| l.chomp.wrap width }.flatten
      end
      lines.map { |line| [[chunk.color, "#{prefix}#{line}"]] }
    elsif chunk.expandable?
      case layout.state
      when :closed
        [[[chunk.patina_color, "#{prefix}+ #{chunk.patina_text}"]]]
      when :open
        [[[chunk.patina_color, "#{prefix}- #{chunk.patina_text}"]]] + chunk.lines.map { |line| [[chunk.color, "#{prefix}#{line}"]] }
      end
    else
      [[[chunk.patina_color, "#{prefix}x #{chunk.patina_text}"]]]
    end
  end

  def view chunk
    say_id = @context.screen.minibuf.say "Viewing #{chunk.content_type} attachment..."
    begin
      chunk.view! or begin
        @context.screen.minibuf.flash "Couldn't execute view command, viewing as text."
        @context.screen.spawn "Attachment: #{chunk.filename}", TextMode.new(chunk.to_s.force_to_ascii, chunk.filename)
      end
    ensure
      @context.screen.minibuf.clear say_id
    end
  end
end

end

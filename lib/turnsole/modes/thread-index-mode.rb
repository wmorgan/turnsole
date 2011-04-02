require 'set'

module Turnsole

class ThreadIndexMode < LineCursorMode
  include LogsStuff
  include CanUndo

  DATE_WIDTH = Time::TO_NICE_S_MAX_LEN
  MIN_FROM_WIDTH = 15
  FROM_WIDTH_PORTION = 0.2
  LOAD_MORE_THREAD_NUM = 20

  ## we never show these directly because we change the display instead.  these
  ## are exactly those set of labels that Heliotrope generates from message
  ## state.
  ALWAYS_HIDDEN_LABELS = %w(unread inbox attachment draft)

  HookManager.register "index-mode-size-widget", <<EOS
Generates the per-thread size widget for each thread.
Variables:
  thread: The message thread to be formatted.
EOS

  HookManager.register "index-mode-date-widget", <<EOS
Generates the per-thread date widget for each thread.
Variables:
  thread: The message thread to be formatted.
EOS

  HookManager.register "mark-as-spam", <<EOS
This hook is run when a thread is marked as spam
Variables:
  thread: The message thread being marked as spam.
EOS

  register_keymap do |k|
    k.add :load_threads, "Load #{LOAD_MORE_THREAD_NUM} more threads", 'M'
    k.add_multi "Load all threads (! to confirm) :", '!' do |kk|
      kk.add :load_all_threads, "Load all threads (may list a _lot_ of threads)", '!'
    end
    k.add :cancel_search, "Cancel current search", :ctrl_g
    k.add :reload, "Refresh view", '@'
    k.add :toggle_archived, "Toggle archived status", 'a'
    k.add :toggle_starred, "Star or unstar all messages in thread", '*'
    k.add :toggle_new, "Toggle new/read status of all messages in thread", 'N'
    k.add :edit_labels, "Edit or add labels for a thread", 'l'
    k.add :edit_message, "Edit message (drafts only)", 'e'
    k.add :toggle_spam, "Mark/unmark thread as spam", 'S'
    k.add :toggle_deleted, "Delete/undelete thread", 'd'
    k.add :kill, "Kill thread (never to be seen in inbox again)", '&'
    k.add :flush_index, "Flush all changes now", '$'
    k.add :jump_to_next_new, "Jump to next new thread", :tab
    k.add :reply, "Reply to latest message in a thread", 'r'
    k.add :reply_all, "Reply to all participants of the latest message in a thread", 'G'
    k.add :forward, "Forward latest message in a thread", 'f'
    k.add :toggle_tagged, "Tag/untag selected thread", 't'
    k.add :toggle_tagged_all, "Tag/untag all threads", 'T'
    k.add :tag_matching, "Tag matching threads", 'g'
    k.add :apply_to_tagged, "Apply next command to all tagged threads", '+', '='
    k.add :join_threads, "Force tagged threads to be joined into the same thread", '#'
    k.add :undo!, "Undo the previous action", 'u'
  end

  attr_reader :query
  def initialize context, query, hidden_labels=[]
    super()
    @context = context
    @query = query
    @hidden_labels = Set.new hidden_labels

    @threads = []
    @text = []
    @lines = {}

    @date_width = DATE_WIDTH

    @size_widget_width = nil
    @size_widgets = []
    @date_widget_width = nil
    @date_widgets = []
    @tags = Tagger.new self, context

    @context.ui.add_event_listener self

    ## keep track of the last size we had when we scheduled more threads to be
    ## loaded, so that we don't duplicate the request. duplication can happen
    ## when the cursor moves down faster than the network responds.
    @last_schedule_more_size = -1
    to_load_more { |size| schedule_more size }
  end

  def cleanup!
    @context.ui.remove_event_listener self
  end

  def load!
    schedule_more(buffer.content_height * 2)
  end

  def num_lines; @text.length end
  def [] i; @text[i] end

  def log; @context.log end

  def schedule_more num_threads
    return if @last_schedule_more_size == @threads.size
    @context.client.search(query, num_threads, @threads.size) { |threads| receive_threads threads }
    @last_schedule_more_size = @threads.size
  end

  def reload
    @threads = []
    @text = []
    @buffer.mark_dirty!
    schedule_more buffer.content_height
  end

  def receive_threads threads
    return unless buffer # die unless i'm still actually being displayed
    old_cursor_thread = @threads[curpos]

    info "got #{threads.size} more threads"
    @threads = (@threads + threads).uniq_in_order_by { |t| t.thread_id }
    regen_text!
    new_cursor_thread = @threads.index old_cursor_thread

    set_cursor_pos new_cursor_thread if new_cursor_thread
  end

  def regen_text!
    @size_widgets = @threads.map { |t| size_widget_for_thread t }
    @date_widgets = @threads.map { |t| date_widget_for_thread t }

    @size_widget_width = @size_widgets.max_of { |w| w.display_width }
    @date_widget_width = @date_widgets.max_of { |w| w.display_width }

    @text = (0 ... @threads.size).map { |i| text_for_thread_at i }
    @lines = {}; @threads.each_with_index { |t, i| @lines[t] = i }
    buffer.mark_dirty!
  end

  ## open up a thread view window
  def select thread=nil # nil for cursor thread
    thread ||= cursor_thread
    return unless thread

    mode = ThreadViewMode.new thread, self, @context
    @context.screen.spawn thread.subject, mode
    mode.load!
  end

  def multi_select threads
    threads.each { |t| select t }
  end

  ## these two methods are called by thread-view-modes when the user
  ## wants to view the previous/next thread without going back to
  ## index-mode. we update the cursor as a convenience.
  def launch_next_thread_after thread, &b
    launch_another_thread thread, 1, &b
  end

  def launch_prev_thread_before thread, &b
    launch_another_thread thread, -1, &b
  end

  def launch_another_thread thread, direction, &b
    l = @lines[thread] or return
    target_l = l + direction
    if (target_l >= 0) && (target_l < @threads.length)
      t = @threads[target_l]
      set_cursor_pos target_l
      select t, b
    elsif b # no next thread. call the block anyways
      b.call
    end
  end

  def handle_thread_update sender, thread_id, what
    t = @threads.find { |t| t.thread_id == thread_id } or return
    l = @lines[t] or return
    what.each { |field, v| t.send "#{field}=", v }
    update_text_for_line! l
  end

  if false
    def handle_labeled_update sender, m
      if(t = thread_containing(m))
        l = @lines[t] or return
        update_text_for_line! l
      elsif is_relevant?(m)
        add_or_unhide m
      end
    end

    def handle_simple_update sender, message_id, thread_id
      t = @threads.find { |t| t.thread_id == thread_id } or return
      l = @lines[t] or return
      update_text_for_line! l
    end

    %w(read unread archived starred unstarred).each do |state|
      define_method "handle_#{state}_update" do |*a|
        handle_simple_update(*a)
      end
    end

    ## overwrite me!
    def is_relevant? m; false; end

    def handle_added_update sender, m
      add_or_unhide m
      BufferManager.draw_screen
    end

    def handle_single_message_deleted_update sender, m
      @ts_mutex.synchronize do
        return unless @ts.contains? m
        @ts.remove_id m.id
      end
      update
    end

    def handle_deleted_update sender, m
      t = @ts_mutex.synchronize { @ts.thread_for m }
      return unless t
      hide_thread t
      update
    end

    def handle_spammed_update sender, m
      t = @ts_mutex.synchronize { @ts.thread_for m }
      return unless t
      hide_thread t
      update
    end

    def handle_undeleted_update sender, m
      add_or_unhide m
    end
  end

  def edit_message
    return unless(t = cursor_thread)
    message, *crap = t.find { |m, *o| m.has_label? :draft }
    if message
      mode = ResumeMode.new message
      BufferManager.spawn "Edit message", mode
    else
      BufferManager.flash "Not a draft message!"
    end
  end

  ## returns an undo lambda
  def actually_toggle_starred t
    pos = curpos
    if t.has_label? :starred # if ANY message has a star
      t.remove_label :starred # remove from all
      UpdateManager.relay self, :unstarred, t.first
      lambda do
        t.first.add_label :starred
        UpdateManager.relay self, :starred, t.first
        regen_text
      end
    else
      t.first.add_label :starred # add only to first
      UpdateManager.relay self, :starred, t.first
      lambda do
        t.remove_label :starred
        UpdateManager.relay self, :unstarred, t.first
        regen_text
      end
    end
  end

  def toggle_starred
    t = cursor_thread or return
    undo = actually_toggle_starred t
    UndoManager.register "toggling thread starred status", undo, lambda { Index.save_thread t }
    update_text_for_line! curpos
    cursor_down
    Index.save_thread t
  end

  def multi_toggle_starred threads
    UndoManager.register "toggling #{threads.size.pluralize 'thread'} starred status",
      threads.map { |t| actually_toggle_starred t },
      lambda { threads.each { |t| Index.save_thread t } }
    regen_text
    threads.each { |t| Index.save_thread t }
  end

  ## returns an undo lambda
  def actually_toggle_archived t
    thread = t
    pos = curpos
    if t.has_label? :inbox
      t.remove_label :inbox
      UpdateManager.relay self, :archived, t.first
      lambda do
        thread.apply_label :inbox
        update_text_for_line! pos
        UpdateManager.relay self,:unarchived, thread.first
      end
    else
      t.apply_label :inbox
      UpdateManager.relay self, :unarchived, t.first
      lambda do
        thread.remove_label :inbox
        update_text_for_line! pos
        UpdateManager.relay self, :unarchived, thread.first
      end
    end
  end

  ## returns an undo lambda
  def actually_toggle_spammed t
    thread = t
    if t.has_label? :spam
      t.remove_label :spam
      add_or_unhide t.first
      UpdateManager.relay self, :unspammed, t.first
      lambda do
        thread.apply_label :spam
        self.hide_thread thread
        UpdateManager.relay self,:spammed, thread.first
      end
    else
      t.apply_label :spam
      hide_thread t
      UpdateManager.relay self, :spammed, t.first
      lambda do
        thread.remove_label :spam
        add_or_unhide thread.first
        UpdateManager.relay self,:unspammed, thread.first
      end
    end
  end

  ## returns an undo lambda
  def actually_toggle_deleted t
    if t.has_label? :deleted
      t.remove_label :deleted
      add_or_unhide t.first
      UpdateManager.relay self, :undeleted, t.first
      lambda do
        t.apply_label :deleted
        hide_thread t
        UpdateManager.relay self, :deleted, t.first
      end
    else
      t.apply_label :deleted
      hide_thread t
      UpdateManager.relay self, :deleted, t.first
      lambda do
        t.remove_label :deleted
        add_or_unhide t.first
        UpdateManager.relay self, :undeleted, t.first
      end
    end
  end

  def toggle_archived
    t = cursor_thread or return
    undo = actually_toggle_archived t
    UndoManager.register "deleting/undeleting thread #{t.first.id}", undo, lambda { update_text_for_line! curpos },
                         lambda { Index.save_thread t }
    update_text_for_line! curpos
    Index.save_thread t
  end

  def multi_toggle_archived threads
    undos = threads.map { |t| actually_toggle_archived t }
    UndoManager.register "deleting/undeleting #{threads.size.pluralize 'thread'}", undos, lambda { regen_text },
                         lambda { threads.each { |t| Index.save_thread t } }
    regen_text
    threads.each { |t| Index.save_thread t }
  end

  def toggle_new
    t = cursor_thread or return
    t.toggle_label :unread
    update_text_for_line! curpos
    cursor_down
    Index.save_thread t
  end

  def multi_toggle_new threads
    threads.each { |t| t.toggle_label :unread }
    regen_text
    threads.each { |t| Index.save_thread t }
  end

  def multi_toggle_tagged threads
    @mutex.synchronize { @tags.drop_all_tags }
    regen_text
  end

  def join_threads
    ## this command has no non-tagged form. as a convenience, allow this
    ## command to be applied to tagged threads without hitting ';'.
    @tags.apply_to_tagged :join_threads
  end

  def multi_join_threads threads
    @ts.join_threads threads or return
    threads.each { |t| Index.save_thread t }
    @tags.drop_all_tags # otherwise we have tag pointers to invalid threads!
    update
  end

  def jump_to_next_new
    n = @mutex.synchronize do
      ((curpos + 1) ... lines).find { |i| @threads[i].has_label? :unread } ||
        (0 ... curpos).find { |i| @threads[i].has_label? :unread }
    end
    if n
      ## jump there if necessary
      jump_to_line n unless n >= topline && n < botline
      set_cursor_pos n
    else
      BufferManager.flash "No new messages."
    end
  end

  def toggle_spam
    t = cursor_thread or return
    multi_toggle_spam [t]
  end

  ## both spam and deleted have the curious characteristic that you
  ## always want to hide the thread after either applying or removing
  ## that label. in all thread-index-views except for
  ## label-search-results-mode, when you mark a message as spam or
  ## deleted, you want it to disappear immediately; in LSRM, you only
  ## see deleted or spam emails, and when you undelete or unspam them
  ## you also want them to disappear immediately.
  def multi_toggle_spam threads
    undos = threads.map { |t| actually_toggle_spammed t }
    threads.each { |t| HookManager.run("mark-as-spam", :thread => t) }
    UndoManager.register "marking/unmarking  #{threads.size.pluralize 'thread'} as spam",
                         undos, lambda { regen_text }, lambda { threads.each { |t| Index.save_thread t } }
    regen_text
    threads.each { |t| Index.save_thread t }
  end

  def toggle_deleted
    t = cursor_thread or return
    multi_toggle_deleted [t]
  end

  ## see comment for multi_toggle_spam
  def multi_toggle_deleted threads
    undos = threads.map { |t| actually_toggle_deleted t }
    UndoManager.register "deleting/undeleting #{threads.size.pluralize 'thread'}",
                         undos, lambda { regen_text }, lambda { threads.each { |t| Index.save_thread t } }
    regen_text
    threads.each { |t| Index.save_thread t }
  end

  def kill
    t = cursor_thread or return
    multi_kill [t]
  end

  def flush_index
    @flush_id = BufferManager.say "Flushing index..."
    Index.save_index
    BufferManager.clear @flush_id
  end

  ## m-m-m-m-MULTI-KILL
  def multi_kill threads
    UndoManager.register "killing #{threads.size.pluralize 'thread'}" do
      threads.each do |t|
        t.remove_label :killed
        add_or_unhide t.first
        Index.save_thread t
      end
      regen_text
    end

    threads.each do |t|
      t.apply_label :killed
      hide_thread t
    end

    regen_text
    BufferManager.flash "#{threads.size.pluralize 'thread'} killed."
    threads.each { |t| Index.save_thread t }
  end

  def toggle_tagged
    t = cursor_thread or return
    @tags.toggle_tag_for t
    update_text_for_line! curpos
    cursor_down
  end

  def toggle_tagged_all
    @mutex.synchronize { @threads.each { |t| @tags.toggle_tag_for t } }
    regen_text
  end

  def tag_matching
    query = BufferManager.ask :search, "tag threads matching (regex): "
    return if query.nil? || query.empty?
    query = begin
      /#{query}/i
    rescue RegexpError => e
      BufferManager.flash "error interpreting '#{query}': #{e.message}"
      return
    end
    @mutex.synchronize { @threads.each { |t| @tags.tag t if thread_matches?(t, query) } }
    regen_text
  end

  def apply_to_tagged; @tags.apply_to_tagged; end

  def edit_labels
    thread = cursor_thread or return
    pos = curpos

    old_labels = thread.labels
    speciall = @hidden_labels + @context.labels.reserved_labels
    keepl, modifyl = thread.labels.partition { |t| speciall.member? t }.map { |x| Set.new x }

    @context.input.asking do
      user_labels = @context.input.ask_for_labels :label, "Labels for thread: ", modifyl, @hidden_labels
      return unless user_labels

      pos = curpos
      old_labels = thread.labels
      new_labels = keepl + user_labels

      thread.labels = new_labels
      update_text_for_line! curpos

      @context.client.set_labels! thread.thread_id, thread.labels
      @context.ui.broadcast self, :thread, thread.thread_id, :labels => thread.labels
      @context.labels.prune!

      to_undo "labeling thread" do
        thread.labels = old_labels
        @context.client.set_labels! thread.thread_id, thread.labels
        @context.ui.broadcast self, :thread, thread.thread_id, :labels => thread.labels
        update_text_for_line! pos
      end
    end
  end

  def multi_edit_labels threads
    user_labels = BufferManager.ask_for_labels :labels, "Add/remove labels (use -label to remove): ", [], @hidden_labels
    return unless user_labels

    user_labels.map! { |l| (l.to_s =~ /^-/)? [l.to_s.gsub(/^-?/, '').to_sym, true] : [l, false] }
    hl = user_labels.select { |(l,_)| @hidden_labels.member? l }
    unless hl.empty?
      BufferManager.flash "'#{hl}' is a reserved label!"
      return
    end

    old_labels = threads.map { |t| t.labels.dup }

    threads.each do |t|
      user_labels.each do |(l, to_remove)|
        if to_remove
          t.remove_label l
        else
          t.apply_label l
          LabelManager << l
        end
      end
      UpdateManager.relay self, :labeled, t.first
    end

    regen_text

    UndoManager.register "labeling #{threads.size.pluralize 'thread'}" do
      threads.zip(old_labels).map do |t, old_labels|
        t.labels = old_labels
        UpdateManager.relay self, :labeled, t.first
        Index.save_thread t
      end
      regen_text
    end

    threads.each { |t| Index.save_thread t }
  end

  def reply type_arg=nil
    t = cursor_thread or return
    m = t.latest_message
    return if m.nil? # probably won't happen
    m.load_from_source!
    mode = ReplyMode.new m, type_arg
    BufferManager.spawn "Reply to #{m.subj}", mode
  end

  def reply_all; reply :all; end

  def forward
    t = cursor_thread or return
    m = t.latest_message
    return if m.nil? # probably won't happen
    m.load_from_source!
    ForwardMode.spawn_nicely :message => m
  end

  def load_n_threads_background n=LOAD_MORE_THREAD_NUM, opts={}
    return if @load_thread # todo: wrap in mutex
    @load_thread = Redwood::reporting_thread("load threads for thread-index-mode") do
      num = load_n_threads n, opts
      opts[:when_done].call(num) if opts[:when_done]
      @load_thread = nil
    end
  end

  def status
    if (l = lines) == 0
      "line 0 of 0"
    else
      "line #{curpos + 1} of #{l}"
    end
  end

  def cancel_search
    @interrupt_search = true
  end

  def resize rows, cols
    regen_text
    super
  end

protected

  def add_or_unhide m
    @ts_mutex.synchronize do
      if (is_relevant?(m) || @ts.is_relevant?(m)) && !@ts.contains?(m)
        @ts.load_thread_for_message m, @load_thread_opts
      end

      @hidden_threads.delete @ts.thread_for(m)
    end

    update
  end

  def thread_containing m; @ts_mutex.synchronize { @ts.thread_for m } end

  ## used to tag threads by query. this can be made a lot more sophisticated,
  ## but for right now we'll do the obvious this.
  def thread_matches? t, query
    t.subj =~ query || t.snippet =~ query || t.participants.any? { |x| x.longname =~ query }
  end

  def size_widget_for_thread t
    @context.hooks.run("index-mode-size-widget", :thread => t) || default_size_widget_for(t)
  end

  def date_widget_for_thread t
    @context.hooks.run("index-mode-date-widget", :thread => t) || default_date_widget_for(t)
  end

  def cursor_thread; @threads[curpos] end

  def drop_all_threads
    @tags.drop_all_tags
    initialize_threads
    update
  end

  def hide_thread t
    @mutex.synchronize do
      i = @threads.index(t) or return
      raise "already hidden" if @hidden_threads[t]
      @hidden_threads[t] = true
      @threads.delete_at i
      @size_widgets.delete_at i
      @date_widgets.delete_at i
      @tags.drop_tag_for t
    end
  end

  def update_text_for_line! l
    need_update = false

    @size_widgets[l] = size_widget_for_thread @threads[l]
    @date_widgets[l] = date_widget_for_thread @threads[l]

    ## if a widget size has increased, we need to redraw everyone
    if (@size_widgets[l].display_width > @size_widget_width) || (@date_widgets[l].display_width > @date_widget_width)
      regen_text!
    else
      @text[l] = text_for_thread_at l
      buffer.mark_dirty!
    end
  end

  def authors; map { |m, *o| m.from if m }.compact.uniq; end

  AUTHOR_LIMIT = 5
  def text_for_thread_at line
    t = @threads[line]
    size_widget = @size_widgets[line]
    date_widget = @date_widgets[line]

    ## format the from column
    cur_width = 0
    from = []

    remaining_width = from_width
    t.participants.each_with_index do |p, i|
      break if remaining_width <= 0

      last = i == t.participants.length - 1
      name = if @context.accounts.is_account? p
        "me"
      elsif t.participants.size == 1
        p.mediumname
      else
        p.shortname
      end

      new_width = name.display_width

      abbrev = if new_width > remaining_width
        name.display_slice(0, (remaining_width - 1)) + "."
      elsif new_width == remaining_width # exact match
        name
      else
        name + (last ? "" : ",")
      end

      remaining_width -= abbrev.display_width

      abbrev += (" " * remaining_width) if last && remaining_width > 0

      from << [(t.unread? ? :index_new : (t.starred? ? :index_starred : :index_old)), abbrev]
    end

    dp = t.participants.any? { |p| @context.accounts.is_account? p }
    p = false # TODO distinguish between direct and indirect participants
    #p = dp || t.participants.any? { |p| AccountManager.is_account? p }

    subj_color = if t.draft?; :index_draft
    elsif t.unread?; :index_new
    elsif t.starred?; :index_starred
    else :index_old
    end

    size_padding = @size_widget_width - size_widget.display_width
    size_widget_text = sprintf "%#{size_padding}s%s", "", size_widget

    date_padding = @date_widget_width - date_widget.display_width
    date_widget_text = sprintf "%#{date_padding}s%s", "", date_widget

    labels = Set.new(t.labels) - @hidden_labels - ALWAYS_HIDDEN_LABELS

    [
      [:tagged, @tags.tagged?(t) ? ">" : " "],
      [:date, date_widget_text],
      [:starred, (t.starred? ? "*" : " ")],
    ] +
      from +
      [
      [subj_color, size_widget_text],
      [:to_me, t.attachment? ? "@" : " "],
      [:to_me, dp ? ">" : (p ? '+' : " ")],
    ] +
      labels.sort.map { |label| [:label, "#{label} "] } +
      [
      [subj_color, t.subject + (t.subject.empty? ? "" : " ")],
      [:snippet, t.snippet],
    ]
  end

  def dirty?; false end

private

  def default_size_widget_for t
    case t.size
    when 1
      ""
    else
      "(#{t.size})"
    end
  end

  def default_date_widget_for t
    t.date.getlocal.to_nice_s
  end

  def from_width
    [(buffer.content_width.to_f * FROM_WIDTH_PORTION).to_i, MIN_FROM_WIDTH].max
  end
end

end

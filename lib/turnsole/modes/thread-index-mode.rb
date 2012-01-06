require 'set'

module Turnsole

class ThreadIndexMode < LineCursorMode
  include LogsStuff
  include CanUndo
  include ModeHelper

  DATE_WIDTH = Time::TO_NICE_S_MAX_LEN
  MIN_FROM_WIDTH = 15
  FROM_WIDTH_PORTION = 0.2
  LOAD_MORE_THREAD_NUM = 20

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
    k.add :refine_search, "Refine search", '|'
    k.add :reload, "Reload", '@'
    k.add :toggle_archived, "Toggle archived status", 'a'
    k.add :toggle_starred, "Star or unstar all messages in thread", '*'
    k.add :toggle_new, "Toggle new/read status of all messages in thread", 'N'
    k.add :edit_labels, "Edit or add labels for a thread", 'l'
    k.add :edit_message, "Edit message (drafts only)", 'e'
    k.add :toggle_spam, "Mark/unmark thread as spam", 'S'
    k.add :toggle_deleted, "Delete/undelete thread", 'd'
    k.add :toggle_muted, "Mute thread (never to be seen in inbox again)", '&'
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
    super(context)

    @context = context
    @query = query
    @hidden_labels = Set.new hidden_labels

    @threads = []          # the threads we actually display
    @text = ["loading..."] # the text on screen
    @lines = {}            # map from thread to line number

    ## various display widgets, per line
    @size_widget_width = nil
    @size_widgets = []
    @date_widget_width = nil
    @date_widgets = []

    @tags = Tagger.new context, self

    ## keep track of the last size we had when we scheduled more threads to be
    ## loaded, so that we don't duplicate the request. duplication can happen
    ## when the cursor moves down faster than the network responds.
    @last_schedule_more_size = -1
    to_load_more { |size| schedule_more size }

    @context.ui.add_event_listener self
  end

  def cleanup!
    @context.ui.remove_event_listener self
  end

  NUM_AT_A_TIME = 20
  def load!
    while buffer && @threads.size < buffer.content_height
      result = schedule_more NUM_AT_A_TIME # oh yeah
      break if result.size < NUM_AT_A_TIME
    end
  end

  def num_lines; @text.length end
  def [] i; @text[i] end

  def log; @context.log end

  def schedule_more num_threads
    return if @already_scheduling_more || (@last_schedule_more_size == 0)
    @already_scheduling_more = true
    threads = @context.client.search query, num_threads, @threads.size
    @last_schedule_more_size = threads.size
    @already_scheduling_more = false
    receive_threads threads
    threads
  end

  def reload
    @threads = []
    @text = ["loading..."]
    @last_schedule_more_size = -1
    @buffer.mark_dirty!
    load!
  end

  def receive_threads threads
    return unless buffer # die unless i'm still actually being displayed
    old_cursor_thread = @threads[curpos]

    info "got #{threads.size} more threads"
    @threads += threads
    sort_threads!
    regen_text!
    new_cursor_thread = @threads.index old_cursor_thread

    set_cursor_pos new_cursor_thread if new_cursor_thread
  end

  def sort_threads!
    @threads = @threads.uniq_by { |t| t.thread_id }.sort_by { |t| t.date }.reverse
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

  def refine_search
    query = @context.input.ask :search, "refine query: ", (@query + " ")
    return unless query && query !~ /^\s*$/
    SearchResultsMode.spawn_from_query @context, query
  end

  ## open up a thread view window
  def select thread=nil # nil for cursor thread
    thread ||= cursor_thread
    return unless thread

    mode = ThreadViewMode.new @context, thread, self
    @context.screen.spawn thread.subject, mode
    mode.load!
  end

  def multi_select threads
    threads.each { |t| select t }
  end

  ## these two methods are called by thread-view-mode two-pass
  ## actions.
  def launch_next_thread_after thread
    launch_another_thread thread, 1
  end

  def launch_prev_thread_before thread
    launch_another_thread thread, -1
  end

  def launch_another_thread thread, direction
    l = @lines[thread] or return
    target_l = l + direction
    if (target_l >= 0) && (target_l < @threads.length)
      t = @threads[target_l]
      set_cursor_pos target_l
      select t
    end
  end

  def handle_thread_update new_thread
    old_thread, index = @threads.find_with_index { |x| x.thread_id == new_thread.thread_id }

    if old_thread # we have this thread currently
      if is_relevant?(new_thread) == false # BUT it is no longer relevant
        @threads.delete_at index
        regen_text!
      else # we will keep the thread and just update the thread from the server
        @threads[index] = new_thread
        @lines.delete old_thread
        @lines[new_thread] = index

        if @tags.tagged? old_thread
          @tags.untag old_thread
          @tags.tag new_thread
        end

        update_text_for_line! index
      end
    elsif is_relevant?(new_thread) # we don't have it, and we need to add it
      add_thread new_thread
      regen_text! # rebuild everybody!
    end
  end

  ## overwrite me! takes a thread that has just been updated. should return
  ## false if the thread does not belong in this view, true if it does, and
  ## nil if it's unknown.
  def is_relevant? t; nil end

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

  ## message state toggles that we allow at the per-thread level,
  ## for convenience.
  { "new" => "unread",
    "deleted" => "deleted",
    "starred" => "starred"
  }.each do |method, state|
    define_method "toggle_#{method}" do
      toggle_cursor_thread_state state
    end

    define_method "multi_toggle_#{method}" do |threads|
      toggle_thread_states threads, state
    end
  end

  ## thread label toggles that we support via immediate keystroke
  ## commands, because they have special semantics in turnsole.
  { "archived" => "inbox",
    "spam" => "spam",
    "muted" => "muted"
  }.each do |method, label|
    define_method "toggle_#{method}" do
      toggle_cursor_thread_label label
    end

    define_method "multi_toggle_#{method}" do |threads|
      toggle_thread_labels threads, label
    end
  end

  def toggle_cursor_thread_state state
    t = cursor_thread or return
    new_threads = toggle_thread_states [t], state
    cursor_down if is_relevant?(new_threads.first)
  end

  def toggle_thread_states threads, state
    new_states = threads.map do |t|
      t.has_state?(state) ? (t.state - [state]) : (t.state + [state])
    end

    modify_thread_state threads, new_states
  end

  def toggle_cursor_thread_label label
    t = cursor_thread or return
    new_threads = toggle_thread_labels [t], label
    cursor_down if is_relevant?(new_threads.first)
  end

  def toggle_thread_labels threads, label
    new_labels = threads.map do |t|
      t.has_label?(label) ? (t.labels - [label]) : (t.labels + [label])
    end

    modify_thread_labels threads, new_labels
  end

  def multi_toggle_tagged threads
    @tags.drop_all_tags!
    regen_text!
  end

  def join_threads
    ## this command has no non-tagged form. as a convenience, allow this
    ## command to be applied to tagged threads without hitting ';'.
    @tags.apply_to_tagged! :join_threads
  end

  def multi_join_threads threads
    @ts.join_threads threads or return
    threads.each { |t| Index.save_thread t }
    @tags.drop_all_tags! # otherwise we have tag pointers to invalid threads!
    update
  end

  def jump_to_next_new
    n = ((curpos + 1) ... @threads.length).find { |i| @threads[i].unread? } || (0 ... curpos).find { |i| @threads[i].unread? }
    if n # jump there if necessary
      jump_to_line n unless n >= topline && n < botline
      set_cursor_pos n
    else
      @context.screen.minibuf.flash "No new messages."
    end
  end

  def toggle_tagged
    t = cursor_thread or return
    @tags.toggle t
    update_text_for_line! curpos
    cursor_down
  end

  def toggle_tagged_all
    @threads.each { |t| @tags.toggle t }
    regen_text!
  end

  def tag_matching
    query = @context.input.ask :search, "Tag all threads matching (regex): "
    return if query.nil? || query.empty?

    begin
      query = /#{query}/i
      @threads.each { |t| @tags.tag t if thread_matches?(t, query) }
      regen_text!
    rescue RegexpError => e
      @context.screen.minibuf.flash "Error interpreting '#{query}': #{e.message}"
      return
    end
  end

  def apply_to_tagged; @tags.apply_to_tagged! end

  def edit_labels
    thread = cursor_thread or return

    old_labels = thread.labels
    speciall = @hidden_labels + @context.labels.reserved_labels
    keepl, modifyl = thread.labels.partition { |t| speciall.member? t }.map { |x| Set.new x }

    user_labels = @context.input.ask_for_labels :label, "Labels for thread: ", modifyl, @hidden_labels
    return unless user_labels

    modify_thread_labels [thread], [keepl + user_labels]
  end

  def multi_edit_labels threads
    user_labels = @context.input.ask_for_labels :labels, "Add/remove labels (use -label to remove): ", [], @hidden_labels
    return unless user_labels

    user_labels = user_labels.map do |l|
      if @hidden_labels.member? l
        @context.screen.minibuf.flash "'#{hl}' is a reserved label!"
        return
      end

      if l =~ /^-(.+)$/
        [$1, true]
      else
        [l, false]
      end
    end

    thread_labels = threads.map do |t|
      user_labels.inject(t.labels) do |labels, (l, remove)|
        remove ? (labels - [l]) : (labels + [l])
      end
    end

    modify_thread_labels threads, thread_labels
  end

  def reply type_arg=nil
    t = cursor_thread or return
    m = latest_message_for_thread t
    return if m.nil? # probably won't happen
    mode = ReplyMode.new @context, m, type_arg
    @context.screen.spawn "Reply to #{m.subject}", mode
  end

  def reply_all; reply :all; end

  def forward
    t = cursor_thread or return
    m = latest_message_for_thread t
    return if m.nil? # probably won't happen
    ForwardMode.spawn_nicely @context, :message => m
  end

  def status
    if (l = lines) == 0
      "line 0 of 0"
    else
      "line #{curpos + 1} of #{l}"
    end
  end

  def set_size rows, cols
    super
    regen_text!
  end

protected

  ## used to tag threads by query. this can be made a lot more sophisticated,
  ## but for right now we'll do the obvious this.
  def thread_matches? t, query
    t.subject =~ query || t.snippet =~ query || t.participants.any? { |x| x.longname =~ query }
  end

  def size_widget_for_thread t
    @context.hooks.run("index-mode-size-widget", :thread => t) || default_size_widget_for(t)
  end

  def date_widget_for_thread t
    @context.hooks.run("index-mode-date-widget", :thread => t) || default_date_widget_for(t)
  end

  def cursor_thread; @threads[curpos] end

  def drop_all_threads
    @tags.drop_all_tags!
    initialize_threads
    update
  end

  def drop_thread t; @threads.delete t end
  def add_thread t
    @threads << t
    sort_threads!
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
      name = if @context.accounts.is_account?(p); "me"
        elsif t.participants.size == 1; p.mediumname
        else p.shortname
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

      from << [(t.unread_participants.member?(p) ? :index_new : (t.starred? ? :index_starred : :index_old)), abbrev]
    end

    amdirect = t.direct_recipients.any? { |p| @context.accounts.is_account? p }
    amindirect = t.indirect_recipients.any? { |p| @context.accounts.is_account? p }

    subj_color = if t.draft?; :index_draft
    elsif t.unread?; :index_new
    elsif t.starred?; :index_starred
    else :index_old
    end

    size_padding = @size_widget_width - size_widget.display_width
    size_widget_text = sprintf "%#{size_padding}s%s", "", size_widget

    date_padding = @date_widget_width - date_widget.display_width
    date_widget_text = sprintf "%#{date_padding}s%s", "", date_widget

    ## don't show any labels that we turn into state
    labels = Set.new(t.labels) - @hidden_labels - @context.labels.reserved_labels

    [
      [:tagged, @tags.tagged?(t) ? ">" : " "],
      [:date, date_widget_text],
      [:starred, (t.starred? ? "*" : " ")],
    ] +
      from +
      [
      [subj_color, size_widget_text],
      [:to_me, t.attachment? ? "@" : " "],
      [:to_me, amdirect ? ">" : (amindirect ? '+' : " ")],
    ] +
      labels.sort.map { |label| [:label, "#{label} "] } +
      [
      [subj_color, t.subject + (t.subject.empty? ? "" : " ")],
      [:snippet, t.snippet],
    ]
  end

  def dirty?; false end

private

  def latest_message_for_thread t
    ## load the thread
    thread = @context.client.load_thread t.thread_id
    ## pick the latest message
    latest = thread.map { |m, depth| m }.sort_by(&:date).last
    ## load it
    @context.client.load_message latest.message_id
  end

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

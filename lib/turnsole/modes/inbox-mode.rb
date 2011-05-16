module Turnsole

class InboxMode < ThreadIndexMode
  register_keymap do |k|
    ## overwrite toggle_archived with archive
    k.add :archive, "Archive thread (remove from inbox)", 'a'
    k.add :read_and_archive, "Archive thread and mark read", 'A'
  end

  def initialize context
    super context, "~inbox", %w(inbox)


    ## label-list-mode wants to be able to raise us if the user selects
    ## the "inbox" label, so we need to keep our singletonness around
    raise "only can have one inbox" if defined?(@@instance)
    @@instance = self

    @index_size = 0 # loaded periodically
  end

  def self.instance; @@instance; end

  def killable?; false; end

  def is_relevant? t; t.has_label?("inbox") end

  def archive
    return unless cursor_thread
    modify_thread_labels cursor_thread, cursor_thread.labels - %w(inbox), :desc => "archiving thread"
  end

  def multi_archive threads
    UndoManager.register "archiving #{threads.size.pluralize 'thread'}" do
      threads.map do |t|
        t.apply_label :inbox
        add_or_unhide t.first
        Index.save_thread t
      end
      regen_text
    end

    threads.each do |t|
      t.remove_label :inbox
      hide_thread t
    end
    regen_text
    threads.each { |t| Index.save_thread t }
  end

  ## we'll plug this in here... not sure if it's a good idea or not.
  def receive_threads(*a)
    super(*a)
    @context.client.size { |size| @index_size = size }
  end

  def read_and_archive
    return unless cursor_thread
    thread = cursor_thread # to make sure lambda only knows about 'old' cursor_thread

    was_unread = thread.labels.member? :unread
    UndoManager.register "reading and archiving thread" do
      thread.apply_label :inbox
      thread.apply_label :unread if was_unread
      add_or_unhide thread.first
      Index.save_thread thread
    end

    cursor_thread.remove_label :unread
    cursor_thread.remove_label :inbox
    hide_thread cursor_thread
    regen_text
    Index.save_thread thread
  end

  def multi_read_and_archive threads
    old_labels = threads.map { |t| t.labels.dup }

    threads.each do |t|
      t.remove_label :unread
      t.remove_label :inbox
      hide_thread t
    end
    regen_text

    UndoManager.register "reading and archiving #{threads.size.pluralize 'thread'}" do
      threads.zip(old_labels).each do |t, l|
        t.labels = l
        add_or_unhide t.first
        Index.save_thread t
      end
      regen_text
    end

    threads.each { |t| Index.save_thread t }
  end

  def handle_unarchived_update sender, m
    add_or_unhide m
  end

  def handle_archived_update sender, m
    t = thread_containing(m) or return
    hide_thread t
    regen_text
  end

  def handle_idle_update sender, idle_since
    flush_index
  end

  def status_bar_text
    super + "    #{@index_size} messages in index"
  end
end

end

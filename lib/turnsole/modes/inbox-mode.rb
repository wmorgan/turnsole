module Turnsole

class InboxMode < ThreadIndexMode
  register_keymap do |k|
    ## overwrite toggle_archived with archive
    k.add :toggle_archived, "Archive thread (remove from inbox)", 'a'
    k.add :read_and_archive, "Archive thread and mark read", 'A'
  end

  def initialize context
    super context, "~inbox -~deleted -~spam -~muted", %w(inbox)

    ## label-list-mode wants to be able to raise us if the user selects
    ## the "inbox" label, so we need to keep our singletonness around
    raise "only can have one inbox" if defined?(@@instance)
    @@instance = self

    @index_size = 0 # loaded later
  end

  def self.instance; @@instance; end

  def killable?; false; end

  def is_relevant? t; t.has_label?("inbox") && !t.has_label?("spam") && !t.has_label?("muted") end

  ## we'll plug this in here... not sure if it's a good idea or not.
  def receive_threads(*a)
    super(*a)
    @index_size = @context.client.size
  end

  def read_and_archive
    multi_read_and_archive [cursor_thread]
  end

  ## a little complicated because we need to modify both the state and the
  ## labels of a thread.
  def multi_read_and_archive threads
    old_states = threads.map(&:state)
    old_labels = threads.map(&:labels)

    threads.each do |thread|
      @context.client.set_thread_state! thread.thread_id, thread.state - %w(unread)
      new_thread = @context.client.set_labels! thread.thread_id, thread.state - %w(inbox)
      @context.ui.broadcast :thread, new_thread
    end

    to_undo "marking as read and archiving" do
      threads.zip(old_states, old_labels).each do |thread, state, labels|
        @context.client.set_thread_state! thread.thread_id, state
        new_thread = @context.client.set_labels! thread.thread_id, labels
        @context.ui.broadcast :thread, new_thread
      end
    end
  end

  def status_bar_text
    super + "    #{@index_size} messages in index"
  end
end

end

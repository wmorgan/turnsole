module ModeHelper
  def modify_thread_values_synchronized threads, new_values, opts={}
    value = opts[:value] or raise ArgumentError, "need :value" # the field to change
    setter = opts[:setter] or raise ArgumentError, "need :setter" # the method to call on the client
    desc = opts[:desc] || "operation"

    old_values = threads.map(&value)

    new_threads = threads.zip(new_values).map do |thread, new_value|
      new_thread = @context.client.send setter, thread.thread_id, new_value
      @context.ui.broadcast :thread, new_thread
      new_thread
    end

    to_undo desc do
      threads.zip(old_values).each do |thread, old_value|
        new_thread = @context.client.send setter, thread.thread_id, old_value
        @context.ui.broadcast :thread, new_thread
      end
    end

    new_threads
  end

  def modify_thread_labels threads, new_labels, opts={}
    desc = opts[:desc] || "changing thread labels"
    #modify_thread_values threads, thread_labels, :value => :labels, :setter => :set_labels!, :desc => desc

    old_labels = threads.map(&:labels)
    threads.zip(new_labels).each do |t, labels|
      @context.client.async_set_labels! t.thread_id, labels
      t.labels = labels
      @context.ui.broadcast :thread, t
      @context.client.async_load_threadinfo t.thread_id
    end

    to_undo desc do
      threads.zip(old_labels).each do |t, labels|
        @context.client.async_set_labels! t.thread_id, labels
        t.labels = labels
        @context.ui.broadcast :thread, t
        @context.client.async_load_threadinfo t.thread_id
      end
    end

    @context.labels.prune! # a convenient time to do this
    threads
  end

  def modify_thread_state threads, new_state, opts={}
    desc = opts[:desc] || "changing thread state"
    #modify_thread_values threads, thread_state, :value => :state, :setter => :set_thread_state!, :desc => desc

    old_state = threads.map(&:state)
    threads.zip(new_state).each do |t, state|
      @context.client.async_set_thread_state! t.thread_id, state
      t.state = state
      @context.ui.broadcast :thread, t
      @context.client.async_load_threadinfo t.thread_id
    end

    to_undo desc do
      threads.zip(old_state).each do |t, state|
        @context.client.async_set_thread_state! t.thread_id, state
        t.state = state
        @context.ui.broadcast :thread, t
        @context.client.async_load_threadinfo t.thread_id
      end
    end
    threads
  end

end

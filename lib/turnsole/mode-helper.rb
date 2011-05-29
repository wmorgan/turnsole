module ModeHelper
  def modify_thread_values threads, new_values, opts={}
    value = opts[:value] or raise ArgumentError, "need :value"
    setter = opts[:setter] or raise ArgumentError, "need :setter"
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

  def modify_thread_labels threads, thread_labels, opts={}
    desc = opts[:desc] || "changing thread labels"
    result = modify_thread_values threads, thread_labels, :value => :labels, :setter => :set_labels!, :desc => desc
    @context.labels.prune! # a convenient time to do this
    result
  end

  def modify_thread_state threads, thread_state, opts={}
    desc = opts[:desc] || "changing thread state"
    modify_thread_values threads, thread_state, :value => :state, :setter => :set_thread_state!, :desc => desc
  end

end

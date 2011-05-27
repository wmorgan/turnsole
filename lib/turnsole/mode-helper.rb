module ModeHelper
  def modify_thread_values threads, new_values, opts={}
    value = opts[:value] or raise ArgumentError, "need :value"
    setter = opts[:setter] or raise ArgumentError, "need :setter"
    desc = opts[:desc] || "operation"

    old_values = threads.map(&value)

    threads.zip(new_values).each do |thread, new_value|
      new_thread = @context.client.send setter, thread.thread_id, new_value
      @context.ui.broadcast :thread, new_thread
    end

    to_undo desc do
      threads.zip(old_values).each do |thread, old_value|
        new_thread = @context.client.send setter, thread.thread_id, old_value
        @context.ui.broadcast :thread, new_thread
      end
    end
  end

  def modify_thread_labels threads, thread_labels
    modify_thread_values threads, thread_labels, :value => :labels, :setter => :set_labels!, :desc => "changing thread labels"
    @context.labels.prune! # a convenient time to do this
  end

end

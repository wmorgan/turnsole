module Turnsole

class HookManager
  class HookEnv
    def initialize name, context
      @__name = name
      @__context = context
      @__say_id = nil
      @__cache = {}
    end

    def say s
      if @context.screen.cursing?
        @__say_id = @context.screen.minibuf.say s, @__say_id
      else
        log s
      end
    end

    def log s
      info "hook[#@__name]: #{s}"
    end

    def ask_yes_or_no q
      if @context.screen.cursing?
        @context.input.ask_yes_or_no q
      else
        print q
        gets.chomp.downcase == 'y'
      end
    end

    def get tag
      HookManager.tags[tag]
    end

    def set tag, value
      HookManager.tags[tag] = value
    end

    def __run __hook, __filename, __locals
      __binding = binding
      __lprocs, __lvars = __locals.partition { |k, v| v.is_a?(Proc) }
      eval __lvars.map { |k, v| "#{k} = __locals[#{k.inspect}];" }.join, __binding
      ## we also support closures for delays evaluation. unfortunately
      ## we have to do this via method calls, so you don't get all the
      ## semantics of a regular variable. not ideal.
      __lprocs.each do |k, v|
        self.class.instance_eval do
          define_method k do
            @__cache[k] ||= v.call
          end
        end
      end
      ret = eval __hook, __binding, __filename
      @context.screen.minibuf.clear @__say_id if @__say_id
      @__cache = {}
      ret
    end
  end

  @descs = {}

  class << self
    attr_reader :descs
  end

  include LogsStuff
  def initialize dir, context
    @dir = dir
    @hooks = {}
    @envs = {}
    @tags = {}
    @context = context

    Dir.mkdir dir unless File.exists? dir
  end

  def log; @context.log end

  attr_reader :tags

  def run name, locals={}
    hook = hook_for(name) or return
    env = @envs[hook] ||= HookEnv.new(name, @context)

    result = nil
    fn = fn_for name
    begin
      result = env.__run hook, fn, locals
    rescue Exception => e
      log.debug "error running #{fn}: #{e.message}"
      log.debug e.backtrace.join("\n")
      @hooks[name] = nil # disable it
      @context.screen.minibuf.flash "Error running hook: #{e.message}" if @context.screen.cursing?
    end
    result
  end

  def self.register name, desc
    @descs[name] = desc
  end

  def dump_hooks f=$stdout
puts <<EOS
Have #{HookManager.descs.size} registered hooks:

EOS

    HookManager.descs.sort.each do |name, desc|
      f.puts <<EOS
#{name}
#{"-" * name.length}
File: #{fn_for name}
#{desc}
EOS
    end
  end

  def enabled? name; !hook_for(name).nil? end

  def clear; @hooks.clear; @context.screen.minibuf.flash "Hooks cleared" end
  def clear_one k; @hooks.delete k; end

private

  def hook_for name
    unless @hooks.member? name
      @hooks[name] = begin
        fn = fn_for name
        debug "reading '#{name}' from #{fn}"
        IO.read fn
      rescue SystemCallError => e
        #debug "disabled hook for '#{name}': #{e.message}"
        nil
      end
    end

    @hooks[name]
  end

  def fn_for name
    File.join @dir, "#{name}.rb"
  end
end

end

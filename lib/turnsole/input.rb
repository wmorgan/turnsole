require 'set'

begin
  require 'continuation'
rescue LoadError # SIGH ruby 1.9 non-backwards-compatible
end

module Turnsole

class Input
  class InputSequenceAborted < StandardError; end
  include LogsStuff

  ## we have to define the key used to continue in-buffer search here, because
  ## it has special semantics that we deal with, namely that current searches
  ## are canceled by any keypress except this one.
  CONTINUE_IN_BUFFER_SEARCH_KEY = "n"

  def initialize context
    @context = context
    @state = :normal
  end

  def log; @context.log end

  ## assumes we're running in the context of a fiber
  def asking_getchar
    Fiber.yield :input
  end

  def handle input_char
    focus_mode = @context.screen.focus_buf.mode

    if focus_mode.in_search? && (input_char != CONTINUE_IN_BUFFER_SEARCH_KEY.ord)
      focus_mode.cancel_search!
    end

    if(action = resolve_input_on_mode focus_mode, input_char)
      focus_mode.send action
    elsif(action = resolve_input_with_keymap(input_char, @context.global.keymap))
      @context.global.do action
    else
      input_char -= 256 while input_char >= 256 # yes i have to do this apparently
      @context.screen.minibuf.flash "Unknown command '#{input_char.chr}' for #{focus_mode.name}!"
    end
  end

  def resolve_input_on_mode mode, input_char
    klass = mode.class
    until klass == Object
      action = resolve_input_with_keymap input_char, klass.keymap
      return action if action
      klass = klass.superclass
    end
    nil
  end

  def ask domain, question, default=nil, opts={}, &block
    raise "question too long" if Ncurses.cols <= question.display_width

    textfield = @context.screen.minibuf.activate_textfield! domain, question, default, block

    completion_buf = nil
    while true
      c = asking_getchar
      continue = textfield.handle_input c # process keystroke
      break unless continue

      if textfield.new_completions?
        @context.screen.kill_buffer completion_buf if completion_buf

        match = textfield.completions.map { |full, short, match| match || short }.shared_prefix(true)
        entries = textfield.completions.map { |full, short, match| short }
        mode = CompletionMode.new @context, entries, :match => match, :header => "Completions for \"#{textfield.answer}\": "
        completion_buf = @context.screen.spawn "<completions>", mode, :height => 10
      elsif textfield.roll_completions?
        completion_buf.mode.roll!
      elsif textfield.clear_completions?
        @context.screen.kill_buffer completion_buf if completion_buf
        completion_buf = nil
      # else leave the buffer up if it's up
      end
    end

    @context.screen.kill_buffer completion_buf if completion_buf
    @context.screen.minibuf.deactivate_textfield!

    textfield.answer
  end

  def ask_with_completions domain, question, completions, default=nil
    ask domain, question, default do |s|
      completions.select { |x| x.has_prefix?(s) }.map { |x| [x, x] }
    end
  end

  def ask_many_with_completions domain, question, completions, default=nil
    ask domain, question, default do |partial|
      prefix, target = case partial
      when /^\s*$/
        ["", ""]
      when /^(.*\s+)?(.*?)$/
        [$1 || "", $2]
      else
        raise "william screwed up completion: #{partial.inspect}"
      end

      completions.select { |x| x.has_prefix?(target) }.map { |x| [prefix + x, x] }
    end
  end

  def ask_many_emails_with_completions domain, question, completions, default=nil
    ask domain, question, default do |partial|
      prefix, target = partial.split_on_commas_with_remainder
      target ||= prefix.pop || ""
      prefix = prefix.join(", ") + (prefix.empty? ? "" : ", ")
      completions.select { |x| x.has_prefix(target) }.sort_by { |c| [ContactManager.contact_for(c) ? 0 : 1, c] }.map { |x| [prefix + x, x] }
    end
  end

  def ask_for_filename domain, question, default=nil
    answer = ask domain, question, default do |s|
      path = File.expand_path s
      glob = path + (File.directory?(path) ? "/" : "") + "*"
      files = Dir[glob]

      while files.size == 1 && File.directory?(files.first)
        files = Dir[files.first + "/*"]
      end

      files.sort.map do |fn|
        suffix = File.directory?(fn) ? "/" : ""
        [fn + suffix, File.basename(fn) + suffix]
      end
    end

    if answer
      answer = if answer.empty?
        @context.screen.spawn_modal "file browser", FileBrowserMode.new(@context)
      elsif File.directory?(answer)
        @context.screen.spawn_modal "file browser", FileBrowserMode.new(@context, answer)
      else
        File.expand_path answer
      end
    end

    answer
  end

  def ask_for_directory domain, question, default=nil
    answer = ask domain, question, default do |s|
      path = File.expand_path s
      glob = path + (File.directory?(path) ? "/" : "") + "*"
      files = Dir[glob].select { |d| File.directory?(d) }

      files.sort.map do |fn|
        [fn + "/", File.basename(fn) + "/"]
      end
    end

    File.expand_path answer if answer
  end

  ## returns an array of labels
  def ask_for_labels domain, question, default_labels, forbidden_labels=[]
    default_labels = Set.new default_labels
    default_labels -= @context.labels.reserved_labels
    default = default_labels.sort.map { |x| x + " " }.join

    forbidden_labels = Set.new forbidden_labels
    autocomplete_labels = (@context.labels.user_mutable_labels - forbidden_labels).sort
    answer = ask_many_with_completions domain, question, autocomplete_labels, default

    return unless answer

    user_labels = Set.new answer.split(/\s+/)

    user_labels.each do |l|
      if @context.labels.reserved_labels.include?(l)
        @context.screen.minibuf.flash "'#{l}' is a reserved label!"
        return
      elsif forbidden_labels.include?(l)
        @context.screen.minibuf.flash "'#{l}' cannot be applied in this context!"
        return
      end
    end

    user_labels
  end

  def ask_for_contacts domain, question, default_contacts=[]
    default = [default_contacts].flatten.join(", ")
    default += " " unless default.empty?

    answer = ask domain, question, default do |partial|
      completed, target = partial.split_on_commas_with_remainder
      target ||= completed.pop || ""
      completed = completed.join(", ") + (completed.empty? ? "" : ", ")
      @context.client.contacts_with_prefix(target).map do |c|
        matched_component = if c.email.has_prefix?(target)
          c.email
        elsif c.email_ready_address.has_prefix?(target)
          c.email_ready_address
        end
        next unless matched_component

        [completed + c.email_ready_address, c.email_ready_address, completed + matched_component]
      end.compact
    end

    if answer
      answer.split_on_commas.map { |x| Person.from_string(x) }#{ |x| ContactManager.contact_for(x) || Person.from_string(x) }
    end
  end

  def ask_for_account domain, question
    completions = @context.accounts.accounts.map { |a| a.email_ready_address }
    answer = @context.input.ask_many_emails_with_completions domain, question, completions, ""
    answer = @context.accounts.default_account.email if answer == ""
    @context.accounts.account_for Person.from_string(answer).email if answer
  end

  def ask_getch question, accept=nil
    accept = accept.split(//).map { |x| x[0].ord } if accept
    @context.screen.minibuf.set_shortq question
    done = false
    ret = nil
    while true
      key = asking_getchar
      if key == Ncurses::KEY_CANCEL
        break
      elsif accept.nil? || accept.empty? || accept.member?(key)
        ret = key
        break
      end
    end
    @context.screen.minibuf.clear_shortq!
    ret
  end

  ## returns true (y), false (n), or nil (ctrl-g / cancel)
  def ask_yes_or_no question
    case(r = ask_getch(question, "ynYN"))
    when ?y.ord, ?Y.ord
      true
    when nil
      nil
    else
      false
    end
  end

  ## turns an input keystroke into an action symbol. returns the action
  ## if found, nil if not found, and throws InputSequenceAborted if
  ## the user aborted a multi-key sequence. (Because each of those cases
  ## should be handled differently.)
  ##
  ## this is in BufferManager because multi-key sequences require prompting.
  def resolve_input_with_keymap c, keymap
    action, text = keymap.action_for c
    while action.is_a? Keymap # multi-key commands, prompt
      key = ask_getch text
      unless key # user canceled, abort
        @context.screen.minibuf.clear_flash!
        raise InputSequenceAborted
      end
      action, text = action.action_for(key) if action.has_key?(key)
    end
    action
  end
end
end

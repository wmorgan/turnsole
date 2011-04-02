module Turnsole

## manages the global keybindings and behaviors--whatever isn't captured by the
## current buffer
class GlobalBehavior
  include LogsStuff

  GLOBAL_KEYMAP = Keymap.new do |k|
    k.add :quit_ask, "Quit Turnsole, but ask first", 'q'
    k.add :quit_now, "Quit Turnsole immediately", 'Q'
    k.add :help, "Show help", '?'
    k.add :roll_buffers, "Switch to next buffer", 'b'
    k.add :roll_buffers_backwards, "Switch to previous buffer", 'B'
    k.add :kill_buffer, "Kill the current buffer", 'x'
    k.add :list_buffers, "List all buffers", ';'
    k.add :list_contacts, "List contacts", 'C'
    k.add :redraw, "Redraw screen", :ctrl_l
    k.add :search, "Search all messages", '\\', 'F'
    k.add :search_unread, "Show all unread messages", 'U'
    k.add :list_labels, "List labels", 'L'
    k.add :poll, "Poll for new messages", 'P'
    k.add :compose, "Compose new message", 'm', 'c'
    k.add :nothing, "Do nothing", :ctrl_g
    k.add :recall_draft, "Edit most recent draft message", 'R'
    k.add :show_inbox, "Show the Inbox buffer", 'I'
    k.add :clear_hooks, "Clear all hooks", 'H'
    k.add :show_console, "Show the Console buffer", '~'

    ## Submap for less often used keybindings
    k.add_multi "reload (c)olors, rerun (k)eybindings hook", 'O' do |kk|
      kk.add :reload_colors, "Reload colors", 'c'
      kk.add :run_keybindings_hook, "Rerun keybindings hook", 'k'
    end
  end

  HookManager.register "keybindings", <<EOS
Add custom keybindings.
Variables:
  modes: Hash from mode names to mode classes.
  global_keymap: The top-level keymap.
EOS

  def initialize context
    @context = context
  end

  def log; @context.log end
  def keymap; GLOBAL_KEYMAP end

  def run_hook!
    modes = Mode.keymaps.inject({}) { |h, (klass, keymap)| h[Mode.make_name(klass.name)] = klass; h }
    locals = {
      :modes => modes,
      :global_keymap => GLOBAL_KEYMAP
    }
    @context.hooks.run 'keybindings', locals
  end

  def do action
    case action
    when :quit_now
      @context.ui.quit! if @context.screen.kill_all_buffers_safely
    when :quit_ask
      @context.input.asking do
        if @context.input.ask_yes_or_no "Really quit?"
          @context.ui.quit! if @context.screen.kill_all_buffers_safely
        end
      end
    when :help
      mode = @context.screen.focus_buf.mode
      @context.screen.spawn_unless_exists("<help for #{mode.name}>") { HelpMode.new mode, GLOBAL_KEYMAP }
    when :roll_buffers; @context.screen.roll_buffers
    when :roll_buffers_backwards; @context.screen.roll_buffers_backwards
    when :kill_buffer; @context.screen.kill_buffer_safely @context.screen.focus_buf
    when :list_buffers; @context.screen.spawn_unless_exists("buffer list", :system => true) { BufferListMode.new @context }
    when :list_contacts
      b, new = @context.screen.spawn_unless_exists("Contact List") { ContactListMode.new }
      b.mode.load_in_background if new
    when :search
      @context.input.asking do
        query = @context.input.ask :search, "Search all messages (enter for saved searches): "
        unless query.nil?
          if query.empty?
            @context.screen.spawn_unless_exists("Saved searches") { SearchListMode.new }
          else
            SearchResultsMode.spawn_from_query @context, query
          end
        end
      end
    when :search_unread; SearchResultsMode.spawn_from_query "~unread"
    when :list_labels
      labels = @context.labels.all_labels
      @context.input.asking do
        user_label = @context.input.ask_with_completions :label, "Show threads with label (enter for listing): ", labels
        if user_label # not canceled
          if user_label.empty?
            @context.screen.spawn_unless_exists("Label list") do
              mode = LabelListMode.new @context
              mode.load!
              mode
            end
          else
            SearchResultsMode.spawn_from_query @context, "~#{user_label}"
          end
        end
      end
    when :compose; ComposeMode.spawn_nicely
    when :poll; PollManager.poll_now!
    when :recall_draft
      case DraftManager.num_drafts
      when 0
        bm.flash "No draft messages."
      when 1
        m = DraftManager.pop_first
        r = ResumeMode.new(m)
        @context.screen.spawn "Edit message", r
        r.edit_message
      else
        ## TODO fix
        b, new = @context.screen.spawn_unless_exists("All drafts") { LabelSearchResultsMode.new [:draft] }
        b.mode.load_threads :num => b.content_height if new
      end
    when :show_inbox; @context.screen.raise_to_front @context.screen.find_by_mode(InboxMode)
    when :clear_hooks; HookManager.clear!
    when :show_console
      b, new = bm.spawn_unless_exists("Console", :system => true) { ConsoleMode.new }
      b.mode.run
    when :reload_colors
      Colormap.reset!
      Colormap.populate!
      UI.redraw!
      UI.flash "reloaded colors"
    when :run_keybindings_hook
      HookManager.clear_one 'keybindings'
      Keymap.run_hook global_keymap
      UI.flash "keybindings hook run"
    when :nothing, Input::InputSequenceAborted
    when :redraw; @context.screen.mark_dirty!
    else
      UI.flash "Unknown keypress '#{c.to_character}' for #{bm.focus_buf.mode.name}."
    end
  end
end

end

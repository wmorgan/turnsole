require 'locale'
require 'fileutils'
require 'yaml'
require 'ncursesw'
require 'curses'
require 'set'

require "turnsole/util"
require "turnsole/logger"
require "turnsole/hook"

## the following files will call HookManager.register at load time,
## so it's important that they are loaded *after* hookmanager.
require "turnsole/util"
require "turnsole/ui"
require "turnsole/ncurses-patches"
require "turnsole/minibuf"
require "turnsole/screen"
require "turnsole/input"
require "turnsole/buffer"
require "turnsole/mode"
require "turnsole/colormap"
require "turnsole/keymap"
require "turnsole/global"
require "turnsole/logger"
require "turnsole/config"
require "turnsole/client"
require "turnsole/models"
require "turnsole/accounts"
require "turnsole/tagger"
require "turnsole/chunks"
require "turnsole/textfield"
require "turnsole/labels"
require "turnsole/undo"

require "turnsole/modes/scroll-mode"
require "turnsole/modes/text-mode"
require "turnsole/modes/log-mode"
require "turnsole/modes/line-cursor-mode"
require "turnsole/modes/buffer-list-mode"
require "turnsole/modes/thread-index-mode"
require "turnsole/modes/thread-view-mode"
require "turnsole/modes/search-results-mode"
require "turnsole/modes/help-mode"
require "turnsole/modes/inbox-mode"
require "turnsole/modes/completion-mode"

module Turnsole
  VERSION = "git"

class Turnsole # this is passed around as @context to many things
  include LogsStuff

  BASE_DIR  = ENV["TURNSOLE_BASE"] || File.join(ENV["HOME"], ".turnsole")
  CONFIG_FN = File.join BASE_DIR, "config.yaml"
  COLOR_FN  = File.join BASE_DIR, "colors.yaml"
  HOOK_DIR  = File.join BASE_DIR, "hooks"
  LOG_FN    = File.join BASE_DIR, "log.txt"

  attr_reader :encoding, :logger
  def initialize
    FileUtils.mkdir_p BASE_DIR
    @config = Config.new CONFIG_FN

    @logfile = File.open LOG_FN, "a"
    @logger = Logger.new
    @logger.add_sink @logfile
  end

  def log; @logger end # for my own logging

  HookManager.register "startup", <<EOS
Executes at startup.
No variables.
No return value.
EOS

  HookManager.register "shutdown", <<EOS
Executes when sup is shutting down. May be run when sup is crashing,
so don't do anything too important. Run before the label, contacts,
and people are saved.
No variables.
No return value.
EOS

  attr_reader :hooks, :colors, :ui, :screen, :input, :global, :client, :accounts, :labels
  def setup! override_url
    @encoding = detect_encoding
    @hooks = HookManager.new HOOK_DIR, self
    @colors = Colormap.new COLOR_FN, self
    @screen = Screen.new self
    @ui = UI.new self
    @input = Input.new self
    @global = GlobalBehavior.new self
    @client = Client.new self, (override_url || @config.heliotrope_url)
    @accounts = Accounts.new @config.accounts
    @labels = Labels.new self
  end

  def start!
    @colors.populate!
    @global.run_hook!
    @client.start!
    @labels.load!

    @hooks.run "startup"
  end

  def detect_encoding
    ## determine encoding and character set
    encoding = Locale.current.charset
    encoding = "UTF-8" if encoding == "utf8"

    encoding ||= begin
      warn "can't find system encoding from locale, defaulting to utf-8"
      "UTF-8"
    end

    info "system encoding is #{encoding.inspect}"
    encoding
  end

  def shutdown!
    @hooks.run "shutdown"
    @logger.remove_sink @logfile
    @logfile.close
  end
end

end

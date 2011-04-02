require 'yaml'

module Turnsole

class Colormap
  include LogsStuff

  DEFAULT_COLOR_SPECS = {
    :default => { :fg => "default", :bg => "default" },
    :status => { :fg => "white", :bg => "blue", :attrs => ["bold"] },
    :index_old => { :fg => "default", :bg => "default" },
    :index_new => { :fg => "default", :bg => "default", :attrs => ["bold"] },
    :index_starred => { :fg => "yellow", :bg => "default", :attrs => ["bold"] },
    :index_draft => { :fg => "red", :bg => "default", :attrs => ["bold"] },
    :labellist_old => { :fg => "white", :bg => "default" },
    :labellist_new => { :fg => "white", :bg => "default", :attrs => ["bold"] },
    :twiddle => { :fg => "blue", :bg => "default" },
    :label => { :fg => "yellow", :bg => "default" },
    :message_patina => { :fg => "black", :bg => "green" },
    :alternate_patina => { :fg => "black", :bg => "blue" },
    :missing_message => { :fg => "black", :bg => "red" },
    :attachment => { :fg => "cyan", :bg => "default" },
    :cryptosig_valid => { :fg => "yellow", :bg => "default", :attrs => ["bold"] },
    :cryptosig_valid_untrusted => { :fg => "yellow", :bg => "blue", :attrs => ["bold"] },
    :cryptosig_unknown => { :fg => "cyan", :bg => "default" },
    :cryptosig_invalid => { :fg => "yellow", :bg => "red", :attrs => ["bold"] },
    :generic_notice_patina => { :fg => "cyan", :bg => "default" },
    :quote_patina => { :fg => "yellow", :bg => "default" },
    :sig_patina => { :fg => "yellow", :bg => "default" },
    :quote => { :fg => "yellow", :bg => "default" },
    :sig => { :fg => "yellow", :bg => "default" },
    :to_me => { :fg => "green", :bg => "default" },
    :starred => { :fg => "yellow", :bg => "default", :attrs => ["bold"] },
    :starred_patina => { :fg => "yellow", :bg => "green", :attrs => ["bold"] },
    :alternate_starred_patina => { :fg => "yellow", :bg => "blue", :attrs => ["bold"] },
    :snippet => { :fg => "cyan", :bg => "default" },
    :option => { :fg => "white", :bg => "default" },
    :tagged => { :fg => "yellow", :bg => "default", :attrs => ["bold"] },
    :draft_notification => { :fg => "red", :bg => "default", :attrs => ["bold"] },
    :completion_character => { :fg => "white", :bg => "default", :attrs => ["bold"] },
    :horizontal_selector_selected => { :fg => "yellow", :bg => "default", :attrs => ["bold"] },
    :horizontal_selector_unselected => { :fg => "cyan", :bg => "default" },
    :search_highlight => { :fg => "black", :bg => "yellow", :attrs => ["bold"] },
    :system_buf => { :fg => "blue", :bg => "default" },
    :regular_buf => { :fg => "white", :bg => "default" },
    :modified_buffer => { :fg => "yellow", :bg => "default", :attrs => ["bold"] },
    :date => { :fg => "white", :bg => "default"},
  }

  def initialize config_fn, context
    @context = context
    @config_fn = config_fn

    ## map from [fg, bg] pairs to curses color pair ids
    ## it is important to have this entry in here at all times, or colros get
    ## screwed up. i do not understand why.
    @color_pairs = {}
    @next_color_pair_id = 0

    ## map from color pair to color pair id
    @users = {}

    ## map from symbolic name to color spec
    @specs = {}

    ## map from symbolic name to full curses color value
    @cache = {}
  end

  def log; @context.log end

  def reset!
    @users.clear
    @specs.clear
    @cache.clear
    @color_pairs.clear
    @next_color_pair_id = 0
  end

  def add sym, fg, bg, attr=nil, highlight=nil
    raise ArgumentError, "color for #{sym} already defined" if @specs.member? sym
    raise ArgumentError, "color '#{fg}' unknown" unless (-1...Curses::NUM_COLORS).include? fg
    raise ArgumentError, "color '#{bg}' unknown" unless (-1...Curses::NUM_COLORS).include? bg
    attrs = [attr].flatten.compact

    @specs[sym] = [fg, bg, attrs]
    @cache[sym] = nil

    @specs[highlight_sym(sym)] = highlight || default_highlight_for(fg, bg, attrs)
    sym
  end

  def setup!; color_for(:default) end
  def highlight_sym sym; "#{sym}_highlight".intern end

  def default_highlight_for fg, bg, attrs
    hfg = case fg
    when Curses::COLOR_BLUE; Curses::COLOR_WHITE
    when Curses::COLOR_YELLOW, Curses::COLOR_GREEN; fg
    else Curses::COLOR_BLACK
    end

    hbg = case bg
    when Curses::COLOR_CYAN; Curses::COLOR_YELLOW
    when Curses::COLOR_YELLOW; Curses::COLOR_BLUE
    else Curses::COLOR_CYAN
    end

    attrs = if fg == Curses::COLOR_WHITE && attrs.include?(Curses::A_BOLD)
      [Curses::A_BOLD]
    else
      case hfg
      when Curses::COLOR_BLACK; []
      else [Curses::A_BOLD]
      end
    end

    [hfg, hbg, attrs]
  end

  def color_for sym, opts={}
    sym = highlight_sym(sym) if opts[:highlight]
    raise ArgumentError, "undefined color #{sym}" unless @specs.member? sym

    ## if this color is cached, return it
    return @cache[sym] if @cache[sym]

    fg, bg, attrs = @specs[sym]

    ## first see if we have to allocate a new color pair
    cp = @color_pairs[[fg, bg]] ||= begin
      id = @next_color_pair_id
      @next_color_pair_id = (@next_color_pair_id + 1) % Curses::MAX_PAIRS

      Curses.init_pair(id, fg, bg) or raise ArgumentError, "couldn't initialize curses color pair #{fg}, #{bg} (key #{id})"
      cp = @color_pairs[[fg, bg]] = Curses.color_pair(id)
      debug "initializing curses '#{sym}' color pair (#{fg}, #{bg}). my id is #{id}; curses color pair is #{cp}."

      ## delete the old mapping, if it exists
      if @users[cp]
        @users[cp].each do |usym|
          warn "dropping cached color #{usym} (#{id})"
          @cache[usym] = nil
        end
        @users[cp] = []
      end

      cp
    end

    # record entry as a user of that color pair
    (@users[cp] ||= []) << sym

    ## now we have a color pair. let's make a color value
    color = attrs.inject(cp) { |c, a| c | a }
    debug "color value for #{sym} is #{color.inspect} = pair ##{cp.inspect} | #{attrs.inspect}"
    @cache[sym] = color # fill the cache and return
  end

  ## Try to use the user defined colors. In case of an error fall back to the
  ## default ones.
  def populate!
    user_colors = YAML.load_file(@config_fn) rescue {}
    DEFAULT_COLOR_SPECS.merge(user_colors).each do |name, spec|
      fg = begin
        Curses.const_get "COLOR_#{spec[:fg].to_s.upcase}"
      rescue NameError
        warn "there is no color named \"#{spec[:fg]}\""
        Curses::COLOR_GREEN
      end

      bg = begin
        Curses.const_get "COLOR_#{spec[:bg].to_s.upcase}"
      rescue NameError
        warn "there is no color named \"#{spec[:bg]}\""
        Curses::COLOR_RED
      end

      attrs = (spec[:attrs]||[]).map do |a|
        begin
          Curses.const_get "A_#{a.upcase}"
        rescue NameError
          warn "there is no attribute named \"#{a}\", using fallback."
          nil
        end
      end.compact

      add name, fg, bg, attrs, spec[:highlight]
    end
  end
end

end

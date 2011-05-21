module Turnsole

class SearchResultsMode < ThreadIndexMode
  register_keymap do |k|
    k.add :save_search, "Save search", '%'
  end

  def save_search
    name = BufferManager.ask :save_search, "Name this search: "
    return unless name && name !~ /^\s*$/
    name.strip!
    unless SearchManager.valid_name? name
      BufferManager.flash "Not saved: " + SearchManager.name_format_hint
      return
    end
    if SearchManager.all_searches.include? name
      BufferManager.flash "Not saved: \"#{name}\" already exists"
      return
    end
    BufferManager.flash "Search saved as \"#{name}\"" if SearchManager.add name, @query[:text].strip
  end

  ## TODO, maybe: write an is_relevant? method that talks to the index
  ## and asks whether the thread is a member of these search results
  ## or not.
  def self.spawn_from_query context, query
    title = query.length < 20 ? query : query[0 ... 20] + "..."
    mode = SearchResultsMode.new context, query
    buf = context.screen.spawn "search: \"#{title}\"", mode
    mode.load!
  end
end

end

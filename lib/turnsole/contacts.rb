module Turnsole

class Contacts
  def initialize context
    @context = context
    @contacts = Set.new
  end

  attr_reader :contacts

  def load!
    @context.client.contacts { |contacts| @contacts = Set.new contacts }
  end

  def recent_recipients; Set.new end

  def contact_with_alias a; nil end
end

end

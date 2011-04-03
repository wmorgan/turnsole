module Turnsole

class Account
  attr_accessor :address, :signature, :gpgkey, :person

  def initialize h
    @address = h[:address]
    @signature = h[:signature]
    @gpgkey = h[:gpgkey]
    @person = Person.from_string h[:address]
  end

  %w(name email handle displayname).each { |m| define_method(m) { @person.send(m) } }
end

class Accounts
  attr_accessor :default_account

  def initialize accounts
    @default_account = nil
    @accounts = []
    @by_email = {}
    @by_regex = {}

    add_account accounts[:default], true
    accounts.each { |k, v| add_account v unless k == :default }
  end

  ## must be called first with the default account. fills in missing
  ## values from the default account.
  def add_account hash, default=false
    ## fill fields in from default account
    unless default
      [:address, :signature, :gpgkey].each { |k| hash[k] ||= @default_account.send(k) }
    end
    hash[:alternates] ||= []
    hash[:regexen] ||= []

    a = Account.new hash
    @accounts << a
    if default
      raise ArgumentError, "multiple default accounts" if @default_account
      @default_account = a
    end

    ([hash[:email]] + hash[:alternates]).each { |email| @by_email[email] ||= a }
    hash[:regexen].each { |re| @by_regex[Regexp.new(re)] = a }
  end

  def is_account? person; is_account_email?(person.email) end
  def is_account_email? email; !account_for(email).nil? end
  def account_for email
    if(a = @by_email[email])
      a
    else
      @by_regex.find { |re, a| break a if re =~ email }
    end
  end
end

end

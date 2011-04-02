require 'etc'
require 'socket'

module Turnsole
class Config
  class Error < StandardError; end

  def initialize filename
    @config = if File.exists? filename
      load_from_yaml filename
    else
      make_new_config filename
    end
  end

  def method_missing(m, *a)
    raise ArgumentError, "wrong number of arguments" unless a.empty?
    @config[m]
  end

private

  ## put all default configuration here
  def make_new_config fn
    name = Etc.getpwnam(ENV["USER"]).gecos.split(/,/).first rescue nil
    name ||= ENV["USER"]
    email = ENV["USER"] + "@" + begin
      Socket.gethostbyname(Socket.gethostname).first
    rescue SocketError
      Socket.gethostname
    end

    config = {
      :accounts => {
        :default => {
          :address => "#{name} <#{email}>",
          :signature => File.join(ENV["HOME"], ".signature"),
          :gpgkey_filename => ""
        }
      },

      :editor => ENV["EDITOR"] || "/usr/bin/vim -f -c 'set filetype=mail'",
      :edit_signature => false,
      :ask_for_from => false,
      :ask_for_to => true,
      :ask_for_cc => true,
      :ask_for_bcc => false,
      :ask_for_subject => true,

      :confirm_no_attachments => true,
      :confirm_top_posting => true,
      :jump_to_open_message => true,

      :default_attachment_save_dir => "",
      :poll_interval => 300,
      :heliotrope_url => "http://localhost:8042/",
    }

    File.open(fn, "w") { |f| f.write config.to_yaml }
    config
  end

  def load_from_yaml fn
    config = YAML.load_file fn
    raise Error, "#{filename} is not a valid configuration file (it's a #{config.class}, not a hash)" unless config.is_a?(Hash)
    config
  end
end
end

begin
  require 'gpgme'
rescue LoadError
end

module Turnsole

class Crypto
  class Error < StandardError; end

  OUTGOING_MESSAGE_OPERATIONS = [
    [:sign, "Sign"],
    [:sign_and_encrypt, "Sign and encrypt"],
    [:encrypt, "Encrypt only"]
  ]

  DEFAULT_GPG_OPTS = begin
    { :protocol => GPGME::PROTOCOL_OpenPGP, :armor => true, :textmode => true }
  rescue NameError => e
    {}
  end

  HookManager.register "gpg-options", <<EOS
Runs before gpg is called, allowing you to modify the options (most
likely you would want to add something to certain commands, like
{:always_trust => true} to encrypting a message, but who knows).

Variables:
operation: what operation will be done ("sign", "encrypt", "decrypt" or "verify")
options: a dictionary of values to be passed to GPGME

Return value: a dictionary to be passed to GPGME
EOS

  HookManager.register "sig-output", <<EOS
Runs when the signature output is being generated, allowing you to
add extra information to your signatures if you want.

Variables:
signature: the signature object (class is GPGME::Signature)
from_key: the key that generated the signature (class is GPGME::Key)

Return value: an array of lines of output
EOS

  def initialize
    # test if the gpgme gem is available
    @gpgme_present = begin
      begin
        GPGME.check_version :protocol => GPGME::PROTOCOL_OpenPGP
      rescue GPGME::Error
        false
      end
    rescue NameError
      false
    end

    if @gpgme_present
      if (bin = `which gpg2`.chomp) =~ /\S/
        GPGME.set_engine_info GPGME::PROTOCOL_OpenPGP, bin, nil
      end
    end
  end

  def have_crypto?; @gpgme_present end

  def sign from, to, payload
    ensure_crypto!

    gpg_opts = DEFAULT_GPG_OPTS.merge signature_options_for(from)
    gpg_opts = @context.hooks.run("gpg-options", :operation => "sign", :options => gpg_opts) || gpg_opts

    begin
      sig = GPGME.detach_sign format_payload(payload), gpg_opts
    rescue GPGME::Error => e
      info "Error while running gpg: #{e.message}"
      raise Error, "GPG command failed. See log for details."
    end

    envelope = RMail::Message.new
    envelope.header["Content-Type"] = 'multipart/signed; protocol=application/pgp-signature'
    envelope.add_part payload
    signature = RMail::Message.make_attachment sig, "application/pgp-signature", nil, "signature.asc"
    envelope.add_part signature
    envelope
  end

  def encrypt from, to, payload, sign=false
    raise Error, "crypto not enabled" unless have_crypto?

    gpg_opts = DEFAULT_GPG_OPTS
    if sign
      gpg_opts.merge signature_options_for(from)
      gpg_opts.merge :sign => true
    end
    gpg_opts = @context.hooks.run("gpg-options", :operation => "encrypt", :options => gpg_opts) || gpg_opts

    recipients = to + [from]
    begin
      cipher = GPGME.encrypt recipients, format_payload(payload), gpg_opts
    rescue GPGME::Error => e
      info "Error while running gpg: #{e.message}"
      raise Error, "GPG command failed. See log for details."
    end

    encrypted_payload = RMail::Message.new
    encrypted_payload.header["Content-Type"] = "application/octet-stream"
    encrypted_payload.header["Content-Disposition"] = 'inline; filename="msg.asc"'
    encrypted_payload.body = cipher

    control = RMail::Message.new
    control.header["Content-Type"] = "application/pgp-encrypted"
    control.header["Content-Disposition"] = "attachment"
    control.body = "Version: 1\n"

    envelope = RMail::Message.new
    envelope.header["Content-Type"] = 'multipart/encrypted; protocol=application/pgp-encrypted'

    envelope.add_part control
    envelope.add_part encrypted_payload
    envelope
  end

  def sign_and_encrypt from, to, payload
    encrypt from, to, payload, true
  end

  def verify_signature_chunk payload, signature, detached=true # both payload and signature should be RubyMail::Message objects
    ensure_crypto!

    gpg_opts = DEFAULT_GPG_OPTS
    gpg_opts = @context.hooks.run("gpg-options", :operation => "verify", :options => gpg_opts) || gpg_opts
    ctx = GPGME::Ctx.new gpg_opts
    sig_data = GPGME::Data.from_str signature.decode
    signed_data, plain_data = if detached
      [GPGME::Data.from_str(format_payload(payload)), nil]
    else
      [nil, GPGME::Data.empty]
    end
    begin
      ctx.verify(sig_data, signed_data, plain_data)
      signatures_to_chunk ctx.verify_result.signatures
    rescue GPGME::Error => e
      warn "while running gpg: #{e.message}"
      unknown_status_chunk e.message
    end
  end

  ## returns decrypted_message, status, desc, lines
  def decrypt payload, armor=false # a RubyMail::Message object
    ensure_crypto!

    gpg_opts = DEFAULT_GPG_OPTS
    gpg_opts = @context.hooks.run("gpg-options", :operation => "decrypt", :options => gpg_opts) || gpg_opts
    ctx = GPGME::Ctx.new(gpg_opts)
    cipher_data = GPGME::Data.from_str(format_payload(payload))
    plain_data = GPGME::Data.empty
    begin
      ctx.decrypt_verify(cipher_data, plain_data)
    rescue GPGME::Error => e
      warn "while running gpg: #{e.message}"
      return Chunk::CryptoNotice.new(:invalid, "This message could not be decrypted", exc.message)
    end

    sig = signatures_to_chunk ctx.verify_result.signatures
    plain_data.seek(0, IO::SEEK_SET)
    output = plain_data.read.safely_mark_binary

    ## TODO: test to see if it is still necessary to do a 2nd run if verify
    ## fails.
    #
    ## check for a valid signature in an extra run because gpg aborts if the
    ## signature cannot be verified (but it is still able to decrypt)
    #sigoutput = run_gpg "#{payload_fn.path}"
    #sig = self.old_verified_ok? sigoutput, $?

    if armor
      msg = RMail::Message.new
      # Look for Charset, they are put before the base64 crypted part
      if payload =~ /^Charset: (.+)$/
        output = Iconv.easy_decode(@context.charset, $1, output)
      end
      msg.body = output
    else
      ## It appears that some clients use Windows new lines - CRLF - but RMail
      ## splits the body and header on "\n\n". So to allow the parse below to
      ## succeed, we will convert the newlines to what RMail expects
      output = output.gsub(/\r\n/, "\n")
      ## This is gross. This decrypted payload could very well be a multipart
      ## element itself, as opposed to a simple payload. For example, a
      ## multipart/signed element, like those generated by Mutt when encrypting
      ## and signing a message (instead of just clearsigning the body).
      ## Supposedly, decrypted_payload being a multipart element ought to work
      ## out nicely because Message::multipart_encrypted_to_chunks() runs the
      ## decrypted message through message_to_chunks() again to get any
      ## children. However, it does not work as intended because these inner
      ## payloads need not carry a MIME-Version header, yet they are fed to
      ## RMail as a top-level message, for which the MIME-Version header is
      ## required. This causes for the part not to be detected as multipart,
      ## hence being shown as an attachment. If we detect this is happening,
      ## we force the decrypted payload to be interpreted as MIME.
      msg = RMail::Parser.read output
      if !msg.multipart? && msg.header.content_type =~ /^multipart/
        output = "MIME-Version: 1.0\n" + output
        output = output.safely_mark_binary
        msg = RMail::Parser.read output
      end
    end
    notice = Chunk::CryptoNotice.new :valid, "This message has been decrypted for display"
    [notice, sig, msg]
  end

private

  def ensure_crypto!; raise Error, "crypto not enabled" unless have_crypto? end

  def signatures_to_chunk signatures
    valid = tested = trusted = true
    output = []

    signatures.each do |signature|
      this_output, this_trusted = sig_output_lines_for signature
      err_code = GPGME::gpgme_err_code signature.status

      output += this_output
      trusted &&= this_trusted
      valid &&= (err_code == GPGME::GPG_ERR_NO_ERROR)
      tested &&= (err_code == GPGME::GPG_ERR_NO_ERROR) || (err_code == GPGME::GPG_ERR_BAD_SIGNATURE)
    end

    sig_from = if signatures.size > 0
      signatures.first.to_s.sub(/from [0-9A-F]{16} /, "from ")
    end

    if output.length == 0
      Chunk::CryptoNotice.new :valid, "Encrypted but unsigned message", output
    elsif valid && trusted
      Chunk::CryptoNotice.new :valid, sig_from, output
    elsif valid && !trusted
      Chunk::CryptoNotice.new :valid_untrusted, sig_from, output
    elsif tested
      Chunk::CryptoNotice.new :invalid, sig_from, output
    else
      unknown_status_chunk output
    end
  end

  def unknown_status_chunk lines=[]
    Chunk::CryptoNotice.new :unknown, "Unable to determine validity of cryptographic signature", lines
  end

  ## here's where we munge rmail output into the format that signed/encrypted
  ## PGP/GPG messages should be
  def format_payload payload
    payload.to_s.gsub(/(^|[^\r])\n/, "\\1\r\n")
  end

  def sig_output_lines_for signature
    ## it appears that the signature.to_s call can lead to a EOFError if the
    ## key is not found. So start by looking for the key.
    ctx = GPGME::Ctx.new
    from_key, first_sig = begin
      from = ctx.get_key signature.fingerprint
      first = signature.to_s.sub(/from [0-9A-F]{16} /, 'from "') + '"'
      [from, first]
    rescue EOFError
      [nil, "No public key available for #{signature.fingerprint}"]
    end

    time_line = "Signature made " + signature.timestamp.strftime("%a %d %b %Y %H:%M:%S %Z") +
                " using " + key_type(from_key, signature.fingerprint) +
                "key ID " + signature.fingerprint[-8..-1]
    output_lines = [time_line, first_sig]

    trusted = false
    if from_key
      ## first list all the uids
      if from_key.uids.length > 1
        aka_list = from_key.uids[1..-1]
        aka_list.each { |aka| output_lines << '                aka "' + aka.uid + '"' }
      end

      ## now we want to look at the trust of that key
      if signature.validity != GPGME::GPGME_VALIDITY_FULL && signature.validity != GPGME::GPGME_VALIDITY_MARGINAL
        output_lines << "WARNING: This key is not certified with a trusted signature!"
        output_lines << "There is no indication that the signature belongs to the owner."
      else
        trusted = true
      end

      # finally, run the hook
      output_lines << @context.hooks.run("sig-output", :signature => signature, :from_key => from_key)
    end

    [output_lines, trusted]
  end

  def key_type key, fpr
    return "" if key.nil?
    subkey = key.subkeys.find { |subkey| subkey.fpr == fpr || subkey.keyid == fpr }
    return "" if subkey.nil?

    case subkey.pubkey_algo
    when GPGME::PK_RSA then "RSA "
    when GPGME::PK_DSA then "DSA "
    when GPGME::PK_ELG then "ElGamel "
    when GPGME::PK_ELG_E then "ElGamel "
    end
  end

  # logic is:
  # if    gpgkey set for this account, then use that
  # elsif only one account,            then leave blank so gpg default will be user
  # else                               set --local-user from_email_address
  def signature_options_for from_address
    account = @context.accounts.account_for(from_address) || @context.accounts.default_account
    if account.gpgkey
      { :signers => account.gpgkey }
    elsif @context.accounts.accounts.size == 1 # only have one account
      {}
    else
      { :signers => from_address }
    end
  end
end
end

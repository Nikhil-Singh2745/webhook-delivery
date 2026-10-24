class EndpointSecret
  class Unavailable < StandardError; end

  KEY_PATH = Rails.root.join("config/endpoint_encryption.key")

  def self.prepare_key!
    unless ENV.key?("ENDPOINT_ENCRYPTION_KEY") || File.exist?(KEY_PATH)
      begin
        File.open(KEY_PATH, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
          file.write(SecureRandom.hex(32))
        end
      rescue Errno::EEXIST
        # A concurrent setup invocation has already created the key.
      end
    end
    encryptor
    nil
  end

  def self.encrypt(secret, endpoint_id:)
    encryptor.encrypt_and_sign(secret, purpose: "endpoint:#{endpoint_id}")
  end

  def self.decrypt(ciphertext, endpoint_id:)
    encryptor.decrypt_and_verify(ciphertext, purpose: "endpoint:#{endpoint_id}") || raise(Unavailable)
  rescue ActiveSupport::MessageEncryptor::InvalidMessage
    raise Unavailable
  end

  def self.encryptor
    encoded = ENV.fetch("ENDPOINT_ENCRYPTION_KEY") { File.read(KEY_PATH).strip }
    raise Unavailable unless encoded.ascii_only? && encoded.match?(/\A[0-9a-f]{64}\z/)

    ActiveSupport::MessageEncryptor.new([encoded].pack("H*"), cipher: "aes-256-gcm", serializer: :json)
  rescue Errno::ENOENT, Errno::EACCES
    raise Unavailable
  end
  private_class_method :encryptor
end

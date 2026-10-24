require_relative "../../config/environment"
require "minitest/autorun"
require "tmpdir"

class EndpointSecretTest < Minitest::Test
  def setup
    @previous_key = ENV["ENDPOINT_ENCRYPTION_KEY"]
    ENV["ENDPOINT_ENCRYPTION_KEY"] = "a" * 64
  end

  def teardown
    @previous_key.nil? ? ENV.delete("ENDPOINT_ENCRYPTION_KEY") : ENV["ENDPOINT_ENCRYPTION_KEY"] = @previous_key
  end

  def test_encryption_is_randomized_and_bound_to_the_endpoint
    secret = "whsec_#{SecureRandom.urlsafe_base64(32, false)}"
    id = SecureRandom.uuid
    first = EndpointSecret.encrypt(secret, endpoint_id: id)
    second = EndpointSecret.encrypt(secret, endpoint_id: id)
    refute_equal first, second
    refute_includes first, secret
    assert_equal secret, EndpointSecret.decrypt(first, endpoint_id: id)
    assert_raises(EndpointSecret::Unavailable) { EndpointSecret.decrypt(first, endpoint_id: SecureRandom.uuid) }
    assert_raises(EndpointSecret::Unavailable) { EndpointSecret.decrypt(first.reverse, endpoint_id: id) }
    ENV["ENDPOINT_ENCRYPTION_KEY"] = "b" * 64
    assert_raises(EndpointSecret::Unavailable) { EndpointSecret.decrypt(first, endpoint_id: id) }
  end

  def test_missing_and_invalid_keys_fail_closed
    ["", "a" * 63, "G" * 64, "a" * 65].each do |key|
      ENV["ENDPOINT_ENCRYPTION_KEY"] = key
      assert_raises(EndpointSecret::Unavailable) { EndpointSecret.encrypt("secret", endpoint_id: "id") }
      assert_raises(EndpointSecret::Unavailable) { EndpointSecret.prepare_key! }
    end
  end

  def test_local_key_creation_is_private_repeatable_and_does_not_print_the_key
    Dir.mktmpdir do |directory|
      path = Pathname.new(directory).join("encryption.key")
      original_path = EndpointSecret::KEY_PATH
      EndpointSecret.send(:remove_const, :KEY_PATH)
      EndpointSecret.const_set(:KEY_PATH, path)
      begin
        ENV.delete("ENDPOINT_ENCRYPTION_KEY")
        assert_raises(EndpointSecret::Unavailable) { EndpointSecret.encrypt("secret", endpoint_id: "id") }
        EndpointSecret.prepare_key!
        first = File.read(path)
        assert_match(/\A[0-9a-f]{64}\z/, first)
        assert_equal 0o600, File.stat(path).mode & 0o777
        EndpointSecret.prepare_key!
        assert_equal first, File.read(path)
        encrypted = EndpointSecret.encrypt("secret", endpoint_id: "id")
        assert_equal "secret", EndpointSecret.decrypt(encrypted, endpoint_id: "id")
      ensure
        EndpointSecret.send(:remove_const, :KEY_PATH)
        EndpointSecret.const_set(:KEY_PATH, original_path)
      end
    end
  end
end

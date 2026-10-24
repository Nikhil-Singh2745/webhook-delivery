require "test_helper"

class ApiCredentialTest < ActiveSupport::TestCase
  test "issuance returns a random token but persists only its digest" do
    tenant = create_tenant
    credential, token = ApiCredential.issue!(tenant: tenant)
    second_credential, second_token = ApiCredential.issue!(tenant: tenant)

    assert_match(/\Awhapi_[A-Za-z0-9_-]{43}\z/, token)
    assert_equal 32, Base64.urlsafe_decode64(token.delete_prefix("whapi_")).bytesize
    assert_not_equal token, second_token
    assert_not_equal credential.token_digest, second_credential.token_digest
    assert_equal Digest::SHA256.hexdigest(token), credential.reload.token_digest
    assert_equal tenant, credential.tenant
    assert_nil credential.revoked_at
    assert_not_includes credential.attributes.values, token
    assert_not_includes credential.inspect, token
    assert_equal credential, ApiCredential.authenticate(token)
    assert_nil ApiCredential.authenticate(credential.token_digest)
  end

  test "unknown and malformed tokens do not authenticate" do
    [nil, "", "wrong", "whapi_#{'a' * 43}", "whapi_#{'a' * 44}", "\xff".b, 123].each do |token|
      assert_nil ApiCredential.authenticate(token)
    end
  end

  test "revocation invalidates only that credential and retains its first timestamp" do
    tenant = create_tenant
    credential, token = ApiCredential.issue!(tenant: tenant)
    other_credential, other_token = ApiCredential.issue!(tenant: tenant)

    travel_to Time.utc(2026, 10, 24, 12) do
      credential.revoke!
    end
    revoked_at = credential.revoked_at
    travel_to Time.utc(2026, 10, 24, 13) do
      credential.revoke!
    end

    assert_equal revoked_at, credential.revoked_at
    assert_nil ApiCredential.authenticate(token)
    assert_equal other_credential, ApiCredential.authenticate(other_token)
  end

  test "issuance and authentication do not send raw tokens to the application logger" do
    output = StringIO.new
    original_logger = ActiveRecord::Base.logger
    ActiveRecord::Base.logger = ActiveSupport::Logger.new(output)

    credential, token = ApiCredential.issue!(tenant: create_tenant)
    assert_equal credential, ApiCredential.authenticate(token)
    credential.revoke!
    assert_nil ApiCredential.authenticate(token)

    assert_not_empty output.string
    assert_not_includes output.string, token
  ensure
    ActiveRecord::Base.logger = original_logger
  end

  test "credential and authorization parameters are filtered" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    parameters = {"authorization" => "Bearer example", "credential" => "example", "token_digest" => "example"}

    assert_equal parameters.transform_values { "[FILTERED]" }, filter.filter(parameters)
  end
end

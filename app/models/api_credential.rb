class ApiCredential < ApplicationRecord
  TOKEN_PATTERN = /\Awhapi_[A-Za-z0-9_-]{43}\z/

  belongs_to :tenant, inverse_of: :api_credentials

  attr_readonly :tenant_id, :token_digest

  validates :token_digest, presence: true

  def self.issue!(tenant:)
    token = "whapi_#{SecureRandom.urlsafe_base64(32, false)}"
    credential = tenant.api_credentials.create!(token_digest: Digest::SHA256.hexdigest(token))
    [credential, token]
  end

  def self.authenticate(token)
    return unless token.is_a?(String) && token.ascii_only? && TOKEN_PATTERN.match?(token)

    find_by(token_digest: Digest::SHA256.hexdigest(token), revoked_at: nil)
  end

  def revoke!
    # Concurrent/repeated revocations retain the first committed timestamp.
    self.class.where(id: id, revoked_at: nil).update_all(revoked_at: Time.current, updated_at: Time.current)
    reload
  end
end

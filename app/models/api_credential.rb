class ApiCredential < ApplicationRecord
  belongs_to :tenant, inverse_of: :api_credentials

  attr_readonly :tenant_id, :token_digest

  validates :token_digest, presence: true
end

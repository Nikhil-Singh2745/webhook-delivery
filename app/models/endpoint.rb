class Endpoint < ApplicationRecord
  belongs_to :tenant, inverse_of: :endpoints
  has_many :deliveries, inverse_of: :endpoint

  attr_readonly :tenant_id, :url, :signing_secret_ciphertext

  validates :url, :signing_secret_ciphertext, presence: true
end

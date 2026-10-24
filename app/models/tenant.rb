class Tenant < ApplicationRecord
  has_many :api_credentials, inverse_of: :tenant
  has_many :endpoints, inverse_of: :tenant
  has_many :events, inverse_of: :tenant
  has_many :deliveries, inverse_of: :tenant
  has_many :delivery_attempts, through: :deliveries

  validates :name, presence: true
end

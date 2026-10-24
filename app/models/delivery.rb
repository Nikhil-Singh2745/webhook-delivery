class Delivery < ApplicationRecord
  belongs_to :tenant, inverse_of: :deliveries
  belongs_to :event, inverse_of: :deliveries
  belongs_to :endpoint, inverse_of: :deliveries
  has_many :delivery_attempts, inverse_of: :delivery

  attr_readonly :tenant_id, :event_id, :endpoint_id
end

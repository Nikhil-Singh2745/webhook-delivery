class Event < ApplicationRecord
  belongs_to :tenant, inverse_of: :events
  has_many :deliveries, inverse_of: :event

  validates :idempotency_key, :request_fingerprint, :event_type, :outbound_body, presence: true

  def readonly?
    persisted? || super
  end
end

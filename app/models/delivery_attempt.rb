class DeliveryAttempt < ApplicationRecord
  belongs_to :delivery, inverse_of: :delivery_attempts
  has_one :tenant, through: :delivery

  attr_readonly :delivery_id, :run_number, :attempt_number, :started_at
end

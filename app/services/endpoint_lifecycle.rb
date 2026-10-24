class EndpointLifecycle
  class Disabled < StandardError; end

  def self.register!(tenant:, url:)
    EndpointDestination.validate!(url)
    endpoint_id = SecureRandom.uuid
    secret = "whsec_#{SecureRandom.urlsafe_base64(32, false)}"
    ciphertext = EndpointSecret.encrypt(secret, endpoint_id: endpoint_id)

    endpoint = tenant.with_lock do
      tenant.endpoints.create!(id: endpoint_id, url: url, signing_secret_ciphertext: ciphertext)
    end
    [endpoint, secret]
  end

  def self.disable!(tenant:, endpoint_id:)
    with_locked_endpoint(tenant: tenant, endpoint_id: endpoint_id) do |endpoint|
      now = Time.current
      endpoint.update!(status: "disabled", disabled_at: now) unless endpoint.status == "disabled"
      endpoint.deliveries.where(state: %w[pending retry_wait]).update_all(
        state: "canceled", next_attempt_at: nil, updated_at: now
      )
      endpoint
    end
  end

  # Ingestion, claims, and replay must take tenant -> endpoint -> delivery locks.
  # Keep only database work inside this block; network I/O happens after commit.
  def self.with_active_endpoint(tenant:, endpoint_id:)
    with_locked_endpoint(tenant: tenant, endpoint_id: endpoint_id) do |endpoint|
      raise Disabled if endpoint.status != "active"
      yield endpoint
    end
  end

  def self.with_locked_endpoint(tenant:, endpoint_id:)
    tenant.with_lock do
      endpoint = tenant.endpoints.lock.find(endpoint_id)
      yield endpoint
    end
  end
  private_class_method :with_locked_endpoint
end

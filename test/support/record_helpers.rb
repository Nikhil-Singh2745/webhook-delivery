module RecordHelpers
  def create_tenant
    Tenant.create!(name: "Example tenant")
  end

  def create_endpoint(tenant:, **attributes)
    Endpoint.create!({
      tenant: tenant,
      url: "https://receiver.example/webhooks",
      signing_secret_ciphertext: "opaque-ciphertext-placeholder"
    }.merge(attributes))
  end

  def create_event(tenant:, **attributes)
    id = SecureRandom.uuid
    created_at = Time.current.utc
    event_type = attributes.fetch(:event_type, "invoice.created")
    data = attributes.fetch(:data, {"invoice_id" => "demo_invoice_1"})
    outbound_body = JSON.generate(id: id, type: event_type, created_at: created_at.iso8601(6), data: data)

    Event.create!({
      id: id,
      tenant: tenant,
      idempotency_key: SecureRandom.uuid,
      request_fingerprint: Digest::SHA256.hexdigest(JSON.generate(type: event_type, data: data)),
      event_type: event_type,
      data: data,
      outbound_body: outbound_body,
      delivery_count: 1,
      created_at: created_at
    }.merge(attributes))
  end

  def create_delivery(tenant:, event:, endpoint:, **attributes)
    Delivery.create!({tenant: tenant, event: event, endpoint: endpoint}.merge(attributes))
  end

  def create_attempt(delivery:, **attributes)
    started_at = Time.current
    DeliveryAttempt.create!({
      delivery: delivery,
      run_number: 1,
      attempt_number: 1,
      outcome: "transient_failure",
      started_at: started_at,
      finished_at: started_at + 1.second,
      http_status: 503,
      error_code: "http_transient"
    }.merge(attributes))
  end

  def insert_copy(record, **attributes)
    record.class.insert_all!([record.attributes.except("id").merge(attributes.stringify_keys)])
  end

  def assert_database_error(exception, &block)
    error = assert_raises(exception) do
      # A savepoint keeps an expected PostgreSQL error from aborting the surrounding test transaction.
      ApplicationRecord.transaction(requires_new: true, &block)
    end
    assert_instance_of PG::CheckViolation, error.cause if exception == ActiveRecord::StatementInvalid
    error
  end
end

require "test_helper"

class DomainRecordsTest < ActiveSupport::TestCase
  setup do
    @tenant = create_tenant
    @endpoint = create_endpoint(tenant: @tenant)
    @event = create_event(tenant: @tenant)
    @delivery = create_delivery(tenant: @tenant, event: @event, endpoint: @endpoint)
  end

  test "records have UUIDs and navigate their tenant relationships" do
    credential = @tenant.api_credentials.create!(token_digest: Digest::SHA256.hexdigest("test-credential"))
    attempt = create_attempt(delivery: @delivery)

    [@tenant, credential, @endpoint, @event, @delivery, attempt].each do |record|
      assert_match(/\A[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\z/, record.id)
    end
    assert_equal [credential], @tenant.api_credentials.to_a
    assert_equal [@endpoint], @tenant.endpoints.to_a
    assert_equal [@event], @tenant.events.to_a
    assert_equal [@delivery], @event.deliveries.to_a
    assert_equal [@delivery], @endpoint.deliveries.to_a
    assert_equal [attempt], @tenant.delivery_attempts.to_a
    assert_equal @tenant, attempt.tenant
  end

  test "new deliveries have an immediately eligible empty first run" do
    assert_equal "pending", @delivery.state
    assert_equal 1, @delivery.run_number
    assert_equal 0, @delivery.attempts_in_run
    assert_equal 0, @delivery.total_attempts
    assert_operator @delivery.next_attempt_at, :<=, Time.current
  end

  test "an event cannot be saved or destroyed through a model" do
    assert_raises(ActiveRecord::ReadOnlyRecord) { @event.update!(event_type: "invoice.changed") }
    assert_raises(ActiveRecord::ReadOnlyRecord) { @event.destroy! }
  end

  test "event content and serialized bytes survive reload unchanged" do
    original_body = @event.outbound_body.dup
    @event.reload

    assert_equal original_body, @event.outbound_body
    assert_equal @event.id, JSON.parse(original_body).fetch("id")
    assert_equal @event.data, JSON.parse(original_body).fetch("data")
  end

  test "the database rejects duplicate event keys within a tenant" do
    assert_database_error(ActiveRecord::RecordNotUnique) { insert_copy(@event) }
    assert_equal 1, @tenant.events.count
  end

  test "different tenants can reuse an event key" do
    other_event = create_event(tenant: create_tenant, idempotency_key: @event.idempotency_key)
    assert_not_equal @event.id, other_event.id
  end

  test "different event keys can have identical request fingerprints" do
    other_event = create_event(tenant: @tenant)
    assert_equal @event.request_fingerprint, other_event.request_fingerprint
  end

  test "the database rejects duplicate event and endpoint deliveries" do
    assert_database_error(ActiveRecord::RecordNotUnique) { insert_copy(@delivery) }
    assert_equal 1, @event.deliveries.count
  end

  test "separate endpoint registrations with the same URL each receive a delivery" do
    other_endpoint = create_endpoint(tenant: @tenant, url: @endpoint.url)
    other_delivery = create_delivery(tenant: @tenant, event: @event, endpoint: other_endpoint)
    assert_not_equal @delivery.id, other_delivery.id
  end

  test "the database rejects an event owned by another tenant" do
    other_event = create_event(tenant: create_tenant)
    assert_database_error(ActiveRecord::InvalidForeignKey) do
      insert_copy(@delivery, event_id: other_event.id)
    end
  end

  test "the database rejects an endpoint owned by another tenant" do
    other_endpoint = create_endpoint(tenant: create_tenant)
    assert_database_error(ActiveRecord::InvalidForeignKey) do
      insert_copy(@delivery, endpoint_id: other_endpoint.id)
    end
  end

  test "the database rejects missing parents" do
    assert_database_error(ActiveRecord::InvalidForeignKey) do
      insert_copy(@endpoint, tenant_id: SecureRandom.uuid)
    end
    assert_database_error(ActiveRecord::InvalidForeignKey) do
      insert_copy(@delivery, event_id: SecureRandom.uuid)
    end
    assert_database_error(ActiveRecord::InvalidForeignKey) do
      insert_copy(@delivery, endpoint_id: SecureRandom.uuid)
    end
    attempt = create_attempt(delivery: @delivery)
    assert_database_error(ActiveRecord::InvalidForeignKey) do
      insert_copy(attempt, delivery_id: SecureRandom.uuid)
    end
  end

  test "referenced parents cannot be deleted" do
    [@tenant, @endpoint, @delivery].each do |record|
      create_attempt(delivery: @delivery) if record == @delivery
      assert_database_error(ActiveRecord::InvalidForeignKey) { record.delete }
    end
  end

  test "credential digests are globally unique and formatted as SHA256" do
    credential = @tenant.api_credentials.create!(token_digest: Digest::SHA256.hexdigest("test-credential"))
    assert_database_error(ActiveRecord::RecordNotUnique) do
      insert_copy(credential, tenant_id: create_tenant.id)
    end
    assert_database_error(ActiveRecord::StatementInvalid) { insert_copy(credential, token_digest: "raw-token") }
    credential.update!(revoked_at: Time.current)
    assert credential.reload.revoked_at
  end

  test "endpoint status must agree with its disable timestamp" do
    [{status: "invalid"}, {status: "disabled"}, {disabled_at: Time.current}].each do |attributes|
      assert_database_error(ActiveRecord::StatementInvalid) { insert_copy(@endpoint, **attributes) }
    end
    @endpoint.update!(status: "disabled", disabled_at: Time.current)
    assert_equal "disabled", @endpoint.reload.status
  end

  test "database required fields cannot be null even without validations" do
    [[@endpoint, :tenant_id], [@endpoint, :signing_secret_ciphertext], [@event, :data],
      [@delivery, :event_id], [@delivery, :endpoint_id]].each do |record, field|
      assert_database_error(ActiveRecord::NotNullViolation) { insert_copy(record, **{field => nil}) }
    end
  end

  test "event fields obey the contract at the database boundary" do
    [
      {idempotency_key: ""}, {idempotency_key: "invalid key"},
      {request_fingerprint: "invalid"},
      {event_type: "Invoice.created"}, {event_type: "invoice..created"},
      {data: []}, {data: "text"},
      {delivery_count: -1}, {outbound_body: ""}, {outbound_body: "a" * 131_073}
    ].each do |attributes|
      assert_database_error(ActiveRecord::StatementInvalid) { insert_copy(@event, **attributes) }
    end
  end

  test "the database enforces event key and type length limits" do
    [{idempotency_key: "a" * 129}, {event_type: "a" * 101}].each do |attributes|
      assert_database_error(ActiveRecord::ValueTooLong) { insert_copy(@event, **attributes) }
    end
  end

  test "outbound size is measured in bytes rather than characters" do
    assert_database_error(ActiveRecord::StatementInvalid) do
      insert_copy(@event, outbound_body: "é" * 65_537)
    end
  end

  test "zero endpoint events and maximum allowed field sizes are accepted" do
    event = create_event(tenant: @tenant, delivery_count: 0, idempotency_key: "a" * 128,
      event_type: "a" * 100, outbound_body: "a" * 131_072)
    assert_equal 0, event.delivery_count
    assert_equal 131_072, event.outbound_body.bytesize
  end

  test "the database prevents bulk event updates including identity and body changes" do
    {event_type: "invoice.changed", tenant_id: create_tenant.id, data: {}, outbound_body: "changed",
      idempotency_key: "changed", delivery_count: 2}.each do |field, value|
      assert_database_error(ActiveRecord::StatementInvalid) do
        Event.where(id: @event.id).update_all(field => value)
      end
    end
    assert_equal "invoice.created", @event.reload.event_type
  end

  test "the database prevents event deletion even when no delivery references it" do
    event = create_event(tenant: @tenant, delivery_count: 0)
    assert_database_error(ActiveRecord::StatementInvalid) { Event.where(id: event.id).delete_all }
    assert Event.exists?(event.id)
  end

  test "delivery states counters and schedules reject inconsistent rows" do
    [
      {state: "invalid"}, {run_number: 0}, {attempts_in_run: -1},
      {attempts_in_run: 9, total_attempts: 9}, {total_attempts: -1},
      {next_attempt_at: nil}, {state: "delivering", next_attempt_at: nil},
      {state: "pending", attempts_in_run: 1, total_attempts: 1},
      {state: "retry_wait", attempts_in_run: 8, total_attempts: 8},
      {state: "failed", attempts_in_run: 1, total_attempts: 1},
      {last_error_code: "unsafe raw exception message"}
    ].each do |attributes|
      assert_database_error(ActiveRecord::StatementInvalid) do
        Delivery.where(id: @delivery.id).update_all(attributes)
      end
    end
  end

  test "delivery states allow completed runs and fresh replay counters" do
    %w[delivering succeeded failed canceled].each do |state|
      @delivery.update!(state: state, next_attempt_at: nil, attempts_in_run: 8, total_attempts: 8)
      assert_equal state, @delivery.reload.state
    end
    @delivery.update!(state: "pending", run_number: 2, attempts_in_run: 0, next_attempt_at: Time.current)
    assert_equal 8, @delivery.reload.total_attempts
    @delivery.update!(state: "retry_wait", attempts_in_run: 1, total_attempts: 9)
    assert_equal "retry_wait", @delivery.reload.state
  end

  test "attempt identities cannot repeat within a run" do
    attempt = create_attempt(delivery: @delivery)
    assert_database_error(ActiveRecord::RecordNotUnique) { insert_copy(attempt) }
  end

  test "attempt numbering restarts in a new run while earlier history remains" do
    first = create_attempt(delivery: @delivery)
    second = create_attempt(delivery: @delivery, run_number: 2)
    assert_equal [first, second], @delivery.delivery_attempts.order(:run_number, :attempt_number).to_a
  end

  test "different deliveries can use the same attempt number" do
    other_delivery = create_delivery(tenant: @tenant, event: @event, endpoint: create_endpoint(tenant: @tenant))
    create_attempt(delivery: @delivery)
    assert create_attempt(delivery: other_delivery).persisted?
  end

  test "attempt numbers must be positive and stay within the per run budget" do
    attempt = create_attempt(delivery: @delivery)
    [{run_number: 0}, {run_number: -1}, {attempt_number: 0}, {attempt_number: 9}].each do |attributes|
      assert_database_error(ActiveRecord::StatementInvalid) { insert_copy(attempt, **attributes) }
    end
    assert create_attempt(delivery: @delivery, attempt_number: 8).persisted?
  end

  test "only one in progress attempt can exist for a delivery across runs" do
    create_attempt(delivery: @delivery, outcome: "in_progress", finished_at: nil, http_status: nil, error_code: nil)
    assert_database_error(ActiveRecord::RecordNotUnique) do
      create_attempt(delivery: @delivery, run_number: 2,
        outcome: "in_progress", finished_at: nil, http_status: nil, error_code: nil)
    end
  end

  test "attempt outcomes timestamps and statuses reject inconsistent rows" do
    attempt = create_attempt(delivery: @delivery)
    [
      {outcome: "invalid"}, {outcome: "in_progress"}, {finished_at: nil},
      {finished_at: attempt.started_at - 1.second}, {http_status: 99}, {http_status: 600},
      {outcome: "succeeded", http_status: nil}, {outcome: "succeeded", http_status: 503},
      {error_code: "raw exception details"}
    ].each do |attributes|
      assert_database_error(ActiveRecord::StatementInvalid) { insert_copy(attempt, **attributes) }
    end
  end

  test "attempt history can record every terminal outcome including uncertain receipt" do
    %w[succeeded transient_failure permanent_failure unknown canceled].each_with_index do |outcome, index|
      status = case outcome
      when "succeeded" then 204
      when "transient_failure" then 429
      when "permanent_failure" then 302
      end
      attempt = create_attempt(delivery: @delivery, attempt_number: index + 1,
        outcome: outcome, http_status: status, error_code: nil)
      assert_equal outcome, attempt.reload.outcome
    end
  end
end

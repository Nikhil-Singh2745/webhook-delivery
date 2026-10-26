require "test_helper"

class EventFanoutTest < ActiveSupport::TestCase
  setup do
    @tenant = create_tenant
    @body = '{"type":"invoice.created","data":{}}'
  end

  test "snapshot includes each active tenant endpoint with immediately eligible durable work" do
    endpoints = 2.times.map { create_endpoint(tenant: @tenant) }
    disabled = create_endpoint(tenant: @tenant)
    EndpointLifecycle.disable!(tenant: @tenant, endpoint_id: disabled.id)
    create_endpoint(tenant: create_tenant)

    result = ingest
    event = result.event.reload
    assert_equal 2, event.delivery_count
    assert_equal endpoints.map(&:id).sort, event.deliveries.pluck(:endpoint_id).sort
    assert_equal [@tenant.id], event.deliveries.distinct.pluck(:tenant_id)
    event.deliveries.each do |delivery|
      assert_equal "pending", delivery.state
      assert_equal 1, delivery.run_number
      assert_equal 0, delivery.attempts_in_run
      assert_equal 0, delivery.total_attempts
      assert_operator delivery.next_attempt_at, :<=, Time.current
      assert_nil delivery.last_error_code
      assert_empty delivery.delivery_attempts
      assert_equal event.outbound_body, delivery.event.outbound_body
    end
  end

  test "retry after lost response preserves committed work and original count after endpoint changes" do
    endpoint = create_endpoint(tenant: @tenant)
    event_id = ingest.event.id
    original = Event.find(event_id).attributes
    delivery_id = Event.find(event_id).deliveries.sole.id
    EndpointLifecycle.disable!(tenant: @tenant, endpoint_id: endpoint.id)
    create_endpoint(tenant: @tenant)

    assert_no_difference ["Event.count", "Delivery.count"] do
      result = ingest
      assert result.replayed
      assert_equal original, result.event.attributes
      assert_equal 1, result.event.delivery_count
      assert_equal delivery_id, result.event.deliveries.sole.id
      assert_equal "canceled", result.event.deliveries.sole.state
    end
  end

  test "zero-endpoint event remains empty after later registration" do
    event = ingest.event
    assert_equal 0, event.delivery_count
    create_endpoint(tenant: @tenant)
    assert_no_difference "Delivery.count" do
      assert_equal event.id, ingest.event.id
    end
    assert_empty event.deliveries
  end

  test "failure after a full insert batch rolls back the event and every delivery and permits retry" do
    # The failure occurs in the second batch after 500 rows have actually been inserted.
    endpoint_ids = 501.times.map { create_endpoint(tenant: @tenant).id }.sort
    connection = ApplicationRecord.connection
    connection.execute(<<~SQL)
      CREATE FUNCTION pg_temp.reject_initial_delivery() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN RAISE EXCEPTION 'test fanout failure'; END;
      $$;
      CREATE TRIGGER reject_initial_delivery BEFORE INSERT ON deliveries
      FOR EACH ROW WHEN (NEW.endpoint_id = '#{endpoint_ids.last}'::uuid)
      EXECUTE FUNCTION pg_temp.reject_initial_delivery();
    SQL
    assert_no_difference ["Event.count", "Delivery.count"] do
      assert_raises(ActiveRecord::StatementInvalid) do
        ApplicationRecord.transaction(requires_new: true) { ingest }
      end
    end
    connection.execute("DROP TRIGGER reject_initial_delivery ON deliveries")
    result = ingest
    refute result.replayed
    assert_equal 501, result.event.delivery_count
    assert_equal endpoint_ids, result.event.deliveries.order(:endpoint_id).pluck(:endpoint_id)
  end

  private

  def ingest
    EventIngestion.call(tenant: @tenant, idempotency_key: "fanout", raw_body: @body)
  end
end

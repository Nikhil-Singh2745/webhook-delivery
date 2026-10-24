require "test_helper"

class EndpointLifecycleTest < ActiveSupport::TestCase
  test "registration persists only encrypted secrets and repeated URLs receive independent secrets" do
    tenant = create_tenant
    first, first_secret = EndpointLifecycle.register!(tenant: tenant, url: "https://8.8.8.8/hooks")
    second, second_secret = EndpointLifecycle.register!(tenant: tenant, url: first.url)
    assert_not_equal first.id, second.id
    assert_not_equal first_secret, second_secret
    [first_secret, second_secret].each do |secret|
      assert_match(/\Awhsec_[A-Za-z0-9_-]{43}\z/, secret)
      assert_equal 32, Base64.urlsafe_decode64(secret.delete_prefix("whsec_")).bytesize
      assert_not_includes first.attributes.values, secret
    end
    assert_equal first_secret, first.reload.signing_secret
    assert_equal second_secret, second.reload.signing_secret
    assert_equal "active", first.status
    assert_nil first.disabled_at
    assert_not_includes first.inspect, first_secret
  end

  test "invalid destinations and unavailable encryption cannot create an endpoint" do
    tenant = create_tenant
    assert_no_difference "Endpoint.count" do
      assert_raises(EndpointDestination::Invalid) { EndpointLifecycle.register!(tenant: tenant, url: "https://127.0.0.1/") }
      previous = ENV["ENDPOINT_ENCRYPTION_KEY"]
      begin
        ENV["ENDPOINT_ENCRYPTION_KEY"] = "invalid"
        assert_raises(EndpointSecret::Unavailable) { EndpointLifecycle.register!(tenant: tenant, url: "https://8.8.8.8/") }
      ensure
        ENV["ENDPOINT_ENCRYPTION_KEY"] = previous
      end
    end
  end

  test "disable cancels only queued work and preserves running and completed history" do
    tenant = create_tenant
    endpoint = create_endpoint(tenant: tenant)
    other_endpoint = create_endpoint(tenant: tenant)
    states = %w[pending retry_wait delivering succeeded failed canceled]
    deliveries = states.to_h do |state|
      event = create_event(tenant: tenant)
      counters = state == "pending" ? 0 : 1
      scheduled = %w[pending retry_wait].include?(state)
      delivery = create_delivery(tenant: tenant, endpoint: endpoint, event: event, state: state,
        attempts_in_run: counters, total_attempts: counters, next_attempt_at: scheduled ? Time.current : nil)
      create_attempt(delivery: delivery) if counters.positive?
      [state, delivery]
    end
    unrelated = create_delivery(tenant: tenant, event: create_event(tenant: tenant), endpoint: other_endpoint)
    history = DeliveryAttempt.order(:id).map(&:attributes)
    preserved = deliveries.except("pending", "retry_wait").transform_values(&:attributes)

    EndpointLifecycle.disable!(tenant: tenant, endpoint_id: endpoint.id)

    %w[pending retry_wait].each do |state|
      delivery = deliveries.fetch(state).reload
      assert_equal "canceled", delivery.state
      assert_nil delivery.next_attempt_at
    end
    preserved.each { |state, attributes| assert_equal attributes, deliveries.fetch(state).reload.attributes }
    assert_equal history, DeliveryAttempt.order(:id).map(&:attributes)
    assert_equal "pending", unrelated.reload.state
    assert_equal "active", other_endpoint.reload.status
    first_disabled_at = endpoint.reload.disabled_at
    assert first_disabled_at
    EndpointLifecycle.disable!(tenant: tenant, endpoint_id: endpoint.id)
    assert_equal first_disabled_at, endpoint.reload.disabled_at
  end

  test "a failed cancellation rolls back the endpoint transition" do
    tenant = create_tenant
    endpoint = create_endpoint(tenant: tenant)
    delivery = create_delivery(tenant: tenant, event: create_event(tenant: tenant), endpoint: endpoint)
    connection = ApplicationRecord.connection
    connection.execute(<<~SQL)
      CREATE FUNCTION pg_temp.reject_delivery_cancellation() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN RAISE EXCEPTION 'test cancellation failure'; END;
      $$;
      CREATE TRIGGER reject_delivery_cancellation BEFORE UPDATE ON deliveries
      FOR EACH ROW WHEN (NEW.id = '#{delivery.id}'::uuid)
      EXECUTE FUNCTION pg_temp.reject_delivery_cancellation();
    SQL
    assert_raises(ActiveRecord::StatementInvalid) do
      ApplicationRecord.transaction(requires_new: true) do
        EndpointLifecycle.disable!(tenant: tenant, endpoint_id: endpoint.id)
      end
    end
    assert_equal "active", endpoint.reload.status
    assert_equal "pending", delivery.reload.state
  end

  test "active endpoint work and disable use tenant scope and a permanent active-state guard" do
    tenant = create_tenant
    other_tenant = create_tenant
    endpoint = create_endpoint(tenant: tenant)
    result = EndpointLifecycle.with_active_endpoint(tenant: tenant, endpoint_id: endpoint.id) { |locked| locked.id }
    assert_equal endpoint.id, result
    assert_raises(ActiveRecord::RecordNotFound) { EndpointLifecycle.disable!(tenant: other_tenant, endpoint_id: endpoint.id) }
    EndpointLifecycle.disable!(tenant: tenant, endpoint_id: endpoint.id)
    assert_raises(EndpointLifecycle::Disabled) do
      EndpointLifecycle.with_active_endpoint(tenant: tenant, endpoint_id: endpoint.id) { flunk "Disabled endpoint accepted work" }
    end
  end
end

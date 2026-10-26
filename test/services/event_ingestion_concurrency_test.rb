require "test_helper"
require "timeout"

class EventIngestionConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @schema = "ingestion_test_#{SecureRandom.hex(8)}"
    @threads = []
    @release = Queue.new
    connection = ApplicationRecord.connection
    # Isolated copies permit real commits without deleting immutable events or other tests' data.
    connection.execute("CREATE SCHEMA #{@schema}")
    %w[tenants events endpoints deliveries].each do |table|
      connection.execute("CREATE TABLE #{@schema}.#{table} (LIKE #{table} INCLUDING ALL)")
    end
    connection.execute("ALTER TABLE #{@schema}.events ADD FOREIGN KEY (tenant_id) REFERENCES #{@schema}.tenants(id)")
    connection.execute("ALTER TABLE #{@schema}.endpoints ADD FOREIGN KEY (tenant_id) REFERENCES #{@schema}.tenants(id)")
    connection.execute("ALTER TABLE #{@schema}.deliveries ADD FOREIGN KEY (tenant_id) REFERENCES #{@schema}.tenants(id)")
    connection.execute("ALTER TABLE #{@schema}.deliveries ADD FOREIGN KEY (tenant_id, event_id) REFERENCES #{@schema}.events(tenant_id, id)")
    connection.execute("ALTER TABLE #{@schema}.deliveries ADD FOREIGN KEY (tenant_id, endpoint_id) REFERENCES #{@schema}.endpoints(tenant_id, id)")
    connection.execute(<<~SQL)
      CREATE TRIGGER events_are_immutable BEFORE UPDATE OR DELETE ON #{@schema}.events
      FOR EACH ROW EXECUTE FUNCTION reject_event_mutation()
    SQL
    in_schema do
      tenant = create_tenant
      @tenant_id = tenant.id
      @endpoint_id = create_endpoint(tenant: tenant).id
    end
    @body = '{"type":"invoice.created","data":{}}'
  end

  teardown do
    @release << true
    @threads.each { |thread| thread.join(5) || thread.kill.join }
    ApplicationRecord.connection.execute("DROP SCHEMA IF EXISTS #{@schema} CASCADE")
  end

  test "concurrent matching requests commit one event and return the same original" do
    outcomes = compete(@body)
    outcomes.each { |outcome| raise outcome if outcome.is_a?(Exception) }
    first, second = outcomes.sort_by { |outcome| outcome.replayed ? 1 : 0 }
    refute first.replayed
    assert second.replayed
    assert_equal first.event.attributes, second.event.attributes
    in_schema do
      assert_equal [first.event.id], Event.pluck(:id)
      assert_equal 1, first.event.delivery_count
      assert_equal [[first.event.id, @endpoint_id, "pending"]], Delivery.pluck(:event_id, :endpoint_id, :state)
    end
  end

  test "concurrent conflicting requests leave one committed winner" do
    outcomes = compete('{"type":"invoice.paid","data":{}}')
    winner = outcomes.find { |outcome| outcome.is_a?(EventIngestion::Result) }
    conflict = outcomes.find { |outcome| outcome.is_a?(EventIngestion::Conflict) }
    outcomes.each { |outcome| raise outcome if outcome.is_a?(Exception) && !outcome.is_a?(EventIngestion::Conflict) }
    assert winner
    refute winner.replayed
    assert conflict
    in_schema do
      assert_equal [winner.event.id], Event.pluck(:id)
      assert_equal Digest::SHA256.hexdigest(@body), Event.first.request_fingerprint
      assert_equal [[winner.event.id, @endpoint_id]], Delivery.pluck(:event_id, :endpoint_id)
    end
  end

  test "registration committed before ingestion is included in its snapshot" do
    outcomes = ordered(
      first: ->(tenant) { EndpointLifecycle.register!(tenant: tenant, url: "https://8.8.8.8/hooks").first },
      second: ->(tenant) { ingest(tenant) })
    event = outcomes.find { |result| result.is_a?(EventIngestion::Result) }.event
    endpoint = outcomes.find { |result| result.is_a?(Endpoint) }
    in_schema do
      assert_equal 2, event.delivery_count
      assert_equal [@endpoint_id, endpoint.id].sort, event.deliveries.pluck(:endpoint_id).sort
    end
  end

  test "registration waiting behind ingestion never backfills the committed event" do
    outcomes = ordered(
      first: ->(tenant) { ingest(tenant) },
      second: ->(tenant) { EndpointLifecycle.register!(tenant: tenant, url: "https://8.8.8.8/hooks").first })
    event = outcomes.find { |result| result.is_a?(EventIngestion::Result) }.event
    in_schema do
      assert_equal 2, Endpoint.count
      assert_equal 1, event.delivery_count
      assert_equal [@endpoint_id], event.deliveries.pluck(:endpoint_id)
      assert ingest(Tenant.find(@tenant_id)).replayed
      assert_equal 1, Delivery.count
    end
  end

  test "disable committed before ingestion excludes the endpoint" do
    outcomes = ordered(
      first: ->(tenant) { EndpointLifecycle.disable!(tenant: tenant, endpoint_id: @endpoint_id) },
      second: ->(tenant) { ingest(tenant) })
    event = outcomes.find { |result| result.is_a?(EventIngestion::Result) }.event
    in_schema do
      assert_equal 0, event.delivery_count
      assert_empty Delivery.all
      assert_equal "disabled", Endpoint.find(@endpoint_id).status
    end
  end

  test "disable waiting behind ingestion cancels its pending delivery and preserves original count" do
    outcomes = ordered(
      first: ->(tenant) { ingest(tenant) },
      second: ->(tenant) { EndpointLifecycle.disable!(tenant: tenant, endpoint_id: @endpoint_id) })
    event = outcomes.find { |result| result.is_a?(EventIngestion::Result) }.event
    in_schema do
      assert_equal 1, event.delivery_count
      delivery = Delivery.sole
      assert_equal event.id, delivery.event_id
      assert_equal "canceled", delivery.state
      assert_nil delivery.next_attempt_at
      assert_equal 1, ingest(Tenant.find(@tenant_id)).event.delivery_count
    end
  end

  test "work survives lost response and a fresh database connection recovers the committed event" do
    original = in_schema { ingest(Tenant.find(@tenant_id)).event.attributes }
    results = Queue.new
    @threads << Thread.new do
      in_schema do
        retry_result = ingest(Tenant.find(@tenant_id))
        results << [retry_result, Delivery.pluck(:event_id, :endpoint_id, :state)]
      end
    rescue => error
      results << error
    end
    outcome = Timeout.timeout(5) { results.pop }
    raise outcome if outcome.is_a?(Exception)
    retry_result, deliveries = outcome
    assert retry_result.replayed
    assert_equal original, retry_result.event.attributes
    assert_equal [[original.fetch("id"), @endpoint_id, "pending"]], deliveries
  end

  private

  def in_schema
    ApplicationRecord.connection_pool.with_connection do |connection|
      previous = connection.schema_search_path
      begin
        connection.schema_search_path = "#{@schema}, #{previous}"
        yield connection
      ensure
        connection.schema_search_path = previous
      end
    end
  end

  def compete(second_body)
    ordered(first: ->(tenant) { ingest(tenant) }, second: ->(tenant) { ingest(tenant, body: second_body) })
  end

  def ingest(tenant, body: @body)
    EventIngestion.call(tenant: tenant, idempotency_key: "same_key", raw_body: body)
  end

  def ordered(first:, second:)
    entered = Queue.new
    started = Queue.new
    results = Queue.new
    @threads << Thread.new do
      in_schema do
        tenant = Tenant.find(@tenant_id)
        result = tenant.with_lock do
          operation = first.call(tenant)
          entered << true
          Timeout.timeout(5) { @release.pop }
          operation
        end
        results << result
      end
    rescue => error
      results << error
    end
    Timeout.timeout(5) { entered.pop }
    @threads << Thread.new do
      in_schema do |connection|
        started << connection.select_value("SELECT pg_backend_pid()")
        results << second.call(Tenant.find(@tenant_id))
      end
    rescue => error
      results << error
    end
    pid = Timeout.timeout(5) { started.pop }
    Timeout.timeout(5) do
      loop do
        waiting = ApplicationRecord.uncached do
          ApplicationRecord.connection.select_value("SELECT wait_event_type FROM pg_stat_activity WHERE pid = #{Integer(pid)}")
        end
        break if waiting == "Lock"
        sleep 0.01
      end
    end
    @release << true
    outcomes = Timeout.timeout(5) { 2.times.map { results.pop } }
    outcomes.each do |outcome|
      raise outcome if outcome.is_a?(Exception) && !outcome.is_a?(EventIngestion::Conflict)
    end
    outcomes
  end
end

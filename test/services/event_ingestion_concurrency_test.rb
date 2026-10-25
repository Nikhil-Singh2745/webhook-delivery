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
    %w[tenants events].each do |table|
      connection.execute("CREATE TABLE #{@schema}.#{table} (LIKE #{table} INCLUDING ALL)")
    end
    connection.execute("ALTER TABLE #{@schema}.events ADD FOREIGN KEY (tenant_id) REFERENCES #{@schema}.tenants(id)")
    connection.execute(<<~SQL)
      CREATE TRIGGER events_are_immutable BEFORE UPDATE OR DELETE ON #{@schema}.events
      FOR EACH ROW EXECUTE FUNCTION reject_event_mutation()
    SQL
    in_schema { @tenant_id = create_tenant.id }
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
    in_schema { assert_equal [first.event.id], Event.pluck(:id) }
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
    end
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
    entered = Queue.new
    started = Queue.new
    results = Queue.new
    @threads << Thread.new do
      in_schema do
        tenant = Tenant.find(@tenant_id)
        result = tenant.with_lock do
          ingestion = EventIngestion.call(tenant: tenant, idempotency_key: "same_key", raw_body: @body)
          entered << true
          Timeout.timeout(5) { @release.pop }
          ingestion
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
        results << EventIngestion.call(tenant: Tenant.find(@tenant_id), idempotency_key: "same_key", raw_body: second_body)
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
    Timeout.timeout(5) { 2.times.map { results.pop } }
  end
end

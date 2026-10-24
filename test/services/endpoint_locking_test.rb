require "test_helper"
require "timeout"

class EndpointLockingTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @tenant = create_tenant
    @endpoint = create_endpoint(tenant: @tenant)
    @threads = []
    @release = Queue.new
  end

  teardown do
    @release << true
    @threads.each { |thread| thread.join(5) || thread.kill.join }
    @endpoint.delete
    @tenant.delete
  end

  test "disable waits for an earlier active endpoint transaction to commit" do
    entered = Queue.new
    started = Queue.new
    results = Queue.new
    @threads << Thread.new do
      ApplicationRecord.connection_pool.with_connection do
        EndpointLifecycle.with_active_endpoint(tenant: Tenant.find(@tenant.id), endpoint_id: @endpoint.id) do
          entered << true
          Timeout.timeout(5) { @release.pop }
        end
        results << :active_work_committed
      end
    rescue => error
      results << error
    end
    Timeout.timeout(5) { entered.pop }
    @threads << Thread.new do
      ApplicationRecord.connection_pool.with_connection do |connection|
        started << connection.select_value("SELECT pg_backend_pid()")
        EndpointLifecycle.disable!(tenant: Tenant.find(@tenant.id), endpoint_id: @endpoint.id)
        results << :disabled
      end
    rescue => error
      results << error
    end
    pid = Timeout.timeout(5) { started.pop }
    wait_for_lock(pid)
    assert_equal "active", @endpoint.reload.status
    @release << true
    outcomes = Timeout.timeout(5) { 2.times.map { results.pop } }
    outcomes.each { |outcome| raise outcome if outcome.is_a?(Exception) }
    assert_equal [:active_work_committed, :disabled].sort, outcomes.sort
    assert_equal "disabled", @endpoint.reload.status
  end

  test "active endpoint work waiting behind disable observes disabled state after commit" do
    entered = Queue.new
    started = Queue.new
    results = Queue.new
    @threads << Thread.new do
      ApplicationRecord.connection_pool.with_connection do
        tenant = Tenant.find(@tenant.id)
        tenant.with_lock do
          EndpointLifecycle.disable!(tenant: tenant, endpoint_id: @endpoint.id)
          entered << true
          Timeout.timeout(5) { @release.pop }
        end
        results << :disabled
      end
    rescue => error
      results << error
    end
    Timeout.timeout(5) { entered.pop }
    @threads << Thread.new do
      ApplicationRecord.connection_pool.with_connection do |connection|
        started << connection.select_value("SELECT pg_backend_pid()")
        EndpointLifecycle.with_active_endpoint(tenant: Tenant.find(@tenant.id), endpoint_id: @endpoint.id) { results << :unexpected_work }
      end
    rescue EndpointLifecycle::Disabled
      results << :work_rejected
    rescue => error
      results << error
    end
    pid = Timeout.timeout(5) { started.pop }
    wait_for_lock(pid)
    @release << true
    outcomes = Timeout.timeout(5) { 2.times.map { results.pop } }
    outcomes.each { |outcome| raise outcome if outcome.is_a?(Exception) }
    assert_equal [:disabled, :work_rejected].sort, outcomes.sort
    assert_equal "disabled", @endpoint.reload.status
  end

  private

  def wait_for_lock(pid)
    Timeout.timeout(5) do
      loop do
        waiting = ApplicationRecord.uncached do
          ApplicationRecord.connection.select_value("SELECT wait_event_type FROM pg_stat_activity WHERE pid = #{Integer(pid)}")
        end
        break if waiting == "Lock"
        sleep 0.01
      end
    end
  end
end

require "test_helper"

class EventIngestionTest < ActiveSupport::TestCase
  setup do
    @tenant = create_tenant
    @body = '{"type":"invoice.created","data":{"invoice_id":"demo_invoice_1"}}'
  end

  test "new ingestion stores immutable identity fingerprint and stable outbound bytes" do
    result = nil
    assert_difference "Event.count", 1 do
      result = ingest
    end
    refute result.replayed
    event = result.event.reload
    assert_equal @tenant.id, event.tenant_id
    assert_equal "invoice_1", event.idempotency_key
    assert_equal Digest::SHA256.hexdigest(@body), event.request_fingerprint
    assert_equal "invoice.created", event.event_type
    assert_equal({"invoice_id" => "demo_invoice_1"}, event.data)
    assert_equal 0, event.delivery_count
    assert_equal({"id" => event.id, "type" => event.event_type, "created_at" => event.created_at.utc.iso8601(6),
      "data" => event.data}, JSON.parse(event.outbound_body))
    assert event.readonly?
  end

  test "matching retries recover the original event and never reserve a second identity" do
    original = ingest.event
    assert_no_difference ["Event.count", "Delivery.count"] do
      2.times do
        duplicate = ingest
        assert duplicate.replayed
        assert_equal original.attributes, duplicate.event.attributes
      end
    end
  end

  test "different valid bytes conflict including whitespace and reordered fields" do
    original = ingest.event
    [' ' + @body, '{"data":{"invoice_id":"demo_invoice_1"},"type":"invoice.created"}',
      '{"type":"invoice.paid","data":{}}'].each do |body|
      assert_no_difference "Event.count" do
        error = assert_raises(EventIngestion::Conflict) { ingest(body: body) }
        refute_includes error.message, body
      end
    end
    assert_equal original.attributes, ingest.event.attributes
  end

  test "keys are independent across tenants and case sensitive within a tenant" do
    other = create_tenant
    original = ingest.event
    same_key = EventIngestion.call(tenant: other, idempotency_key: "invoice_1", raw_body: @body)
    different_case = ingest(key: "INVOICE_1")
    refute same_key.replayed
    refute different_case.replayed
    assert_equal 3, [original.id, same_key.event.id, different_case.event.id].uniq.size
    assert_equal other.id, same_key.event.tenant_id
  end

  test "invalid requests neither reserve keys nor become conflicts on an existing key" do
    ["", '{"type":"invalid-type","data":{}}', '{"type":"test","data":[]}'].each do |body|
      assert_no_difference "Event.count" do
        assert_raises(EventSubmission::Invalid) { ingest(body: body) }
      end
    end
    original = ingest.event
    assert_raises(EventSubmission::Invalid) { ingest(body: '{"type":"test","data":[]}') }
    assert_equal original.id, ingest.event.id
  end

  test "a rolled back transaction does not reserve the idempotency key" do
    rolled_back_id = nil
    assert_no_difference "Event.count" do
      ApplicationRecord.transaction(requires_new: true) do
        rolled_back_id = ingest.event.id
        raise ActiveRecord::Rollback
      end
    end
    result = ingest
    refute result.replayed
    refute_equal rolled_back_id, result.event.id
    assert result.event.persisted?
  end

  private

  def ingest(body: @body, key: "invoice_1")
    EventIngestion.call(tenant: @tenant, idempotency_key: key, raw_body: body)
  end
end

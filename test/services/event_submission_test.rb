require_relative "../../config/environment"
require "minitest/autorun"

class EventSubmissionTest < Minitest::Test
  def submission(body, key: "invoice:demo_1")
    EventSubmission.new(idempotency_key: key, raw_body: body)
  end

  def assert_invalid(status, code, &block)
    error = assert_raises(EventSubmission::Invalid, &block)
    assert_equal status, error.status
    assert_equal code, error.code
    error
  end

  def test_keys_are_required_case_sensitive_ascii_and_bounded
    [nil, "", [], "a" * 129, "contains space", "key\n", "é", "a,b", "a/b", "\xff".b].each do |key|
      assert_invalid(400, "invalid_request") { submission('{"type":"test","data":{}}', key: key) }
    end
    ["a", "a" * 128, "Key._:-123"].each do |key|
      assert_equal key, submission('{"type":"test","data":{}}', key: key).idempotency_key
    end
  end

  def test_fingerprint_preserves_every_request_byte
    bodies = ['{"type":"test","data":{}}', '{ "type":"test","data":{}}', '{"data":{},"type":"test"}']
    fingerprints = bodies.map do |body|
      fingerprint = submission(body).request_fingerprint
      assert_equal Digest::SHA256.hexdigest(body), fingerprint
      fingerprint
    end
    assert_equal 3, fingerprints.uniq.size
  end

  def test_stable_envelope_contains_only_server_identity_type_time_and_data
    body = '{"type":"invoice.created","data":{"label":"café","items":[1,true,null,{"x":"y"}]}}'
    attributes = submission(body).event_attributes
    envelope = JSON.parse(attributes.fetch(:outbound_body))
    assert_equal %w[created_at data id type], envelope.keys.sort
    assert_match(/\A[0-9a-f-]{36}\z/, envelope.fetch("id"))
    assert_equal attributes.fetch(:id), envelope.fetch("id")
    assert_equal attributes.fetch(:created_at).iso8601(6), envelope.fetch("created_at")
    assert_equal "invoice.created", envelope.fetch("type")
    assert_equal JSON.parse(body).fetch("data"), envelope.fetch("data")
    assert_operator attributes.fetch(:outbound_body).bytesize, :<=, EventSubmission::OUTBOUND_LIMIT
  end

  def test_exact_fields_and_event_type_format_are_enforced
    ["", "{}", '{"type":"test"}', '{"type":"test","data":{},"tenant_id":"injected"}',
      '{"type":"test","data":{},"id":"injected"}', '{"type":"test","data":{},"created_at":"injected"}'].each do |body|
      assert_invalid(422, "validation_failed") { submission(body) }
    end
    [nil, 1, [], "", "Test", "test.", ".test", "test..created", "test-created", "test\n", "é", "a" * 101].each do |type|
      error = assert_invalid(422, "validation_failed") { submission(JSON.generate(type: type, data: {})) }
      assert_equal [:type], error.details.keys
    end
    ["a", "a" * 100, "invoice_1.item2_created"].each do |type|
      assert_equal type, submission(JSON.generate(type: type, data: {})).event_attributes.fetch(:event_type)
    end
  end

  def test_data_must_be_an_object_and_representable_as_jsonb
    [nil, [], "text", 1, true, {"nested" => ["nul\0value"]}, {"nul\0key" => true}].each do |data|
      assert_invalid(422, "validation_failed") { submission(JSON.generate(type: "test", data: data)) }
    end
    assert_invalid(422, "validation_failed") { submission('{"type":"test","data":{"amount":1e400}}') }
  end

  def test_shared_parser_rejects_malformed_duplicate_deep_and_oversized_bodies
    ['{"type":"test",', '{"type":"a","type":"b","data":{}}',
      '{"type":"test","data":{"nested":{"x":1,"x":2}}}', "{\"type\":\"\xff\",\"data\":{}}".b].each do |body|
      assert_invalid(400, "invalid_json") { submission(body) }
    end
    ["null", "[]", "1"].each do |body|
      assert_invalid(400, "invalid_request") { submission(body) }
    end
    assert_invalid(422, "validation_failed") { submission('{"type":"test","data":' + "[" * 20 + "0" + "]" * 20 + "}") }
    assert_invalid(413, "payload_too_large") { submission(" " * 65_537) }
    body = JSON.generate(type: "test", data: {text: "x" * 65_502})
    assert_equal 65_536, body.bytesize
    assert submission(body).event_attributes
  end
end

require "test_helper"
require "minitest/mock"

class EventsTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = create_tenant
    _, @token = ApiCredential.issue!(tenant: @tenant)
    @headers = {"Authorization" => "Bearer #{@token}", "CONTENT_TYPE" => "application/json", "Idempotency-Key" => "invoice_1"}
    @body = '{"type":"invoice.created","data":{"invoice_id":"demo_invoice_1"}}'
  end

  test "acceptance returns the committed event and work and retries return the same representation" do
    endpoint = create_endpoint(tenant: @tenant)
    post_event
    assert_response :created
    original = response.parsed_body.fetch("data")
    assert_equal %w[created_at data delivery_count id type], original.keys.sort
    assert_equal "invoice.created", original.fetch("type")
    assert_equal({"invoice_id" => "demo_invoice_1"}, original.fetch("data"))
    assert_equal 1, original.fetch("delivery_count")
    assert_nil response.headers["Idempotency-Replayed"]
    assert_equal "no-store", response.headers["Cache-Control"]
    event = @tenant.events.find(original.fetch("id"))
    assert_equal endpoint.id, event.deliveries.sole.endpoint_id
    assert_equal event.created_at.utc.iso8601(6), original.fetch("created_at")
    assert_no_difference ["Event.count", "Delivery.count"] do
      post_event
      assert_response :ok
      assert_equal "true", response.headers["Idempotency-Replayed"]
      assert_equal original, response.parsed_body.fetch("data")
    end
    post_event(body: " " + @body)
    assert_response :conflict
    assert_error "idempotency_conflict"
    assert_nil response.headers["Idempotency-Replayed"]
  end

  test "authentication precedes event validation and unauthorized requests create nothing" do
    assert_no_difference ["Event.count", "Delivery.count"] do
      [nil, "Bearer invalid"].each do |authorization|
        post_event(body: "{}", headers: @headers.merge("Authorization" => authorization, "Idempotency-Key" => nil))
        assert_response :unauthorized
        assert_error "unauthorized"
        assert_equal "Bearer", response.headers["WWW-Authenticate"]
      end
    end
  end

  test "identical keys are scoped to the credential tenant and fanout never crosses tenants" do
    other = create_tenant
    _, token = ApiCredential.issue!(tenant: other)
    endpoint = create_endpoint(tenant: other)
    post_event
    assert_response :created
    first_id = response.parsed_body.fetch("data").fetch("id")
    assert_equal 0, response.parsed_body.fetch("data").fetch("delivery_count")
    post_event(headers: @headers.merge("Authorization" => "Bearer #{token}"))
    assert_response :created
    second_id = response.parsed_body.fetch("data").fetch("id")
    refute_equal first_id, second_id
    assert_equal [endpoint.id], other.events.find(second_id).deliveries.pluck(:endpoint_id)
    assert_empty @tenant.events.find(first_id).deliveries
  end

  test "invalid keys fields query parameters and transport never reserve an event" do
    assert_no_difference ["Event.count", "Delivery.count"] do
      [nil, "", "has spaces", "x" * 129].each do |key|
        post_event(headers: @headers.merge("Idempotency-Key" => key))
        assert_response :bad_request
        assert_error "invalid_request"
      end
      ["", "{}", '{"type":"bad-type","data":{}}', '{"type":"test","data":[]}',
        '{"type":"test","data":{},"tenant_id":"injected"}', '{"type":"test","data":{"nul":"\\u0000"}}'].each do |body|
        post_event(body: body)
        assert_response :unprocessable_entity
        assert_error "validation_failed"
      end
      post "/v1/events?endpoint_id=injected", params: @body, headers: @headers
      assert_response :bad_request
      assert_error "invalid_request"
      post_event(body: '{"type":"test","type":"other","data":{}}')
      assert_response :bad_request
      assert_error "invalid_json"
      post_event(headers: @headers.merge("CONTENT_TYPE" => "text/plain"))
      assert_response :unsupported_media_type
      post_event(body: " " * 65_537)
      assert_response :content_too_large
    end
    post_event
    assert_response :created
  end

  test "unsupported collection methods return Allow and safe errors" do
    get "/v1/events", headers: @headers
    assert_response :method_not_allowed
    assert_equal "POST", response.headers["Allow"]
    assert_error "method_not_allowed"
  end

  test "database failures return safe errors and the original key remains usable" do
    [ [ActiveRecord::StatementInvalid, :internal_server_error, "internal_error"],
      [ActiveRecord::Deadlocked, :service_unavailable, "temporarily_unavailable"],
      [ActiveRecord::ConnectionNotEstablished, :service_unavailable, "temporarily_unavailable"] ].each do |exception, status, code|
      failure = ->(**) { raise exception, "private database failure #{@body}" }
      assert_no_difference ["Event.count", "Delivery.count"] do
        EventIngestion.stub(:call, failure) { post_event }
        assert_response status
        assert_error code
        refute_includes response.body, "private database failure"
        refute_includes response.body, "invoice_id"
        assert_nil response.headers["Idempotency-Replayed"]
      end
    end
    post_event
    assert_response :created
  end

  test "request and SQL logs redact payloads and outbound envelopes" do
    logs = StringIO.new
    previous_logger = Rails.logger
    previous_sql_logger = ActiveRecord::Base.logger
    Rails.logger = ActiveSupport::Logger.new(logs)
    ActiveRecord::Base.logger = ActiveSupport::Logger.new(logs)
    marker = "private_payload_#{SecureRandom.hex(12)}"
    post_event(body: JSON.generate(type: "test", data: {value: marker}))
    assert_response :created
    assert logs.string.present?
    refute_includes logs.string, marker
    refute_includes logs.string, @token
  ensure
    Rails.logger = previous_logger
    ActiveRecord::Base.logger = previous_sql_logger
  end

  private

  def post_event(body: @body, headers: @headers)
    post "/v1/events", params: body, headers: headers
  end

  def assert_error(code)
    assert_equal code, response.parsed_body.fetch("error").fetch("code")
    assert_equal response.headers["X-Request-Id"], response.parsed_body.fetch("request_id")
    assert_equal "no-store", response.headers["Cache-Control"]
  end
end

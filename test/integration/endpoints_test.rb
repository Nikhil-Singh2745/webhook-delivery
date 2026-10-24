require "test_helper"

class EndpointsTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = create_tenant
    @other_tenant = create_tenant
    _, @token = ApiCredential.issue!(tenant: @tenant)
    _, @other_token = ApiCredential.issue!(tenant: @other_tenant)
    @headers = {"Authorization" => "Bearer #{@token}"}
  end

  test "creation returns an independent secret once and inspection excludes secrets" do
    assert_difference "@tenant.endpoints.count", 1 do
      post "/v1/endpoints", params: {url: "https://8.8.8.8/hooks/a%2Fb/"}, headers: @headers, as: :json
      assert_response :created
    end
    data = response.parsed_body.fetch("data")
    assert_equal %w[created_at disabled_at id signing_secret status url], data.keys.sort
    assert_equal "https://8.8.8.8/hooks/a%2Fb/", data.fetch("url")
    assert_equal "active", data.fetch("status")
    assert_nil data.fetch("disabled_at")
    secret = data.fetch("signing_secret")
    endpoint = @tenant.endpoints.find(data.fetch("id"))
    assert_equal secret, endpoint.signing_secret
    refute_includes endpoint.signing_secret_ciphertext, secret
    assert_equal "no-store", response.headers["Cache-Control"]

    get "/v1/endpoints/#{endpoint.id}", headers: @headers
    assert_response :ok
    assert_equal data.except("signing_secret"), response.parsed_body.fetch("data")
    refute_includes response.body, secret
    get "/v1/endpoints", headers: @headers
    assert_response :ok
    assert_equal [data.except("signing_secret")], response.parsed_body.fetch("data")
    assert_nil response.parsed_body.fetch("next_cursor")
    refute_includes response.body, secret
  end

  test "authentication prevents endpoint creation and secret disclosure" do
    assert_no_difference "Endpoint.count" do
      post "/v1/endpoints", params: {url: "https://8.8.8.8/"}, as: :json
      assert_response :unauthorized
      assert_equal "Bearer", response.headers["WWW-Authenticate"]
      refute_includes response.body, "whsec_"
    end
  end

  test "generated signing secrets are absent from request and SQL logs" do
    logs = StringIO.new
    previous_logger = Rails.logger
    previous_sql_logger = ActiveRecord::Base.logger
    Rails.logger = ActiveSupport::Logger.new(logs)
    ActiveRecord::Base.logger = ActiveSupport::Logger.new(logs)
    post "/v1/endpoints", params: {url: "https://8.8.8.8/hooks"}, headers: @headers, as: :json
    assert_response :created
    secret = response.parsed_body.fetch("data").fetch("signing_secret")
    refute_includes logs.string, secret
    refute_includes logs.string, @token
  ensure
    Rails.logger = previous_logger
    ActiveRecord::Base.logger = previous_sql_logger
  end

  test "invalid destinations and ownership or secret injection are rejected" do
    bodies = [{}, {url: nil}, {url: []}, {url: "http://8.8.8.8/"}, {url: "https://127.0.0.1/"},
      {url: "https://8.8.8.8/?token=secret"}, {url: "https://8.8.8.8/", tenant_id: @other_tenant.id},
      {url: "https://8.8.8.8/", signing_secret: "injected"}, {url: "https://8.8.8.8/", status: "disabled"}]
    assert_no_difference "Endpoint.count" do
      bodies.each do |body|
        post "/v1/endpoints", params: body, headers: @headers, as: :json
        assert_response :unprocessable_entity
        assert_equal "validation_failed", response.parsed_body.fetch("error").fetch("code")
        refute_includes response.body, "secret"
      end
    end
  end

  test "unavailable encryption returns a safe error and persists nothing" do
    previous = ENV["ENDPOINT_ENCRYPTION_KEY"]
    ENV["ENDPOINT_ENCRYPTION_KEY"] = "invalid"
    assert_no_difference "Endpoint.count" do
      post "/v1/endpoints", params: {url: "https://8.8.8.8/"}, headers: @headers, as: :json
      assert_response :service_unavailable
      assert_equal "temporarily_unavailable", response.parsed_body.fetch("error").fetch("code")
      refute_includes response.body, "ENDPOINT_ENCRYPTION_KEY"
    end
  ensure
    ENV["ENDPOINT_ENCRYPTION_KEY"] = previous
  end

  test "cross-tenant and unknown endpoints cannot be read or disabled" do
    endpoint = create_endpoint(tenant: @other_tenant)
    [endpoint.id, SecureRandom.uuid, "invalid"].each do |id|
      get "/v1/endpoints/#{id}", headers: @headers
      assert_response :not_found
      post "/v1/endpoints/#{id}/disable", params: {}, headers: @headers, as: :json
      assert_response :not_found
      assert_equal "not_found", response.parsed_body.fetch("error").fetch("code")
    end
    assert_equal "active", endpoint.reload.status
  end

  test "disable is permanent repeatable and cancels queued work without exposing a secret" do
    endpoint, secret = EndpointLifecycle.register!(tenant: @tenant, url: "https://8.8.8.8/")
    delivery = create_delivery(tenant: @tenant, event: create_event(tenant: @tenant), endpoint: endpoint)
    post "/v1/endpoints/#{endpoint.id}/disable", params: {}, headers: @headers, as: :json
    assert_response :ok
    first = response.parsed_body.fetch("data")
    assert_equal "disabled", first.fetch("status")
    assert first.fetch("disabled_at")
    assert_equal "canceled", delivery.reload.state
    refute_includes response.body, secret
    post "/v1/endpoints/#{endpoint.id}/disable", params: {}, headers: @headers, as: :json
    assert_response :ok
    assert_equal first, response.parsed_body.fetch("data")
  end

  test "pagination isolates tenants and uses stable newest-first ordering including disabled endpoints" do
    created_at = Time.current.change(usec: 0)
    endpoints = 3.times.map { create_endpoint(tenant: @tenant, created_at: created_at) }.sort_by(&:id).reverse
    create_endpoint(tenant: @other_tenant, created_at: created_at + 1.second)
    EndpointLifecycle.disable!(tenant: @tenant, endpoint_id: endpoints.first.id)
    get "/v1/endpoints", params: {limit: "2"}, headers: @headers
    assert_response :ok
    assert_equal endpoints.first(2).map(&:id), response.parsed_body.fetch("data").map { |item| item.fetch("id") }
    assert_equal "disabled", response.parsed_body.fetch("data").first.fetch("status")
    cursor = response.parsed_body.fetch("next_cursor")
    assert cursor
    get "/v1/endpoints", params: {limit: "2", cursor: cursor}, headers: @headers
    assert_response :ok
    assert_equal [endpoints.last.id], response.parsed_body.fetch("data").map { |item| item.fetch("id") }
    assert_nil response.parsed_body.fetch("next_cursor")

    [cursor.reverse, "invalid", "", cursor].each_with_index do |invalid, index|
      headers = index == 3 ? {"Authorization" => "Bearer #{@other_token}"} : @headers
      get "/v1/endpoints", params: {cursor: invalid}, headers: headers
      assert_response :bad_request
      assert_equal "invalid_cursor", response.parsed_body.fetch("error").fetch("code")
    end
  end

  test "unsupported query parameters limits bodies and methods are rejected" do
    [{limit: "0"}, {limit: "101"}, {limit: "-1"}, {limit: "1.0"}, {limit: ["1"]}, {unexpected: "value"}].each do |query|
      get "/v1/endpoints", params: query, headers: @headers
      assert_response :bad_request
    end
    post "/v1/endpoints?unexpected=value", params: {url: "https://8.8.8.8/"}, headers: @headers, as: :json
    assert_response :bad_request
    endpoint = create_endpoint(tenant: @tenant)
    post "/v1/endpoints/#{endpoint.id}/disable", params: {status: "active"}, headers: @headers, as: :json
    assert_response :unprocessable_entity
    assert_equal "active", endpoint.reload.status
    patch "/v1/endpoints/#{endpoint.id}", params: {}, headers: @headers, as: :json
    assert_response :method_not_allowed
    assert_equal "GET, HEAD", response.headers["Allow"]
    assert_equal "method_not_allowed", response.parsed_body.fetch("error").fetch("code")
  end

  test "transport errors have safe JSON envelopes and correlation identifiers" do
    [ ['{"url":"first","url":"second"}', "application/json", :bad_request, "invalid_json"],
      ["{}", "text/plain", :unsupported_media_type, "unsupported_media_type"],
      [" " * 65_537, "application/json", :content_too_large, "payload_too_large"] ].each do |body, type, status, code|
      post "/v1/endpoints", params: body, headers: @headers.merge("CONTENT_TYPE" => type)
      assert_response status
      assert_equal code, response.parsed_body.fetch("error").fetch("code")
      assert_equal response.headers["X-Request-Id"], response.parsed_body.fetch("request_id")
      assert_equal "no-store", response.headers["Cache-Control"]
    end
  end
end

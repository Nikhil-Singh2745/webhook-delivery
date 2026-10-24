require "test_helper"
require_relative "../support/tenant_isolation_probe_controller"

class TenantIsolationTest < ActionDispatch::IntegrationTest
  with_routing do |routes|
    routes.draw do
      get "/v1/probe/endpoints", to: "tenant_isolation_probe#endpoints"
      post "/v1/probe/endpoints", to: "tenant_isolation_probe#create_endpoint"
      get "/v1/probe/endpoints/:id", to: "tenant_isolation_probe#endpoint"
      patch "/v1/probe/endpoints/:id", to: "tenant_isolation_probe#write_endpoint"
      get "/v1/probe/events/:id", to: "tenant_isolation_probe#event"
      get "/v1/probe/deliveries/:id", to: "tenant_isolation_probe#delivery"
      get "/v1/probe/events/:event_id/deliveries/:id", to: "tenant_isolation_probe#event_delivery"
      get "/v1/probe/deliveries/:delivery_id/attempts/:id", to: "tenant_isolation_probe#attempt"
    end
  end

  setup do
    @tenant = create_tenant
    @other_tenant = create_tenant
    @credential, @token = ApiCredential.issue!(tenant: @tenant)
    @other_credential, @other_token = ApiCredential.issue!(tenant: @other_tenant)
    @headers = {"Authorization" => "Bearer #{@token}", "Accept" => "application/json"}
    @endpoint = create_endpoint(tenant: @tenant)
    @event = create_event(tenant: @tenant)
    @delivery = create_delivery(tenant: @tenant, event: @event, endpoint: @endpoint)
    @attempt = create_attempt(delivery: @delivery)
    @other_endpoint = create_endpoint(tenant: @other_tenant)
    @other_event = create_event(tenant: @other_tenant)
    @other_delivery = create_delivery(tenant: @other_tenant, event: @other_event, endpoint: @other_endpoint)
    @other_attempt = create_attempt(delivery: @other_delivery)
  end

  test "missing malformed unknown and revoked credentials share the same unauthorized response" do
    @credential.revoke!
    headers = [nil, "", "Basic #{@other_token}", "Token #{@other_token}", "Bearer wrong",
      "Bearer whapi_#{'a' * 43}", "Bearer #{@other_token} extra", "Bearer #{@token}"]

    headers.each do |authorization|
      get "/v1/probe/endpoints", headers: {"Authorization" => authorization}

      assert_response :unauthorized
      assert_equal "Bearer", response.headers["WWW-Authenticate"]
      assert_equal "no-store", response.headers["Cache-Control"]
      assert_equal({"code" => "unauthorized", "message" => "Authentication required.", "details" => {}}, response.parsed_body.fetch("error"))
      assert_equal response.headers["X-Request-Id"], response.parsed_body.fetch("request_id")
      assert_not_empty response.parsed_body.fetch("request_id")
      assert_equal "application/json", response.media_type
    end
  end

  test "authentication precedes target lookup and prevents writes" do
    [@endpoint.id, SecureRandom.uuid].each do |id|
      patch "/v1/probe/endpoints/#{id}"
      assert_response :unauthorized
    end
    assert_equal "active", @endpoint.reload.status
    assert_no_difference "Endpoint.count" do
      post "/v1/probe/endpoints"
      assert_response :unauthorized
    end
  end

  test "a credential lists only its tenant records and request identity never persists between requests" do
    get "/v1/probe/endpoints", headers: @headers
    assert_response :ok
    assert_equal [@endpoint.id], response.parsed_body.fetch("data")
    assert_equal "no-store", response.headers["Cache-Control"]

    get "/v1/probe/endpoints", headers: {"Authorization" => "bearer #{@other_token}"}
    assert_response :ok
    assert_equal [@other_endpoint.id], response.parsed_body.fetch("data")

    get "/v1/probe/endpoints"
    assert_response :unauthorized
  end

  test "scoped lookups resolve owned endpoints events deliveries and nested resources" do
    ["endpoints/#{@endpoint.id}", "events/#{@event.id}", "deliveries/#{@delivery.id}",
      "events/#{@event.id}/deliveries/#{@delivery.id}",
      "deliveries/#{@delivery.id}/attempts/#{@attempt.id}"].each do |target|
      get "/v1/probe/#{target}", headers: @headers
      assert_response :ok
    end
  end

  test "unknown and cross-tenant targets return identical safe not-found errors" do
    ["endpoints/#{@other_endpoint.id}", "endpoints/#{SecureRandom.uuid}", "endpoints/not-a-uuid",
      "events/#{@other_event.id}", "events/#{SecureRandom.uuid}",
      "deliveries/#{@other_delivery.id}", "deliveries/#{SecureRandom.uuid}",
      "events/#{@other_event.id}/deliveries/#{@other_delivery.id}",
      "events/#{@event.id}/deliveries/#{@other_delivery.id}",
      "deliveries/#{@other_delivery.id}/attempts/#{@other_attempt.id}",
      "deliveries/#{@delivery.id}/attempts/#{@other_attempt.id}"].each do |target|
      get "/v1/probe/#{target}", headers: @headers

      assert_response :not_found
      assert_equal({"code" => "not_found", "message" => "Resource not found.", "details" => {}}, response.parsed_body.fetch("error"))
      assert_equal response.headers["X-Request-Id"], response.parsed_body.fetch("request_id")
    end
  end

  test "nested lookup rejects an unrelated resource within the same tenant" do
    unrelated_event = create_event(tenant: @tenant)
    unrelated_delivery = create_delivery(tenant: @tenant, event: unrelated_event, endpoint: @endpoint)
    unrelated_attempt = create_attempt(delivery: unrelated_delivery)

    get "/v1/probe/events/#{@event.id}/deliveries/#{unrelated_delivery.id}", headers: @headers
    assert_response :not_found
    get "/v1/probe/deliveries/#{@delivery.id}/attempts/#{unrelated_attempt.id}", headers: @headers
    assert_response :not_found
  end

  test "scoped writes cannot change another tenant records" do
    [@other_endpoint.id, SecureRandom.uuid].each do |id|
      patch "/v1/probe/endpoints/#{id}", headers: @headers
      assert_response :not_found
    end
    assert_equal "active", @other_endpoint.reload.status
    assert_nil @other_endpoint.disabled_at

    patch "/v1/probe/endpoints/#{@endpoint.id}", headers: @headers
    assert_response :ok
    assert_equal "disabled", @endpoint.reload.status
  end

  test "creating through the tenant association ignores client-supplied ownership" do
    assert_difference "@tenant.endpoints.count", 1 do
      assert_no_difference "@other_tenant.endpoints.count" do
        post "/v1/probe/endpoints", headers: @headers, params: {tenant_id: @other_tenant.id}, as: :json
        assert_response :created
      end
    end
  end

  test "revocation takes effect on the next request" do
    get "/v1/probe/endpoints", headers: @headers
    assert_response :ok
    @credential.revoke!
    get "/v1/probe/endpoints", headers: @headers
    assert_response :unauthorized
  end
end

require_relative "../../config/environment"
require "minitest/autorun"
require "rack/mock"

class ApiRequestBodyTest < Minitest::Test
  def call_body(body, **options)
    @received = nil
    app = ApiRequestBody.new(->(env) { @received = env; [200, {}, ["ok"]] })
    env = Rack::MockRequest.env_for("/v1/endpoints", method: "POST", input: body.dup,
      "CONTENT_TYPE" => "application/json", "action_dispatch.request_id" => "test-request")
    env.merge!(options.transform_keys(&:to_s))
    app.call(env)
  end

  def test_limit_is_enforced_without_content_length_and_preserves_accepted_bytes
    body = '{"url":"' + "a" * (65_536 - 10) + '"}'
    assert_equal 65_536, body.bytesize
    assert_equal 200, call_body(body, CONTENT_LENGTH: nil).first
    assert_equal body, @received.fetch("rack.input").read
    assert_equal 413, call_body(body + " ", CONTENT_LENGTH: "0").first
    assert_nil @received
    assert_equal 413, call_body('"' + "é" * 32_768 + '"').first
  end

  def test_rejects_malformed_duplicate_and_nonobject_json_without_exposing_the_body
    ['{"url":', '{"url":"secret","url":"other"}', '{"data":{"x":1,"x":2}}', "null", "[]", "1", "{\"a\":\"\xff\"}".b].each do |body|
      status, headers, response = call_body(body)
      assert_equal 400, status, body.inspect
      assert_nil @received
      assert_equal "no-store", headers["cache-control"]
      parsed = JSON.parse(response.join)
      assert_equal "test-request", parsed.fetch("request_id")
      refute_includes response.join, "secret"
    end
  end

  def test_nesting_counts_the_root_and_checks_nested_arrays
    assert_equal 200, call_body('{"a":' * 20 + "1" + "}" * 20).first
    assert_equal 422, call_body('{"a":' * 21 + "1" + "}" * 21).first
    assert_equal 422, call_body('{"a":' + "[" * 20 + "1" + "]" * 20 + "}").first
  end

  def test_media_type_charset_and_compression_are_checked
    ["text/plain", "application/json; charset=latin1", "application/json; other=value", 'application/json; charset="utf-8'].each do |type|
      assert_equal 415, call_body("{}", CONTENT_TYPE: type).first
    end
    ["application/json", "Application/JSON; charset=UTF-8", 'application/json; charset="utf-8"'].each do |type|
      assert_equal 200, call_body("{}", CONTENT_TYPE: type).first
    end
    assert_equal 415, call_body("{}", HTTP_CONTENT_ENCODING: "gzip").first
    assert_equal 200, call_body("{}", HTTP_CONTENT_ENCODING: "identity").first
  end

  def test_empty_get_and_non_api_requests_pass_through
    assert_equal 200, call_body("", REQUEST_METHOD: "GET", CONTENT_TYPE: nil).first
    assert_equal 200, call_body("invalid", PATH_INFO: "/elsewhere", CONTENT_TYPE: nil).first
  end

  def test_bodyless_writes_reach_authentication_without_requiring_a_media_type
    %w[POST PATCH PUT DELETE].each do |method|
      [nil, "application/x-www-form-urlencoded", "text/plain", "application/json"].each do |type|
        assert_equal 200, call_body("", REQUEST_METHOD: method, CONTENT_TYPE: type).first
        assert_equal "", @received.fetch("rack.input").read
      end
      assert_equal 415, call_body("{}", REQUEST_METHOD: method, CONTENT_TYPE: nil).first
      assert_equal 400, call_body(" ", REQUEST_METHOD: method, CONTENT_TYPE: "application/json").first
    end
  end
end

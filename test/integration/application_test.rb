require "test_helper"

class ApplicationTest < ActionDispatch::IntegrationTest
  test "unknown API routes return a JSON not-found response" do
    get "/v1/unknown", headers: {"Accept" => "application/json"}

    assert_response :not_found
    assert_equal "application/json", response.media_type
  end
end

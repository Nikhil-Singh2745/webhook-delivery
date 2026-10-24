require "test_helper"
require "rake"

Rails.application.load_tasks unless Rake::Task.task_defined?("credentials:issue")

class CredentialsTaskTest < ActiveSupport::TestCase
  test "bootstrap creates a tenant and emits a usable credential once" do
    output = nil
    assert_difference ["Tenant.count", "ApiCredential.count"], 1 do
      output, errors = invoke_task("credentials:issue", {"TENANT_NAME" => "Local demo"})
      assert_empty errors
    end

    issued = JSON.parse(output)
    credential = ApiCredential.authenticate(issued.fetch("credential"))
    assert_equal issued.fetch("credential_id"), credential.id
    assert_equal issued.fetch("tenant_id"), credential.tenant_id
    assert_equal "Local demo", credential.tenant.name
    assert_equal %w[credential credential_id tenant_id], issued.keys.sort
    assert_equal 1, output.lines.count
    assert_not_includes credential.reload.attributes.values, issued.fetch("credential")
  end

  test "issuing for an existing tenant preserves records and creates an independent credential" do
    tenant = create_tenant
    original_credential, original_token = ApiCredential.issue!(tenant: tenant)
    output = nil

    assert_no_difference "Tenant.count" do
      assert_difference "tenant.api_credentials.count", 1 do
        output, = invoke_task("credentials:issue", {"TENANT_ID" => tenant.id})
      end
    end

    issued = JSON.parse(output)
    assert_equal tenant.id, issued.fetch("tenant_id")
    assert_not_equal original_credential.id, issued.fetch("credential_id")
    assert_equal tenant, ApiCredential.authenticate(issued.fetch("credential")).tenant
    assert_equal original_credential, ApiCredential.authenticate(original_token)
  end

  test "invalid or ambiguous bootstrap inputs create no records" do
    [{}, {"TENANT_NAME" => " "}, {"TENANT_NAME" => "x" * 101},
      {"TENANT_ID" => SecureRandom.uuid}, {"TENANT_ID" => "not-a-uuid"},
      {"TENANT_NAME" => "Local", "TENANT_ID" => SecureRandom.uuid}].each do |environment|
      assert_no_difference ["Tenant.count", "ApiCredential.count"] do
        output, errors = invoke_task("credentials:issue", environment, fails: true)
        assert_empty output
        assert_not_empty errors
      end
    end
  end

  test "local revocation is repeatable and never outputs a credential" do
    credential, token = ApiCredential.issue!(tenant: create_tenant)

    2.times do
      output, errors = invoke_task("credentials:revoke", {"CREDENTIAL_ID" => credential.id})
      assert_empty errors
      assert_equal credential.id, JSON.parse(output).fetch("credential_id")
      assert JSON.parse(output).fetch("revoked_at").end_with?("Z")
      assert_not_includes output, token
      assert_nil ApiCredential.authenticate(token)
    end
  end

  test "revocation requires an existing credential identifier" do
    [{}, {"CREDENTIAL_ID" => SecureRandom.uuid}, {"CREDENTIAL_ID" => "not-a-uuid"}].each do |environment|
      output, errors = invoke_task("credentials:revoke", environment, fails: true)
      assert_empty output
      assert_not_empty errors
    end
  end

  private

  def invoke_task(name, environment, fails: false)
    keys = %w[TENANT_NAME TENANT_ID CREDENTIAL_ID]
    previous = ENV.to_h.slice(*keys)
    keys.each { |key| ENV.delete(key) }
    ENV.update(environment)
    task = Rake::Task[name]
    task.reenable

    capture_io do
      if fails
        error = assert_raises(SystemExit) { task.invoke }
        assert_equal 1, error.status
      else
        task.invoke
      end
    end
  ensure
    keys.each { |key| ENV.delete(key) }
    ENV.update(previous)
  end
end

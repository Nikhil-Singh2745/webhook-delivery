namespace :credentials do
  desc "Issue a credential: TENANT_NAME creates a tenant; TENANT_ID uses an existing tenant"
  task issue: :environment do
    tenant_name = ENV["TENANT_NAME"]&.strip
    tenant_id = ENV["TENANT_ID"]

    unless tenant_name.present? ^ tenant_id.present?
      abort "Supply exactly one of TENANT_NAME or TENANT_ID."
    end
    if tenant_name && tenant_name.length > 100
      abort "TENANT_NAME must contain 1–100 characters."
    end

    credential, token = ApplicationRecord.transaction do
      tenant = tenant_id.present? ? Tenant.find(tenant_id) : Tenant.create!(name: tenant_name)
      ApiCredential.issue!(tenant: tenant)
    end

    puts JSON.generate(tenant_id: credential.tenant_id, credential_id: credential.id, credential: token)
  rescue ActiveRecord::RecordNotFound
    abort "Tenant not found."
  end

  desc "Revoke a credential by CREDENTIAL_ID"
  task revoke: :environment do
    abort "Supply CREDENTIAL_ID." if ENV["CREDENTIAL_ID"].blank?

    credential = ApiCredential.find(ENV["CREDENTIAL_ID"])
    credential.revoke!
    puts JSON.generate(credential_id: credential.id, revoked_at: credential.revoked_at.utc.iso8601(6))
  rescue ActiveRecord::RecordNotFound
    abort "Credential not found."
  end
end

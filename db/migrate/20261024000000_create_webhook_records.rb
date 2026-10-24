class CreateWebhookRecords < ActiveRecord::Migration[8.1]
  def up
    create_tenants
    create_api_credentials
    create_endpoints
    create_events
    create_deliveries
    create_delivery_attempts
    protect_events
  end

  def down
    drop_table :delivery_attempts
    drop_table :deliveries
    drop_table :events
    drop_table :endpoints
    drop_table :api_credentials
    drop_table :tenants
    execute "DROP FUNCTION reject_event_mutation()"
  end

  private

  def create_tenants
    create_table :tenants, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :name, limit: 100, null: false
      t.timestamps
      t.check_constraint "btrim(name) <> ''", name: "tenants_name_present"
    end
  end

  def create_api_credentials
    create_table :api_credentials, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.string :token_digest, limit: 64, null: false
      t.datetime :revoked_at
      t.timestamps
      t.index :token_digest, unique: true
      t.check_constraint "token_digest ~ '^[0-9a-f]{64}$'", name: "api_credentials_digest_format"
    end
  end

  def create_endpoints
    create_table :endpoints, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.text :url, null: false
      t.text :signing_secret_ciphertext, null: false
      t.string :status, null: false, default: "active"
      t.datetime :disabled_at
      t.timestamps
      t.index [:tenant_id, :id], unique: true
      t.index [:tenant_id, :created_at, :id]
      t.check_constraint "btrim(url) <> '' AND btrim(signing_secret_ciphertext) <> ''",
        name: "endpoints_required_content"
      t.check_constraint <<~SQL.squish, name: "endpoints_status"
        (status = 'active' AND disabled_at IS NULL) OR
        (status = 'disabled' AND disabled_at IS NOT NULL)
      SQL
    end
  end

  def create_events
    create_table :events, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.string :idempotency_key, limit: 128, null: false
      t.string :request_fingerprint, limit: 64, null: false
      t.string :event_type, limit: 100, null: false
      t.jsonb :data, null: false
      t.text :outbound_body, null: false
      t.integer :delivery_count, null: false
      t.datetime :created_at, null: false
      t.index [:tenant_id, :idempotency_key], unique: true
      t.index [:tenant_id, :id], unique: true
      t.index [:tenant_id, :created_at, :id]
      t.check_constraint "idempotency_key ~ '^[A-Za-z0-9._:-]{1,128}$'", name: "events_key_format"
      t.check_constraint "request_fingerprint ~ '^[0-9a-f]{64}$'", name: "events_fingerprint_format"
      t.check_constraint "event_type ~ '^[a-z][a-z0-9_]*([.][a-z][a-z0-9_]*)*$'", name: "events_type_format"
      t.check_constraint "jsonb_typeof(data) = 'object'", name: "events_data_object"
      t.check_constraint "octet_length(outbound_body) BETWEEN 1 AND 131072", name: "events_body_size"
      t.check_constraint "delivery_count >= 0", name: "events_delivery_count"
    end
  end

  def create_deliveries
    create_table :deliveries, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.references :event, type: :uuid, null: false
      t.references :endpoint, type: :uuid, null: false
      t.string :state, null: false, default: "pending"
      t.integer :run_number, null: false, default: 1
      t.integer :attempts_in_run, null: false, default: 0
      t.bigint :total_attempts, null: false, default: 0
      t.datetime :next_attempt_at, default: -> { "CURRENT_TIMESTAMP" }
      t.string :last_error_code, limit: 64
      t.timestamps
      t.index [:event_id, :endpoint_id], unique: true
      t.index [:tenant_id, :created_at, :id]
      t.index [:next_attempt_at, :id], where: "state IN ('pending', 'retry_wait')", name: "deliveries_due"
      t.check_constraint "state IN ('pending', 'delivering', 'retry_wait', 'succeeded', 'failed', 'canceled')",
        name: "deliveries_state"
      t.check_constraint "run_number >= 1 AND attempts_in_run BETWEEN 0 AND 8 AND total_attempts >= attempts_in_run",
        name: "deliveries_counters"
      t.check_constraint "(state IN ('pending', 'retry_wait')) = (next_attempt_at IS NOT NULL)",
        name: "deliveries_schedule"
      t.check_constraint <<~SQL.squish, name: "deliveries_state_attempts"
        (state = 'pending' AND attempts_in_run = 0) OR
        (state = 'retry_wait' AND attempts_in_run BETWEEN 1 AND 7) OR
        (state IN ('delivering', 'succeeded', 'failed') AND attempts_in_run BETWEEN 1 AND 8) OR
        state = 'canceled'
      SQL
      t.check_constraint "last_error_code IS NULL OR last_error_code ~ '^[a-z][a-z0-9_]{0,63}$'",
        name: "deliveries_error_code"
    end

    # Including tenant_id prevents an otherwise valid UUID from linking another tenant's records.
    add_foreign_key :deliveries, :events, column: [:tenant_id, :event_id],
      primary_key: [:tenant_id, :id], name: "deliveries_tenant_event"
    add_foreign_key :deliveries, :endpoints, column: [:tenant_id, :endpoint_id],
      primary_key: [:tenant_id, :id], name: "deliveries_tenant_endpoint"
  end

  def create_delivery_attempts
    create_table :delivery_attempts, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :delivery, type: :uuid, null: false, foreign_key: true
      t.integer :run_number, null: false
      t.integer :attempt_number, null: false
      t.string :outcome, null: false, default: "in_progress"
      t.datetime :started_at, null: false
      t.datetime :finished_at
      t.integer :http_status
      t.string :error_code, limit: 64
      t.index [:delivery_id, :run_number, :attempt_number], unique: true, name: "attempts_identity"
      t.index :delivery_id, unique: true, where: "outcome = 'in_progress'", name: "attempts_one_in_progress"
      t.check_constraint "run_number >= 1 AND attempt_number BETWEEN 1 AND 8", name: "attempts_numbering"
      t.check_constraint "outcome IN ('in_progress', 'succeeded', 'transient_failure', 'permanent_failure', 'unknown', 'canceled')",
        name: "attempts_outcome"
      t.check_constraint <<~SQL.squish, name: "attempts_completion"
        (outcome = 'in_progress' AND finished_at IS NULL AND http_status IS NULL AND error_code IS NULL) OR
        (outcome <> 'in_progress' AND finished_at IS NOT NULL AND finished_at >= started_at)
      SQL
      t.check_constraint "http_status IS NULL OR http_status BETWEEN 100 AND 599", name: "attempts_http_status"
      t.check_constraint "outcome <> 'succeeded' OR (http_status IS NOT NULL AND http_status BETWEEN 200 AND 299)",
        name: "attempts_success_status"
      t.check_constraint "error_code IS NULL OR error_code ~ '^[a-z][a-z0-9_]{0,63}$'", name: "attempts_error_code"
    end
  end

  def protect_events
    execute <<~SQL
      CREATE FUNCTION reject_event_mutation() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'Events are immutable'
          USING ERRCODE = '23514', CONSTRAINT = 'events_are_immutable';
      END;
      $$;

      CREATE TRIGGER events_are_immutable
      BEFORE UPDATE OR DELETE ON events
      FOR EACH ROW EXECUTE FUNCTION reject_event_mutation();
    SQL
  end
end

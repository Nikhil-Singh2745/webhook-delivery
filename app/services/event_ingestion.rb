class EventIngestion
  class Conflict < StandardError
    def initialize
      super("Idempotency key was already used for a different request.")
    end
  end

  Result = Data.define(:event, :replayed)

  def self.call(tenant:, idempotency_key:, raw_body:)
    submission = EventSubmission.new(idempotency_key: idempotency_key, raw_body: raw_body)

    # The same tenant lock orders endpoint lifecycle changes and concurrent ingestion.
    tenant.with_lock do
      existing = tenant.events.find_by(idempotency_key: submission.idempotency_key)
      if existing
        raise Conflict unless existing.request_fingerprint == submission.request_fingerprint
        Result.new(event: existing, replayed: true)
      else
        endpoint_ids = tenant.endpoints.where(status: "active").order(:id).pluck(:id)
        event = tenant.events.create!(submission.event_attributes.merge(delivery_count: endpoint_ids.size))
        endpoint_ids.each_slice(500) do |batch|
          Delivery.insert_all!(batch.map do |endpoint_id|
            {tenant_id: tenant.id, event_id: event.id, endpoint_id: endpoint_id,
             next_attempt_at: event.created_at, created_at: event.created_at, updated_at: event.created_at}
          end)
        end
        Result.new(event: event, replayed: false)
      end
    end
  end
end

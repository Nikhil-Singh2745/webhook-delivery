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
        event = tenant.events.create!(submission.event_attributes.merge(delivery_count: 0))
        Result.new(event: event, replayed: false)
      end
    end
  end
end

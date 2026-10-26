module V1
  class EventsController < BaseController
    rescue_from EventSubmission::Invalid, with: :invalid_submission
    rescue_from EventIngestion::Conflict, with: :idempotency_conflict
    rescue_from ActiveRecord::StatementInvalid, with: :persistence_failed
    rescue_from ActiveRecord::ConnectionNotEstablished, ActiveRecord::ConnectionTimeoutError,
      ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout, with: :database_unavailable

    def create
      unless request.query_parameters.empty?
        render_error(:bad_request, "invalid_request", "Unsupported query parameters.")
        return
      end
      result = EventIngestion.call(tenant: current_tenant,
        idempotency_key: request.headers["Idempotency-Key"], raw_body: request.raw_post)
      response.headers["Idempotency-Replayed"] = "true" if result.replayed
      event = result.event
      render json: {data: {id: event.id, type: event.event_type, data: event.data,
        created_at: event.created_at.utc.iso8601(6), delivery_count: event.delivery_count}},
        status: result.replayed ? :ok : :created
    end

    def method_not_allowed
      response.headers["Allow"] = "POST"
      render_error(:method_not_allowed, "method_not_allowed", "Method not allowed.")
    end

    private

    def invalid_submission(error)
      render_error(error.status, error.code, error.message, details: error.details)
    end

    def idempotency_conflict(error)
      render_error(:conflict, "idempotency_conflict", error.message)
    end

    def database_unavailable
      render_error(:service_unavailable, "temporarily_unavailable", "Database is temporarily unavailable.")
    end

    def persistence_failed
      render_error(:internal_server_error, "internal_error", "Event could not be persisted.")
    end
  end
end

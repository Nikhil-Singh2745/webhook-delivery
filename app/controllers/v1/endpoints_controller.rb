module V1
  class EndpointsController < BaseController
    rescue_from EndpointDestination::Invalid, with: :invalid_destination
    rescue_from EndpointSecret::Unavailable, with: :secret_unavailable
    rescue_from EndpointPage::Invalid, with: :invalid_pagination

    def create
      return unless validate_fields(required: ["url"])
      endpoint, secret = EndpointLifecycle.register!(tenant: current_tenant, url: request.request_parameters["url"])
      render json: {data: representation(endpoint).merge(signing_secret: secret)}, status: :created
    end

    def index
      return unless validate_body_empty
      endpoints, cursor = EndpointPage.fetch(tenant: current_tenant, query: request.query_parameters)
      render json: {data: endpoints.map { |endpoint| representation(endpoint) }, next_cursor: cursor}
    end

    def show
      endpoint = find_endpoint(params[:id])
      return unless validate_fields
      render json: {data: representation(endpoint)}
    end

    def disable
      endpoint = find_endpoint(params[:id])
      return unless validate_fields
      endpoint = EndpointLifecycle.disable!(tenant: current_tenant, endpoint_id: endpoint.id)
      render json: {data: representation(endpoint)}
    end

    def method_not_allowed
      response.headers["Allow"] = params[:allowed_methods]
      render_error(:method_not_allowed, "method_not_allowed", "Method not allowed.")
    end

    private

    def representation(endpoint)
      {id: endpoint.id, url: endpoint.url, status: endpoint.status,
       created_at: endpoint.created_at.utc.iso8601(6), disabled_at: endpoint.disabled_at&.utc&.iso8601(6)}
    end

    def validate_fields(required: [])
      unless request.query_parameters.empty?
        render_error(:bad_request, "invalid_request", "Unsupported query parameters.")
        return false
      end
      body = request.request_parameters
      unless (body.keys - required).empty? && (required - body.keys).empty?
        render_error(:unprocessable_entity, "validation_failed", "Request fields are invalid.")
        return false
      end
      true
    end

    def validate_body_empty
      return true if request.request_parameters.empty?
      render_error(:unprocessable_entity, "validation_failed", "Request fields are invalid.")
      false
    end

    def invalid_destination
      render_error(:unprocessable_entity, "validation_failed", "Request validation failed.", details: {url: "must be an HTTPS destination with only public addresses on port 443"})
    end

    def secret_unavailable
      render_error(:service_unavailable, "temporarily_unavailable", "Endpoint encryption is unavailable.")
    end

    def invalid_pagination
      code = request.query_parameters.key?("cursor") ? "invalid_cursor" : "invalid_request"
      render_error(:bad_request, code, "Invalid pagination parameters.")
    end
  end
end

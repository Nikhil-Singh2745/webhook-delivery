# Test-only actions exercise the shared authentication and scoped lookups without exposing unfinished API routes.
class TenantIsolationProbeController < V1::BaseController
  def endpoints
    render json: {data: current_tenant.endpoints.order(:id).pluck(:id)}
  end

  def endpoint
    render json: {data: {id: find_endpoint(params[:id]).id}}
  end

  def event
    render json: {data: {id: find_event(params[:id]).id}}
  end

  def delivery
    render json: {data: {id: find_delivery(params[:id]).id}}
  end

  def event_delivery
    delivery = find_event(params[:event_id]).deliveries.find(params[:id])
    render json: {data: {id: delivery.id}}
  end

  def attempt
    attempt = find_delivery(params[:delivery_id]).delivery_attempts.find(params[:id])
    render json: {data: {id: attempt.id}}
  end

  def write_endpoint
    endpoint = find_endpoint(params[:id])
    endpoint.update!(status: "disabled", disabled_at: Time.current)
    render json: {data: {id: endpoint.id}}
  end

  def create_endpoint
    endpoint = current_tenant.endpoints.create!(
      url: "https://receiver.example/test-only",
      signing_secret_ciphertext: "test-only-placeholder"
    )
    render json: {data: {id: endpoint.id}}, status: :created
  end
end

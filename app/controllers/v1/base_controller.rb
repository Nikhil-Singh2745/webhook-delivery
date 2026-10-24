module V1
  class BaseController < ApplicationController
    before_action :authenticate_credential

    rescue_from ActiveRecord::RecordNotFound, with: :resource_not_found

    private

    attr_reader :current_tenant

    def authenticate_credential
      response.headers["Cache-Control"] = "no-store"
      token = request.authorization.to_s.b[/\ABearer[ \t]+(\S+)\z/i, 1]
      credential = ApiCredential.authenticate(token)

      if credential
        @current_tenant = credential.tenant
      else
        response.headers["WWW-Authenticate"] = "Bearer"
        render_error(:unauthorized, "unauthorized", "Authentication required.")
      end
    end

    def find_endpoint(id)
      current_tenant.endpoints.find(id)
    end

    def find_event(id)
      current_tenant.events.find(id)
    end

    def find_delivery(id)
      current_tenant.deliveries.find(id)
    end

    def resource_not_found
      render_error(:not_found, "not_found", "Resource not found.")
    end

    def render_error(status, code, message)
      render json: {
        error: {code: code, message: message, details: {}},
        request_id: request.request_id
      }, status: status
    end
  end
end

require_relative "api_json_body"
require "stringio"

class ApiRequestBody
  LIMIT = ApiJsonBody::LIMIT

  def initialize(app)
    @app = app
  end

  def call(env)
    return @app.call(env) unless env["PATH_INFO"].match?(%r{\A/v1(?:/|\z)})

    body = env["rack.input"]&.read(LIMIT + 1).to_s
    return error(env, 413, "payload_too_large", "Request body is too large.") if body.bytesize > LIMIT
    encoding = env["HTTP_CONTENT_ENCODING"]
    if encoding.present? && !encoding.casecmp?("identity")
      return error(env, 415, "unsupported_media_type", "Unsupported request encoding.")
    end

    unless body.empty?
      unless env["CONTENT_TYPE"].to_s.match?(/\Aapplication\/json(?:\s*;\s*charset\s*=\s*(?:utf-8|"utf-8"))?\z/i)
        return error(env, 415, "unsupported_media_type", "Use application/json with UTF-8 encoding.")
      end
      begin
        parsed = ApiJsonBody.parse(body)
      rescue ApiJsonBody::Invalid => exception
        return error(env, exception.status, exception.code, exception.message)
      end

      env["action_dispatch.request.request_parameters"] = parsed
    end

    env["rack.input"] = StringIO.new(body)
    @app.call(env)
  end

  private

  def error(env, status, code, message)
    body = JSON.generate(error: {code: code, message: message, details: {}}, request_id: env["action_dispatch.request_id"])
    [status, {"content-type" => "application/json", "cache-control" => "no-store"}, [body]]
  end
end

require "json"

class ApiJsonBody
  LIMIT = 65_536

  class Invalid < StandardError
    attr_reader :status, :code

    def initialize(status, code, message)
      @status, @code = status, code
      super(message)
    end
  end

  class DuplicateKey < StandardError; end

  class UniqueObject < Hash
    def []=(key, value)
      raise DuplicateKey if key?(key)
      super
    end
  end

  def self.parse(body)
    raise Invalid.new(413, "payload_too_large", "Request body is too large.") if body.bytesize > LIMIT
    body = body.dup.force_encoding(Encoding::UTF_8)
    raise Invalid.new(400, "invalid_json", "Invalid JSON body.") unless body.valid_encoding?

    parsed = JSON.parse(body, object_class: UniqueObject, max_nesting: 20, create_additions: false)
    unless parsed.is_a?(Hash)
      raise Invalid.new(400, "invalid_request", "Request body must be an object.")
    end
    parsed
  rescue JSON::NestingError
    raise Invalid.new(422, "validation_failed", "Request nesting exceeds the limit.")
  rescue JSON::ParserError, DuplicateKey
    raise Invalid.new(400, "invalid_json", "Invalid JSON body.")
  end
end

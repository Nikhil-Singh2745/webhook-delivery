require "digest"

class EventSubmission
  OUTBOUND_LIMIT = 131_072

  class Invalid < StandardError
    attr_reader :status, :code, :details

    def initialize(status, code, message, details: {})
      @status, @code, @details = status, code, details
      super(message)
    end
  end

  attr_reader :idempotency_key, :request_fingerprint

  def initialize(idempotency_key:, raw_body:)
    unless idempotency_key.is_a?(String) && idempotency_key.ascii_only? &&
        idempotency_key.match?(/\A[A-Za-z0-9._:-]{1,128}\z/)
      raise Invalid.new(400, "invalid_request", "A valid Idempotency-Key is required.")
    end
    body = raw_body.empty? ? {} : ApiJsonBody.parse(raw_body)
    unless body.keys.sort == %w[data type]
      raise Invalid.new(422, "validation_failed", "Request fields are invalid.")
    end
    @event_type = body.fetch("type")
    unless @event_type.is_a?(String) && @event_type.ascii_only? && @event_type.bytesize <= 100 &&
        @event_type.match?(/\A[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*\z/)
      raise Invalid.new(422, "validation_failed", "Request validation failed.", details: {type: "has an invalid format"})
    end
    @data = body.fetch("data")
    unless @data.is_a?(Hash) && storable_data?(@data)
      raise Invalid.new(422, "validation_failed", "Request validation failed.", details: {data: "must be an object with storable JSON values"})
    end
    @idempotency_key = idempotency_key.dup.freeze
    @request_fingerprint = Digest::SHA256.hexdigest(raw_body).freeze
  rescue ApiJsonBody::Invalid => error
    raise Invalid.new(error.status, error.code, error.message)
  end

  def event_attributes
    id = SecureRandom.uuid
    created_at = Time.current.utc.floor(6)
    outbound_body = JSON.generate(id: id, type: @event_type, created_at: created_at.iso8601(6), data: @data)
    if outbound_body.bytesize > OUTBOUND_LIMIT
      raise Invalid.new(422, "validation_failed", "Serialized event exceeds the size limit.")
    end
    {id: id, idempotency_key: idempotency_key, request_fingerprint: request_fingerprint,
     event_type: @event_type, data: @data, outbound_body: outbound_body, created_at: created_at}
  end

  private

  def storable_data?(value)
    # PostgreSQL jsonb cannot represent NUL strings or non-finite numbers.
    case value
    when Hash then value.all? { |key, item| storable_data?(key) && storable_data?(item) }
    when Array then value.all? { |item| storable_data?(item) }
    when String then !value.include?("\0")
    when Float then value.finite?
    else true
    end
  end
end

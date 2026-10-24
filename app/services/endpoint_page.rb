class EndpointPage
  class Invalid < StandardError; end

  def self.fetch(tenant:, query:)
    raise Invalid unless (query.keys - %w[limit cursor]).empty?
    limit = query.fetch("limit", "20")
    raise Invalid unless limit.is_a?(String) && limit.match?(/\A[1-9][0-9]{0,2}\z/) && limit.to_i <= 100

    relation = tenant.endpoints.order(created_at: :desc, id: :desc)
    if query.key?("cursor")
      cursor = query["cursor"]
      raise Invalid unless cursor.is_a?(String) && cursor.bytesize <= 2048
      position = verifier.verified(cursor, purpose: "endpoints:#{tenant.id}")
      raise Invalid unless position.is_a?(Hash) && position.keys.sort == %w[created_at id]
      raise Invalid unless position["id"].is_a?(String) && position["id"].match?(/\A[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\z/)
      raise Invalid unless position["created_at"].is_a?(String)
      timestamp = Time.iso8601(position.fetch("created_at"))
      relation = relation.where("(created_at, id) < (?, ?)", timestamp, position.fetch("id"))
    end

    records = relation.limit(limit.to_i + 1).to_a
    more = records.size > limit.to_i
    records = records.first(limit.to_i)
    cursor = if more
      last = records.last
      verifier.generate({created_at: last.created_at.utc.iso8601(6), id: last.id}, purpose: "endpoints:#{tenant.id}")
    end
    [records, cursor]
  rescue ArgumentError, TypeError
    raise Invalid
  end

  def self.verifier
    Rails.application.message_verifier("endpoint-pagination")
  end
  private_class_method :verifier
end

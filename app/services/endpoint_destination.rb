require "ipaddr"
require "resolv"
require "timeout"
require "uri"

class EndpointDestination
  class Invalid < StandardError; end

  # Conservatively exclude special-purpose ranges, including their public exceptions.
  IPV4_EXCLUSIONS = %w[
    0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16
    172.16.0.0/12 192.0.0.0/24 192.0.2.0/24 192.88.99.0/24 192.168.0.0/16
    198.18.0.0/15 198.51.100.0/24 203.0.113.0/24 224.0.0.0/3
  ].map { |range| IPAddr.new(range) }.freeze
  IPV6_GLOBAL = IPAddr.new("2000::/3")
  IPV6_EXCLUSIONS = %w[2001::/23 2001:db8::/32 2002::/16 3fff::/20].map { |range| IPAddr.new(range) }.freeze

  def self.resolve(host)
    Timeout.timeout(3) do
      Resolv::DNS.open do |dns|
        dns.timeouts = 1
        dns.getaddresses("#{host.delete_suffix('.')}.").map(&:to_s)
      end
    end
  end

  def self.validate!(url, resolver: method(:resolve))
    raise Invalid unless url.is_a?(String) && url.ascii_only? && !url.match?(/[\x00-\x20\x7f\\]/)

    uri = URI.parse(url)
    raise Invalid unless uri.is_a?(URI::HTTPS) && uri.host.present? && uri.port == 443
    raise Invalid if uri.userinfo || uri.query || uri.fragment

    host = uri.hostname
    raise Invalid if host.include?("%")
    literal = begin
      IPAddr.new(host)
    rescue IPAddr::InvalidAddressError
      nil
    end

    if literal
      addresses = [literal.to_s]
    else
      labels = host.delete_suffix(".").split(".", -1)
      raise Invalid unless labels.any? && host.bytesize <= 254 && labels.all? { |label| label.match?(/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/i) }
      # Prevent alternate numeric IPv4 spellings from being treated as DNS names.
      raise Invalid unless labels.last.match?(/\A[a-z][a-z0-9-]*\z/i) && !host.match?(/\A0x[0-9a-f]+\z/i)
      addresses = resolver.call(host)
    end

    raise Invalid if addresses.empty? || addresses.size > 32
    raise Invalid unless addresses.all? { |address| public_address?(address) }

    url
  rescue URI::InvalidURIError, IPAddr::InvalidAddressError, Resolv::ResolvError, Timeout::Error, SocketError, IOError, SystemCallError
    raise Invalid
  end

  def self.public_address?(address)
    ip = IPAddr.new(address)
    if ip.ipv4?
      IPV4_EXCLUSIONS.none? { |range| range.include?(ip) }
    else
      IPV6_GLOBAL.include?(ip) && IPV6_EXCLUSIONS.none? { |range| range.include?(ip) }
    end
  end
end

require_relative "../../config/environment"
require "minitest/autorun"

class EndpointDestinationTest < Minitest::Test
  def test_public_destinations_preserve_the_exact_registered_path
    resolver = ->(host) { assert_equal "receiver.example", host; ["8.8.8.8", "2606:4700:4700::1111"] }
    url = "https://receiver.example:443/hooks/a%2Fb/"
    assert_equal url, EndpointDestination.validate!(url, resolver: resolver)
    assert_equal "https://8.8.8.8/hooks", EndpointDestination.validate!("https://8.8.8.8/hooks")
    assert_equal "https://[2606:4700:4700::1111]/", EndpointDestination.validate!("https://[2606:4700:4700::1111]/")
  end

  def test_url_components_and_ambiguous_numeric_hosts_are_rejected_before_resolution
    urls = [nil, {}, "", "http://receiver.example/", "ftp://receiver.example/", "//receiver.example/",
      "https://user:password@receiver.example/", "https://receiver.example/?", "https://receiver.example/#",
      "https://receiver.example:8443/", "https://receiver.example/ bad", "https://receiver.example/\n",
      "https://receiver.example\\@8.8.8.8/", "https://127.1/", "https://2130706433/",
      "https://0177.0.0.1/", "https://0x7f000001/", "https://-receiver.example/",
      "https://receiver..example/", "https://./", "https://[fe80::1%25eth0]/",
      "https://[2606:4700:4700::1111%25eth0]/", "https://8.8.8.8:foo/", "https://8.8.8.8:99999/"]
    urls.each do |url|
      assert_raises(EndpointDestination::Invalid, url.inspect) do
        EndpointDestination.validate!(url, resolver: ->(_) { flunk "Invalid URL reached DNS" })
      end
    end
  end

  def test_private_special_and_nonpublic_ipv4_and_ipv6_are_rejected
    addresses = %w[0.0.0.0 10.1.2.3 100.64.0.1 127.0.0.1 169.254.169.254 172.16.0.1
      192.0.0.9 192.0.2.1 192.88.99.1 192.168.1.1 198.18.0.1 198.51.100.1 203.0.113.1
      224.0.0.1 255.255.255.255 :: ::1 ::ffff:8.8.8.8 ::ffff:127.0.0.1 64:ff9b::808:808
      fc00::1 fe80::1 ff02::1 2001::1 2001:db8::1 2002:808:808::1 3fff::1 5f00::1]
    addresses.each do |address|
      host = address.include?(":") ? "[#{address}]" : address
      assert_raises(EndpointDestination::Invalid, address) { EndpointDestination.validate!("https://#{host}/") }
      assert_raises(EndpointDestination::Invalid, address) do
        EndpointDestination.validate!("https://receiver.example/", resolver: ->(_) { ["8.8.8.8", address] })
      end
    end
  end

  def test_empty_malformed_excessive_and_failed_dns_results_are_rejected
    [[], ["invalid"], Array.new(33, "8.8.8.8")].each do |addresses|
      assert_raises(EndpointDestination::Invalid) do
        EndpointDestination.validate!("https://receiver.example/", resolver: ->(_) { addresses })
      end
    end
    [Resolv::ResolvError, Timeout::Error, SocketError, Errno::ECONNREFUSED].each do |error|
      assert_raises(EndpointDestination::Invalid) do
        EndpointDestination.validate!("https://receiver.example/", resolver: ->(_) { raise error })
      end
    end
  end
end

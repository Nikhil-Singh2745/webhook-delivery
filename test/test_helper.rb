ENV["RAILS_ENV"] = "test"
ENV["ENDPOINT_ENCRYPTION_KEY"] = "a" * 64

require_relative "../config/environment"
require "rails/test_help"
require_relative "support/record_helpers"

class ActiveSupport::TestCase
  parallelize(workers: 1)
  include RecordHelpers
end

ENV["RAILS_ENV"] = "test"

require_relative "../config/environment"
require "rails/test_help"
require_relative "support/record_helpers"

class ActiveSupport::TestCase
  parallelize(workers: 1)
  include RecordHelpers
end

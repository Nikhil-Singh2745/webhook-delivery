require "test_helper"

class DatabaseTest < ActiveSupport::TestCase
  test "uses the isolated PostgreSQL test database" do
    ActiveRecord::Base.connection_pool.with_connection do |connection|
      assert_equal "PostgreSQL", connection.adapter_name
      assert_equal "test", connection.pool.db_config.env_name
      assert_equal connection.pool.db_config.database, connection.select_value("SELECT current_database()")
    end
  end
end

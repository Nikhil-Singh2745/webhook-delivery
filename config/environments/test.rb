Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = ENV["CI"].present?
  config.consider_all_requests_local = false
  config.action_dispatch.show_exceptions = :rescuable
  config.action_controller.perform_caching = false
  config.cache_store = :null_store
  config.active_support.deprecation = :stderr
  config.action_controller.raise_on_missing_callback_actions = true

  config.after_initialize do
    configurations = ActiveRecord::Base.configurations
    test_database = configurations.configs_for(env_name: "test", name: "primary").database
    other_databases = %w[development production].map do |environment|
      configurations.configs_for(env_name: environment, name: "primary").database
    end

    if other_databases.include?(test_database)
      raise ArgumentError, "TEST_DATABASE_URL must name a separate test database."
    end
  end
end

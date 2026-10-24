namespace :endpoints do
  desc "Prepare the ignored local endpoint-encryption key without replacing an existing key"
  task prepare_key: :environment do
    EndpointSecret.prepare_key!
    puts "Endpoint encryption key configured. Keep the key with your database backups."
  end
end

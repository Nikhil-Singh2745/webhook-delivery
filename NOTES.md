# Implementation notes

- The application uses the Rails API stack with Active Record and PostgreSQL. Mail, browser assets, file storage, Action Cable, Active Job, and deployment scaffolding are omitted. Later delivery work will use database rows as its durable work source.
- Development and test use explicitly configured, separate database URLs. Test-environment boot rejects a database name matching development or production before schema preparation. Minitest runs in one process to keep local resource use bounded. The initial schema is empty; no domain tables or migrations exist yet.
- Setup prepares both local databases without resetting them. Checks run with the test environment and include Rails' Zeitwerk autoload validation.
- The application foundation does not implement domain constraints, tenant isolation, outbound safety, retries, or concurrency behavior.
- Version selection was checked against the official [Ruby maintenance branches](https://www.ruby-lang.org/en/downloads/branches/), [Rails releases](https://rubyonrails.org/releases), [Rails maintenance policy](https://rubyonrails.org/maintenance), and [PostgreSQL versioning policy](https://www.postgresql.org/support/versioning/). Rails 8.1 remains under security maintenance through October 10, 2027; its listed general bug-fix window has ended. Review supported patch releases before subsequent upgrades.

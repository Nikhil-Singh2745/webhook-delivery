# Reliable webhook delivery

A Rails API foundation for a local outbound webhook service. The application defines tenants, credential digests, endpoints, immutable events, deliveries, and attempts, with PostgreSQL constraints for their relationships and identities. Local credential issuance, revocation, and a shared authenticated controller with tenant-scoped lookups are implemented. Endpoint registration, inspection, ingestion, delivery workers, and replay remain unimplemented; there are no application API routes or delivery guarantees yet.

## Local setup

Requirements: Ruby **3.4.10**, Bundler **2.6.9**, and a local PostgreSQL **16** server. Ruby is pinned in `.ruby-version` and `Gemfile`; dependency versions are recorded in `Gemfile.lock`. No Redis, containers, Node.js, or paid services are required.

On Ubuntu 24.04 / WSL2, install the native dependencies and PostgreSQL:

```sh
sudo apt-get update
sudo apt-get install -y build-essential libssl-dev libyaml-dev zlib1g-dev libreadline-dev libffi-dev libgmp-dev pkg-config postgresql-16 libpq-dev
sudo service postgresql start
sudo -u postgres createuser --createdb "$USER"
```

Create the PostgreSQL role only if it does not already exist. The default connection uses the current operating-system user over a local Unix socket; the role needs permission to create the two application databases.

Install Ruby 3.4.10 with a Ruby version manager, then run these commands from this directory:

```sh
ruby --version
gem install bundler --version 2.6.9 --no-document
bin/setup
bin/check
bin/rails server --binding 127.0.0.1
```

`bin/setup` installs the locked dependencies and prepares `webhook_delivery_development` and `webhook_delivery_test`, applying pending migrations. It can be repeated without dropping either database and does not start a server. Dependency installation requires internet access on the first run; application checks use only local PostgreSQL. Keep PostgreSQL's `pg_dump` and `psql` client tools installed: schema preparation uses `db/structure.sql` to preserve database triggers.

For a different local connection, export `DEVELOPMENT_DATABASE_URL` and `TEST_DATABASE_URL` before setup. They must name separate databases. `.env.example` documents the defaults; `.env` files are not automatically loaded. To use one, copy the example to `.env` and load it into the shell:

```sh
set -a
. ./.env
set +a
```

Keep passwords in an ignored local file or PostgreSQL's password file. Local development and test configuration explicitly select their own URLs so a generic `DATABASE_URL` cannot silently point both environments at the same database. Standard PostgreSQL variables such as `PGHOST`, `PGPORT`, and `PGUSER` can supply connection defaults.

## Local credentials

Create a tenant and issue its first credential:

```sh
TENANT_NAME="Local demo" bin/rails credentials:issue
```

The command prints one JSON object containing `tenant_id`, `credential_id`, and `credential`. Save the credential securely: this is its only display, and only its SHA-256 digest is stored. Each `TENANT_NAME` invocation creates a new tenant, even if the name already exists. To issue another credential for an existing tenant, use its returned UUID:

```sh
TENANT_ID="<tenant UUID>" bin/rails credentials:issue
CREDENTIAL_ID="<credential UUID>" bin/rails credentials:revoke
```

Issuance commits the tenant and credential together before printing. Supplying both tenant selectors is rejected. Revocation is permanent and repeatable; it takes effect on subsequent authentication checks. It does not cancel a request already authenticated. These are local administrative commands with database access, not HTTP management routes. A lost credential must be replaced and its old credential ID revoked.

API controllers inherit bearer authentication from `V1::BaseController`. Credentials use `Authorization: Bearer <credential>`; missing, invalid, and revoked credentials receive the same JSON `401` and `WWW-Authenticate: Bearer`. The shared resource lookups resolve through the authenticated tenant and return JSON `404` for unknown or other-tenant records. Protected responses use `Cache-Control: no-store`. Resource routes will be added with their behavior; no HTTP credential demo is available yet.

## Checks and scope

```sh
bin/check                 # Test-environment autoload check and tests
bin/rails test            # Tests only
bin/rails routes          # No application routes yet
```

Tests cover PostgreSQL test-database isolation, record associations, uniqueness, foreign keys, cross-tenant delivery links, immutable events, delivery counters and schedules, and attempt identities and outcomes. Credential tests cover issuance, revocation, digest storage, and parameter filtering. Test-only routes exercise the shared controller through the Rails request stack, including authentication failures, nested lookups, tenant-scoped reads and writes, and identity isolation between requests. They do not expose unfinished resource APIs. Constraint tests bypass model validations. Test-environment boot rejects database names shared with development or production, even when configured on different hosts. These checks do not verify webhook behavior or worker concurrency.

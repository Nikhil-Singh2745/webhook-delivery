# Reliable webhook delivery

A local Rails API that accepts events and creates durable outbound webhook work. It supports API credentials, tenant-scoped endpoint management, encrypted signing secrets, and idempotent event ingestion. Each new event and its pending deliveries commit together. Delivery workers and replay remain unimplemented; accepting an event does not contact receivers.

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

`bin/setup` installs the locked dependencies, creates a local endpoint-encryption key if needed, and prepares `webhook_delivery_development` and `webhook_delivery_test`, applying pending migrations. It preserves existing keys and databases and does not start a server. Dependency installation requires internet access on the first run; application checks use only local PostgreSQL. Keep PostgreSQL's `pg_dump` and `psql` client tools installed: schema preparation uses `db/structure.sql` to preserve database triggers.

Signing secrets use a separate encryption key in ignored `config/endpoint_encryption.key`, created with owner-only permissions. Back it up securely alongside the database: losing or replacing it makes existing signing secrets unreadable. `ENDPOINT_ENCRYPTION_KEY` can override this file with exactly 64 lowercase hexadecimal characters. Existing installations can prepare the key with `bin/rails endpoints:prepare_key`; it never prints the key. Tests use a separate fixed test key.

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

Credentials use `Authorization: Bearer <credential>`; missing, invalid, and revoked credentials receive the same JSON `401` and `WWW-Authenticate: Bearer`. Resource lookups resolve through the authenticated tenant and return JSON `404` for unknown or other-tenant records. Protected responses use `Cache-Control: no-store`.

## Endpoints

With the server running, set `API_CREDENTIAL` to the issued credential in your shell, then register an endpoint:

```sh
curl --request POST http://127.0.0.1:3000/v1/endpoints \
  --header "Authorization: Bearer $API_CREDENTIAL" \
  --header 'Content-Type: application/json' \
  --data '{"url":"https://example.com/webhooks"}'
```

The `201` response contains `data` with `id`, `url`, `status`, `created_at`, `disabled_at`, and `signing_secret`. Save the secret securely: it is returned only at creation. Each registration creates a separate endpoint and secret, including repeated registrations of the same URL. A URL or secret cannot be changed; register a replacement instead.

Only HTTPS on port 443 is accepted. Credentials in URLs, query strings, fragments, non-public IP addresses, and DNS names resolving to any non-public address are rejected with `422`. Registration needs working DNS for hostnames. It preserves the exact URL and path; it does not contact the receiver or prove that it accepts webhooks. Private and loopback receivers have no exception yet.

Set `ENDPOINT_ID` to the returned UUID to inspect or disable it:

```sh
curl "http://127.0.0.1:3000/v1/endpoints?limit=20" \
  --header "Authorization: Bearer $API_CREDENTIAL"
curl "http://127.0.0.1:3000/v1/endpoints/$ENDPOINT_ID" \
  --header "Authorization: Bearer $API_CREDENTIAL"
curl --request POST "http://127.0.0.1:3000/v1/endpoints/$ENDPOINT_ID/disable" \
  --header "Authorization: Bearer $API_CREDENTIAL" \
  --header 'Content-Type: application/json' --data '{}'
```

Inspection and disable responses omit signing secrets. Lists include disabled endpoints, ordered by creation time and UUID descending. `limit` defaults to 20 and cannot exceed 100; pass the returned `next_cursor` as the next request's `cursor` query parameter. Cursors are bound to the tenant and endpoint list; pagination is not a snapshot.

Disabling is permanent and repeatable. It cancels queued `pending` and `retry_wait` deliveries in the same transaction while preserving attempt history and already-running deliveries. The delivery contract allows an already-claimed request to finish after disabling; its eventual worker behavior is not implemented yet. No enable, update, or delete route exists.

Requests use JSON objects, reject unknown fields and duplicate keys, and allow at most 65,536 body bytes and 20 nested containers. Compressed bodies and unsupported media types are rejected. Errors contain `error` (`code`, `message`, and `details`) and `request_id`.

## Events

Submit an event with a tenant-scoped idempotency key:

```sh
curl --request POST http://127.0.0.1:3000/v1/events \
  --header "Authorization: Bearer $API_CREDENTIAL" \
  --header 'Content-Type: application/json' \
  --header 'Idempotency-Key: demo_invoice_1' \
  --data '{"type":"invoice.created","data":{"invoice_id":"demo_invoice_1","amount_minor":2500}}'
```

A new request returns `201` with `data` containing `id`, `type`, `data`, `created_at`, and `delivery_count`. The event and one immediately eligible `pending` delivery per active tenant endpoint commit in one PostgreSQL transaction before success is returned. No external queue or receiver request is involved. Acceptance guarantees local durable work subject to database durability; it does not guarantee receipt.

Retry with the same key and exact body bytes to receive the original event with `200` and `Idempotency-Replayed: true`. Changed valid bytes return `409 idempotency_conflict`, including whitespace or field-order changes. Keys are case-sensitive, 1–128 ASCII letters, digits, `.`, `_`, `:`, or `-`, and have no automatic expiry. Validation failures do not reserve a key. If a connection fails after submission, retry with the original key and bytes to resolve the unknown outcome.

`type` must match `[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*` and contain at most 100 ASCII characters. `data` must be an object; PostgreSQL-incompatible NUL strings and non-finite numbers are rejected. Client identifiers, timestamps, endpoint lists, and query parameters are rejected.

The endpoint snapshot is ordered with registration and disable by a tenant lock. Earlier committed registration is included; later registration never backfills old events. Earlier disable excludes an endpoint; later disable cancels its queued delivery. Zero active endpoints is valid. Matching retries take no new snapshot, and `delivery_count` always retains the original count, including subsequently canceled work. Event inspection routes and delivery processing are not available yet.

## Checks and scope

```sh
bin/check                 # Test-environment autoload check and tests
bin/rails test            # Tests only
bin/rails routes          # Implemented endpoint routes and event acceptance
```

Tests cover PostgreSQL isolation and constraints, immutable events, credentials, tenant boundaries, endpoint APIs, secret encryption, URL/DNS policy, body parsing, pagination, cancellation rollback, competing endpoint transactions, and event acceptance including concurrent duplicates and conflicts, atomic fan-out rollback across insert batches, endpoint-snapshot races, and recovery after a lost response. Ingestion concurrency tests use isolated PostgreSQL schemas to permit real commits without deleting immutable history. Network-bound tests use controlled DNS results and public IP literals without contacting receivers. Additional temporary routes test shared authentication and nested ownership. Test-environment boot rejects database names shared with development or production. Worker claims, outbound connections, retries, replay, and event/delivery inspection are not implemented.

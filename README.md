# Reliable webhook delivery

A Rails API foundation for a local outbound webhook service. The current application provides PostgreSQL configuration, application boot, and initial checks. Endpoint registration, authentication, ingestion, delivery workers, and replay are not implemented yet; there are no application API routes or delivery guarantees at this stage.

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

`bin/setup` installs the locked dependencies and prepares `webhook_delivery_development` and `webhook_delivery_test`. It can be repeated without dropping either database and does not start a server. Dependency installation requires internet access on the first run; application checks use only local PostgreSQL.

For a different local connection, export `DEVELOPMENT_DATABASE_URL` and `TEST_DATABASE_URL` before setup. They must name separate databases. `.env.example` documents the defaults; `.env` files are not automatically loaded. To use one, copy the example to `.env` and load it into the shell:

```sh
set -a
. ./.env
set +a
```

Keep passwords in an ignored local file or PostgreSQL's password file. Local development and test configuration explicitly select their own URLs so a generic `DATABASE_URL` cannot silently point both environments at the same database. Standard PostgreSQL variables such as `PGHOST`, `PGPORT`, and `PGUSER` can supply connection defaults.

## Checks and scope

```sh
bin/check                 # Test-environment autoload check and tests
bin/rails test            # Tests only
bin/rails routes          # No application routes yet
```

The initial tests cover PostgreSQL test-database isolation and an unknown JSON route through the Rails request stack. Test-environment boot rejects database names shared with development or production, even when configured on different hosts. These checks do not verify webhook behavior.

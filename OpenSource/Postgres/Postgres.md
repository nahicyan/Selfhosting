# PostgreSQL (shared, Docker)

One PostgreSQL server that many apps share, reachable remotely over TLS with
client certificates. ufw decides who can reach the port. Each app gets its own
role and database, and each database can be backed up and restored on its own.

## Layout

```
Postgres/
├── Postgres.md
├── docker-compose.yml                  # Template copied into every instance
└── scripts/
    ├── postgres-docker-install.sh      # CA + certs, pg_hba, Docker network, ufw, start, cron
    ├── postgres-docker-manage.sh       # Add an app, client certs, passwords, ufw, status
    ├── postgres-docker-backup.sh       # Roles + one dump per database + config, timestamped
    └── postgres-docker-restore.sh      # One database, or everything (disaster recovery)
```

Each instance lives at `/var/www/docker/postgres/<domain>/`:

| Path                  | Contents                                                        |
|-----------------------|-----------------------------------------------------------------|
| `docker-compose.yml`  | Copy of the template                                            |
| `.env`                | Settings + superuser password (mode `600`)                      |
| `conf/pg_hba.conf`    | Who may connect, and how                                        |
| `certs/`              | `server.crt`, `server.key` (root:postgres `640`), `ca.crt`. Mounted read-only |
| `ca/`                 | The private CA. `ca.key` is never mounted into the container    |
| `clients/<role>/`     | Bundle for a remote login: `ca.crt`, `client.crt`, `client.key`, `client.pk8` |

The data lives in the Docker volume `<project>_data`.

## How access works

| From                      | Connects to                     | Needs                                     |
|---------------------------|---------------------------------|-------------------------------------------|
| A Docker app on this host | `<gateway>:<port>` on the `postgres` network | Password                       |
| A process on this host    | `127.0.0.1:<port>`              | Password                                  |
| Anywhere else             | `<domain>:<port>`               | ufw allows the source, **and** TLS, password and a client certificate whose CN is the role name |

You can turn the client certificate requirement off at install time. TLS and
the password are always required for remote connections.

**Why host networking.** Ports that Docker publishes bypass ufw. A
`ports: 5432:5432` mapping would be open to the whole internet no matter what
ufw says. The container uses `network_mode: host` instead, so Postgres listens
like a normal host service and the ufw rules really apply.

**Why the `postgres` Docker network.** Containers in other compose projects
can't use a Docker DNS name to reach a host-network service. The installer
creates a bridge network (default name `postgres`, default subnet
`10.254.254.0/24`, bridge `br-postgres`) with inter-container traffic turned
off. Apps join it and connect to its gateway IP. One ufw rule allows that
bridge to reach the port. Apps share Postgres but can't reach each other.

**Why there is no Nginx vhost.** Postgres doesn't speak HTTP, and it does its
own TLS handshake (an SSLRequest inside the Postgres protocol), so Nginx can't
terminate TLS for normal clients. Putting a stream proxy in front would also
hide client IPs from `pg_hba.conf`. The certificate comes from the private CA
the installer creates, not from Let's Encrypt, so no DNS challenge or 90-day
renewal is involved.

## Prerequisites

- Docker + the Docker Compose plugin, and your user in the `docker` group
- `openssl`, `ufw`, `sudo`
- A DNS record for the domain if clients connect by name. `sslmode=verify-full`
  checks the name against the certificate. To connect by IP, give that IP at the
  certificate prompt.

## Install

```bash
./scripts/postgres-docker-install.sh
```

```
  1) New instance
  2) From a backup  (reuse its CA, client certificates and superuser password)
```

Prompts (press Enter to accept the default):

- **Domain**: the name clients connect to, e.g. `db.example.com`. It goes into
  the server certificate and names the instance directory.
- **Port**: default `5432`. The script refuses a port that's already in use.
- **Server IP for the certificate** (optional): for clients that connect by IP.
- **Allowed sources**: IPs or CIDRs separated by spaces, `any`, or blank. One
  ufw rule is added per source.
- **Require a client certificate**: default yes.
- **Docker network / subnet**: default `postgres` / `10.254.254.0/24`. An
  existing network with that name is reused.

What it does:

1. Creates the instance directory, the CA (10 years), a server certificate for
   the domain (10 years) and a client bundle for `postgres` (825 days)
2. Creates the Docker network
3. Writes `conf/pg_hba.conf` and `.env`
4. Pulls the image and gives `server.key` to root:postgres `640` (Postgres
   refuses a key it can't trust)
5. Adds the ufw rules: the Docker bridge, plus each allowed source. It
   **does not enable ufw**. If ufw is inactive it warns you; allow SSH before
   you enable it.
6. Starts Postgres and waits for it to report healthy
7. **Checks a real remote login**: from the host's outward-facing IP, using the
   `postgres` client bundle and `sslmode=verify-full` against the domain
8. Offers to add a nightly backup to your crontab (02:30, keeps 7)

The superuser password is generated and printed. It's stored in `.env`.

### Mode 2: rebuild from a backup

Pick a snapshot. The installer reuses its CA, every client bundle and the
superuser password, then issues a **new** server certificate from that CA.
Certificates you already handed out keep working, even if the domain or IP
changes. Then load the data:

```bash
./scripts/postgres-docker-install.sh    # mode 2
./scripts/postgres-docker-restore.sh    # option 2: roles + every database
```

ufw rules aren't part of a backup. Mode 2 asks for the allowed sources again.

## Adding an app

```bash
./scripts/postgres-docker-manage.sh     # option 1
```

This creates a login role and a database with the same name, owned by the
role, with `CONNECT` revoked from `PUBLIC`, so no other app's role can open
it. The script prints the password once, along with the connection strings.
For a Docker app, add this to the app's own `docker-compose.yml`:

```yaml
services:
  app:
    environment:
      DATABASE_URL: postgres://myapp:<password>@postgres:5432/myapp
    extra_hosts:
      - "postgres:10.254.254.1"       # PG_GATEWAY from the instance .env
    networks: [default, postgres]
networks:
  postgres:
    external: true
```

`extra_hosts` gives the name `postgres` to the gateway. Use the gateway of
*this* network, not `host-gateway`. `host-gateway` is `docker0`, so the
traffic would arrive on another bridge and ufw would drop it.

## Remote clients

Copy the role's bundle to the client machine, then:

```bash
scp -r you@db.example.com:/var/www/docker/postgres/db.example.com/clients/myapp ./pg-myapp
psql "host=db.example.com port=5432 dbname=myapp user=myapp sslmode=verify-full \
      sslrootcert=pg-myapp/ca.crt sslcert=pg-myapp/client.crt sslkey=pg-myapp/client.key"
```

- **libpq tools and drivers** (psql, Python, Node, Go, Rails, …): use the
  `sslrootcert` / `sslcert` / `sslkey` parameters shown above. `client.key`
  must be mode `600`.
- **Java / pgjdbc** (DBeaver, DataGrip, Java apps): SSL mode `verify-full`,
  root certificate `ca.crt`, client certificate `client.crt`, client key
  **`client.pk8`**. pgjdbc only reads DER PKCS#8 keys.

Use `sslmode=verify-full`. `require` encrypts the connection but doesn't check
the server's identity.

## Manage

```bash
./scripts/postgres-docker-manage.sh
```

1. **Add an app**: role + database + connection strings, with an optional
   client certificate
2. **Issue a client certificate**: writes `clients/<role>/`. The CN must equal
   the role.
3. **Reset a role's password**: for `postgres`, it updates `.env` as well
4. **Allow a remote address through ufw**
5. **Remove a remote address from ufw**
6. **Status**: databases (owner, size, connections), roles, certificate
   expiry dates, ufw rules for the port

There's no certificate revocation list. A remote login needs both the
certificate and the password, so to lock someone out, reset the role's
password (option 3).

## Backup

```bash
./scripts/postgres-docker-backup.sh
```

Writes `<backup-root>/postgres/<domain>/<timestamp>/`:

```
roles.sql.gz            pg_dumpall --roles-only (password hashes, memberships, role settings)
databases/<db>.sql.gz   pg_dump --create, one per database (owner, grants, settings included)
databases.tsv           name <tab> owner
config.tar.gz           .env, compose, pg_hba, ca/, clients/, certs/ (not server.key)
manifest.txt            date, image, server version, databases
SHA256SUMS              checked before any restore
```

- Every dump is checked for pg_dump's closing line, which catches truncation.
  A failed run deletes its half-written snapshot.
- Apps stay up during the backup. Each `pg_dump` reads one consistent snapshot.
- By default the script keeps the 7 newest snapshots per domain.
- A lock file stops two backups (or a backup and a restore) from running at
  the same time.

Unattended (cron) mode, which the installer can set up for you:

```cron
30 2 * * * POSTGRES_BACKUP_ROOT=/home/backup POSTGRES_INSTANCE_DIR=/var/www/docker/postgres/db.example.com /path/to/scripts/postgres-docker-backup.sh >> $HOME/postgres-backup.log 2>&1
```

`POSTGRES_BACKUP_KEEP` sets how many snapshots to keep (`0` = never prune).

Backups contain the CA key and password hashes. Treat them like the server
itself: the snapshot directories are mode `700`, and off-site copies should be
encrypted.

## Restore

```bash
./scripts/postgres-docker-restore.sh
```

1. **One database**: drops and recreates just that database. No other app is
   touched. Its owner role must already exist on the target.
2. **Everything**: restores roles first (a role that already exists gets its
   attributes and password reset to the snapshot's), then every database.

The `postgres` superuser is never touched, so its password stays whatever the
target's `.env` says. Before anything is dropped, the script takes a full
**pre-restore snapshot** into the same backup root. It shows up in the list
marked `pre-restore`, so you can undo a restore with this same script.

**Stop the apps that use the database first.** `DROP DATABASE … WITH (FORCE)`
disconnects them, and an app that reconnects mid-restore may run its
migrations against a half-loaded database.

## Upgrading PostgreSQL

Minor versions (18.x): pull and recreate.

```bash
cd /var/www/docker/postgres/<domain>
docker compose --env-file .env pull && docker compose --env-file .env up -d
```

Major versions (18 → 19) won't start on the old data directory. Use dump and
restore:

```bash
./scripts/postgres-docker-backup.sh
docker compose --env-file .env down
docker volume rm <project>_data           # docker volume ls to confirm the name
# set POSTGRES_IMAGE=postgres:19 in .env
docker compose --env-file .env up -d
./scripts/postgres-docker-restore.sh       # option 2
```

On 18+, the data mount point is `/var/lib/postgresql`. Images before 18 need
`/var/lib/postgresql/data` in the compose file instead.

## Useful commands

Run from `/var/www/docker/postgres/<domain>/`:

```bash
DC="docker compose --env-file .env -f docker-compose.yml"

$DC ps                                        # status and health
$DC logs -f postgres
$DC exec -u postgres postgres psql            # superuser shell, no password (peer auth)
$DC exec -u postgres postgres psql -c 'SELECT pg_reload_conf()'   # after editing pg_hba.conf
```

Tuning (`shared_buffers`, `work_mem`, `max_connections`, …): add `--name=value`
lines under `command:` in the instance's `docker-compose.yml`, then `$DC up -d`.

## Troubleshooting

- **`connection requires a valid client certificate`**: the client didn't send
  `sslcert`/`sslkey`, or it sent a certificate that wasn't issued by this
  instance's CA.
- **`password authentication failed` with the right password, remotely**: the
  client certificate's CN isn't the role you're logging in as. Issue one for
  that role (manage, option 2).
- **`no pg_hba.conf entry … no encryption`**: the client used
  `sslmode=disable`. Remote connections must use TLS.
- **`server certificate … does not match host name`**: you connected by a name
  or IP that isn't in the certificate. Reinstall with the right domain, or add
  the IP at the certificate prompt (mode 2 keeps the CA).
- **A Docker app times out**: it isn't on the `postgres` network, or it uses
  `host.docker.internal` / `host-gateway` instead of `PG_GATEWAY`.
- **Remote clients time out**: ufw doesn't allow their address (manage,
  option 4), or your provider's firewall blocks the port.
- **Postgres won't start: `private key file … has group or world access` or
  `must be owned by the database user or root`**: something reset the ownership
  of `server.key`. Fix it with:
  `docker run --rm --entrypoint sh -v "$PWD/certs:/certs" postgres:18 -c 'chown root:postgres /certs/server.key && chmod 640 /certs/server.key'`

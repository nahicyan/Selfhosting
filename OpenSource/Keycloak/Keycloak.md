# Keycloak (Docker Compose)

Self-hosted [Keycloak](https://www.keycloak.org/) with PostgreSQL, run behind a
host Nginx reverse proxy that terminates TLS. Keycloak itself speaks plain HTTP
on `127.0.0.1` and trusts `X-Forwarded-*` from the proxy — the "external cert"
topology, as opposed to letting Keycloak hold the certificate on `:8443`.

## Layout

```
Keycloak/
├── Keycloak.md
├── keycloak-docker-nginx.conf              # Reverse proxy template (placeholders: auth.example.com, 127.0.0.1:8090)
├── keycloak-production-docker-compose/     # Vendored upstream compose repo + Theme.md (reference)
└── scripts/
    ├── keycloak-docker-install.sh          # Generates .env + compose, starts the stack, wires up Nginx/certbot
    ├── keycloak-docker-backup.sh           # Postgres dump + per-realm JSON export + .env, timestamped
    └── keycloak-docker-restore.sh          # Restores Postgres / realm JSON / .env into a running instance
```

Each installed instance lives at `/var/www/docker/keycloak/<domain>/`, which is
a **clone of the compose repo** plus one file the installer writes:

| Path                                 | Contents                                             |
|--------------------------------------|-------------------------------------------------------|
| `docker-compose.external-cert.yml`   | From the repo — the file this setup runs              |
| `.env`                               | **Written by the installer** (mode `600`)             |
| `themes/`                            | Mounted read-only; one subdirectory per custom theme  |
| `.git/`, `README.md`, `Theme.md`, …  | The rest of the clone                                 |

The installer writes no YAML. Everything about the stack — images, volumes,
ports, health, the Postgres data layout — lives in
[`keycloak-production-docker-compose`](https://github.com/nahicyan/keycloak-production-docker-compose)
and is configured through `.env`.

> [!important]
> The compose **filename** and the two **service names** (`keycloak`,
> `keycloak_postgres`) are a contract. `keycloak-docker-backup.sh` and
> `keycloak-docker-restore.sh` discover instances with
> `find /var/www/docker/keycloak -maxdepth 2 -name docker-compose.external-cert.yml`
> and address services by name. Rename either and both scripts stop finding
> your instance.

## Prerequisites

- Docker + the Docker Compose plugin
- `git`, and network access to GitHub from the host — the installer clones the
  compose repo
- Nginx and certbot on the host
- `jq` (only needed by the backup/restore scripts, for realm JSON)
- A public DNS record pointing at the host — Keycloak issues tokens against
  this hostname, so it must be the name clients actually use

## Install

```bash
./scripts/keycloak-docker-install.sh
```

The script opens with a mode choice:

```
  1) New instance                (enter all values now)
  2) Restore .env from a backup  (reuse credentials from a snapshot)
```

### Mode 1 — New instance

You'll be prompted for:

- **Domain** — e.g. `auth.example.com` (stored bare, without a scheme)
- **Port** — host port Keycloak publishes on, `127.0.0.1` only (default `8090`).
  This one value is written to `.env` as `KEYCLOAK_PORT`, published by the
  compose file, **and** substituted into the Nginx vhost, so the proxy and the
  container can't drift apart. If something is already listening on it, the
  script says what and asks before continuing.
- **Admin username / password** — blank password generates a strong one and
  prints it
- **PostgreSQL username / password** — same
Image tags are not asked for, and neither is anything else about the stack —
images, volumes, health, log limits and the Postgres data layout all live in the
compose repo.

### Mode 2 — Restore `.env` from a backup

Pick a backup root (default `/home/backup`), then the domain and snapshot:

```
  #    Date                               Postgres   Realms       .env
  ---- ---------------------------------- ---------- ------------ ------
  1)   September 3, 2026, 02:00 AM        ok         2 realm(s)   ok
  2)   September 2, 2026, 02:00 AM        ok         2 realm(s)   ok
```

The snapshot's `.env` is copied in **verbatim** — passwords keep their original
values and quoting, and any extra keys you had are preserved. Only the keys
this install actually decides (domain, port, project name, image tags) are
reconciled afterwards, and the domain/port prompts are pre-filled from the file
so pressing Enter keeps them.

This is the mode to use before restoring a Postgres dump: the dump contains its
own database role and admin account, so Keycloak has to come up already
configured with credentials that match it. Order of operations for a full
rebuild:

```bash
./scripts/keycloak-docker-install.sh    # mode 2 — .env from the snapshot
./scripts/keycloak-docker-restore.sh    # option 2 — Postgres, and say yes to themes
```

After that restore the admin account is whatever the dump holds, not the
bootstrap values in `.env`.

### What the script does

1. Validates the domain, port, and secrets, and refuses to install into a
   non-empty directory
2. `git clone --depth 1` of the compose repo into
   `/var/www/docker/keycloak/<domain>/`, chowned to you rather than root
3. Writes `.env` (mode `600`) — the only file it creates
4. Runs `docker compose config` against the chosen compose file and this `.env`
   as a pre-flight check
5. Creates any bind-mount source the compose file expects (`themes/`), reading
   the resolved paths back out of `config` so Docker doesn't create them
   root-owned
6. Optionally opens `.env` or the compose file in `$EDITOR`
7. Pulls images and starts the stack
8. Polls `http://127.0.0.1:<port>/realms/master` until Keycloak answers — first
   boot runs the full schema migration, so this can take minutes
9. Optionally requests a Let's Encrypt certificate (`certbot certonly --nginx`)
10. Optionally installs `keycloak-docker-nginx.conf` into
    `/etc/nginx/sites-available/<domain>` with the domain and port substituted,
    symlinks it, runs `nginx -t`, and reloads

## `.env` reference

```ini
COMPOSE_PROJECT_NAME=keycloak-auth-example-com
KEYCLOAK_URL=auth.example.com     # bare hostname, no scheme
KEYCLOAK_PORT=8090                # published on 127.0.0.1 only
KEYCLOAK_USER=admin
KEYCLOAK_PASSWORD='...'
POSTGRES_USER=keycloak
POSTGRES_PASSWORD='...'
```

`KEYCLOAK_URL` stays a bare hostname because the backup and restore scripts
build `https://$KEYCLOAK_URL` from it to reach the admin API. Adding a scheme
here breaks realm export.

`KEYCLOAK_USER` / `KEYCLOAK_PASSWORD` only bootstrap the first admin while the
database is still empty. Once Keycloak has started, the account lives in
Postgres — changing these values later does nothing.

Secrets are limited to `A-Z a-z 0-9 . _ ~ - @ ! ? * :` and written
single-quoted. That set is safe in all three places a password ends up: bash's
`source` (backup/restore), Compose's dotenv parser, and the URL-encoded form
body `keycloak-docker-backup.sh` posts to log in to the admin API. A `&` or `=`
in an admin password would silently break realm export at backup time.

## Where the compose file comes from

The instance directory is a clone of
[`keycloak-production-docker-compose`](https://github.com/nahicyan/keycloak-production-docker-compose),
so the compose file you run is the one in that repo — not a copy, not a
generated approximation. Fixing something about the stack means committing it
there; every future install picks it up, and existing instances pick it up with
`git pull`.

`docker-compose.external-cert.yml` is the file this setup runs: TLS terminated
by the host Nginx, Keycloak on loopback, and `./themes` mounted read-only. The
repo's other two files (`docker-compose.yml`, which holds the certificate itself
on `:8443`, and `docker-compose.dev.yml`, which runs `start-dev`) come along in
the clone but aren't used — the install, backup and restore scripts all address
the external-cert file by name.

What the installer contributes is `.env`, and nothing else. The compose file
reads exactly seven keys from it — `KEYCLOAK_PORT`, `KEYCLOAK_URL`,
`KEYCLOAK_USER`, `KEYCLOAK_PASSWORD`, `POSTGRES_USER`, `POSTGRES_PASSWORD` and
`COMPOSE_PROJECT_NAME` — which is what lets one repo serve any number of
instances on one host. Everything else, including the images, is whatever the
repo says at the commit you cloned.

## Nginx reverse proxy

`keycloak-docker-nginx.conf` terminates TLS, redirects `80` → `443`, and
proxies to `127.0.0.1:<port>` with `Host` and the `X-Forwarded-*` headers
Keycloak needs to build correct issuer/redirect URLs (it's started with
`--proxy-headers=xforwarded`).

Two buffer settings matter more here than in a typical vhost:
`large_client_header_buffers 4 32k` for the long OIDC/SAML query strings and
large session cookies coming *in*, and `proxy_buffer_size`/`proxy_buffers`
going *out* — a response carrying several `Set-Cookie` headers mid-login
overflows the defaults and Nginx answers `502 upstream sent too big header`.

`X-Frame-Options` is deliberately not set: Keycloak sends its own per-realm
frame policy (Realm settings → Security defenses), and a blanket header here
would override it.

## Custom themes

`docker-compose.external-cert.yml` mounts the themes directory as a whole:

```yaml
    volumes:
      - ./themes:/opt/keycloak/themes:ro
```

So adding a theme is just a directory — build it into
`/var/www/docker/keycloak/<domain>/themes/<name>/` following
[`Theme.md`](keycloak-production-docker-compose/Theme.md), restart, and select
it under Realm settings → Themes → Login theme. Any number of themes can sit
there side by side, and no compose edit is involved either way.

Mounting over `/opt/keycloak/themes` doesn't hide the built-in themes: they ship
inside `org.keycloak.keycloak-themes-*.jar`, which is why Theme.md's Step 2
extracts the reference templates from that JAR rather than from this directory.

## Backup

```bash
./scripts/keycloak-docker-backup.sh
```

Writes `<backup-root>/keycloak/<domain>/<timestamp>/`:

```
postgres/keycloak.sql.gz   full database — authoritative
keycloak/<realm>.json      per-realm config export (no users, no credentials)
env/.env                   mode 600
themes/themes.tar.gz       custom login themes, when the instance has any
manifest.txt               images, realms and themes captured, folder contents
```

The theme files are in there because the database only records *which* theme a
realm uses. Restoring a dump onto a fresh instance without them leaves realms
pointing at a theme that isn't on disk.

Keeps the last 7 snapshots per domain and deletes a half-written one if
anything fails. The realm JSON needs the admin API to be reachable over
`https://<domain>`; if the token request fails it warns and continues — the
Postgres dump is unaffected.

## Restore

```bash
./scripts/keycloak-docker-restore.sh
```

Five options:

1. **Keycloak (realm JSON)** — config only, and it *deletes and recreates* the
   realm. Users and credentials are not in the export. Use it to undo a bad
   config change to one realm.
2. **Postgres** — the whole database: every realm, users, password hashes,
   signing keys. Real disaster recovery.
3. **`.env`** — credentials only.
4. **Postgres + `.env`** — `.env` is restored and re-sourced *first*, so the
   database restore uses the credentials just written.
5. **Custom theme files** — extracts `themes/` back into the instance.

Whichever of 1–4 you pick, if the snapshot carries theme files the script offers
to bring those along too. Extracting merges over what's on disk and never
deletes a theme the snapshot doesn't have; Keycloak is restarted afterwards
because it caches themes in production mode.

Options 1 and 2 are never offered together on purpose: a Postgres restore
already brings back everything the JSON would, and re-importing the JSON on top
would delete the users Postgres just restored.

## Updating

The instance directory is a git checkout, so changes to the compose repo arrive
with a pull:

```bash
cd /var/www/docker/keycloak/<domain>
./scripts/keycloak-docker-backup.sh        # first
git pull
docker compose --env-file .env -f docker-compose.external-cert.yml up -d
```

Image versions are whatever the compose repo pins — `latest` for both Keycloak
and Postgres, so a `pull` can also move you across a major version:

- **Keycloak** migrates its schema automatically on start, and that migration is
  not reversible — the pre-upgrade backup is the rollback path.
- **Postgres** will **not** start on a data directory written by a previous
  major version. Dump with the backup script, remove the volume, start fresh,
  restore. Note that the data mount point moved in 18
  (`/var/lib/postgresql/data` → `/var/lib/postgresql`), so a compose file
  pinning an older tag needs the older path with it.

# bump KEYCLOAK_IMAGE_TAG in .env, then:
docker compose --env-file .env -f docker-compose.external-cert.yml pull
docker compose --env-file .env -f docker-compose.external-cert.yml up -d
```

Keycloak migrates its schema automatically on start, and that migration is not
reversible — the pre-upgrade backup is the rollback path.

Postgres is a different story: bumping `POSTGRES_IMAGE_TAG` across a major
version will **not** start on an existing data directory. Dump with the backup
script, change the tag, remove the volume, start fresh, restore.

Crossing 17 → 18 changes the mount point as well — 18+ keeps data in
`/var/lib/postgresql/<major>/docker` and expects the single mount at
`/var/lib/postgresql` — so the `volumes:` line moves with the tag, in either
direction. Installs default to the 18+ pairing the compose repo uses.

## Useful commands

Run from `/var/www/docker/keycloak/<domain>/`:

```bash
DC="docker compose --env-file .env -f docker-compose.external-cert.yml"

$DC up -d          # start
$DC down           # stop
$DC restart        # restart
$DC ps             # status, including health
$DC logs -f keycloak
$DC exec keycloak_postgres psql -U "$POSTGRES_USER" keycloak
```

## Troubleshooting

- **`nginx -t` fails on missing certificates** — the vhost references
  `/etc/letsencrypt/live/<domain>/`. Run certbot first; the install script
  offers this in the right order.
- **Infinite redirect loop, or links pointing at `http://`** — the proxy isn't
  sending `X-Forwarded-Proto: https`, or Keycloak wasn't started with
  `--proxy-headers=xforwarded`. Both are set by default here.
- **`502 upstream sent too big header`** — the proxy buffer settings above are
  missing from the vhost.
- **`HTTPS required` on the admin console** — you reached Keycloak directly on
  its port instead of through Nginx. It only listens on `127.0.0.1`, so this
  usually means an SSH tunnel or a stale port mapping.
- **Container shows `unhealthy` but Keycloak works** — the healthcheck probes
  `/health/ready` on the management port via bash's `/dev/tcp`. Nothing depends
  on it; drop the `healthcheck:` block if a future image changes that endpoint.
- **Postgres dies at boot with `Error: in 18+, these Docker images are
  configured to store database data in a format which is compatible with
  "pg_ctlcluster"`, and Compose reports `dependency failed to start: container
  ... is unhealthy`** — the volume is mounted at `/var/lib/postgresql/data`
  while the image is PostgreSQL 18 or newer (`postgres:latest` is 18). The tag
  and the mount have drifted apart — either the instance predates the current
  compose file, or `POSTGRES_IMAGE_TAG` was pinned without moving the mount.
  Bring the pair back into agreement and recreate the volume (nothing was ever
  initialised in it, so there is no data to lose):

  ```bash
  cd /var/www/docker/keycloak/<domain>
  DC="docker compose --env-file .env -f docker-compose.external-cert.yml"
  $DC down
  docker volume rm <project>_postgres_data     # docker volume ls to confirm the name
  # then make the pair agree — either 18+ (what the compose repo uses):
  #   POSTGRES_IMAGE_TAG=latest  +  - postgres_data:/var/lib/postgresql
  # or pinned below 18:
  #   POSTGRES_IMAGE_TAG=17      +  - postgres_data:/var/lib/postgresql/data
  $DC up -d
  ```
- **Backup skips realm JSON** — the admin token request failed. Check that
  `https://<domain>` resolves from the host itself and that
  `KEYCLOAK_USER`/`KEYCLOAK_PASSWORD` in `.env` still match the current admin.

## Manual install (reference)

The same thing by hand — the installer automates exactly this, and writes `.env`
for you:

```bash
read -p "Enter domain name: " domain && \
mkdir -p /var/www/docker/keycloak && cd /var/www/docker/keycloak && \
git clone https://github.com/nahicyan/keycloak-production-docker-compose "$domain" && \
cd "$domain" && cp .env.example .env && vim .env && \
sudo certbot certonly --nginx -d "$domain" && \
vim /etc/nginx/sites-available/"$domain" && \
sudo ln -s /etc/nginx/sites-available/"$domain" /etc/nginx/sites-enabled/ && \
sudo systemctl reload nginx && \
docker compose -f docker-compose.external-cert.yml up -d
```

Set `KEYCLOAK_PORT` in `.env` if you want anything other than `8090`, and
`COMPOSE_PROJECT_NAME` if you run more than one instance on the host.

## References

- [Keycloak: running in a container](https://www.keycloak.org/server/containers)
- [Keycloak: reverse proxy configuration](https://www.keycloak.org/server/reverseproxy)
- [Keycloak: hostname configuration](https://www.keycloak.org/server/hostname)
- [`keycloak-production-docker-compose/`](keycloak-production-docker-compose/) —
  vendored upstream compose repo (`README.md`, `Theme.md`, the four compose
  variants including the `:8443` self-signed and `start-dev` ones)

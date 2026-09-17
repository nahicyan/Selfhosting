# Outline

[Outline](https://www.getoutline.com/) is a fast, collaborative wiki / knowledge
base for teams, with real-time collaborative editing (Y.js). This runs the
official Docker image via Docker Compose, behind a host Nginx reverse proxy
that terminates TLS — the same pattern used by every other app in this repo.

## Layout

```
Outline/
├── README.md
├── docker-compose.yml       # outline + postgres + redis (outline/temp/docker.txt, adapted)
├── outline-nginx.conf       # Reverse proxy template (placeholders: outline.example.com, 127.0.0.1:3000)
├── outline/                 # Vendored upstream source (reference only — not run directly)
├── temp/                    # Plain-text copies of the official self-hosting docs used to build this
└── scripts/
    └── outline-docker-install.sh   # Writes .env, starts the stack, wires up Nginx/certbot
```

Each installed instance lives at `/var/www/docker/outline/<domain>/` by
default:

| Path                 | Contents                                                      |
|----------------------|-----------------------------------------------------------------|
| `docker-compose.yml` | Copy of the compose file above                                  |
| `.env`               | **Written by the installer** (mode `600`) — all app config      |

Attachments and the database live in **named Docker volumes**
(`storage-data`, `database-data`), not bind mounts, so there's no host
UID/GID to reconcile — unlike code-server or Keycloak's themes.

## Prerequisites

- Docker + the Docker Compose plugin
- `curl`, `openssl`, `sed`
- Nginx and certbot on the host
- A public DNS record pointing at the host
- A **custom SMTP mail server** you can send from. Sign-in in this setup is
  email "magic link" only (no Slack/Google/Microsoft/OIDC), so SMTP is not
  optional — see [Auth method](#auth-method-email-magic-link-only) below.

## Install

```bash
./scripts/outline-docker-install.sh
```

You'll be asked for, in order:

1. **Domain** — e.g. `outline.example.com`
2. **Install directory** — defaults to `/var/www/docker/outline/<domain>`,
   or type another absolute path
3. **Host port** — `127.0.0.1:<port>` that Nginx will proxy to (default
   `3000`). Warns if something is already listening on it.
4. **SMTP** — host, port (default `465`), username, password (input hidden;
   blank is allowed if the server doesn't require auth), from address, an
   optional reply-to address, and whether to connect with TLS (defaults to
   on for port `465`, off — i.e. opportunistic STARTTLS — for `587`/`25`,
   matching how Outline's mailer actually uses `SMTP_SECURE`)

Everything else — `SECRET_KEY`, `UTILS_SECRET`, the Postgres password — is
generated for you; there's no bootstrap admin credential to set, because
Outline has none (see below).

After confirming the summary, the script pulls the images, starts the stack,
polls `/_health` until Outline is actually ready (not just "the process
started" — see below), then optionally requests a Let's Encrypt certificate
and installs `outline-nginx.conf`.

### What the script does

1. Validates the domain, port and SMTP inputs, and refuses to install into a
   non-empty directory
2. Copies `docker-compose.yml` into the install directory
3. Writes `.env` (mode `600`) with every value Outline needs, including two
   things that are easy to get wrong by hand (see [Gotchas](#gotchas) below):
   `PGSSLMODE=disable`, and `$` in any SMTP field escaped to `$$`
4. Runs `docker compose config` against it as a pre-flight check
5. Optionally opens `.env` or `docker-compose.yml` in `$EDITOR`
6. Pulls images and starts `outline`, `postgres`, `redis`
7. Polls `http://127.0.0.1:<port>/_health` until it returns `200` — this
   endpoint checks both the Postgres and Redis connections
   (`server/main.ts`), so a green result means the whole stack is actually
   working, not just that the container is running
8. Optionally requests a Let's Encrypt certificate (`certbot certonly
   --nginx`) and installs `outline-nginx.conf` into
   `/etc/nginx/sites-available/<domain>` with the domain and port
   substituted, symlinks it, runs `nginx -t`, and reloads

## Auth method: email magic-link only

Outline requires at least one sign-in method. Rather than wiring up an
external identity provider, this setup uses Outline's built-in **email
magic-link** authentication: a user enters their address, gets a one-time
sign-in link by email, and clicking it signs them in — no password is ever
stored. It's enabled automatically once SMTP is configured
(`outline/temp/magic-link.txt`). No `SLACK_CLIENT_ID`, `GOOGLE_CLIENT_ID`,
`OIDC_CLIENT_ID`, etc. are set.

**The first person to sign in creates the workspace and becomes its admin.**
There's no separate bootstrap admin account or password to configure —
that's why the installer doesn't ask for one.

If you later want OIDC/Slack/Google/Azure sign-in as well, add the relevant
variables from `outline/outline/.env.sample` (or `outline/temp/OIDC.txt`) to
`.env` and restart; magic-link keeps working alongside them.

## File storage: local disk only

`FILE_STORAGE=local` (`outline/temp/file-system.txt`) — attachments and
images are written to `/var/lib/outline/data` inside the container, which is
the `storage-data` named volume. No S3-compatible bucket is configured.
`FILE_STORAGE_UPLOAD_MAX_SIZE` is `262144000` (250MB); `outline-nginx.conf`'s
`client_max_body_size 300m` is set with headroom above it — raise both
together if you increase the limit.

## Gotchas

These are the two non-obvious things the installer handles for you. If you
ever hand-edit `.env` or build a stack outside the installer, keep them in
mind:

- **`PGSSLMODE=disable` is required.** In production mode, Outline always
  attempts an SSL connection to Postgres unless this is set
  (`server/storage/database.ts`). A stock `postgres:18` image has no
  certificate configured and will refuse the SSL handshake, and the outline
  container fails to start with `Logger.fatal("The database does not
  support SSL connections...")`. This is safe here because Outline and
  Postgres only ever talk over the private Docker Compose network on the
  same host — never the public internet.
- **A literal `$` in an SMTP field must be written as `$$` in `.env`.**
  Docker Compose interpolates `.env` itself — a lone `$` starts what it
  thinks is a variable reference (`docker compose config` prints a
  `variable "X" is not set` warning and silently truncates the value at that
  point). The installer escapes every SMTP field automatically; if you
  hand-edit a password containing `$`, double it.

## `.env` reference

```ini
COMPOSE_PROJECT_NAME=outline-outline-example-com
URL=https://outline.example.com
PORT=3000                          # container's internal port — always 3000
OUTLINE_PORT=3000                  # host port, published on 127.0.0.1 only
SECRET_KEY=...                     # generated
UTILS_SECRET=...                   # generated
FORCE_HTTPS=true

DATABASE_URL=postgres://outline:...@postgres:5432/outline
PGSSLMODE=disable                  # see Gotchas
POSTGRES_USER=outline
POSTGRES_PASSWORD=...              # generated
POSTGRES_DB=outline

REDIS_URL=redis://redis:6379

FILE_STORAGE=local
FILE_STORAGE_LOCAL_ROOT_DIR=/var/lib/outline/data
FILE_STORAGE_UPLOAD_MAX_SIZE=262144000

SMTP_HOST=mail.example.com
SMTP_PORT=465
SMTP_USERNAME=...
SMTP_PASSWORD=...
SMTP_FROM_EMAIL=Outline <noreply@example.com>
SMTP_REPLY_EMAIL=
SMTP_SECURE=true
```

Every key here is Outline's own variable name (`outline/outline/.env.sample`)
— the `outline` service reads `.env` via `env_file:`, so anything you add
that Outline supports (an OIDC provider, `SENTRY_DSN`, integrations, ...)
just needs adding to `.env` and a restart, no compose edits required.

## Where the images come from

`docker.getoutline.com/outlinewiki/outline:latest` — the official image from
Outline's own self-hosting docs (`outline/temp/docker.txt`). `postgres:18`
and `redis:7-alpine` are pinned rather than tracking `latest`, per that same
doc's own recommendation. To pin the Outline image itself, uncomment
`OUTLINE_VERSION=` in `.env` (e.g. `OUTLINE_VERSION=1.2.0`) and re-run
`docker compose up -d`.

## Nginx reverse proxy

`outline-nginx.conf` terminates TLS, redirects `80` → `443`, and proxies to
`127.0.0.1:<port>` with WebSocket upgrade headers — required for the Y.js
real-time collaboration engine, not optional. `X-Frame-Options` is
deliberately not set: Outline sends its own via `helmet()` and overrides it
per-route for embeds (`server/routes/embeds.ts`), so a blanket header here
would fight the app's own framing policy.

## Updating

```bash
cd /var/www/docker/outline/<domain>
docker compose pull
docker compose up -d
```

Database migrations run automatically on container start
(`outline/temp/docker.txt`). Back up first — see below.

## Backup

There's no dedicated backup script for Outline yet. Everything stateful is
in two named volumes plus `.env`:

```bash
docker run --rm -v outline-<domain-with-dashes>_database-data:/data -v "$PWD":/backup alpine \
  tar czf /backup/outline-postgres-$(date +%F).tar.gz -C /data .
docker run --rm -v outline-<domain-with-dashes>_storage-data:/data -v "$PWD":/backup alpine \
  tar czf /backup/outline-storage-$(date +%F).tar.gz -C /data .
cp /var/www/docker/outline/<domain>/.env outline-env-$(date +%F).backup
```

(A proper `pg_dump`-based backup, like the other apps in this repo have,
would be a cleaner follow-up than tarring the raw volume.)

## Useful commands

Run from `/var/www/docker/outline/<domain>/`:

```bash
docker compose up -d          # start
docker compose down           # stop
docker compose restart        # restart
docker compose ps             # status, including health
docker compose logs -f outline
docker compose exec postgres psql -U outline outline
```

## Troubleshooting

- **`outline` container exits immediately, log mentions "does not support
  SSL connections"** — `PGSSLMODE=disable` is missing from `.env`. See
  [Gotchas](#gotchas).
- **`docker compose config` warns `variable "X" is not set` and an SMTP
  field looks truncated** — an unescaped `$` in that field. See
  [Gotchas](#gotchas).
- **Magic-link emails never arrive** — check `docker compose logs -f
  outline` for the SMTP connect error, confirm `SMTP_SECURE` matches what
  the server expects on that port (`true` for implicit TLS on 465, `false`
  for STARTTLS on 587/25), and that the mail server allows the host's
  outbound IP to send as `SMTP_FROM_EMAIL`'s domain (SPF/DKIM).
- **`nginx -t` fails on missing certificates** — the vhost references
  `/etc/letsencrypt/live/<domain>/`. Run certbot first; the install script
  offers this in the right order.
- **Real-time editing doesn't sync between two open tabs / collaboration
  feels laggy** — check that WebSocket upgrade headers are reaching Outline;
  something between the browser and Nginx (a CDN, another proxy) is likely
  stripping `Upgrade`/`Connection`.

## References

Local copies of the official self-hosting docs this setup was built from:

- [`temp/docker.txt`](temp/docker.txt) — Docker Compose
- [`temp/nginx.txt`](temp/nginx.txt) — Nginx
- [Outline: SMTP](https://docs.getoutline.com/s/hosting/doc/smtp-cqCJyZGMIB) — also [`temp/SMTP.txt`](temp/SMTP.txt)
- [Outline: File storage](https://docs.getoutline.com/s/hosting/doc/file-storage-N4M0T6Ypu7) — also [`temp/file-system.txt`](temp/file-system.txt)
- [`temp/magic-link.txt`](temp/magic-link.txt) — Email magic link
- [`outline/`](outline/) — vendored upstream source (reference only)

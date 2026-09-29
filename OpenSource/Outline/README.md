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
- Either a **custom SMTP mail server** (email magic-link sign-in), or
  **Keycloak** on this host (`../Keycloak`, which the installer can set up for
  you) — see [Sign-in methods](#sign-in-methods) below
- `jq` (Keycloak sign-in only)

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
4. **Sign-in method** — `1` email magic link, or `2` Keycloak (OIDC)
5. **Keycloak** (option 2 only):
   - pick an existing instance found under `/var/www/docker/keycloak/`, or
     **install a new one**, which runs `../Keycloak/scripts/keycloak-docker-install.sh`
     right there (answer its prompts, accept its certbot + Nginx steps), then
     carries on with that instance
   - the admin API login uses `KEYCLOAK_USER`/`KEYCLOAK_PASSWORD` from that
     instance's `.env`. If those no longer work (the bootstrap admin was
     changed), you're asked for admin credentials instead
   - realm name (default `outline`; an existing realm can be reused as-is),
     client ID (default `outline`; an existing one can be overwritten), and
     the sign-in button label (default `Keycloak`)
   - optionally a **first user** (username, email, first/last name,
     password). Blank password = generated + temporary
6. **SMTP** — required for magic link, optional for Keycloak: host, port
   (default `465`), username, password (input hidden; blank is allowed if the
   server doesn't require auth), from address, an optional reply-to address,
   and whether to connect with TLS (defaults to on for port `465`, off — i.e.
   opportunistic STARTTLS — for `587`/`25`, matching how Outline's mailer
   actually uses `SMTP_SECURE`)

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
   - Keycloak only: creates the realm, the client and the first user through
     the admin REST API (see [Keycloak](#keycloak-oidc)) **before** anything
     is written for Outline, because the client secret goes into `.env`
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
   - Keycloak only: checks that the `outline` container itself can fetch
     Keycloak's `/.well-known/openid-configuration`, and offers a fix if it
     can't (see [Troubleshooting](#troubleshooting))
8. Optionally requests a Let's Encrypt certificate (`certbot certonly
   --nginx`) and installs `outline-nginx.conf` into
   `/etc/nginx/sites-available/<domain>` with the domain and port
   substituted, symlinks it, runs `nginx -t`, and reloads

## Sign-in methods

Outline requires at least one sign-in method, and has **no bootstrap admin
account**: **the first person to sign in creates the workspace and becomes
its admin.** That's why the installer never asks for an Outline admin
password.

### Email magic link

A user enters their address, gets a one-time sign-in link by email, and
clicking it signs them in. No password is ever stored. It's enabled
automatically once SMTP is configured (`temp/magic-link.txt`).

### Keycloak (OIDC)

Uses Outline's generic OIDC plugin (`outline/plugins/oidc`, `temp/OIDC.txt`)
against a Keycloak instance from `../Keycloak` on this host. The installer
logs in to the Keycloak admin API (on `127.0.0.1:<KEYCLOAK_PORT>` first,
falling back to `https://<keycloak-domain>`) and sets up:

| Object | Settings |
|--------|----------|
| **Realm** (new only) | enabled, self-registration **off**, login with email on, brute-force protection on. If SMTP was given: that server as the realm's mail server, plus "forgot password". An existing realm you choose to reuse is **not modified**. |
| **Client** | confidential (`client-secret`, secret generated by the installer), standard flow only (no implicit or direct grants). Redirect URI `https://<outline>/auth/oidc.callback`, web origin `https://<outline>`, post-logout redirect URIs `https://<outline>` and `https://<outline>/*` |
| **User** (optional) | `enabled`, `emailVerified: true`, the password you entered, or a generated one marked temporary |

Outline gets these keys in `.env`:

```ini
OIDC_CLIENT_ID=outline
OIDC_CLIENT_SECRET=...
OIDC_AUTH_URI=https://auth.example.com/realms/outline/protocol/openid-connect/auth
OIDC_TOKEN_URI=https://auth.example.com/realms/outline/protocol/openid-connect/token
OIDC_USERINFO_URI=https://auth.example.com/realms/outline/protocol/openid-connect/userinfo
OIDC_LOGOUT_URI=https://auth.example.com/realms/outline/protocol/openid-connect/logout
OIDC_USERNAME_CLAIM=preferred_username
OIDC_DISPLAY_NAME=Keycloak
OIDC_SCOPES=openid profile email
```

Why this is set up the way it is (from reading `outline/plugins/oidc/server/`):

- **Explicit endpoints, not `OIDC_ISSUER_URL`.** With the issuer set, Outline
  runs discovery at boot, and if Keycloak doesn't answer at that moment it
  calls `Logger.fatal` and the container exits. With explicit endpoints it
  always starts, and Keycloak is contacted only when someone signs in. The
  trade-off: PKCE is only switched on in discovery mode. The confidential
  client secret still protects the code exchange.
- **Post-logout redirect.** Outline's `/auth/oidc.logout` sends
  `id_token_hint`, `client_id` and `post_logout_redirect_uri=<URL>` to
  Keycloak's end-session endpoint. Keycloak rejects that unless the exact URL
  is allowed on the client, so the installer adds it.
- **Email is mandatory.** Outline refuses sign-in without an `email` claim,
  and the workspace domain comes from the first user's email. Users you add
  in Keycloak later need an email address too.
- **Outline calls Keycloak server-side.** The token and userinfo requests
  come from inside the `outline` container and go to
  `https://<keycloak-domain>`, so that name has to resolve and have a valid
  certificate from inside Docker, not only from your browser.

If you also configured SMTP, magic link is available alongside Keycloak. To
allow only Keycloak, turn off **Email** under Settings → Authentication in
Outline.

Add more users in the Keycloak admin console
(`https://<keycloak-domain>/admin/master/console/#/<realm>` → Users).
Self-registration is off by default. Enable it under Realm settings → Login
if you want it.

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
SMTP_SECURE=true                   # SMTP_* only if SMTP was configured

# OIDC_* only with Keycloak sign-in - see above
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

- **Keycloak: "Invalid redirect uri" / "Invalid parameter:
  redirect_uri"** — the client's redirect URI must be exactly
  `https://<outline-domain>/auth/oidc.callback`. If you changed the Outline
  domain, update it in Keycloak (Clients → outline → Settings).
- **Keycloak sign-in loops back with an error in `docker compose logs
  outline` (`ECONNREFUSED`, `ETIMEDOUT`, certificate errors to the Keycloak
  domain)** — the container can't reach `https://<keycloak-domain>`. Usually
  the host can't reach its own public IP (no NAT hairpin). The installer
  offers a `docker-compose.override.yml` for this that maps the Keycloak
  hostname to `host-gateway`, so the request goes straight to host Nginx on
  :443. Check from inside the container with:
  `docker compose exec outline node -e "fetch('https://<keycloak-domain>/realms/<realm>/.well-known/openid-configuration').then(r=>console.log(r.status))"`
- **"An email field was not returned…"** — the Keycloak user has no email.
  Set one (Users → the user → Details).

## References

Local copies of the official self-hosting docs this setup was built from:

- [`temp/docker.txt`](temp/docker.txt) — Docker Compose
- [`temp/nginx.txt`](temp/nginx.txt) — Nginx
- [Outline: SMTP](https://docs.getoutline.com/s/hosting/doc/smtp-cqCJyZGMIB) — also [`temp/SMTP.txt`](temp/SMTP.txt)
- [Outline: File storage](https://docs.getoutline.com/s/hosting/doc/file-storage-N4M0T6Ypu7) — also [`temp/file-system.txt`](temp/file-system.txt)
- [`temp/magic-link.txt`](temp/magic-link.txt) — Email magic link
- [`temp/OIDC.txt`](temp/OIDC.txt) — OIDC / Keycloak
- [`../Keycloak/Keycloak.md`](../Keycloak/Keycloak.md) — the Keycloak stack this integrates with
- [`outline/`](outline/) — vendored upstream source (reference only)

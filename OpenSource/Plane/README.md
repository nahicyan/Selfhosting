# Plane (Community Edition)

[Plane](https://plane.so) is an open-source project management tool (issues, cycles, modules — a self-hosted Jira/Linear alternative). This installs the free, MIT-licensed **Community Edition** via Docker Compose, using the same release artifacts as the official `setup.sh` installer, driven non-interactively.

> The Commercial Edition (`curl -fsSL https://prime.plane.so/install/ | sh -`) requires a license for Pro/Business features and manages itself through `prime-cli`. This setup targets the free Community Edition instead, which fits this repo's self-hosted-OSS pattern.

## Install

```bash
./scripts/plane-docker-install.sh
```

You'll be asked for:

- **Domain** — e.g. `plane.example.com`
- **Port** — the host port Plane's internal proxy listens on (e.g. `8080`). This is the port the Nginx reverse proxy config will be pointed at.

Everything else is handled automatically.

## What the script does

1. Resolves the latest Plane release tag from GitHub and downloads that release's `docker-compose.yml` and `variables.env` — the same two files the official `setup.sh` fetches — into `/var/www/docker/plane/<domain>/` as `docker-compose.yaml` and `plane.env`.
2. Generates fresh random secrets for `SECRET_KEY`, `LIVE_SERVER_SECRET_KEY`, the Postgres password, the RabbitMQ password, and the MinIO access/secret keys. The downloaded `variables.env` ships with well-known defaults (`plane`/`plane`, `access-key`/`secret-key`, `change-this-key-on-deployment`) — these are never used.
3. Writes `DATABASE_URL` and `AMQP_URL` explicitly so they carry the generated Postgres/RabbitMQ passwords. Both default to the vendor's hardcoded `plane:plane` credentials in `variables.env`, which is a real footgun: Compose's `${VAR:-default}` treats a defined-but-empty variable as unset, so `variables.env`'s blank `DATABASE_URL=` line would silently fall back to the *default* password even after `POSTGRES_PASSWORD` is changed, and the API/worker containers would fail to authenticate against Postgres.
4. Sets `APP_DOMAIN`, `WEB_URL`, `CORS_ALLOWED_ORIGINS` to the domain, and `SITE_ADDRESS=:80` — this is the setting from Plane's own [external reverse proxy docs](https://developers.plane.so/self-hosting/govern/reverse-proxy) that stops the bundled proxy container from attempting its own ACME/TLS handling, since Nginx terminates TLS here instead.
5. Patches `docker-compose.yaml` so the bundled `proxy` service's published ports bind to `127.0.0.1` only (it ships bound to `0.0.0.0` via `mode: host`). Nginx is the only intended public entrypoint.
6. Offers to open `plane.env` / `docker-compose.yaml` in `$EDITOR` for review before anything starts.
7. Pulls images and starts the stack with `docker compose ... up -d`, then waits on the `migrator` container and fails loudly if database migrations didn't exit `0`.
8. Optionally requests a Let's Encrypt certificate via `certbot certonly --nginx` and installs `plane-nginx.conf` into `/etc/nginx/sites-available/<domain>`, substituting in your domain and port.

## Architecture note

Plane's compose stack ships its own reverse proxy container (`makeplane/plane-proxy`, Caddy-based) that fronts `web`, `api`, `space`, `admin`, and `live` (the websocket service behind real-time collaboration) behind a single port. That container is kept — it still does the internal routing between Plane's five HTTP services — but it's rebound to loopback so the host's Nginx becomes the actual internet-facing edge, matching every other app in this repo. Don't remove or bypass the `proxy` service; point Nginx at it instead.

## Nginx config

`plane-nginx.conf` proxies to the internal `proxy` container and forwards `Upgrade`/`Connection` headers, which the `live` service needs for websockets. Placeholders `plane.example.com` and `127.0.0.1:8080` are substituted by the install script; edit them by hand if configuring Nginx separately.

## Useful commands

Run from `/var/www/docker/plane/<domain>/`:

```bash
COMPOSE="docker compose -f docker-compose.yaml --env-file=plane.env --project-name plane-<domain-with-dashes>"

$COMPOSE up -d        # start
$COMPOSE down         # stop
$COMPOSE restart      # restart
$COMPOSE logs -f      # tail logs (add a service name to scope it, e.g. `logs -f migrator`)
```

The install script prints the exact `$COMPOSE` invocation (with your project name filled in) at the end of the run.

## Upgrading

Re-download `docker-compose.yaml` and `variables.env` for the new release tag, diff `variables.env` against your existing `plane.env` for any new keys, then `$COMPOSE pull && $COMPOSE up -d`. The official [`setup.sh`](https://github.com/makeplane/plane/releases/latest/download/setup.sh) automates this (`./setup.sh upgrade`) if you'd rather drive it interactively — it's compatible with the files this script lays down, since they're the same artifacts it would have downloaded itself.

## Backup

Plane's stateful data lives in four named volumes: `pgdata` (Postgres), `uploads` (MinIO), `rabbitmq_data`, and `redisdata` (cache only, safe to skip). Back these up with your usual Docker volume backup approach, or use the official [`restore.sh`](https://github.com/makeplane/plane/releases/latest/download/restore.sh) / `restore-airgapped.sh` release assets as a reference for the expected layout.

## Troubleshooting

- [Error during Docker Compose execution](https://developers.plane.so/self-hosting/troubleshoot/installation-errors#error-during-docker-compose-execution)
- [Migrator container exited](https://developers.plane.so/self-hosting/troubleshoot/installation-errors#migrator-container-exited) — the install script already surfaces this by checking the migrator's exit code, but the linked doc covers root causes.

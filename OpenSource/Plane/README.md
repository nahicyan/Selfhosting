# Plane (Community Edition)

[Plane](https://plane.so) is an open-source project management tool (issues, cycles, modules — a self-hosted Jira/Linear alternative). This installs the free, MIT-licensed **Community Edition** via Docker Compose, using the same release artifacts as the official `setup.sh` installer, driven non-interactively.

> The Commercial Edition (`curl -fsSL https://prime.plane.so/install/ | sh -`) requires a license for Pro/Business features and manages itself through `prime-cli`. This setup targets the free Community Edition instead, which fits this repo's self-hosted-OSS pattern.

| Script | Purpose |
| --- | --- |
| `scripts/plane-docker-install.sh` | Installs Plane, then optionally certbot + Nginx |
| `scripts/plane-docker-backup.sh` | Takes a snapshot: database, uploads, configuration |
| `scripts/plane-docker-restore.sh` | Restores a snapshot (everything, or just one part) |

## Install

```bash
./scripts/plane-docker-install.sh
```

You'll be asked for:

- **Domain** — e.g. `plane.example.com`
- **Port** — the host port Plane's internal proxy listens on (e.g. `8080`). This is the port the Nginx reverse proxy config will be pointed at.

Everything else is handled automatically.

### Known issue: the MinIO image (until Plane ships a fix)

MinIO removed its Docker Hub organisation, so `docker pull minio/minio` fails with *requested access to the resource is denied*, and the latest release (v1.4.2, as well as v1.4.1) still names `minio/minio:latest`. The installer will stop at its image pull. Plane fixed this on its `preview` branch on 2026-09-15 (makeplane/plane#9829) by pinning `quay.io/minio/minio:RELEASE.2025-09-07T16-13-09Z`, but no release includes it yet.

Until one does, answer **y** to *"review/edit docker-compose.yaml before starting?"* (it comes before the pull) and change the `plane-minio` image line to that reference:

```yaml
  plane-minio:
    image: quay.io/minio/minio:RELEASE.2025-09-07T16-13-09Z
```

An instance that already has its images is not affected. The same applies to a new server before a restore, since Full recovery needs the instance installed first.

**Already running a server?** It keeps working, but it can no longer pull that image, and MinIO's community edition is unmaintained. [`migration/`](migration/README.md) has the analysis (including what Plane has and hasn't provided), a runbook, and three step scripts that back up, save the working image, and pin the compose file to a source that still exists.

## What the install script does

1. Resolves the latest Plane release tag from GitHub and downloads that release's `docker-compose.yml` and `variables.env` — the same two files the official `setup.sh` fetches — into `/var/www/docker/plane/<domain>/` as `docker-compose.yaml` and `plane.env`.
2. Generates fresh random secrets for `SECRET_KEY`, `LIVE_SERVER_SECRET_KEY`, the Postgres password, the RabbitMQ password, and the MinIO access/secret keys. The downloaded `variables.env` ships with well-known defaults (`plane`/`plane`, `access-key`/`secret-key`, `change-this-key-on-deployment`) — these are never used.
3. Writes `DATABASE_URL` and `AMQP_URL` explicitly so they carry the generated Postgres/RabbitMQ passwords. Both default to the vendor's hardcoded `plane:plane` credentials in `variables.env`, which is a real footgun: Compose's `${VAR:-default}` treats a defined-but-empty variable as unset, so `variables.env`'s blank `DATABASE_URL=` line would silently fall back to the *default* password even after `POSTGRES_PASSWORD` is changed, and the API/worker containers would fail to authenticate against Postgres.
4. Sets `APP_DOMAIN`, `WEB_URL`, `CORS_ALLOWED_ORIGINS` to the domain, and `SITE_ADDRESS=:80` — this is the setting from Plane's own [external reverse proxy docs](https://developers.plane.so/self-hosting/govern/reverse-proxy) that stops the bundled proxy container from attempting its own ACME/TLS handling, since Nginx terminates TLS here instead.
5. Patches `docker-compose.yaml` so the bundled `proxy` service's published ports bind to `127.0.0.1` only (it ships bound to `0.0.0.0` via `mode: host`). Nginx is the only intended public entrypoint.
6. Offers to open `plane.env` / `docker-compose.yaml` in `$EDITOR` for review before anything starts.
7. Pulls images and starts the stack with `docker compose ... up -d`, then waits on the `migrator` container and fails loudly if database migrations didn't exit `0`.
8. Optionally requests a Let's Encrypt certificate via `certbot certonly --nginx` and installs `plane-nginx.conf` into `/etc/nginx/sites-available/<domain>`, substituting in your domain and port.

Each domain is its own Compose project (`plane-<domain-with-dashes>`), so several instances can share a host.

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

Take a [backup](#backup) first. Then download the new release's `docker-compose.yml` (`https://github.com/makeplane/plane/releases/download/<tag>/docker-compose.yml`) over `docker-compose.yaml` and re-apply what the installer did to it (the loopback `host_ip` lines, and the MinIO image above while the bug lasts). Keep your `plane.env`, set `APP_RELEASE=<tag>` in it, and add any keys that are new in that release's `variables.env`. Then `$COMPOSE pull && $COMPOSE up -d`. The migrator brings the database schema forward on start.

Plane's official `setup.sh upgrade` does **not** apply here: it manages a `plane-app/` folder that this install does not have.

## Backup

```bash
./scripts/plane-docker-backup.sh
```

Like the other apps here it asks where to save (default `/home/backup`) and which instance, then writes one snapshot:

```
/home/backup/plane/<domain>/<date-time>/
  postgres/plane.sql.gz          pg_dump of the Plane database
  uploads/uploads.tar.gz         the MinIO data volume (attachments, images)
  config/plane.env               secrets: SECRET_KEY and the generated passwords
  config/docker-compose.yaml     reference copy
  manifest.txt                   release, PostgreSQL version, schema level, notes
```

It follows Plane's own [backup guidance](https://developers.plane.so/self-hosting/manage/backup-restore) for setups that aren't the official volume backup: the PostgreSQL database, the object storage, and the configuration. The database is dumped with `pg_dump` inside the `plane-db` container, so it is a consistent snapshot and Plane keeps running; Plane's own `./setup.sh backup` instead copies the live data directory (crash-consistent only). The last 7 snapshots per domain are kept.

Not included, on purpose: Redis (only Django's cache), RabbitMQ (only the job queue; each new container starts a fresh node), the log volumes, and Nginx/TLS (the installer regenerates the vhost and certbot re-issues the certificate). With `USE_MINIO=0` (external S3) there is no uploads volume: back that up with your S3 provider's tools.

**Keep `config/plane.env` with the rest of the snapshot.** Plane encrypts settings saved in its database (SMTP, OAuth secrets) with a key derived from `SECRET_KEY`. A database restored under a different `SECRET_KEY` reads those settings as empty: nothing fails visibly, Plane only logs an error. The snapshot is secret material: it is created mode 700/600.

The database and uploads are read while Plane runs, so a file uploaded during the backup may be in one but not the other. Copy `/home/backup/plane/` off the server.

Snapshots are not interchangeable with Plane's official `./setup.sh backup` / `restore.sh`: this install has no `setup.sh`, and its Compose project is `plane-<domain>`, not `plane-app`.

## Restore

```bash
./scripts/plane-docker-restore.sh
```

Pick a snapshot, the instance to restore into, and what to restore:

| Option | Does |
| --- | --- |
| **1) Full recovery** | `plane.env`, then the database, then uploads. For a new server or rolling everything back. |
| **2) Database only** | Replaces the database; keeps the current `plane.env`. |
| **3) Uploads only** | Replaces the MinIO data. |
| **4) Configuration only** | Restores `plane.env`. |

It checks the dump and archive **before** stopping anything, takes a safety copy of what it is about to replace (`<install-dir>/pre-restore-<time>/`: `plane.env`, a database dump, the uploads), and needs you to type `restore`. If a step fails part-way it says where the safety copies are, and the snapshot itself is never modified, so you can fix the cause and run it again.

**New server:** run `plane-docker-install.sh` with the **same domain** (mind the [MinIO note](#known-issue-the-minio-image-until-plane-ships-a-fix)), then choose **Full recovery**. The installer generated new random passwords, and PostgreSQL only reads its password when its volume is first created, so Full recovery restores the snapshot's `plane.env` and re-creates the database volume so the old password applies. It refuses to restore the configuration of a different domain.

`docker-compose.yaml` is deliberately not restored. It is a per-release file plus the installer's loopback patch, all the state is in `plane.env`, and an old copy could bring back references that no longer work (such as the retired `minio/minio` image). If yours differs from the snapshot's, the restore says so, and the old copy stays in the snapshot.

If the snapshot is from a newer Plane release than the running one, the restore warns: use Full recovery (which takes the snapshot's `APP_RELEASE` with it) or upgrade first. From an older release, the migrator brings the schema forward on start.

## Troubleshooting

- [Error during Docker Compose execution](https://developers.plane.so/self-hosting/troubleshoot/installation-errors#error-during-docker-compose-execution)
- [Migrator container exited](https://developers.plane.so/self-hosting/troubleshoot/installation-errors#migrator-container-exited) — the install script already surfaces this by checking the migrator's exit code, but the linked doc covers root causes.

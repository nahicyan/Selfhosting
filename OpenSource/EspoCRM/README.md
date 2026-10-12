# EspoCRM (Docker Compose)

Self-hosted [EspoCRM](https://www.espocrm.com/) using the official
`espocrm/espocrm` image (Apache variant) and the Docker Compose setup EspoCRM
documents for production, behind a host Nginx reverse proxy. Nginx terminates
TLS on 80/443. The app and its WebSocket server listen on `127.0.0.1` only.

The compose file follows the **EspoCRM 10** layout from the
[Docker docs](https://docs.espocrm.com/administration/docker/installation/#docker-compose):
`data`, `custom` and `client/custom` are mounted separately. The example in the
[espocrm-docker README](https://github.com/espocrm/espocrm-docker) still mounts
all of `/var/www/html`. The v10 entrypoint flags that layout as
*"LEGACY INSTALLATION METHOD DETECTED … No further EspoCRM upgrades will be
available"*, so it is not used here.

## Layout

```
EspoCRM/
├── README.md
├── docker-compose.yml             # The docs' production compose, adapted (see below) — copied into each instance
├── espocrm-nginx.conf             # Reverse proxy template (placeholders: crm.example.com, 127.0.0.1:8100, 127.0.0.1:8101)
├── espocrm-docker/                # Upstream image repo, for reference only (git-ignored)
└── scripts/
    ├── espocrm-docker-install.sh  # Writes .env, starts the stack, watches the first-run install, wires up Nginx/certbot
    ├── espocrm-docker-backup.sh   # Database dump + data/custom files + .env, timestamped; unattended mode for cron
    └── espocrm-docker-restore.sh  # Restores a snapshot into the same or a fresh instance, with a safety snapshot first
```

The installed instance lives at `/var/www/docker/espocrm/<domain>/` by default:

| Path                 | Contents                                                              |
|----------------------|-----------------------------------------------------------------------|
| `docker-compose.yml` | Copied from this repo                                                 |
| `.env`               | **Written by the installer** (mode `600`): ports, versions, passwords |

State is in four named volumes, prefixed with the Compose project
`espocrm-<domain-with-dashes>`:

| Volume                    | Mounted at                    | Holds                                              |
|---------------------------|-------------------------------|----------------------------------------------------|
| `…_espocrm-db`            | `/var/lib/mysql`              | MariaDB                                            |
| `…_espocrm-data`          | `/var/www/html/data`          | `config.php`, `config-internal.php` (DB password), uploads, logs |
| `…_espocrm-custom`        | `/var/www/html/custom`        | Entity Manager / Layout Manager customizations, extensions |
| `…_espocrm-custom-client` | `/var/www/html/client/custom` | Front-end customizations                           |

Four containers (Compose service names are the same as in the EspoCRM docs, so
every `docker compose …` command there works unchanged):

| Service             | Role                                                                         |
|---------------------|------------------------------------------------------------------------------|
| `espocrm`           | Apache + PHP. Its first start **installs** EspoCRM, and later starts run migrations |
| `espocrm-db`        | MariaDB                                                                      |
| `espocrm-daemon`    | Scheduled jobs (email fetching, reminders, cleanup). It replaces the host crontab |
| `espocrm-websocket` | Real-time notifications and record/stream updates, proxied at `/wss`        |

Several instances can share one host. There are no fixed container names, and
each domain is its own Compose project with its own ports.

## Prerequisites

- Docker and the Docker Compose plugin. Your user must be in the `docker` group
  and able to use `sudo`.
- Nginx and certbot on the host
- A DNS record for the domain. EspoCRM builds every link it sends (emails,
  notifications, portals) from it.
- Two free loopback ports: the web app (default `8100`) and the WebSocket
  server (default port + 1)

## Install

```bash
./scripts/espocrm-docker-install.sh
```

Prompts, in order:

1. **Domain** (e.g. `crm.example.com`)
2. **Install directory** (default `/var/www/docker/espocrm/<domain>`)
3. **Host port** (default `8100`) and **WebSocket host port** (default port + 1)
4. **EspoCRM version.** Defaults to the newest `X.Y.Z` tag on Docker Hub. Pin an
   exact version for production. `10` or `10.0` also work if you want
   `docker compose pull` to bring in patch releases. fpm tags are refused
   because they need a separate web server.
5. **Time zone.** Defaults to the host's zone.
6. **Admin password.** Leave it blank to generate one. The username is always
   `admin` (see below).

Both database passwords (the `espocrm` user and MariaDB `root`) are generated.

### What the script does

1. Refuses anything that would make a broken install: a non-empty install
   directory, existing containers for the project, or **leftover volumes**
   from an earlier install with the same domain. An old database volume keeps
   its old passwords, and a fresh `.env` could not log in to it.
2. Copies `docker-compose.yml` and writes `.env`, then validates them with
   `docker compose config`. Every required variable uses `${VAR:?}`, so a
   missing one stops Compose with a clear error instead of being left blank.
3. Pulls the images, then starts **only MariaDB and EspoCRM**. It waits until
   Apache answers on the published port. The entrypoint starts Apache only
   after the install finishes, so that is the real "done" signal. If the
   install crash-loops, it stops and prints the log rather than waiting
   forever. A plain `docker compose up -d` would wait forever, because the
   daemon and websocket containers depend on the app being healthy.
4. Starts the daemon and the WebSocket server. Checks that the web port
   answers, the WebSocket port listens and the daemon runs. Confirms both
   ports are published on `127.0.0.1` only, because Docker-published ports
   bypass ufw.
5. Optionally gets a Let's Encrypt certificate and installs the Nginx vhost.
   If one already exists for the domain, it asks before overwriting.

After the install:

- **Administration → Outbound Emails**: set up SMTP. Until then EspoCRM cannot
  send notifications or password-reset emails.
- **Administration → Settings**: date and time format, currency, language.
- Change the admin password in the UI if you want it out of `.env`. The value
  in `.env` is only used on the first start.

### Why the admin username is fixed

The v10 entrypoint (`docker-entrypoint.sh`, `actionInstall`) runs:

```bash
bin/command create-admin-user "$ESPOCRM_ADMIN_USERNAME"
printf '%s\n' "$ESPOCRM_ADMIN_PASSWORD" | bin/command set-password admin
```

`set-password` names `admin` literally. With any other username it exits 1
(`User 'admin' not found`), which aborts the entrypoint (`set -euo pipefail`)
before `isInstalled` is set. Every restart then fails again at
`create-admin-user` ("already exists"). The compose file therefore pins
`ESPOCRM_ADMIN_USERNAME: admin`. You can rename the user in the UI afterwards.

## Changes from the documented compose file

| Change | Why |
|---|---|
| No `container_name` | Per-domain Compose project: names, volumes and network never collide between instances |
| Ports on `127.0.0.1` | Nginx is the only public entry point |
| Images pinned from `.env` (`ESPOCRM_VERSION`, `MARIADB_VERSION=12.3`) | EspoCRM migrates the database on every start. With `:latest`, any pull becomes an upgrade nobody chose. 12.3 is MariaDB's current LTS (`mariadb:lts`) |
| `MARIADB_AUTO_UPGRADE=1` | Runs `mariadb-upgrade` after a MariaDB image bump |
| `--max-allowed-packet=64MB` | From EspoCRM's official installer (`espocrm-installer`) |
| `ESPOCRM_CONFIG_SITE_URL` | Re-applies `siteUrl` on every start, so changing `ESPOCRM_DOMAIN` takes effect (`ESPOCRM_SITE_URL` is install-only). The official installer does the same |
| `ESPOCRM_CONFIG_WEB_SOCKET_URL=wss://<domain>/wss` | The URL the client uses by default for an https site, made explicit |
| `ESPOCRM_CONFIG_IP_ADDRESS_SERVER_PARAM=HTTP_X_REAL_IP` | Behind a proxy, `REMOTE_ADDR` is always the Docker gateway. EspoCRM's failed-login limit counts per IP, so 10 bad logins from anyone would lock out **everyone**. The header comes from Nginx and can't be spoofed from outside, because the port is loopback-only |
| App healthcheck also requires Apache to answer | `app-check` alone passes a few seconds into the first start, while the install is still running, because Docker 25+ probes every 5s during `start_period`. The daemon and websocket then start mid-install and race it writing `data/config.php`. This was observed in testing. Apache only starts after install or migrations finish, so with this check "healthy" means ready, on upgrades too |
| `start_period: 5m` on the app healthcheck | A first install or an upgrade migration can take minutes on a small VPS. Failures in `start_period` don't count, so a fast host is unaffected |
| `ESPOCRM_TIME_ZONE` | Install-time setting, prompted for |
| Log rotation (`json-file`, 10 MB × 5) | Docker's default never rotates, and Apache logs every request to stdout. Remove the `x-logging` block if `/etc/docker/daemon.json` already rotates |

## `.env` reference

| Key | Used | Notes |
|---|---|---|
| `COMPOSE_PROJECT_NAME` | always | `espocrm-<domain-with-dashes>`, the prefix of every container and volume |
| `ESPOCRM_DOMAIN` | every start | Site URL `https://<domain>` and WebSocket URL `wss://<domain>/wss`. If you change it, update the Nginx vhost and the certificate too |
| `ESPOCRM_PORT`, `ESPOCRM_WS_PORT` | every start | Loopback ports. Must match `proxy_pass` in the vhost |
| `ESPOCRM_VERSION`, `MARIADB_VERSION` | every start | Image tags (see [Upgrading](#upgrading)) |
| `ESPOCRM_TIME_ZONE` | first start only | Afterwards: Administration → Settings |
| `ESPOCRM_ADMIN_PASSWORD` | first start only | Afterwards the password lives in the database |
| `ESPOCRM_DATABASE_PASSWORD` | first start (DB + EspoCRM) | Also written to `data/config-internal.php`. To change it, change it in MariaDB, in that file, and here |
| `MARIADB_ROOT_PASSWORD` | first start (DB) | The backup and restore scripts log in as root with it, read from the database container's environment. Changing it here later does not change MariaDB |

Config options can be pinned the same way as the ones above: add
`ESPOCRM_CONFIG_<SNAKE_CASE_NAME>` to the `espocrm` service (e.g.
`exportDisabled` → `ESPOCRM_CONFIG_EXPORT_DISABLED: "true"`). It is applied on
every start and overrides the UI. See
[Config Environments](https://docs.espocrm.com/administration/docker/installation/#config-environments).

## Nginx reverse proxy

`espocrm-nginx.conf` has two upstreams:

- `location /wss` → `127.0.0.1:<ws-port>`. WebSocket upgrade headers, and
  `proxy_read_timeout 12h` because Nginx would otherwise drop idle sockets
  after 60s (EspoCRM's documented value).
- `location /` → `127.0.0.1:<port>`. Sets `X-Real-IP` (see above) and
  `client_max_body_size 50M`, which matches the image's PHP upload limit.
  Without it, Nginx's 1 MB default rejects most attachments.

It also hides EspoCRM's own HSTS and `nosniff` headers, which it sends on HTML
pages only, and sets them itself on every response, so nothing is duplicated.
There is deliberately no `X-Frame-Options`. EspoCRM sends a configurable CSP
`frame-ancestors`, which you need for embedding web-to-lead forms and portals.

The vhost uses no `map` block, so it can't collide with other vhosts on the
host.

To check the WebSocket after setup, open the site, press F12, and look for
WebSocket errors in the console. With no errors, notifications arrive without
a page reload.

## Upgrading

```bash
./scripts/espocrm-docker-backup.sh           # 1. back up first
cd /var/www/docker/espocrm/<domain>
# 2. set ESPOCRM_VERSION in .env to the new version, then:
docker compose pull && docker compose up -d
docker compose logs -f espocrm      # watch the "migrate" action finish
```

If the migration fails with *"customizations may be incompatible with the new
version"* (usually an extension), set `ESPOCRM_VERSION` back to the previous
version and `docker compose up -d`. If the old version won't start on the
partly migrated data, restore the pre-upgrade backup. Then update the
extension. See
[Incompatible customizations](https://docs.espocrm.com/administration/docker/installation/#incompatible-customizations).

MariaDB: stay on an LTS line. `MARIADB_AUTO_UPGRADE` upgrades the data files
when the image is newer, but take a backup before changing `MARIADB_VERSION`.

## Backup

```bash
./scripts/espocrm-docker-backup.sh
```

Writes `<backup-root>/espocrm/<domain>/<timestamp>/` (default root `/home/backup`):

```
database/espocrm.sql.gz     mariadb-dump of the espocrm database
files/files.tar.gz          data, custom, client/custom (without data/cache, data/tmp)
config/.env                 mode 600 - reference copy, never restored automatically
config/docker-compose.yml   reference copy
manifest.txt                domain, EspoCRM version, images, type
```

- **Online.** The dump uses `--single-transaction`, so EspoCRM stays up. The
  files are archived *after* the dump: a file uploaded in between becomes an
  orphan in the archive, never a database row pointing at a missing file.
- **Verified.** The dump must pass `gzip -t` and end with mariadb-dump's
  `-- Dump completed` trailer, and the archive must contain `config.php` and
  `config-internal.php`. Otherwise the half-written snapshot is deleted and
  the script exits non-zero.
- **Works on a broken app.** Files are read through a throwaway container
  that mounts the app's volumes read-only, so only `espocrm-db` needs to be
  running.
- **No passwords in `ps`.** The root password is read inside the database
  container and passed as `MYSQL_PWD`.
- Keeps the last 7 snapshots per domain. Only timestamp-named directories are
  ever pruned.
- A lock file (`<instance>/.maintenance.lock`) stops two backups, or a backup
  and a restore, from running against the same instance at once.

### Scheduled backups

Setting `ESPOCRM_BACKUP_ROOT` and `ESPOCRM_INSTANCE_DIR` skips every prompt.
That is the same pattern as the Rocket.Chat backup's non-interactive mode. A
crontab line for a user in the `docker` group:

```cron
15 2 * * * ESPOCRM_BACKUP_ROOT=/home/backup ESPOCRM_INSTANCE_DIR=/var/www/docker/espocrm/crm.example.com /path/to/OpenSource/EspoCRM/scripts/espocrm-docker-backup.sh >> $HOME/espocrm-backup.log 2>&1
```

`ESPOCRM_BACKUP_KEEP` changes how many snapshots are kept (`0` = never prune).
Unattended runs never prompt. They create a missing backup root, refuse to
start without enough free space, and exit non-zero on any failure, which cron
reports. Copy the backup root off the host, too. A snapshot on the same disk
does not survive losing that disk.

## Restore

```bash
./scripts/espocrm-docker-restore.sh
```

Pick a snapshot, then the instance to restore **into**. The database and the
files are always restored together. `custom/` defines the custom fields and
entities the tables must match, and `config-internal.php` holds `cryptKey`,
which decrypts the email-account passwords stored in the database.

The target can be:

- **the same instance**, to roll back, or
- **a fresh instance**, for disaster recovery. On a new host, or with another
  domain, run `espocrm-docker-install.sh` first and restore into it. The
  target's `.env` stays the source of truth. The database credentials in the
  restored `config-internal.php` are rewritten to the target's, and `siteUrl`
  and the WebSocket URL are re-applied from its `ESPOCRM_DOMAIN` on start. The
  passwords don't have to match the snapshot's.

What happens:

1. The snapshot is verified (gzip, dump trailer, config files) before anything
   changes.
2. Optional **safety snapshot** of the target, made by the backup script, so
   the restore can be undone with this same script (shown as `pre-restore`).
3. `espocrm`, `espocrm-daemon` and `espocrm-websocket` are stopped. MariaDB
   stays up.
4. The `espocrm` database is dropped, recreated and loaded from the dump.
5. `data`, `custom` and `client/custom` are emptied and extracted. The DB
   credentials are set with EspoCRM's own `config:set`, `data/cache` is cleared,
   and ownership goes back to `www-data`.
6. `espocrm` starts. Its entrypoint clears the cache and runs migrations. The
   script waits until it answers, stops early with the log if it crash-loops,
   then starts the daemon and websocket.

The target's EspoCRM version must be the snapshot's or newer, because
migrations only run forward. A newer target migrates the restored data on
start, the same as an upgrade. After a restore, users and passwords are the
snapshot's, including admin's.

## Useful commands

Run from `/var/www/docker/espocrm/<domain>/`:

```bash
docker compose ps                    # status, including health
docker compose logs -f espocrm       # app (install/migrate output, Apache)
docker compose logs -f espocrm-daemon
docker compose restart
docker compose down                  # stop - keeps the volumes
docker compose up -d                 # start

# EspoCRM CLI - as www-data, so files it writes stay writable by the app
docker compose exec -u www-data espocrm bin/command rebuild
docker compose exec -u www-data espocrm bin/command clear-cache
docker compose exec -u www-data espocrm bin/command set-password admin

# MariaDB shell
docker compose exec espocrm-db sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb -uroot espocrm'
```

`docker compose down -v` **deletes all data**.

## Troubleshooting

**Install fails / container restarts in a loop.** Check
`docker compose logs espocrm`. The entrypoint prints `error: Installation failed: …`.
The install only runs against an empty database, so after fixing the cause,
start over: `docker compose down -v`, then re-run the installer into an empty
directory.

**"Max failed login attempts exceeded for IP address 172.x.x.x".** The request
reached EspoCRM without `X-Real-IP`, so the vhost isn't the one from this repo,
or another proxy sits in front. Every user shares that one address. Fix the
proxy headers. The block clears after `authFailedAttemptsPeriod` (60s).

**WebSocket errors in the browser console.** Check that `location /wss` is in
the vhost and that its `proxy_pass` port matches `ESPOCRM_WS_PORT`. Then run
`docker compose logs espocrm-websocket`.

**Links in emails point to the wrong host.** `siteUrl` comes from
`ESPOCRM_DOMAIN`. Fix it in `.env` and run `docker compose up -d`.

**Uploads fail with 413.** Raise `client_max_body_size` in the vhost. Past
50 MB you also need to raise PHP's limits in the container.

## References

- Docker installation (compose, environments, upgrading, troubleshooting):
  https://docs.espocrm.com/administration/docker/installation/
- WebSocket (proxy paths and timeouts): https://docs.espocrm.com/administration/websocket/
- Config parameters (`ipAddressServerParam`, auth limits): https://docs.espocrm.com/administration/config-params/
- Official image source: https://github.com/espocrm/espocrm-docker
- Official installer (Nginx and compose templates): https://github.com/espocrm/espocrm-installer

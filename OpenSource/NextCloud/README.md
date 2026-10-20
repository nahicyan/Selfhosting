# Nextcloud AIO (Docker Compose)

Self-hosted [Nextcloud](https://nextcloud.com/) using
[Nextcloud All-in-One](https://github.com/nextcloud/all-in-one) (AIO) behind
the host's Nginx, following AIO's
[reverse proxy guide](https://github.com/nextcloud/all-in-one/blob/main/reverse-proxy.md).
Nginx terminates TLS on 80/443 and proxies to AIO's Apache container, which
listens on `127.0.0.1` only.

This replaces the manual AIO steps in [EOL-README.md](EOL-README.md). The script
applies the same `compose.yaml` changes to a freshly downloaded upstream file.

## Layout

```
NextCloud/
├── README.md
├── EOL-README.md                        # Old manual notes (AIO, nextcloud:fpm, bare metal), kept for reference
├── nextcloud-aio-nginx.conf             # Official AIO Nginx example as a vhost (placeholders: cloud.example.com, 127.0.0.1:11000, proxy_read_timeout 3610s)
├── all-in-one/                          # Upstream AIO repo, for reference only (git-ignored)
└── scripts/
    └── nextcloud-aio-docker-install.sh  # Downloads + patches compose.yaml, starts AIO, wires up certbot/Nginx
```

The instance lives at `/var/www/docker/nextcloud/<domain>/` by default:

| Path                | Contents                                                          |
|---------------------|-------------------------------------------------------------------|
| `compose.yaml`      | Upstream `compose.yaml` with the changes below                    |
| `compose.yaml.orig` | Upstream file as downloaded. `diff -u compose.yaml.orig compose.yaml` shows every change |
| `data/`             | Nextcloud's datadir (`NEXTCLOUD_DATADIR`). The location can be changed at install time |

AIO is not a normal Compose stack. `compose.yaml` only starts the
**mastercontainer**. Its web interface (the "AIO interface") takes the domain,
then creates and updates every other container (`nextcloud-aio-apache`,
`-nextcloud`, `-database`, `-redis`, Talk, Collabora, …). It also runs the
borg backups and restores. That is why there are no update, backup or
restore scripts here.

AIO allows **one instance per host**: the container name, the
`nextcloud_aio_mastercontainer` volume and the `nextcloud-aio` Compose project
are fixed upstream.

## Prerequisites

- Docker Engine from [docs.docker.com](https://docs.docker.com/engine/install/)
  (**not** the snap, which AIO doesn't support) and the Compose plugin. Your
  user must be in the `docker` group and able to use `sudo`.
- Nginx and certbot on the host
- DNS for the domain pointing to this server: an A record, plus an AAAA record
  if the server has IPv6 (see [IPv6](#ipv6))
- Free ports, and these open in the firewall/router for IPv4 and IPv6:

| Port | Default | Bound to | Used by |
|---|---|---|---|
| 80, 443 /tcp | | Nginx (`0.0.0.0`, `[::]`) | Nextcloud, ACME |
| AIO interface /tcp | `8081` | `0.0.0.0`, `[::]` | Admin interface, self-signed certificate (the official setup) |
| Apache /tcp+udp | `11000` | `127.0.0.1` | Nginx upstream only, never opened in the firewall |
| Talk /tcp+udp | `3478` | `0.0.0.0`, `[::]` | Talk's TURN server, only if Talk is ticked in the AIO interface |

Docker publishes the interface and Talk ports itself, so `ufw` rules don't
apply to them.

## Install

```bash
./scripts/nextcloud-aio-docker-install.sh
```

Prompts, in order:

1. **Domain** (e.g. `cloud.example.com`)
2. **Install directory** (default `/var/www/docker/nextcloud/<domain>`)
3. **Each `compose.yaml` change**, one question per row of the
   [table below](#changes-from-upstream-composeyaml). **Yes** applies the
   change. **No** keeps upstream's line exactly as it is. The defaults give
   the EOL-README.md setup, so pressing Enter throughout reproduces it: yes
   to each change with its EOL-README.md value, and no to Talk. A yes on a
   port or the data directory then asks for the value:
   - AIO interface port (`8081`)
   - Apache port (`11000`)
   - data directory (default `<install-dir>/data`). Put it on the big disk
     now, because AIO does not support moving it after the first start.

   **Will you use Nextcloud Talk?** (default no) comes in between. Only a yes
   asks about `TALK_PORT` (`3478`, must be above 1024). It also adds the Talk
   port to the port checks and the firewall list.

   The summary lists the accepted changes and the lines kept as upstream
   before anything is written.
4. **IPv6** for AIO's internal network. The default is yes when the host
   has a global IPv6 address. The prompt is skipped when the network already
   has IPv6, the kernel has IPv6 disabled, or Docker is older than 27.0.1.

### What the script does

1. Refuses a snap Docker, a missing `/var/run/docker.sock`, existing
   `nextcloud-aio-*` containers, or a non-empty install or data directory. If
   `nextcloud_aio_*` volumes are left from an earlier instance, it warns that
   AIO would resume that instance, and asks before continuing.
2. Downloads `compose.yaml` from AIO's `main` branch. Upstream changes often,
   and AIO updates itself anyway. Keeps the original as `compose.yaml.orig`.
3. Applies only the changes you accepted. Upstream's example lines are
   uncommented in place, so their documentation comments stay. It then
   checks the result with `docker compose config`: every accepted
   environment value and the published ports must be exactly as intended.
   If upstream changes its file layout, the script stops here instead of
   starting a wrong setup.
4. Offers to open `compose.yaml` in `$EDITOR`. Values you change there carry
   over to Nginx (`APACHE_PORT`, `NEXTCLOUD_MAX_TIME`).
5. With IPv6 chosen, creates the `nextcloud-aio` network with `--ipv6` (see
   [IPv6](#ipv6)).
6. Pulls and starts the mastercontainer, then waits until the interface
   answers. If the mastercontainer crash-loops (AIO rejects invalid settings
   at startup), the script stops and prints its log.
7. Warns if the domain's AAAA record does not point to this host, or notes
   that it is missing. Then it optionally gets a Let's Encrypt certificate
   (`certbot certonly --nginx`) and installs the Nginx vhost (see
   [below](#nginx-reverse-proxy)).

To use a specific upstream commit instead of `main`:

```bash
AIO_COMPOSE_URL=https://raw.githubusercontent.com/nextcloud/all-in-one/<commit>/compose.yaml \
  ./scripts/nextcloud-aio-docker-install.sh
```

### Finish in the AIO interface

1. Open `https://<server-ip>:<aio-port>/`. Use the **IP address, not the
   domain**: once Nextcloud sends HSTS for the domain, the browser would refuse
   the interface's self-signed certificate. Accept the certificate warning.
2. Note the passphrase, log in, enter the domain and submit. AIO validates the
   domain through Nginx, so the certificate and the vhost must be live first.
3. Choose the optional containers (Collabora, Talk, …) and the time zone,
   then **Download and start containers**. Note the initial admin password.
   **Nextcloud Talk is ticked by default.** Untick it if you don't use it.
   It can only be changed while the containers are stopped.
4. In the **Backup and restore** section, set the backup location. Optionally
   enable daily backups with automatic updates.

## Changes from upstream `compose.yaml`

These are the EOL-README.md changes, each offered on its own at install. The
ports and data directory come from the prompts. What declining means:

- **A port removal** (`80`, `8443`): the port stays published. `80`
  collides with the host's Nginx. `8443` collides with anything else on it,
  such as mailcow behind a reverse proxy. The port check warns before
  anything is written.
- **`APACHE_PORT`**: AIO runs without a reverse proxy. Its Apache takes 443
  itself, and the script skips the certificate and Nginx steps.
- **`APACHE_IP_BINDING`**: Apache listens on all interfaces, so plain HTTP
  to Nextcloud also works from outside, bypassing Nginx.
- **Any other row**: AIO's default applies (the "Why" column names it).

| Setting | Value | Why |
|---|---|---|
| `80:80`, `8443:8443` | removed | Only needed when AIO gets its own certificate. Nginx owns 80/443 here |
| `8080:8080` | `<aio-port>:8080` | Interface port. Only the host side may change |
| `APACHE_PORT` | `11000` | Required behind a reverse proxy. It is the Nginx upstream port |
| `APACHE_IP_BINDING` | `127.0.0.1` | Apache is reachable from this host only. Nginx is the single entry point |
| `NEXTCLOUD_DATADIR` | `<install-dir>/data` | Files on a host path instead of a Docker volume. Still included in AIO's backups |
| `TALK_PORT` | `3478` | Asked only if you will use Talk. TURN port, published by the Talk container. Without Talk, AIO doesn't read it |
| `NEXTCLOUD_UPLOAD_LIMIT` | `128G` | Default `1G` (non-chunked uploads, e.g. public shares) |
| `NEXTCLOUD_MAX_TIME` | `604800` | Default `3600`s. Nginx's `proxy_read_timeout` is set 10s above this |
| `NEXTCLOUD_MEMORY_LIMIT` | `2048M` | PHP memory per process. Default `512M` |
| `BORG_RETENTION_POLICY` | `--keep-within=7d --keep-weekly=4 --keep-monthly=6` | Upstream's default, made explicit |
| `NEXTCLOUD_STARTUP_APPS` | `deck twofactor_totp tasks calendar contacts notes` | Upstream's default, made explicit |
| `NEXTCLOUD_ADDITIONAL_APKS` / `_PHP_EXTENSIONS` | `imagemagick` / `imagick` | Upstream's default, made explicit |
| `AIO_DISABLE_BACKUP_SECTION` | `false` | Keeps the backup section visible |
| `WATCHTOWER_DOCKER_SOCKET_PATH` | `/var/run/docker.sock` | Needed for mastercontainer self-updates |

## Nginx reverse proxy

`nextcloud-aio-nginx.conf` is the official
[AIO Nginx example](https://github.com/nextcloud/all-in-one/blob/main/reverse-proxy.md#nginx-freenginx-openresty-angie),
with its comments. The official file is a whole `nginx.conf`, so a few things
differ to make it a vhost on a shared host:

| Difference | Why |
|---|---|
| No `pcre_jit`, `worker_processes`, `worker_cpu_affinity` | Main-context directives. Set them in `/etc/nginx/nginx.conf` if wanted (Debian/Ubuntu's already has `worker_processes auto`) |
| The `http {}` directives (`sendfile`, `aio`, `http2`, `ssl_*`, …) live in the `server {}` block | They apply to Nextcloud only and leave other vhosts alone |
| `map … $nextcloud_aio_connection_upgrade` and `upstream nextcloud_aio` | Maps and upstreams are global in nginx. The official names would clash with a `$connection_upgrade` or `nextcloud` from another vhost |

The script fills in the domain, `APACHE_PORT` and `NEXTCLOUD_MAX_TIME + 10s`.
It then applies the official version notes for the host's nginx:

- **nginx < 1.25.1**: switches to the `listen … ssl http2` lines and drops
  `http2 on;`, which older versions reject.
- **Other vhosts on 80/443**: drops `bind reuseport deferred so_keepalive=on`
  from the listen lines. nginx allows socket options only once per
  address:port across *all* vhosts. Next to a certbot-managed vhost
  (`listen [::]:443 ssl ipv6only=on;`), the official lines fail with
  `duplicate listen options for [::]:443`.
- **nginx built without threads**: comments out `aio threads` and `aio_write`.
- **Kernel booted with `ipv6.disable=1`**: comments out the `[::]` listen
  lines, which nginx could not open there.

It writes `/etc/nginx/sites-available/<domain>`, or
`/etc/nginx/conf.d/<domain>.conf` without the Debian layout, and asks before
overwriting. Then it runs `nginx -t`. If the test fails, it disables the vhost
again, because a broken vhost left enabled would also break later reloads and
certbot renewals.

AIO's Apache already sends HSTS and the other security headers, so the vhost
adds none.

## IPv6

Nginx and the ports Docker publishes serve IPv4 and IPv6 without any change.
Nginx forwards IPv6 clients to Apache over `127.0.0.1`, and their address
reaches Nextcloud in `X-Forwarded-For`.

Inside Docker, AIO puts its containers on a network called `nextcloud-aio`.
The mastercontainer creates that network **IPv4-only**, unless one with that
name already exists, and a network can't be switched to IPv6 later. On an
IPv4-only network:

- Docker's userland proxy forwards IPv6 connections to the published ports
  over IPv4, so the container sees the Docker gateway (`172.x.0.1`) instead
  of the client.
- Talk's TURN server relays IPv4 only. It takes its IPv6 relay address from
  its own address on this network (`TALK_HOST=nextcloud-aio-talk`), and there
  is none.
- The containers have no outbound IPv6. Nextcloud can't reach IPv6-only
  servers (federation, external storage, app store mirrors).

So the script creates the network itself before the first start. This
follows AIO's
[docker-ipv6-support.md](https://github.com/nextcloud/all-in-one/blob/main/docker-ipv6-support.md):

```bash
docker network create --ipv6 nextcloud-aio
```

Since Docker 27.0.1, Docker picks a private (ULA) IPv6 subnet for it and NATs
outbound traffic, with no `daemon.json` change. AIO's guide also offers
`"default-network-opts"` in `daemon.json`. The script doesn't use it, because
it would enable IPv6 on every new network of every other stack on the host.
Later `docker compose` commands don't touch the network, because it isn't part
of the Compose project. AIO finds it already there and uses it.

For IPv6 to work end to end:

- **AAAA record** for the domain, pointing to the host's global IPv6 address.
  Let's Encrypt validates over IPv6 when an AAAA record exists, so a stale one
  breaks `certbot` even when IPv4 is fine.
- **Firewall**: allow 80/443 (and the interface and Talk ports) for IPv6 as
  well. `ufw` does this by default (`IPV6=yes`). Cloud security groups
  usually need separate `::/0` rules.

Check an instance with:

```bash
docker network inspect nextcloud-aio --format '{{.EnableIPv6}}'   # true
```

To enable IPv6 on an existing instance, recreate the network with IPv6
([AIO discussion #4989](https://github.com/nextcloud/all-in-one/discussions/4989)):
stop the containers in the AIO interface, then run:

```bash
docker network disconnect nextcloud-aio nextcloud-aio-mastercontainer
docker network rm nextcloud-aio
docker network create --ipv6 --driver bridge nextcloud-aio
docker network connect nextcloud-aio nextcloud-aio-mastercontainer
docker restart nextcloud-aio-mastercontainer
```

Then start the containers again in the interface.

## Changing settings later

AIO reads its environment only when the mastercontainer is created:

1. Stop the containers in the AIO interface.
2. Edit `compose.yaml`, then from the install directory run
   `docker compose up -d`. Compose recreates the mastercontainer, and no data
   is lost.
3. Start the containers again in the interface.

If you change `APACHE_PORT` or `NEXTCLOUD_MAX_TIME`, also update `server
127.0.0.1:…` and `proxy_read_timeout` in the vhost. **Never change
`NEXTCLOUD_DATADIR`** after the first start.

## Updates and backups

Both run from the AIO interface. You can update the mastercontainer, then the
other containers, by hand, or let daily backups update everything
automatically. Backups are borg repositories that include the datadir.
Restoring is done in the same interface. To move to a fresh host, follow AIO's
[How to migrate from AIO to AIO?](https://github.com/nextcloud/all-in-one#how-to-migrate-from-aio-to-aio):
copy the borg repository over, run this installer there, then choose
**Restore former AIO instance from backup** in the new interface.

## Useful commands

```bash
docker logs -f nextcloud-aio-mastercontainer               # mastercontainer / interface
docker logs -f nextcloud-aio-nextcloud                     # Nextcloud (PHP)
docker ps --filter name=nextcloud-aio                      # all AIO containers
docker exec --user www-data -it nextcloud-aio-nextcloud php occ status
docker exec --user www-data -it nextcloud-aio-nextcloud php occ <command>
```

## Troubleshooting

**Domain validation fails.** Check `curl -I https://<domain>` from the server.
During validation AIO starts a temporary container on `APACHE_PORT`, so check
that the vhost is enabled, `nginx -t` passes, the certificate exists, and the
vhost's `server 127.0.0.1:…` matches `APACHE_PORT`. Then work through
[AIO's debug list](https://github.com/nextcloud/all-in-one/blob/main/reverse-proxy.md#7-how-to-debug-things).
It also covers hairpin NAT and Cloudflare.

**502 Bad Gateway on the domain.** Apache only exists after **Download and
start containers** in the interface, so a 502 before that is expected. Later,
check `docker ps --filter name=nextcloud-aio-apache`.

**Interface unreachable.** Open the interface port in the cloud provider's
firewall or security group, and use the IP address, not the domain.

**Mastercontainer restarts in a loop.** Run
`docker logs nextcloud-aio-mastercontainer`. AIO prints which setting it
rejects. For example, `NEXTCLOUD_UPLOAD_LIMIT` must end in `G`,
`NEXTCLOUD_MEMORY_LIMIT` must end in `M`, and `APACHE_PORT` must differ from
`TALK_PORT`.

**Start over.** Follow
[How to properly reset the instance](https://github.com/nextcloud/all-in-one#how-to-properly-reset-the-instance).
It removes the containers and every `nextcloud_aio_*` volume. Then delete the
install and data directories.

## References

- AIO readme (install, every environment variable, FAQ): https://github.com/nextcloud/all-in-one
- Reverse proxy guide (Nginx example, debugging): https://github.com/nextcloud/all-in-one/blob/main/reverse-proxy.md
- Upstream `compose.yaml`: https://github.com/nextcloud/all-in-one/blob/main/compose.yaml
- Docker IPv6 for AIO: https://github.com/nextcloud/all-in-one/blob/main/docker-ipv6-support.md

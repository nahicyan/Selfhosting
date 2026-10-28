# Plane: the MinIO image problem (runbook and analysis)

Written 2026-09-19, rewritten 2026-10-28 after Plane shipped its fix. Everything marked *verified* was checked on the date given, with the commands in [Re-verifying the facts](#re-verifying-the-facts). Re-check before acting on it later.

**In one paragraph.** Plane's bundled object storage is MinIO. MinIO removed its images from Docker Hub (`minio/minio`) and later from quay.io as well, so a compose file that names either can no longer pull. Plane has since fixed its releases. On 2026-09-28 it re-published v1.4.2's `docker-compose.yml` with `docker.io/pgsty/minio:RELEASE.2026-08-04T00-00-00Z`, a maintained community fork of MinIO. v1.4.3 moves on to the fork's renamed successor, `docker.io/pgsty/silo`. New installs work again with no workaround. A server installed **before** the fix still names `minio/minio:latest`. It keeps running while that image is cached, but it cannot upgrade or be rebuilt. This folder moves it to Plane's image: one service only, with checks, and an automatic rollback.

## Contents

- [What happened](#what-happened)
- [Did Plane provide a patch or a migration?](#did-plane-provide-a-patch-or-a-migration)
- [Is the switch safe for existing data?](#is-the-switch-safe-for-existing-data)
- [What is and is not affected](#what-is-and-is-not-affected)
- [Runbook: switch to Plane's image](#runbook-switch-to-planes-image)
- [Optional: upgrade Plane afterwards](#optional-upgrade-plane-afterwards)
- [Future paths](#future-paths)
- [Re-verifying the facts](#re-verifying-the-facts)
- [Notes for LLMs](#notes-for-llms)

## What happened

| Date | Event | Evidence |
| --- | --- | --- |
| 2025-09-07 | Last regular MinIO community release, `RELEASE.2025-09-07T16-13-09Z`. Docker Hub's final `minio/minio:latest` is this release. | `minio --version` in a cached `minio/minio:latest` (digest `sha256:14cea493d9a3…`), *verified* 2026-10-28. |
| 2026-03-19 | Issue makeplane/plane **#8774**: "minio/minio is maintenance-only, any plan to replace it?" | GitHub API. |
| 2026 (before 2026-09-12) | MinIO removes the `minio` organisation from Docker Hub. github.com/minio/minio says "THIS REPOSITORY IS NO LONGER MAINTAINED". | `docker pull minio/minio:latest` denied, *verified* 2026-09-19 and 2026-10-28. |
| 2026-08-04 / 08-06 | Pigsty's MinIO fork publishes its last release under the MinIO name, `pgsty/minio:RELEASE.2026-08-04T00-00-00Z`. Two days later it is renamed **Silo** (`pgsty/silo`). | Docker Hub; the pgsty/silo README. |
| 2026-08-23 | Plane **v1.4.2** released. Its compose file still names `minio/minio:latest` (so does v1.4.1). | The original release asset. |
| 2026-09-15 | Plane PR **#9829** on `preview`: `quay.io/minio/minio:RELEASE.2025-09-07T16-13-09Z`. The 2026-09-19 version of this folder used the same pin. | Git history. |
| 2026-09-28 | Plane **re-uploads v1.4.2's `docker-compose.yml`** under the same tag, now naming `docker.io/pgsty/minio:RELEASE.2026-08-04T00-00-00Z`. A Plane team member says so on #8774 and closes it. The release notes were not changed. | Asset `created_at` 2026-09-28T11:12:51Z (the other assets are still dated 2026-08-23); the issue's comments. *Verified* 2026-10-28. |
| 2026-10-01 | The same image on `preview` (PR #9727). | Commit `03197e3e`. |
| 2026-10-08 | PRs #9962 / #9963 switch `preview` and `release/v1.4.3` to `pgsty/silo:RELEASE.2026-09-16T00-00-00Z`, because `pgsty/minio` is "frozen at its final tag". | The PRs. |
| 2026-10-23 | **v1.4.3-rc2** ships Silo. No stable v1.4.3 yet on 2026-10-28. | Releases API, *verified* 2026-10-28. |
| by 2026-10-28 | `quay.io/minio/minio` and `quay.io/minio/mc` answer **401** to anonymous clients. Docker Hub gave the same "gone" signal. So the quay pin no longer pulls. | Registry v2 HEAD and quay API, *verified* 2026-10-28. |

## Did Plane provide a patch or a migration?

**Patch: yes, in the release assets.** v1.4.2's compose file was re-published with `pgsty/minio`, and v1.4.3 uses `pgsty/silo`. The only trace of the re-publish is the asset's date and the comment on #8774. The release notes do not mention it.

**Migration: none, and Plane treats it as unnecessary.** Plane's `setup.sh` upgrade stops the stack, downloads the new compose file and starts it again: `plane-minio` is recreated from the new image on the same `uploads` volume, with no data step. Silo's own guide (https://silo.pgsty.com/compatibility/migration/) says the same for single-node volumes: the data volume is reused in place, and the `MINIO_*` variables, the `/minio/*` routes and the `.minio.sys` metadata keep working.

**Install method: unchanged.** Community Edition is still installed from the release's `setup.sh`, which downloads that release's `docker-compose.yml` and `variables.env`. `../scripts/plane-docker-install.sh` downloads the same two files, so it works again as it is.

Also on `preview`, not yet in any release (v1.4.3-rc2's `variables.env` is byte-identical to v1.4.2's):

- `variables.env` ships `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` blank, and `setup.sh` generates them (#10074). Our installer already generates them.
- `NUM_PROXIES` sets the number of proxy hops for rate-limit client IPs (#10075).
- Redis TLS certificate verification (#10061).

None of these touches MinIO's data.

Moving uploads to external S3 is still documented on Plane's *Migrate data to external services* page (`mc mirror` from inside the MinIO container). Both new images still ship `mc`; Silo also ships it as `mcli`. So those commands still work.

## Is the switch safe for existing data?

*Tested* 2026-10-28 on a workstation's Docker 29. One volume was opened by each image in turn, with Plane's own `command: server /export --console-address ":9090"` and a bucket `uploads` with anonymous download, as Plane sets it. The data was small objects plus a 40 MB multipart object, and each hop also wrote a new object:

| Opened by | Objects, bytes, content hashes | Anonymous GET |
| --- | --- | --- |
| `minio/minio:latest` = `RELEASE.2025-09-07T16-13-09Z` (writes the data) | baseline | 200 |
| `pgsty/minio:RELEASE.2026-08-04T00-00-00Z` (v1.4.2 today) | identical | 200 |
| `pgsty/silo:RELEASE.2026-09-16T00-00-00Z` (v1.4.3-rc2) | identical | 200 |
| back to `RELEASE.2025-09-07T16-13-09Z` | identical | 200 |

`.minio.sys/format.json` stays `xl-single` throughout. Silo cannot open MinIO's legacy `fs` mode. MinIO itself dropped that mode in 2022, so no running 2025 MinIO can be on it.

**Going back** worked here for simple single-user data. Silo documents that an older binary is not guaranteed to understand metadata a newer one has written (IAM revocations, bucket metadata). Plane uses only the root credentials. Even so, treat the backup as the way back, not an older image.

**Binary.** `pgsty/silo` has no `minio` binary; its version command is `silo --version`. Its entrypoint maps a bare `server …` to `silo server …`, so Plane's `command:` works unchanged. `docker exec` does not go through the entrypoint, though, so `docker exec <c> minio …` fails there. `pgsty/minio` still has `minio`.

## What is and is not affected

| | Affected? |
| --- | --- |
| The running containers | No. The image is cached locally. |
| `docker compose up -d` / restart / recreate, image still cached | No. |
| `docker compose pull`, an upgrade that pulls, or a rebuild, with a compose file that names `minio/minio` or the quay pin | **Yes, fails.** |
| A first install today (`plane-docker-install.sh`) | No: it downloads the fixed compose file. |
| A new server for a restore | No: install first (fixed), then restore. |
| `docker image prune -a` while the MinIO container is stopped | Only the *old* release is lost (it cannot be pulled again). Moving forward to Plane's image still works. |
| The data (`uploads` volume, database) | No. |

The real production server (project `plane-plane-landivo-com`, Plane **v1.4.1**, `minio/minio:latest`, proxy on 127.0.0.1:3892) was "running, cached" on 2026-09-19. Whether the earlier quay runbook was run there is not known here; `01-preflight.sh` reports it either way. Its MinIO is almost certainly `RELEASE.2025-09-07T16-13-09Z`, Docker Hub's final `latest`, so the expected verdict is `UPGRADE`.

## Runbook: switch to Plane's image

Run from this folder, on the server, as a user in the `docker` group. Downtime: only in step 3, a few seconds of failing file uploads and downloads. Steps 1 and 2 change nothing in the running stack.

| Step | Command | Changes |
| --- | --- | --- |
| 0 | `../scripts/plane-docker-backup.sh` | Writes a snapshot under `/home/backup/plane/<domain>/`. Read its `manifest.txt`. |
| 1 | `./01-preflight.sh` | **Nothing (read-only).** Reports the running MinIO release, what the compose file names, and what Plane's latest release names, then gives a verdict. |
| 2 | `./02-save-minio-image.sh` | Tags the running image `plane-minio-rollback:<version>` and saves it to `/home/backup/plane-minio-image/<domain>/`. |
| 3 | `./03-pin-minio-image.sh` | Edits one compose line and recreates only `plane-minio`. |

**Read step 1's verdict first.**

- `UPGRADE` (the expected one): the running MinIO is older than the target, so step 3 moves it forward along the same line Plane's own upgrade takes. Continue once the backup exists.
- `SAME`: the running MinIO already is the target's release. Step 3 changes where the image comes from, not the software.
- `NEWER THAN THE TARGET`: **do not switch**, because it would be a downgrade. Choose a target at least as new (below), or let step 3 pin your saved copy.
- `UNKNOWN`: the version could not be read. Investigate; do not continue.
- *Nothing to do*: the compose file already names Plane's image (`pgsty/minio` or `pgsty/silo`). From here on, Plane's upgrades manage that line.

**Which target.** The default is `docker.io/pgsty/minio:RELEASE.2026-08-04T00-00-00Z`. That is what the current stable release (v1.4.2) names, so it matches what new installs get. To follow v1.4.3 (Silo) instead, run steps 1 and 3 with `MINIO_TARGET_IMAGE=docker.io/pgsty/silo:RELEASE.2026-09-16T00-00-00Z`. Step 1 prints what Plane's latest release names, and suggests that override when it differs from the target. The override's tag must be the plain `RELEASE.<date>`: the checks compare it with what the server prints.

**Earlier pins.** A compose file pinned by the 2026-09-19 runbook (`quay.io/minio/minio:…`) is in the same position as `minio/minio`: quay no longer serves it. A local pin (`plane-minio-rollback:…`) is in the same position too. The same three steps move either one to Plane's image.

**What step 3 guarantees.**

- It pulls the target before touching anything.
- It edits exactly one line, and aborts unless it finds exactly one.
- It recreates only `plane-minio`; the data volume is untouched.
- Afterwards it requires MinIO's health endpoint, the *target's* release from `minio --version` / `silo --version`, and the *same object count and total bytes* in Plane's bucket.
- On any failure it restores the compose file byte-for-byte and recreates the old container by itself.
- Re-running it after success says "Already done".

**Undo by hand** (if you ever need to): `cp -p docker-compose.yaml.pre-minio-pin-<time> docker-compose.yaml`, then `docker compose -f docker-compose.yaml --env-file=plane.env --project-name plane-<domain-with-dashes> up -d --no-deps plane-minio`. To restore the old image on any host: `gunzip -c <archive> | docker load`. After a forward switch, prefer restoring the backup over running the old image on data the new one has written (see above).

**Afterwards.** `docker compose pull` works for every service again. Copy `/home/backup/plane-minio-image/` off the server with your backups. From now on, upgrade as in [`../README.md`](../README.md#upgrading); the new compose file carries Plane's MinIO image. After a *local* pin, pull fails for that one service: use `docker compose pull --ignore-pull-failures`.

**How this was tested** (2026-10-28): on a workstation's real Docker 29, not on the production server. The rig was an instance shaped like production: its compose file named `minio/minio:latest`, served from a cached genuine `RELEASE.2025-09-07T16-13-09Z`, while Docker Hub and quay denied it. Only `api` and `plane-minio` ran, and `api` was a Python + boto3 stand-in that lists the bucket the way Plane's S3 client does. The seed was 12 objects plus a 21 MB multipart object. 34 checks, all passed:

- Step 1 changes nothing, and gives the `UPGRADE` verdict. It reports Docker Hub and quay as denied, and reads `pgsty/minio` from Plane's v1.4.2.
- Step 2 tags and archives the image.
- Step 3 happy path: one line changed, only MinIO recreated, the release reported is now `2026-08-04`, the object count and bytes are identical, and a full `docker compose pull` then works. Re-running it is a no-op.
- Rollback: a `-distroless` target reports a different release, so step 3 fails after the switch. The compose file comes back byte-identical, the old release runs again, and the bucket is unchanged.
- A target older than the running release is refused, and only the saved copy is offered.
- A local pin followed by a move to Plane's image works.
- Following v1.4.3 with `MINIO_TARGET_IMAGE=…pgsty/silo…` works, and the version is read through `silo`.

Not tested: the real server, the full Plane stack, Plane v1.4.1.

## Optional: upgrade Plane afterwards

This is not needed for MinIO, and the steps here do not test it. Facts about v1.4.1 to v1.4.2 (*verified* 2026-10-28):

- The release notes list one web fix.
- `variables.env` is byte-identical.
- The compose file differs in the image-tag defaults and in the `plane-minio` image. After step 3 with the default target, only the tag defaults differ, and `APP_RELEASE` in `plane.env` overrides them.

So no file needs replacing. From the install directory, after a backup and after step 3:

```bash
cp -p plane.env plane.env.bak
sed -i 's/^APP_RELEASE=.*/APP_RELEASE=v1.4.2/' plane.env
COMPOSE="docker compose -f docker-compose.yaml --env-file=plane.env --project-name plane-<domain-with-dashes>"
$COMPOSE pull && $COMPOSE up -d      # the migrator re-runs on start
```

For v1.4.3 and later, replace the compose file as in [`../README.md`](../README.md#upgrading). That also moves MinIO to Silo.

## Future paths

**A. Plane ships a release that fixes the image.** *Done* (v1.4.2 re-published, then v1.4.3). New installs need nothing. Existing servers: run the runbook above, or upgrade normally.

**B. Plane replaces the bundled storage with a server that is not MinIO-compatible.** Follow Plane's migration guide, whatever it says. Expect a new service name, new env keys and a different on-disk format. Consequences here:

- `plane-docker-backup.sh` step 7 archives the MinIO *volume*, which is meaningless for another server. It must become an S3 sync (`mc mirror`, `aws s3 sync` or `rclone`), and the restore's uploads option must follow.
- The installer's `sed` lines that write `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` assume those are MinIO's root credentials.

(Silo is not this case: it keeps MinIO's format.)

**C. Move uploads to external S3** (Plane's documented path, and the long-term option). Managed choices: AWS S3, Cloudflare R2, Backblaze B2, Wasabi. Adapted to this layout (`<install-dir>` = `/var/www/docker/plane/<domain>`, project `plane-<domain-with-dashes>`, MinIO container `plane-<domain-with-dashes>-plane-minio-1`):

1. Take a backup and do steps 1-3 above first (a working, pullable MinIO is your rollback).
2. Create the bucket, an IAM user with `s3:GetObject` and `s3:PutObject`, and the **CORS** policy from Plane's docs (allowed origin `https://<domain>`; methods GET, POST, PUT, DELETE, HEAD; expose `ETag`, `x-amz-*`). Presigned uploads go from the browser straight to the bucket, so CORS is required.
3. Copy the data with Plane's commands, run from the install directory: `docker compose ... exec plane-minio mc alias set localminio http://localhost:9000 <AWS_ACCESS_KEY_ID> <AWS_SECRET_ACCESS_KEY>` (those two values are in `plane.env`; here they double as MinIO's root user/password), an alias for the cloud endpoint, then `mc mirror localminio/uploads cloudminio/<bucket> --overwrite`. Repeat the mirror right before the cutover. (`mc` is in `pgsty/minio` and `pgsty/silo`; Silo also calls it `mcli`.)
4. In `plane.env`: `USE_MINIO=0`, `AWS_REGION`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_S3_ENDPOINT_URL`, `AWS_S3_BUCKET_NAME` (per Plane's Community Edition instructions). Plane's page says to restart with `setup.sh`; in this layout use `$COMPOSE up -d`.
5. Verify in the browser: existing attachments and images load, a new upload works. Keep the MinIO volume until you are confident.
6. Afterwards `plane-docker-backup.sh` **skips** the uploads (it detects `USE_MINIO=0`): back the bucket up with your provider's tools. The restore's uploads option disappears for new snapshots. Plane's docs recommend an external database as well; that is a separate move.

**D. A different self-hosted S3 server** (RustFS, Garage, SeaweedFS were suggested on #8774; Plane chose Silo instead). It is a copy, like C, not an in-place swap. Test presigned uploads, CORS and path-style addressing before cutting over.

## Re-verifying the facts

```bash
# latest release, and which MinIO image its compose names
curl -fsSL https://api.github.com/repos/makeplane/plane/releases/latest | grep '"tag_name"'
curl -fsSL https://github.com/makeplane/plane/releases/download/<tag>/docker-compose.yml | grep -n -A1 'plane-minio:'
# when the release's assets were (re)uploaded
curl -fsSL https://api.github.com/repos/makeplane/plane/releases/tags/<tag> | grep -E '"name"|"created_at"'
# are MinIO's own registries still refusing? (a control: docker manifest inspect busybox)
docker manifest inspect minio/minio:latest
docker manifest inspect quay.io/minio/minio:latest
# the fork's published tags
curl -fsSL 'https://hub.docker.com/v2/repositories/pgsty/silo/tags/?page_size=10&ordering=last_updated'
# the release a container runs, whichever binary its image has
docker exec <minio-container> sh -c 'minio --version 2>/dev/null || silo --version'
# Plane's history of the community compose file
git -C <makeplane/plane clone> log --format='%h %ad %s' --date=short -- deployments/cli/community/docker-compose.yml
```

## Notes for LLMs

Context for a future session that picks this up cold.

**The owner's decisions.**

- 2026-09-19: keep bundled MinIO, pinned to a source that still existed (quay). The install script was not patched.
- 2026-10-28: re-check upstream and update the scripts to match. Upstream had fixed its releases. The install logic needed no change, only its notes. This folder was retargeted from the dead quay pin to Plane's image, with a forward-only version check.

Still standing: one-off work lives here in `migration/`; the reusable `scripts/plane-docker-{install,backup,restore}.sh` get notes as comments. Do not change install/backup/restore logic, migrate storage, or use the `-distroless` or `.hotfix.*` tags without being asked; list such ideas for the owner to choose.

**Repo conventions** (see the other apps' scripts): `set -euo pipefail`; numbered `── N. ──` sections; interactive menus; `/var/www/docker/<app>/<domain>` and `/home/backup` defaults; instance scan by a compose file that names the app's image; typed confirmations for anything destructive. `lib.sh` here holds the shared helpers; it is sourced, not run.

**Layout facts.** Instance: `/var/www/docker/plane/<domain>/{docker-compose.yaml, plane.env}`. The Compose project is `plane-${domain//./-}`, always passed as `--project-name`. MinIO service `plane-minio`, data volume `uploads` mounted at `/export`, bucket `uploads`. The proxy publishes on `127.0.0.1:<LISTEN_HTTP_PORT>`. `plane.env` holds `SECRET_KEY`, which encrypts settings stored in the database: never restore a database without the matching `plane.env`.

**Pitfalls already learned.**

- Do **not** put non-snapshot folders under `/home/backup/plane/<domain>/`. The backup script prunes every folder there beyond 7, and the restore script lists every folder there as a snapshot. That is why the image archive lives in the sibling `plane-minio-image/`.
- `docker save <image-id>` drops the tag: tag first (`plane-minio-rollback:<version>`), then save the tag.
- Never move MinIO to an *older* release than the one that wrote the data. Compare `minio --version` / `silo --version` in the running container, not the image tag (`latest` says nothing). `RELEASE.<date>` strings sort chronologically across MinIO, pgsty/minio and Silo (`release_le` in `lib.sh`).
- Silo has no `minio` binary. Anything that execs `minio` inside the container must fall back to `silo`.
- `MINIO_TARGET_IMAGE` must carry the plain `RELEASE.<date>` tag. A `-distroless` tag fails step 3's version check, which fails safe and rolls back; the rig used that on purpose to exercise the rollback.
- `docker compose up -d --no-deps plane-minio` recreates only MinIO; without `--no-deps`, compose may touch dependencies.
- To read the bucket safely use Plane's own client in the `api` container (`boto3` with `AWS_S3_ENDPOINT_URL`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_S3_BUCKET_NAME`); it uses exactly what Plane uses.
- The wording "reads as empty **silently**" about a wrong `SECRET_KEY` was tested: `decrypt_data` returns `''`, exits 0, and only logs an error server-side.

**Testing without the server.**

- Real Docker works, and so does rootless Podman (the 2026-09-19 rig).
- A cached genuine `minio/minio:latest` stands in for the production image. If the test host runs other stacks from it, never re-tag, prune or remove it: it cannot be pulled again.
- The 2026-10-28 rig needed only two services: `api` (`python:3.12-slim` plus `boto3`, with Plane's `AWS_*` variables) and `plane-minio`, whose compose file carries a `makeplane/plane-backend` comment so `select_instance` finds it. It also needed a snapshot folder named with the current time under the backup root, so the freshness check passes. It drove 01-03 by piping the answers to stdin.
- Prove "read-only" by comparing the compose file before and after.
- Clean up afterwards: containers, volumes, the `plane-minio-rollback:*` tag (untag only) and the pulled images.

**Not verified.** The production server itself (unreachable from the workspace), the full Plane stack against the new images, and the upgrade to v1.4.2 or v1.4.3.

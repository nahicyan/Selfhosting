# Plane: the MinIO image problem (runbook and analysis)

Written 2026-09-19. Everything marked *verified* was checked that day with the commands in [Re-verifying the facts](#re-verifying-the-facts); re-check before acting on it later.

**In one paragraph.** Plane's bundled object storage is MinIO. MinIO declared its repository unmaintained and removed its Docker Hub organisation, so `docker pull minio/minio` is now denied. Every Plane release still names `minio/minio:latest`, so anything that *pulls* fails (`docker compose pull`, a first install, a new server). A server that is already running is unaffected until the day it has to pull. Plane has published no migration and no patch for existing installs; the owner's decision (2026-09-19) is to **keep bundled MinIO for now**, pin its image to a source that still exists, and revisit when Plane decides something.

## Contents

- [What happened](#what-happened)
- [Did Plane provide a patch or a migration?](#did-plane-provide-a-patch-or-a-migration)
- [What is and is not affected](#what-is-and-is-not-affected)
- [Runbook: keep bundled MinIO, pinned](#runbook-keep-bundled-minio-pinned)
- [Optional: upgrade Plane afterwards](#optional-upgrade-plane-afterwards)
- [Future paths](#future-paths)
- [Re-verifying the facts](#re-verifying-the-facts)
- [Notes for LLMs](#notes-for-llms)

## What happened

| Date | Event | Evidence |
| --- | --- | --- |
| 2025-09-07 | Last regular MinIO community release, `RELEASE.2025-09-07T16-13-09Z`. | quay.io tag `latest` points at it. |
| 2026-03-19 | Issue makeplane/plane **#8774**: "minio/minio is maintenance-only, any plan to replace it?" It is **still open**: 5 comments, none from the Plane team. | GitHub API. |
| 2026 (before 2026-09-12) | MinIO removes the `minio` organisation from Docker Hub, and github.com/minio/minio now says "THIS REPOSITORY IS NO LONGER MAINTAINED". A commenter on #8774 reports it on 2026-09-12. | Real `docker pull minio/minio:latest` on 2026-09-19: *requested access to the resource is denied* (a control image pulled fine). |
| 2026-08-23 | Plane **v1.4.2** released. Its compose file still has `image: minio/minio:latest`. So does v1.4.1. | Release assets. |
| 2026-09-15 | Plane commit `f25814c` (PR **#9829**, "pull MinIO images from quay.io instead of the removed Docker Hub org") on the **`preview`** branch: `quay.io/minio/minio:RELEASE.2025-09-07T16-13-09Z`. | Git history of makeplane/plane. |

MinIO's own statement is that the community edition is no longer maintained, so this image will not get security fixes. quay.io also carries later `.hotfix.*` tags (for example `RELEASE.2025-09-07T16-13-09Z.hotfix.7aa24e772`, 2026-04-01). Their contents could not be verified and they are **not** used here.

## Did Plane provide a patch or a migration?

**No, not for existing installs.**

- **Patch:** PR #9829 only repoints the image reference, which helps *new pulls*. It is in `preview`, **in no release** (latest is v1.4.2, 2026-08-23).
- **Replacement:** none chosen. #8774 has no reply from the Plane team. A community draft (#8820) proposes RustFS and notes that swapping storage servers in place is impossible because their on-disk formats differ.
- **Migration:** the only documented one is Plane's page *Migrate data to external services* (https://developers.plane.so/self-hosting/manage/migration/migrate-data-to-external-services): Postgres via `pg_dump`/`pg_restore`, storage via `mc mirror` from inside the MinIO container to an S3 bucket, then `USE_MINIO=0`. That moves you **off** bundled MinIO; it is not a fix for it. (`mc` is bundled in the MinIO server image, so those commands work as written.)
- The `migration-0.13-0.14.sh` in Plane's repo is an unrelated one-time volume migration.

## What is and is not affected

| | Affected? |
| --- | --- |
| The running containers | No. The image is cached locally. |
| `docker compose up -d` / restart / recreate, image still cached | No. |
| `docker compose pull`, upgrades that pull, a first install (`plane-docker-install.sh` stops at its pull step) | **Yes, fails.** |
| A new or rebuilt server, or a restore that needs an install first | **Yes.** |
| `docker image prune -a` while the MinIO container is stopped | **Yes**: the only copy of a working image is deleted and cannot be pulled again. |
| The data (`uploads` volume, database) | No. |

The real production server (project `plane-plane-landivo-com`, Plane **v1.4.1**, MinIO `minio/minio:latest` created about 4 weeks before 2026-09-19, proxy on 127.0.0.1:3892) is in the "running, cached" state. Its actual MinIO version is unknown until `01-preflight.sh` has been run on it.

## Runbook: keep bundled MinIO, pinned

Run from this folder, on the server, as a user in the `docker` group. Downtime: only step 3, a few seconds of failing file uploads/downloads. Steps 1 and 2 change nothing in the running stack.

| Step | Command | Changes |
| --- | --- | --- |
| 0 | `../scripts/plane-docker-backup.sh` | Writes a snapshot under `/home/backup/plane/<domain>/`. Read its `manifest.txt`. |
| 1 | `./01-preflight.sh` | **Nothing (read-only).** Reports the MinIO version and a verdict. |
| 2 | `./02-save-minio-image.sh` | Tags the running image `plane-minio-rollback:<version>` and saves it to `/home/backup/plane-minio-image/<domain>/`. |
| 3 | `./03-pin-minio-image.sh` | Edits one compose line and recreates only `plane-minio`. |

**Read step 1's verdict first.**

- `MATCH`: the running MinIO is the release the pin (`quay.io/minio/minio:RELEASE.2025-09-07T16-13-09Z`) points at, so step 3 changes where the image comes from, not the software. Continue.
- `MISMATCH`: the running MinIO is a different release. **Do not pin to quay**: an older MinIO opening data written by a newer one can fail. Do step 2, then in step 3 choose the local option (your own saved image). Do not override the tag to "fix" the mismatch without understanding the MinIO release history first.
- `UNKNOWN`: could not read the version. Investigate; do not continue.

**What step 3 guarantees.** It pulls the target before touching anything; edits exactly one line (and aborts unless it finds exactly one); recreates only `plane-minio` (its data volume is untouched); requires MinIO's health endpoint, the same MinIO version and the *same object count and total bytes* in Plane's bucket afterwards; and on any failure restores the compose file byte-for-byte and recreates the old container by itself. Re-running it after success says "already pinned".

**Undo by hand** (if you ever need to): `cp -p docker-compose.yaml.pre-minio-pin-<time> docker-compose.yaml`, then `docker compose -f docker-compose.yaml --env-file=plane.env --project-name plane-<domain-with-dashes> up -d --no-deps plane-minio`. To restore the image itself on any host: `gunzip -c <archive> | docker load`.

**Afterwards.** Copy `/home/backup/plane-minio-image/` off the server with your backups. `docker compose pull` works again (verified on the test rig). After a *local* pin it fails for that one service; use `docker compose pull --ignore-pull-failures`.

**How this was tested:** on a rebuilt rig, not on the production server: a real Plane v1.4.2 stack (rootless Podman) made to look like the server (compose naming a locally cached `minio/minio:latest`, Docker Hub really denying it). Verified: step 1 changes nothing (state fingerprint identical); step 2's archive loads back to the identical image id; step 3 happy path (one line changed, only the MinIO container recreated, object count and bytes identical, API 200, a full `docker compose pull` then exits 0); step 3 rollback (a non-MinIO image makes the container fail; compose byte-identical, old image, same bucket); version mismatch refused; local pin works; re-running is a no-op. Not tested: the real server, real Docker (the rig used Podman), Plane v1.4.1.

## Optional: upgrade Plane afterwards

Not needed for MinIO, and not tested by these scripts. Verified facts about v1.4.1 to v1.4.2: the release notes list one web fix; `variables.env` is byte-identical; the compose file differs only in the image-tag defaults, which `APP_RELEASE` in `plane.env` overrides. So no file needs replacing. From the install directory, after a backup and after step 3:

```bash
cp -p plane.env plane.env.bak
sed -i 's/^APP_RELEASE=.*/APP_RELEASE=v1.4.2/' plane.env
COMPOSE="docker compose -f docker-compose.yaml --env-file=plane.env --project-name plane-<domain-with-dashes>"
$COMPOSE pull && $COMPOSE up -d      # the migrator re-runs on start
```

## Future paths

Decide by what changes. The owner's current choice is "keep bundled MinIO"; these are for later.

**A. Plane ships a release that fixes the image** (check the release's `docker-compose.yml`, see below). Then upgrade normally; the compose file from the release is fine. Delete the workaround advice in the install script's notes and the README. Existing servers: run `01-preflight.sh`; if Plane's image differs from the pin, prefer Plane's.

**B. Plane replaces MinIO with another S3 server.** Follow Plane's migration guide, whatever it says. Expect a new service name, new env keys and a different on-disk format. Consequences here: `plane-docker-backup.sh` step 7 archives the MinIO *volume*, which is meaningless for another server, so it must become an S3 sync (`mc mirror`, `aws s3 sync` or `rclone`); the restore's uploads option must follow; and the installer's `sed` lines that write `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` assume those are MinIO's root credentials.

**C. Move uploads to external S3** (Plane's documented path; the recommended long-term target). Managed choices: AWS S3, Cloudflare R2, Backblaze B2, Wasabi. Adapted to this layout (`<install-dir>` = `/var/www/docker/plane/<domain>`, project `plane-<domain-with-dashes>`, MinIO container `plane-<domain-with-dashes>-plane-minio-1`):

1. Take a backup and do steps 1-3 above first (a working, pinned MinIO is your rollback).
2. Create the bucket, an IAM user with `s3:GetObject` and `s3:PutObject`, and the **CORS** policy from Plane's docs (allowed origin `https://<domain>`; methods GET, POST, PUT, DELETE, HEAD; expose `ETag`, `x-amz-*`). Presigned uploads go from the browser straight to the bucket, so CORS is required.
3. Copy the data with Plane's commands, run from the install directory: `docker compose ... exec plane-minio mc alias set localminio http://localhost:9000 <AWS_ACCESS_KEY_ID> <AWS_SECRET_ACCESS_KEY>` (those two values are in `plane.env`; here they double as MinIO's root user/password), an alias for the cloud endpoint, then `mc mirror localminio/uploads cloudminio/<bucket> --overwrite`. Repeat the mirror right before the cutover.
4. In `plane.env`: `USE_MINIO=0`, `AWS_REGION`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_S3_ENDPOINT_URL`, `AWS_S3_BUCKET_NAME` (per Plane's Community Edition instructions). Plane's page says to restart with `setup.sh`; in this layout use `$COMPOSE up -d`.
5. Verify in the browser: existing attachments and images load, a new upload works. Keep the MinIO volume until you are confident.
6. Afterwards `plane-docker-backup.sh` **skips** the uploads (it detects `USE_MINIO=0`): back the bucket up with your provider's tools. The restore's uploads option disappears for new snapshots. Plane's docs recommend an external database as well; that is a separate move.

**D. A self-hosted S3 server** (RustFS, Garage, SeaweedFS, or the MinIO fork Silo were suggested by commenters on #8774; Plane has not tested or endorsed any). It is a copy, like C, not an in-place swap. Test presigned uploads, CORS and path-style addressing before cutting over.

## Re-verifying the facts

```bash
# latest release, and whether its compose still names the dead image
curl -fsSL https://api.github.com/repos/makeplane/plane/releases/latest | grep '"tag_name"'
curl -fsSL https://github.com/makeplane/plane/releases/download/<tag>/docker-compose.yml | grep -n 'image:.*minio'
# is Docker Hub still refusing it? (a control: docker pull busybox)
docker pull minio/minio:latest
# what quay.io carries
curl -fsSL 'https://quay.io/api/v1/repository/minio/minio/tag/?limit=12&onlyActiveTags=true'
# Plane's response: the issue, the PR, and preview's history
curl -fsSL https://api.github.com/repos/makeplane/plane/issues/8774/comments
git -C <makeplane/plane clone> log --format='%h %ad %s' --date=short -i --grep=minio
# MinIO's own status
curl -fsSL https://raw.githubusercontent.com/minio/minio/master/README.md | head -20
# does the MinIO server image bundle mc? (Plane's migration commands assume it)
curl -fsSL https://raw.githubusercontent.com/minio/minio/RELEASE.2025-09-07T16-13-09Z/Dockerfile.release | grep -n 'mc'
```

## Notes for LLMs

Context for a future session that picks this up cold.

**The owner's decisions (2026-09-19).** Keep bundled MinIO for now. One-off work lives here in `migration/`, not in the reusable `scripts/plane-docker-{install,backup,restore}.sh`. Detailed notes go in those three scripts as **comments only**. The install script was deliberately **not** patched (the owner restored the original after an earlier rewrite). Do not change install/backup/restore logic, migrate storage, or use quay's `.hotfix.*` tags without being asked; list such ideas for the owner to choose.

**Repo conventions** (see the other apps' scripts): `set -euo pipefail`; numbered `── N. ──` sections; interactive menus; `/var/www/docker/<app>/<domain>` and `/home/backup` defaults; instance scan by a compose file that names the app's image; typed confirmations for anything destructive. `lib.sh` here holds the shared helpers; it is sourced, not run.

**Layout facts.** Instance: `/var/www/docker/plane/<domain>/{docker-compose.yaml, plane.env}`; Compose project `plane-${domain//./-}`, always passed as `--project-name`; MinIO service `plane-minio`, data volume `uploads` mounted at `/export`, bucket `uploads`; the proxy publishes on `127.0.0.1:<LISTEN_HTTP_PORT>`. `plane.env` holds `SECRET_KEY`, which encrypts settings stored in the database: never restore a database without the matching `plane.env`.

**Pitfalls already learned.**
- Do **not** put non-snapshot folders under `/home/backup/plane/<domain>/`: the backup script prunes every folder there beyond 7 and the restore script lists every folder there as a snapshot. That is why the image archive lives in the sibling `plane-minio-image/`.
- `docker save <image-id>` drops the tag: tag first (`plane-minio-rollback:<version>`), then save the tag.
- Never pin MinIO to an *older* release than the one that wrote the data. Compare `minio --version` in the running container, not the image tag (`latest` says nothing).
- `docker compose up -d --no-deps plane-minio` recreates only MinIO; without `--no-deps` compose may touch dependencies.
- To read the bucket safely use Plane's own client in the `api` container (`boto3` with `AWS_S3_ENDPOINT_URL`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_S3_BUCKET_NAME`); it uses exactly what Plane uses.
- The wording "reads as empty **silently**" about a wrong `SECRET_KEY` was tested: `decrypt_data` returns `''`, exits 0, and only logs an error server-side.

**Testing without the server.** Rootless Podman works: run `podman system service --time=0 unix:///run/user/<uid>/<short>.sock` (the path must be under 108 characters) with `CONTAINERS_REGISTRIES_CONF` pointing at a file containing `unqualified-search-registries = ["docker.io"]`, and export `DOCKER_HOST` to that socket so `docker compose` works. Install with a copy of `plane-docker-install.sh` (three mechanical changes: scratch install path, `sudo mkdir` to `mkdir`, and the MinIO image swap before the pull). To mimic the server, `docker tag` the quay image as `docker.io/minio/minio:latest` and put `minio/minio:latest` in the compose file. Rig-only quirk: `docker compose down` intermittently fails with `rootless netns: kill network process: permission denied`; retry it. Prove "read-only" by fingerprinting containers, compose, env, volumes and images before and after. Clean up afterwards (containers, volumes, images, the service and its socket).

**Not verified.** The production server itself (unreachable from the workspace), real Docker, and the upgrade to v1.4.2.

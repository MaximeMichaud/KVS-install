# kvsctl

`kvsctl` upgrades a KVS Docker stack installed by this repository the way a
packaged product is upgraded: a signed list of releases, a version to go to
and one to come back to, a backup first, the images downloaded while the
site keeps running, a restart, a verification, and an automatic rollback
when the new version does not come up.

The Docker path of `kvs-install` keeps working exactly as before: `kvsctl`
only adds the commands below on top of it. The images it pins are not
published on a registry yet; the pipeline that will publish them is
described in [docs/releasing.md](../docs/releasing.md), and every scenario
below ran against a lab registry on a real site.

## What a release is

A release of the stack (not of KVS: KVS updates itself from its own admin
panel) is:

- a version number, `YY.M.PATCH` (`26.11.0`, then `26.11.1`), with a
  candidate written `26.11.0-rc1`;
- a bundle: the repository files the stack is made of (`docker/`, `conf/`,
  the scripts, the README) as a `.tar.gz`, with `docker/RELEASE` naming the
  version and `docker/docker-compose.release.yml` pinning the image of every
  service the setup used to build on the server;
- the images those pins name, with their digest, their layers and their
  sizes, so `kvsctl` knows before pulling how many bytes this machine
  lacks. The php-fpm and cron images are published once per PHP series
  (`variants.php["8.1"]`, `["8.2"]`, ...) because an IonCube encoded site is
  bound to the series its files were encoded for: each site pulls the
  images of its own series and the override reads them from `.env`
  (`KVS_PHP_FPM_IMAGE`, `KVS_CRON_IMAGE`);
- what the release requires: the oldest version allowed to upgrade directly
  (`min_from`), the PHP series it publishes, the oldest KVS supported, the
  MariaDB series its database image upgrades from (`mariadb_from`), the
  oldest Docker Compose that reads its override (`compose_min`);
- whether the release changes the database (`database: migrates`), which
  makes a rollback restore the backup, and whether it is one way
  (`one_way`), which makes a rollback recreate the MariaDB data directory
  before restoring it;
- one line of notes, up to three highlights and a link to the changelog.

All of this is `manifest.json`, signed with an Ed25519 key. The signature
file lists one signature per signing key, so a key rotation is a release
signed by the outgoing key and the incoming one at once; the manifest can
also announce a key ahead of its first use, and `kvsctl` warns when it does
not know it yet. `kvsctl` embeds the public keys and refuses a manifest none
of them signed. Nothing is sent anywhere: a check is one GET of a public
file, at most once a day.

## Commands

| Command | What it does |
| --- | --- |
| `kvsctl adopt --version X` | Records the version of a stack installed before `kvsctl` existed, keeps its release files for a rollback and checksums them. Run once; `--force` replaces the record. |
| `kvsctl status` | The site, its KVS and PHP versions, the stack version, one line per service with the image it runs and its health, and whether a newer release exists. |
| `kvsctl check [--version X]` | Reads the manifest and prints the plan: the image of every service today and in the release, the bytes to download, the notes, what the release requires, and what blocks it. |
| `kvsctl upgrade [--version X]` | Backup, pull, apply, restart, verify, and rollback on failure. |
| `kvsctl rollback [--restore-db]` | Returns to the previous version by hand; its files and images are still on the machine. |
| `kvsctl backup [--keep N]` | A database dump with the `.env` and the state, as `backups/backup-<version>-<date>.tar`; the oldest backups beyond `N` (5) go. |
| `kvsctl restore [backup] [--latest] [--env]` | Replays the database of a backup over the running stack, after backing up the current one. Without an argument the backups are listed and asked for. |
| `kvsctl history [--json]` | What `kvsctl` did to this stack, oldest first. |
| `kvsctl releases [--json]` | The releases the signed manifest offers, with the installed one marked. |
| `kvsctl logs [service] [--tail N] [-f]` | The logs of the stack or of one service. |
| `kvsctl clean [--dry-run]` | Removes the images, release files and downloads of the versions that are neither installed nor the one a rollback returns to. |
| `kvsctl version [--check]` | The build, and whether the latest release ships a newer one. |
| `kvsctl update-cli` | Replaces the binary with the one the latest release ships, after checking its sha256. Nothing to do when this build is that release's. |

`--plain` prints lines instead of the interactive screen; without a
terminal (cron, `nohup`, CI) lines are printed anyway and `--yes` answers
the questions. `--quiet` keeps only the steps, the failures and the
questions, and skips the reminder that a newer release exists which every
other command prints on stderr. `--root` or `KVS_INSTALL_DIR` name the
installation when it is not `/opt/kvs`; `--manifest` or
`KVSCTL_MANIFEST_URL` name another release list (a lab), `KVSCTL_RELEASE_KEY`
another set of public keys (`id=base64`, comma separated).
`--allow-stale-manifest` accepts a manifest older than one already seen.

The commands that write (`upgrade`, `rollback`, `backup`, `restore`, `adopt`,
`clean`) take a lock on the installation; a second one says which run holds
it and exits.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | done |
| 1 | an error before anything was changed, or a command that refused |
| 2 | the command line could not be parsed |
| 3 | the upgrade is blocked: nothing was touched, `check` says why |
| 4 | the upgrade failed and the previous version is back and healthy |
| 5 | the upgrade failed and the rollback failed too: read the log before touching anything |
| 6 | another `kvsctl` holds the lock |
| 7 | the manifest is older than the one already seen (a stale mirror, a replayed file) |

## What an upgrade does, step by step

1. Reads and verifies the manifest, refuses one older than the newest it
   has seen, picks the target (the latest, or `--version`) and builds the
   plan: for every service, the image the container runs and the one the
   release pins, whether the engine already holds it, and the layers left
   to download. The blockers below stop it here, and nothing is touched.
2. Lists every service with the version it runs and the one the release
   pins (`nginx  26.10.0 → 26.11.0  67 MB to download`, `mariadb  11.8
   unchanged`), prints the notes, the highlights and the changelog link,
   and asks for confirmation with the download size: the layers of the
   release images that the engine does not hold yet, not the size of the
   images. During the pull the same lines carry one bar per image.
3. Backs up the database (`mariadb-dump` inside the container, streamed
   through zstd) with the `.env` and the state, then prunes the backups
   beyond `--keep`.
4. Pulls the images of the release, one progress bar per image, and checks
   that each one carries the digest the manifest lists. The site keeps
   running during this step.
5. Downloads the bundle, checks its sha256, keeps the files of the running
   version under `kvsctl/releases/<version>/`, and lays the new files over
   the installation. Only release files are touched: `.env`, the KVS
   archive, GeoIP, the rendered nginx configuration and the staged dumps are
   never in a bundle. `.env` gains the settings the release introduced
   (from its `docker/.env.example`, values untouched), the variant images of
   the site's PHP series (`KVS_PHP_FPM_IMAGE`, `KVS_CRON_IMAGE`), and the
   release override at the end of `COMPOSE_FILE`, after the operator's own
   `docker-compose.override.yml` when there is one, so every
   `docker compose` command, by hand or from the scripts, uses the pinned
   images from then on.
6. `docker compose up -d` recreates what changed.
7. Verifies, for up to two minutes (`--health-timeout`): every container of
   the project must run, pass its health check when it has one, and stay
   up; then the site must answer below 400 for `/` and `/admin/` through
   the published port, with the host the site is served under. A container
   that keeps restarting ends the wait at once, even when its entrypoint
   runs for a while before failing. When MariaDB alone is still starting
   after a series change, the wait extends to `--db-timeout` (30 minutes),
   because upgrading the data files takes as long as the database is big.
8. If anything in 5 to 7 fails: the release files come back only when they
   were laid, compose restarts the previous images (still on the machine)
   only when the containers were recreated, the database is restored only
   then and only when the release declared a change or `--restore-db` was
   given, and the site is verified again. Every decision is logged. The
   command exits 4 when the previous version is back, 5 when the rollback
   failed too.
9. Records the new version, the previous one, the checksums of the release
   files and the history in `kvsctl/state.json`, and `KVS_STACK_VERSION`
   in `.env`.

An adopted installation is a git checkout made by `kvs-install.sh`. Once
`kvsctl` manages it, do not run `kvs-install.sh` again on it: its update
path does a `git pull` that fights with the release files.

## What blocks an upgrade

`check` lists them, `upgrade` refuses with exit 3, and nothing is touched:

- a release in between requires a stop (`min_from`); the whole chain is
  printed, `0.1.0 -> 0.2.0 -> 0.3.0 -> 0.4.0`, not one refusal at a time;
- the release publishes no image for the PHP series this site runs, or,
  for a release without variants, runs another series than the one the
  IonCube files were encoded for;
- the site's KVS is older than the release supports;
- the release moves MariaDB to another series: the data files are
  upgraded in place and the previous server cannot open them again, so
  `--allow-mariadb-upgrade` is needed, `--skip-backup` is then refused,
  and a rollback restores the backup. A release also names the series its
  image upgrades from (`mariadb_from`): MariaDB moves one series at a
  time, and a stack two series behind is told to install a release in
  between;
- the release needs a newer Docker Compose than the machine has
  (`compose_min`: `build: !reset null` in the override needs 2.24.0);
- a release file was edited on the machine since the version was laid
  (the checksums taken at adopt or upgrade say which ones): the upgrade
  would overwrite the edit, `--allow-local-changes` accepts that;
- the disk is short: the pull needs twice the download plus 1 GiB free
  where the engine keeps its images, the bundle three times its size plus
  200 MiB under the installation.

## Rollbacks

An automatic rollback undoes what the failed upgrade did, and only that.
`kvsctl rollback` returns to the previous version by hand: the files kept
under `kvsctl/releases/<previous>/` come back, the variant images of the
previous version are written back to `.env`, the release override leaves
`COMPOSE_FILE` when the previous version had none, compose restarts the
previous images, and the database is replayed from the newest backup of
the previous version when the installed release changed it or
`--restore-db` is given. The backup is found before anything is touched;
without one, the command stops and says so.

A one-way release (a MariaDB series change, or `one_way` in the manifest)
cannot be undone by restarting the previous images: the previous MariaDB
would not open the upgraded data files. Its rollback stops mariadb, moves
the data files into a dated folder inside their volume
(`.kvsctl-rollback-<date>`, never deleted by `kvsctl`), starts the previous
image on a fresh directory, waits for it, and replays the dump. The folder
is left for the operator to remove once the site is checked.

## Backups

`backups/backup-<version>-<date>.tar` holds `backup.json` (the version, the
domain, the tool that wrote it), the `.env`, the state and
`database.sql.zst`, the dump streamed through zstd as it is taken so the
disk never holds two copies. `restore` replays one; `--env` also writes its
`.env` over the live one, `--no-backup` skips the backup of the current
database that a restore takes first. The `.tar.zst` archives written by
the proof of concept still restore. `backup --keep N` and `upgrade --keep N`
remove the oldest beyond `N`, never the one just taken.

## Making a release (maintainers)

[docs/releasing.md](../docs/releasing.md) is the runbook: a tag builds the
images for every PHP series, packages the bundle, signs the manifest with
the key held in the repository secrets and publishes the release. The tool
behind it, `kvsctl-release`, can also run by hand; the private key never
enters the repository:

```text
kvsctl-release keygen --out keys/
kvsctl-release bundle --repo . --ref v26.11.0 --version 26.11.0 \
    --images "nginx=ghcr.io/.../nginx:26.11.0,php-fpm@8.1=ghcr.io/.../php:26.11.0-php8.1,cron@8.1=...,manticore=..." \
    --digests "nginx=sha256:...,php-fpm@8.1=sha256:...,..." \
    --out kvs-stack-26.11.0.tar.gz
kvsctl-release manifest --key keys/release.key --out site/ --version 26.11.0 \
    --bundle kvs-stack-26.11.0.tar.gz --bundle-url https://.../kvs-stack-26.11.0.tar.gz \
    --images "nginx=...,php-fpm@8.1=...,cron@8.1=...,manticore=..." \
    --php-series 8.1,8.2,8.3,8.4 --min-from 26.9.0 --kvs-min 7.0.0 --compose-min 2.24.0 \
    --notes-file RELEASE_NOTES.md --notes-url https://.../releases/tag/v26.11.0 \
    --previous site/manifest.json \
    --cli linux-amd64=https://.../kvsctl-linux-amd64 --assets dist/
kvsctl-release verify --manifest site/manifest.json --signature site/manifest.json.sig --pub <base64>
```

An image given as `service@series=ref` is a variant, filed under
`variants.php[series]`; a plain `service=ref` is pinned directly. The
digests, the layers and the sizes come from the registry itself, so the
progress bars are right from the first second and a swapped image is
refused after the pull. `--key` repeated signs with several keys (a
rotation), `--announce-key id=base64@date` announces the next one,
`--one-way`, `--mariadb-from` and `--database migrates` describe what the
release does to the database.

## The lab

`lab/lab-images.sh` turns the images a running instance built into three
versions in a local registry: the running one, a derived one with a layer
of 64 MB of random bytes (a real download), and one whose php-fpm refuses
to start. The derived versions are removed from the engine after the push,
so the upgrade pulls them as it would from a public registry. With the
bundles built from this tree and a signed manifest served from a local HTTP
server, the scenarios below ran against a real KVS 7.0.2 site with IonCube,
PHP 8.1, Manticore and MariaDB 11.8 on a 1 GB VM.

The manifest of the lab lists four releases: 0.2.0 (php-fpm and cron as
PHP 8.1 variants, notes, highlights, a changelog link, `compose_min`),
0.3.0 (a php-fpm that refuses to start), 0.4.0 (PHP 8.3 variants only) and
0.5.0 (MariaDB moved to the 11.4 series, one way, signed by two keys, a
third key announced for December). A second copy listing only 0.2.0 stands
in for a stale mirror.

- `adopt --version 0.1.0` kept and checksummed 62 release files. `check`
  printed the table of the four services with the running image, the
  release image and 67 MB to download each, the notes and the highlights,
  the Compose line, the announced signing key, and `Ready`. Against 0.4.0
  it said `release 0.4.0 publishes no image for PHP 8.1 (it publishes
  8.3)` and `upgrade` exited 3 without touching a container.
- A line appended to `README.md` made `check` report `1 of 62 changed
  since 0.1.0: README.md`, `upgrade` exit 3, `--allow-local-changes` show
  `Ready` again; the file put back, the blocker went. Two `backup` runs at
  once: the second exited 6 with `another kvsctl is running (pid ...,
  backup, started just now)`.
- With `COMPOSE_FILE` and `USE_WWW` removed from `.env` and an operator
  `docker-compose.override.yml` setting a variable on php-fpm, 0.1.0 to
  0.2.0 took 48 seconds: backup of 127 tables as a 446 kB `.tar` with four
  members, 269 MB pulled, 67 files laid, `COMPOSE_FILE` rebuilt as
  `docker-compose.yml:docker-compose.override.yml:docker-compose.release.yml`,
  `USE_WWW`, `PHP_FPM_BASE` and `PHP_CLI_BASE` merged in, `KVS_PHP_FPM_IMAGE`
  and `KVS_CRON_IMAGE` written, the variable of the override visible in
  the php container, the five health checks green, `/` and `/admin/` at
  200. Interactively the same upgrade shows one bar per image and ends on
  `Done`.
- 0.2.0 to 0.3.0 failed in 63 seconds and exited 4: the crash loop was
  caught, the variant keys of 0.3.0 were removed from `.env` and the ones
  of 0.2.0 written back, the 67 files of 0.2.0 laid again, the database
  left alone (`0.3.0 does not change the database`), and the site
  answered 200. `clean --dry-run` then listed the four images of 0.3.0,
  its release files and the downloads, 5.67 GB, and `clean --yes` removed
  them.
- The stale copy of the manifest made `check` exit 7 with `manifest is
  older than the one seen on ...`; `--allow-stale-manifest` read it.
- `check --version 0.5.0` showed `mariadb 11.8 -> 11.4, 73 MB`, `Database:
  MariaDB changes series` and `Rollback: one way`, and blocked;
  `--allow-mariadb-upgrade --skip-backup` was refused. Accepted, the
  upgrade took 20 seconds, and 11.4 opened the 11.8 data files. The
  rollback stopped mariadb, moved the data files to
  `.kvsctl-rollback-<date>` inside the volume, started 11.8 on a fresh
  directory, replayed the dump and verified the site: 35 seconds, 127
  tables before and after.
- `rollback` to 0.1.0 took 18 seconds (37 on the interactive screen) and
  left the setup-built images running, the release override out of
  `COMPOSE_FILE` and the operator's override in place; Ctrl-C at its
  confirmation changed nothing. A second `rollback` was refused: `the
  previous version 0.2.0 is newer than the installed 0.1.0: a rollback
  only goes back`.
- `restore --latest --yes` replayed the newest backup after taking one
  (15 seconds); `backup --keep 2` removed three; `update-cli` replaced the
  0.2.0 build by the one release 0.5.0 ships and said `nothing to do` the
  second time; `version --check` agreed.

## Not done yet

- Images published by the CI on a registry and the manifest signed with
  the project's key: the workflow exists and has not run; the lab registry
  and a throwaway key stand in for them.
- The multi-site layout (Caddy and several sites): `kvsctl` refuses it.

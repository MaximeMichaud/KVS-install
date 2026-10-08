# kvsctl

`kvsctl` upgrades the single-site KVS Docker stack that `kvs-install.sh`
installs, from the signed releases of this repository. An upgrade backs up
the database, pulls the images of the release while the site keeps running,
lays the release files, restarts the stack, checks the containers and the
site, and rolls back by itself when the new version does not come up. It
runs as root on the server of the stack.

## What it is, and what it is not

A release of the stack is the Docker side of an installation: the images of
nginx, PHP-FPM, cron, Manticore, MariaDB and the init service, pinned by
digest, and the files of this repository at that version (compose files,
configuration, scripts). It is not KVS: KVS updates itself from its admin
panel. `kvsctl` never changes the files of the site. It dumps the database
for its backups, and replaces it only by replaying a backup, in a rollback
or a restore.

`kvsctl` is not:

- an installer: `kvs-install.sh` installs the stack, and `kvsctl adopt` takes
  it over;
- a tool for the multi-site layout: on an installation with several sites
  (`MODE=multi` in `docker/.env`, or a `docker/multi-site/sites` directory
  that is not empty) it stops with
  `multi-site installations are not supported by kvsctl yet`;
- an off-site backup: its archives stay in `backups/` of the installation,
  on the same disk as the database. Copy them elsewhere;
- a monitor: it looks at the stack when it runs, never in between.

It sends nothing about the server anywhere. It downloads the signed
manifest, the release bundles and its own builds from GitHub, and the images
from their registries.

## Installing kvsctl

You need:

- an x86_64 server: the release images are built for linux/amd64 only, and
  `kvsctl` refuses to upgrade a stack whose Docker engine runs on another
  architecture;
- Docker Engine 19.03 or newer (Engine API 1.40), and the Docker Compose
  plugin: `setup.sh` needs 2.10.0 or newer for the stack, and a release asks
  for 2.19.0 (`compose_min`), the first that applies the
  `build: !reset null` with which the release override clears the build
  sections (2.18 reads it as a build from a directory named `null`); once
  the release override is there, `setup.sh` asks for 2.19.0 too.
  `kvsctl check` says when the machine is short of either;
- root: `kvsctl` reads and writes the installation and talks to the Docker
  engine.

`kvsctl` talks to the engine the `docker` CLI of the machine uses:
`DOCKER_HOST`, else the context `DOCKER_CONTEXT` names, else the current
context of the CLI configuration, else the default socket. A context that
reaches its engine over TLS, or through ssh, is refused: set `DOCKER_HOST`
to the engine of the stack. `kvsctl status` and `kvsctl check` name the
engine when it is not `unix:///var/run/docker.sock`.

As root, take the binary of the latest stable release with the checksums
published next to it, and check it before installing it:

```sh
cd "$(mktemp -d)"
curl -fsSLO https://github.com/MaximeMichaud/KVS-install/releases/latest/download/kvsctl-linux-amd64
curl -fsSLO https://github.com/MaximeMichaud/KVS-install/releases/latest/download/SHA256SUMS
sha256sum --check --ignore-missing SHA256SUMS
install -m 0755 kvsctl-linux-amd64 /usr/local/bin/kvsctl
kvsctl version
```

`sha256sum` must answer `kvsctl-linux-amd64: OK`; on any other answer, do
not install the file. GitHub never marks a release candidate as the latest
release, so these URLs serve the latest stable one. From then on,
`kvsctl update-cli` replaces the binary with the build of the latest stable
release (see [Commands that write](#commands-that-write)), and
`kvsctl version --check` says whether that one is newer.

`kvsctl` looks for the installation in `/opt/kvs`, where `kvs-install.sh`
puts it. `--root DIR`, or `KVS_INSTALL_DIR=DIR` in the environment, name
another one.

## Taking over a stack

A stack that `kvs-install.sh` installed is a git checkout. `kvsctl adopt`
records it once, and `kvsctl check` then says what an upgrade would do:

```sh
kvsctl adopt
kvsctl check
```

The version recorded is the one `docker/RELEASE` names when the checkout has
that file, else the release tag at the commit of the checkout, else `0.0.0`;
`--version V` names it instead. `kvsctl` shows `0.0.0` as
`unreleased checkout <commit>`, and only the records keep `0.0.0`: the
state, the journal, the history as `kvsctl history` prints it,
`KVS_STACK_VERSION` in `docker/.env`, the backups and
`kvsctl/releases/0.0.0/`. `adopt` keeps the release files, the files git
tracks as they are on disk, in `kvsctl/releases/<version>/` for a rollback,
and records the commit, its date and the checksums of the files as
committed. It records the images the checkout built, those of the services
of a profile that is off included, as the images of that version:
`kvsctl clean` removes them once upgrades have left that version behind.
The files that differ from the commit are listed: `kvsctl check` reports
them as local changes, and `kvsctl upgrade` overwrites them only with
`--allow-local-changes`. A `docker/php/php.ini` that differs from the
commit by the JIT block the setup used to append, and nothing else, counts
as unchanged.

An upgrade never takes an adopted checkout back in time: while the stack
runs the files it was adopted with, a release whose commit is older than the
commit of the checkout is refused, unless the release was cut from that very
commit, and neither the reminder nor `kvsctl status` offers it.
`adopt --force` records the stack again, as long as `kvsctl` has not
upgraded it. Once the stack is recorded, `kvs-install.sh` no longer updates
it, and upgrades go through `kvsctl`.

The first upgrade changes how the stack runs. A checkout builds the images
of nginx, PHP-FPM, cron, Manticore and the init service on the server; a
release runs the images it pins by digest, for every service. That upgrade
lays the release override, `docker-compose.release.yml`, whose
`build: !reset null` clears the `build` sections of the base compose file.
It sets `COMPOSE_FILE` in `docker/.env`, which a checkout leaves unset, so
that compose loads the override last, after the operator's override when
there is one: the first of `compose.override.yml`, `compose.override.yaml`,
`docker-compose.override.yml` and `docker-compose.override.yaml` found in
`docker/`, the one compose loads by itself while `COMPOSE_FILE` is unset.
It also writes the images of the PHP and MariaDB series of the stack
(`KVS_PHP_FPM_IMAGE`, `KVS_CRON_IMAGE`, `KVS_MARIADB_IMAGE`). Compose then
recreates the containers on the release images. From then on, do not run
`kvs-install.sh` on the stack: it refuses an installation `kvsctl` records,
and the files of a branch would not match the images the release pins.

A rollback of that first upgrade returns to the checkout: its files come
back, `COMPOSE_FILE` is unset again and the image settings go. When the
first upgrade applies the release the checkout was adopted at, the files of
the checkout are kept in `kvsctl/checkout/<version>/` for that rollback.

## Commands

### Flags of every command

- `--root DIR`: the installation (default `/opt/kvs`, or `$KVS_INSTALL_DIR`).
- `--manifest URL`: the release manifest, `https://`, `http://` or `file://`
  (default `$KVSCTL_MANIFEST_URL`, else the manifest of the latest release of
  this repository). The default URL serves stable releases only: every
  command refuses the list of a release candidate there. A release candidate
  is a GitHub pre-release; to try one, point `--manifest` at its
  `manifest.json` and name it with `--version` (see [Releases](#releases)).
- `--yes`, `-y`: answer yes to every question. Unless stdin and stdout are
  both a terminal, a question is answered no at once, and stderr says to
  pass `--yes`: cron jobs, scripts and runs whose output goes to a file pass
  it. On the interactive screen only `y` answers yes; Enter and any other
  key answer no.
- `--plain`: print lines instead of the interactive screen of `upgrade`,
  `rollback` and `recover`. Unless both stdin and stdout are a terminal,
  lines are printed anyway.
- `--quiet`: skip the reminder that a newer stable release exists, and name
  the log of a run only in the message of a failure. What each command
  prints then:
  - `upgrade`, `rollback` and `recover` print lines instead of the screen,
    only their steps, their failures, their questions, each question after
    what it asks about, and what the operator must act on (services that
    could not be started again, a `.env` taken from an archive); an upgrade
    with nothing to do prints nothing, and one that is blocked prints its
    blockers alone;
  - `backup`, `clean`, `adopt` and `update-cli` print nothing unless they
    fail or ask, a question after what it asks about, and `clean --dry-run`
    its list;
  - `restore` prints its warnings, its question, what became of `.env`, the
    services it could not start again and its result line; the description
    of an archive named on the command line or by `--latest`, and the
    progress of the backup and of the replay, go to the log alone;
  - `status`, `check`, `releases`, `history`, `logs` and `version` print
    what they print without it;
  - the notice that `KVSCTL_RELEASE_KEY` replaces the release keys is
    printed all the same.
- `--allow-stale-manifest`: accept a manifest older than the newest one
  already read from the same URL (see [Troubleshooting](#troubleshooting)).

When `adopt`, `backup`, `clean`, `history`, `logs`, `releases`, `restore`
or `rollback` succeeds on a recorded stack, it then says on stderr whether a
newer stable release than the installed one exists, and what to run about
it: `26.11.0 is available, run 'kvsctl check'`, which says whether
`kvsctl upgrade` can install it and ends with the command to run. What has
to come first is named instead: `run 'kvsctl recover' first` after an
interrupted run, `run 'kvsctl check' once the kvsctl running now ends`
while another run holds the lock,
`run 'kvsctl check --version 26.10.3' first` when a release on the way has
to be installed first, and `run 'kvsctl check' once the cause is fixed`
after the upgrade to that release failed. The `kvsctl check` of these lines
repeats `--root`, `--manifest` and `--allow-stale-manifest` when they were
given; `kvsctl recover`, which reads no manifest, repeats `--root` alone. A
release candidate is never announced, nor a release older than the git
checkout of an adopted stack, and when this `kvsctl` can no longer read the
manifest, it says so, with `run 'kvsctl update-cli'`. `upgrade`, `recover`,
`update-cli` and `version` say nothing of it, `status` and `check` say it
themselves, and `--quiet` skips it. The manifest is read for it at most
once a day and waited for 5 seconds at most, and a read that failed is not
tried again by the same `kvsctl` build for an hour, both kept in
`kvsctl/update-check.json`.

`KVSCTL_RELEASE_KEY` in the environment replaces the public keys built into
`kvsctl`, the ones a manifest must be signed with, for a test lab that signs
its own manifests. While it is set, every run log says so, and so does
stderr whenever a manifest is checked with those keys:
`release keys from KVSCTL_RELEASE_KEY, not the ones this build embeds`. It
has no place on a production server.

### Commands that only read

- `kvsctl status`: the installed stack, line by line. It runs while another
  `kvsctl` holds the lock and changes nothing; a Ctrl-C while it reads the
  manifest ends it with exit 1.
  - First, a run that did not finish: `Running`, another `kvsctl` at work,
    with the phase its journal names; `Locked`, a `kvsctl` that has ended
    while a docker command it started still holds the lock; `Failed`, a run
    that failed and left its journal, with when and why; `Interrupted`, a
    run cut short. The last two wait for `kvsctl recover`.
  - The site with its KVS, PHP and IonCube; the stack version and the
    previous one, or that the stack is not recorded yet; the engine when it
    is not `unix:///var/run/docker.sock`; the MariaDB series and the version
    of its server.
  - `Override`, when the override compose loads by itself, the first of
    `compose.override.yml`, `compose.override.yaml`,
    `docker-compose.override.yml` and `docker-compose.override.yaml` in
    `docker/`, exists and `COMPOSE_FILE` does not load it, so compose
    ignores it. The next upgrade or rollback adds it to `COMPOSE_FILE`,
    unless the list already names an override under another of those
    names: it then has to be added by hand.
  - `Rollback`, when images of the previous version are no longer on the
    machine: a rollback pulls them first, and is refused while the registry
    cannot be reached.
  - One line per service with the image it runs and its state, then, when
    every service is stopped, a `Stopped` line with the
    `docker compose up -d` that starts the stack. When the compose project
    has no container, a `Services` line takes their place and says that the
    stack is down, with that same command, or, when its MariaDB container
    exists all the same, to check `COMPOSE_PROJECT_NAME` in `.env`.
  - `Last upgrade`, when the last upgrade failed, was cancelled or was
    interrupted and was rolled back: when, its cause and its log.
  - `Updates`: whether a newer stable release exists, and what to run about
    it, as the reminder says it; a release candidate is never announced. It
    waits 15 seconds at most for the manifest.
  - `Signing key`, when the manifest announces a signing key this build
    does not carry: run `kvsctl update-cli` before the rotation.
- `kvsctl check`, with `--version V`, `--mariadb-series S`,
  `--allow-unhealthy` and `--allow-local-changes` as for `upgrade`: what
  `kvsctl upgrade` would do with the same flags. It reads the signed
  manifest and the bundle of the target, downloaded no further than the
  size the manifest signs and checked against its sha256, for the files the
  upgrade would lay and the services its compose file runs here; nothing of
  the bundle is kept. It prints the installed version, the latest stable
  release of the manifest and a newer release candidate, the target, the
  notes of every release it installs, the image every service runs against
  the one the release pins, and what is left to download. A `Disk` line per
  filesystem follows, with what is free there, what the upgrade needs and
  what that is made of, then a `not measured` line for each need it could
  not measure, with why: such a need blocks nothing, and `kvsctl upgrade`
  says it again before its question. Then the PHP, KVS and Compose the
  release needs against what the site and the machine have, what happens to
  MariaDB, the engine, what happens to the database, the health of the
  services or, when none of them runs, why and what to do, as `status` says
  it, the release files edited on this machine, the last upgrade when it
  failed, was cancelled or was interrupted and was rolled back, and what
  blocks the upgrade, or `Ready` with the `kvsctl upgrade` command to run,
  the flags given to `check` included, once the `kvsctl` that holds the
  lock has ended when one does. The stack is not touched, and it exits 0
  whether the upgrade is blocked or not.
- `kvsctl releases [--json]`: the releases of the manifest, newest first,
  each with its day in UTC, the PHP series it publishes images for, the
  oldest version it upgrades from directly (`min_from`), what it does to the
  database and its notes. The latest stable release is marked `latest`,
  each release candidate `release candidate`, and the installed one `*`.
- `kvsctl history [--json]`: what `kvsctl` did to this stack, oldest first:
  the adopt, every upgrade and every rollback, one line each with its date
  in UTC, the version the stack was left on and a note. The line
  of a rollback that undid a run says which version that run went to, how it
  ended (it failed, was cancelled or was interrupted) and why. `--json`
  prints the entries, and gives that run as `undid`: its `action`, the
  version it went `to`, its `outcome` (`failed`, `cancelled` or
  `interrupted`) and its `cause`. An entry an older `kvsctl` wrote has no
  `undid` and says it in its note alone.
- `kvsctl logs [service] [--tail N] [-f]`: the logs of the stack, or of one
  service, through `docker compose logs`: the last `N` lines of each (200),
  then, with `-f`, the new ones until Ctrl-C.
- `kvsctl version [--check]`: the build; with `--check`, whether the latest
  stable release ships a newer one.

### Commands that write

- `kvsctl upgrade`: upgrade to the latest stable release, or to
  `--version V`, see [What an upgrade does](#what-an-upgrade-does).
  - `--version V`: the release to install (default the latest stable
    release, or the release candidate the stack runs when the manifest lists
    it and no stable release is newer; any other release candidate only
    when named). A stack that runs a release newer than the latest stable
    one, a release candidate the manifest no longer lists, has nothing to
    upgrade to: without `--version`, the upgrade says so and exits 0.
  - `--mariadb-series S`: move MariaDB to that series, see
    [MariaDB series](#mariadb-series).
  - `--skip-backup`: no backup first, so a failed upgrade cannot replay the
    database. Refused when the upgrade is one way.
  - `--restore-db`: have a rollback replay the backup even when the releases
    change nothing in the database.
  - `--allow-unhealthy`: upgrade a stack whose services are not all healthy
    now, and leave those services out of the verification. MariaDB cannot be
    left out, and a stack none of whose services runs has to be started
    first.
  - `--allow-local-changes`: overwrite the release files edited on this
    machine since the installed version was laid down.
  - `--keep N`: how many backups to keep in `backups/`, the last written
    (5). The one this run takes, and the one a rollback of the installed
    version would replay, are never removed, and `0` keeps only those.
  - `--health-timeout D`: how long the services may stay unhealthy or
    stopped after the restart (2m). A container still starting gets the
    window its own health check declares.
  - `--db-timeout D`: how long MariaDB alone may take to be ready (default
    30m when its series changes, 10m otherwise).
- `kvsctl rollback`: return to the previous version, see
  [Rollbacks](#rollbacks).
  - `--restore-db`: replay the archive the upgrade took even when the
    installed release changed nothing in the database.
  - `--no-backup`: no backup of the live database before the replay: what
    was written since the archive is then lost.
  - `--allow-unhealthy`: leave out of the verification the services that are
    unhealthy, restarting or stopped when the rollback begins.
  - `--health-timeout D`, `--db-timeout D`: as for `upgrade`.
- `kvsctl recover`: finish or undo the run `kvsctl/journal.json` names, an
  upgrade, a rollback or a restore, see
  [Interruptions](#interruptions-the-journal-and-recover).
  `--health-timeout D` and `--db-timeout D` as for `upgrade`.
- `kvsctl backup [--keep N]`: back up the database and the configuration to
  `backups/`, see [Backups](#backups), then keep the `N` last written
  archives (5), and always the new one and the one a rollback would replay;
  `0` keeps only those two.
- `kvsctl restore [archive] [--latest] [--env] [--other-site] [--no-backup]`:
  replay the database of an archive, see [Backups](#backups).
  `--health-timeout D` and `--db-timeout D` as for `upgrade`.
- `kvsctl adopt [--version V] [--force]`: record a stack `kvs-install.sh`
  installed, see [Taking over a stack](#taking-over-a-stack).
- `kvsctl clean [--dry-run]`: remove what earlier upgrades left behind: the
  images of the versions that are neither installed nor the one a rollback
  returns to, every image of their releases, the ones of a profile that is
  off included; the release files kept for those versions; and the bundles
  downloaded in `kvsctl/downloads/`. An image a container still uses is
  kept. It lists them with their size and asks first; `--dry-run` only
  lists. A removal that fails does not stop the others, and `clean` then
  exits 1 with what it reclaimed.
- `kvsctl update-cli [--version V]`: replace this binary with the build the
  latest stable release ships, or the one of the release `--version` names,
  a release candidate included. The download stops past the size the signed
  manifest gives (128 MiB when it gives none) and must match its sha256, and
  its `version` has to run within 10 seconds and name that release before it
  takes the place of this binary, which is kept as `<path>.previous`. It
  reads only the part of the manifest every `kvsctl` reads, so it also works
  on a manifest of a newer format, which `check` and `upgrade` send it to.
  It needs no installation; on a machine that holds one, it refuses while a
  run is interrupted, and holds the manifest to the newest one read from the
  same URL as `upgrade` does.

`upgrade`, `rollback`, `recover`, `backup`, `restore`, `adopt` and `clean`
take the lock of the installation (`kvsctl/lock`) before they read its
state. A second one exits 6 and says which run holds it:
`another kvsctl is running (pid 1234, upgrade, started 3 minutes ago)`. The
lock is a `flock`, which a run that dies, whatever the way, never leaves
behind; the docker commands a run started hold it too, until they end, so a
run killed while `docker compose` works leaves the lock to that command,
and no second compose starts beside it. `kvs-install.sh`, `docker/setup.sh`
and `docker/reconfigure.sh` change nothing while a run holds the lock.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | done |
| 1 | an error or a refusal, which may come after part of the change of a backup, a clean or an adopt, or after a restore whose database is replayed and whose stack is not healthy |
| 2 | the command line is wrong |
| 3 | the upgrade is blocked and nothing was touched (`kvsctl check` says why) |
| 4 | the upgrade failed and the previous version is back and healthy |
| 5 | a rollback failed (the automatic one, or a manual one part way), or a restore stopped part way: the stack is in an unknown state, read the log |
| 6 | another `kvsctl` holds the lock of the installation |
| 7 | the manifest is older than the one already seen |
| 8 | the change succeeded but could not be recorded: run `kvsctl recover` |

Every command prints this table at the end of its `--help`. A command that
fails says why on stderr, `kvsctl: <message>`, as its last line: that is the
line a script reads.

## What an upgrade does

1. **Plan.** `kvsctl` reads the manifest, checks its signature against the
   keys it carries, refuses a manifest older than the newest one read from
   that URL, or of a channel that URL does not serve, and takes the target:
   the latest stable release, or `--version`. A target older than the
   installed version is refused: going back is `kvsctl rollback`. The
   installed version itself is applied again only when the images the stack
   would run differ from the ones it runs (another PHP series in `.env`, or
   `--mariadb-series`); otherwise it is already installed. A re-apply keeps
   the version before it as the way back, and one that fails puts back the
   images and the PHP series it ran with. The plan reads the bundle of the
   target as `kvsctl check` does. Any
   [blocker](#what-blocks-an-upgrade) stops the upgrade here, with exit 3.
2. **Confirm.** Every service with the image it runs and the one the
   release pins, and what is left to download; the notes of every release
   the upgrade installs, the ones it skips included, the highlights and the
   link to the changelog; what happens to the database; what the plan could
   not measure on disk. Then the question, unless `--yes`.
3. **Back up.** The database and the configuration go to `backups/` (see
   [Backups](#backups)), unless `--skip-backup`; the archives beyond
   `--keep` go, the last written kept.
4. **Pull.** The images of the services compose runs here are pulled by
   digest, and each must carry the digest the manifest lists; the site keeps
   running. Those services are the ones compose runs now and the ones the
   compose file of the target runs with the `COMPOSE_PROFILES` of the stack,
   so a service the release adds, or takes out of a profile that is off, is
   pulled here, before anything changes. The image of a service whose
   profile is off is not pulled: the release override pins it by digest, and
   compose pulls that digest the day the service is turned on. An image the
   container of its service already runs under another name (the same
   digest from a mirror, for instance) is pulled by its digest too, and
   downloads nothing. Up to here, a failure or Ctrl-C leaves the stack as it
   was.
5. **Apply.** The bundle is downloaded to `kvsctl/downloads/`, no further
   than the size the signed manifest gives, and checked against its sha256,
   and the files of the running version are kept in
   `kvsctl/releases/<version>/` for a rollback. `kvsctl` then writes the
   journal of the run, `kvsctl/journal.json`, and lays the release files
   over the installation, without following links, removing the release
   files the new version no longer ships. Only release files: `docker/.env`,
   the files of the site, the database and the backups are never part of a
   release. `docker/.env` gains the settings the release adds (from its
   `docker/.env.example`, the values already there kept), the image of each
   variant (`KVS_PHP_FPM_IMAGE`, `KVS_CRON_IMAGE`, `KVS_MARIADB_IMAGE`), and
   a `COMPOSE_FILE` that ends with the release override,
   `docker-compose.release.yml`, after the operator's override when there is
   one. Every `docker compose` command, run by hand or by the scripts, uses
   the pinned images from then on. When something of the operator's stands
   where the release lays its files (a link on their way, a file where a
   directory goes, a directory of its own files where a file goes), the lay
   refuses before its first change: the run ends with exit 1 and what to
   move, its journal goes, and the stack keeps its version, with nothing to
   roll back.
6. **Restart.** `docker compose config` reads the project first: an error
   in the files or in `.env` fails before any container changed. The
   containers of the services the release drops are removed, then
   `docker compose up -d` runs; when the MariaDB image changes, MariaDB comes
   up alone first and the other services once it is healthy, within the
   database wait (`--db-timeout`), which the log names.
7. **Verify.** Only the containers of the services compose runs here are
   judged, and Docker's health state decides: running and healthy, or
   running without a health check, passes. A container still starting gets
   the window its health check declares; one that is unhealthy, stopped or
   missing fails the upgrade once `--health-timeout` has passed; one that
   keeps restarting fails it at once. While MariaDB alone is not ready, the
   wait goes on until the database wait ends. Then the site must answer
   `/` and `/admin/` on its published HTTPS port, under its own name, with
   a status below 400; 401 and 403 pass too, as a protected admin. Last,
   every container of an active service, the ones accepted with
   `--allow-unhealthy` aside, must run the image the release pins for it,
   compared by image ID: a container left on another image, by a compose run
   from a shell that exported an older pin for instance, fails the upgrade.
8. **Record.** `kvsctl/state.json` gets the new version, the previous one,
   the release files and their checksums, the archive a rollback would
   replay and the history; `KVS_STACK_VERSION` in `.env` names the version,
   and the journal goes.

Once the journal is written in step 5, a failure, or the first Ctrl-C, makes
the upgrade roll back by itself (see [Rollbacks](#rollbacks)); it exits 4
once the previous version is back and healthy. A lay that refuses, as step 5
says, is the one exception: nothing was changed, and the run ends with
exit 1.

`kvsctl` reads and writes `docker/.env` the way docker compose reads it,
`export` lines, quotes and inline comments included, and refuses an edit
that compose and the shell of the scripts, which source the file, would not
read alike (see [Troubleshooting](#troubleshooting)). It runs compose with
the settings of `docker/.env` alone: a value a shell exported for one of
them, after sourcing an older `.env` for instance, does not reach the
compose commands of `kvsctl`. A `docker compose` run by hand from such a
shell still takes the exported value: open a new shell.

### What blocks an upgrade

`kvsctl check` lists every blocker, and `kvsctl upgrade` refuses with exit 3
without touching anything, when:

- a release in between is a required stop (`min_from`): the whole chain is
  printed, `26.9.0 -> 26.10.3 -> 26.11.0`, with the first step to take,
  which the reminder and the `Updates` line of `kvsctl status` name too;
- a release it installs needs a newer `kvsctl` (`kvsctl_min`): the blocker
  names the `kvsctl update-cli` command that installs one, with `--manifest`
  when the manifest is not the default one, and `--version` when no stable
  release ships a `kvsctl` new enough; the plan stops there;
- the release publishes no image for the PHP series of the site; or, for a
  release that ships a single PHP, the site is IonCube encoded for another
  series;
- the site runs a KVS older than the release supports (`kvs_min`);
- the Docker Compose plugin is older than the release needs (`compose_min`),
  or its version cannot be read;
- the Docker engine runs on another architecture than x86_64, or is too old
  for `kvsctl` (Engine API below 1.40);
- the stack is down, none of its services runs: start it with
  `docker compose up -d` in `docker/`;
- the services are not all healthy before the upgrade: a container that is
  unhealthy, restarting or stopped, a service with no container, or one the
  engine restarted less than a minute ago. Repair them, or pass
  `--allow-unhealthy` to leave those services out of the verification;
  MariaDB cannot be left out, since php-fpm and manticore wait for it to be
  healthy;
- release files were edited on the machine since the installed version was
  laid down: copy them aside, or pass `--allow-local-changes`;
- the bundle of the target cannot be read, or a file, a link or a directory
  of the operator's stands where the release lays a file or needs a
  directory: move it away;
- the MariaDB series is unknown, not published by the target, or the series
  change asked for is not allowed (see [MariaDB series](#mariadb-series));
- `--skip-backup` is given for a one-way upgrade;
- a filesystem is short of space: where the pulled layers land (the root of
  containerd with the containerd image store of Docker 29), twice the
  download, and 1 GiB on the root of the engine; under `kvsctl/`, three
  times the bundle and 200 MiB; in `backups/`, the expected size of the
  backup (half again the last one, or half of what the tables take); for a
  one-way upgrade, a fifth more than the database on the filesystem of the
  MariaDB data volume. Directories on the same filesystem add up. A need
  `kvsctl` cannot measure (a size, the data directory or a filesystem it
  cannot read) blocks nothing: `kvsctl check` prints it as `not measured`,
  with why, and `kvsctl upgrade` says it before its question;
- the stack is an adopted checkout newer than the release;
- the state lists no release file of the installed version;
- Docker does not answer, or cannot list the containers of the stack, which
  the plan then says alone; or compose cannot read the project.

## MariaDB series

A stack keeps the MariaDB series it runs. Each release publishes one MariaDB
image per series it supports, and an upgrade installs the image of the
series the stack already runs: the series of the image of its mariadb
container, else the one the server of that image declares, else
`MARIADB_VERSION` in `.env`. When none of them names a series, the upgrade is
blocked until `MARIADB_VERSION` is set.

A series changes only when you ask for it, with
`kvsctl upgrade --mariadb-series S` (`kvsctl check` takes it too). The series
asked for must be published by the target release, newer than the one the
stack runs, and the next one the release publishes after it: MariaDB moves
one series at a time. The new server upgrades the data files in place, and
the previous server cannot open them again, so such an upgrade is one way:
the backup is mandatory, `MARIADB_VERSION` in `.env` follows the new series,
and a rollback replays the backup on a new data directory. A series change
can also apply the installed release again, with only MariaDB moving.

MariaDB never goes back: a series older than the one the stack runs is
refused, and so is a release that pins an older build of the running series
than the one the server runs (`11.8.9` over `11.8.10`). A target that does
not publish the running series blocks the upgrade, and names the release
that can move the stack to the next series first, when the manifest has one.

When the MariaDB image changes, MariaDB starts alone first and the rest of
the stack once it is healthy, so the services that wait for a healthy
database do not give up while the new server upgrades its tables. That wait
lasts up to 30 minutes for a series change and 10 minutes otherwise, or
`--db-timeout`; a container that stops or keeps restarting ends it at once.

## Rollbacks

### The automatic rollback

When an upgrade fails after its first change, it undoes what really
happened, nothing more. The files and the settings come back when they were
laid. Compose restarts the previous images only when it had run, or when
the containers are no longer the ones the upgrade began with (compose run
by hand or by a script after a cut); an image of the previous version the
engine no longer holds is pulled by digest first, and the containers of the
services the failed release added are removed, and only those. The
database is replayed from the backup the upgrade took only when compose had
run and a release installed changes the database or `--restore-db` was
given, or when a one-way upgrade recreated the MariaDB container. A replay
runs with MariaDB the only service up, so nothing writes to the database
meanwhile and the site is down until it is over; the cache (memcached or
Dragonfly) then starts empty, and Manticore rebuilds its indexes from the
replayed database. The stack is then verified again, and every decision
goes to the log. A rollback runs to its end: Ctrl-C does not interrupt it.

The upgrade exits 4 when the previous version is back and healthy. When the
rollback fails too, it exits 5 and leaves the journal, which records when
and why it failed. Its message says why the upgrade failed and why the
rollback failed, with the last line a docker or compose command printed
when one of them failed, then what to do, and ends with the log:

```text
upgrade to 26.11.0 failed: <cause>; the rollback to 26.10.0 failed too: <error>; once the cause is fixed, 'kvsctl recover' runs the rollback again; to finish by hand instead, remove /opt/kvs/kvsctl/journal.json once the stack runs 26.10.0 again; log: /opt/kvs/kvsctl/logs/20261102-140130-upgrade.log
```

When the rollback replays the backup, the way by hand is to remove the
journal and run `kvsctl restore` with that archive once MariaDB runs, and
once the rollback of a one-way upgrade has moved aside the data files the
newer server wrote, the message also says which folder of the MariaDB data
volume keeps them. A rollback that stopped before the files were back, on
images it could not pull or files it could not put back, names
`kvsctl recover` alone.

### kvsctl rollback

`kvsctl rollback` returns to the previous version: the files kept for it
come back (`kvsctl/releases/<previous>/`, or `kvsctl/checkout/<previous>/`
for the checkout a release was applied over), with the images, the PHP
series and the `COMPOSE_FILE` that version ran with, and compose restarts
the previous images. Everything it needs is checked before its first
change. The images of the previous version the engine no longer holds, the
image of a service the installed version dropped included, are pulled by
digest while the site still runs, and a rollback that cannot pull them is
refused; so is one whose files cannot take their place (a link on their
way, or a file of the operator where the previous version lays one of its
own), and one that would leave compose a project it cannot read. When the
installed release changed the database, was one way, or with
`--restore-db`, the archive the upgrade took is replayed (the newest backup
of the previous version when the state names none), after a backup of the
live database, unless `--no-backup`. The services that write are stopped
before that backup and stay stopped until the replay is over, so the site
is down meanwhile. The question says which archive, from when, the KVS
version its database belongs to, and that what was written since is
replaced.

A rollback has no health check before it starts: it is the repair of a
broken upgrade. `--allow-unhealthy` leaves out of its verification the
services that were unhealthy, restarting or stopped when it began. MariaDB
is the exception: one that runs unhealthy or keeps restarting refuses a
rollback that keeps MariaDB as it is, `--allow-unhealthy` or not, since the
services that need it wait for it to be healthy. A rollback that puts back
another MariaDB image or series, or a one-way one, starts MariaDB alone
first and goes on, unless it must back up the live database first: then
repair MariaDB, or pass `--no-backup`. Once its first change is made, it is
not interrupted; one that fails part way exits 5 and keeps its journal, and
`kvsctl recover` returns the stack to the version the rollback started
from. A rollback only goes back: after one, the previous version recorded is
the newer one, and installing it again is `kvsctl upgrade --version V`. It
never moves MariaDB to a newer series either.

### One-way upgrades

A one-way upgrade, a MariaDB series change or a release marked `one_way`,
cannot be undone by restarting the previous images: the previous MariaDB
would not open the upgraded data files. Its rollback stops mariadb, moves the
data files into a dated folder inside their volume,
`.kvsctl-rollback-<yyyymmdd-hhmmss>`, starts the previous image on an empty
data directory, waits for it, and replays the backup. `kvsctl` never deletes
that folder: remove it once the site is checked. When a one-way
`kvsctl rollback` fails or is cut short, `kvsctl recover` moves the data
files back from that folder before it starts the newer version again, and
keeps the files the older server wrote in `<folder>-fresh`: the newer
version never starts on the fresh data directory.

## Interruptions, the journal and recover

The commands that change the stack own Ctrl-C and the termination signals
for their whole run:

- the first Ctrl-C (SIGINT) or SIGTERM says what it does and stops the run
  where it can. An upgrade stops: until it begins to lay the release files
  (the plan, the question, the backup and the pull), nothing was changed,
  and from then on what it changed is rolled back. A rollback or a restore
  stops only before its first change, while it asks the engine, pulls the
  images it needs, stops the services that write or backs up the database:
  it starts again the services it stopped and ends on one line, such as
  `rollback interrupted, nothing was changed, the stack is still on 26.10.0`
  or `restore interrupted during the backup before it, nothing was changed`.
  A recover stops only while it checks the engine, which ends on
  `recover interrupted, nothing was changed`, or asks its question, which
  ends on `recover cancelled, nothing was changed`. Past that, a recover
  runs to its end, and so does a rollback or a restore once it has begun
  changing the stack. A backup removes its unfinished archive
  (`backup interrupted, no archive was kept`), or keeps one already
  complete and leaves the older ones alone; `clean` stops after the removal
  in progress and says what it reclaimed; `adopt` records nothing. The step
  cut short is marked cancelled, and the error of the command it stopped is
  a line of the log, `cancelled: <error>`;
- a second one, or any that comes while a rollback runs, is said and
  ignored: `SIGINT: the rollback is running and is not interrupted`, and the
  same of the replay of a restore, or of the recovery `recover` runs; on the
  interactive screen, Ctrl-C then shows
  `rollback in progress: Ctrl-C does not interrupt it`;
- a terminal or an SSH session that goes away (SIGHUP) stops nothing: the
  screen ends, the run carries on to its end, and its log says how it went;
- the docker commands run in process groups of their own, so a Ctrl-C at
  the terminal reaches `kvsctl` alone;
- a closed output, `kvsctl upgrade | head` for instance, is ignored.

An upgrade, a rollback or a restore that cannot finish, after a power cut, a
`kill -9`, or a rollback or a replay that failed, leaves
`kvsctl/journal.json`: what the run had done, phase by phase. While it is
there, every command but `status`, `version`, `history`, `logs`, `releases`
and `recover` refuses, with the run, its log and what to do, and so do
`kvs-install.sh`, `docker/setup.sh` and `docker/reconfigure.sh`, whose
status options still run:

```text
an upgrade from 26.10.0 to 26.11.0 was interrupted during restart on 2026-11-02 14:05 UTC: run 'kvsctl recover' (its log: /opt/kvs/kvsctl/logs/20261102-140130-upgrade.log)
```

A run that failed, a rollback whose `docker compose up` failed for instance,
is told as one, dated when it failed and with why:

```text
the rollback of an upgrade from 26.10.0 to 26.11.0 failed on 2026-11-02 14:31 UTC: <cause>; once the cause is fixed, run 'kvsctl recover' (its log: /opt/kvs/kvsctl/logs/20261102-140130-upgrade.log)
```

`status` shows the run first.

`kvsctl recover` (`--yes` to skip its question) finishes that run. An
upgrade or a rollback that had passed its verification is recorded, as the
run would have done; any other is rolled back to the version it started
from. Its question says what that rollback does with the database, and why:
the backup is replayed, and what was written since it was taken is
replaced; the data files a one-way rollback moved aside come back; or the
database is left as it is. A run whose rollback failed is told as failed,
with when and why, and `recover` runs that rollback again once the cause is
fixed; the history then keeps both causes. A restore is finished: cut before
its replay, the services it stopped start again; cut during it, the archive
is replayed again, from the start; cut after it, what was left is done.
Then the stack is verified as at the end of a restore.
`recover` tells a run whose compose never started from one whose containers
were brought up by hand since, and finishes a journal an older `kvsctl` left
by the rule of that version. It takes the lock and writes a log like any
other run, and can run again after a failure: every step of a rollback can.
Where it says to finish by hand, its message also says when to remove
`kvsctl/journal.json`.

## Run logs

`upgrade`, `rollback`, `recover`, `backup`, `restore`, `adopt` and `clean`
write a log of their run:
`kvsctl/logs/<yyyymmdd-hhmmss>-<command>.log`, named after its start in UTC,
in a directory only root reads. It holds one timestamped line per event,
every line docker and compose printed, every decision of the run, and its
result: `exit 0`, or `exit 4: ...` with the message. Its path is printed
first (`log: ...`), or under the title of the interactive screen, and again
at the end of the message of exit codes 4, 5 and 8; with `--quiet`, it is
printed only at the end of the message of a run that failed, whatever the
code. The 30 newest logs are kept, and always the one of the run a journal
names. A run that cannot take the lock, or that a journal refuses, writes
no log; `update-cli`, which may run without an installation, writes none.

## Backups

`kvsctl backup`, every upgrade unless `--skip-backup`, and a rollback or a
restore before it replays an older dump write one archive,
`backups/backup-<version>-<yyyymmdd-hhmmss>.tar`, named after its start in
UTC. It holds `database.sql.zst`, the dump of the database compressed with
zstd as it streams out of `mariadb-dump`, so the disk never holds two copies
of it; `.env` and `state.json`, copies of `docker/.env` and
`kvsctl/state.json`; and `backup.json`: the stack version, the KVS version
the site runs (`kvs_version`), the date, a sequence number, the domain, the
sizes of the dump and the `kvsctl` build. The sequence is one more than the
highest of the archives in `backups/`, and orders them: `--latest`,
`--keep` and a rollback that has no archive recorded read that order, which
a clock set wrong does not change.

The dump reads every table at one point: in one transaction when every
table of the site takes part in transactions, and under a lock of every
table of its database when some are MyISAM or Aria, as an installation
imported from an older server keeps; the writes of the site then wait until
the dump ends, and the backup says so. A table emptied or rebuilt while the
dump reads the database (error 1412) starts the dump again, up to three
dumps in all. While the dump streams, the backup stops and removes its partial file
before the free space of its filesystem falls below the larger of 1 GiB and
2 % of its size: the running database may live there too. An archive
reaches the disk before it takes its name, and so does the name: an archive
whose directory could not be flushed once it was named is complete and
stays, and the backup exits 1 with
`<archive> is written but its directory could not be flushed: ...`. A
Ctrl-C that comes once the archive is complete keeps it too, and leaves the
older archives where they are:
`backup interrupted once <archive> was written: the archive is kept, and the older backups were not pruned`.

`kvsctl restore` replays one archive over the running stack: the one named,
the last one written with `--latest`, or the one picked from the list it
prints. It shows what the archive holds, refuses an archive of another site
(its `backup.json` names another domain than `DOMAIN`) unless
`--other-site`, and warns when the archive comes from another stack version,
or holds the database of another KVS version than the site runs, whose
files stay as they are; the question names that KVS version. A MariaDB that
runs unhealthy or keeps restarting refuses the restore. Then it stops every
service but MariaDB, takes a backup of the current database, unless
`--no-backup`, replays the archive, empties the cache, starts the services
again and has Manticore rebuild its indexes: the site is down until the
replay is over. Then it waits for the services to be healthy and for the
site to answer, the verification an upgrade ends with, Manticore given
the time `--db-timeout` gives MariaDB to build its indexes; the services
that were not healthy before the restore began are left out, and the log
names them. It ends with
`<domain> restored from <archive> (stack <version>) in <duration>`. A
stack that does not come up ends the restore with exit 1 and says what is
wrong: the database is restored all the same, and `kvsctl recover` has
nothing to do.

A replay first empties the database of the site, every table, view,
sequence, routine and event, and keeps the database with its character set
and its grants; the dump then creates what it holds, so the database ends as
the archive has it, tables created since gone too, and a replay cut short
can run again from the start. An archive whose dump is empty or cannot be
read is refused before anything is dropped. Once the replay has begun it is
not interrupted, and its progress is printed, unless `--quiet`, which leaves
it to the log. It has no time limit while the server works on it: a long
statement, the index rebuild of a large table, is waited for. It is stopped
once the database took nothing from the dump for 10 minutes and the server
showed no statement of the replay at work in that time: its connection idle,
its statement waiting for a lock another connection keeps (a transaction
left open) or for room on a full disk, or the connection not shown three
times in a row. A replay that is stopped has its connection ended on the
server, so nothing of it runs afterwards; when that fails, the message says
so, and the MariaDB container should be restarted before the archive is
replayed again.

A restore that stops part way exits 5 and leaves the journal, and one that
is cut short, by a power cut or a kill, leaves it too: once the cause is
fixed, `kvsctl recover` finishes the restore, and replays the archive again,
from the start, when its replay had begun and not ended. The message of a
replay that stopped names the backup of the database as it was before.
`--env` also puts back the `.env` of the archive, but keeps the live values
of the settings `kvsctl` manages, `COMPOSE_FILE`, `KVS_STACK_VERSION`, every
`KVS_*_IMAGE`, `PHP_FPM_BASE`, `PHP_CLI_BASE`, and `MARIADB_VERSION` when
`KVS_MARIADB_IMAGE` is set, and of the settings that name the site,
`DOMAIN`, `COMPOSE_PROJECT_NAME` and `SITE_PREFIX`. Both files are read the
way docker compose reads them, an `export` line counting as the setting.
Before anything changes, the restore builds the `.env` it would leave and
checks that compose reads it and that `docker/` takes a new file: a result
compose would not read (an unterminated quote, an invalid `${}`, a
`${VAR:?}` whose `VAR` the merged file no longer sets) refuses the restore
with exit 1, before the backup and the replay. A `.env` that still cannot be
written once the database is replayed exits 5 and leaves the journal:
`kvsctl recover` finishes the restore, and the message says how to do it by
hand. The containers read the restored `.env` at the next
`docker compose up -d`, which the restore names.

`kvs-install.sh`, run again on an installation `kvsctl` does not manage,
keeps `backups/` and `kvsctl/` in its new copy.

## Troubleshooting

- `another kvsctl is running (pid ..., upgrade, started ...)` (exit 6):
  wait for that run; `kvsctl status` shows it.
- `the kvsctl run that holds the lock has ended (...), but a docker command it started still runs and holds it`
  (exit 6): the run was killed while a docker command worked, and that
  command keeps the lock until it ends, so that no second compose runs beside
  it. `fuser -v /opt/kvs/kvsctl/lock` names it: wait for it, then run
  `kvsctl recover` when `kvsctl status` shows an interrupted run. When
  `fuser` names nothing, a check held the lock for a moment (`kvsctl status`,
  or `setup.sh`, `reconfigure.sh` or `kvs-install.sh` looking for a run):
  run the command again.
- `... was interrupted during ...: run 'kvsctl recover'`: a run was cut
  short. Read its log, named in the message, then run `kvsctl recover`.
- `... failed ... on ...: <cause>; once the cause is fixed, run 'kvsctl recover'`:
  a run, or its rollback, stopped on that cause, in the words compose or
  Docker used. Fix it, then run `kvsctl recover`.
- Exit 5: the stack is between two versions, or a restore stopped part way.
  Read the log first: the message says what failed, and how to finish once
  it is fixed (disk space, Docker, a container that does not start). After
  an upgrade, `kvsctl recover` runs the rollback again. After
  `kvsctl rollback`, `kvsctl recover` returns the stack to the version the
  rollback started from. After `kvsctl restore`, `kvsctl recover` finishes
  the restore, and replays the archive again first when its replay had
  begun and not ended.
- Exit 8: the new version runs and the site is healthy, but
  `kvsctl/state.json` could not be written. Fix the cause (a full disk, a
  read-only filesystem), then `kvsctl recover` records it.
- `the stack is down: start it with 'docker compose up -d' in ...`: the
  stack was stopped or taken down. Start it, then run `kvsctl check` again.
- `the stack is not healthy before the upgrade: ...`: an upgrade over a
  failing stack could not tell its own failure from the one already there.
  Repair the services, or pass `--allow-unhealthy`; MariaDB has to be
  repaired first.
- `... release files changed since ... was installed (...)`: copy the edited
  files aside, then run with `--allow-local-changes`, and apply the edit
  again on the new files if it still applies.
- `... cannot lay its files: ...`: a file, a link or a directory of the
  operator's stands where the release lays a file or needs a directory.
  Move it away, then run `kvsctl check` again.
- `... free on the filesystem of ... is not enough`: `kvsctl clean` removes
  what earlier upgrades left, and old archives can go from `backups/`.
- `... needs kvsctl ... or newer, and this is kvsctl ...: run 'kvsctl update-cli ...' first`:
  run the command it names, then the upgrade again.
- `this manifest needs a newer kvsctl (schema ..., this build reads ...): run 'kvsctl update-cli'`:
  the manifest has a format this build does not read. `kvsctl update-cli`
  reads it all the same; run it, then the command again.
- `manifest is older than the one seen on ...` (exit 7): the manifest read
  is older than one already read from the same URL, a stale mirror or a
  replayed file; the list of a release candidate is held to the newest
  stable release seen there, not to its date. Pass `--allow-stale-manifest`
  only when you know why.
- `the manifest at ..., and that URL serves stable releases only: ...`: a
  release candidate was marked as the latest release on GitHub. Wait until
  a stable release is the latest again, or point `--manifest` at the
  manifest of the release to install.
- `manifest signature does not match any release key this kvsctl knows`:
  the manifest is signed with a key this build does not carry, after a
  rotation of the signing key for instance. Install the binary of the
  latest release as in [Installing kvsctl](#installing-kvsctl), then run the command again.
- `this stack has no recorded version: run 'kvsctl adopt' once`: `kvsctl`
  has not taken the stack over yet, see
  [Taking over a stack](#taking-over-a-stack).
- `.../docker/.env: KEY: line N: the shell of the scripts may take NAME= there for a setting ...`,
  or `... the value of NAME ends with a backslash out of quotes ...`: the
  scripts source `docker/.env` with bash, which would read line `N`
  otherwise than docker compose once `kvsctl` edits `KEY`, so `kvsctl`
  leaves the file as it is. Write each setting of that line as
  `KEY="value"` on a line of its own, or put the value that ends with a
  backslash in quotes, then run the command again.
- `the Docker Engine of this machine speaks API 1.39, and kvsctl needs API 1.40 or newer`:
  upgrade Docker to 19.03 or newer.
- `kvsctl cannot talk to the Docker engine`: start Docker.
- `the docker context "..." (...) reaches its engine over TLS, ...`, or
  `... through ssh, ...`: set `DOCKER_HOST` to the engine of the stack, or
  run `kvsctl` on the machine of the engine.
- Every command waits 5 seconds before it prints anything in a terminal:
  the terminal answers neither of the two queries the screen library sends
  when `kvsctl` starts, for the background colour and for the cursor
  position. `TERM=dumb` skips both.

## Releases

A release is a calendar version, `YY.M.PATCH`: `26.10.0`, then `26.10.1`. A
release candidate carries a suffix, `26.11.0-rc1`, and sorts before its
release. The manifest entry of a release carries the bundle with its sha256
and its size, every image with its digest, its layers and their sizes (which
is how the download size is known before the pull), the `kvsctl` build it
ships with its sha256 and its size, the PHP and MariaDB series it publishes,
what it requires (`min_from`, `kvs_min`, `compose_min`, and `kvsctl_min`,
the oldest `kvsctl` that may install it), whether it changes the database
(`database: migrates`) or is one way (`one_way`), one line of notes, up to
three highlights and a link to the changelog. The manifest is signed with
Ed25519; it can announce the key of a coming rotation, which `kvsctl check`
and `kvsctl status` then name when this build does not carry it yet.

The manifest of a release is signed into the `stable` channel. A release
candidate is a GitHub pre-release, never marked as the latest release: its
manifest is the stable list of the day with the candidate added, signed into
the `candidate` channel. Try one on a lab installation by naming both:

```sh
kvsctl check --manifest https://github.com/MaximeMichaud/KVS-install/releases/download/26.11.0-rc1/manifest.json --version 26.11.0-rc1
kvsctl upgrade --manifest https://github.com/MaximeMichaud/KVS-install/releases/download/26.11.0-rc1/manifest.json --version 26.11.0-rc1
```

When a candidate asks for its own `kvsctl` (`kvsctl_min`), `check` and
`upgrade` stop with the
`kvsctl update-cli --manifest ... --version 26.11.0-rc1` that installs it.
`kvsctl` remembers the newest manifest it read for each URL, so
reading the list of a candidate never makes the stable channel look stale,
and an installation on a candidate moves to its release with a plain
`kvsctl upgrade` once it is out.

Making a release is described in [docs/releasing.md](../docs/releasing.md).

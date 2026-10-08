# Releasing the stack

This is the runbook for publishing a release of the Docker stack: its images,
the bundle of its files, and the signed manifest `kvsctl` reads. It is not
about KVS itself, which updates from its own admin panel.

A release is a calendar version, `YY.M.PATCH`. `26.10.0` is the first release
of October 2026, `26.10.1` the next patch that month, `26.1.0` a January
release with no leading zero. The git tag is the version itself, with no `v`
in front, so the tag, the manifest version and the image tags are the same
string. A release candidate carries a suffix of lower case letters and an
optional number, `26.11.0-rc1`, and is published as a GitHub pre-release. The
workflow refuses a tag of any other form, and a tag starting with `v` does
not even start it.

## What a release run does

Pushing a tag runs `.github/workflows/release.yml` as it is in the tagged
commit. It has six stages.

1. **prepare** checks the tag, refuses a version that already has a GitHub
   release, or whose release GitHub could not say anything about, and
   checks `.github/release.env` and the manifest the release will extend,
   the one of the latest release: its signature, that it is the stable
   list, and that it lists the stop `MIN_FROM` names. The publish job checks
   that manifest again before it extends it. Then prepare writes the release
   notes.
2. **tests** runs, on the tagged commit, the checks a pull request runs:
   the `kvsctl` workflow (gofmt, vet, `go test -race`, `govulncheck`, the
   build) and the `tests` workflow (the base of every Dockerfile, and the
   image the compose files run for `phpmyadmin-init`, against
   `docker/images.lock`, then every shell suite of `tests/`, the release
   scripts included). The kvsctl tests compare how `kvsctl` and the
   `docker compose` of the runner read a `.env`, `docker/.env.example`
   included, and run the check of the publish job below on a scratch
   release of the compose file and the lock of the commit. The suites run
   as uid 1000, the owner the stack gives the site's files, through
   `.github/scripts/as-uid-1000.sh`: the runner user is uid 1001. They run
   on GNU coreutils, those of the Debian releases the stack supports, and
   the suites of the release scripts run once more on the coreutils the
   runner comes with, uutils from Ubuntu 26.04 on, which the release jobs
   run them with. The jobs below wait
   for both, so a commit whose tests fail never pushes an image.
3. **signing keys** runs in the `release` environment, so it waits for an
   approval. It reads each signing secret with `kvsctl-release`, the way the
   publish job signs with it, and checks that its public half is a key of
   `ReleasePublicKey` in the tagged commit, and that a key `ANNOUNCE_KEY`
   names is one of them. It refuses a `ReleasePublicKey` that lists
   `c23d8b96`, the key `kvsctl` was developed with, whatever the secrets
   hold (step 2 of the one-time setup). The images wait for it: a secret
   `kvsctl-release` cannot sign with, or a key the released `kvsctl` would
   not trust, stops the run before anything is pushed.
4. **images** builds eleven linux/amd64 images and pushes them to GHCR:
   `nginx`, `init` and `manticore` once, tagged with the version, and `php`
   and `cron` once per PHP series from 8.1 to 8.4, tagged
   `<version>-php<series>`. It records the digest the registry gave each one.
5. **kvsctl** builds `kvsctl` and `kvsctl-release` for linux/amd64 with the
   exact Go release `cli/go.mod` names, and writes `SHA256SUMS`.
6. **publish** runs in the `release` environment too, and waits for a second
   approval. It downloads the manifest of the latest stable release
   and checks its signature with the keys `kvsctl` embeds, and that it lists
   the newest stack release, which the GitHub API names: the newest
   published stable release that carries the assets of this workflow. Only
   when there is none is a missing manifest the first release. It builds the
   bundle, whose compose override pins every image by digest. It reads every
   image back from its registry without credentials, as a server with none
   would, and stops when a digest differs from the one the build reported or
   `docker/images.lock` holds. It signs the new manifest, which is the
   previous one with this release added, and checks that every signature of
   it matches a key of `ReleasePublicKey` in the tagged commit. Then the
   `kvsctl` the release ships has to name its own version and list the
   release from that manifest, which it reads with the keys it embeds alone.
   `TestShippedRelease` (`cli/cmd/kvsctl-release/shipped_test.go`) checks
   the bundle and the `kvsctl` builds the way `kvsctl` downloads them, each
   build against the size the manifest signs for it, and
   runs the upgrade plan of `kvsctl`, from the same commit, for every pair of
   a PHP and a MariaDB series the release publishes: the images it picks and
   the `.env` keys it writes have to be the ones the compose override of the
   bundle runs and reads. Only then does it create the GitHub release: every
   asset goes to a draft, which is published last.

The release carries `manifest.json`, `manifest.json.sig`,
`kvs-stack-<version>.tar.gz`, `kvsctl-linux-amd64`,
`kvsctl-release-linux-amd64` and `SHA256SUMS`, with the release notes as its
description. A stable release is marked as the latest one, which is the
release every `kvsctl` reads by default:
`https://github.com/MaximeMichaud/KVS-install/releases/latest/download/manifest.json`.

One run goes at a time. A manifest extends the one of the latest release, so
two runs publishing together would start from the same manifest and the
second would drop the release of the first. A run started while another one
is in progress waits for it. GitHub keeps a single waiting run: a third run
cancels the one that was waiting, which then has to be started again (Re-run
all jobs on its page).

## One-time setup

1. **Generate the signing key outside the checkout.**

   ```sh
   cd cli && go run ./cmd/kvsctl-release keygen --out ~/kvsctl-release-keys
   ```

   `release.key` is the private key (PKCS8 PEM), `release.pub` its public
   half in base64, and the command prints the key id. Neither file belongs in
   the repository. `.gitignore` ignores `keys/` and `*.key`, but only as a
   safety net. `keygen` refuses a directory that already holds a key, so it
   never replaces one.

2. **Put the public key in `kvsctl`.** Replace the value of
   `ReleasePublicKey` in `cli/cmd/kvsctl/main.go` with the content of
   `release.pub`, in a commit that comes before the first tag. Every
   installed `kvsctl` verifies the manifest with the keys of that string,
   and the signing keys job refuses a secret whose key it does not list,
   before any image is pushed. In this repository the string holds the
   release key, `eab0209b`. Before it, the string held `c23d8b96`, the key
   `kvsctl` was developed with, whose private half is not kept as a release
   key is: the signing keys job refuses every release whose
   `ReleasePublicKey` lists it.
   Keep it a single string on one line, with its
   `// pragma: allowlist secret` comment: the workflow reads the keys from
   that line (`.github/scripts/release-public-keys.sh`), and the comment
   keeps the detect-secrets hook from taking the key for a secret.

3. **Create the `release` environment before the first tag.** In the
   repository settings, under Environments, create an environment named
   `release`. Add yourself under Required reviewers, and leave Prevent
   self-review off if you are the only reviewer, or nobody can approve a
   run. Under Environment secrets, add `KVSCTL_RELEASE_KEY` holding the whole
   content of `release.key`, its BEGIN and END lines included, and nothing
   else. The signing keys job and the publish job then each wait for an
   approval and cannot read the secret before it. A tag pushed before the
   environment exists makes GitHub create it with no protection and no
   secret: the signing keys job then stops, before any image is pushed.

4. **Keep an offline copy of `release.key`**, in a password manager for
   instance. Without it, no later manifest can be signed with a key the
   installed binaries trust, and every installed `kvsctl` would have to be
   replaced by hand.

5. **Make the five GHCR packages public during the first run.** The first
   run creates the container packages `nginx`, `init`, `manticore`, `php` and
   `cron` under `ghcr.io/<owner>/kvs-install/` (the repository name in lower
   case), and GitHub makes a package private when it is first published. The
   publish job reads the images without credentials, as `kvsctl` does on a
   server that has none, so it fails on a private package. Once the images
   job is done and the publish job waits for its approval, open each package
   from the Packages tab of the account that owns the repository, then
   Package settings, Danger Zone, Change visibility, Public, and only then
   approve. If the job was approved too early, it fails with a message naming
   the image: make the package public and re-run the failed job. A public
   package cannot be made private again. Later releases push new versions
   into the same packages, so this is done once.

`secrets.GITHUB_TOKEN` does the rest: with `packages: write` the images job
pushes the images, and with `contents: write` the publish job lists the
releases, creates the new one and publishes it.

Release immutability (Settings, General, Releases) may be on. GitHub then
accepts an asset only before a release is published, and the workflow
uploads every asset to a draft first: the release action drafts a stable
release and publishes it after the uploads itself, and a candidate is
created as a draft and published by the last step of the publish job, with
the GitHub CLI of the runner. With it on, the assets and the tag of a
published release can never change again, which is the rule of [A bad
release](#a-bad-release) anyway.

## Cutting a release

1. **Refresh `docker/images.lock`.**

   ```sh
   docker/bin/resolve-bases.sh          # rewrite the lock
   docker/bin/resolve-bases.sh --check  # or only compare it with the registries
   ```

   The tags are a human decision and live in the tables at the top of that
   script: bump a tag there, run the script, review the diff, commit. The
   script also moves the base default of each Dockerfile to the entry of its
   name and series (`php-fpm 8.1`, `php-cli 8.1`, `nginx`, `debian`,
   `manticore`), and the image of `phpmyadmin-init` in
   `docker/docker-compose.yml` and
   `docker/multi-site/docker-compose.site.yml.template` to the `alpine`
   entry, so the diff covers the lock, those Dockerfiles and those two
   compose files. `--check`, which the weekly lock check runs, and
   `--check-dockerfiles`, which the tests workflow runs, fail when a
   Dockerfile default or that image is not the lock's. The lock pins the
   bases the images are built on, and the images the stack runs unchanged
   (MariaDB, memcached, Dragonfly, acme.sh, Alpine). The publish job reads
   each of the latter from its registry by tag and stops when the digest
   differs from the lock, so a tag rebuilt upstream since the lock was
   written stops the release (see [When a run fails](#when-a-run-fails)). A
   MariaDB patch moves through that table as well: a stack that already
   runs a newer patch of its series than a release pins is blocked until a
   release pins that patch or a newer one.

2. **Edit `.github/release.env`** in the commit the tag will point at. The
   publish job writes it into the manifest:

   - `NOTES`, required: the one line `kvsctl` shows beside the version.
     Write it again for every release, or the line of the previous one is
     repeated.
   - `HIGHLIGHT_1` to `HIGHLIGHT_3`: up to three more lines, which
     `kvsctl upgrade` shows on its confirmation screen and `kvsctl check`
     beside the release. Optional, one line each, and written again or
     emptied for every release, like `NOTES`.
   - `MIN_FROM`: empty, unless the release is a [required
     stop](#a-required-stop).
   - `DATABASE`: `none`, or `migrates` when the release changes the
     database.
   - `ONE_WAY`: `false`, or `true` when restarting the previous images
     cannot undo the release.
   - `KVSCTL_MIN`: empty, unless the release [needs a newer
     kvsctl](#a-release-that-needs-a-newer-kvsctl).
   - `KVS_MIN` and `COMPOSE_MIN` rarely move. `COMPOSE_MIN` is 2.19.0, the
     first Docker Compose that applies `build: !reset null`, with which the
     release override clears the build sections of the compose file: 2.18
     reads it as a build from a directory named `null`, and fails to build
     it. `docker/setup.sh` asks the same version of an installation
     `kvsctl` manages, and a suite keeps the two equal.
   - `ANNOUNCE_KEY`: empty, except during a [key
     rotation](#rotating-the-signing-key).

   The prepare job checks the file before anything is built, and refuses
   every value `kvsctl-release` would refuse when it signs, such as a
   version with a leading zero in one of its numbers (`2.024.0`), a day that
   is not in the calendar (`2026-02-30`), a highlight over two lines or of
   blanks only, or a `KVSCTL_MIN` newer than the release. It then checks
   `MIN_FROM` against the manifest of the latest release, which has to list
   it, and the signing keys job checks `ANNOUNCE_KEY` against the secrets.
   The check of the file is a script you can run first:

   ```sh
   .github/scripts/release-env.sh 26.11.0
   ```

3. **Tag a commit of main and push the tag.**

   ```sh
   git tag -a 26.11.0 -m 26.11.0
   git push origin 26.11.0
   ```

   The run uses the workflow, the scripts and the files of the tagged
   commit. The bundle holds that commit's `docker/` and `conf/` directories,
   `kvs-install.sh`, `kvs-export.sh`, `README.md` and `LICENSE`, and `kvsctl`
   lays it over an installed stack, removing the files the previous release
   had and this one lacks. A tag on a branch that is behind main would
   publish a stack without main's newer files.

4. **Approve the two jobs of the `release` environment**: the signing keys
   job when the run waits for it, right after prepare, and the publish job
   once the images and kvsctl jobs are green.

5. **Check the result.** The release page lists the six files above. On a
   lab installation, `kvsctl check` shows the new version, its images and the
   size of the download.

## Release notes

The prepare job writes the description of the GitHub release with git-cliff
and `cliff.toml`, from the Conventional Commit subjects: everything since the
previous stable release, grouped by type, breaking changes first. A
candidate and the release it leads to cover the same span, so the notes of
`26.11.0-rc2` and of `26.11.0` both start at the last `26.10` release, and a
tag pushed later never changes the notes of an earlier run started again.
The first stable release lists the whole history.

The manifest only carries the line of `NOTES`, the highlights, and a link to
the release page, because `kvsctl` downloads it at every check.

## Release candidates

A candidate is tagged the same way, `26.11.0-rc1`. It is published as a
GitHub pre-release and never marked as the latest release, so the stable
channel every `kvsctl` reads by default keeps serving the newest stable
release. The manifest of a candidate is the stable manifest of the day with
the candidate added, signed into the `candidate` channel, where a release
is signed into the `stable` one: at the URL of the latest release, every
`kvsctl` command that reads the manifest refuses the list of a candidate.
`kvsctl check`, `kvsctl upgrade`, `kvsctl update-cli`,
`kvsctl version --check` and `kvsctl releases` stop on it, and
`kvsctl status` says it could not check for updates, so even a candidate
marked as the latest release by mistake is not taken for the stable list.
Try it on a lab installation by pointing `kvsctl` at it and naming the
candidate, since `kvsctl` goes to the newest stable release of a manifest
unless told otherwise:

```sh
kvsctl check --manifest https://github.com/MaximeMichaud/KVS-install/releases/download/26.11.0-rc1/manifest.json --version 26.11.0-rc1
kvsctl upgrade --manifest https://github.com/MaximeMichaud/KVS-install/releases/download/26.11.0-rc1/manifest.json --version 26.11.0-rc1
```

A candidate that asks for its own `kvsctl` (see [A release that needs a
newer kvsctl](#a-release-that-needs-a-newer-kvsctl)) stops `kvsctl check`
and `kvsctl upgrade` on an older `kvsctl` with the command that installs
that `kvsctl` first:

```sh
kvsctl update-cli --manifest https://github.com/MaximeMichaud/KVS-install/releases/download/26.11.0-rc1/manifest.json --version 26.11.0-rc1
```

`update-cli` installs the `kvsctl` of the newest stable release of the
manifest unless `--version` names another release of it, a candidate
included.

`kvsctl` remembers the newest manifest it has seen for each manifest URL, so
reading a candidate this way never makes the stable channel look stale. A
candidate sorts before its release, so an installation on `26.11.0-rc1`
moves to `26.11.0` with a plain `kvsctl upgrade` once it is out.

A candidate is created as a draft, gets its assets, and is published by the
last step of the publish job. A run that stops in between leaves a draft,
which no `kvsctl` sees: re-run the failed job, which uploads the assets
again and publishes it.

A candidate pushes its own images (`26.11.0-rc1`, `26.11.0-rc1-php8.3` and so
on), and the release builds and pushes its own as well. When the last
candidate is good, tag the release on its commit:

```sh
git tag -a 26.11.0 -m 26.11.0 "26.11.0-rc2^{commit}"
git push origin 26.11.0
```

The release then reads the `.github/release.env` of the candidate, so write
its `NOTES` and highlights for the release, not for the candidate. A
`KVSCTL_MIN` naming the release, `26.11.0`, makes each candidate of it ask
for its own `kvsctl` instead, `26.11.0-rc1` for the first one: that is the
only `kvsctl` of that version until the release is out.

## MariaDB series

A stack keeps the MariaDB series it runs. Every release publishes one MariaDB
image per series of `docker/images.lock` (`variants.mariadb` in the
manifest), and `kvsctl` writes the one of the stack's series to `.env` as
`KVS_MARIADB_IMAGE`, so an upgrade never moves a database to another series
by itself.

- **Adding a series:** add its line to `RUNTIME_IMAGES` in
  `docker/bin/resolve-bases.sh`, the way the existing MariaDB lines are
  written, then run the script and commit the lock. The next release
  publishes it.
- **Retiring a series:** remove its line, but only after a release has
  published it together with the series that follows it, so a stack still
  on it has a release to move up with.
- **Moving a stack** to another series is a decision of its operator:
  `kvsctl upgrade --mariadb-series <series>`, after
  `kvsctl check --mariadb-series <series>` to see the plan. It goes one
  series at a time, to the next one the release publishes, never
  backwards, and the backup is mandatory. MariaDB upgrades the data files in
  place, so `kvsctl` treats such an upgrade as one way and a rollback
  replays the backup. No flag of `.github/release.env` is needed for it.
- **A series a release no longer publishes:** `kvsctl` blocks the upgrade of
  a stack still on it and names the way out, the newest release that
  publishes both that series and the next one:
  `kvsctl upgrade --version <that release> --mariadb-series <next series>`.

## Only stack releases

Every release of this repository is a stack release, made by the release
workflow. Never publish another kind by hand, such as installer notes or an
announcement: GitHub marks a new release that is not a pre-release as the
latest one by default, and the latest release is where every `kvsctl` reads
its manifest. Every `kvsctl` then gets a 404 for it until a stack release is
the latest one again.

The publish job refuses to go on in that state, since a manifest built on
the wrong release would drop every release before it. It names the release
GitHub marks as the latest one. Mark the newest stack release as the latest
one again: open it on the Releases page, Edit, tick "Set as the latest
release", Update release, or with the GitHub CLI:

```sh
gh release edit 26.11.0 --latest
```

Then re-run the failed job. The same applies when an edit marked an older
stack release as the latest one. GitHub never marks a pre-release as the
latest one: when the newest stack release was turned into a pre-release by
hand, the message says so, and the same edit unticks "Set as a pre-release":

```sh
gh release edit 26.11.0 --prerelease=false --latest
```

Never delete or replace an asset of a stack release either. The next release
extends the `manifest.json` of the newest stack release, so when that file is
gone the publish job stops and names the release, rather than build on an
older manifest that lacks it. Upload the same file again, from a copy
downloaded before, once `kvsctl-release verify` accepts it (see [Checking a
release](#checking-a-release)). Without a copy, that manifest has to be
signed again by hand, from the manifest of the release before it, with the
arguments the publish job of that release used. Release immutability makes
the deletion impossible in the first place.

## A required stop

`MIN_FROM` is the oldest version allowed to upgrade straight to the release.
From anything older, `kvsctl` refuses the jump and prints the chain of
releases to go through. Set it when the release relies on something an
earlier release does to the installations it upgrades.

```sh
# .github/release.env of 26.11.0, which nothing older than 26.10.3 may jump to
MIN_FROM=26.10.3
```

The stop has to be a published release, since every older installation
upgrades to it first: the prepare job refuses a version the manifest of
the latest release does not list, before any image is pushed, and names
the newest releases it holds. `kvsctl-release` refuses it again when it
signs.

A stop is part of its release, and every later manifest carries it
unchanged. When a published stop turns out too old, give the next release
the right one: `kvsctl` takes the stop of every release an upgrade covers,
so an upgrade to that release, or past it, goes through the right stop. Only
an explicit `--version` of the release with the wrong stop still skips it. A
stop newer than needed costs the installations below it one more upgrade
and nothing else.

A release that changes the database or is one way does not need to be a
stop: when an upgrade jumps over releases, it migrates and is one way as soon
as one of the releases it covers is.

## A release that changes the database

`DATABASE=migrates` says the release changes the database: a rollback then
restores the backup instead of only restarting the previous images.
`ONE_WAY=true` says restarting the previous images cannot undo the release at
all: `kvsctl` refuses `--skip-backup`, and a rollback recreates the MariaDB
data directory and replays the backup.

```sh
# .github/release.env
DATABASE=migrates
ONE_WAY=true
```

A MariaDB series change needs neither: each stack asks for its own, and
`kvsctl` handles it as one way by itself (see [MariaDB
series](#mariadb-series)).

## A release that needs a newer kvsctl

`KVSCTL_MIN` names the oldest `kvsctl` that may install the release. Set it
when the release relies on something only a newer `kvsctl` does, a field of
the manifest an older one would ignore for instance: `kvsctl check` and
`kvsctl upgrade` on an older one stop and ask for `kvsctl update-cli` first.

```sh
# .github/release.env of 26.11.0, which only the kvsctl of 26.11.0 installs
KVSCTL_MIN=26.11.0
```

It is at most the version of the release, whose own `kvsctl` is the newest
one `update-cli` can install: the prepare job refuses a newer one. Every
later manifest carries the minimum of each release unchanged, and an
upgrade that goes through several releases needs the highest minimum among
them.

## When a run fails

Nothing reaches `kvsctl` before the publish job creates the GitHub release,
so a failed run is fixed and run again.

- **prepare** failed on the tag, on `.github/release.env` or on the
  manifest of the latest release, or **tests** failed: nothing was pushed
  yet. When the fix is a new commit, delete the tag and tag again:

  ```sh
  git push --delete origin 26.11.0
  git tag -d 26.11.0
  ```

  - "could not check whether release 26.11.0 already exists" means the
    GitHub API answered neither 200 nor 404, or nothing at all: re-run the
    failed job.
  - "MIN_FROM in .github/release.env is 26.10.9, which the manifest of the
    latest release does not list": the stop is not a published release
    (see [A required stop](#a-required-stop)). Correct it in a new commit.
  - "the manifest of the latest release is of channel 'candidate', not
    stable": a candidate is marked as the latest release. Mark the newest
    stable release as the latest one again ([Only stack
    releases](#only-stack-releases)) and re-run the failed job.
  - "the previous manifest does not verify": the manifest of the latest
    release is not signed by any key the tagged commit trusts. Find out why
    before anything else.
  - "manifest.json answered 404, but 26.10.0 is a stack release", or "the
    manifest of the latest release does not list 26.10.0": GitHub marks
    another release as the latest one, and the message names it. Mark the
    newest stack release as the latest one again, clearing its pre-release
    flag first when the message says it has one ([Only stack
    releases](#only-stack-releases)), and re-run the failed job.
  - "26.10.0, the newest stack release, carries no manifest.json any more":
    that asset was deleted. Upload it again ([Only stack
    releases](#only-stack-releases)) and re-run the failed job.
  - "returned HTTP" with a status other than 200 or 404, "incomplete: curl
    exit", or "is not a list of releases": GitHub failed, cut its answer
    short or sent something else. Re-run the failed job.
  - `TestComposeParity` or `TestComposeResolvesWhatKvsctlReads` failed on a
    commit whose pull request passed: the runner image moved to another
    `docker compose`, which no longer reads a `.env` the way `kvsctl` does.
    The test prints the difference, or the message of a compose that
    refused the file; fix it in a new commit and tag again.

- **signing keys** failed: nothing was pushed yet.

  - "ReleasePublicKey in cli/cmd/kvsctl/main.go lists c23d8b96, the key
    kvsctl was developed with": step 2 of the one-time setup was not done.
    Do it in a new commit and tag again.
  - "the release environment has no KVSCTL_RELEASE_KEY secret": add it (step
    3 of the one-time setup) and re-run the failed job.
  - "KVSCTL_RELEASE_KEY is not a key kvsctl-release can sign with", with the
    reason `kvsctl-release` gives: the secret holds something else than
    `release.key` as `keygen` wrote it, such as the public half pasted
    before it as a PEM block, `BEGIN PUBLIC KEY` as `openssl pkey -pubout`
    prints it ("asn1: structure error"), or a copy whose line ends were
    changed to CRLF and that lost its last line feed ("release key is not
    PEM"). Put the whole content of `release.key` in the secret and re-run
    the failed job. The same goes for `KVSCTL_RELEASE_KEY_NEXT`.
  - "KVSCTL_RELEASE_KEY is the key ..., which ReleasePublicKey in
    cli/cmd/kvsctl/main.go does not list": the secret is not a key the
    tagged commit trusts, and every signature it made would be refused. Put
    the right key in the secret and re-run the failed job, or, when
    `ReleasePublicKey` is the wrong one, fix it in a new commit and tag
    again. The same goes for `KVSCTL_RELEASE_KEY_NEXT`, which only a commit
    listing the new key in `ReleasePublicKey` may be released with.
  - "ANNOUNCE_KEY ... announces the key ..., and no signing secret is that
    key": the `release` environment has no `KVSCTL_RELEASE_KEY_NEXT`
    holding the announced key. Add it and re-run the failed job (see
    [Rotating the signing key](#rotating-the-signing-key)).

- **images** or **kvsctl** failed on something transient, such as a network
  or registry error: re-run the failed jobs. When the fix needs a new commit,
  release the next patch instead. Some images were already pushed under this
  version, and a tag on another commit would replace them under the same
  image tags.

- **publish** failed. Nothing was published, but the images are pushed under
  the version, so a fix that needs a new commit is the next patch. Its log
  says why:

  - "GHCR does not show this image to an anonymous reader": the package is
    private. Make it public (step 5 of the one-time setup) and re-run the
    failed job.
  - "the build reported sha256:... and the registry answers sha256:..." for
    MariaDB, memcached, Dragonfly, acme.sh or Alpine: the tag was rebuilt
    upstream since the lock was written. Refresh the lock, commit it and
    release the next patch.
  - "the manifest would be ... and kvsctl reads at most 8.0 MiB": see [The
    size of the manifest](#the-size-of-the-manifest).
  - "the kvsctl of the release says ...", an error of `kvsctl releases`,
    or a failure of `TestShippedRelease`, one line per problem, such as
    "MariaDB 11.8 and PHP 8.1: the override reads KVS_MARIADB_IMAGE for
    mariadb, which kvsctl does not write": the `kvsctl` this release ships
    could not install it. Fix the cause and release the next patch.
  - A message of the prepare or the signing keys job above, the
    `kvsctl-release` forms included ("--min-from 26.10.9 names no release of
    the manifest", "--announce-key ...: no --key is that key", "signature 1
    of 2: manifest signature does not match any release key this kvsctl
    knows"): the latest release or a secret changed after those jobs ran.
    The same fixes apply, then re-run the failed job.
  - "the image list names no image for ... of docker/docker-compose.yml": a
    service was added to the compose file without its image in
    `.github/scripts/release-images.sh`. The tests workflow reports it on the
    pull request; fix it and release the next patch.

## Checking a release

Anyone can check what a release ships, without the signing key:

```bash
kvsctl-release verify --manifest manifest.json --signature manifest.json.sig \
    --pub "<a key of ReleasePublicKey in cli/cmd/kvsctl/main.go>"
mkdir bundle && tar -xzf kvs-stack-26.11.0.tar.gz -C bundle
mkdir tree && git archive 26.11.0 docker conf kvs-export.sh kvs-install.sh README.md LICENSE | tar -x -C tree
diff -r tree bundle
```

The only files the bundle adds to the tag are `docker/RELEASE` and
`docker/docker-compose.release.yml`, whose images carry the digests the
manifest lists. The bundle is reproducible: every member carries the time of
the tagged commit, so running the bundle step of the publish job again on
the tag, with the same image list, gives the sha256 the manifest signs. That
time is also the date of the release in the manifest, which `kvsctl`
compares with the commit of a git checkout it adopted: it never lays a
release over a checkout made after it.

## A bad release

Never delete a published release. `kvsctl` remembers the newest manifest it
has seen and refuses an older one as stale, which protects it from a frozen
or replayed copy. Deleting the newest release would make `releases/latest`
serve the previous manifest, which every `kvsctl` that already saw the bad
one refuses (exit code 7) until a newer release exists. Publish a fix
release instead, the next patch, and say in its `NOTES` what it replaces:
an upgrade goes to the latest release by default, so the installations on the
bad release move on and the others skip it.

Do not move a tag either. The prepare job refuses a version that already has
a release, and anyone who fetched the old manifest would hold a different
file under the same version.

**The images stay.** The manifest of the release that shipped them records
their digests, and a machine may have to pull them again, after its image
cache was pruned or the server rebuilt. Delete one only if running it is
dangerous, and say so in the notes of the fix release.

## Rotating the signing key

A manifest cannot introduce the key it is signed with: that would prove
nothing. A binary that trusts the new key has to reach the installations
first, from a manifest signed with the old one. `kvsctl` accepts a manifest
as soon as one of its signatures matches a key it embeds, and the publish
job checks that every signature matches a key the released binary embeds,
so a rotation takes several releases.

1. **Announce.** Generate the new key outside the checkout, as in the
   one-time setup but into another directory, for instance
   `~/kvsctl-release-keys-next`. In one commit, add its public
   half to `ReleasePublicKey` after the current key, comma separated, and
   set `ANNOUNCE_KEY` in `.github/release.env` to `ID=BASE64@YYYY-MM-DD`: the
   key id keygen printed, the public key, and the day the new key will sign
   alone. Add the new private key to the `release` environment as the secret
   `KVSCTL_RELEASE_KEY_NEXT`, then cut a release. It is signed with both
   keys, its `kvsctl` trusts both, and on an older binary `kvsctl status`
   and `kvsctl check` say that the manifest announces a key it does not know
   and to run `kvsctl update-cli`.
2. **Wait.** Keep `ANNOUNCE_KEY` and both secrets for every release until
   that day: a manifest announces only what its own `.github/release.env`
   says.
3. **Switch.** Put the new private key in `KVSCTL_RELEASE_KEY`, delete
   `KVSCTL_RELEASE_KEY_NEXT`, empty `ANNOUNCE_KEY`, remove the old key from
   `ReleasePublicKey`, and cut a release. It is signed with the new key
   alone. A `kvsctl` that never updated stops at a signature error naming
   the new key id, and its operator installs the new binary by hand from the
   release page.

Two rules keep the workflow green during a rotation. `KVSCTL_RELEASE_KEY_NEXT`
may only exist while the tagged commit lists the new key in
`ReleasePublicKey`, or the signing keys job refuses it. And the release
before the switch must be signed with the new key too, because the switch
checks the previous manifest with the keys of its own commit, which no
longer include the old one: the announced releases are signed with both
keys for that reason. The signing keys job checks this one at the
announcement, before any image is pushed, and `kvsctl-release` refuses to
sign a manifest that announces a key it is not signed with: a forgotten
`KVSCTL_RELEASE_KEY_NEXT` stops the first announcing release instead of the
switch.

Keep the old private key offline after the switch: the binaries released
before it still trust it.

`KVSCTL_RELEASE_KEY` in the environment of an installed `kvsctl` replaces
the whole list of keys it trusts. It is meant for a lab that signs its own
manifests, not for adding a key to a production installation.

## The format of the manifest

`schema` is the number of the manifest format. Adding a field never changes
it; a change an older `kvsctl` would read wrongly does, and `kvsctl check`
and `kvsctl upgrade` on that older binary then refuse the manifest and ask
for `kvsctl update-cli`. `update-cli` reads one part of the manifest
whatever its schema, which is how every `kvsctl` already out finds the build
that reads a newer format, so no format may ever change it: `channel`;
`updated`, an RFC3339 time; the `id` and `valid_from` of each key of
`keys`; and for each release its `version` and, for each build of its
`cli`, the `url` and the `sha256`. It also reads the `size` of a build when
it is a number of bytes, the bound of its download: a later format may
leave `size` out or give it another shape, never another meaning as a
number. `schema` stays a number. A release that needs a newer `kvsctl`
without a new format sets `KVSCTL_MIN` instead, which the manifest carries
as `requires.kvsctl_min` (see [A release that needs a newer
kvsctl](#a-release-that-needs-a-newer-kvsctl)).

## The size of the manifest

The manifest lists every release since the first, with the layers of each
of its images, so it only grows, and `kvsctl` reads 8 MiB of it at most: it
refuses a larger one. A release of the current stack lists 18 images and
about 250 layers, which adds about 76 kB, so about 110 releases fit. A new
PHP or MariaDB series adds its images to every release that publishes it.

That limit stays even once a later `kvsctl` reads more. An installation runs
the `kvsctl` it has until `kvsctl update-cli` replaces it, and `update-cli`
reads the manifest before anything else: a manifest over 8 MiB would leave
every installation on an older `kvsctl` with no release to see and no way
to update. The way out is a smaller manifest, never a higher limit in
`kvsctl-release`.

The publish job warns from 6 MiB on, about 27 releases before the limit,
with the number of releases that still fit, and refuses to sign a manifest
larger than 8 MiB. Before that, the oldest releases have to leave the
manifest, which `kvsctl-release` cannot do yet. Such a change has to keep
every release that a kept release names in `MIN_FROM`, since older
installations upgrade to it first, and, for each MariaDB series, the newest
release that publishes it together with a newer one, which is how `kvsctl`
moves a stack off a series the latest release no longer publishes. Writing the
manifest without indentation buys time: it makes it a third smaller, and
every `kvsctl` reads it.

## The weekly lock check

The `docker images` workflow compares `docker/images.lock` with the
registries every Monday at 05:23 UTC, and on demand from the Actions tab
(Run workflow). A failed run means an upstream tag moved, usually for a
security fix in a base image: refresh the lock as described in [Cutting a
release](#cutting-a-release), and cut a release when the change matters.
GitHub disables the scheduled workflows of a public repository after 60 days
without activity; the Actions tab enables them again.

## What the workflow does not do

- It does not sign the container images. `kvsctl` checks the digest of every
  image it pulls against the signed manifest, which is what protects an
  upgrade, and requiring `cosign` on a server that may reach nothing but the
  registry would cost more than it buys. Keyless image signing can be added
  later without touching the client.
- It builds nothing for arm64. The PHP-FPM and cron images build on arm64
  too, with the ionCube loader and yt-dlp of that architecture, and the
  `docker images` workflow builds them there for every PHP series; it
  builds nginx, init and manticore for amd64 only. A release publishes
  linux/amd64 images and `kvsctl` binaries only, and `kvsctl` refuses an
  engine of another architecture.
- It never publishes PHP 7.4, and nothing builds it: the upstream
  `php:7.4-*` images are Debian 11, which lacks packages the PHP-FPM and cron
  images install, and no longer receive security fixes. The lock pins no
  7.4 base, and `setup.sh` refuses a KVS archive that needs PHP 7.4.
- It does not refresh the lock, write `.github/release.env` or choose the
  version: those belong to the commit you tag.
- It deletes nothing, and it creates neither the environment nor its secrets,
  nor does it change the visibility of a package.

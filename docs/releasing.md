# Releasing the stack

This is the runbook for publishing a release of the Docker stack: the images,
the bundle, and the signed manifest `kvsctl` reads. It is not about KVS
itself, which updates from its own admin panel.

A release is a calendar version, `YY.M.PATCH`. `26.10.0` is the first release
of October 2026, `26.10.1` the next patch that month, `26.1.0` a January
release with no leading zero. The git tag is the version with no prefix, so
the tag, the manifest version and the image tag are the same string. A
release candidate carries a suffix, `26.11.0-rc1`, and is published as a
GitHub pre-release.

## One-time setup

1. **Generate the signing key off the build machine.**

   ```sh
   cd cli && go run ./cmd/kvsctl-release keygen --out ../keys
   ```

   `keys/release.key` is the PKCS8 PEM private key, `keys/release.pub` the
   base64 public half. Neither goes into the repository.

2. **Put the public half in the binary.** `ReleasePublicKey` in
   `cli/cmd/kvsctl/main.go` is what every installed `kvsctl` verifies
   against. `.github/scripts/verify-manifest.sh` reads the same constant, so
   the previous manifest is always checked against what the shipped binaries
   hold.

3. **Put the private half in a protected environment.** In the repository
   settings, create an environment named `release` with the required
   reviewers you want, and add a secret `KVSCTL_RELEASE_KEY` holding the
   contents of `keys/release.key`. Only the `publish` job runs in that
   environment, so a pull request build can never reach the key.

4. **Keep an offline copy** of `keys/release.key` in a password manager.
   Losing it means replacing every installed binary by hand.

5. **Make the GHCR packages public, once.** The first `release` run pushes
   five packages, which GHCR creates private. Open each one under the
   organisation or user packages page, Package settings, Change visibility,
   Public. There is no REST endpoint for this, so it cannot be scripted, and
   until it is done `docker pull` asks anonymous users for credentials.
   The packages are `nginx`, `init`, `manticore`, `php` and `cron` under
   `ghcr.io/maximemichaud/kvs-install/`.

Nothing else is needed: `secrets.GITHUB_TOKEN` with `packages: write` pushes
the images, and `contents: write` in the publish job creates the release.

## Cutting a release

1. **Refresh the pins if they are stale.**

   ```sh
   docker/bin/resolve-bases.sh          # rewrite docker/images.lock
   docker/bin/resolve-bases.sh --check  # or just check it
   ```

   The tags themselves live in the tables at the top of that script: bump a
   tag there, run the script, review the diff. A base image digest that moved
   with no tag change is a rebuilt upstream image, which is exactly what a
   release should pick up deliberately rather than by accident.

2. **Write `.github/release.env`** in the same commit as the tag. It is what
   the publish job turns into the `requires` block of the manifest:

   - `MIN_FROM` is empty for an ordinary release.
   - `DATABASE` is `none`, or `migrates` when the release changes the
     database, which makes a rollback restore the backup.
   - `ONE_WAY` is `false`, or `true` when restarting the previous images
     cannot undo the upgrade.
   - `KVS_MIN` and `COMPOSE_MIN` rarely move. `COMPOSE_MIN` is 2.24.0
     because the release override clears the build key with
     `build: !reset null`, which older Compose does not understand.

3. **Tag and push.**

   ```sh
   git tag 26.10.0
   git push origin 26.10.0
   ```

   The workflow validates the tag, refuses a tag that already has a release,
   generates the notes with git-cliff, builds and pushes eleven images
   (nginx, init and manticore once, php and cron once per PHP series 8.1 to
   8.4), builds `kvsctl` and `kvsctl-release` for linux amd64 and arm64,
   verifies the previous manifest, then signs and publishes the new one.

4. **Check the result.** The release page must carry `manifest.json`,
   `manifest.json.sig`, `kvs-stack-<version>.tar.gz`, the four binaries and
   `SHA256SUMS`. On an installed stack, `kvsctl check` must show the new
   version and the download size.

PHP 7.4 is never published. `setup.sh` still offers it for an old KVS
archive and `docker/images.lock` still pins its base so it builds locally,
but the upstream `php:7.4-*` images are unmaintained.

## Marking a required stop

A release that must not be skipped sets `MIN_FROM` to the version just before
it. `kvsctl` then refuses to jump over it and names the intermediate release.
Every one-way release has to be a required stop, or a machine two versions
behind would walk straight into the change it cannot come back from.

```sh
# .github/release.env for 26.11.0, which nobody may skip
MIN_FROM=26.10.3
```

## A one-way release

A release is one way when restarting the previous images does not restore the
previous state. The usual reason is a MariaDB major upgrade: the image runs
`mariadb-upgrade` and rewrites the system tables in place, and the older
server refuses to open the datadir afterwards.

```sh
# .github/release.env
MIN_FROM=26.10.3
DATABASE=migrates
ONE_WAY=true
```

`ONE_WAY=true` makes `--skip-backup` an error rather than a choice, and sends
a rollback down the path that recreates the `mariadb-data` volume, starts the
previous MariaDB on an empty datadir and replays the dump, instead of simply
restarting the old image on an upgraded datadir, which would not start.

Move MariaDB alone. Do not change the PHP series in the same release: two
irreversible changes in one step leave nowhere useful to stop.

## Pulling a bad release

Delete the GitHub release. That is the whole mechanism:
`releases/latest/download/manifest.json` resolves against whichever release
carries the latest flag, so removing the bad one moves the stable channel
back to the previous release, and every `kvsctl status` and `kvsctl check`
stops offering it within a day (the check is cached that long).

```sh
gh release delete 26.10.1 --cleanup-tag
```

Then cut `26.10.2` with the fix. Do not re-tag `26.10.1`: the publish job
refuses a tag that already has a release, and anyone who already fetched the
old manifest would be holding a different file under the same version.

**The images stay.** They are not deleted, for three reasons. A machine that
already upgraded is running them, and deleting the images would break its
next restart and its rollback, which pulls nothing but expects the previous
images to still resolve. The digests are recorded in the manifest of the
release that shipped them, so an image that disappears turns a verifiable
pin into a dead reference. And a GHCR package version cannot be restored once
deleted. Untag them only if they are actively dangerous, and say so in the
notes of the replacement release.

## Rotating the signing key

A new key cannot be announced by a manifest signed with it: that proves
nothing. The rotation takes two releases.

1. **Release N** advertises the next public key in `manifest.keys` as
   information only, and ships a `kvsctl` binary that embeds both keys.
   `kvsctl status` says a new signing key is coming. This release is still
   signed with the old key alone.
2. **Release N+1** is signed with both keys, by passing `--key` twice, so an
   old binary and a new one both verify it. Users run `kvsctl update-cli`,
   which verifies with the old key and installs the binary holding both.
3. **Release N+2** and later are signed with the new key only. Anyone who did
   not update gets a signature failure naming the key id, which is a real
   error and not a silent downgrade.

In practice: generate the new key, add it to `ReleasePublicKey` (comma separated) in
`cli/cmd/kvsctl/main.go`, cut release N; add the new key to the `release`
environment as a second secret and pass both to
`kvsctl-release manifest --key ... --key ...`, cut release N+1; then remove
the old key from the environment and from the binary, and cut N+2.

`KVSCTL_RELEASE_KEY` in the environment of an installed `kvsctl` replaces the
whole trust set. It is a lab escape hatch for the local registry, not a way
to add a key to a production install.

## What the workflow does not do

- It never signs the container images. `kvsctl` verifies image digests after
  the pull, which is what protects the upgrade, and requiring `cosign` on a
  box that may have no outbound access beyond the registry would cost more
  than it buys. Keyless image signing can be added later without touching the
  client.
- It never publishes arm64 service images. The ionCube tarball the
  Dockerfiles fetch is `lin_x86-64`; arm64 needs the `lin_aarch64` tarball
  and is its own change. The `kvsctl` binaries are built for both.
- It never moves a tag. Every image tag carries the release version, and the
  manifest records the digest as well, so a re-pushed tag would be caught.

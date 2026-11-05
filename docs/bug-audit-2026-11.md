# Bug audit, November 2026

Audit of `kvs-install.sh`, `kvs-export.sh`, the Go CLI (`cli/`, kvsctl) and the
Docker stack (`docker/`: `setup.sh`, the import libraries, `reconfigure.sh`,
multi-site, the init and service entrypoints, the nginx templates) at commit
`edd35eb` (release 26.11.0). Every test suite of the repository passes at that
commit, so none of the findings below is covered by an existing test.

Suggested order: first T1 and T2 (so the suites can catch a regression in the
nginx and runtime fixes), then by risk on a production host: C1, C2, C3, M1,
R1, D1, E1, N1, W1, D13, R2, then the other high findings, then medium (M2,
D2, D3, C9 among the first), then low.

This file is a work list for a follow-up agent: fix each finding with a
regression test, or reject it with the reason.

Every finding has been through an independent, adversarial
verification pass (reviewers who did not write it tried to disprove it, most
of them by reproduction). None was rejected. Many write-ups were corrected:
for a finding marked `confirmed (corrected)`, the note under
[Verification pass](#verification-pass) overrides the finding's own text,
including its severity, line numbers and fix direction. Several original fix
directions would have broken existing behaviour or tests; the notes say which.
Findings added after that pass (X and later) are marked `open` until verified.

## How to work through this list

1. Take the findings in the suggested order above. For each one:
   - **Validate** it: reproduce the failure with the steps given, against the
     current code. Line numbers are those of `edd35eb` and may have drifted:
     search for the function name.
   - If it does not reproduce, set its status to `rejected` with one line why.
   - Otherwise **write the regression test first** (it must fail), then fix,
     then show the test passing. Keep each fix to what the finding needs.
   - Set the status to `fixed` and name the test that covers it.
2. One commit per finding (or per tightly related group), message in the style
   of the history (`fix(export): ...`, `fix(install): ...`, `fix(kvsctl): ...`).
3. Before pushing, run the checks below. All of them must pass.
4. **The suites are a weaker safety net than they look** (see T1 to T6): the
   nginx rules are checked as text only, and 15 of the 16 integration suites
   never run in CI, including `integration_origin_security.sh`, which the C1 and
   C3 tests should extend. Fix T1 and T2 first, or at least run the integration
   suites by hand (`tests/integration_*`) for every nginx, import or runtime
   change.

Status legend: `open` (not yet validated), `confirmed` (reproduced again by an
independent verification pass, not fixed), `confirmed (corrected)` (real, but
the verification pass corrected the write-up: read the note in
[Verification pass](#verification-pass) before fixing), `fixed`, `rejected`. "Confidence" is how the audit verified it: **repro** (a
reproduction failed as described) or **code** (exact code-path reading only,
validate carefully).

### Running the checks in a cloud container

The suites need tools a bare container lacks. Without them, about a dozen
suites fail for reasons that are not bugs:

```bash
apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends shellcheck rsync zstd gettext-base uidmap 7zip python3-yaml iproute2
```

```bash
nohup dockerd > /tmp/dockerd.log 2>&1 &
```

```bash
CI=true .github/scripts/as-uid-1000.sh tests/run.sh
```

```bash
cd cli && go vet ./... && go test -race ./...
```

`tests/run.sh` stops at the first failing suite. To see every failure, run
each `tests/test_*.sh` on its own through `as-uid-1000.sh`.

## Summary

| ID | Severity | Area | Title | Confidence | Status |
| --- | --- | --- | --- | --- | --- |
| E1 | high | export | Export archive is world-readable | repro | confirmed (corrected) |
| E2 | medium | export | Any file change during tar fails the whole export | repro | confirmed |
| I1 | medium | install | DNS "wait and retry" loops forever | repro | confirmed |
| I2 | medium | install | Archive copied while still being uploaded | repro | confirmed (corrected) |
| E3 | high | export | Output under a symlink inside the site: tar recurses, or the dump lands in the web root | repro | confirmed (corrected) |
| I3 | medium | install | Standalone install deletes an existing `/root/tmp` | code | confirmed |
| I4 | medium | install | Domain taken from the archive name blocks valid installs | repro | confirmed (corrected) |
| I5 | medium | install | Failed SQL import is reported as success and never redone | code | confirmed |
| I6 | low | install | `DOMAIN` rewritten in `.env` before `setup.sh` reads the old one | code | confirmed (corrected) |
| E4 | medium | export | Non-canonical `--exclude` is reported excluded but archived | repro | confirmed |
| E5 | medium | export | `setup_db.php` parsing reads commented lines, misses valid forms | repro | confirmed (corrected) |
| I7 | medium | install | IonCube lines appended on every run and on failure | code | confirmed |
| G1 | low | kvsctl | `dotenv.Set`/`MergeEnv` append CRLF lines the shell misreads | repro | confirmed (corrected) |
| G2 | low | kvsctl | `${PWD}` in `.env` expands differently from compose | code | confirmed (corrected) |
| I8 | low | install | "Update the Script" corrupts the log and drops arguments | repro | confirmed (corrected) |
| I9 | low | install | `www.conf.bak` overwritten on re-run | code | confirmed |
| E6 | low | export | Storage server columns shift when one is empty | repro (mechanism) | confirmed (corrected) |
| E7 | low | export | IPv6 `DB_HOST` misparsed | repro | confirmed |
| G3 | low | kvsctl | doctor fails on distro/Desktop compose version strings | code | confirmed (corrected) |
| G4 | low | kvsctl | `semver.Compare` treats `RC1`/`rc1` and `rc01`/`rc1` as equal | repro | confirmed (corrected) |
| G5 | low | kvsctl | Bare word on the last line changes meaning after `Set` | repro | confirmed (corrected) |
| D1 | high | setup | Headless re-run replaces saved prefix, SSL and cache choices | repro | confirmed (corrected) |
| D2 | medium | setup | Port overrides written raw to `.env`, then sourced as code | repro | confirmed |
| D3 | medium | setup | Staged import dump is world-readable | code | confirmed (corrected) |
| D4 | medium | setup | Empty `dhparam.pem` from an interrupted run is kept | repro | confirmed (corrected) |
| D5 | medium | setup | Truncated `gum` download is installed and never replaced | repro | confirmed |
| D6 | medium | setup | Headless pre-flight still prompts and exits silently at EOF | repro | confirmed |
| D7 | medium | setup | `DNS_CHOICE` unknown or `1` loops forever in headless mode | repro | confirmed |
| D8 | medium | setup | `DB_CHOICE` ignored when endoflife.date does not answer | repro | confirmed (corrected) |
| D9 | medium | setup | `--dev` fails unless `DOMAIN` is given, ignores the saved domain | repro | confirmed |
| D10 | medium | setup | Multi-site Caddy exception also skips loopback port conflicts | repro | confirmed |
| D11 | low | setup | Partial GeoIP database kept as "already configured" | repro | confirmed |
| D12 | low | setup | Started from another project's directory, it uses that `.env` | repro | confirmed (corrected) |
| D13 | high | setup | Admin password lost when kvs-init fails after setting it | code | confirmed |
| D14 | medium | setup | A failed ACME issuance aborts before cache, Manticore, cron, import finish | code | confirmed (corrected) |
| D15 | medium | setup | Default-admin checks of setup and 35-harden disagree | repro | confirmed (corrected) |
| D16 | low | setup | One-time admin password saved in the 0644 install log | repro | confirmed (corrected) |
| D17 | low | setup | Switch to self-signed keeps a public cert nothing renews | repro | confirmed (corrected) |
| D18 | low | setup | Step output goes to predictable `/tmp` files | repro (partial) | confirmed (corrected) |
| C1 | high | runtime | PHP runs in upload directories, `.phar` included | repro | confirmed (corrected) |
| C2 | high | runtime | Root init container runs a script PHP can write | repro | confirmed (corrected) |
| C3 | high | nginx | Asset regexes win over the internal-directories deny | repro | confirmed (corrected) |
| C4 | low | nginx | TLS 1.3 0-RTT on, replayable, invisible to PHP | repro | confirmed (corrected) |
| C5 | low | nginx | SVG and font responses lose every security header | repro | confirmed (corrected) |
| C6 | low | runtime | PHP-FPM can rewrite phpMyAdmin's `config.inc.php` | code | confirmed (corrected) |
| C7 | low | nginx | `_INSTALL/` (`install_db.sql`) served as static files | repro | confirmed (corrected) |
| C8 | low | runtime | Init re-runs rewrite the title; Manticore cron failure hidden | code | confirmed (corrected) |
| C9 | medium | runtime | PHP-FPM workers exceed MariaDB's 151 connections on 38 GiB+ hosts | repro | confirmed |
| C10 | low | runtime | Internal TLS trust installs a CA:TRUE self-signed cert as a root | repro | confirmed (corrected) |
| C11 | low | runtime | Buffer pool of 5M is accepted, but MariaDB refuses to start | repro | confirmed |
| R1 | high | multi-site | `remove` of a new site deletes a single-mode primary's data | repro | confirmed |
| R2 | high | multi-site | Two sites can claim the same `www` host, breaking Caddy for all | repro | confirmed |
| R3 | medium | reconfigure | Multi-mode rollback leaves the recreated containers changed | repro (stub) | confirmed (corrected) |
| R4 | medium | reconfigure | Edited `DOMAIN` half-applies and takes the site down | code | confirmed (corrected) |
| R5 | medium | multi-site | `remove` hides a failed `down -v`, then deletes the config | repro | confirmed |
| R6 | low | multi-site | Manual `caddy-start` sets the ACME email to `admin@example.com` | repro | confirmed (corrected) |
| M1 | high | import | Shell injection on the old server in the tar fallback | repro | confirmed |
| M2 | medium | import | Untrusted dump runs shell commands in the MariaDB container | repro | confirmed |
| M3 | medium | import | Decompression errors ignored; a corrupt dump is marked complete | repro | confirmed |
| M4 | medium | import | Absolute symlinks on the old server copied as root, readable by PHP | repro | confirmed (corrected) |
| M5 | low | import | A resumed pass can run with no free-space check | code | confirmed (corrected) |
| K1 | medium | kvsctl | `backup --keep` deletes the archive a rollback would replay | repro | confirmed |
| K2 | medium | kvsctl | Relative restore path recorded; `recover` elsewhere replays the wrong file | repro | confirmed |
| K3 | medium | scripts | Scripts check the kvsctl lock but never hold it | code | confirmed (corrected) |
| K4 | medium | kvsctl | A second `restore --latest` replays the safety backup | code | confirmed |
| K5 | low | kvsctl | `update-cli --version <older>` does nothing and exits 0 | repro | confirmed (corrected) |
| K6 | low | kvsctl | `restore <archive> --latest` silently ignores `--latest` | code | confirmed |
| N1 | high | native | `setup_db.php` (DB password) left world-readable by `chmod -R 755` | code | confirmed (corrected) |
| N2 | medium | native | www redirect server always answers 444 in the default mode | repro | confirmed (corrected) |
| N3 | medium | native | `php.ini` timeout edits are no-ops; no `fastcgi_read_timeout` | repro | confirmed (corrected) |
| N4 | medium | native | Failed ACME silently ships self-signed; storage TLS check left on | code | confirmed |
| N5 | medium | native | nginx configs always fetched from `main`, failures unchecked | code | confirmed (corrected) |
| N6 | low | native | No KVS rewrites file for an existing site on a new host | repro | confirmed (corrected) |
| N7 | low | native | yt-dlp can be replaced by an HTTP error page, as root, nightly | repro | confirmed |
| N8 | low | native | Printed phpMyAdmin URL unreachable; its install cannot fail | repro | confirmed (corrected) |
| S1 | low | release | Dispatch from a branch named like a version mixes tag and branch | repro | confirmed (corrected) |
| S2 | medium | release | Actions pinned by mutable tag in privileged jobs | repro | confirmed |
| S3 | low | release | Failed lock lookup swallowed; PHP image built from a floating tag | repro | confirmed (corrected) |
| S4 | medium | release | Lock check reads only the first `ARG` line and never `FROM` | repro | confirmed |
| S5 | low | runtime | Manticore PHP plugin installed unverified by default | code | confirmed (corrected) |
| S6 | low | release | Registry digest header trusted without hashing the body | repro | confirmed (corrected) |
| S7 | low | ci | `push.yml` and `markdown-lint.yml` have no `permissions:` | repro | confirmed |
| S8 | low | multi-site | Caddy outside the lock; site template references not checked | repro | confirmed (corrected) |
| W1 | high | docs | `MENU_OPTION=2` "Add site" runs a broken native install, even on Docker | code | confirmed (corrected) |
| W2 | low | install | `kvs-install.sh --help` (any unknown argument) starts an install | repro | confirmed (corrected) |
| W3 | medium | multi-site | `site-manager.sh add` always uses PHP 8.1 and `IONCUBE=YES` | code | confirmed (corrected) |
| W4 | low | docs | Standalone headless ignores `SSL_CHOICE` and `KVS_EMAIL` | code | confirmed (corrected) |
| W5 | low | docs | `.env.example` gives the wrong default container prefix | code | confirmed |
| W6 | low | docs | Standalone PHP-FPM is never set to "static" | code | confirmed (corrected) |
| W7 | low | docs | The "monitoring tools" (ncdu, vnstat, nload) are not installed | repro | confirmed |
| W8 | low | docs | Supported KVS versions disagree across docs, Docker and kvsctl | code | confirmed (corrected) |
| T1 | high | tests | nginx deny rules checked as text only, never by request | repro | confirmed (corrected) |
| T2 | high | tests | 15 of the 16 integration suites never run in CI | repro | confirmed (corrected) |
| T3 | medium | tests | `site-manager.sh remove` traversal check passes for the wrong reason | repro | confirmed (corrected) |
| T4 | medium | tests | Manticore runtime privilege check can never run in CI | repro | confirmed |
| T5 | low | tests | Project URL assertions in a subshell cannot fail | repro | confirmed (corrected) |
| T6 | low | tests | A stub's `fail` does not stop the `install_gum` test | repro | confirmed |
| X1 | medium | setup | `DISABLE_KVS_SUPPORT_ACCESS=true` silently reversed by a second `.env` reader | repro | open |
| X2 | medium | setup | PHP series taken from a stale archive name, not the site in place | repro | open |
| X3 | low | kvsctl | kvsctl reads booleans case-insensitively; nginx and the scripts do not | repro | open |
| X4 | low | multi-site | Several archives: setup refuses, site-manager and init pick one at random | repro | open |
| X5 | low | kvsctl | KVS versions setup accepts (`7.0.3.1`, `7.0`) block kvsctl upgrades | repro | open |
| X6 | low | setup | Bracketed endpoints compose rejects pass setup's parser | repro | open |
| P1 | medium | multi-site | Full disk replaces the primary Caddy route with an empty file; exit 0 | repro | open |
| P2 | medium | multi-site | Interrupted `add` leaves a half site that `add` refuses and `start` calls working | repro | open |
| P3 | low | setup | Import receipt written before cleanup; re-run advises wiping a complete database | repro | open |
| P4 | low | scripts | `.env` and export renames are never fsynced | code | open |
| U1 | high | kvsctl | Upgrading an adopted pre-26.10 stack removes acme; certificates stop renewing | repro | open |
| U2 | medium | kvsctl | `kvsctl upgrade` never fixes files the old root cron created | code | open |
| U3 | medium | setup | Re-run overwrites `PROJECT_HTTPS_PORT` with the published port | repro | open |
| U4 | medium | setup | Re-run discards the saved `PHP_VERSION` for the default series | repro | open |
| U5 | medium | setup | Volume check allows multi-series MariaDB jumps in place, no backup | repro | open |
| V1 | medium | import | tar archive with a non-ASCII site directory or dump name cannot be imported | repro | confirmed |
| V2 | medium | import | A resumed directory import is refused for lack of space | repro | confirmed (corrected) |
| V3 | low | scripts | Under a UTF-8 locale, domain and prefix checks accept Unicode | repro | confirmed (corrected) |
| V4 | low | setup | DNS check reads `/etc/hosts` and only the first A record | repro | confirmed (corrected) |
| V5 | low | setup | Docker DNS check ignores AAAA records | code | confirmed (corrected) |
| V6 | low | export | Export size walk starts one `du` per shallow file | repro | confirmed (corrected) |

## Verification pass

A second set of reviewers, who did not write the findings, tried to disprove
them from the code at `c7e0068`, reproducing them where possible. Their
verdicts and corrections override the finding text below where they differ.

- **E2 — confirmed.** A file that *shrinks* during the read also gives exit 1
  ("File shrank by N bytes; padding with zeros") and is archived with zeros in
  place of its data. So "treat 1 as success" must list the shrunk files, or
  treat them as fatal. Severity lowered to medium: no data is lost and a re-run
  works. Live `admin/logs` is archived, which makes exit 1 likely
  (`tests/test_kvs_export.sh:717`).
- **E3 — confirmed, and wider than written.** `kvs_path_inside_site` calls
  `readlink -f`, so `--dump-only -o "$site/contents/dump.sql.gz"` (a path through
  the in-site symlink) passes the check: the database dump is written into the
  web-served contents directory, mode 0644, with exit 0. The fix must cover
  `--dump-only` and compare the unresolved path too. Correction: the staging
  directory is 0700 (`mktemp -d`), so "staging is web-served meanwhile" is
  overstated.
- **I1 — confirmed.** It re-checks every 60 s and continues once DNS matches,
  so "forever" holds only while DNS stays wrong; nothing is damaged. Severity
  lowered to medium.
- **I2 — corrected.** The race is real, but
  `docker/init/docker-entrypoint.d/00-extract.sh:105` runs `unzip -tq` and refuses
  the truncated archive, so no truncated KVS is installed. The real impact: a
  failed kvs-init that fails again on every re-run (the `kvs-archive/` copy is
  preferred, `kvs-install.sh:2192`) until the user deletes it. The same
  wait-then-use pattern is on the standalone path, `kvs-install.sh:615-620`.
  Severity lowered to medium.
- **I3 — confirmed (code).** There is no `set -e`, so the `rm -rf` runs even when
  `cp KVS_*` fails. The function ignores `KVS_ARCHIVE_DIR`. Not covered:
  `tests/test_kvs_install.sh` stubs `whatisdomain`. Severity lowered to medium (a
  fresh host rarely has `/root/tmp`).
- **G1 — corrected fix direction.** "Always LF" breaks behaviour the tests pin on
  purpose: `cli/internal/dotenv/dotenv_test.go:420` ("a CRLF file" expects
  `C=3\r\n`) and `cli/internal/instance/env_test.go:166-183` (MergeEnv on a CRLF
  file expects CRLF). In an all-CRLF file the shell already misreads every line,
  so LF only helps a mixed file. Fix instead: use the ending of the line the
  text is appended after, not "any CRLF anywhere", and update those tests on
  purpose. The MergeEnv variant comes from `instance.go:405` (`TrimRight` plus
  the new ending). Severity lowered to low.
- **D13 — confirmed (code).** 35-harden is around lines 70-95. Example trigger:
  `80-manticore.sh:62-67` exits 1 when kernel-scripts.com is unreachable. The
  interactive default for an existing database is 3 (Exit); only headless
  defaults to Keep (`docker/setup.sh:1341`). An undocumented recovery exists:
  re-run with a `KVS_ADMIN_PASSWORD` of 20 or more characters, which 35-harden
  applies even on Keep. Prefer showing the password, or writing a 0600 file,
  before kvs-init or on failure, over "run 35-harden last".
- **R2 — confirmed** with the real `write_caddy_site_config` and `caddy validate`.
  `add_site` always passes `use_www=false` (`site-manager.sh:566`), so the
  `USE_WWW=true` variant applies only to `primary-config`.
- **M3 — confirmed.** The inspect pipeline is at `docker/lib/import.sh:202` (not
  206). The "Related" part holds: `docker/setup.sh:1800-1806` refuses a dump
  without "Dump completed" only for remote sources.
- **K1 — confirmed.** `run.go:203` passes the same empty `state.UpgradeBackup` to
  the upgrade's prune; a state written before `UpgradeBackup` existed hits the
  same fallback. Severity lowered to medium: rollback then refuses with a clear
  message, and the case needs `--skip-backup` on a migrating release or a
  legacy state.
- **S3 — corrected severity.** The release images job `needs: [prepare, go,
  suites, keys]` (`release.yml:189`), and `suites` runs the matrix-versus-lock
  check (`tests/test_release_workflow.sh:335-350`); `--get` only reads the local
  lock, so a missing series is the only realistic failure and it is caught.
  `docker.yml` never pushes. Defence in depth: severity lowered to low.
- **S4 — confirmed.** The fix must allow `${PHP_FROM}` and stage names (php and
  cron use `FROM ${PHP_FROM} AS ffmpeg-build` and `COPY --from=ffmpeg-build`),
  and also check the `ARG PHP_FROM=` line.
- **C1 — confirmed; severity high (was critical).** It needs someone who can
  already write a `.php` file under `contents/`: defence in depth. Fix scope:
  `tmp/` and `langs/` are already covered (`/tmp/x.php` hits the internal
  location and the deny at `:136`; `:88` covers langs), so only `contents/`
  needs the new rule. The native `conf/nginx/globals/php_fastcgi.conf:2` already
  has `try_files $fastcgi_script_name =404`, so the `.phar` PATH_INFO trick does
  not apply to the native install; a direct `.php` does. The `10-config-php.sh`
  prune is at `:91` (comment at `:80-81`).
- **C2 — confirmed; severity high (was critical); fix corrected.** It is a
  privilege escalation from uid 1000. `60-permissions.sh:113` chowns the whole
  tree, the marker included, to 1000 before `:127`, so uid 1000 can also forge
  or delete the marker. No `USER`, `security_opt`, `read_only` or `cap_drop`
  anywhere in `docker/`. Do **not** move `.kvs-extraction-complete` out of the
  site: `00-extract.sh:42-60` relies on it across `run --rm` containers (skip,
  refusal and resume, `tests/test_init_resume_hardening.sh`). Instead add a
  separate per-run flag in the container's `/tmp`, shared by the
  `entrypoint.d` scripts of one run, and trust only that. The staging directory
  cannot be the script's source (the `00-extract` EXIT trap deletes it before
  `60` runs): copy the script to `/tmp` during extraction.
- **C3 — confirmed; fix caveat.** Moving the `^/tmp/` deny above the asset
  regexes 403s every static file under `/tmp/`: check first that KVS serves no
  upload preview or temporary file from `/tmp/` by direct URL. Line references
  are right in all three files (`domain.conf` includes `general.conf` at `:30`,
  before `:41`).
- **M1 — confirmed** with the real `import_remote_files`. The call is at
  `import.sh:3253`. The rsync path is not affected (its excludes travel in the
  protocol); `$dir` is protected by `import_remote_path_check`.
- **M2 — confirmed; severity medium (was high).** Whoever controls the dump
  already controls the whole imported database, admin accounts included; the
  extra gain is a shell as mysql in the MariaDB container. `import_prepare_dump`
  starts at `import.sh:320`; native at `native-import-runtime.sh:228-237`. The
  entrypoint passes no `--binary-mode`.
- **R1 — confirmed** with real Docker (`down -v` from another directory under the
  same project name removed the other project's container and volume).
  Current lines: `add_site` `:451`, `ensure_site_prefix_available` `:168`
  (called at `:484`), `remove_site` `:707` (`down -v` near `:736`). It needs
  `site-manager add/remove` on a single-mode install and typing `yes`;
  medium-to-high. The working_dir label check is the right guard.
- **D1 — confirmed; fix caveat.** `retirement_prepare_identity`
  (`docker/setup.sh:997`, `:1002`) writes `SITE_PREFIX=kvs` on purpose as a
  "choose again" signal when the domain changes, and `.env.example` ships
  `SITE_PREFIX=kvs`. A new "legacy" marker must keep both working.
- **D2 — confirmed; severity medium (was high).** The value comes from root's own
  environment: no privilege boundary. Also: the loopback ports reach
  `parse_publish_endpoint` only inside `publish_endpoint_is_listening`, within an
  `if`, so an invalid value is read as "not listening" and never rejected.
  `parse_publish_endpoint` is at `:1083`; the capture at about `:3298-3308`.
- **D3 — confirmed; severity medium (was high); fix corrected.** Worse than
  written: `docker/setup.sh:8` sets `umask 022` explicitly, and the default
  install directory `/opt/kvs` is a 0755 clone. But a root-owned 0700
  `mariadb/init` breaks the import: the image entrypoint drops to mysql (uid 999)
  before reading `/docker-entrypoint-initdb.d`. Own or group the directory and
  files to 999. `tests/test_native_import.sh:88` asserts 644 on the native
  payload and must change with the fix. Mind userns-remap and rootless Docker,
  where 999 maps differently. Needs an unprivileged local user on the host.
- **E1 — confirmed (code); fix detail.** Tar is at about `:2449`, the
  `--dump-only` path at `:2404-2408`. The default output is `./<domain>-…` in the
  current directory, so a run from `/root` (0700) is safe; a 0755 home or `/tmp`
  exposes it. Prefer `chmod 600` on the staged file before `mv` to a global
  `umask 077`.
- **G2 — confirmed; severity low (was medium).** kvsctl never reads `DATA_DIR`,
  so the example is wrong; no shipped file (`.env.example`, compose files) uses
  `${PWD}`, and the scripts `cd` into `docker/` before sourcing. Only a
  hand-edited `.env` with `${PWD}` in a key kvsctl reads (for example
  `COMPOSE_FILE`) is affected.
- **G3 — confirmed; citation corrected.** `cli/internal/upgrade/plan.go` (around
  `:527`) does not parse the leading `MAJOR.MINOR.PATCH`: it skips the minimum
  check when the version does not parse. Either behaviour is a fine fix.
- **G4 — real in the library, not reachable through the release pipeline.**
  `.github/scripts/release-version.sh:50` refuses uppercase labels and leading
  zeros in the tag, which is the signed version; only a hand-run
  `kvsctl-release` with the signing key could produce such a manifest.
  Informational. Fixing `Parse` breaks no test.
- **G5 — confirmed, narrower.** Plain compose and the scripts see no change
  (compose prefers the process environment either way; the stack has no
  `env_file:`). The change goes through kvsctl, in `ReadEnv` and `Isolate`:
  with `DOMAIN=a.com\nDOMAIN` and `DOMAIN=old` exported, compose renders `a.com`
  before the `Set` and `old` after it.
- **K2 — confirmed.** `resolveBackup` is at `cli/cmd/kvsctl/restore.go:277-291`.
  `filepath.Abs` breaks no test (`TestResolveBackup` already uses absolute
  paths).
- **K3 — confirmed; fix caveat.** Holding a shared lock for the whole script run
  cannot deadlock (kvsctl never runs the scripts). But `Instance.Lock`
  (`cli/internal/instance/lock.go:117-131`) treats a blocked lock whose
  recorded PID is gone as "a docker command it started still runs": a script's
  shared lock would hit that path with the wrong message, so change it too.
  `kvs-install.sh:1968-1990`.
- **K4 — confirmed, medium-low.** `list[0]` is at `restore.go:253-255`. The case
  only arises after `verifyRestore` fails, after `dropJournal` (a failed replay
  leaves a journal and `noJournal` refuses a second restore). The error says the
  database is restored and "the restore is over": the risk is scripted retries.
- **K5 — confirmed; fix caveat.** `cliState`'s newer-than rule is pinned for the
  default target by `TestCLIState` (`updatecli_test.go:157`): branch on
  `--version` in `updatecli.go:78-82`, do not change `cliState`. Prefer an error
  to a downgrade: an older kvsctl may not read state or a journal written by a
  newer one.
- **K6 — confirmed.** `chooseBackup` at `restore.go:247-249`.
- **R3 — confirmed (code); fix corrected.** Multi mode recreates nginx at
  `reconfigure.sh:1474` and the runtime services at `:1520`. "Recreate with the
  previous environment" is impossible as is: the operator edits `.env` before
  running the script and nothing keeps the old one. Snapshot the running
  containers' environment or the old `.env` first, or validate before
  recreating. Seven assertions in `tests/test_reconfigure_hardening.sh` (1265,
  1329, 1354, 1468, 1519, 1607, 1712) pin "Application state restored": update
  them on purpose if the message changes.
- **R4 — confirmed (code); line corrected.** `:505` is the definition of
  `run_mariadb_query`; the first query call is `:1518`. README documents domain
  changes through `setup.sh` only, so refusing here breaks nothing.
- **R5 — confirmed** with a stub `docker` (the site directory and `.caddy` file
  were removed and success printed; EOF on the webroot prompt then exits before
  the Caddy reload).
- **R6 — confirmed; context corrected.** `add` prints `caddy-start` only when
  Caddy is not running (`site-manager.sh:572-573`); the likelier trigger is
  `README.md:73`, which tells users to run `caddy-start` to apply the log cap.
  `docker/setup.sh:5661,5665` itself falls back to `admin@example.com` when
  `EMAIL` is empty. Let's Encrypt stopped sending expiry emails in 2025, so the
  real risk is a refused account registration at renewal (not reproduced).
- **S1 — confirmed; severity low (was medium).** Missed mitigations: a manual
  dispatch needs write access; the keys and publish jobs wait for a required
  reviewer in the `release` environment (`docs/releasing.md:126-135`);
  `release-version.sh` refuses a tag that already has a release. Line refs
  `release.yml:447`, `:452`. The fix is compatible with
  `tests/test_release_workflow.sh`.
- **S2 — confirmed.** `renovate.json` softens automerge only with a 3-day
  `minimumReleaseAge`. The key is deleted before the softprops step
  (`release.yml:500-502`, `if: always()`, then `:570`), so "cannot sign" holds.
  SHA pins keep the workflow suite's `startswith(...)` checks passing.
- **S5 — real; severity low (was medium); fix corrected.** The URL is the KVS
  vendor's own HTTPS site, the same party that supplies KVS. A pinned default
  sha256 plus refusing an empty value would make every Manticore-enabled init
  fail the day the vendor updates its unversioned file (and a failed
  `80-manticore` already triggers D13). Instead: mirror the file as a release
  asset pinned per release, or pin it per release with a refresh process.
- **S6 — locations and scope corrected.** `checkImage` is
  `cli/internal/manifest/manifest.go:688`; `readImage` is `registry.go:124-197`;
  the `localhost` prefix check is `registry.go:80`. The digest header *is*
  cross-checked against the build or lock digest for every image
  (`main.go:953-962`, `release-images.sh`); only the body (layers, sizes, diff
  IDs) is unverified, and pulls by digest verify content anyway. Fix caveat: fake
  digests appear in 6 test files and `stubDigest` hashes the URL path
  (`main_test.go:1049`), so validate in `kvsctl-release` and update those
  fixtures on purpose.
- **S7 — confirmed.** Pull requests from forks get a read-only token anyway;
  only pushes are exposed.
- **S8 — corrected.** `mariadb`, `memcached` and `dragonfly` *are* in
  `images.lock` and `RUNTIME_IMAGES` (`resolve-bases.sh:84-92`); only
  `caddy:2-alpine` is missing from the lock. What is missing is that the site
  template's references are not in `COMPOSE_IMAGES`. The proposed test is wrong:
  the main `docker/docker-compose.yml` also has tag references, pinned by the
  release override, and `COMPOSE_IMAGES` cannot express the per-series
  `${MARIADB_VERSION}` image. Instead: add caddy to the lock, and give multi-site
  sites a pinned override, or limit the check to the multi-site files.
- **E4 — confirmed** with the real script. Nuance: the summary prints the real
  entry as "copied" and the typed path as "excluded", so it contradicts itself
  rather than only claiming "excluded". `..` is already rejected at
  `kvs-export.sh:2467`; only the normalising is new.
- **E5 — confirmed; fix corrected.** In PHP the *first* `define()` wins (a later
  one only warns): use the first uncommented definition, or fail on several,
  not the last. Do **not** parse with `php -r include` as root: natively the file
  is writable by www-data (N1), so that would be www-data-to-root code
  execution; tokenise instead (for example `token_get_all`). Skipping `//` and
  `#` lines does not cover multi-line `/* */` blocks.
- **E6 — confirmed; missed consumer.** The same `server_N=` lines are displayed
  on the Docker import side by `import_remote_show_servers`
  (`docker/setup.sh:1993-2008`, split on `|`). With `mysql -B`, NULL prints as
  `NULL`, so only empty strings collapse; whether KVS stores `''` in `path` is
  still unverified.
- **E7 — confirmed** with the mariadb image (a bare `-h ::1` is accepted).
- **I4 — confirmed; fix scope widened.** The same TLD regex is in six places:
  `kvs-install.sh:727` and `:589`, `docker/setup.sh:637` and `:3342` (email),
  `docker/reconfigure.sh:272` (domain) and `:281` (email).
- **I5 — confirmed** with stubs: run 1 returned 0 with `_INSTALL/` gone; run 2
  saw "already exists" and never imported.
- **I6 — confirmed (code); severity low (was medium).** It needs all of: a
  `new.com` archive replacing the old one in `kvs-archive/`, no `DOMAIN` in the
  environment (an environment `DOMAIN` wins through `KVS_DOMAIN_OVERRIDE`,
  `docker/setup.sh:3294`/`3505`, and the change is then detected), and import
  mode or `KVS_IMPORT_COMPLETED`. The `export DOMAIN=` mismatch is real; the fix
  works (`setup.sh` persists `DOMAIN` itself at `:1001`).
- **I7 — confirmed.** Also: after `cd ioncube`, the shell is left inside the
  `/root/ioncube` the function then deletes.
- **I8 — confirmed, worse; fix corrected.** Every line of the first run was lost,
  the log held 8402 NUL bytes, and each second-run line appeared twice. `tee -a`
  does **not** fix it: the new tee writes to fd 3, the old tee's pipe, so the old
  tee logs every line again at its own offset. Only an environment marker that
  makes the re-exec skip the log setup (keeping the inherited fds) works.
  `"$@"` is empty inside `update()`: pass a saved copy of main's argv.
- **I9 — confirmed, trivial.** Nothing reads the `.bak` and the `sed` edits are
  idempotent; only the stock pm values are lost.
- **N1 — confirmed; fix corrected.** Without the `chmod`, unzip under umask 022
  still leaves the file 0644, so chmod `setup_db.php` explicitly after
  `configure_kvs_database_file`, on every run. Do **not** take ownership of the
  code away from www-data: it breaks KVS's self-update from the admin panel
  (comment at `kvs-install.sh:1062-1063`) and diverges from Docker, which chowns
  the tree to the PHP user and sets only `setup_db.php` to 600
  (`60-permissions.sh:113`, `:141-145`). Scope the fix to file modes and
  `setup_db.php` (0640 `root:www-data`, or 0600 www-data).
- **N2 — confirmed; fix and test corrected.** Default mode: `https://www` gets an
  empty reply, apex 200. `USE_WWW=true`: apex 301 to www, other subdomains 444.
  Drop the `if`; "compare against `$URL`" would still 444 the www host. Test:
  301 for https www in the default mode, and for apex in www mode.
- **N3 — confirmed; impact narrowed.** "Uploads fail" is overstated: nginx
  buffers request bodies, so transfer time does not count against these limits.
  Long PHP actions do fail. The Docker `fastcgi_read_timeout 300` is at
  `conf/nginx/templates/kvs.conf.tpl:153`.
- **N4 — confirmed.** Even if acme.sh's cron later issues the certificate,
  `--install-cert` never ran, so nginx keeps the self-signed one.
- **N5 — confirmed; detail.** `aptinstall_nginx` ends with `service nginx
  restart` (`:997`) and returns its status, so a bad `nginx.conf` can show there;
  a missing globals file shows only when the vhost is enabled.
- **N6 — confirmed; severity low (was medium).** The step is reported as failed
  (`install_acme.sh` returns the restart status), and the native installer has no
  import flow, so "existing site on a new host" needs a manual copy into
  `/var/www`.
- **N7 — confirmed.** A network failure partway through also truncates the binary
  in place. Writing to a temp file then `mv` stays compatible with the
  `tests/test_kvs_install.sh:266` stub.
- **N8 — confirmed; fix corrected.** `updatephpMyAdmin` also regenerates
  `config.inc.php` from the sample (around `:2420`), and lacks the PHP package
  install and the nginx restart, so reusing it does not keep local edits. Also,
  `setupdone` (`:1654`) writes the DB password into the install log (see D16).
- **D16 — confirmed; severity low (was medium); fix corrected.** `/root` is 0700 by
  default, so the 0644 mode does not reach other local users; the issues are
  backups, log shipping, and the false message (which is true for setup.sh's
  own 0600 debug log, `docker/setup.sh:14`, `:323`, when it runs alone).
  `/dev/tty` is absent in detached or headless runs, and fd 3 exists only under
  kvs-install.sh, so printing only there would lose the password. Instead,
  create the install log 0600 before the tee (which also covers the native DB
  password at `kvs-install.sh:1654`), and/or write a 0600 password file. The
  print block is in `setup.sh`, so test it there.
- **D4 — confirmed** (the pinned nginx fails `nginx -t` with `PEM_read_bio_DHparams
  … no start line`). Fix caveat: `tests/test_setup_directory_import.sh:72` creates
  an empty `dhparam.pem` on purpose and its openssl stub exits 97 on `dhparam`
  (`:39`): change that fixture with the fix.
- **D5 — confirmed:** the partial binary segfaults (139) on `gum style` while
  `command -v gum` still finds it. `install_gum` at `:3202-3223`, called at
  `:3250`.
- **D6 — confirmed.** Not fully silent: the warnings and the prompt are shown,
  then the exit is 1 without an error. The comment at `:3181` says "Skip prompt
  if headless mode", but the code checks only `PREFLIGHT_BYPASS`.
- **D7 — confirmed:** about 565 curl calls in 3 s. Interactive runs with
  `DNS_CHOICE` exported loop the same way. Loop now at `:5220-5262`;
  `README.md:269` documents 1-3.
- **D8 — confirmed; detail.** Interactive users are not asked either when the API
  is down. A non-numeric `DB_CHOICE` prints "integer expression expected" on
  stderr. Recoverable on a fresh install (empty volume, re-run with
  `VOLUME_CHOICE=1`).
- **D9 — confirmed;** also fails on a fresh install without `DOMAIN`, so `--dev`
  never works without it. Capture at `:3294`.
- **D10 — confirmed.** `docker-compose.multi.yml` resets only nginx's ports, so
  MariaDB still publishes `127.0.0.1:3306` in multi mode.
- **D11 — confirmed.** Simple extra fix: `rm -f` the file in the "Download
  failed" branch (`:4590`); the "already configured" check is at `:4504`.
- **D12 — confirmed; fix caveat.** Several harnesses
  (`tests/test_setup_existing_project_detection.sh` and others) run a setup copy
  from a directory without `docker-compose.yml` and rely on the stay branch
  `[ ! -f "$script_dir/docker-compose.yml" ]`: keep it, and replace only the
  `[ -f docker-compose.yml ]` stay with `$PWD -ef "$script_dir"`.
- **D14 — real; impact corrected.** `--resume-import` re-runs ACME (`:5787-5788`),
  then the runtime start, `import_finish` and cron, so an import can be resumed
  after DNS is fixed, not only redone. The reboot claim is doubtful: the check
  needs `RestartCount 0`, which `docker restart` and `stop`/`start` keep; only a
  crash restart or a recreated container blocks resume. Medium for non-import
  runs, lower for imports.
- **D15 — confirmed; missed sites.** `site-manager.sh:641` uses the same
  `login="admin"` predicate and `:661` hardcodes "Admin login: admin". The
  35-harden check is at `:100`. `tests/test_setup_resume_flow.sh:52` matches the
  setup query on the substring `login='admin'` (anything else exits 97): update
  that stub on purpose.
- **D17 — real; fix corrected.** `docker/nginx/docker-entrypoint.sh:223-224` says
  by design that "a retained public/private-CA certificate remains the
  operator/ACME's responsibility": replacing every certificate that is not
  self-signed would destroy operator-supplied ones (private CA, Cloudflare Origin
  CA). Limit the fix to ACME-issued certificates on a provider switch, in setup.
  An expired pair fails `certificate_pair_is_valid` at the next nginx start, so
  the exposure lasts until a restart.
- **D18 — confirmed (code); missed sibling.** `detect_ioncube` uses
  `TEMP_DIR=/tmp/kvs-detect-$$` (`:3887`) with `mkdir -p` and unzip; cover it too.
- **C4 — confirmed; severity low (was medium).** Replay needs an on-path attacker.
  The native `conf/nginx/nginx.conf:55-56` has the same lines.
- **C5 — real; severity low (was medium); scope widened.** Same location in
  `docker/multi-site/nginx/kvs-caddy.conf.template:70-74` and native
  `conf/nginx/globals/general.conf:20-24`; Debian's nginx has no
  `add_header_inherit`, so use the include approach there. For a correctly typed
  `image/svg+xml`, nosniff does not stop SVG script, and HSTS is set by every other
  response; only CSP would help. Whether KVS lets users upload SVG is
  unverified.
- **C6 — real; severity low (was medium); fix insufficient.** phpMyAdmin runs in
  the same php-fpm pool as uid 1000 (template `:119-127`); its `tmp/` (the compiled
  Twig cache) stays writable to that uid by design, and the sessions volume is
  shared, so root-owning `config.inc.php` does not close the hole. Only a separate
  FPM pool or container with another uid would. Also in the multi-site template
  (`:93`). An attacker with KVS-level code execution already holds the KVS
  database credentials.
- **C7 — confirmed; lines and window corrected.** "preserving _INSTALL" is at
  `30-import-database.sh:175` (the file has 191 lines). A setup re-run stops the
  project's nginx through the port-conflict path before kvs-init, and nginx starts
  only after it (`docker/setup.sh:5653-5655`). The real windows: multi mode (the
  Caddy exception skips the stop), `site-manager.sh`'s kvs-init (`:659`), and a
  manual `compose up` after a failed run.
- **C8 — confirmed (code).** Title sed now at `10-config-php.sh:174`. The compose
  healthcheck comment (around `:274`) says by design that a failed hourly rotation
  is only logged: failing the start when cron does not start fits better than a
  healthcheck on reindexes.
- **M4 — confirmed; fix caveat.** Dereferencing is deliberate:
  `kvs-export.sh:688-690` and `:2428-2429` rely on a `contents` symlink to another
  disk being copied. `--safe-links` or `--munge-links` by default would break that
  standard migration; use the allowlist or confirm-before-transfer option.
- **M5 — real; corrected.** The loaded database size *is* counted (`db_size_mb`,
  passed as `IMPORT_TRANSFER_RESERVE_MB`, `docker/setup.sh:2668-2669`,
  `import.sh:3072`); only the extra dump copies (raw plus `mariadb/init`) are not.
  "Refuse instead of only warning" contradicts the documented behaviour
  (`README.md:320`, `docker/setup.sh:2023-2027`: an unknown size only warns):
  refuse only in the saved-count-minus-present case.
  `tests/test_import_transfer_progress.sh:562-611` pins the no-recount behaviour
  of `skip_count`; do not reintroduce the scan.
- **C9 — confirmed.** 38 GiB already gives 152 children; the php service has no
  memory limit that would lower it. A cap of 128 keeps every
  `tests/test_php_fpm_resources.sh` case passing and leaves about 23 connections
  of headroom.
- **C10 — confirmed; fix corrected.** "basicConstraints absent" is not safe: a
  certificate without it but with keyUsage `keyCertSign` also passes
  `self_signed` and signs a verifying leaf (`openssl x509 -purpose` reports "SSL
  server CA : Yes"). Require `-purpose` to say "SSL server CA : No", or require an
  explicit `CA:FALSE`. Adding the check to nginx's `certificate_pair_is_valid`
  breaks `tests/test_nginx_hardening.sh` ("a valid certificate was replaced"):
  its fixtures at `:123-128` and `:191` are default `req -x509` (CA:TRUE) and need
  `CA:FALSE` as part of the fix.
- **C11 — confirmed.** 6M and 7M start and read back exactly, so
  `database_verify_running_resources` still passes with a 6M minimum.
- **W1 — confirmed, worse.** Docker sites live at `/var/www/$DOMAIN`, so a Docker
  host always takes `manageMenu`; `dockerInstall` copies the archive
  (`kvs-install.sh:2195`), so `whatisdomain` finds the live site's domain.
  `extract_kvs_archive` returns 0 on an existing site, then `install_KVS` makes
  `setup_db.php` world-readable (as N1) and its `sed` rewrites `/usr/local/bin/` to
  `/usr/bin/` in the Docker site's `setup.php`. No `set -e`, so it carries on past
  failures.
- **W2 — confirmed; scope corrected, severity low.** "Straight to
  `dockerInstall`" holds only on non-Debian hosts such as Ubuntu
  (`:1666-1670`); on Debian the install-type prompt comes first, and with
  `/var/www` `manageMenu` prompts first. On Ubuntu as root it installs Docker and
  clones `/opt/kvs` without a prompt, then waits for an archive or the import
  question.
- **W3 — confirmed; fix note.** `kvs_documented_php_version` (`setup.sh:1585`) and
  `detect_ioncube` (`setup.sh:3835`) live in `setup.sh`, which cannot be sourced:
  move them into a lib to reuse them. `add` also never refuses KVS 6.2.0 and
  older.
- **W4 — confirmed; scope corrected, severity low.** The variable table sits under
  "Docker Headless (Recommended)" (`README.md:230`), and the standalone section
  (`:275-284`) documents its own variables. Standalone headless already honours
  `SSL_PROVIDER` (`:257`) and an exported `EMAIL`: the fix is mostly to document
  those two. An empty `-m` matters for ZeroSSL, much less for Let's Encrypt.
- **W5 — confirmed.**
- **W6 — confirmed; wider.** Docker is dynamic-only as well
  (`docker/php/fpm-config.sh:133`), so the README line is wrong for both paths.
- **W7 — confirmed.** The `aptinstall` list is at `:680-705`.
- **W8 — confirmed; minor.** The refusal is `refuse_unbuildable_kvs_php`, about
  `docker/setup.sh:1634-1658`; `KVS_MIN=7.0.0` is at `.github/release.env:42`.
  `cli/README.md:588` documents the `kvs_min` blocker, but not its value. The
  refusal can be bypassed for unencoded sites with `KVS_PHP_VERSION`.
- **T1 — confirmed, sharper.** The mutations (template `:70`, `:90`, `:137`) pass
  every `run.sh` suite reading the template. `integration_origin_security.sh`
  catches only the dotfile mutation: no suite at all, integration included,
  requests `/admin/include/*.php` or `/tmp/*.php`, so new request tests are
  needed for those, not only running the existing integration suite.
- **T2 — confirmed; practical note.** `integration_origin_security.sh` passes on
  clean code with the locked nginx digest (`NGINX_TEST_IMAGE`). But
  `as-uid-1000.sh` strips `NGINX_TEST_IMAGE`, so a CI job needs the image tagged
  or the default changed.
- **T3 — confirmed; fix corrected.** `sites/../../escape.example` resolves only when
  `sites/` exists, and the invalid fixture asserts `sites/` is never created
  (`:172`): the sentinel test needs its own fixture with `sites/` pre-created.
  Mitigation: `remove` needs a typed "yes" (`:724`); `stop` has none but runs
  `down` without `-v`. `validate_domain` calls are at `:687` (`stop_site`) and
  `:709` (`remove_site`).
- **T4 — confirmed.** `integration_manticore_startup.sh` does not check the uids
  or modes either.
- **T5 — confirmed; wider.** The suites sourcing `common.sh`
  (`test_admin_hardening`, `test_mariadb_password_argv_hardening`,
  `test_tables_prefix`) also pass the mutation (`common.sh:90`);
  `test_init_resume_hardening` checks a port against its own stub
  `get_project_url` (`:85`).
- **T6 — confirmed.**
- **V1 — confirmed** with GNU tar 1.35 (list, analyze, peek, extract and settle).
  `--quoting-style=literal` keeps `LC_ALL=C`, gives raw bytes, and the peek still
  matches. `tests/test_setup_import_sources.sh:211` uses ASCII names only.
- **V2 — confirmed, broader.** A re-run after a *complete* copy is refused too
  (any later failure, the dump import for example). There is no "reserve":
  `import_free_space_mb_ok` (`import.sh:578-590`) asks for the full `du -sLm` size
  plus 10%. Fix: as the remote branch does, skip the full-size check when the
  marker matches (`docker/setup.sh:2045-2056`), then subtract what the destination
  holds. Leave the archive path (`setup.sh:1916`) alone: re-extracting into the
  stage needs the full size while the old copy is in place.
- **V3 — confirmed** in Debian 13 (glibc 2.41, bash 5.2.37, generated
  `en_US.UTF-8` and `de_DE.UTF-8`; `globasciiranges` does not affect `=~`):
  `münchen.de` and `café.example.com` pass all four domain validators;
  `kvs-münchen`, `kvs-é`, `kvs-ß` pass both prefix validators; C.UTF-8 refuses
  them. Correction: capital `München.de` is refused by reconfigure and
  site-manager, but setup lowercases first. Same flaw in the `TABLES_PREFIX`
  check (`docker/setup.sh:1240`) and in `kvs-export.sh:1620`, `:1690`. Fix:
  `LC_ALL=C [[ … ]]` is not valid bash; `local LC_ALL=C` inside the function works
  and is restored on return, or explicit `[abcdefghijklmnopqrstuvwxyz]` lists;
  `[[:lower:]]` also matches `ü`. Nginx entrypoint call at `:155-159`.
- **V4 — confirmed; fix corrected.** `getent -s dns ahostsv4` skips `/etc/hosts` and
  needs no dnsutils (tested). "Accept a match on any A record" is wrong: with old
  and new A records mid-migration, Let's Encrypt can validate against the old IP.
  Require every distinct A record to equal the server IP, and name the foreign
  ones; the existing stub still passes with that rule.
- **V5 — confirmed (code plus documented behaviour, about 85% sure).** Boulder tries
  IPv6 first and falls back to IPv4 only on connection errors, never on an HTTP
  answer: a stale AAAA to a still-running old server that answers 404 fails
  issuance; one to a dead address mostly falls back. Ports are published on all
  addresses, so a correct AAAA works. Natively, nginx without `listen [::]` gives
  connection-refused and falls back, so native issuance is not broken. Fix
  corrected: on an IPv4-only host `api64.ipify.org` returns IPv4 (there, any AAAA
  is foreign); compare AAAA against locally assigned addresses (`ip -6 addr`)
  rather than one api64 answer (several or privacy addresses); warn, do not fail,
  so headless `DNS_CHOICE=3` does not abort.
- **V6 — real; framing and fix corrected.** Every entry at depth 3 is also one `du`
  (`kvs-export.sh:751-752`), so any flat directory at depth 2 or 3 costs the same.
  The exporter's own default timeout is 0, no limit (`kvs-export.sh:55`); 300 s
  applies only when setup drives it (`setup.sh:1378`). Batching breaks
  `tests/test_kvs_export.sh:480` ("one du per entry"), the du stub (`:296-308`)
  and the asserts at `:472-476` and around `:630-656`; it also changes semantics
  (hard links and `-L` targets counted once per batch, coarser progress, a
  timeout kill loses up to a batch). Rewrite those tests on purpose.

## kvs-export.sh

### E1. Export archive is world-readable

- **Severity:** high (database dump and `setup_db.php` exposed to local users)
- **Confidence:** repro. **Status:** open
- **Where:** `kvs-export.sh:2441` (`tar -chf "$STAGING_DIR/export"`),
  `kvs_publish_export` at `kvs-export.sh:2303`, and the `--dump-only` path
  around `kvs-export.sh:2401`.
- **Defect:** the script sets no `umask` and never `chmod`s the output. The file
  is created with the caller's umask inside the 0700 staging directory, then
  moved out. It keeps the caller's permissions only when an output already
  existed (`cp --attributes-only`).
- **Repro:** as root with `umask 022`, run `./kvs-export.sh` with the output in a
  0755 directory such as `/home/admin` or `/tmp`. The `.tar` is mode 0644.
- **Fix direction:** create the staged output with mode 0600 (`umask 077` around
  the tar/dump, or `chmod 600` on the staged file before `mv`) when no previous
  output exists. Keep the current "preserve the existing file's mode" behaviour.
- **Test:** in `tests/test_kvs_export.sh`, run an export under `umask 022` and
  assert `stat -c %a` is `600`, for the archive and for `--dump-only`.

### E2. Any file change during tar fails the whole export

- **Severity:** high (hours of reading lost on any live site)
- **Confidence:** repro (GNU tar 1.35). **Status:** open
- **Where:** `kvs-export.sh:2435` (stdout case) and `kvs-export.sh:2441`.
- **Defect:** every non-zero tar status is fatal. GNU tar exits **1** for "file
  changed as we read it" and "File removed before we read it", which is normal
  on a live site the script does not freeze (uploads, `admin/logs`, which is
  not excluded). Only status 2 means a fatal error.
- **Repro:** remove or append to a file under the site while `tar -chf` runs:
  tar exits 1, the script prints "tar failed" and deletes the staged export.
- **Fix direction:** treat status 1 as success with a warning that lists what
  changed (or pass `--warning=no-file-changed` plus explicit handling), and
  keep status 2 or higher fatal. Consider also excluding `admin/logs`.
  Decide whether stdout mode (`-o -`) should behave the same.
- **Test:** a stub `tar` on `PATH` that exits 1, asserting that the export is
  published and a warning is printed, and one that exits 2, asserting the
  current failure.

### E3. Output under a symlinked site directory makes tar recurse

- **Severity:** high (fills the production disk; staging is web-served meanwhile)
- **Confidence:** repro (265 MB in seconds, then tar segfaulted). **Status:** open
- **Where:** `kvs_path_inside_site` at `kvs-export.sh:1352-1362`, together with
  `tar -h` (follows symlinks) at `kvs-export.sh:2441`.
- **Defect:** the "output is inside the site" check compares against the
  resolved `SITE_DIR` only. It misses a destination under the target of a
  symlink inside the site. The staging `www -> SITE_DIR` link then puts the
  archive inside its own input.
- **Repro:** `site/contents -> /data`, then `./kvs-export.sh -o /data/x.tar`.
- **Fix direction:** refuse an output (and a staging directory) located under
  the resolved target of any symlink tar will follow inside the site. Cheaper
  alternative: make tar exclude the staging directory and the output path
  explicitly, by their resolved paths.
- **Test:** fixture site with a `contents` symlink to a directory outside it.
  Export to a path under that directory; assert a clear refusal before tar
  starts.

### E4. Non-canonical `--exclude` is reported excluded but archived

- **Severity:** medium (terabytes archived that the user believes are excluded)
- **Confidence:** repro. **Status:** open
- **Where:** `kvs_add_path_option` at `kvs-export.sh:2457-2468`, used by the
  tar `--anchored --exclude=www<path>` built near `kvs-export.sh:2297`.
- **Defect:** only one leading and one trailing `/` are stripped. `./`, `//` and
  `/./` are not normalised, so the tar pattern never matches. The summary still
  lists the path as "excluded (named with --exclude)".
- **Repro:** `--exclude ./contents/videos_sources`, `--exclude
  contents//videos_sources` or `--exclude contents/videos_sources//`: the
  directory is in the archive.
- **Fix direction:** normalise the path (collapse `//`, drop `./` segments,
  strip every leading and trailing `/`), and reject `..` segments.
- **Test:** each of the three forms leaves the directory out of the archive.

### E5. `setup_db.php` parsing reads commented lines and misses valid forms

- **Severity:** medium (may dump the wrong database)
- **Confidence:** repro. **Status:** open
- **Where:** `kvs_define_value` at `kvs-export.sh:343-352`.
- **Defect:** the regex `^.*define\(` takes the first match, including a line
  commented out with `//`, `#` or inside `/* */`. It only accepts
  `define('NAME','value')`: single quotes, lowercase `define`, no space before
  `(`.
- **Repro:**
  - `//define('DB_DEVICE','old_db');` above the real line: `old_db` is used.
  - `define("DB_PASS","x")`, `define ('DB_PASS','x')`, `DEFINE(...)` or
    `define('DB_PASS', "x")`: the value is empty.
- **Fix direction:** skip lines whose first non-blank characters are `//` or `#`,
  allow `define` with any case and spaces before `(`, and accept double-quoted
  values (unescaping `\"` and `\\`). Use the last matching definition, or fail
  when there are several. Stock KVS writes the single-quoted form, so keep it
  working exactly. If `php` is available on the host, parsing the file with
  `php -r` may be the more robust option.
- **Test:** one fixture per form above in `tests/test_kvs_export.sh`.

### E6. Storage server columns shift when one is empty

- **Severity:** low. **Confidence:** the mechanism is reproduced; whether KVS
  leaves `admin_servers.path` empty for FTP/S3 servers is not verified.
  **Status:** open
- **Where:** `kvs-export.sh:1217` (`IFS=$'\t' read`), and the `|` join at
  `kvs-export.sh:1225`.
- **Defect:** tab is IFS whitespace, so `read` collapses consecutive tabs and an
  empty column disappears. A remote server is then reported as "OUTSIDE the
  site directory: not transferred". A title containing `|` also breaks the
  `server_N=` line, because `kvs_one_line` does not strip `|`.
- **Repro:** the row `title<TAB><TAB>1<TAB>http://cdn/` reads as path=`1`,
  remote=`http://cdn/`.
- **Fix direction:** split on a non-whitespace delimiter: have the SQL output use
  `\x1f`, or read the line and split with parameter expansion. Strip or escape
  `|` in titles.
- **Test:** a mocked database row with an empty path.

### E7. IPv6 `DB_HOST` misparsed

- **Severity:** low (fails loudly). **Confidence:** repro. **Status:** open
- **Where:** `kvs_build_connection_args` at `kvs-export.sh:570-585`.
- **Defect:** any value containing `:` is split at its last `:` and the tail is
  taken as the port.
- **Repro:** `DB_HOST='::1'` gives `-h : -P 1`. `[::1]:3307` gives `-h [::1]`,
  which the client rejects.
- **Fix direction:** handle `[addr]:port` and `[addr]`. Treat a value with more
  than one `:` and no brackets as a bare IPv6 address with no port.
- **Test:** unit cases for `::1`, `[::1]`, `[::1]:3307`, `db:3307`, `db`.

## kvs-install.sh

### I1. DNS "wait and retry" loops forever

- **Severity:** high (interactive install stuck; only Ctrl-C stops it)
- **Confidence:** repro (curl, dig and sleep stubbed). **Status:** open
- **Where:** `check_dns_configuration`, `kvs-install.sh:884-896`.
- **Defect:** option 2 sleeps, then calls `check_dns_configuration` again. The
  global `DNS_ACTION` is still `2`, so `until [[ "$DNS_ACTION" =~ ^[1-3]$ ]]`
  skips the prompt and the function waits again, forever.
- **Repro:** a domain whose DNS points elsewhere, answer `2`: the user is never
  asked again.
- **Fix direction:** reset `DNS_ACTION=""` before the recursive call (or before
  the `until` loop), or turn the recursion into a loop that re-prompts.
- **Test:** stub `dig`/`curl` so DNS never matches, stub `sleep`, feed `2` then
  `1` on stdin; assert it continues after one retry.

### I2. Archive copied while still being uploaded

- **Severity:** high (truncated KVS install that later runs keep using)
- **Confidence:** repro (a writer paused mid-file left a 100000 of 1000000 byte
  copy). **Status:** open
- **Where:** `kvs-install.sh:2207-2212`, and the precedence at
  `kvs-install.sh:2192`.
- **Defect:** `while [ ! -f /root/KVS_*.zip ]` stops as soon as the file exists,
  and `cp` runs at once while scp/sftp is still writing. Later runs prefer
  `kvs-archive/` over `/root`, so the complete upload is ignored.
- **Fix direction:** after the file appears, wait until its size is stable over
  a few seconds, then check it with `unzip -tq` before copying. Also check an
  archive already in `kvs-archive/` with `unzip -tq`, and replace it when the
  `/root` one is newer or the existing one is corrupt.
- **Test:** a background writer that pauses mid-file; assert the copied archive
  is complete. A corrupt `kvs-archive/KVS_*.zip` must be reported.

### I3. Standalone install deletes an existing `/root/tmp`

- **Severity:** high (deletes the admin's files)
- **Confidence:** code. **Status:** open
- **Where:** `whatisdomain` at `kvs-install.sh:739-741`, and `rm -rf /root/tmp` at
  `kvs-install.sh:779`.
- **Defect:** the function uses the fixed `/root/tmp`, unzips the whole archive
  into it, then removes the directory. Anything that was already there is
  lost. `cp KVS_* /root/tmp/` also depends on the current directory: run from
  anywhere but `/root`, the `setup.php` domain lookup is silently skipped.
- **Fix direction:** `mktemp -d`, a `trap` to remove it, the archive path made
  absolute, and only `admin/include/setup.php` extracted
  (`unzip -p archive admin/include/setup.php`).
- **Test:** pre-create `/root/tmp/keep` (in a fake root/HOME), run the function,
  assert the file is still there.

### I4. Domain taken from the archive name blocks valid installs

- **Severity:** medium. **Confidence:** repro. **Status:** open
- **Where:** `kvs-install.sh:2218-2239`, `validate_kvs_domain` at
  `kvs-install.sh:721-727`. The same regex is in `docker/setup.sh:637`
  (`validate_domain`), and the email check at `kvs-install.sh:589`.
- **Defect:**
  - The Docker install derives the domain from the `[...]` part of the archive
    name and returns 1 when it is invalid, before `setup.sh` runs. A `DOMAIN`
    in the environment or in `.env` cannot get past it. A renamed
    `KVS_7.0.3.zip` reads as `kvs_7.0.3.zip` and aborts the install.
  - `\.[a-z]{2,}$` rejects every punycode TLD: `xn--e1afmkfd.xn--p1ai`,
    `sub.example.xn--90ais`, and the email `user@example.xn--p1ai`.
- **Fix direction:** when `DOMAIN` is already set (environment or `.env`), use
  it and only warn when the archive name disagrees. When the name has no
  `[...]` part, fall back to asking, or to `DOMAIN`. Accept a final label of
  `[a-z]{2,}` or `xn--[a-z0-9-]+`, in all three places.
- **Test:** `KVS_7.0.3.zip` with `DOMAIN=example.com` proceeds; the
  `xn--p1ai` domain and email are accepted.

### I5. Failed SQL import is reported as success and never redone

- **Severity:** medium. **Confidence:** code (not reproduced). **Status:** open
- **Where:** `install_KVS`, `kvs-install.sh:1130-1163`.
- **Defect:** none of the `mariadb` commands (CREATE DATABASE, CREATE/ALTER
  USER, the import of `install_db.sql` at 1154) has its status checked.
  `install_KVS` returns the status of `configure_kvs_database_file` only.
  `_INSTALL/`, including `install_db.sql`, is removed at 1161 regardless. On a
  re-run, `setup_db.php` exists, so extraction is skipped (1069); the database
  exists, so `db_created=false` and nothing is imported. The site has no tables
  until someone drops the database by hand.
- **Fix direction:** check each `mariadb` command and stop on failure, without
  removing `_INSTALL/`. Decide "already imported" by the presence of a known
  KVS table rather than by the database existing.
- **Test:** a stub `mariadb` that fails on the import; assert a non-zero status,
  `_INSTALL/` still present, and a re-run that imports again.

### I6. `DOMAIN` rewritten in `.env` before `setup.sh` reads the old one

- **Severity:** medium. **Confidence:** code (the export-line case is certain
  from the `sed`; the import impact is not reproduced). **Status:** open
- **Where:** `kvs-install.sh:2234`; it bypasses `docker/setup.sh:3324-3328`
  (`PREVIOUS_DOMAIN`), 960 and 972.
- **Defect:** `sed -i "s/^DOMAIN=.*/…/" .env` runs before `setup.sh` records
  `PREVIOUS_DOMAIN` from `.env`. So `setup.sh` never sees a domain change:
  the rule that "an import completed under the old domain does not count" (960)
  and the retirement and prefix reset (972) are skipped. With
  `DOMAIN=old.com` plus `KVS_IMPORT_COMPLETED` in `.env` and an archive for
  `new.com`, a headless run says "import already completed … source ignored".
  Also, a line written `export DOMAIN=old.com` (which `setup.sh`'s
  `set_env_value` supports) is not matched, but the installer still prints
  "Domain set to: new.com".
- **Fix direction:** do not edit `.env` in `kvs-install.sh`; pass the domain to
  `setup.sh` through the environment (`DOMAIN=… ./setup.sh`), and let its
  `set_env_value` write it after it has recorded the previous value.
- **Test:** `.env` with `DOMAIN=old.com` and an import marker, archive for
  `new.com`: assert that `setup.sh` sees the change.

### I7. IonCube lines appended on every run and on failure

- **Severity:** medium. **Confidence:** code. **Status:** open
- **Where:** `kvs-install.sh:1606-1612`.
- **Defect:** the `zend_extension=` lines are appended with `>>` on every run,
  even when the download, `tar` or `cd ioncube && cp` failed. The function
  returns the status of its final `rm -rf`, so "IonCube configured" is always
  shown. A re-run loads the loader twice (a warning on every PHP start); a
  failed download leaves `php.ini` pointing at a missing `.so`.
- **Fix direction:** stop on each failed step, add the line only when no
  `zend_extension=.*ioncube` line is present, and return a real status.
- **Test:** run the function twice and assert a single line; with a failing
  download stub, assert that nothing is appended and the status is non-zero.

### I8. "Update the Script" corrupts the log and drops arguments

- **Severity:** low. **Confidence:** repro. **Status:** open
- **Where:** `kvs-install.sh:2319`, with the `tee` set up at
  `kvs-install.sh:74-76`.
- **Defect:** `exec bash "$script"` starts a second `tee` on the same
  `LOG_FILE`, truncating it, while the first `tee` is still writing at its old
  offset. The log ends with NUL bytes and duplicated lines. `"$@"` is not
  passed on, so `--dev` is lost.
- **Fix direction:** pass `"$@"` on. Make the second run append (`tee -a`), or
  mark the re-exec with an environment variable so it skips the log setup.
- **Test:** run option 4 with a stubbed download; assert a log without NUL bytes
  and the arguments preserved.

### I9. `www.conf.bak` overwritten on re-run

- **Severity:** low. **Confidence:** code. **Status:** open
- **Where:** `kvs-install.sh:1300`.
- **Defect:** `cp www.conf www.conf.bak` on a re-run replaces the original backup
  with the already-modified file.
- **Fix direction:** `[ -e www.conf.bak ] || cp www.conf www.conf.bak` (or
  `cp -n`).
- **Test:** two runs; assert the backup still holds the original contents.

## cli (kvsctl)

`go test -race ./...` passes, `govulncheck` reports nothing, and `staticcheck`
reports only style hits. A fuzz comparison of `dotenv.Parse` against compose-go
v2.16.2 found no difference. Upgrade rollback, backup and restore were reviewed
and came out clean.

### G1. `dotenv.Set`/`MergeEnv` append CRLF lines the shell misreads

- **Severity:** medium. **Confidence:** repro. **Status:** open
- **Where:** `cli/internal/dotenv/write.go:72-79`; same pattern in `MergeEnv`
  (`cli/internal/instance/instance.go`, around line 379).
- **Defect:** if the file contains a single `\r\n` anywhere, even in a comment,
  every line `Set` appends ends in CRLF. The scripts source `.env` with
  `set -a; . .env`, so the shell reads the value with a trailing `\r`, while
  compose strips it. This breaks the rule that both readers see the same
  value.
- **Repro:** `Set([]byte("# pasted header\r\nDOMAIN=example.com\nSITE_PREFIX=kvs\n"),
  "KVS_STACK_VERSION", "26.10.0")` ends with `KVS_STACK_VERSION=26.10.0\r\n`.
  The shell reads `26.10.0\r`. Variant: `Set("\r\nA=", "B", "0")` also gives the
  untouched last line `A=` a CRLF, so the shell's value of `A` becomes `\r`.
- **Fix direction:** always end appended lines (and the newline added after a
  last line that has none) with LF. `rewrite` already keeps each existing
  line's own ending.
- **Test:** the repro above as a table case in `write_test.go`, and the same
  for `MergeEnv`.

### G2. `${PWD}` in `.env` expands differently from compose

- **Severity:** medium. **Confidence:** code. **Status:** open
- **Where:** `cli/internal/instance/instance.go:224`, compared with
  `cli/internal/dockerx/dockerx.go:549-550`.
- **Defect:** kvsctl expands `.env` with its own `os.Environ()`, whose `PWD` is
  the directory it was started from. It runs compose with
  `PWD=<abs docker dir>`. With `DATA_DIR=${PWD}/data` and
  `kvsctl --root /opt/kvs` run from `/root`, kvsctl reads `/root/data` and
  compose uses `/opt/kvs/docker/data`.
- **Fix direction:** build the lookup environment for parsing the same way as
  for compose, with `PWD` set to the docker directory.
- **Test:** parse an `.env` with `${PWD}` from another working directory, and
  assert the value matches what compose is given.

### G3. doctor fails on distro and Desktop compose version strings

- **Severity:** low (a false failure in a diagnostic). **Confidence:** code; that
  real installs print these strings is likely but not verified. **Status:** open
- **Where:** `cli/internal/doctor/config.go:130`; compare
  `cli/internal/upgrade/plan.go:523`, which deliberately tolerates them.
- **Defect:** `semver.Parse` rejects `2.29.7-desktop.1`, `2.27.1-1` and
  `2.24.6+ds1-0ubuntu1~22.04.1`, and doctor reports "Docker Compose returned an
  unreadable version" as a failure.
- **Fix direction:** parse the leading `MAJOR.MINOR.PATCH` and ignore the
  suffix, as `plan.go` does, or report a warning rather than a failure.
- **Test:** doctor table cases for the three strings.

### G4. `semver.Compare` treats `RC1`/`rc1` and `rc01`/`rc1` as equal

- **Severity:** low (manifests are signed). **Confidence:** repro.
  **Status:** open
- **Where:** `cli/internal/semver/semver.go:71-91`.
- **Defect:** `Compare` lowercases the pre-release label and ignores leading
  zeros in its number, while `Parse` keeps `Pre` as written, and
  `manifest.Find`, the duplicate check and `releaseTag` compare exact strings.
  Such versions tie (their order is left to `sort.SliceStable`), and both can
  appear in a manifest.
- **Fix direction:** have `Parse` reject (or canonicalise) uppercase labels and
  leading zeros, so that equal under `Compare` means equal as strings.
- **Test:** `Parse("26.11.0-RC1")` and `Parse("26.11.0-rc01")` fail, or
  `String()` returns the canonical form.

### G5. Bare word on the last line changes meaning after `Set`

- **Severity:** low (unlikely in a real `.env`, but silent). **Confidence:**
  repro. **Status:** open
- **Where:** `cli/internal/dotenv/write.go:76-79`; also `MergeEnv`
  (`instance.go`, around line 405) and the appends of `Graft` (around
  `write.go:178`).
- **Defect:** compose reads a bare word on the last line, with no trailing
  newline, as the value of an empty key, which nothing uses. Adding the
  newline before the new setting makes it a key alone on its line, which
  compose fills from the environment (and `Isolate` keeps).
- **Repro:** with `FOO=from-shell` in the environment, `Parse("A=1\nFOO")` gives
  `{"":"FOO","A":"1"}`. After `Set(..., "B", "2")` the file is
  `A=1\nFOO\nB=2\n` and parses with `FOO=from-shell`.
- **Fix direction:** refuse to write (return an error) when the last line has
  no `=` and no trailing newline, or comment it out with a note. Do not change
  its meaning silently.
- **Test:** the repro as a `write_test.go` case.

## docker/setup.sh

The repros below ran a sed-patched copy of `setup.sh` with `docker`, `curl`,
`gum` and `ss` stubbed on `PATH`, the way
`tests/test_setup_existing_project_detection.sh` does.

### D1. Headless re-run replaces saved prefix, SSL and cache choices

- **Severity:** high (new compose project name: the stack comes up on new,
  empty volumes and the old database is orphaned)
- **Confidence:** repro. **Status:** open
- **Where:** `docker/setup.sh:1335-1347`, used at `docker/setup.sh:3632-3672` and
  `3698-3723`; same pattern in `select_cache` (`docker/setup.sh:4264`).
- **Defect:** `PREFIX_CHOICE`, `SSL_CHOICE` and `CACHE_CHOICE` default to `1` in
  headless mode and override what `.env` holds. `SITE_PREFIX=kvs` (the legacy
  option 2) is read as "never chosen", so `select_site_prefix` runs again on
  every run; interactively, the prefix question comes back every time and
  Enter switches it.
- **Repro:** `.env` with `SITE_PREFIX=kvs`, `COMPOSE_PROJECT_NAME=kvs`,
  `SSL_PROVIDER=selfsigned`, then `HEADLESS=y ./setup.sh` (the README example).
  `.env` now has `SITE_PREFIX=kvs-mysite`, `COMPOSE_PROJECT_NAME=kvs-mysite` and
  `SSL_PROVIDER=letsencrypt`, saved before the run fails on `EMAIL`. A ZeroSSL
  setup is switched to Let's Encrypt and reissued with `--force`; Memcached is
  replaced by Dragonfly.
- **Fix direction:** when `.env` already holds a domain and these keys, keep
  them unless the matching `*_CHOICE` is given explicitly. Record the legacy
  prefix choice as a value distinct from "unset".
- **Test:** an existing legacy, self-signed, Memcached `.env`; a headless run
  without any `*_CHOICE`; assert the keys are unchanged.

### D2. Port overrides written raw to `.env`, then sourced as code

- **Severity:** high (shell code from a port value runs as root on every later
  run; the value comes from the operator's environment, so the realistic
  failure is a typo or a templated deployment that breaks `.env` for good)
- **Confidence:** repro (the injected command ran). **Status:** open
- **Where:** `docker/setup.sh:3497-3503` (top level); values captured at
  `docker/setup.sh:3291-3307`; `set_env_value` at `docker/setup.sh:779`.
- **Defect:** `HTTP_PORT`, `HTTPS_PORT`, `MARIADB_HOST_PORT`, `CACHE_HOST_PORT` and
  the two `MANTICORE_*` ports are saved to `.env` before any check.
  `set_env_value` refuses newlines but does not quote. HTTP and HTTPS are only
  validated later (`docker/setup.sh:5070`); the four loopback ports never are.
  The next `source .env` (`docker/setup.sh:3672`), and every later run of
  `setup.sh`, `reconfigure.sh` or kvsctl, executes the value.
- **Repro:** `HTTP_PORT='8080$(id -u>/tmp/pwned)'`: `.env` holds that line and
  `/tmp/pwned` is created. `HTTP_PORT='80 443'` leaves a `.env` that breaks every
  later run.
- **Fix direction:** validate before saving (`parse_publish_endpoint` for HTTP
  and HTTPS, `1-65535` for the loopback ports) and refuse anything else before
  writing. Consider making `set_env_value` refuse `$`, backticks, quotes and
  spaces for keys that hold no free text.
- **Test:** headless runs with `HTTP_PORT='80;touch X'` and
  `MARIADB_HOST_PORT=abc`: non-zero exit, `.env` unchanged, `X` absent.

### D3. Staged import dump is world-readable

- **Severity:** high (the whole imported database, including admin password
  hashes and user emails, readable by any local user, possibly for days)
- **Confidence:** code (the modes come straight from the umask and an explicit
  `chmod`). **Status:** open
- **Where:** `import_stage_dump`, `docker/setup.sh:5362-5402`; the native payload
  in `docker/lib/native-import.sh:330` does the same.
- **Defect:** `mkdir -p mariadb/init` under umask 022 gives 0755, then
  `chmod 644 "$target"`. The dump stays in
  `mariadb/init/10-kvs-import.sql*` until `import_finish`, so indefinitely when
  the import fails or waits for `--resume-import`. The raw dump in `import/` is
  kept 0700/0600; this copy is not.
- **Fix direction:** `mariadb/init` 0700 (or 0750 with group 999), the file 0600
  or 0640, owned by 999 (mysql in the image).
- **Test:** stage a dump; assert neither the file nor the directory has any
  "other" permission bit.

### D4. Empty `dhparam.pem` from an interrupted run is kept

- **Severity:** medium (nginx cannot start with the TLS config)
- **Confidence:** repro for the empty file (`timeout 1 openssl dhparam -out f
  2048`); the nginx failure is known nginx behaviour, not run. **Status:** open
- **Where:** `docker/setup.sh:5275-5280`; used by `ssl_dhparam` in `nginx.conf:48`.
- **Defect:** openssl creates the output file before generating anything, and
  the guard is `[ ! -f ]`. After Ctrl-C, an OOM kill or a failed step, the next
  run prints "DH parameters already exist" and keeps a 0-byte file.
- **Fix direction:** generate into a temp file and `mv` it into place; check
  existing files with `[ -s ]` and `openssl dhparam -check -noout -in`.
- **Test:** pre-create an empty `nginx/dhparam.pem`; assert it is regenerated.

### D5. Truncated `gum` download is installed and never replaced

- **Severity:** medium (the setup is broken for good; an unverified binary runs
  as root on every step)
- **Confidence:** repro (tar exit 2, partial executable left, `command -v gum`
  true). **Status:** open
- **Where:** `install_gum`, `docker/setup.sh:3202-3232`.
- **Defect:** the unpinned "latest" GitHub tarball is piped with
  `curl | tar -x` straight into `/usr/local/bin`, with no checksum or
  signature, then `chmod +x`. A truncated stream leaves a partial `gum`; the
  next run finds it with `command -v gum` and does not reinstall. Every
  `run_step` then fails, and `progress_bar` (`gum style`) exits under `set -e`.
  `kvs-install.sh` uses a signed apt repository instead.
- **Fix direction:** pin the version and its sha256, download into a temp dir,
  verify, then `install`. Check that the installed binary runs
  (`gum --version`) before trusting it.
- **Test:** stub `curl` to serve a truncated tarball; assert no
  `/usr/local/bin/gum` and that the fallback output is used.

### D6. Headless pre-flight still prompts and exits silently at EOF

- **Severity:** medium. **Confidence:** repro. **Status:** open
- **Where:** `preflight_checks`, `docker/setup.sh:3182-3185`.
- **Defect:** the "Continue anyway? [y/N]:" prompt is skipped only when
  `PREFLIGHT_BYPASS` is set, not when `HEADLESS=y`. With stdin at EOF, `read`
  returns 1 and `set -e` ends the script with status 1 and no message; with a
  terminal attached, it blocks.
- **Repro:** `HEADLESS=y` with no internet, or less than 10 GB free.
- **Fix direction:** in headless mode without `PREFLIGHT_BYPASS`, print a clear
  error and exit non-zero; use `prompt_read` for the interactive case.
- **Test:** headless run with `curl` stubbed to fail; assert no prompt and an
  explicit error.

### D7. `DNS_CHOICE` unknown or `1` loops forever in headless mode

- **Severity:** medium (endless busy loop hammering ipify/icanhazip)
- **Confidence:** repro (51 iterations without a prompt before the test guard
  stopped it). **Status:** open
- **Where:** DNS retry loop, `docker/setup.sh:5220-5261`. Same family as I1.
- **Defect:** `dns_answer=$DNS_CHOICE` is reused on every pass, and `*) continue`
  (or `1) continue`) re-runs `check_dns` with no prompt and no sleep.
- **Repro:** `DNS_CHOICE=yes` (or `1`) with a DNS mismatch.
- **Fix direction:** validate `DNS_CHOICE` against `1-3`. In headless mode, make
  `1` a bounded retry with a sleep, and an unknown value an error.
- **Test:** extract the loop, stub `check_dns` to return 1, `DNS_CHOICE=yes`;
  assert it exits within a bounded number of iterations.

### D8. `DB_CHOICE` ignored when endoflife.date does not answer

- **Severity:** medium (the data volume is initialised on a newer MariaDB
  series that cannot be downgraded without deleting it)
- **Confidence:** repro. **Status:** open
- **Where:** `select_mariadb_version`, `docker/setup.sh:3768-3832`.
- **Defect:** the function returns ("Using defaults") before looking at
  `DB_CHOICE`, although the menu is built from the static
  `MARIADB_LTS_VERSIONS` and needs no API. A non-numeric `DB_CHOICE` is also
  dropped silently, because `[ -ge ]` fails inside the condition.
- **Repro:** `HEADLESS=y DB_CHOICE=3` (11.4) with `curl` failing gives
  `MARIADB_VERSION=12.3`.
- **Fix direction:** apply `DB_CHOICE` from the static list whatever the API
  does; reject values outside `1-N` with an error.
- **Test:** `curl` stub failing plus `DB_CHOICE=3`; assert
  `MARIADB_VERSION=11.4`.

### D9. `--dev` fails unless `DOMAIN` is given, and ignores the saved domain

- **Severity:** medium. **Confidence:** repro. **Status:** open
- **Where:** `docker/setup.sh:1314-1328`, with `3293` and `3505`.
- **Defect:** dev mode exports `DOMAIN=${DOMAIN:-example.com}` before
  `KVS_DOMAIN_OVERRIDE` is captured. The override then replaces the `.env`
  domain with `example.com`, which headless mode rejects.
  `EMAIL=dev@localhost.local` overrides the saved email the same way.
- **Repro:** `.env` with `DOMAIN=mysite.test`, `./setup.sh --dev`: "ERROR: Set
  DOMAIN to a real domain in headless mode".
- **Fix direction:** do not export the defaults, or apply them only while `.env`
  still holds the placeholder.
- **Test:** `--dev` with a saved domain gets past the domain check and keeps it.

### D10. Multi-site Caddy exception also skips loopback port conflicts

- **Severity:** medium (late failure after the images are built)
- **Confidence:** repro (extracted function). **Status:** open
- **Where:** `docker/setup.sh:5102-5104`.
- **Defect:** when `caddy_publishes_required_multi_site_ports` is true, the
  whole `PUBLIC_PORT_CONFLICTS` list is skipped, including `127.0.0.1:3306`,
  11211, 9306 and 9308.
- **Repro:** `MODE=multi`, Caddy running, a native MariaDB on `127.0.0.1:3306`:
  "Caddy already publishes the required multi-site ports", then
  `compose up mariadb` fails with "port is already allocated".
- **Fix direction:** take only 80/tcp, 443/tcp and 443/udp out of the list for
  Caddy; report the other conflicts as in single-site mode.
- **Test:** the same scenario; assert the 3306 conflict is an error.

### D11. Partial GeoIP database kept as "already configured"

- **Severity:** low (GeoIP silently broken)
- **Confidence:** repro (curl exit 18 left a 1000-byte file). **Status:** open
- **Where:** `select_geoip`, `docker/setup.sh:4582-4595`.
- **Defect:** `curl -fsSL … -o geoip/GeoLite2-Country.mmdb` leaves a partial file
  when the transfer is cut; the next run sees the file and skips the download.
  The file comes from an unpinned third-party mirror with no checksum.
- **Fix direction:** download into a temp file, check it (size, or the MaxMind
  metadata marker `\xab\xcd\xefMaxMind.com` near the end), then `mv`.
- **Test:** stub `curl` to write half a file and exit 18; assert no `.mmdb` is
  left and the next run downloads again.

### D12. Started from another project's directory, it uses that `.env`

- **Severity:** low. **Confidence:** repro (another `.env` went from 644 to 600
  and was sourced before the run stopped at the prefix check).
  **Status:** open
- **Where:** `setup_enter_script_dir`, `docker/setup.sh:41`.
- **Defect:** the script stays in the current directory whenever it holds any
  `docker-compose.yml`. Started from another project's directory, it runs
  `chmod 600`, `source` (as root) and `set_env_value DOMAIN` on that project's
  `.env`.
- **Fix direction:** stay only when `$PWD -ef "$script_dir"`; otherwise `cd` to
  the script's directory as today.
- **Test:** run from a directory holding an unrelated `docker-compose.yml` and
  `.env`; assert that `.env` is untouched.

### D13. Admin password lost when kvs-init fails after setting it

- **Severity:** high (nobody ever sees the admin password; a later run reports
  it as "preserved and verified")
- **Confidence:** code (the only gate is `run_step`'s exit status).
  **Status:** open
- **Where:** `docker/setup.sh:5030-5035` (generated), `:5634-5643` (printed only
  after `run_step … kvs-init` succeeds), `:6008` (summary);
  `docker/init/docker-entrypoint.d/35-harden-admin-users.sh:73-96`;
  `docker/init/init-kvs.sh:36-49`.
- **Defect:** 35-harden writes the new hash, then later init scripts run. If
  one fails (40-configure-database, 50-nginx-rewrites, or 80-manticore when
  kernel-scripts.com is unreachable), `init-kvs.sh` exits 1 and `set -e` ends
  setup before the password is printed. On the re-run with "Keep" (headless
  default `VOLUME_CHOICE=2`), no password is generated, the default-admin probe
  returns 0, and the summary says "Existing non-default password preserved and
  verified".
- **Fix direction:** show the password (or write it to a 0600 file) before
  kvs-init runs, or run 35-harden last; drop "verified" from the summary.
- **Test:** stub `docker compose run kvs-init` to exit 1 on a fresh install;
  assert the one-time password is in the output.

### D14. A failed ACME issuance aborts before cache, Manticore, cron, import finish

- **Severity:** medium (half-started stack; an import may need a full redo)
- **Confidence:** code, with the service dependencies checked in
  `docker/docker-compose.yml`. **Status:** open
- **Where:** `docker/setup.sh:5883` (`configure_direct_acme_certificate || exit $?`),
  before `setup_start_runtime_services` (`:5938`), `import_finish` (`:5954`) and
  `setup_start_cron` (`:5955`). The DNS menu at `:5243` offers "Continue anyway
  (SSL will fail)".
- **Defect:** with DNS still on the old server (normal mid-migration) or Let's
  Encrypt down, only mariadb, php-fpm, nginx (self-signed) and acme run. Cache,
  Manticore and cron never start and the summary is not printed. On an import,
  `KVS_INSTALL_IMPORT` and the staged dump stay; `--resume-import` refuses once
  MariaDB has restarted (for example after a reboot while waiting for DNS), so
  only a full re-import is left.
- **Fix direction:** make an ACME failure a warning: keep the self-signed
  certificate, finish the runtime start, cron and `import_finish`, print the
  retry command, and exit non-zero at the end.
- **Test:** stub the acme exec to fail; assert `setup_start_runtime_services` and
  `import_finish` still run.

### D15. Default-admin checks of setup and 35-harden disagree

- **Severity:** medium (kvs-init stops on "still uses the archive default
  credential"; one more run needed, or every run fails)
- **Confidence:** repro (real MariaDB). **Status:** open
- **Where:** `docker/setup.sh:5473-5484` versus
  `docker/init/docker-entrypoint.d/35-harden-admin-users.sh:102`.
- **Defect:** setup counts `user_id=1 AND login='admin' AND pass=default` and
  treats a query error as 0; 35-harden checks `user_id=1 AND pass=default`.
  - Interrupted first run (volume initialised, kvs-init not run): the re-run
    keeps the database, the table is missing, setup reads 0 and generates no
    password; 30-import-database seeds admin/123 and 35-harden fails.
  - A kept or imported database whose user 1 was renamed but still has the
    default password: setup reads 0 on every run, and every run fails.
- **Fix direction:** decide inside kvs-init (generate there and report back),
  or use the same predicate in setup; treat a missing table as "will be
  seeded"; print the real login instead of a hardcoded `admin`.
- **Test:** both queries against MariaDB with `(1,'boss',default)`, and with no
  table.

### D16. One-time admin password saved in the 0644 install log

- **Severity:** medium (a credential kept in a file that goes into backups and
  log shipping, while setup says it is not logged)
- **Confidence:** repro (the log was 644 and held "One-time admin password:
  SECRETabc"). **Status:** open
- **Where:** `docker/setup.sh:5636-5639` ("It is not written to .env or the setup
  log"); `kvs-install.sh:30` (`umask 022`), `:52` and `:71-76` (all output, setup
  included, through `tee -i /root/kvs-install.log`).
- **Fix direction:** print the password to `/dev/tty` or the saved fd 3 only, or
  to a separate 0600 file; create the install log 0600.
- **Test:** source `kvs-install.sh`, call `initialize_runtime_output <tmpfile>`,
  run the print block; assert the password is absent and the mode is 600.

### D17. Switch to self-signed keeps a public cert nothing renews

- **Severity:** low (expired certificate after at most 90 days, while setup says
  self-signed is in use)
- **Confidence:** repro (real nginx image: the CA certificate's sha256 was
  unchanged). **Status:** open
- **Where:** `configure_direct_tls_profile`, `docker/setup.sh:4412-4442` (removes
  the acme container), and `:5881`; `docker/nginx/docker-entrypoint.sh:143-149`
  keeps any valid pair, and its monitor (`:217-232`) only regenerates
  self-signed certificates.
- **Repro:** re-run with `SSL_CHOICE=3` on a site with a Let's Encrypt
  certificate (for example when moving behind Cloudflare, as the menu suggests).
- **Fix direction:** with `SSL_PROVIDER=selfsigned`, replace a certificate that is
  not self-signed, or have the monitor regenerate one near expiry.
- **Test:** a CA-signed 2-day leaf in the volume, entrypoint with
  `SSL_PROVIDER=selfsigned`; assert it is replaced.

### D18. Step output goes to predictable `/tmp` files

- **Severity:** low (step output readable by a local user; a symlink attack
  where `fs.protected_symlinks=0`)
- **Confidence:** a pre-created 666 file was written into on a host with
  `protected_regular=0`; on distro defaults, a denial of service at most.
  **Status:** open
- **Where:** `log_command`, `docker/setup.sh:346` (`/tmp/log_cmd_$$.log`);
  `run_step`, `:400` (`/tmp/run_step_$$.log`).
- **Fix direction:** `mktemp` under the 0700 `$LOG_DIR`.
- **Test:** pre-create the predictable name; assert setup does not write to it.

## Container runtime and nginx

The nginx repros render `conf/nginx/templates/kvs.conf.tpl` through the real
`docker/nginx/docker-entrypoint.sh`, as `tests/integration_origin_security.sh`
does, on the pinned nginx image (1.31.8) against a php-fpm container from the
local php image (8.1.34).

### C1. PHP runs in upload directories, `.phar` included

- **Severity:** critical (an uploaded `.php` or `.phar` is remote code
  execution)
- **Confidence:** repro. **Status:** open
- **Where:** the generic `location ~ \.php$` at `conf/nginx/templates/kvs.conf.tpl:141`;
  PHP-FPM keeps its defaults (`cgi.fix_pathinfo=1`,
  `security.limit_extensions=.php .phar`), which `docker/php/php.ini` does not
  change.
- **Defect:** nothing denies PHP under `/contents/` (only `^~ /contents/videos/`
  is internal), and the PHP block has no `try_files $fastcgi_script_name =404`.
  `docker/init/docker-entrypoint.d/10-config-php.sh:94` skips `contents/`
  because "PHP does not run there", which is false.
- **Repro:** `/contents/other/evil.php` returned `PWNED-fpm-fcgi` (200);
  `/contents/other/up.phar/x.php` returned `PHAR-EXEC` (200) through the
  PATH_INFO fallback. `.jpg/a.php` is blocked by `limit_extensions`.
- **Fix direction:** deny `\.(php|phar)` under `contents`, `tmp` and `langs`
  before the PHP handler; add `try_files $fastcgi_script_name =404;`; set
  `security.limit_extensions = .php` and `cgi.fix_pathinfo=0`. Apply the same
  to `docker/multi-site/nginx/kvs-caddy.conf.template` and to the native
  `conf/nginx/conf.d/domain.conf`.
- **Test:** an integration test with real FPM requesting `/contents/x.php` and
  `/contents/x.phar/y.php`, expecting 403 or 404.

### C2. Root init container runs a script PHP can write

- **Severity:** critical (uid 1000 to root: a code execution in KVS becomes a
  root setuid binary on the host bind mount)
- **Confidence:** repro (the planted script wrote `ran as uid=0`, and a copied
  bash came out `-rwsr-xr-x root`). **Status:** open
- **Where:** `docker/init/docker-entrypoint.d/60-permissions.sh:127-137`
  (`bash install_permissions.sh`); same trust problem in
  `docker/init/docker-entrypoint.d/50-nginx-rewrites.sh:25-32`.
- **Defect:** every kvs-init run executes `$KVS_PATH/_INSTALL/install_permissions.sh`
  as root when that file and `.kvs-extraction-complete` exist. Both live in the
  web root, which uid 1000 (PHP-FPM, cron) owns. The marker stays for good, and
  `90-cleanup` removes `_INSTALL` after each run, so an attacker only has to
  recreate the script before the next `setup.sh` or `site-manager.sh` run. No
  service sets `no-new-privileges`. In `50-nginx-rewrites.sh`,
  `_INSTALL/nginx_config.txt` (writable by PHP) is copied verbatim into the
  nginx include on every run.
- **Fix direction:** take `install_permissions.sh` and `nginx_config.txt` only
  from the staging directory or the archive of the same run, and keep the
  "extracted here" marker in the init container's own `/tmp`, never in the
  site. Add `security_opt: [no-new-privileges:true]` to the services.
- **Test:** plant `_INSTALL/install_permissions.sh` (owned by 1000, writing
  `id -u` to a file) next to an existing `.kvs-extraction-complete`, run
  `60-permissions.sh` as root, and assert the script did not run.

### C3. Asset regexes win over the internal-directories deny

- **Severity:** high (files in `admin/data`, `admin/logs` and `tmp` downloadable)
- **Confidence:** repro for the precedence. That KVS's `nginx_config.txt` marks
  source directories with plain prefixes, and that sensitive media sits in
  `admin/data` or `tmp`, is plausible. **Status:** open
- **Where:** asset regexes at `conf/nginx/templates/kvs.conf.tpl:74` and `:80`,
  before the deny at `:136`. Same order in
  `docker/multi-site/nginx/kvs-caddy.conf.template` (64 and 70 before 132), and
  in `conf/nginx/conf.d/domain.conf` (`general.conf` is included before line
  41).
- **Defect:** nginx uses the first matching regex, so the comment's "evaluated
  first" holds only for `.php`. Any asset extension under the denied
  directories, or under a path the KVS rewrites mark `internal` with a plain
  prefix, is served.
- **Repro:** 200 with the secret body for `/admin/data/system/x.js`,
  `/admin/data/system/x.css`, `/tmp/upload.mp4` and `/admin/logs/x.svg`. With a
  plain `location /contents/videos_sources/ { internal; }` include,
  `/contents/videos_sources/0/1/1.mp4` and `/contents/albums/sources/1/1.jpg`
  also returned 200. `.php` and `.txt` got 403.
- **Fix direction:** move the deny regex (with a `^/_INSTALL/` entry, see C7)
  above the asset regexes, or turn the denied directories into `^~` prefix
  locations with a nested exception for the two uploader scripts.
- **Test:** extend `tests/integration_origin_security.sh` with `.js`, `.mp4` and
  `.svg` requests under each denied directory, expecting 403.

### C4. TLS 1.3 0-RTT on, replayable, invisible to PHP

- **Severity:** medium (replayable early-data requests reach PHP undetected)
- **Confidence:** repro (`openssl s_client -sess_in sess.pem -early_data
  req.txt` twice: "Early data was accepted" and 200 both times).
  **Status:** open
- **Where:** `docker/nginx/nginx.conf:58-59`.
- **Defect:** `ssl_early_data on;` is set. The only signal is
  `proxy_set_header Early-Data`, which does nothing for `fastcgi_pass`, and the
  template passes no `HTTP_EARLY_DATA`. `ssl_session_tickets off` does not
  prevent it.
- **Fix direction:** remove `ssl_early_data`, or pass
  `fastcgi_param HTTP_EARLY_DATA $ssl_early_data;` and return 425 for non-GET
  requests sent as early data.
- **Test:** an `s_client` replay test expecting early data to be rejected.

### C5. SVG and font responses lose every security header

- **Severity:** medium (uploaded SVGs, which can carry script, are served
  without nosniff or frame protection)
- **Confidence:** repro. **Status:** open
- **Where:** `conf/nginx/templates/kvs.conf.tpl:80-84`.
- **Defect:** the `add_header Access-Control-Allow-Origin` in that location
  stops it from inheriting the server-level `add_header` lines.
- **Repro:** `/a.css` returned X-Frame-Options, nosniff and HSTS; `/a.svg`
  returned only `access-control-allow-origin: *`.
- **Fix direction:** put the security headers in an include and repeat it in
  every location that has its own `add_header`, or use
  `add_header_inherit merge` (nginx 1.29.3 and later). Consider
  `Content-Security-Policy: script-src 'none'` on SVG.
- **Test:** assert the security headers on `.svg` and `.woff2` responses.

### C6. PHP-FPM can rewrite phpMyAdmin's `config.inc.php`

- **Severity:** medium (a KVS-level code execution captures the MariaDB root
  credentials of the next phpMyAdmin login)
- **Confidence:** code (ownership and mount are explicit). **Status:** open
- **Where:** `docker/docker-compose.yml:86` mounts `phpmyadmin-data` read-write
  into php-fpm; `docker/phpmyadmin/init.sh:257-258` makes `config.inc.php`
  `1000`-owned, mode 600.
- **Fix direction:** `config.inc.php` owned by root with group 1000, mode 0640;
  mount the volume `:ro` in php-fpm, with a separate writable mount for its
  `tmp`.
- **Test:** assert `config.inc.php` is not writable by uid 1000.

### C7. `_INSTALL/` served as static files

- **Severity:** low (window: `_INSTALL` is kept after a failed import, and
  re-extracted when the database is empty while nginx is already serving)
- **Confidence:** repro that nginx serves it; the window is from code.
  **Status:** open
- **Where:** `conf/nginx/templates/kvs.conf.tpl` (no deny for `/_INSTALL/`);
  `docker/init/docker-entrypoint.d/30-import-database.sh:201` keeps it on
  failure.
- **Repro:** `/_INSTALL/install_db.sql` returned 200.
- **Fix direction:** `location ^~ /_INSTALL/ { deny all; }` in every template.
- **Test:** request it, expect 403.

### C8. Init re-runs rewrite the title; Manticore cron failure hidden

- **Severity:** low. **Confidence:** code. **Status:** open
- **Where:** `docker/init/docker-entrypoint.d/10-config-php.sh:188`;
  `docker/manticore/docker-entrypoint.sh:222`.
- **Defect:**
  - `s/KVS/${DOMAIN}/` on `project_title` runs on every init run: an imported
    "KVS Tube" becomes "example.com Tube", and a title with "KVS" twice
    changes again on the next run.
  - `service cron start || echo` lets Manticore start without cron: the hourly
    reindex never runs and the healthcheck stays green.
- **Fix direction:** rewrite the title only for a fresh archive (when the
  `/PATH` placeholder was present). Fail the Manticore start when cron does
  not start, or make the healthcheck look at the last reindex.
- **Test:** run `10-config-php.sh` twice on an imported `setup.php`; assert the
  title is unchanged.

### C9. PHP-FPM workers exceed MariaDB's 151 connections on 38 GiB+ hosts

- **Severity:** medium (`ERROR 1040 Too many connections` under load)
- **Confidence:** repro for the arithmetic and the server limit; the site
  failure end to end is plausible (it assumes each busy worker holds one
  connection). **Status:** open
- **Where:** `configure_php_fpm`, `docker/php/fpm-config.sh:100-104`; the `mariadb`
  command in `docker/docker-compose.yml:132-139` sets no `max_connections`
  (nothing in the repo does).
- **Defect:** automatic `max_children = MemTotal * 25% / 64 MiB` has no upper bound
  and ignores MariaDB's default of 151 connections. 64 GiB gives 256 children,
  128 GiB gives 512; `mariadb:12.3.3` reports `@@max_connections=151`, and 160
  concurrent sessions got nine 1040 errors. Cron and the Manticore indexer also
  hold connections.
- **Fix direction:** cap automatic `max_children` (for example 128, or a
  `PHP_FPM_MAX_CHILDREN_CAP` setting), and/or pass `--max-connections` to MariaDB
  from the same budget plus headroom. `tests/test_php_fpm_resources.sh` cases are
  all at or below 32 GiB (128 children), so a cap of 128 or more keeps them
  passing.
- **Test:** a 64 GiB `MemTotal` fixture gives `max_children` at most the configured
  `max_connections` minus a reserve.

### C10. Internal TLS trust installs a CA:TRUE self-signed cert as a root

- **Severity:** low (whoever holds the nginx key, in the acme-certs volume, can
  intercept every outbound TLS connection from PHP-FPM and cron)
- **Confidence:** repro. **Status:** open
- **Where:** `self_signed`, `docker/tls/internal-trust.sh:19-25`, used by `publish`
  (`:33-44`) and `sync_trust` (`:73-87`); neither `certificate_pair_is_valid`
  (`docker/nginx/docker-entrypoint.sh:60-122`) nor
  `nginx_certificate_matches_provider` (`docker/reconfigure.sh:1146`) checks
  basicConstraints.
- **Defect:** only subject equals issuer and `openssl verify -purpose sslserver
  -verify_hostname` are checked. The repo's own generator adds `CA:FALSE`, but an
  operator-supplied `openssl req -x509 …` certificate gets `CA:TRUE` by default.
- **Repro:** with such a certificate and `SSL_PROVIDER=selfsigned`, `publish` then
  `sync` installed it; a leaf for `api.github.com` signed with the nginx key then
  verified `OK` against `/etc/ssl/certs/ca-certificates.crt`, and PHP's
  `openssl_x509_checkpurpose(…, X509_PURPOSE_SSL_SERVER)` trusted it.
- **Fix direction:** in `self_signed`, refuse unless basicConstraints is absent or
  `CA:FALSE` (`openssl x509 -noout -ext basicConstraints`); have nginx's
  `certificate_pair_is_valid` regenerate such a pair. The repo's certificates
  carry `CA:FALSE`, so `tests/test_internal_tls_retry.sh` and
  `tests/integration_internal_tls.py` should be unaffected.
- **Test:** publish a CA:TRUE self-signed certificate; `publish` and `sync`
  refuse it, and the bundle does not verify a leaf for another hostname.

### C11. Buffer pool of 5M is accepted, but MariaDB refuses to start

- **Severity:** low. **Confidence:** repro (mariadb 11.4.13 and 12.3.3).
  **Status:** open
- **Where:** `database_configure_resources`, `docker/lib/database.sh:531`
  (`[ "$pool_mb" -lt 5 ]`, "at least 5M").
- **Defect:** `MARIADB_BUFFER_POOL_SIZE_REQUEST=5M` is saved to `.env`, then MariaDB
  aborts with "innodb_page_size=16384 requires innodb_buffer_pool_size >= 6 MiB";
  `database_wait_ready` reports a stopped container and every re-run reuses the
  saved 5M.
- **Fix direction:** minimum 6M (or 8M), with the message updated. No test covers
  the boundary (`tests/test_database_resources.sh` uses 64M as its smallest).
- **Test:** 5M refused before `.env` changes; 6M accepted.

## reconfigure.sh and multi-site

### R1. `remove` of a new site deletes a single-mode primary's data

- **Severity:** high (`docker compose down -v` on the primary's project)
- **Confidence:** repro (real Docker: the primary's container and volume were
  deleted). **Status:** open
- **Where:** `docker/multi-site/site-manager.sh:459` (`add_site`), `:484`
  (`ensure_site_prefix_available`), `:735` (`remove_site`); primary prefix from
  `docker/setup.sh:3623`.
- **Defect:** the only prefix-collision check is `sites/.primary.env`, which
  exists only in multi mode. A single-mode primary's project (`kvs-` plus the
  domain without its TLD, dots turned into `-`) can equal a new site's
  `kvs-<domain_to_safe>`. The validator also accepts single-label and numeric
  names, unlike `reconfigure.sh`.
- **Repro:** primary `my-site.com` has the prefix `kvs-my-site`;
  `site-manager.sh add my.site` gets `kvs-my-site` too and succeeds;
  `remove my.site` runs `down -v` on `kvs-my-site`. Same with primary
  `example.com` and site `example`.
- **Fix direction:** read `COMPOSE_PROJECT_NAME`/`SITE_PREFIX` from `docker/.env`
  in single mode as well; refuse `add` when a container or volume labelled
  `com.docker.compose.project=<prefix>` exists; before `down -v`, check that
  the `com.docker.compose.project.working_dir` label is the site directory.
- **Test:** `docker/.env` with `SITE_PREFIX=kvs-my-site` and no `.primary.env`:
  `add my.site` fails, and `remove` never calls `down -v` on a project whose
  working directory differs.

### R2. Two sites can claim the same `www` host, breaking Caddy for all

- **Severity:** high (every later reload fails; a Caddy restart takes all sites
  down)
- **Confidence:** repro (`caddy validate` on `caddy:2-alpine`: "ambiguous site
  definition: `www.a.com`"). **Status:** open
- **Where:** `docker/multi-site/site-manager.sh:479-484` and `:276-296`
  (`add_site`, `write_caddy_site_config`, `configure_primary_site`).
- **Defect:** the collision check only looks for `<domain>.caddy`, not for the
  new site's host names in another site's route. `add a.com` creates a
  `www.a.com` redirect; `add www.a.com` is then accepted. The reverse order, a
  primary `a.com`, or `sub.a.com` with `USE_WWW=true` fail the same way. The
  Caddy healthcheck (`caddy validate`) goes unhealthy, and `reconfigure.sh`
  refuses to run in multi mode.
- **Fix direction:** collect every host in `caddy/sites/*.caddy` plus the
  primary's, and refuse `add` and `primary-config` on any overlap. Optionally
  run `caddy validate` on the candidate set before the `mv`.
- **Test:** `add a.com` then `add www.a.com` fails and leaves no
  `www.a.com.caddy`; same for `add www.x.com` then `add x.com`.

### R3. Multi-mode rollback leaves the recreated containers changed

- **Severity:** medium (the site is down while the script says it was restored)
- **Confidence:** repro with stubs (`MOCK_CADDY_VALIDATE_RESULTS=0,57,0`) that
  nothing recreates the containers; the outage is from the nginx host map.
  **Status:** open
- **Where:** `docker/reconfigure.sh:1474` and `:1522`; `multi_rollback_on_exit`
  (`:975`), `rollback_multi_application_state` (`:890`).
- **Defect:** nginx, php-fpm and cron are force-recreated with the new `.env`
  before the commit point. On failure only the route, the reservation, the
  database and the files are restored, and the script prints "Application
  state restored". Example: a primary `sub.a.com` going from `USE_WWW=true` to
  `false`, then any later failure: the old route (canonical `www.sub.a.com`)
  comes back, but nginx now returns 444 for `www`.
- **Fix direction:** on rollback, recreate nginx, php-fpm and cron with the
  previous environment, or validate everything before recreating anything.
- **Test:** the existing Caddy-validation rollback case with old `USE_WWW=true`
  and new `false`; assert a second recreate with the old value, or a message
  that does not claim a full restore.

### R4. Edited `DOMAIN` half-applies and takes the site down

- **Severity:** medium (site down, a real certificate issued for the new name)
- **Confidence:** code (the stubs do not model database users).
  **Status:** open
- **Where:** `docker/reconfigure.sh:352` (no check that the domain is the
  installed one); `:1488`, `:1513` and `:1522` run before the first query
  (`:505`, `:1518`).
- **Defect:** `DOMAIN` decides the webroot mount, the nginx host and
  certificate, and the MariaDB user and database. In single mode every
  container-changing step runs before the first SQL query. With `DOMAIN`
  edited from `old.com` to `new.com`, nginx and acme are recreated for
  `new.com`, a Let's Encrypt certificate is issued for it, php-fpm and cron are
  recreated on an empty `/var/www/new.com`, then `run_query` fails with access
  denied for user `new.com` and the script exits without rollback: `old.com`
  gets 444. Multi mode fails safely earlier, at the snapshot.
- **Fix direction:** before any change, compare `DOMAIN` with the running nginx
  container's `DOMAIN` or `setup.php`'s `project_url`, and refuse with "use
  setup.sh to change the domain".
- **Test:** single-mode fixture whose running nginx says `old.com` while `.env`
  says `new.com`; assert no `compose up` and no `acme.sh` call.

### R5. `remove` hides a failed `down -v`, then deletes the config

- **Severity:** medium (volumes left behind; a later `add` of the same domain
  reuses them with new passwords and fails to start)
- **Confidence:** repro. **Status:** open
- **Where:** `docker/multi-site/site-manager.sh:735-742`.
- **Defect:** `docker compose down -v 2>/dev/null || true` swallows any failure,
  and the site directory and route are removed anyway. MariaDB keeps the old
  root password, so `start` of a re-added site fails at "Could not inspect the
  KVS admin account". Also, `read` at EOF on the webroot prompt aborts under
  `set -e` before Caddy is reloaded.
- **Fix direction:** fail and keep the site directory when `down -v` fails;
  check afterwards that no volume labelled with the project remains; have
  `add` refuse when such volumes exist.
- **Test:** compose stub returning 1 on `down`; `remove` fails and keeps
  `sites/<domain>`.

### R6. Manual `caddy-start` sets the ACME email to `admin@example.com`

- **Severity:** low (expiry notices lost; Let's Encrypt likely rejects the
  contact, so issuance and renewals may fail)
- **Confidence:** repro for the email (`docker compose -p multi-site -f
  docker-compose.caddy.yml config` renders `admin@example.com`); the issuance
  failure is not reproduced. **Status:** open
- **Where:** `start_caddy`, `docker/multi-site/site-manager.sh:839`;
  `docker-compose.caddy.yml:46`; `Caddyfile:17`.
- **Defect:** only `setup.sh` passes `ACME_EMAIL`. The `caddy-start` that `add`
  prints as the next step passes nothing, and `multi-site/` has no `.env`, so
  Compose recreates Caddy with the default.
- **Fix direction:** have `start_caddy` read `EMAIL` from `../.env` (or keep a
  `multi-site/.env` with `ACME_EMAIL`), and refuse to start without one.
- **Test:** `caddy-start` with a stub docker and no `ACME_EMAIL` exported;
  assert the real email is passed.

## Site import (docker/lib/import*.sh, native-import*.sh)

`docker/setup.sh` runs with `set -e` only, never `pipefail`, which matters for
M3.

### M1. Shell injection on the old server in the tar fallback

- **Severity:** high (commands run on the old server as the SSH user, often
  root, outside `sudo`)
- **Confidence:** repro (through a simulated remote `bash -c`).
  **Status:** open
- **Where:** `import_remote_files`, `docker/lib/import.sh:2951`
  (`tar_excludes+=("'--exclude=.$pattern'")`), used at `:3250` in
  `import_ssh … tar -C "$dir" "${tar_excludes[@]}" -chf - .`.
- **Defect:** the exclude patterns are wrapped in single quotes without
  escaping, and the remote shell parses the command line again. The patterns
  come from the old server's `exclude_N` lines, which `kvs-export.sh:1173-1175`
  writes as `/<name>` for every hidden top-level directory, with the raw name.
- **Repro:** a directory named `.a';touch PWNED;'` in the old site root and no
  rsync on the old server: `touch PWNED` ran, then the transfer failed with 127.
  A harmless name such as `.bob's` also breaks the fallback.
- **Fix direction:** quote each argument with `printf %q` before it goes into the
  ssh command line, or refuse patterns outside a safe character set. Never
  hand-wrap arguments in `'…'`. Check the other `import_ssh` call sites for the
  same pattern.
- **Test:** stub `import_ssh` to run `bash -c "$*"`, call
  `import_remote_files <dir> <dest> no "/.a';touch X;'"`, assert `X` is absent.

### M2. Untrusted dump runs shell commands in the MariaDB container

- **Severity:** high (an imported dump is code, not data)
- **Confidence:** repro (mariadb image 12.3.3: the init log printed the
  injected text). **Status:** open
- **Where:** `import_prepare_dump`, `docker/lib/import.sh:302-382`;
  `native_import_run`, `docker/lib/native-import-runtime.sh:228-238` (it
  concatenates `data/*.sql` into `docker_process_sql`).
  `native_import_validate_schema` does not reject client commands either.
- **Defect:** mariadb client commands (`\!`, `system`, `source`) pass through,
  and the entrypoint replays the file with the mariadb client. Older mysqldump
  output carries no sandbox header.
- **Repro:** a `10-kvs-import.sql` containing the line `\! echo PWNED-FROM-DUMP`
  printed `PWNED-FROM-DUMP` during init.
- **Fix direction:** make the first line of the prepared dump, and of the native
  schema stream, `/*M!999999\- enable the sandbox mode */`. With it, the same file
  failed with "ERROR at line 3: Not allowed in the sandbox mode" (verified).
- **Test:** `import_prepare_dump` output starts with the sandbox line; same for
  the native schema stream.

### M3. Decompression errors ignored; a corrupt dump is marked complete

- **Severity:** medium (corrupt rows imported and later verified as complete)
- **Confidence:** repro. **Status:** open
- **Where:** `import_prepare_dump`, `docker/lib/import.sh:354-358`
  (`import_dump_cat | sed | import_innodb_row_format - || return 1`), and
  `import_inspect_dump`, `docker/lib/import.sh:206` (same pattern).
- **Defect:** without pipefail only the last stage's status counts, so the
  comment "Stop on read/filter failures before appending a completion marker"
  does not hold. A gzip or zstd checksum failure shows only after the data was
  written.
- **Repro:** a valid `d.sql.gz` with its CRC trailer flipped (`gzip -t` fails):
  inspect returned "complete" with status 0, and prepare returned 0 and
  appended the `KVS_INSTALL_IMPORT` marker.
- **Related:** for archive and directory sources, a dump without the "Dump
  completed" line (truncated) only gets a yellow warning, then the import goes
  on and is marked complete.
- **Fix direction:** run these pipelines with `set -o pipefail` in a subshell, or
  check `PIPESTATUS`; in `import_inspect_dump`, report "not complete" when the
  decompressor fails. Consider refusing a dump without "Dump completed" unless
  the operator confirms.
- **Test:** a CRC-corrupted `.gz` and a truncated `.zst` make both functions
  fail, and prepare leaves no output file.

### M4. Absolute symlinks on the old server copied as root, readable by PHP

- **Severity:** medium (root-only files of the old server end up readable by
  PHP on the new one)
- **Confidence:** repro (local rsync with the import's flags). **Status:** open
- **Where:** `rsync_args`, `docker/lib/import.sh:3002`
  (`--copy-unsafe-links … --no-perms --chown=1000:1000`, run under umask 0),
  with `--rsync-path="sudo -n rsync"` or a root SSH user.
- **Defect:** every absolute or escaping symlink is followed with root
  privileges on the old server, and its target lands in `/var/www/<domain>`
  owned by 1000:1000. Nothing reports or limits these links before the
  transfer: `import_check_site_links` runs after, when they are plain files.
- **Repro:** `site/innocent.txt -> /etc/shadow` arrives as
  `-rw------- 1000 1000 innocent.txt`. `ln -s / x` would copy the whole old
  server.
- **Fix direction:** have the exporter list the external links in its detect
  report and require confirmation or an allowlist (for example, only targets
  under the reported storage-server paths). Or use `--munge-links` or
  `--safe-links` by default and make dereferencing opt-in.
- **Test:** a stubbed transfer whose source links to a 0600 file outside the
  site must refuse or warn before copying.

### M5. A resumed pass can run with no free-space check

- **Severity:** low (can fill the filesystem holding `/var/www` and the Docker
  volumes)
- **Confidence:** code (not run). **Status:** open
- **Where:** `import_remote_files`, `docker/lib/import.sh:3013-3019` and
  `:3075-3096` (the `skip_count=yes` branch); `import_remote_free_space_check`,
  `docker/setup.sh:2045-2056` (the same-source branch checks only the dump).
- **Defect:** when the previous count timed out (`.count-timeout` exists), the
  next pass skips the count and takes the `count_status=124` branch, which
  never reaches `import_free_space_mb_ok`. The second copy of the dump in
  `mariadb/init` and the loaded database size are not counted on any path.
- **Fix direction:** when the count is skipped or times out, check against the
  saved count minus what the destination already holds (or `site_fs_used_mb`),
  and refuse instead of only warning.
- **Test:** pre-create the count-timeout flag and a saved count, set free space
  below the remainder, assert `import_remote_files` refuses before rsync runs.

## kvsctl commands

### K1. `backup --keep` deletes the archive a rollback would replay

- **Severity:** high (rollback impossible after routine backups)
- **Confidence:** repro (temporary Go test). **Status:** open
- **Where:** `runBackup`, `cli/cmd/kvsctl/main.go:1043` and `:1065` (only
  `state.UpgradeBackup` is protected from `pruneBackups`); the fallback in
  `cli/internal/upgrade/rollback.go:1046-1053` (`backup.Latest(dir, state.Previous)`);
  `--skip-backup` allowed at `cli/internal/upgrade/plan.go:498`, recorded empty
  at `run.go:515`.
- **Defect:** after `upgrade --skip-backup` on a release that migrates the
  database (allowed when it is not one-way), rollback replays the newest backup
  of the previous version. Pruning does not know this rule, although the
  `--keep` help says "the one a rollback would replay are never removed".
- **Repro:** state `{Current: 1.1.0, Previous: 1.0.0, Database: migrates}` with
  `backup-1.0.0-…` and `backup-1.1.0-…`; `kvsctl backup --keep 1` (or five daily
  cron backups at the default `--keep 5`) deletes the 1.0.0 archive, and
  `kvsctl rollback` refuses with "no backup of 1.0.0 is kept".
- **Fix direction:** compute the rollback archive with the same rule as
  `rollbackDump` and pass it to `pruneBackups`; same for the upgrade's own prune.
- **Test:** the scenario through `runBackup` with the real `backup.Prune`; assert
  `backup.Latest(dir, "1.0.0") != ""`.

### K2. Relative restore path recorded; `recover` elsewhere replays the wrong file

- **Severity:** medium (a half-replayed database and stopped services that
  `recover` cannot finish)
- **Confidence:** repro for the resolver; journal and recover by code.
  **Status:** open
- **Where:** `resolveBackup`, `cli/cmd/kvsctl/restore.go:243-256`; stored as
  `Replay: archive` at `cli/internal/upgrade/replay.go:169`, read at `:404` and
  `:324`.
- **Defect:** an argument with a slash that does not match the list (whose
  paths are absolute) is returned as given, relative to the current directory,
  and the journal records it that way.
- **Repro:** `cd /opt/kvs && kvsctl restore backups/backup-1.0.0-20261001-000000.tar`,
  the replay is cut short, then `kvsctl recover` runs from `/root` or cron:
  ENOENT, or a different file with that relative name. `--env` fails the same
  way through `ArchivedEnv`.
- **Fix direction:** `filepath.Abs` in `resolveBackup`, and in `Runner.Restore`.
- **Test:** `t.Chdir(tmp)`; `resolveBackup(dir, "sub/b.tar", nil)` returns an
  absolute path; `journal.Replay` is absolute after `Restore`.

### K3. Scripts check the kvsctl lock but never hold it

- **Severity:** medium (two writers on the same compose project and `.env`)
- **Confidence:** code. **Status:** open
- **Where:** `docker/setup.sh:288-309` (`flock --shared --nonblock "$lock" true`),
  `docker/reconfigure.sh:122-146`, `kvs-install.sh` (around line 1975); kvsctl's
  lock in `cli/internal/instance/lock.go`.
- **Defect:** `flock … true` takes the lock and releases it at once. The scripts
  refuse to start while kvsctl runs, but `kvsctl upgrade` or `restore` succeeds
  while `setup.sh` is rebuilding images, writing `.env` or running
  `compose up`. There is also a window between the check and the first change.
- **Fix direction:** hold a shared lock for the whole run (`mkdir -p kvsctl;
  exec 9<>"$root/kvsctl/lock"; flock -n -s 9`), so kvsctl's exclusive lock fails
  with exit 6; have kvsctl's message say a script may hold it.
- **Test:** a shell test holding the lock as the scripts would, then
  `kvsctl backup` expecting exit 6.

### K4. A second `restore --latest` replays the safety backup

- **Severity:** medium (the retry undoes the first restore)
- **Confidence:** code. **Status:** open
- **Where:** `cli/cmd/kvsctl/restore.go:223-225` (`list[0]`), with
  `cli/internal/upgrade/replay.go:189` (the safety backup goes to the same
  `BackupDir` with the next sequence number, so it ranks newest).
- **Defect:** when `restore --latest --yes` exits 1 because the stack is
  unhealthy although the database was restored, retrying the same command
  replays the pre-restore dump.
- **Fix direction:** mark safety backups in `backup.json` (a kind field) and skip
  them in `--latest`, or store them in a separate subdirectory; label them in
  the picker.
- **Test:** two archives, a restore with a fake replay that writes the safety
  archive; a second `chooseBackup(latest=true)` does not return it.

### K5. `update-cli --version <older>` does nothing and exits 0

- **Severity:** low. **Confidence:** repro. **Status:** open
- **Where:** `cli/cmd/kvsctl/updatecli.go:79-83`; `cliState` in
  `cli/cmd/kvsctl/main.go`.
- **Defect:** an explicitly named release goes through the "newer than" check of
  the default target. Binary 1.3.0 with `--version 1.2.0` prints "nothing to
  do" and exits 0, while the help says it installs the named release.
- **Fix direction:** with `--version`, install unless equal; if downgrades are
  refused on purpose, return an error (non-zero exit).
- **Test:** `Version="1.3.0"`, target `1.2.0` with `--version`: the binary is
  replaced, or an error is returned.

### K6. `restore <archive> --latest` silently ignores `--latest`

- **Severity:** low. **Confidence:** code. **Status:** open
- **Where:** `cli/cmd/kvsctl/restore.go:217-219`.
- **Defect:** the argument is checked first and the conflict is not reported, so
  a script that passes a stale name with `--latest` replays the named archive.
- **Fix direction:** a `usageError` (exit 2) when both are given.
- **Test:** `runKvsctl("restore", "x", "--latest")` exits 2.

Minor, not listed: `logs --tail -1` becomes `--tail 0` (nothing instead of
everything), and `logs` exits 0 on SIGTERM.

## Native (standalone) install

Tested by rendering `conf/nginx/nginx.conf`, `conf/nginx/conf.d/domain.conf`
and `conf/nginx/globals/*` as `aptinstall_nginx` does, in the nginx 1.31.8
image against a real php-fpm, plus stock `php.ini-production` files (upstream
PHP 8.1 and Debian trixie `php8.4-fpm`).

**How the C findings apply to the native config:**

- **C1 applies, partly:** `/contents/other/evil.php` returns 200 and runs. The
  `.phar` PATH_INFO trick does not (404, thanks to `try_files
  $fastcgi_script_name =404` in `php_fastcgi.conf`), but a bare
  `/contents/other/up.phar` is served as raw source. `/tmp/x.php` gets 403
  (`domain.conf:41` comes before the PHP handler at `:76`).
- **C3 applies identically:** `general.conf` is included at `domain.conf:30`,
  before the deny at `:41`; `/admin/data/system/x.js`, `/admin/logs/x.svg`,
  `/tmp/upload.mp4` and a plain-prefix internal `contents/videos_sources/…mp4`
  return 200.
- **C4 applies:** `ssl_early_data on;` at `conf/nginx/nginx.conf:55`.
- **C5 applies:** `/a.svg` carries only `access-control-allow-origin`.
- **C7 does not apply:** `install_KVS` deletes `_INSTALL` before the site is
  enabled.

### N1. `setup_db.php` (DB password) left world-readable by `chmod -R 755`

- **Severity:** high (any local account reads the database password)
- **Confidence:** code. **Status:** open
- **Where:** `install_KVS`, `kvs-install.sh:1104` (`chmod -R 755 "$KVS_PATH"`).
- **Defect:** every file, `admin/include/setup_db.php` included (with `DB_PASS`
  in clear), becomes 0755, and `sed -i` keeps the mode. All code is also owned
  and writable by the FPM user (`chown -R www-data`). A re-run applies 755 to
  the whole site again. The Docker path restricts `setup_db.php` (see
  `60-permissions.sh`); the native path does not.
- **Fix direction:** directories 0755, files 0644, `setup_db.php` 0640
  `root:www-data`; do not give www-data ownership of the code.
- **Test:** `stat -c %a` on `setup_db.php` after `install_KVS` with stubs: 640.

### N2. www redirect server always answers 444 in the default mode

- **Severity:** medium (`https://www.<domain>/` broken by default)
- **Confidence:** repro (curl rc 56/92 instead of a 301). **Status:** open
- **Where:** `conf/nginx/conf.d/domain.conf:97` (`if ($host != $server_name)`),
  with `REDIRECT_SERVER_NAME="*.$DOMAIN"` from `whatisdomain`
  (`kvs-install.sh:777`).
- **Defect:** `$server_name` is the literal `*.example.com`, so the comparison
  never matches a real host and every request is closed. The certificate covers
  www whenever its DNS points at the server. With `USE_WWW=true`
  (`.example.com`), apex to www does redirect (301).
- **Fix direction:** drop that `if` from the redirect server (its `server_name`
  already selects the hosts), or compare against `$URL`.
- **Test:** render both modes; expect 301 for https www and apex.

### N3. `php.ini` timeout edits are no-ops; no `fastcgi_read_timeout`

- **Severity:** medium (long admin actions and uploads fail on native only)
- **Confidence:** repro. **Status:** open
- **Where:** `aptinstall_php`, `kvs-install.sh:1038-1039`;
  `conf/nginx/globals/php_fastcgi.conf`.
- **Defect:** the patterns are `;max_execution_time = 30` and
  `;max_input_time = 30`, but stock `php.ini-production` has them uncommented,
  and `max_input_time` is `60`. After the sed, 30 and 60 remain (Docker uses
  300 and 360, `docker/php/php.ini:6-7`). The native `php_fastcgi.conf` has no
  `fastcgi_read_timeout` (the Docker template sets 300), so nginx returns 504
  after 60 s anyway.
- **Fix direction:** anchor on `^;?\s*max_execution_time\s*=.*`, or better, drop a
  `conf.d/99-kvs.ini` with the values; check the result; add
  `fastcgi_read_timeout 300`.
- **Test:** run the edit on a fixture `php.ini-production` and grep the
  expected values.

### N4. Failed ACME silently ships self-signed; storage TLS check left on

- **Severity:** medium (install reported complete with a self-signed
  certificate, and KVS storage checks fail TLS)
- **Confidence:** code. **Status:** open
- **Where:** `install_acme.sh`, `kvs-install.sh:1264-1267`;
  `configure_kvs_servers` (`:1580`), run at step `:349`, before
  `install_acme.sh` at `:352`.
- **Defect:** `ssl_skip` comes from `SSL_PROVIDER`, not from the certificate
  actually installed. After the fallback (DNS not propagated, or headless
  ZeroSSL without `EMAIL`, which is never defaulted), the step prints "SSL
  certificates configured", `streaming_skip_ssl_check=0` stays, and nothing
  retries ACME before the 365-day self-signed certificate expires. Same family
  as D14 on the Docker path.
- **Fix direction:** warn loudly, or return non-zero, on fallback; set
  `streaming_skip_ssl_check` from the outcome, after the certificate step.
- **Test:** stub `acme.sh` to exit 1; assert a warning or failure and
  `ssl_skip=1`.

### N5. nginx configs always fetched from `main`, failures unchecked

- **Severity:** medium (a tagged installer deploys whatever `main` holds; a
  failed download leaves nginx down at the very end)
- **Confidence:** code. **Status:** open
- **Where:** `aptinstall_nginx`, `kvs-install.sh:982-998`.
- **Defect:** hard-coded `raw.githubusercontent.com/.../main/conf/...`, ignoring
  the local checkout, `SCRIPT_VERSION` and `KVS_INSTALL_BRANCH` (documented in
  the header at `:12`, honoured by the Docker path). No `curl` has `|| return`;
  a failed download only shows at the final `nginx restart` in `install_acme.sh`.
- **Fix direction:** use the files next to the script when present, otherwise
  the tag or branch; `curl -f … || return`; `nginx -t` before enabling.
- **Test:** stub `curl` returning 22 for one file; expect the step to fail.

### N6. No KVS rewrites file for an existing site on a new host

- **Severity:** medium (`nginx: [emerg] open() "/etc/nginx/globals/kvs.conf"
  failed`; the install ends with nginx down)
- **Confidence:** repro (`nginx -t`) and code. **Status:** open
- **Where:** `install_KVS`, `kvs-install.sh:1111-1112`, with
  `extract_kvs_archive` skipping extraction; the fallback download is commented
  out at `:989`.
- **Defect:** `globals/kvs.conf` comes only from `_INSTALL/nginx_config.txt`.
  When `/var/www/$DOMAIN/admin/include/setup_db.php` already exists, nothing is
  extracted and there is no re-extraction from the archive (Docker's
  `50-nginx-rewrites.sh` does that). On the same host, a re-run keeps stale
  rewrites.
- **Fix direction:** `unzip -p "$archive" _INSTALL/nginx_config.txt` when
  `_INSTALL` is absent; refuse an empty file.
- **Test:** existing-site fixture; assert `kvs.conf` is written and not empty.

### N7. yt-dlp can be replaced by an HTTP error page, as root, nightly

- **Severity:** low (video grabbing broken until a later good run)
- **Confidence:** repro (curl exits 0 on a 404 without `-f`). **Status:** open
- **Where:** `install_yt-dlp`, `kvs-install.sh:713`; root cron at `:1476`.
- **Defect:** `curl -L … -o "$bin_dir/yt-dlp"` without `-f`, writing in place:
  a 404 or 5xx body ("Not Found") overwrites the binary and the step passes.
  The Docker path (`docker/cron/yt-dlp-update.sh`) checks the sha256.
- **Fix direction:** `curl -fsSL -o tmp`, verify (sha256 from the release, and
  that it runs), then `mv`.
- **Test:** a stub server answering 404; assert the old binary is kept.

### N8. Printed phpMyAdmin URL unreachable; its install cannot fail

- **Severity:** low. **Confidence:** repro for the URL (Host=IP gets an empty
  reply); code for the rest. **Status:** open
- **Where:** `setupdone`, `kvs-install.sh:1651`; `aptinstall_phpmyadmin`,
  `:1046-1055`.
- **Defect:** it prints `http://$IPV4/phpmyadmin`, but the port-80
  `default_server` returns 444. `aptinstall_phpmyadmin` checks none of its
  curl, tar or sed calls (unlike `updatephpMyAdmin`): an empty `PHPMYADMIN_URL`
  leaves an empty `config.inc.php` and prints "phpMyAdmin installed". A re-run
  regenerates `config.inc.php` and the blowfish secret over local edits.
- **Fix direction:** print `https://$URL/phpmyadmin/`; reuse `updatephpMyAdmin`
  for the first install.
- **Test:** assert the printed URL; an empty download page must fail the step.

## Release and supply chain

### S1. Dispatch from a branch named like a version mixes tag and branch

- **Severity:** medium (a signed manifest pairs a commit and bundle with images
  and binaries built from other code)
- **Confidence:** repro for the git ambiguity (`warning: refname '26.12.0' is
  ambiguous`, resolved to the tag); the softprops default is from its
  documentation. **Status:** open
- **Where:** `.github/workflows/release.yml:7` (`workflow_dispatch`);
  `.github/scripts/release-version.sh` checks only `$GITHUB_REF_NAME`.
- **Defect:** `github.ref_type` is never checked, so a dispatch from a branch
  named `26.12.0` passes. Images and binaries are built from `GITHUB_SHA` (the
  branch head), while `git rev-parse "${TAG}^{commit}"` and `bundle --ref "$TAG"`
  resolve to a tag of the same name if one exists, because git prefers
  `refs/tags`. Without such a tag, softprops gets no `target_commitish` and
  GitHub creates the tag on the default branch head, not on the built commit.
- **Fix direction:** `if: github.ref_type == 'tag'` on the prepare job (or fail
  when `GITHUB_REF` is not `refs/tags/$tag`); use `refs/tags/$TAG` in every
  `rev-parse` and in `--ref`; pass `target_commitish: ${{ github.sha }}`.
- **Test:** `tests/test_release_workflow.sh` asserts the ref-type guard and the
  `refs/tags/` prefix.

### S2. Actions pinned by mutable tag in privileged jobs

- **Severity:** medium (a moved tag runs code with write access to the repo,
  its releases and the GHCR images; it cannot sign a manifest)
- **Confidence:** repro (YAML parse of every `uses:`). **Status:** open
- **Where:** every workflow. For example `softprops/action-gh-release@v3` in
  the publish job (`contents: write`, environment `release`, token persisted
  in `.git/config`); `docker/login-action@v4` and `docker/build-push-action@v7`
  with `packages: write`; `orhun/git-cliff-action@v4`, which writes the release
  body. `docker.yml:39` runs `hadolint/hadolint:v2.14.0` with no digest.
  `renovate.json` automerges every update, majors included, without
  `helpers:pinGitHubActionDigests`.
- **Fix direction:** pin every `uses:` to a 40-hex SHA with a version comment;
  add `helpers:pinGitHubActionDigests`; set `persist-credentials: false` where
  nothing pushes; stop automerging majors.
- **Test:** the workflow suite fails on any `uses:` not matching
  `@[0-9a-f]{40}`.

### S3. Failed lock lookup swallowed; PHP image built from a floating tag

- **Severity:** medium (an unpinned base signed into a release)
- **Confidence:** repro (series 8.5: "no entry for php-fpm 8.5", exit 0,
  `PHP_BASE=` written). Today the matrix-versus-lock check in
  `tests/test_release_workflow.sh` catches this case before the images job;
  the build step itself has no guard. **Status:** open
- **Where:** `.github/workflows/release.yml:229`; same pattern in
  `.github/workflows/docker.yml:89`.
- **Defect:** `echo "PHP_BASE=$(resolve-bases.sh --get …)"` hides the status of
  the command substitution, even under `bash -e`. The empty value then hits
  `ARG PHP_FROM=${PHP_BASE:-php:${PHP_VERSION}-fpm}` in the php and cron
  Dockerfiles, which falls back to the floating tag.
- **Fix direction:** `base=$(…)` on its own line, then `[ -n "$base" ]`; in the
  release, refuse an empty or digest-less `PHP_BASE`, or drop the fallback for
  CI builds.
- **Test:** run the step body with a stub lock lacking the series; expect a
  non-zero exit.

### S4. Lock check reads only the first `ARG` line and never `FROM`

- **Severity:** medium (the CI check passes while a Dockerfile builds on an
  unpinned base)
- **Confidence:** repro (scratch copy of `docker/`, plus a build showing
  Docker uses the second global `ARG` default). **Status:** open
- **Where:** `dockerfile_bases`, `docker/bin/resolve-bases.sh:190`.
- **Defect:** only the first `ARG <BASE>=` line is read, and `FROM` lines are
  never checked. Adding `ARG NGINX_BASE=nginx:latest` just before
  `FROM ${NGINX_BASE}`, or changing `docker/init/Dockerfile` to
  `FROM debian:latest`, still prints "the Dockerfiles build on the lock".
- **Fix direction:** require exactly one `ARG <BASE>=` line, every `FROM` to be
  `${ARG}`, `${PHP_FROM}` or a stage name, and reject unpinned
  `COPY --from=<external image>`.
- **Test:** both mutations above, through `RESOLVE_BASES_DOCKER_DIR`, must
  fail.

### S5. Manticore PHP plugin installed unverified by default

- **Severity:** medium (any modified zip at the URL becomes PHP code run by
  PHP-FPM)
- **Confidence:** code (the branch is explicit). **Status:** open
- **Where:** `docker/init/docker-entrypoint.d/80-manticore.sh:53-87`; defaults
  `docker/.env.example:128` and `docker/docker-compose.yml:380`.
- **Defect:** the init downloads `https://kernel-scripts.com/files/manticore.zip`;
  `MANTICORE_PLUGIN_SHA256` defaults to empty, and empty means "accept anything
  and log the sha256". It is documented, but no shipped default pins it.
- **Fix direction:** ship a pinned sha256 (release manifest or `.env.example`)
  and refuse an empty value unless an explicit opt-out is set.
- **Test:** with the variable empty and a stub URL, the script exits non-zero.

### S6. Registry digest header trusted without hashing the body

- **Severity:** low (the "two independent sources agree" claim is weaker than
  stated)
- **Confidence:** repro (httptest case). **Status:** open
- **Where:** `cli/cmd/kvsctl-release/registry.go:130-179`; `checkImage`,
  `cli/cmd/kvsctl-release/manifest.go:695`.
- **Defect:** `Docker-Content-Digest` is never compared with `sha256(body)`, nor
  are an index's sub-manifest and the config blob checked against their
  digests. `checkImage` accepts any string starting with `sha256:`. Also,
  `imageLocation` switches to plain `http` for any host starting with
  `localhost` or `127.0.0.1`, such as `localhost.example.com`.
- **Repro:** header `sha256:aaaa…` with a body hashing to `sha256:89f8…` (layer
  size 999999999) is accepted, and its layers, sizes and diff IDs are signed.
- **Fix direction:** verify each body against the requested or claimed digest,
  validate digests with `^sha256:[0-9a-f]{64}$`, match the http hosts exactly.
- **Test:** the httptest case must return an error.

### S7. `push.yml` and `markdown-lint.yml` have no `permissions:`

- **Severity:** low (depends on the repository's default token setting)
- **Confidence:** repro (YAML). **Status:** open
- **Where:** `.github/workflows/push.yml`, `.github/workflows/markdown-lint.yml`.
- **Defect:** they run on every push with the default token scope, and run
  `ludeeus/action-shellcheck@2.0.0` and `DavidAnson/markdownlint-cli2-action@v25`
  by tag. With a read/write default, those actions get a write token.
- **Fix direction:** `permissions: contents: read` at the top of each.
- **Test:** the workflow suite requires a `permissions` block in every
  workflow.

### S8. Multi-site images are outside the lock

- **Severity:** low. **Confidence:** repro (grep). **Status:** open
- **Where:** `docker/multi-site/docker-compose.caddy.yml:30` (`caddy:2-alpine`,
  the TLS front end); `docker/multi-site/docker-compose.site.yml.template:134`
  (`mariadb:${MARIADB_VERSION}`), `:185` (`dragonfly:latest`) and `:203`
  (`memcached:alpine`).
- **Defect:** none of them is in `images.lock` or `COMPOSE_IMAGES`, and the
  release override does not cover them, so "the lock pins every runtime image"
  does not hold for multi-site.
- **Fix direction:** add them to `RUNTIME_IMAGES` and `COMPOSE_IMAGES`, with
  digests.
- **Test:** `--check-dockerfiles` fails on any compose `image:` without
  `@sha256:`.

## Documentation against code

Places where the README, `.env.example` or the scripts' own menus promise
behaviour the code does not deliver. Each one was checked against the code once
and is not yet independently verified.

### W1. `MENU_OPTION=2` "Add site" runs a broken native install, even on Docker

- **Severity:** high (on a Docker host it can re-own a Docker site's files away
  from uid 1000)
- **Confidence:** code. **Status:** open
- **Doc:** `README.md:259` (headless table: `MENU_OPTION` `1-5`, "2=Add site").
- **Code:** `kvs-install.sh:2259` labels it "Add another KVS website (work in
  progress, not working)"; `:2270-2272` runs `whatisdomain` then `install_KVS`,
  the standalone path, whatever the install type. `install_KVS` (`:1100-1104`)
  runs `chown -R www-data` and `chmod -R 755 /var/www/$DOMAIN`, calls `mariadb` on
  the host and writes `/etc/nginx/globals/kvs.conf`; `$PHP` is never set on this
  path.
- **Consequence:** no usable second site; if the domain is an existing Docker
  site, its files lose uid 1000 ownership and PHP loses write access. Docker
  sites are added with `docker/multi-site/site-manager.sh add`.
- **Fix direction:** doc now (drop or flag the value, point to
  `site-manager.sh`); code: refuse option 2 on Docker hosts, or route it to
  `site-manager.sh`.
- **Test:** `MENU_OPTION=2` on a Docker-mode fixture refuses without touching
  `/var/www`.

### W2. `kvs-install.sh --help` (any unknown argument) starts an install

- **Severity:** medium. **Confidence:** repro (`parse_arguments --help -h`
  returned without exiting). **Status:** open
- **Code:** `kvs-install.sh:41-44` ("Unknown args are ignored"); `main`
  (`:2467-2479`) then reaches `manageMenu` or `chooseInstallationType`, and on a
  host without `/var/www` goes straight to `dockerInstall` (`:1666-1670`), which
  pipes get.docker.com into `sh`, clones `/opt/kvs` and runs `setup.sh`.
  `setup.sh` and `reconfigure.sh` do have `--help`.
- **Fix direction:** handle `-h`/`--help`; refuse unknown options (keep
  backward compatibility for any documented legacy one).
- **Test:** `kvs-install.sh --help` prints usage and exits 0 without side
  effects; `--bogus` exits 2.

### W3. `site-manager.sh add` always uses PHP 8.1 and `IONCUBE=YES`

- **Severity:** medium (a KVS 7.0.3+ site's encoded files fail on PHP 8.1)
- **Confidence:** code. **Status:** open
- **Doc:** `README.md:179` and `docker/.env.example:42-47` (PHP 8.3 for KVS 7.0.3
  and newer).
- **Code:** `docker/multi-site/site-manager.sh:461` (`local php_version=8.1`),
  `:541` and `:544` write `PHP_VERSION=${php_version}` and `IONCUBE=YES`; the
  archive version and its encoding are never read.
- **Fix direction:** reuse `setup.sh`'s `kvs_documented_php_version` and
  `detect_ioncube`.
- **Test:** `add` with a 7.0.3 archive fixture writes `PHP_VERSION=8.3`; an
  unencoded archive writes `IONCUBE=NO`.

### W4. Standalone headless ignores `SSL_CHOICE` and `KVS_EMAIL`

- **Severity:** medium (`SSL_CHOICE=3` still tries Let's Encrypt and opens UFW
  80/443; `SSL_CHOICE=2` is silently ignored; the ACME account has no email)
- **Confidence:** code. **Status:** open
- **Doc:** `README.md:260` and `:262` (`KVS_EMAIL` "required for Let's
  Encrypt/ZeroSSL", `SSL_CHOICE` 1-3, in the table shared with `INSTALL_TYPE`);
  the standalone headless example at `:275-284` sets neither.
- **Code:** `kvs-install.sh:251-258` defaults `SSL_PROVIDER=letsencrypt` in
  headless mode; `KVS_EMAIL` appears nowhere in `kvs-install.sh`; the SSL and
  email questions exist only in the interactive branch (`:483-611`); `:1246` runs
  `acme.sh --install -m "$EMAIL"` with an empty email. Related to N4.
- **Fix direction:** map `SSL_CHOICE` and `KVS_EMAIL` in the standalone headless
  path, or document `SSL_PROVIDER` and `EMAIL` for it.
- **Test:** headless standalone with `SSL_CHOICE=3` never calls `acme.sh`.

### W5. `.env.example` gives the wrong default container prefix

- **Severity:** low (scripts or backup jobs using `kvs-php` or
  `kvs_mariadb-data` miss the real containers and volumes)
- **Confidence:** code. **Status:** open
- **Doc:** `docker/.env.example:8` ("Default: kvs (containers: kvs-php,
  kvs-mariadb, volumes: kvs_mariadb-data…)").
- **Code:** `docker/setup.sh:3620-3661` and `:3675-3677`: with `SITE_PREFIX=kvs`,
  the default choice (also the headless default) replaces it with
  `kvs-<domain minus TLD>` and sets `COMPOSE_PROJECT_NAME` to match. See D1.
- **Fix direction:** doc.

### W6. Standalone PHP-FPM is never set to "static"

- **Severity:** low. **Confidence:** code. **Status:** open
- **Doc:** `README.md:526` (dynamic below 4 GB of RAM, static above).
- **Code:** `configure_dynamic_php_fpm`, `kvs-install.sh:1274-1306`, only rewrites
  the four dynamic values from half of RAM at 64 MB per worker; it never sets
  `pm` and has no 4 GB threshold.
- **Fix direction:** doc, or implement the threshold.

### W7. The "monitoring tools" (ncdu, vnstat, nload) are not installed

- **Severity:** low. **Confidence:** repro (grep: they appear only in the
  README). **Status:** open
- **Doc:** `README.md:532`. **Code:** the `aptinstall` package list,
  `kvs-install.sh:680-706`.
- **Fix direction:** doc or code.

### W8. Supported KVS versions disagree across docs, Docker and kvsctl

- **Severity:** low (loud failures; nothing is changed)
- **Confidence:** code. **Status:** open
- **Doc:** `README.md:1` ("Tested with 5.5.1, 6.1.2, …"); the kvsctl section
  (`README.md:440-447`) gives no KVS minimum.
- **Code:** Docker, the default, refuses KVS 6.2.0 and older
  (`docker/setup.sh:1633-1655`; `README.md:552` does say PHP 7.4 is
  standalone-only); `.github/release.env` has `KVS_MIN=7.0.0`, and
  `cli/internal/upgrade/plan.go:119-122` blocks kvsctl upgrades for 6.2.1 to 6.x
  Docker sites.
- **Fix direction:** doc: say which versions each path supports.

Not a clear mismatch, but wider than an operator would expect: in multi-site
mode with `SSL_PROVIDER=selfsigned`, `docker/reconfigure.sh:1478-1480` sets
`streaming_skip_ssl_check = 1` on every storage row, remote servers with valid
certificates included (`.env.example:15-17` and `SECURITY.md` keep verification
only for single-site).

## Test suites that give false confidence

Each one was proved by mutation: the production code it claims to cover was
broken in a scratch copy, and the suite still passed (run with `CI=true` through
`.github/scripts/as-uid-1000.sh`). Not yet independently verified.

### T1. nginx deny rules checked as text only, never by request

- **Severity:** high (guards C1, C3 and the `setup_db.php` exposure)
- **Where:** `tests/test_nginx_hardening.sh:39-58`
  (`assert_protected_locations_precede_php`) and `:68-104`
  (`assert_kvs_internal_directories_denied_before_php`), called at `:512-524`.
- **Defect:** they check that the `location` lines exist and come before
  `location ~ \.php$`, and test the regex against their own copy of it; they
  never look inside the blocks.
- **Mutations that still passed every `run.sh` suite reading the template:** in
  `conf/nginx/templates/kvs.conf.tpl`, the internal-directories `deny all;` to
  `allow all;` (nginx then serves `admin/include/setup_db.php`, with the database
  password, as plain source); the dotfile block `deny all;` to `allow all;`;
  `location ~* /tmp/.*\.php$ { internal; }` to `{ }`.
- **Fix direction:** render the template and send real requests (as
  `tests/integration_origin_security.sh` does), asserting 403 or 404 for
  `/admin/include/setup_db.php`, `/admin/data/x.php`, `/.private/x.css` and
  `/tmp/x.php`; at minimum, check that each block's body is `deny all;` or
  `internal;`.

### T2. 15 of the 16 integration suites never run in CI

- **Severity:** high
- **Where:** `tests/run.sh:6-12` runs `test_*.sh` plus
  `integration_cloudflare_realip.sh` only; `.github/workflows/tests.yml:71` runs
  only `tests/run.sh`, and no other workflow runs the rest.
- **Defect:** `integration_origin_security.sh`, `integration_nginx_healthcheck.sh`,
  `integration_native_import.sh`, `integration_resume_*.sh`,
  `integration_php_security.py` and the others are manual only.
- **Evidence:** with T1's dotfile mutation, every `run.sh` suite passed while
  `integration_origin_security.sh` failed ("hidden file …/.private/proof.css
  returned HTTP 200"); on clean code it passes. (It pulls `nginx:alpine`; Docker
  Hub rate limits may require pointing it at the locked nginx digest.)
- **Fix direction:** run the integration suites in `run.sh` or a CI job, on the
  locked images, failing (not skipping) under `CI=true` when Docker or an image
  is missing.

### T3. `site-manager.sh remove` traversal check passes for the wrong reason

- **Severity:** medium (guards a `down -v` and `rm -rf` path; relates to R1 and
  R5)
- **Where:** `tests/test_multisite_manager_hardening.sh:125-133` and `:172-178`.
- **Defect:** the traversal target does not exist, so the script exits on "Site …
  does not exist" whether or not `validate_domain` runs.
- **Mutation:** deleting `validate_domain "$domain" || return 1` from `remove_site`
  and `stop_site` still passed this suite, `test_setup_multisite_hardening.sh`
  and `test_reconfigure_hardening.sh`. Without validation, an existing target
  gets `docker compose down -v` and `rm -rf "$site_dir"`. No suite tests `remove`
  of a real site at all.
- **Fix direction:** create the directory `sites/../../escape.example` resolves to,
  with a sentinel file; assert it survives, that the output says "Invalid
  domain", and that docker was not called. Add a `remove` test on a real site
  fixture.

### T4. Manticore runtime privilege check can never run in CI

- **Severity:** medium (searchd not root, `manticore.conf` with the database
  password mode 600)
- **Where:** `tests/test_cron_hardening.sh:201-235`, gated on
  `MANTICORE_RUNTIME_CONTAINER`, which nothing sets; `as-uid-1000.sh` also runs
  suites with `env -i` (PATH, LANG and CI only).
- **Evidence:** `MANTICORE_RUNTIME_CONTAINER=no-such-container CI=true
  as-uid-1000.sh tests/test_cron_hardening.sh` passes; without the wrapper it
  fails with "Manticore runtime container is not running".
- **Fix direction:** start the container in the suite, or move the check into an
  integration suite that runs in CI and fails under `CI=true` instead of
  skipping.

### T5. Project URL assertions in a subshell cannot fail

- **Severity:** low
- **Where:** `tests/test_docker_hardening.sh:723` and `:726`, inside
  `( … ) || fail`, where `set -e` is off and only the last command counts.
- **Mutation:** in `get_project_url` (`docker/init/lib/common.sh`),
  `port_suffix=":${port}"` to `port_suffix=""` (non-443 ports dropped from the
  URL written to `setup.php` and the database): all 40 tests passed.
- **Fix direction:** `|| exit 1` on each line, or move the checks out of the
  subshell.

### T6. A stub's `fail` does not stop the `install_gum` test

- **Severity:** low
- **Where:** `tests/test_kvs_install.sh:1082`
  (`curl() { fail "curl must not run without gpg"; }`): in this suite `fail` only
  returns 1, and `install_gum` treats a failed curl as a failed key fetch.
- **Mutation:** removing the `command -v gpg` guard in `install_gum`: the log
  shows "FAIL: curl must not run without gpg", then "PASS", and the suite exits 0.
- **Fix direction:** have the stub write a marker file and assert it is absent.

Heads-up: `tests/test_phpmyadmin_init_hardening.sh:302` requires `config.inc.php`
owned `1000:1000` with mode 600, which is exactly C6; a C6 fix must change that
assertion on purpose.

Searched and found clean: no grep on a file that never exists (all 79 suites run
with a logging grep wrapper), no test function defined but never called, no bare
assertion between `set +e` and `set -e`, Docker and CI skips fail correctly
under `CI=true`, no `t.Parallel` in Go and every table is iterated.

## Same value, two readers

Values computed or parsed in two places that disagree. Each pair was run on the
same input. Not yet independently verified.

### X1. `DISABLE_KVS_SUPPORT_ACCESS=true` silently reversed by a second `.env` reader

- **Severity:** medium (the operator turns KVS support access off; setup leaves it
  on and says how to turn it off)
- **Confidence:** repro (extracted block against real compose). **Status:** open
- **Where:** `docker/setup.sh:5053` reads `.env` with `source` (last line wins,
  `export` and quotes accepted), then `:5060` re-reads it with
  `sed -n 's/^DISABLE_KVS_SUPPORT_ACCESS=//p' .env | head -n 1` (first line wins,
  `export` lines invisible, quotes kept) and exports the result at `:5069`; compose
  prefers the process environment, so kvs-init gets it
  (`docker/docker-compose.yml:372`, `35-harden-admin-users.sh:112`).
- **Repro:**
  - `.env.example`'s `DISABLE_KVS_SUPPORT_ACCESS=false` plus an appended `=true`:
    compose alone reads `true`, setup runs compose with `false`.
  - `export DISABLE_KVS_SUPPORT_ACCESS=true`: same (`set_env_value` keeps the
    "export" prefix, so it persists across runs).
  - `DISABLE_KVS_SUPPORT_ACCESS="true"`: setup exits with "must be true or false".
- **Fix direction:** drop the `sed` re-read and use the sourced value (or the
  request just written). Look for other `sed`/`grep ^KEY=` re-readers of `.env`
  in the scripts with the same pattern. No test pins the current behaviour.
- **Test:** setup cases for the duplicate, `export` and quoted forms.

### X2. PHP series taken from a stale archive name, not the site in place

- **Severity:** medium (a re-run rebuilds PHP 8.1 under a site that needs 8.3)
- **Confidence:** repro (extracted functions on a fixture). **Status:** open
- **Where:** `kvs_documented_php_version`, `docker/setup.sh:1593-1603`: the
  `kvs-archive/KVS_X.Y.Z*.zip` name first, then the import's version, then the
  site's `version.php`. kvsctl reads `version.php`
  (`cli/internal/instance/instance.go:541`, `KVSVersion`), and setup's own
  `detect_ioncube` (`:3843-3876`) uses the opposite order.
- **Repro:** `kvs-archive/KVS_7.0.2_[ex.com].zip` still present, site self-updated
  from the admin panel to 7.0.3: setup picks `7.0.2` and PHP 8.1, while the site
  and kvsctl say 7.0.3 (PHP 8.2-encoded files, `.env.example:46-47`). An old 6.2.0
  archive with a site now on 6.2.1 makes `refuse_unbuildable_kvs_php` refuse the
  run.
- **Fix direction:** prefer the site in place and the imported version over the
  archive name, or refuse when they disagree.
  `tests/test_setup_php_version_selection.sh` cases 1b and 1c cover only the
  no-archive case.
- **Test:** archive 7.0.2 plus site 7.0.3 selects PHP 8.3 (or refuses).

### X3. kvsctl reads booleans case-insensitively; nginx and the scripts do not

- **Severity:** low (every `kvsctl upgrade` fails health and rolls back)
- **Confidence:** repro (Go test plus the nginx entrypoint under `sh`).
  **Status:** open
- **Where:** `SiteHost`, `cli/internal/instance/instance.go:525`
  (`EqualFold(USE_WWW, "true")`); `cli/internal/doctor/config.go:97-98` (lowercases
  `USE_WWW`, `CLOUDFLARE_ENABLED`, `ENABLE_MANTICORE`,
  `DISABLE_KVS_SUPPORT_ACCESS`). Against `docker/nginx/docker-entrypoint.sh:40`,
  `:171` and `:11-17` (exact `true`/`false`), and `reconfigure.sh:382`, `:423`.
  setup never validates `USE_WWW`.
- **Repro:** `USE_WWW=True` with `DOMAIN=sub.example.com`: doctor says ok and
  `SiteHost` is `www.sub.example.com`, nginx builds without the www name, and
  `httpCheck` (`verify.go:396`) sends a www SNI that hits `ssl_reject_handshake`.
  `CLOUDFLARE_ENABLED=TRUE`: doctor ok, nginx exits 1.
- **Fix direction:** make kvsctl strict (exact `true`/`false`), or have setup
  refuse other values; check `config_test.go` for pinned tolerance.
- **Test:** `USE_WWW=True` is reported by doctor as invalid.

### X4. Several archives: setup refuses, site-manager and init pick one at random

- **Severity:** low (multi-site `add b.com` can install another domain's licensed
  archive or version)
- **Confidence:** repro for the selection; the licence impact from code.
  **Status:** open
- **Where:** `require_single_kvs_archive`, `docker/setup.sh:618-625` (refuses, and
  says why); `docker/multi-site/site-manager.sh:487` (existence only) and `:158`
  (`compgen -G … | head -n1`); `docker/init/lib/common.sh:37` (`find … | head -1`,
  directory order, never matched against the `[domain]`; sites share
  `../../../kvs-archive`).
- **Repro:** five `KVS_7.0.3_[*].zip` on ext4: `compgen` picked `[zz.net]`, `find`
  picked `[b.com]`.
- **Fix direction:** site-manager selects the archive whose `[...]` matches the
  domain (or refuses several) and passes the chosen file to the init.
- **Test:** two archives; `add b.com` uses `[b.com]` or refuses.

### X5. KVS versions setup accepts (`7.0.3.1`, `7.0`) block kvsctl upgrades

- **Severity:** low. **Confidence:** repro for the divergence; whether KVS ever
  ships four-part or suffixed versions is not confirmed. **Status:** open
- **Where:** setup takes the leading `X.Y.Z` (`docker/setup.sh:1595`, `:1598`,
  `:1602`), and `kvs-export.sh:1624` allows `X.Y.Z.W` and suffixes; kvsctl's
  `semver.Less` sorts unparsable versions first
  (`cli/internal/semver/semver.go:94-101`), used for `kvs_min` at
  `cli/internal/upgrade/plan.go:120`.
- **Repro:** `Less("7.0.3.1","7.0.0")`, `Less("7.0.3a","7.0.0")` and
  `Less("7.0","7.0.0")` are all true: "update KVS from its admin panel first".
- **Fix direction:** compare the leading `X.Y.Z` in kvsctl, or skip the blocker
  when the version does not parse.
- **Test:** `kvs_min=7.0.0` with KVS `7.0.3.1` is not blocked.

### X6. Bracketed endpoints compose rejects pass setup's parser

- **Severity:** low (every later compose command fails)
- **Confidence:** repro (compose v5.6.1). **Status:** open
- **Where:** `parse_publish_endpoint`, `docker/setup.sh:1061` (any bracketed run of
  hex digits, `:`, `.`, `%`), and its copy at `docker/reconfigure.sh:293`; doctor
  (`cli/internal/doctor/config.go:66-70`, `net.ParseIP`) refuses them.
- **Repro:** `HTTPS_PORT='[:]:8443'` or `'[...]:8443'`: setup accepts, compose says
  "invalid IP address".
- **Fix direction:** validate the bracketed host as an IPv6 address in both
  copies. Related to D2.
- **Test:** both values are refused before `.env` changes.

## Interrupt and disk-full paths

Tested with small tmpfs mounts and `timeout -s INT`/`kill -HUP` on stubbed runs.
Not yet independently verified. Sound, so skip: bash runs EXIT traps on INT,
TERM, HUP and PIPE, subshells included, and no top-level EXIT trap is overwritten
in `setup.sh`; gum kills the step's children on Ctrl-C; every kvsctl write
(journal, state, `.env`, backup, binary) goes through temp file, fsync and
rename; `set_env_value` and `remove_env_value` fail on ENOSPC; the resume token,
staged dump identity, `kvs_publish_export`, the retirement phases, `00-extract`
and `50-nginx-rewrites` hold against interrupts.

### P1. Full disk replaces the primary Caddy route with an empty file; exit 0

- **Severity:** medium (the primary site goes offline and no rollback runs)
- **Confidence:** repro (1 MiB tmpfs; real `caddy:2-alpine` validates the empty
  import). **Status:** open
- **Where:** `configure_primary_site`, `docker/multi-site/site-manager.sh:391`
  (`if ! write_caddy_site_config …`); the write at `:307-348`.
- **Defect:** inside `if !`, `set -e` is off for the whole called function. A failed
  `{ cat <<EOF …; } > "$temp_file"` is ignored, `mv -f` installs the empty or
  partial file, and `log_success` returns 0. If `mktemp` fails, the old route stays
  but success is still reported. `reconfigure.sh` (`configure_multi_route`,
  `:1308-1326`) then reloads and reaches its commit point
  (`MULTI_TRANSACTION_COMMITTED=true`); `setup.sh:4483` (`prepare_multi_site_proxy`)
  carries on the same way.
- **Repro:** full tmpfs with an existing route: "cat: write error: No space left on
  device", then "[OK] Generated Caddy config", exit 0, a 0-byte route file.
- **Fix direction:** check each step (`{ … } > "$temp_file" || { rm -f --
  "$temp_file"; return 1; }`, `mktemp`, `mv`), and before `mv` check the file is not
  empty and holds `# KVS Site: $domain`. Audit other functions called under
  `if !`/`||` for the same `set -e` blind spot. The existing `primary-config`
  assertions (`tests/test_multisite_manager_hardening.sh` around `:359-370`) still
  pass.
- **Test:** a PATH stub `cat` that prints an ENOSPC error and exits 1:
  `primary-config` exits non-zero and the old route is byte-identical (the stub
  reproduces the bug today).

### P2. Interrupted `add` leaves a half site that `add` refuses and `start` calls working

- **Severity:** medium. **Confidence:** repro for `add`; `start` by code.
  **Status:** open
- **Where:** `add_site`, `docker/multi-site/site-manager.sh:504-566`; `start_site`,
  `:585-667`.
- **Defect:** the site directory, webroot, `.env`, `docker-compose.yml` and route are
  created one after another with no cleanup on failure or interrupt, and `start`
  never checks that the route exists.
- **Repro:** with 5 free pages, `add newsite.example.com` wrote `.env` and
  `docker-compose.yml`, then failed on the route (only
  `.newsite.example.com.caddy.XXXXXX` left). A second `add` says "already exists";
  `start` runs compose, kvs-init and `reload_caddy`, then prints "Site started!
  Access your site at https://…" while Caddy has no route. Ctrl-C anywhere after
  `mkdir site_dir` gives the same state.
- **Fix direction:** build the site in a temporary sibling directory and rename it
  into `sites/<domain>` last (or remove it on failure with a trap); have `start`
  refuse when `caddy/sites/<domain>.caddy` is missing or empty.
- **Test:** the `cat` stub failing only for the route write: `add` exits non-zero
  and leaves no `sites/<domain>`, or `start` refuses.

### P3. Import receipt written before cleanup; re-run advises wiping a complete database

- **Severity:** low (the advice destroys a complete database if followed)
- **Confidence:** repro of the refusal; the window by code. **Status:** open
- **Where:** `import_finish`, `docker/setup.sh:5603` (`set_env_value
  KVS_IMPORT_COMPLETED`), then `:5613` (DELETE of `KVS_INSTALL_IMPORT`), then
  `:5615-5616` (removal of the staged dump or native stage);
  `import_check_leftover_dump`, `:1553-1563`.
- **Defect:** an interrupt after `:5603`, or a failed DELETE, leaves a finished
  import with its staged dump. Every re-run then stops with "an earlier import did
  not complete … the database may be partial. Run the import again with
  VOLUME_CHOICE=1 to replace the database". If the DELETE already ran,
  `--resume-import` also refuses. The `rm -rf` of a large native stage makes the
  window last seconds.
- **Fix direction:** when `KVS_IMPORT_COMPLETED` is set and the stage is still
  there, say the cleanup was interrupted and finish it (remove the stage, delete
  the marker if present). Check against `tests/test_setup_resume*.sh` and
  `tests/test_import_resume.sh`, which rely on the stage surviving until finish.
- **Test:** `.env` with `KVS_IMPORT_COMPLETED` plus
  `mariadb/init/10-kvs-import.sql.zst` present: no "VOLUME_CHOICE=1 to replace"
  advice.

### P4. `.env` and export renames are never fsynced

- **Severity:** low (after a power cut on XFS, `.env` can come back empty or with
  the placeholders while the volume holds the generated passwords)
- **Confidence:** code (power loss not reproducible here). **Status:** open
- **Where:** `set_env_value` (`docker/setup.sh:814`) and `remove_env_value`
  (`:773`), the same pattern in `docker/reconfigure.sh:200`; `kvs_publish_export`
  (`kvs-export.sh:2303-2321`). No `sync` anywhere in the shell scripts, while
  kvsctl flushes the same `.env` on purpose (`release.WriteFile`).
- **Defect:** `docker/setup.sh:5040-5048` writes the new `MARIADB_ROOT_PASSWORD` and
  `MARIADB_PASSWORD` this way; MariaDB then initialises the volume with them. A
  crash soon after can lose the `.env` (ext4's `auto_da_alloc` mostly hides it), and
  the next run generates passwords that do not match. For an export, a good
  archive can be replaced by an unflushed, truncated one.
- **Fix direction:** `sync -- "$temporary"` before `mv`, and `sync -- .` (the
  directory) after, in these three helpers.
- **Test:** a PATH stub `sync` that logs its arguments, called on the temp file
  before `mv`.

Lower-value notes, not ranked: `import_take_over_site`
(`docker/lib/import.sh:434-438`) moves the directory first and its source marker
second, so an interrupt between the two leaves a destination no later run
accepts; `retirement_prepare_identity`'s no-containers branch (`docker/setup.sh`
around `:1000`) writes `DOMAIN` and `SITE_PREFIX` separately, so an interrupt in
between makes the next import reuse the old prefix, and `VOLUME_CHOICE=1` would
then delete the old site's database volume.

## Upgrading from an older stack release

Old states were rebuilt from git history (release tags 26.10.0 to 26.11.0, and
`main` at 4448603, July 2026). Not yet independently verified. Stable across
that range, so skip: volume and network names, the service uids, certificate
paths, `DOMAIN_SAFE`, database name and user; `.env.example` values for keys an
older `.env` lacks match the compose defaults; `dotenv.Set` and `set_env_value`
replace duplicates left by old `>> .env` appends; `kvsctl_min` exists from
26.10.0.

### U1. Upgrading an adopted pre-26.10 stack removes acme; certificates stop renewing

- **Severity:** high (silent: health checks pass until the certificate expires)
- **Confidence:** repro (`docker compose config --services` with the same July
  `.env` lists acme for the 4448603 compose file, not for 26.11.0); the removal
  follows from `removeLeftovers`, exercised by `scenario_test.go:432`.
  **Status:** open
- **Where:** `docker/docker-compose.yml:293-294` (acme under the `direct-tls`
  profile since 66e90fb); `COMPOSE_PROFILES` in `mergeKept`
  (`cli/internal/instance/instance.go:342`), so a merge never adds it;
  `targetServices` (`cli/internal/upgrade/plan.go:678-697`, "an upgrade never
  changes" `COMPOSE_PROFILES`); `removeLeftovers`
  (`cli/internal/upgrade/run.go:835-873`); only `configure_direct_tls_profile`
  (`docker/setup.sh:4412`) adds the profile; `.github/release.env:27`
  (`MIN_FROM=` empty).
- **Defect:** a July checkout with `COMPOSE_PROFILES=dragonfly` and
  `SSL_PROVIDER=letsencrypt` is adopted as 0.0.0 and upgraded to 26.11.0 (allowed:
  `MIN_FROM` is empty). The run logs "removing the containers of acme: the files
  laid no longer run them", and acme never starts again.
- **Fix direction:** add `direct-tls` during the upgrade when `MODE=single` and
  `SSL_PROVIDER` is letsencrypt or zerossl; make the plan block or warn when an
  active service would become inactive; or set `MIN_FROM`, or refuse 0.0.0
  checkouts older than 26.10.0 until `setup.sh` has been re-run.
- **Test:** an upgrade scenario where the old compose runs acme without a profile
  and the new one gates it behind `direct-tls`: acme still runs after, or the plan
  has a blocker.

### U2. `kvsctl upgrade` never fixes files the old root cron created

- **Severity:** medium (background tasks and conversions can fail on files uid 1000
  cannot rewrite)
- **Confidence:** code for the missing step; which KVS files break is plausible.
  **Status:** open
- **Where:** e3a1dd3 moved the KVS cron task from root to www-data
  (`docker/cron/crontab:6`); the only ownership fix is
  `docker/init/docker-entrypoint.d/60-permissions.sh:113`, in kvs-init (the `setup`
  profile), which kvsctl never runs. kvsctl has no chown.
- **Defect:** on a July install, `cron.php` ran as root and created root-owned
  0644/0755 files and directories in the web root; after adopt and upgrade, cron
  runs as uid 1000 and cannot rewrite or delete them or create files in them.
- **Fix direction:** a one-time `find ! -uid 1000 -exec chown -h 1000:1000` step, or a
  blocker, for adopted stacks older than e3a1dd3 (alongside U1).
- **Test:** an adopted 0.0.0 fixture with a root-owned file in the web root: the
  upgrade fixes the owner or blocks.

### U3. Re-run overwrites `PROJECT_HTTPS_PORT` with the published port

- **Severity:** medium (every redirect and storage URL points at a port the proxy
  does not expose)
- **Confidence:** repro (extracted functions: `PROJECT_HTTPS_PORT=8443`,
  `project_url=https://mysite.com:8443`). **Status:** open
- **Where:** `docker/setup.sh:5072` (unconditional
  `set_env_value PROJECT_HTTPS_PORT "$PUBLIC_HTTPS_PORT"`), feeding
  `get_project_url` (`docker/init/lib/common.sh`), `10-config-php` (project_url),
  `40-configure-database` (storage server URLs) and the nginx redirects.
- **Defect:** an explicit saved value is never kept. The July `.env.example`
  suggested other ports when 80/443 are in use and `selfsigned` behind a reverse
  proxy, so a typical old install has `HTTP_PORT=8080`, `HTTPS_PORT=8443`,
  `SSL_PROVIDER=selfsigned` behind HAProxy on 443, with port-less URLs. After a
  re-run they all carry `:8443`; a hand-set `PROJECT_HTTPS_PORT=443` is overwritten
  on the next run. kvsctl merges `443` for the same `.env`, so the two paths
  disagree.
- **Fix direction:** derive it only when the key is missing or `HTTPS_PORT` changed
  in this run; keep an explicit value; ask when `SSL_PROVIDER=selfsigned`.
- **Test:** `HTTPS_PORT=8443` and `PROJECT_HTTPS_PORT=443`: still 443 after a run.

### U4. Re-run discards the saved `PHP_VERSION` for the default series

- **Severity:** medium (the site is silently rebuilt on another PHP series)
- **Confidence:** repro (extracted function). **Status:** open
- **Where:** `select_php_version`, `docker/setup.sh:4006`
  (`choice=${choice:-$documented}`, also the prompt default) and `:3989`;
  `KVS_PHP_VERSION` is never persisted; `refuse_unbuildable_kvs_php` (`:1637`)
  ignores the saved value. Distinct from X2.
- **Defect:**
  - Unencoded KVS 7.0.2 installed on PHP 8.4: a headless re-run, or Enter at the
    prompt, writes `PHP_VERSION=8.1` and rebuilds.
  - An encoded site installed with `KVS_PHP_VERSION=8.2` is reset the same way.
  - Unencoded KVS 6.1.x installed with `KVS_PHP_VERSION=8.2` (the documented way):
    every later re-run, `kvs-install.sh` updates included, refuses with "needs PHP
    7.4" unless the variable is exported again.
  kvsctl-managed stacks are protected by `kvsctl_note_php_change`; others are not.
- **Fix direction:** use the saved `PHP_VERSION` as the default, and keep it when the
  site is unencoded or the series is compatible; only an explicit
  `KVS_PHP_VERSION` or a prompt answer changes it.
- **Test:** `PHP_VERSION=8.4`, `IONCUBE=NO`, a 7.0.2 archive, `HEADLESS=y`: 8.4 kept.

### U5. Volume check allows multi-series MariaDB jumps in place, no backup

- **Severity:** medium (an in-place 10.6 to 12.3 or 11.4 to 12.3 upgrade with nothing
  taken first)
- **Confidence:** repro (function extracted, docker stubbed; `mariadb_upgrade_info`
  confirmed written at init on a real 12.3 volume). **Status:** open
- **Where:** `ask_existing_volume`, `docker/setup.sh:4848-4886`; the headless
  default `VOLUME_CHOICE=2` is commented "2=exit (safe default)" at `:1341`, but
  in this branch 2 means "Keep existing database and upgrade". The version menu
  (`:2765`) offers only 12.3, 11.8 and 11.4.
- **Defect:** kvsctl refuses these jumps (one series at a time, 10.x only through
  a dump: `seriesRefusal`, `unpublishedSeries` in `plan.go`); setup offers them in
  place. A July install on 10.6 that answers "Keep this version? n" gets 12.3 as
  the default and "MariaDB will auto-upgrade from 10.6 to 12.3". Headless,
  `MARIADB_VERSION=12.3` on an 11.4 volume with `KEEP_VERSION=n` skips 11.8.
- **Fix direction:** refuse a jump of more than one series, and from 10.x, as kvsctl
  does; require a backup or an explicit choice before an in-place series change;
  make headless `2` exit in every branch, as its comment says.
- **Test:** volume 11.4, `MARIADB_VERSION=12.3`, `VOLUME_CHOICE=2`: exits; 11.8 to
  12.3 needs explicit consent.

## Environment and scale

Run under the real interpreters and images. Not yet independently verified.
Sound, so skip: every `#!/bin/sh` script passes `shellcheck -s sh`, and the
phpMyAdmin init runs in the pinned alpine/busybox image; `kvs-export.sh` passes
its 33 tests under bash 4.2.53 and 5.3.20; `patsub_replacement` escaping is the
same on bash 4.2, 5.2 and 5.3; byte counts are 64-bit or double throughout; the
rsync stats and progress parsers survive locale thousands separators; no glob is
passed over an unbounded list; IPv6 publish parsing is handled.

### V1. tar archive with a non-ASCII site directory or dump name cannot be imported

- **Severity:** medium (an empty site reported as copied, or hours of extraction
  before a refusal)
- **Confidence:** repro (`tar.gz` against the same tree as `.zip`). **Status:** open
- **Where:** `import_archive_list`, `docker/lib/import.sh:805-821` (tar branch); the
  names are used in `import_archive_settle` (`:990`, `:998`, `:1004`), called from
  `docker/setup.sh:2589`.
- **Defect:** `LC_ALL=C tar -tvf` prints names in GNU tar's escape quoting
  (`vid\303\251o`); those become the site root and dump path, which do not exist on
  disk. The peek (`tar -xOf`) still works because tar unquotes its arguments, so
  the analysis passes.
- **Repro:** site directory `site-vidéos/`: settle finds nothing, moves nothing,
  returns 0 and deletes the extracted stage; setup prints "✓ Site files in
  /var/www/…" with an empty destination, then fails on the missing `setup.php`.
  Dump `données.sql`: "archive member is not a regular file" after the full
  extraction. zip and 7z listings show raw UTF-8 and work.
- **Fix direction:** decode tar's escapes in the awk (as `import_rsync_plan` does for
  rsync's `\#ooo`), or list with `--quoting-style=literal` and refuse names with a
  newline; make settle fail when the site root is missing.
- **Test:** a `tar.gz` with root `site-vidéos/` and dump `données.sql` imports.

### V2. A resumed directory import is refused for lack of space

- **Severity:** medium (a 1 TB site on 1.2 TB free can never be resumed after a
  halfway interruption)
- **Confidence:** repro (75 MB tmpfs, 60 MB source, interrupted at 40 MB:
  "REFUSED"). **Status:** open
- **Where:** `import_free_space_ok`, `docker/lib/import.sh:593-601`, called from
  `docker/setup.sh:1862`.
- **Defect:** it asks for the source's full size (`du -sLm`) plus the reserve on top
  of what the interrupted copy already wrote, while the same flow resumes
  ("Resuming the copy…", rsync copies only the rest).
- **Fix direction:** subtract the destination's current usage, or size the rest
  with `rsync --dry-run --stats`, as the remote path does (`import.sh:3060-3075`).
- **Test:** the tmpfs scenario passes the check.

### V3. Under a UTF-8 locale, domain and prefix checks accept Unicode

- **Severity:** low (compose rejects the project name after `.env` is written, or
  nginx crash-loops)
- **Confidence:** reproduced by the reviewer with glibc 2.39 and generated
  `en_US.UTF-8`/`de_DE.UTF-8` locales; not reproduced in the audit's own shell,
  which lacks those locales (`C.UTF-8` does not match). Verify first.
  **Status:** open
- **Where:** `[[ =~ ]]` checks with `[a-z]` ranges: `docker/setup.sh:636`
  (`validate_domain`) and `:3336` (`validate_site_prefix`),
  `docker/reconfigure.sh:272`, `kvs-install.sh:727`,
  `docker/multi-site/site-manager.sh:63`, `:74`.
- **Defect:** bash's regex ranges follow the locale's collation, so `[a-z]` matched
  `ü` and `é`. `DOMAIN=München.de` passed all four domain checks and the prefix
  `kvs-münchen` passed; then compose refused the project name, or, with an ASCII
  prefix, `tls/internal-trust.sh:15-16` rejected the domain under dash and the nginx
  entrypoint (`set -e`, `:160`) exited in a loop ("invalid internal TLS domain").
- **Fix direction:** `LC_ALL=C` around these checks, or explicit ASCII lists; convert
  IDNs to punycode or refuse them with a clear message. The same may hold for the
  table and database name checks of `kvs-export.sh` (`:1620`, `:1690`) on a UTF-8
  old server (not reproduced).
- **Test:** each validator under `LC_ALL=en_US.UTF-8` refuses `münchen.de` and
  `kvs-münchen`.

### V4. DNS check reads `/etc/hosts` and only the first A record

- **Severity:** low (headless with `DNS_CHOICE=3` aborts the install on a correct
  DNS)
- **Confidence:** repro (`--hostname example.com --add-host
  example.com:127.0.1.1`: "MISMATCH -> 127.0.1.1"). **Status:** open
- **Where:** `docker/setup.sh:5179`, `:5182` (`getent ahostsv4 … | awk 'NR == 1'`).
- **Defect:** `getent` consults files before DNS, and VPS images and cloud-init write
  `127.0.1.1 <fqdn>` when the hostname is the domain; only the first A record is
  compared. `kvs-install.sh` uses `dig` and is not affected.
- **Fix direction:** query DNS directly, or skip loopback and `/etc/hosts` answers;
  accept a match on any A record.
- **Test:** extend `tests/test_setup_dns_check.sh` with a `getent` stub answering
  `127.0.1.1` first, and one with the server's IP as the second of two records.

### V5. Docker DNS check ignores AAAA records

- **Severity:** low (mid-migration, a stale AAAA makes the ACME issuance fail,
  which aborts setup, see D14)
- **Confidence:** code, plus Let's Encrypt's documented preference for IPv6; no
  issuance was run. **Status:** open
- **Where:** `docker/setup.sh:5170-5213` (nothing under `docker/` checks AAAA).
  Native: `kvs-install.sh:837` reports a matching AAAA as OK although
  `conf/nginx/*` has no `listen [::]:` (a documented IPv4-only limitation).
- **Fix direction:** compare AAAA records against `api64.ipify.org` and warn on a
  mismatch.
- **Test:** an AAAA stub with a foreign address gives a warning.

### V6. Export size walk starts one `du` per shallow file

- **Severity:** low (the size comes back "incomplete" under the default 300 s
  `IMPORT_SIZE_TIMEOUT` on a flat site, and the live old server burns about four
  cores meanwhile)
- **Confidence:** repro for the cost (50k files at depth 2: 25.9 s against 0.13 s for
  one `du`); whether real KVS layouts are that flat is not checked.
  **Status:** open
- **Where:** `kvs_list_measure_units` and `xargs -0 -n 1 -P 4 du`, `kvs-export.sh:741-756`
  and `:768-771`; the comment assumes "three levels down is thousands of entries at
  most".
- **Fix direction:** batch the arguments (`xargs -0 -n 256 du -sLk`), or one `du -s` per
  depth-1 or depth-2 directory.
- **Test:** a 20k-file `tmp/` fixture; assert at most N `du` calls, or a time bound.

## Checked and found sound

So that a follow-up does not redo them:

- Escaping of generated passwords in `sed`, SQL and PHP: `openssl` base64 never
  produces `|`, `&` or `'`.
- `set_env_value` in `docker/setup.sh` rejects newlines and writes through a
  temp file with mode 600.
- Several archives in `/root`: `require_single_kvs_archive` stops on it.
- In `kvs-export.sh`, all `rm -rf` targets come from `mktemp` and are guarded,
  pipefail carries dump and compressor failures, and `MYSQL_PWD` handling and
  `kvs_php_unescape` are correct.
- kvsctl backup create and restore, tar extraction path checks, manifest
  signature checks, upgrade journal and rollback.
- Container runtime: no SQL injection (`TABLES_PREFIX` and
  `IMPORT_SOURCE_DOMAIN` are validated, `DOMAIN` is lowercased and validated);
  passwords travel through `MYSQL_PWD` or the environment, never argv; `chown`
  uses `-h` and `find`/`chmod` do not follow symlinks; log rotation; the
  phpMyAdmin download is checksum-pinned; Cloudflare real IP is limited to
  Cloudflare ranges; the deny regex resists encoding and case tricks.
- yt-dlp updates check the sha256 from the same release but not the GPG
  signature of `SHA2-256SUMS.sig`: a design limit, low.
- Multi-site: two managed sites cannot collide on names or volumes
  (`domain_to_safe` is reversible); no template injection (domains are
  validated); certificate SAN sets and key modes are correct.
- Import: GNU tar 1.35, unzip and 7-Zip 23.01 refuse symlink-then-file escapes
  and `../` or absolute hard-link targets (the p7zip 16.02 fallback was not
  tested); the native bundle's layout, checksums and duplicate members; the
  resume token and markers; `import_ssh_rsh` quoting; validation of remote
  paths, port and user, and IPv6 bracketing for rsync.
- Cosmetic: `import_remote_show_entries` (`docker/setup.sh`) prints the old
  server's entry names with `echo -e` without stripping control characters.
- Release: no untrusted `${{ github.event.* }}` expression in any `run:`, no
  `pull_request_target` or `workflow_run`; tag runs cannot read PR caches;
  `verify-manifest.sh` fails closed without keys and has no TOCTOU; key
  rotation checks; the bundle rejects symlinks and submodules; every
  Dockerfile download is checked against a sha256; no secret in a layer.
- Native install: MariaDB root is unix_socket only; all three apt sources have
  `signed-by`; `insert_cronjob` is idempotent across runs and PHP version
  changes; ACME renewal webroot reachable for apex and www; IonCube extension
  directories correct for PHP 7.4 to 8.4; phpMyAdmin's nested locations win and
  alias traversal returns 400.
- Not a bug today, but worth knowing: `backup.RestoreEnv` (`backup.go`, around
  line 1290) writes through a fixed `.kvsctl.tmp` path with `O_TRUNC` and
  follows symlinks. Nothing calls it yet.

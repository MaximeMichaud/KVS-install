# Bug audit, November 2026

Audit of `kvs-install.sh`, `kvs-export.sh` and the Go CLI (`cli/`, kvsctl) at
commit `edd35eb` (release 26.11.0). Every test suite of the repository passes at
that commit, so none of the findings below is covered by an existing test.

This file is a work list for a follow-up agent: validate each finding, then fix
it with a regression test, or reject it with the reason.

## How to work through this list

1. Take the findings in order (most severe first). For each one:
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

Status legend: `open` (not yet validated), `confirmed` (reproduced, not fixed),
`fixed`, `rejected`. "Confidence" is how the audit verified it: **repro** (a
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
| E1 | high | export | Export archive is world-readable | repro | open |
| E2 | high | export | Any file change during tar fails the whole export | repro | open |
| I1 | high | install | DNS "wait and retry" loops forever | repro | open |
| I2 | high | install | Archive copied while still being uploaded | repro | open |
| E3 | high | export | Output under a symlinked site directory makes tar recurse | repro | open |
| I3 | high | install | Standalone install deletes an existing `/root/tmp` | code | open |
| I4 | medium | install | Domain taken from the archive name blocks valid installs | repro | open |
| I5 | medium | install | Failed SQL import is reported as success and never redone | code | open |
| I6 | medium | install | `DOMAIN` rewritten in `.env` before `setup.sh` reads the old one | code | open |
| E4 | medium | export | Non-canonical `--exclude` is reported excluded but archived | repro | open |
| E5 | medium | export | `setup_db.php` parsing reads commented lines, misses valid forms | repro | open |
| I7 | medium | install | IonCube lines appended on every run and on failure | code | open |
| G1 | medium | kvsctl | `dotenv.Set`/`MergeEnv` append CRLF lines the shell misreads | repro | open |
| G2 | medium | kvsctl | `${PWD}` in `.env` expands differently from compose | code | open |
| I8 | low | install | "Update the Script" corrupts the log and drops arguments | repro | open |
| I9 | low | install | `www.conf.bak` overwritten on re-run | code | open |
| E6 | low | export | Storage server columns shift when one is empty | repro (mechanism) | open |
| E7 | low | export | IPv6 `DB_HOST` misparsed | repro | open |
| G3 | low | kvsctl | doctor fails on distro/Desktop compose version strings | code | open |
| G4 | low | kvsctl | `semver.Compare` treats `RC1`/`rc1` and `rc01`/`rc1` as equal | repro | open |
| G5 | low | kvsctl | Bare word on the last line changes meaning after `Set` | repro | open |
| D1 | high | setup | Headless re-run replaces saved prefix, SSL and cache choices | repro | open |
| D2 | high | setup | Port overrides written raw to `.env`, then sourced as code | repro | open |
| D3 | high | setup | Staged import dump is world-readable | code | open |
| D4 | medium | setup | Empty `dhparam.pem` from an interrupted run is kept | repro | open |
| D5 | medium | setup | Truncated `gum` download is installed and never replaced | repro | open |
| D6 | medium | setup | Headless pre-flight still prompts and exits silently at EOF | repro | open |
| D7 | medium | setup | `DNS_CHOICE` unknown or `1` loops forever in headless mode | repro | open |
| D8 | medium | setup | `DB_CHOICE` ignored when endoflife.date does not answer | repro | open |
| D9 | medium | setup | `--dev` fails unless `DOMAIN` is given, ignores the saved domain | repro | open |
| D10 | medium | setup | Multi-site Caddy exception also skips loopback port conflicts | repro | open |
| D11 | low | setup | Partial GeoIP database kept as "already configured" | repro | open |
| D12 | low | setup | Started from another project's directory, it uses that `.env` | repro | open |
| C1 | critical | runtime | PHP runs in upload directories, `.phar` included | repro | open |
| C2 | critical | runtime | Root init container runs a script PHP can write | repro | open |
| C3 | high | nginx | Asset regexes win over the internal-directories deny | repro | open |
| C4 | medium | nginx | TLS 1.3 0-RTT on, replayable, invisible to PHP | repro | open |
| C5 | medium | nginx | SVG and font responses lose every security header | repro | open |
| C6 | medium | runtime | PHP-FPM can rewrite phpMyAdmin's `config.inc.php` | code | open |
| C7 | low | nginx | `_INSTALL/` (`install_db.sql`) served as static files | repro | open |
| C8 | low | runtime | Init re-runs rewrite the title; Manticore cron failure hidden | code | open |
| R1 | high | multi-site | `remove` of a new site deletes a single-mode primary's data | repro | open |
| R2 | high | multi-site | Two sites can claim the same `www` host, breaking Caddy for all | repro | open |
| R3 | medium | reconfigure | Multi-mode rollback leaves the recreated containers changed | repro (stub) | open |
| R4 | medium | reconfigure | Edited `DOMAIN` half-applies and takes the site down | code | open |
| R5 | medium | multi-site | `remove` hides a failed `down -v`, then deletes the config | repro | open |
| R6 | low | multi-site | Manual `caddy-start` sets the ACME email to `admin@example.com` | repro | open |

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
  definition: www.a.com"). **Status:** open
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
- Not a bug today, but worth knowing: `backup.RestoreEnv` (`backup.go`, around
  line 1290) writes through a fixed `.kvsctl.tmp` path with `O_TRUNC` and
  follows symlinks. Nothing calls it yet.

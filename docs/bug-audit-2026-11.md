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
- Not a bug today, but worth knowing: `backup.RestoreEnv` (`backup.go`, around
  line 1290) writes through a fixed `.kvsctl.tmp` path with `O_TRUNC` and
  follows symlinks. Nothing calls it yet.

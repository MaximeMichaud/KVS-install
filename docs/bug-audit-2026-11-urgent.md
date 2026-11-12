# Bug audit, November 2026: most urgent findings

This is a short extract of [bug-audit-2026-11.md](bug-audit-2026-11.md), a
defensive review of this repository's own code at commit `edd35eb` (release
26.11.0). It lists the findings with the highest risk on a production host,
most urgent first. Every finding here was reproduced, then checked again by a
second reviewer; the text below already includes that second review's
corrections. The full report has the reproductions, the line-by-line evidence
and the 142 lower-priority findings.

Line numbers are those of `edd35eb`; the function names are given so they can
be found after drift. Each entry says which existing tests constrain the change,
where the review found one.

## Summary

| Order | ID | Area | Finding |
| --- | --- | --- | --- |
| 1 | T1 | tests | nginx deny rules are checked as text only, never by request |
| 2 | T2 | tests | 15 of the 16 integration suites never run in CI |
| 3 | H1 | kvsctl | Upgrade and restore verification accept a 403 site and any redirect |
| 4 | C1 | nginx | PHP files under `contents/` are executed |
| 5 | C2 | runtime | The root init container runs a script the PHP user can write |
| 6 | C3 | nginx | Asset rules win over the deny on internal directories |
| 7 | M1 | import | Shell injection on the old server in the tar fallback |
| 8 | Z1 | import | Imported tables silently change collation |
| 9 | R1 | multi-site | Removing a new site can delete the primary site's data |
| 10 | D1 | setup | A headless re-run replaces the saved prefix, SSL and cache choices |
| 11 | E1 | export | The export archive is world-readable |
| 12 | N1 | native | `setup_db.php` is world-readable on the native install |
| 13 | W1 | install | Menu option 2 "Add site" runs a broken native install, even on Docker |
| 14 | U1 | kvsctl | Upgrading a pre-26.10 stack removes acme; certificates stop renewing |
| 15 | D13 | setup | The admin password is lost when kvs-init fails after setting it |
| 16 | R2 | multi-site | Two sites can claim the same `www` host and break Caddy for all |
| 17 | E3 | export | Output under a symlink inside the site: tar recurses, or the dump lands in the web root |

T1, T2 and H1 come first because they decide whether a mistake in any later
change is noticed: today the suites would pass with the nginx protections
removed, and kvsctl would record a broken upgrade as healthy.

## 1. T1. nginx deny rules are checked as text only

- **Where:** `tests/test_nginx_hardening.sh:39-58`
  (`assert_protected_locations_precede_php`) and `:68-104`
  (`assert_kvs_internal_directories_denied_before_php`).
- **Problem:** the tests check that the `location` lines exist and come before
  the PHP handler, but not what the blocks do. Changing the internal-directories
  block in `conf/nginx/templates/kvs.conf.tpl` from `deny all;` to `allow all;`
  (which makes nginx serve `admin/include/setup_db.php`, with the database
  password, as plain text), or emptying the `/tmp/*.php` block, still passes
  every suite of `tests/run.sh`. No suite requests `/admin/include/*.php` or
  `/tmp/*.php` at all.
- **Direction:** render the template and send real requests, as
  `tests/integration_origin_security.sh` does, expecting 403 or 404 for
  `/admin/include/setup_db.php`, `/admin/data/x.php`, `/.private/x.css` and
  `/tmp/x.php`. At minimum, check that each block's body is `deny all;` or
  `internal;`.

## 2. T2. 15 of the 16 integration suites never run in CI

- **Where:** `tests/run.sh:6-12` runs `test_*.sh` plus
  `integration_cloudflare_realip.sh` only; `.github/workflows/tests.yml:71` runs
  only `tests/run.sh`.
- **Problem:** `integration_origin_security.sh`, `integration_nginx_healthcheck.sh`,
  `integration_native_import.sh`, the resume suites and the others are manual
  only. `integration_origin_security.sh` does catch a broken dotfile rule, but
  never runs in CI.
- **Direction:** run them in CI on the locked images, failing (not skipping)
  under `CI=true` when Docker or an image is missing. `as-uid-1000.sh` strips
  `NGINX_TEST_IMAGE`, so the CI job needs the image tagged, or the default
  changed to the locked digest.

## 3. H1. Upgrade and restore verification accept a 403 site

- **Where:** `httpCheck`, `cli/internal/upgrade/verify.go:394-427`
  (`protected :=` at `:417`); doctor does the same at
  `cli/internal/doctor/http.go:103`.
- **Problem:** 401 and 403 count as "up" on every path, any redirect passes, and
  the body is never read. A site where every PHP script answers PHP-FPM's 403
  "Access denied." (reproduced with the real 26.11.0 images), or one that
  redirects to another host, is reported healthy: `kvsctl upgrade` records the
  new version and drops its journal, so no automatic rollback happens.
- **Direction:** accept 401/403 only on `/admin/`; require `/` to be 2xx, or a
  3xx to the same site (www included); optionally reject the FPM "Access
  denied." and "File not found." bodies.
- **Tests:** `TestHTTPCheck` (`verify_test.go:451`) pins 401/403 as up and has to
  change with the fix.

## 4. C1. PHP files under `contents/` are executed

- **Where:** the generic `location ~ \.php$`, `conf/nginx/templates/kvs.conf.tpl:141`;
  the same in `docker/multi-site/nginx/kvs-caddy.conf.template` and the native
  `conf/nginx/conf.d/domain.conf`.
- **Problem:** nothing denies PHP under `/contents/` (only `/contents/videos/` is
  internal), and the Docker PHP block has no `try_files $fastcgi_script_name
  =404`, so a PHP file placed in an upload directory runs, and on Docker a
  `.phar` runs through the path-info fallback. This turns any way of writing a
  file under `contents/` into code execution. `10-config-php.sh:91` skips
  `contents/` on the assumption that PHP does not run there.
- **Direction:** deny `\.(php|phar)` under `contents` before the PHP handler
  (`tmp/` and `langs/` are already covered), add `try_files
  $fastcgi_script_name =404;` to the Docker template (the native
  `php_fastcgi.conf` already has it), and set `security.limit_extensions = .php`
  and `cgi.fix_pathinfo=0`.

## 5. C2. The root init container runs a script the PHP user can write

- **Where:** `docker/init/docker-entrypoint.d/60-permissions.sh:127-137`
  (`bash install_permissions.sh`); the same trust issue in
  `50-nginx-rewrites.sh:25-32` (`_INSTALL/nginx_config.txt` copied into the
  nginx config).
- **Problem:** each kvs-init run executes `_INSTALL/install_permissions.sh` as
  root when it and `.kvs-extraction-complete` exist. Both are in the web root,
  owned by uid 1000 (PHP-FPM, cron), and `60-permissions.sh:113` chowns the
  marker to 1000 as well. So code running as the PHP user can have a script of
  its choosing run as root at the next setup or site start: a privilege
  escalation from uid 1000 to root on the host bind mount. No service sets
  `no-new-privileges`.
- **Direction:** keep `.kvs-extraction-complete` where it is
  (`00-extract.sh:42-60` and `tests/test_init_resume_hardening.sh` rely on it),
  but add a separate per-run flag in the container's own `/tmp`, set by the
  extraction of the same run, and run the script only when that flag exists.
  Copy the script to `/tmp` during extraction (the staging directory is deleted
  by `00-extract`'s EXIT trap before `60` runs). Treat `nginx_config.txt` the
  same way. Add `security_opt: [no-new-privileges:true]`.

## 6. C3. Asset rules win over the deny on internal directories

- **Where:** the asset regular expressions at `kvs.conf.tpl:74` and `:80` come
  before the deny at `:136`; the same order in the multi-site template (`:64`,
  `:70` before `:132`) and in the native `domain.conf` (`general.conf` included at
  `:30`, before `:41`).
- **Problem:** nginx uses the first matching regular expression, so a `.js`,
  `.css`, `.svg`, `.mp4` or other asset under `admin/data`, `admin/logs`,
  `admin/smarty`, `admin/template`, `admin/tools` or `/tmp` is served. With a
  plain-prefix `internal` rule from the KVS rewrites file, files under
  `contents/videos_sources/` are served too.
- **Direction:** move the deny (with a `^/_INSTALL/` entry) above the asset rules,
  or make the denied directories `^~` prefix locations with a nested exception
  for the two uploader scripts. Before denying everything under `/tmp/`, check
  that KVS serves no preview or temporary file from `/tmp/` by direct URL.

## 7. M1. Shell injection on the old server in the tar fallback

- **Where:** `import_remote_files`, `docker/lib/import.sh:2951`
  (`tar_excludes+=("'--exclude=.$pattern'")`), used at `:3253` over ssh.
- **Problem:** exclude patterns are wrapped in single quotes without escaping,
  and the remote shell parses the command line again. The patterns come from the
  old server's report, which lists hidden top-level directories by their raw
  names (`kvs-export.sh:1173-1175`). A directory name containing a single quote
  and shell syntax runs that syntax on the old server as the SSH user (often
  root) when rsync is absent there; a harmless name with an apostrophe breaks
  the fallback. The rsync path is not affected.
- **Direction:** quote each argument with `printf %q` before it goes on the ssh
  command line, or refuse patterns outside a safe character set.

## 8. Z1. Imported tables silently change collation

- **Where:** `import_prepare_dump`, `docker/lib/import.sh:354-357`;
  `docker/docker-compose.yml:133-139` sets no collation option.
- **Problem:** the MariaDB image maps utf8mb4 (and, from 11.8, utf8mb3) to
  `uca1400_ai_ci` by default. Dumps from MySQL 5.x and older MariaDB write
  `DEFAULT CHARSET` without `COLLATE`, so imported tables lose their
  `general_ci` collation: equality, sorting and uniqueness change (full-width
  and kana variants compare equal, `strasse` equals `straße`). When a UNIQUE
  column holds two values that become equal, the import stops with an error and
  the container exits. Reproduced from MySQL 5.7 into 11.4, 11.8 and 12.3.
- **Direction:** emit `SET SESSION character_set_collations='';` before the dump
  body (verified: the import passes and every collation matches the source), or
  add an explicit `COLLATE` to each `CREATE TABLE`.

## 9. R1. Removing a new site can delete the primary site's data

- **Where:** `add_site` (`docker/multi-site/site-manager.sh:451`),
  `ensure_site_prefix_available` (`:168`), `remove_site` (`:707`, `down -v` near
  `:736`).
- **Problem:** the only prefix-collision check reads `sites/.primary.env`, which
  exists only in multi mode. A single-mode primary such as `my-site.com` (project
  `kvs-my-site`) collides with a new site `my.site`; `remove my.site` then runs
  `docker compose down -v` on the primary's project and deletes its containers
  and volumes (reproduced with real Docker). The validator also accepts
  single-label names (`example` collides with `example.com`).
- **Direction:** also read `COMPOSE_PROJECT_NAME`/`SITE_PREFIX` from `docker/.env`
  in single mode; refuse `add` when a container or volume labelled with that
  project exists; before `down -v`, check that the
  `com.docker.compose.project.working_dir` label is the site directory.

## 10. D1. A headless re-run replaces the saved prefix, SSL and cache choices

- **Where:** `docker/setup.sh:1335-1347`, used at `:3632-3672` and `:3698-3723`;
  the same in `select_cache` (`:4264`).
- **Problem:** in headless mode `PREFIX_CHOICE`, `SSL_CHOICE` and `CACHE_CHOICE`
  default to 1 and override `.env`. Re-running the README's headless example on
  an install with `SITE_PREFIX=kvs` writes `SITE_PREFIX=kvs-mysite`,
  `COMPOSE_PROJECT_NAME=kvs-mysite` and `SSL_PROVIDER=letsencrypt`: the stack
  comes up on new, empty volumes and the original database is orphaned.
- **Direction:** when `.env` already holds a domain and these keys, keep them
  unless the matching `*_CHOICE` is set explicitly. `retirement_prepare_identity`
  (`:997`, `:1002`) writes `SITE_PREFIX=kvs` on purpose as a "choose again"
  signal, and `.env.example` ships `SITE_PREFIX=kvs`: a separate "legacy" marker
  must keep both working.

## 11. E1. The export archive is world-readable

- **Where:** `kvs_publish_export`, `kvs-export.sh:2303`; tar at about `:2449`; the
  `--dump-only` path at `:2404-2408`.
- **Problem:** no `umask` or `chmod` applies to the output, so a new archive (with
  the full database dump and `setup_db.php`) is created 0644 under a 022 umask.
  A run from a 0755 directory exposes it to every local user.
- **Direction:** `chmod 600` on the staged file before `mv` when no previous output
  exists; keep the current behaviour of preserving an existing file's mode.

## 12. N1. `setup_db.php` is world-readable on the native install

- **Where:** `install_KVS`, `kvs-install.sh:1104` (`chmod -R 755 "$KVS_PATH"`).
- **Problem:** every file, the database password in `setup_db.php` included,
  becomes 0755, and a re-run applies it again. Without the `chmod`, unzip under
  umask 022 would still leave the file 0644.
- **Direction:** after `configure_kvs_database_file`, on every run, set
  `setup_db.php` to 0640 `root:www-data` (or 0600 www-data), and use 0755 for
  directories and 0644 for files. Keep the code owned by www-data: KVS's
  self-update from the admin panel needs it (`kvs-install.sh:1062-1063`), and the
  Docker path does the same (`60-permissions.sh:113`, `:141-145`).

## 13. W1. Menu option 2 "Add site" runs a broken native install, even on Docker

- **Where:** `kvs-install.sh:2259` (labelled "work in progress, not working") and
  `:2270-2272`; documented as "2=Add site" in `README.md:259`.
- **Problem:** the option runs `whatisdomain` and `install_KVS`, the standalone
  path, whatever the install type. On a Docker host, which always takes this
  menu, it finds the live site's domain, re-owns its files to www-data (so the
  containers' uid 1000 loses write access), makes `setup_db.php` world-readable
  (as N1) and rewrites binary paths in the Docker site's `setup.php`.
- **Direction:** refuse option 2 on Docker hosts (or route it to
  `docker/multi-site/site-manager.sh add`), and fix the README entry.

## 14. U1. Upgrading a pre-26.10 stack removes acme; certificates stop renewing

- **Where:** `docker/docker-compose.yml:293-294` (acme behind the `direct-tls`
  profile since 66e90fb); `COMPOSE_PROFILES` kept as is by kvsctl
  (`cli/internal/instance/instance.go:342`, `cli/internal/upgrade/plan.go:678-697`);
  `removeLeftovers` (`cli/internal/upgrade/run.go:835-873`); `MIN_FROM=` empty in
  `.github/release.env:27`.
- **Problem:** an older stack ran acme without a profile. After `kvsctl adopt` and
  `kvsctl upgrade` to 26.11.0, acme is removed as a leftover and never starts
  again; health checks pass until the certificate expires. Re-running `setup.sh`
  afterwards is no remedy: setup refuses a kvsctl-managed stack.
- **Direction:** add `direct-tls` during the upgrade when `MODE=single` and
  `SSL_PROVIDER` is letsencrypt or zerossl, or block the plan when an active
  service would become inactive, or set `MIN_FROM`.

## 15. D13. The admin password is lost when kvs-init fails after setting it

- **Where:** `docker/setup.sh:5030-5035` (generated), `:5634-5643` (printed only
  after kvs-init succeeds), `:6008` (summary);
  `35-harden-admin-users.sh` (about `:70-95`).
- **Problem:** 35-harden writes the new password hash, then a later init step can
  fail (for example `80-manticore.sh:62-67` when kernel-scripts.com is
  unreachable); setup stops before printing the password. A re-run that keeps the
  database generates none and reports "preserved and verified". The only
  recovery, undocumented, is a re-run with a `KVS_ADMIN_PASSWORD` of 20 or more
  characters.
- **Direction:** show the password, or write it to a 0600 file, before kvs-init
  runs or on its failure; drop "verified" from the summary.

## 16. R2. Two sites can claim the same `www` host and break Caddy for all

- **Where:** `docker/multi-site/site-manager.sh:479-482` and `:277-304`
  (`add_site`, `write_caddy_site_config`, `configure_primary_site`).
- **Problem:** the collision check looks only for `<domain>.caddy`. `add a.com`
  creates a `www.a.com` redirect, and `add www.a.com` is then accepted; Caddy
  reports "ambiguous site definition" and every later reload fails, so a Caddy
  restart takes every site down and `reconfigure.sh` refuses to run in multi mode.
- **Direction:** collect every host in `caddy/sites/*.caddy` plus the primary's,
  and refuse `add` and `primary-config` on any overlap.

## 17. E3. Output under a symlink inside the site

- **Where:** `kvs_path_inside_site`, `kvs-export.sh:1352-1362`, with `tar -h` at
  about `:2449`.
- **Problem:** the "output inside the site" check compares only the resolved site
  directory. With `contents` linked to another disk and the output written there,
  tar archives its own output until the disk fills. In `--dump-only` mode, an
  output path written through the site (such as `site/contents/dump.sql.gz`)
  passes the check, and the database dump lands in the web-served directory,
  mode 0644, with exit 0.
- **Direction:** refuse an output located under the site, under its unresolved
  path as well as under the target of any symlink tar follows, in both archive
  and `--dump-only` modes; or exclude the output and staging paths from tar
  explicitly.

## Next in line

From the full report: the other tests that cannot fail (T3 to T6), then the
medium findings, among the first M2 (an imported dump can run client shell
commands inside the MariaDB container; a one-line sandbox header fixes it), D2,
D3, C9, Z4 (kvsctl backups fail on MariaDB 11.4 for rows over 24 MiB), H2, H3
and H5.

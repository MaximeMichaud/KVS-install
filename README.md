# KVS-install | Tested with 5.5.1, 6.1.2, 6.2.1, 6.3.2, 6.4.0 and 7.0.2

[![ShellCheck](https://github.com/MaximeMichaud/KVS-install/workflows/ShellCheck/badge.svg)](https://github.com/MaximeMichaud/KVS-install/actions?query=workflow%3AShellCheck)
[![Codacy Badge](https://app.codacy.com/project/badge/Grade/183a53d1a8ea49619c49d6fc2514c237)](https://app.codacy.com/gh/MaximeMichaud/KVS-install/dashboard?utm_source=gh&utm_medium=referral&utm_content=&utm_campaign=Badge_grade)
[![made-with-bash](https://img.shields.io/badge/-Made%20with%20Bash-1f425f.svg?logo=image%2Fpng%3Bbase64%2CiVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAAAGXRFWHRTb2Z0d2FyZQBBZG9iZSBJbWFnZVJlYWR5ccllPAAAAyZpVFh0WE1MOmNvbS5hZG9iZS54bXAAAAAAADw%2FeHBhY2tldCBiZWdpbj0i77u%2FIiBpZD0iVzVNME1wQ2VoaUh6cmVTek5UY3prYzlkIj8%2BIDx4OnhtcG1ldGEgeG1sbnM6eD0iYWRvYmU6bnM6bWV0YS8iIHg6eG1wdGs9IkFkb2JlIFhNUCBDb3JlIDUuNi1jMTExIDc5LjE1ODMyNSwgMjAxNS8wOS8xMC0wMToxMDoyMCAgICAgICAgIj4gPHJkZjpSREYgeG1sbnM6cmRmPSJodHRwOi8vd3d3LnczLm9yZy8xOTk5LzAyLzIyLXJkZi1zeW50YXgtbnMjIj4gPHJkZjpEZXNjcmlwdGlvbiByZGY6YWJvdXQ9IiIgeG1sbnM6eG1wPSJodHRwOi8vbnMuYWRvYmUuY29tL3hhcC8xLjAvIiB4bWxuczp4bXBNTT0iaHR0cDovL25zLmFkb2JlLmNvbS94YXAvMS4wL21tLyIgeG1sbnM6c3RSZWY9Imh0dHA6Ly9ucy5hZG9iZS5jb20veGFwLzEuMC9zVHlwZS9SZXNvdXJjZVJlZiMiIHhtcDpDcmVhdG9yVG9vbD0iQWRvYmUgUGhvdG9zaG9wIENDIDIwMTUgKFdpbmRvd3MpIiB4bXBNTTpJbnN0YW5jZUlEPSJ4bXAuaWlkOkE3MDg2QTAyQUZCMzExRTVBMkQxRDMzMkJDMUQ4RDk3IiB4bXBNTTpEb2N1bWVudElEPSJ4bXAuZGlkOkE3MDg2QTAzQUZCMzExRTVBMkQxRDMzMkJDMUQ4RDk3Ij4gPHhtcE1NOkRlcml2ZWRGcm9tIHN0UmVmOmluc3RhbmNlSUQ9InhtcC5paWQ6QTcwODZBMDBBRkIzMTFFNUEyRDFEMzMyQkMxRDhEOTciIHN0UmVmOmRvY3VtZW50SUQ9InhtcC5kaWQ6QTcwODZBMDFBRkIzMTFFNUEyRDFEMzMyQkMxRDhEOTciLz4gPC9yZGY6RGVzY3JpcHRpb24%2BIDwvcmRmOlJERj4gPC94OnhtcG1ldGE%2BIDw%2FeHBhY2tldCBlbmQ9InIiPz6lm45hAAADkklEQVR42qyVa0yTVxzGn7d9Wy03MS2ii8s%2BeokYNQSVhCzOjXZOFNF4jx%2BMRmPUMEUEqVG36jo2thizLSQSMd4N8ZoQ8RKjJtooaCpK6ZoCtRXKpRempbTv5ey83bhkAUphz8fznvP8znn%2B%2F3NeEEJgNBoRRSmz0ub%2FfuxEacBg%2FDmYtiCjgo5NG2mBXq%2BH5I1ogMRk9Zbd%2BQU2e1ML6VPLOyf5tvBQ8yT1lG10imxsABm7SLs898GTpyYynEzP60hO3trHDKvMigUwdeaceacqzp7nOI4n0SSIIjl36ao4Z356OV07fSQAk6xJ3XGg%2BLCr1d1OYlVHp4eUHPnerU79ZA%2F1kuv1JQMAg%2BE4O2P23EumF3VkvHprsZKMzKwbRUXFEyTvSIEmTVbrysp%2BWr8wfQHGK6WChVa3bKUmdWou%2BjpArdGkzZ41c1zG%2Fu5uGH4swzd561F%2BuhIT4%2BLnSuPsv9%2BJKIpjNr9dXYOyk7%2FBZrcjIT4eCnoKgedJP4BEqhG77E3NKP31FO7cfQA5K0dSYuLgz2TwCWJSOBzG6crzKK%2BohNfni%2Bx6OMUMMNe%2Fgf7ocbw0v0acKg6J8Ql0q%2BT%2FAXR5PNi5dz9c71upuQqCKFAD%2BYhrZLEAmpodaHO3Qy6TI3NhBpbrshGtOWKOSMYwYGQM8nJzoFJNxP2HjyIQho4PewK6hBktoDcUwtIln4PjOWzflQ%2Be5yl0yCCYgYikTclGlxadio%2BBQCSiW1UXoVGrKYwH4RgMrjU1HAB4vR6LzWYfFUCKxfS8Ftk5qxHoCUQAUkRJaSEokkV6Y%2F%2BJUOC4hn6A39NVXVBYeNP8piH6HeA4fPbpdBQV5KOx0QaL1YppX3Jgk0TwH2Vg6S3u%2BdB91%2B%2FpuNYPYFl5uP5V7ZqvsrX7jxqMXR6ff3gCQSTzFI0a1TX3wIs8ul%2Bq4HuWAAiM39vhOuR1O1fQ2gT%2F26Z8Z5vrl2OHi9OXZn995nLV9aFfS6UC9JeJPfuK0NBohWpCHMSAAsFe74WWP%2BvT25wtP9Bpob6uGqqyDnOtaeumjRu%2ByFu36VntK%2FPA5umTJeUtPWZSU9BCgud661odVp3DZtkc7AnYR33RRC708PrVi1larW7XwZIjLnd7R6SgSqWSNjU1B3F72pz5TZbXmX5vV81Yb7Lg7XT%2FUXriu8XLVqw6c6XqWnBKiiYU%2BMt3wWF7u7i91XlSEITwSAZ%2FCzAAHsJVbwXYFFEAAAAASUVORK5CYII%3D)](https://www.gnu.org/software/bash/)
[![GNU Licence](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://github.com/MaximeMichaud/KVS-install/blob/main/LICENSE)

This script automates the setup and configuration of Kernel Video Sharing (KVS), ensuring **optimal performance** and **security** with minimal dependencies and **stable** LTS packages.

We strongly recommend all users to thoroughly read this README.md to fully understand the features, limitations, and development aspects of the script.


## Usage

```bash
curl -fsSL https://raw.githubusercontent.com/MaximeMichaud/KVS-install/main/kvs-install.sh -o kvs-install.sh && sudo bash kvs-install.sh
```

The script will prompt you to choose between:

1. **Docker (recommended)** - Containerized installation with Docker Compose
2. **Standalone** - Traditional installation directly on the server

### Docker Installation

Docker installation is the recommended method. It provides:

- Isolated environment with all dependencies
- Easy updates and rollbacks
- Consistent configuration across environments
- Dragonfly cache (faster than Memcached)

Requirements:

- Docker with the Compose plugin (both installed by the script when Docker is missing; a Docker without the Compose plugin stops the installer)
- KVS archive file (`KVS_X.X.X_[domain.tld].zip`) in `/root`

The script will:

1. Install Docker if not present
2. Clone the repository to `/opt/kvs`
3. Configure environment variables automatically
4. Generate secure database passwords
5. Start all services via Docker Compose

### Standalone Installation

For traditional bare-metal installation on Debian systems.

### Headless Usage

Headless mode enables fully automated installations without interactive prompts. Ideal for scripted deployments, CI/CD pipelines, and mass installations.

#### Docker Headless (Recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/MaximeMichaud/KVS-install/main/kvs-install.sh -o kvs-install.sh
chmod +x kvs-install.sh

# Minimal (uses smart defaults)
HEADLESS=y \
KVS_EMAIL=admin@yourdomain.com \
./kvs-install.sh

# Full control
HEADLESS=y \
INSTALL_TYPE=1 \
MENU_OPTION=1 \
KVS_EMAIL=admin@yourdomain.com \
PREFIX_CHOICE=1 \
SSL_CHOICE=1 \
DB_CHOICE=1 \
IONCUBE_CHOICE=1 \
CACHE_CHOICE=1 \
MODE_CHOICE=1 \
./kvs-install.sh
```

| Variable | Values | Default | Description |
| -------- | ------ | ------- | ----------- |
| `HEADLESS` | `y` | - | Enable headless mode (required) |
| `INSTALL_TYPE` | `1`/`2` | `1` | 1=Docker, 2=Standalone |
| `MENU_OPTION` | `1-5` | `1` | 1=Install, 2=Add site, 3=Update PMA, 4=Update script, 5=Quit |
| `KVS_EMAIL` | email | - | Email for SSL certificates (required for Let's Encrypt/ZeroSSL) |
| `PREFIX_CHOICE` | `1-3` | `1` | 1=Auto (kvs-domain), 2=Legacy (kvs), 3=Custom |
| `SSL_CHOICE` | `1-3` | `1` | 1=Let's Encrypt, 2=ZeroSSL, 3=Self-signed |
| `DB_CHOICE` | `1-3` | `1` | MariaDB version (1=12.3, 2=11.8, 3=11.4) |
| `IONCUBE_CHOICE` | `1`/`2` | `1` | 1=Yes, 2=No |
| `CACHE_CHOICE` | `1`/`2` | `1` | 1=Dragonfly, 2=Memcached |
| `MODE_CHOICE` | `1`/`2` | `1` | 1=Single site, 2=Multi site |
| `MANTICORE_CHOICE` | `1`/`2` | `2` | 1=Manticore Search (the External Search plugin is pointed at it), 2=KVS search |
| `STOP_EXISTING` | `Y`/`n` | `Y` | Stop existing KVS containers |
| `DNS_CHOICE` | `1-3` | `2` | DNS check: 1=Retry, 2=Continue anyway, 3=Exit |
| `DISABLE_KVS_SUPPORT_ACCESS` | `true`/`false` | `false` | Turn off KVS support access (Kernel Team login with kvs_support); the admin dashboard re-enables it |
| `KVS_PHP_VERSION` | `7.4`, `8.1`-`8.4` | detected | PHP release for an unencoded archive (IONCUBE_CHOICE=2 or IONCUBE=NO); an encoded archive keeps the release KVS documents |
| `KVS_INSTALL_BRANCH` | branch | `main` | Branch of this repository installed into `/opt/kvs`, to try a change before it is merged (run the `kvs-install.sh` of that branch); works outside headless mode too |

#### Standalone Headless (Legacy)

```bash
HEADLESS=y \
INSTALL_TYPE=2 \
database_ver=12.3 \
IONCUBE=YES \
AUTOPACKAGEUPDATE=YES \
./kvs-install.sh
```

With `IONCUBE=NO` the archive is treated as unencoded and `KVS_PHP_VERSION` picks the PHP release to install (7.4, 8.1, 8.2, 8.3 or 8.4); interactive runs ask instead. An IonCube encoded archive keeps the release KVS documents for it.

### Importing an existing site (Docker, experimental)

An existing KVS site moves into the Docker stack from two inputs: its files and a dump of its database. KVS keeps everything else (videos, members, categories, settings) in that database, so the files alone cannot rebuild a site. The setup takes both from one of three sources:

- **An archive on the new server**, made by `kvs-export.sh` on the old server or by hand: a zip, 7z, tar, tar.gz, tar.zst, tar.xz or tar.bz2 that holds the site directory (the one with `admin/include/setup.php`, at the top or nested) and one dump (`.sql`, `.sql.gz`, `.sql.xz` or `.sql.zst`) next to it, nothing else. The tool the archive needs (`unzip`, `7zip`, `zstd`, `xz-utils` or `bzip2`) is installed when missing, and only that one.
- **A directory and a dump on the new server**, copied there by any means.
- **The old server over SSH**: the setup pipes `kvs-export.sh` to it, shows what it found (KVS version, domain, paths, database name, host and user with the password masked, table count, sizes), then streams the dump and mirrors the files with rsync (a tar stream when the old server has no rsync). The transfer is counted first, a dry run of rsync, and shown against that count: bytes and files done out of the whole, the rates of the last twenty seconds and the time left that follows the slower of the two, since the tail of a site is many small files where the bytes hardly move (rsync's own percentage and estimate are relative to the files its scan has found so far, and grow with it). One SSH connection serves the whole import, so a password is typed once, on ssh's own prompt; a run nobody attends hands it over with `IMPORT_REMOTE_PASSWORD` instead (to `sshpass`, installed when missing, through its environment). Nothing is installed or written on the old server, and its credentials are never stored on the new one.

Procedure:

1. No KVS archive is needed: the site brings its version (`admin/include/version.php`, which picks the PHP release), its encoding (`admin/include/functions_base.php`, IonCube or plain PHP, which decides whether the PHP image gets the loader) and its nginx rewrite rules (see below). An archive in `docker/kvs-archive/` is only a fallback for the rewrites and must then be of the site's version.
2. For the archive source, run the exporter on the old server. It finds the site, checks the database access with the credentials of `admin/include/setup_db.php`, dumps the database (zstd when installed, gzip otherwise) and writes one tar with the files, the dump and a manifest. Copy the result to the new server. The site size is measured first, a few entries at a time with a progress line every ten seconds; `--size-timeout SECONDS` bounds that and `--no-size` skips it, since millions of files take long to count. The summary lists every directory at the root, under `contents/` and the few under `admin/` that grow on their own, with its size and whether it travels: temporary files and compiled templates KVS rebuilds (`tmp`, `admin/data/tmp`, `admin/smarty/*`) travel as empty directories, hidden entries, network mounts (a storage server's content, on a KVS server) and the query logs of the KVS debug switch (`admin/logs/debug_sql_*.txt`, gigabytes on a busy site) stay behind, anything else at the root that is not KVS is reported as such; `--exclude PATH` leaves a directory behind (`contents/videos_sources`, an old `backup`), `--include PATH` takes a hidden entry or a mount along. The storage servers of the site are listed too: a local one outside the site directory is not carried and its path is not rewritten, a remote one stays where it is.

   ```bash
   curl -fsSL https://raw.githubusercontent.com/MaximeMichaud/KVS-install/main/kvs-export.sh -o kvs-export.sh
   sudo bash kvs-export.sh                  # archive in the current directory
   sudo bash kvs-export.sh --dump-only      # the compressed dump alone
   ```

3. Run the installer on the new server. Interactive runs ask whether to import and from where, show what was found and ask for confirmation. Headless runs set one source:

   ```bash
   IMPORT_ARCHIVE=/root/example.com-kvs-export-20260923-1200.tar \
     HEADLESS=y DOMAIN=example.com EMAIL=admin@example.com SSL_CHOICE=3 VOLUME_CHOICE=1 ./setup.sh

   IMPORT_SITE_DIR=/var/www/example.com IMPORT_DB_DUMP=/root/example.sql.zst \
     HEADLESS=y DOMAIN=example.com EMAIL=admin@example.com SSL_CHOICE=3 VOLUME_CHOICE=1 ./setup.sh

   IMPORT_REMOTE_HOST=old.example.com IMPORT_SSH_KEY=/root/.ssh/id_ed25519 \
     HEADLESS=y DOMAIN=example.com EMAIL=admin@example.com SSL_CHOICE=3 VOLUME_CHOICE=1 ./setup.sh
   ```

`IMPORT_REMOTE_USER` (root), `IMPORT_REMOTE_PORT` (22) and `IMPORT_REMOTE_DIR` (searched for when empty) complete the remote source; `IMPORT_SSH_KEY` names the key and `IMPORT_REMOTE_PASSWORD` the password when there is no key (it reaches `sshpass` through its environment, is written nowhere, and implies `IMPORT_SSH_ACCEPT_NEW=y`). Headless runs need one of the two, and `IMPORT_SSH_ACCEPT_NEW=y` to trust a host key that is not in `known_hosts` yet (interactive runs get ssh's own question, and a password is typed once: the connection is multiplexed). `IMPORT_SIZE_TIMEOUT` (300) is how many seconds the old server spends measuring the site size; past that the setup goes on with what was counted and the space used on the old server's filesystem as the upper bound, and only warns when even that bound may not fit. 0 measures the whole site. `IMPORT_EXCLUDE` (space separated paths relative to the site directory) leaves directories behind and `IMPORT_INCLUDE` takes a hidden entry or a network mount along, on top of what the exporter leaves behind on its own; the summary shows every directory with its size and what happens to it, interactive runs then ask for more paths to leave behind, and the choice is kept in `.env` so the second pass repeats it. The SSH user is root, or a user with passwordless sudo, which the setup detects and uses for the detection, the dump and the files; any other user only gets what it can read, and `setup_db.php` is root only on most installations. Start with a self-signed certificate (`SSL_CHOICE=3`) when the DNS still points at the old server, then run the setup again with Let's Encrypt after the switch.

A site that stays live during the transfer keeps changing, so a migration is two passes: the first one while the old site runs (the dump is taken first, then the files, so whatever the site creates meanwhile exists as files the database does not know yet, which is harmless), then the old site is frozen (KVS maintenance mode, or its web server stopped) and the same command runs again with `VOLUME_CHOICE=1`: rsync carries only the changes, a fresh dump replaces the database, and the DNS switches. The exporter dumps InnoDB tables in one transaction without blocking the site; MyISAM or Aria tables (older installations) are locked for the duration of the dump instead, and both the exporter and the setup say so.

The site can be tried under another domain first, a development subdomain the KVS license accepts (`DOMAIN=dev.example.com`, with the DNS of that name pointing at the new server so Let's Encrypt works from the first pass): the setup says that the site is configured for another domain, the init rewrites the project URL and the storage URLs on the old domain to the new one (URLs on other hosts, such as a CDN, stay), and the domain the site came from is kept in `.env` as `IMPORT_SOURCE_DOMAIN`. The copy holds the production database with its mail settings, remote storage servers and queues, so stop its cron container (`docker compose stop cron`) unless those are meant to run twice. When the real domain's turn comes on the same server, run the import again with the real `DOMAIN` and `IMPORT_REUSE_SITE_DIR=/var/www/dev.example.com`: the development stack's containers are removed (the two cannot share the ports), the container prefix follows the new domain, the site directory moves into place with its source marker, rsync carries the changes only and a fresh dump replaces the development database in a new volume; the development stack's volumes stay until removed (`docker volume ls --filter name=<its prefix>_`). A pass into a directory that already holds the files of an earlier pass from the same source checks the free space against the dump alone, so a large site does not need twice its size for the second pass.

The setup extracts an archive in a private directory next to `/var/www/<domain>` and moves the site in (the dump leaves the webroot before anything starts) or mirrors the remote site there, then checks the site (table prefix `ktvs_`, version against the archive, dump complete, symbolic links), prepares the dump for the container (database statements dropped, `INITIAL_VERSION` recorded when the old site never did, storage and conversion server paths moved from the old project path to `/var/www/kvs`, `DEFINER` clauses of views and triggers dropped, completion marker at the end), deletes the database volume of an earlier installation right before MariaDB starts (`VOLUME_CHOICE=1` gives the consent, interactive runs ask) and refuses to continue if the replay stopped part way. The init then adopts the site as it does for a fresh one: connection settings, project URL, server URLs on the site domain (URLs on other hosts, such as a CDN, stay), permissions, server type nginx. The admin password is kept unless it is still the KVS default. After the run, `logs/import-rows.txt` lists the rows of every table for a comparison with the old server, and `KVS_IMPORT_COMPLETED` in `.env` turns later runs of the same command into ordinary re-runs, unless `VOLUME_CHOICE=1` asks to replace the database and import again. A transfer or extraction that failed can be repeated with the same command: the site directory remembers its source and refuses any other. An import interrupted after MariaDB started replaying the dump leaves the staged dump in place and clears the completion marker, so an ordinary run refuses the partial database until the import runs again with `VOLUME_CHOICE=1`. The container mounts the site directory alone, so a symbolic link that leaves it (a `contents` directory on another disk) is copied with its target by the remote and directory sources, and refused with the list of links when it comes out of an archive or points nowhere. Files that vanish on a live site during the transfer are tolerated; files the SSH user cannot read stop it with rsync's list. Password protected archives are refused: extract them yourself and use the directory source.

The nginx configuration of the old server travels with the detection: `nginx -T`, so every file the running configuration includes (`nginx.conf`, `sites-enabled`, `conf.d`, snippets), or the files under `/etc/nginx` when the binary cannot print it. The setup saves it as `docker/import/<domain>.old-nginx.conf` and names the files that mention the site: custom rules come from there into `conf/nginx/templates/kvs.conf.tpl`, the template the nginx container regenerates its vhost from at every start. The KVS rewrite rules the vhost includes come from the site's `_INSTALL/nginx_config.txt` when the site kept that directory; otherwise from `IMPORT_NGINX_REWRITES=FILE` (the `nginx_config.txt` of the KVS package of the same version), else from an archive in `docker/kvs-archive/`, else the `rewrite` directives of the server blocks serving the site (a `root` naming its directory, `include` directives followed into the files of the dump) are recovered from the old configuration and written to `_INSTALL/nginx_config.txt` with a header saying so, after every transfer since rsync mirrors the old server. A file given or recovered is kept as `docker/import/<domain>.nginx_config.txt`, outside the webroot the init cleans `_INSTALL` from: the next pass, the take-over by the real domain and a re-run after the volumes were recreated take the rules from there, and a re-run never needs the archive. Without any of these the setup stops and says which to provide.

A site whose search ran through the KVS External Search plugin (Sphinx or Manticore on the old server) is announced: with Manticore enabled (`MANTICORE_CHOICE=1`) the init points the plugin at the stack's own Manticore (used always and replacing the internal search, as the plugin form advises for Manticore, the internal fallback kept for when Manticore is down), which indexes the imported database when its container starts and every hour, its three search scripts kept outside the KVS tree in the `manticore-api` volume shared by nginx, php-fpm and the init (the KVS audit plugin reports every file or directory it does not know inside the site as suspicious); without it the init removes the plugin configuration and KVS falls back to its MySQL search. A reindex by hand runs as the container's own user (`docker compose exec -u manticore manticore indexer --rotate --all`): run as root it leaves rotation files searchd cannot read, which the hourly job clears before indexing.

The table prefix comes from the site's `setup.php` (`ktvs_` for every archive KVS ships, whatever the old server used for an imported site) and reaches every script that names a table, the Manticore indexer included, through `TABLES_PREFIX` in `.env`.

The debug switches of the old server's `setup.php` are turned off on import: `enable_debug`, and `sql_debug`, the query log KVS support turns on by hand, which writes every query into `admin/logs/debug_sql_get.txt` and `debug_sql_post.txt` for as long as it stays on.

Not covered: a domain the KVS license does not accept (it needs a new archive from KVS), custom web server rules from the old vhost, and the standalone installer.

## Compatibility

The latest versions are more stable and we recommend using Debian 13 for the best support.

This script supports the following Linux distributions:

| Operating System | Support |
| --- | --- |
| Debian 12 | ✅ |
| Debian 13 | ✅ |

At present, non-Debian-based distros are not a priority. We recommend using the latest stable version of Debian as it was the development platform for this script. If you wish to use another distro, please open an issue on GitHub with a valid reason for consideration. Your case will be studied, and may provide support through Docker to achieve similar results.


### Hardware Recommendations

This script does not have specific minimum requirements, but we recommend using an SSD for KVS and an HDD for mass storage.

Additionally, certain configurations may need to be modified based on your site's needs, such as the number of PHP workers.

However, in general, you should be fine even with a site experiencing a high amount of traffic, unless you have specific usage patterns or inefficient code. This is why SSDs are important, or other measures may need to be implemented to improve performance if it becomes problematic.

### Tested Environment

**Development**: The script has been tested on a system with at least 1 vCPU, 2GB of RAM, and a 10GB SSD, proving sufficient for basic setup and testing.

**Production**: For production environments, we recommend a server configuration with more cores, increased RAM, and significantly more storage. KVS runs efficiently with an optimal configuration; however, performance heavily depends on the SSD speed, KVS theme, and custom plugins. Typically, the database is the most resource-intensive component. Configuring Sphinx can mitigate CPU load if necessary.

**Disk layout (Docker)**: the site files live in `/var/www/<domain>` (bind mount) and the volumes and build cache under the Docker data directory. Docker 29 stores images through containerd, under `/var/lib/containerd` rather than the Docker `data-root`, so moving only `data-root` leaves the images on the system disk. On a host with a small system disk and a large data disk, point `"data-root"` in `/etc/docker/daemon.json` and `root = "..."` in `/etc/containerd/config.toml` at the data disk, and create `/var/www/<domain>` as a symlink or mount on that disk before running the setup. The pre-flight check reports the tightest of these locations.

In a 2023 test, a standard installation left 6.3GB free out of 10GB. Watch demo 6 May 2023: [Demo Video](https://www.youtube.com/watch?v=WIa3xobMBR4).

## Features

- **Docker Support (Recommended)**: Full Docker Compose setup with NGINX, PHP-FPM, MariaDB, Dragonfly cache, and automatic SSL via ACME. Includes bind mount option for direct file access with kvs-cli.
- **Automated KVS Setup**: Installs all necessary dependencies, sets up the database, configures cron jobs, and prepares the webserver. Tailored to meet the [KVS requirements](https://www.kernel-video-sharing.com/en/requirements/).
- **Optimized Web Server Configuration**: Configures NGINX with the latest performance and security enhancements including HTTP/2 with ALPN, 0-RTT support for TLS 1.3, and x25519 support. Configurations are aligned with [Qualys SSL Labs](https://www.ssllabs.com/ssltest/) and Mozilla Foundation security standards, ensuring broad compatibility without compromising on security.
- **SSL Configuration via ACME.sh**: Automatically handles SSL certificate issuance and renewal using ACME.sh with ECDSA support for enhanced security.
- **Dynamic PHP Configuration**: Adjusts PHP settings based on the server's RAM to optimize KVS performance. Utilizes dynamic settings for systems with less than 4GB of RAM and static settings for systems with more (may require tuning depending on your traffic or if PHP workers use more RAM than average).
- **Extended PHP Support**: Uses Sury's repository to provide extended PHP version support, incorporating security updates from [Freexian's Debian LTS project](https://www.freexian.com/lts/debian/).
- **Memcached Configuration**: Sets Memcached memory allocation to a level suited for high traffic websites, optimizing cache performance.
- **Automated Updates**: Enables automatic updates for all installed packages and added repositories to keep the server secure and up-to-date.
- **Domain Configuration**: Automatically configures the server domain based on the uploaded CMS license, ensuring correct system operation. DNS zone configuration is still required.
- **MariaDB Latest LTS**: Installs the latest LTS version of MariaDB, offering more up-to-date solutions than standard repository versions with options to select preferred LTS versions.
- **Resource Monitoring Tools**: Includes additional packages like ncdu, vnstat, and nload for resource monitoring.
- **Optional IonCube Installation**: Provides the option to install or skip IonCube depending on licensing needs.
- **YT-DLP Installation**: Installs the latest version of yt-dlp, a fork of youtube-dl, ensuring up-to-date media downloading capabilities.

## To-Do

Features are continuously being developed to enhance the script, ensuring it remains comprehensive and up-to-date. For a detailed view of ongoing and planned improvements, visit the [project page](https://github.com/users/MaximeMichaud/projects/2).

If you have suggestions or questions, please feel free to open an issue on GitHub with the 'enhancement' or 'question' label.

Current priorities include increasing SSL flexibility to support configurations such as Cloudflare, improving NGINX configurations (e.g., handling `CF-Connecting-IP`), and integrating Cloudflare settings via API. We are also focused on enhancing testing protocols to identify bugs more efficiently and verifying that the installation is functional and optimized across all script components after completion.

Your input is valuable— if you believe certain enhancements should be prioritized, please let us know.

## Supports

The technologies used depend on what KVS supports, which means that some may not be the most up-to-date if KVS has not yet provided support for them. (For example, PHP 8.3/8.4 is not yet officially supported by KVS and thus not recommended.)

- NGINX 1.29.x mainline
- MariaDB 11.4 LTS, 11.8 LTS or 12.3 LTS (Default)
- PHP 7.4 or PHP 8.1 (since 6.2.0)
- phpMyAdmin 5.2.3 (or newer)

## Customization and Limitations

While this script is designed for a straightforward deployment on systems that do not already have a web server setup, it may require adjustments based on your server's specific setup and traffic needs. Here are a few points to consider:

- **Existing LEMP Stacks**: If you already have a LEMP stack installed and are familiar with its configuration, you may opt to use the NGINX configuration provided in this repository. This allows you to leverage the optimizations without running the script.
- **Server Configuration Understanding**: It is beneficial to review the functions within the script to understand the recommended configurations for NGINX, PHP-FPM, and Memcached. Specifically, the script adjusts NGINX to align with PHP-FPM settings and increases Memcached's default memory allocation, which is typically insufficient in default distribution installations.
- **Web Server Compatibility**: The script is optimized for NGINX and does not support other web servers such as Apache2, LiteSpeed, or Caddy. If your environment uses these or other web servers, manual configuration adjustments will be necessary.
- **Distro Compatibility**: This script is primarily designed for use with Debian-based distributions.

These points should help you tailor the installation to your needs, providing a deeper understanding of the Kernel Video Sharing platform configuration requirements and ensuring optimal performance.

## Contributing

Contributions to the script are welcome! If you have improvements or bug fixes, please fork the repository and submit a pull request.

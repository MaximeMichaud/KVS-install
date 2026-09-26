#!/bin/bash
# shellcheck disable=SC1091,SC2034,SC2154,SC2329

set -o pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly TEST_DIR
REPO_DIR=$(cd "$TEST_DIR/.." && pwd)
readonly REPO_DIR
readonly INSTALLER="$REPO_DIR/kvs-install.sh"

# shellcheck source=../kvs-install.sh
source "$INSTALLER"

fail() {
  echo "FAIL: $*" >&2
  return 1
}

assert_equal() {
  local expected="$1"
  local actual="$2"
  local message="$3"

  [[ "$actual" == "$expected" ]] || fail "$message (expected '$expected', got '$actual')"
}

assert_file_contains() {
  local file="$1"
  local pattern="$2"
  local message="$3"

  grep -Fq "$pattern" "$file" || fail "$message"
}

test_install_failure_stops_pipeline() {
  local temp_dir
  local status
  temp_dir=$(mktemp -d)
  trap 'rm -rf "$temp_dir"' RETURN

  install_gum() { :; }
  installQuestions() { :; }
  progress_header() { :; }
  progress_step() { :; }
  progress_done() { :; }
  progress_success() { : >"$temp_dir/success"; }
  aptupdate() { return 42; }
  aptinstall() { : >"$temp_dir/next-step"; }
  whatisdomain() { :; }
  check_dns_configuration() { :; }
  install_yt-dlp() { :; }
  aptinstall_php() { :; }
  aptinstall_memcached() { :; }
  aptinstall_nginx() { :; }
  aptinstall_mariadb() { :; }
  aptinstall_phpmyadmin() { :; }
  install_KVS() { :; }
  configure_kvs_system_settings() { :; }
  configure_kvs_servers() { :; }
  install_ioncube() { :; }
  insert_cronjob() { :; }
  install_acme.sh() { :; }
  configure_dynamic_php_fpm() { :; }
  autoUpdate() { :; }
  setupdone() { : >"$temp_dir/setupdone"; }

  script >"$temp_dir/output" 2>&1
  status=$?

  assert_equal "42" "$status" "script must preserve the failed step status" || return 1
  [[ ! -e "$temp_dir/next-step" ]] || fail "script continued after a failed step" || return 1
  [[ ! -e "$temp_dir/success" ]] || fail "script displayed success after a failed step" || return 1
  [[ ! -e "$temp_dir/setupdone" ]] || fail "script ran setupdone after a failed step" || return 1
}

test_visual_progress_failure_is_nonfatal() {
  local status
  local business_step_called=false

  progress_step() { :; }
  progress_done() { return 23; }
  successful_business_step() {
    business_step_called=true
    return 0
  }

  run_install_step "Business step" "Business step completed" successful_business_step
  status=$?

  assert_equal "0" "$status" "visual progress failure changed a successful business status" || return 1
  [[ "$business_step_called" == true ]] || fail "business step was not executed" || return 1
}

test_headless_php_detection() {
  local temp_dir
  local archive
  local status
  temp_dir=$(mktemp -d)
  trap 'rm -rf "$temp_dir"' RETURN
  HEADLESS=y
  KVS_ARCHIVE_DIR="$temp_dir"

  archive="$temp_dir/KVS_6.2.0_[example.com].zip"
  : >"$archive"
  installQuestions
  status=$?
  assert_equal "0" "$status" "headless KVS 6.2.0 detection failed" || return 1
  assert_equal "7.4" "$PHP" "KVS 6.2.0 must use PHP 7.4" || return 1
  assert_equal "/usr/lib/php/20190902" "$php_path" "KVS 6.2.0 used the wrong PHP extension path" || return 1

  rm "$archive"
  archive="$temp_dir/KVS_7.0.2_[example.com].zip"
  : >"$archive"
  installQuestions
  status=$?
  assert_equal "0" "$status" "headless KVS 7.0.2 detection failed" || return 1
  assert_equal "8.1" "$PHP" "KVS 7.0.2 must use PHP 8.1" || return 1
  assert_equal "/usr/lib/php/20210902" "$php_path" "KVS 7.0.2 used the wrong PHP extension path" || return 1

  rm "$archive"
  installQuestions >/dev/null 2>&1
  status=$?
  [[ $status -ne 0 ]] || fail "headless detection accepted a missing KVS archive" || return 1
}

test_php_version_choice_for_unencoded_archive() {
  local temp_dir
  local archive
  local status
  temp_dir=$(mktemp -d)
  trap 'rm -rf "$temp_dir"' RETURN
  HEADLESS=y
  KVS_ARCHIVE_DIR="$temp_dir"
  archive="$temp_dir/KVS_7.0.2_[example.com].zip"
  : >"$archive"

  # Encoded archive: the documented release is kept.
  IONCUBE=YES
  KVS_PHP_VERSION=""
  installQuestions >/dev/null 2>&1 || fail "encoded archive detection failed" || return 1
  assert_equal "8.1" "$PHP" "encoded archive must keep the documented PHP release" || return 1

  # Encoded archive with an explicit request: honored, with a warning.
  IONCUBE=YES
  KVS_PHP_VERSION=8.3
  installQuestions >"$temp_dir/output" 2>&1 || fail "explicit PHP request failed on an encoded archive" || return 1
  assert_equal "8.3" "$PHP" "explicit KVS_PHP_VERSION was not honored" || return 1
  assert_equal "/usr/lib/php/20230831" "$php_path" "PHP 8.3 used the wrong extension path" || return 1
  assert_file_contains "$temp_dir/output" "Proceeding because KVS_PHP_VERSION was set explicitly" \
    "encoded archive override did not warn" || return 1

  # Unencoded archive, headless, no request: the documented release.
  IONCUBE=NO
  KVS_PHP_VERSION=""
  installQuestions >/dev/null 2>&1 || fail "unencoded archive detection failed" || return 1
  assert_equal "8.1" "$PHP" "unencoded archive must default to the documented release" || return 1

  # Unencoded archive, headless request: honored.
  IONCUBE=NO
  KVS_PHP_VERSION=8.4
  installQuestions >/dev/null 2>&1 || fail "headless PHP choice failed" || return 1
  assert_equal "8.4" "$PHP" "headless KVS_PHP_VERSION was not applied" || return 1
  assert_equal "/usr/lib/php/20240924" "$php_path" "PHP 8.4 used the wrong extension path" || return 1

  # Unsupported request: refused.
  IONCUBE=NO
  KVS_PHP_VERSION=8.0
  installQuestions >/dev/null 2>&1
  status=$?
  [[ $status -ne 0 ]] || fail "unsupported PHP release was accepted" || return 1

  # Interactive unencoded archive: the prompt answer wins, Enter keeps the
  # documented release, and an invalid answer falls back to it at end of input.
  HEADLESS=n
  IONCUBE=NO
  KVS_PHP_VERSION=""
  configure_php_for_kvs_archive "$archive" <<<"8.2" >/dev/null 2>&1 ||
    fail "interactive PHP choice failed" || return 1
  assert_equal "8.2" "$PHP" "interactive PHP answer was not applied" || return 1
  assert_equal "/usr/lib/php/20220829" "$php_path" "PHP 8.2 used the wrong extension path" || return 1
  configure_php_for_kvs_archive "$archive" </dev/null >/dev/null 2>&1 ||
    fail "interactive PHP default failed" || return 1
  assert_equal "8.1" "$PHP" "Enter must keep the documented PHP release" || return 1
  configure_php_for_kvs_archive "$archive" <<<"nope" >/dev/null 2>&1 ||
    fail "interactive PHP fallback failed" || return 1
  assert_equal "8.1" "$PHP" "invalid PHP answer must fall back to the documented release" || return 1

  # Interactive encoded archive: no prompt, the documented release is kept.
  IONCUBE=YES
  configure_php_for_kvs_archive "$archive" <<<"8.4" >/dev/null 2>&1 ||
    fail "interactive encoded detection failed" || return 1
  assert_equal "8.1" "$PHP" "encoded archive must not offer a PHP choice" || return 1

  HEADLESS=y
  IONCUBE=YES
  KVS_PHP_VERSION=""
}

test_certificate_names_follow_the_www_record() {
  local names
  DOMAIN=example.com
  SERVER_IP=203.0.113.10

  dig() { printf '%s\n' "$MOCK_WWW_IP"; }

  MOCK_WWW_IP=198.51.100.7
  USE_WWW=false
  names=$(certificate_domain_names)
  assert_equal "-d example.com" "$names" "a www record hosted elsewhere must stay off the certificate" || return 1

  MOCK_WWW_IP=203.0.113.10
  USE_WWW=false
  names=$(certificate_domain_names)
  assert_equal "-d example.com -d www.example.com" "$names" "a www record pointing here must be covered" || return 1

  MOCK_WWW_IP=198.51.100.7
  USE_WWW=true
  names=$(certificate_domain_names)
  assert_equal "-d example.com -d www.example.com" "$names" "an explicit www site must request its name" || return 1

  MOCK_WWW_IP=""
  USE_WWW=false
  names=$(certificate_domain_names)
  assert_equal "-d example.com" "$names" "a missing www record must stay off the certificate" || return 1

  SERVER_IP=""
  MOCK_WWW_IP=203.0.113.10
  names=$(certificate_domain_names)
  assert_equal "-d example.com" "$names" "an unknown server address must not add www" || return 1

  unset -f dig
  USE_WWW=false
}

test_yt_dlp_step_is_repeatable() {
  local temp_dir
  local status
  temp_dir=$(mktemp -d)
  trap 'rm -rf "$temp_dir"' RETURN
  YT_DLP_BIN_DIR="$temp_dir"

  curl() {
    local output=""
    while (($# > 0)); do
      [[ "$1" == -o ]] && output="$2"
      shift
    done
    printf 'binary\n' >"$output"
  }

  install_yt-dlp >/dev/null 2>&1 || fail "first yt-dlp installation failed" || return 1
  [[ -L "$temp_dir/youtube-dl" ]] || fail "youtube-dl link was not created" || return 1
  install_yt-dlp >/dev/null 2>&1
  status=$?
  assert_equal "0" "$status" "a second yt-dlp installation must succeed with the link present" || return 1
  [[ -x "$temp_dir/yt-dlp" ]] || fail "yt-dlp is not executable after the second run" || return 1

  unset -f curl
  unset YT_DLP_BIN_DIR
}

test_package_steps_stop_when_apt_fails() {
  local temp_dir
  local status
  temp_dir=$(mktemp -d)
  trap 'rm -rf "$temp_dir"' RETURN
  APT_SOURCES_DIR="$temp_dir"
  VERSION_ID=13
  OS=debian
  ID=debian
  DOMAIN=example.com
  URL=example.com
  REDIRECT_SERVER_NAME='*.example.com'
  PHP=8.1
  webserver=nginx
  database_ver=12.3

  check_ports() { :; }
  curl() { :; }
  gpg() { :; }
  lsb_release() { echo trixie; }
  apt-get() {
    printf '%s\n' "$*" >>"$temp_dir/apt-calls"
    [[ "$1" == install ]] && return 100
    return 0
  }
  reset_nginx_configuration_dirs() { : >"$temp_dir/nginx-reset"; }
  openssl() { : >"$temp_dir/dhparam"; }
  service() { : >"$temp_dir/service"; }
  systemctl() { : >"$temp_dir/systemctl"; }
  sed() { : >"$temp_dir/sed"; }

  aptinstall_nginx >/dev/null 2>&1
  status=$?
  assert_equal "100" "$status" "nginx step must report the apt failure" || return 1
  assert_file_contains "$temp_dir/apt-calls" \
    "install -y -o Dpkg::Options::=--force-confnew -o Dpkg::Options::=--force-confmiss nginx" \
    "nginx install must take the packaged configuration files" || return 1
  [[ ! -e "$temp_dir/nginx-reset" ]] || fail "nginx configuration was reset although the package failed to install" || return 1
  [[ ! -e "$temp_dir/service" ]] || fail "nginx was restarted although the package failed to install" || return 1

  aptinstall_php >/dev/null 2>&1
  status=$?
  assert_equal "100" "$status" "PHP step must report the apt failure" || return 1
  [[ ! -e "$temp_dir/sed" ]] || fail "php.ini was edited although the packages failed to install" || return 1

  aptinstall_mariadb >/dev/null 2>&1
  status=$?
  assert_equal "100" "$status" "MariaDB step must report the apt failure" || return 1
  [[ ! -e "$temp_dir/systemctl" ]] || fail "MariaDB was enabled although the package failed to install" || return 1

  aptinstall_memcached >/dev/null 2>&1
  status=$?
  assert_equal "100" "$status" "Memcached step must report the apt failure" || return 1

  unset -f check_ports curl gpg lsb_release apt-get reset_nginx_configuration_dirs openssl service systemctl sed
  unset APT_SOURCES_DIR
}

test_nginx_step_needs_a_usable_mime_types() {
  local temp_dir
  local status
  temp_dir=$(mktemp -d)
  trap 'rm -rf "$temp_dir"' RETURN
  NGINX_MIME_TYPES="$temp_dir/mime.types"

  # A types map trimmed by a previous provisioning and no packaged copy: stop.
  printf 'types {\n    video/mp4 mp4;\n}\n' >"$NGINX_MIME_TYPES"
  ensure_nginx_mime_types >/dev/null 2>&1
  status=$?
  assert_equal "1" "$status" "a types map without CSS or JavaScript must fail the check" || return 1

  # The copy dpkg kept aside is restored.
  printf 'types {\n    text/css css;\n    application/javascript js;\n}\n' >"$NGINX_MIME_TYPES.dpkg-dist"
  ensure_nginx_mime_types >/dev/null 2>&1 ||
    fail "the packaged types map was not restored" || return 1
  assert_file_contains "$NGINX_MIME_TYPES" "application/javascript" \
    "restored types map must map JavaScript" || return 1

  # A complete map is left alone.
  printf 'types {\n    text/css css;\n    application/javascript js;\n    text/html html;\n}\n' >"$NGINX_MIME_TYPES"
  rm -f "$NGINX_MIME_TYPES.dpkg-dist"
  ensure_nginx_mime_types >/dev/null 2>&1 ||
    fail "a complete types map was rejected" || return 1
  assert_file_contains "$NGINX_MIME_TYPES" "text/html" \
    "a complete types map must not be rewritten" || return 1

  # In the step, the check runs before the configuration is replaced.
  printf 'types {\n    video/mp4 mp4;\n}\n' >"$NGINX_MIME_TYPES"
  APT_SOURCES_DIR="$temp_dir"
  VERSION_ID=13
  OS=debian
  check_ports() { :; }
  curl() { :; }
  gpg() { :; }
  lsb_release() { echo trixie; }
  apt-get() { return 0; }
  reset_nginx_configuration_dirs() { : >"$temp_dir/nginx-reset"; }
  openssl() { :; }
  service() { : >"$temp_dir/service"; }
  sed() { :; }

  aptinstall_nginx >/dev/null 2>&1
  status=$?
  assert_equal "1" "$status" "nginx step must stop on an unusable types map" || return 1
  [[ ! -e "$temp_dir/nginx-reset" ]] || fail "nginx configuration was reset although the types map is unusable" || return 1
  [[ ! -e "$temp_dir/service" ]] || fail "nginx was restarted although the types map is unusable" || return 1

  unset -f check_ports curl gpg lsb_release apt-get reset_nginx_configuration_dirs openssl service sed
  unset APT_SOURCES_DIR NGINX_MIME_TYPES
}

test_auto_updates_follow_upstream_repositories() {
  local temp_dir
  temp_dir=$(mktemp -d)
  trap 'rm -rf "$temp_dir"' RETURN
  APT_CONF_DIR="$temp_dir"
  AUTOPACKAGEUPDATE=YES
  printf 'APT::Periodic::Update-Package-Lists "0";\nAPT::Periodic::Unattended-Upgrade "0";\n' >"$temp_dir/20auto-upgrades"
  apt_install() { :; }

  autoUpdate >/dev/null 2>&1 || fail "auto-update step failed" || return 1
  assert_file_contains "$temp_dir/20auto-upgrades" 'APT::Periodic::Unattended-Upgrade "1";' \
    "periodic upgrades must be switched on" || return 1
  for origin in nginx deb.sury.org MariaDB; do
    assert_file_contains "$temp_dir/52kvs-upstream-origins" "origin=$origin,codename=\${distro_codename}" \
      "auto-updates must follow the $origin repository" || return 1
  done

  unset -f apt_install
  unset APT_CONF_DIR AUTOPACKAGEUPDATE
}

test_kvs_system_settings_select_nginx() {
  local temp_dir
  local status
  temp_dir=$(mktemp -d)
  trap 'rm -rf "$temp_dir"' RETURN
  DOMAIN=example.com
  MOCK_SERVER_TYPE=nginx
  mariadb() {
    printf '%s\n' "$*" >>"$temp_dir/mariadb-calls"
    if [[ "$*" == *SELECT* ]]; then
      printf '%s\n' "$MOCK_SERVER_TYPE"
    else
      cat >>"$temp_dir/sql"
    fi
  }

  configure_kvs_system_settings >/dev/null 2>&1 ||
    fail "system settings step failed although the read-back says nginx" || return 1
  assert_file_contains "$temp_dir/sql" "'\$.server_type', 'nginx'" \
    "settings update must switch the KVS server type to nginx" || return 1
  assert_file_contains "$temp_dir/sql" "'\$.file_upload_max_size', 2048" \
    "settings update must align the KVS upload limit with the PHP and nginx limits" || return 1
  assert_file_contains "$temp_dir/mariadb-calls" "example.com" \
    "settings update must target the site database" || return 1

  MOCK_SERVER_TYPE=other
  configure_kvs_system_settings >/dev/null 2>&1
  status=$?
  assert_equal "1" "$status" "a server type still reading other must fail the step" || return 1

  unset -f mariadb
  unset MOCK_SERVER_TYPE DOMAIN
}

test_archive_extraction_skips_an_installed_site() {
  local temp_dir
  temp_dir=$(mktemp -d)
  trap 'rm -rf "$temp_dir"' RETURN
  mkdir -p "$temp_dir/src/admin/include" "$temp_dir/root" "$temp_dir/www"
  printf "define('DB_PASS','pass');\n" >"$temp_dir/src/admin/include/setup_db.php"
  echo stock >"$temp_dir/src/index.php"
  (cd "$temp_dir/src" && zip -qr "$temp_dir/root/KVS_7.0.2_[example.com].zip" .)

  # First run: the archive is extracted and consumed.
  extract_kvs_archive "$temp_dir/www" "$temp_dir/root" >/dev/null ||
    fail "fresh extraction failed" || return 1
  [[ -f "$temp_dir/www/index.php" ]] || fail "archive was not extracted" || return 1
  [[ ! -e "$temp_dir/root/KVS_7.0.2_[example.com].zip" ]] || fail "archive was left behind after extraction" || return 1

  # Later run over the installed site: nothing is overwritten, the archive stays.
  echo customized >"$temp_dir/www/index.php"
  echo "define('DB_PASS','configured');" >"$temp_dir/www/admin/include/setup_db.php"
  echo dummy >"$temp_dir/root/KVS_7.0.2_[example.com].zip"
  extract_kvs_archive "$temp_dir/www" "$temp_dir/root" >/dev/null ||
    fail "re-run extraction guard failed" || return 1
  assert_equal "customized" "$(cat "$temp_dir/www/index.php")" "installed files must not be overwritten on a re-run" || return 1
  [[ -f "$temp_dir/root/KVS_7.0.2_[example.com].zip" ]] || fail "archive must stay in place on a re-run" || return 1
}

test_database_file_configuration_is_anchored() {
  local temp_dir
  local file
  temp_dir=$(mktemp -d)
  trap 'rm -rf "$temp_dir"' RETURN
  file="$temp_dir/setup_db.php"
  printf "define('DB_HOST','localhost');\ndefine('DB_LOGIN','login');\ndefine('DB_PASS','pass');\ndefine('DB_DEVICE','base');\n" >"$file"

  assert_equal "" "$(read_kvs_database_password "$file")" "stock placeholders must not read as a password" || return 1
  configure_kvs_database_file "$file" example.com 'p4ss/w0rd=' || fail "configuration failed" || return 1
  assert_file_contains "$file" "define('DB_LOGIN','example.com');" "login must be set" || return 1
  assert_file_contains "$file" "define('DB_PASS','p4ss/w0rd=');" "password must be set" || return 1
  assert_file_contains "$file" "define('DB_DEVICE','example.com');" "database must be set" || return 1
  assert_equal "p4ss/w0rd=" "$(read_kvs_database_password "$file")" "configured password must be read back" || return 1

  # A configured file is left alone, even with a new password on the re-run.
  configure_kvs_database_file "$file" example.com 'another' || fail "re-run configuration failed" || return 1
  assert_file_contains "$file" "define('DB_PASS','p4ss/w0rd=');" "configured password must survive a re-run" || return 1
  assert_equal "" "$(read_kvs_database_password "$temp_dir/missing.php")" "a missing file reads as no password" || return 1
}

test_acme_issue_reuses_a_valid_certificate() {
  local temp_dir
  local status
  temp_dir=$(mktemp -d)
  trap 'rm -rf "$temp_dir"' RETURN
  # shellcheck disable=SC2016  # the script must expand ACME_EXIT at run time
  printf '#!/bin/bash\nexit "${ACME_EXIT:-0}"\n' >"$temp_dir/acme.sh"
  chmod +x "$temp_dir/acme.sh"

  ACME_EXIT=0 acme_issue_or_reuse "$temp_dir/acme.sh" --issue >/dev/null || fail "a fresh issue must succeed" || return 1
  ACME_EXIT=2 acme_issue_or_reuse "$temp_dir/acme.sh" --issue >/dev/null || fail "a still valid certificate must count as success" || return 1
  ACME_EXIT=1 acme_issue_or_reuse "$temp_dir/acme.sh" --issue >/dev/null 2>&1
  status=$?
  assert_equal "1" "$status" "a failed issue must stay a failure" || return 1
}

test_port_check_accepts_the_installer_nginx() {
  local status

  ss() {
    case "$MOCK_LISTENER" in
      nginx) printf 'LISTEN 0 511 0.0.0.0:80 0.0.0.0:* users:(("nginx",pid=7,fd=6),("nginx",pid=1,fd=6))\nLISTEN 0 511 0.0.0.0:443 0.0.0.0:* users:(("nginx",pid=7,fd=7))\n' ;;
      apache) printf 'LISTEN 0 511 0.0.0.0:80 0.0.0.0:* users:(("apache2",pid=9,fd=4))\n' ;;
      *) : ;;
    esac
  }

  MOCK_LISTENER=none
  (check_ports </dev/null >/dev/null 2>&1) || fail "free ports must pass" || return 1
  MOCK_LISTENER=nginx
  (check_ports </dev/null >/dev/null 2>&1) || fail "nginx from a previous run must not abort a re-run" || return 1
  MOCK_LISTENER=apache
  (check_ports </dev/null >/dev/null 2>&1)
  status=$?
  assert_equal "1" "$status" "a foreign web server must still abort a headless run" || return 1

  unset -f ss
  unset MOCK_LISTENER
}

test_kvs_servers_follow_the_site_url() {
  local temp_dir
  local status
  temp_dir=$(mktemp -d)
  trap 'rm -rf "$temp_dir"' RETURN
  DOMAIN=example.com
  URL=example.com
  KVS_PATH=/var/www/example.com
  SSL_PROVIDER=letsencrypt
  MOCK_STALE=0
  mariadb() {
    case "$*" in
      *"NOT LIKE"*) printf '%s\n' "$MOCK_STALE" ;;
      *COALESCE*) printf '0\n' ;;
      *"COUNT(*)"*) printf '2\n' ;;
      *) cat >>"$temp_dir/sql" ;;
    esac
  }

  configure_kvs_servers >/dev/null 2>&1 || fail "server configuration failed" || return 1
  assert_file_contains "$temp_dir/sql" "'https://example.com/contents/'" "server URLs must follow the site URL" || return 1
  assert_file_contains "$temp_dir/sql" "'^https?://(www[.])?example[.]com(:[0-9]+)?/contents/'" "seeded www and plain http URLs must be matched" || return 1
  assert_file_contains "$temp_dir/sql" "streaming_skip_ssl_check = 0" "a public certificate must be verified" || return 1

  SSL_PROVIDER=selfsigned
  URL=www.example.com
  : >"$temp_dir/sql"
  configure_kvs_servers >/dev/null 2>&1 || fail "self-signed server configuration failed" || return 1
  assert_file_contains "$temp_dir/sql" "'https://www.example.com/contents/'" "the www choice must reach the server URLs" || return 1
  assert_file_contains "$temp_dir/sql" "streaming_skip_ssl_check = 1" "a self-signed certificate must not be verified" || return 1

  MOCK_STALE=1
  configure_kvs_servers >/dev/null 2>&1
  status=$?
  assert_equal "1" "$status" "a stale server URL must fail the step" || return 1

  unset -f mariadb
  unset MOCK_STALE DOMAIN URL KVS_PATH SSL_PROVIDER
}

test_domain_validation_respects_database_limit() {
  local max_label
  local oversized_label

  printf -v max_label '%*s' 60 ''
  printf -v oversized_label '%*s' 61 ''
  max_label=${max_label// /a}
  oversized_label=${oversized_label// /a}

  validate_kvs_domain "${max_label}.com" ||
    fail "a 64-character domain was rejected" || return 1
  if validate_kvs_domain "${oversized_label}.com"; then
    fail "a 65-character MariaDB identifier was accepted"
    return 1
  fi
  validate_kvs_domain "EXAMPLE.COM" || fail "domain validation is not case-insensitive" || return 1
  if validate_kvs_domain '-invalid.example'; then
    fail "an invalid DNS label was accepted"
    return 1
  fi
}

test_cron_is_unprivileged_and_multisite_idempotent() {
  local temp_dir
  local root_state
  local www_data_state
  local www_data_before_failed_root
  local root_before_read_failure
  local www_before_read_failure
  local count
  local active_count
  local job_line
  local path_after_line
  local status
  temp_dir=$(mktemp -d)
  trap 'rm -rf "$temp_dir"' RETURN
  export TEST_CRON_DIR="$temp_dir"
  root_state="$temp_dir/root"
  www_data_state="$temp_dir/www-data"
  DOMAIN=example.com
  PHP=8.1
  FAIL_ROOT_CRONTAB=false
  FAIL_WWW_DATA_ROLLBACK=false
  FAIL_ROOT_CRONTAB_READ=false
  FAIL_WWW_DATA_CRONTAB_READ=false

  cat >"$root_state" <<'EOF'
15 4 * * * /usr/local/bin/unrelated-job
15 3 * * * cd /var/www/neighbor.example/admin/include-backups && /usr/bin/php cleanup_cron.php > /dev/null 2>&1
#KVS
* * * * * cd /var/www/example.com/admin/include && /usr/bin/php7.4 cron.php > /dev/null 2>&1
* * * * * cd /var/www/legacy.example/admin/include && /usr/bin/php7.3 cron.php > /dev/null 2>&1
# BEGIN KVS CRON: root-only.example
*/5 * * * * cd  /var/www/root-only.example/admin/include && /usr/bin/php7.4 cron.php > /dev/null 2>&1
# END KVS CRON: root-only.example
* * * * * cd /var/www/commented.example/admin/include && /usr/bin/php7.4 cron.php > /dev/null 2>&1
#yt-dlp Automatic Update
0 0 * * * /bin/bash -c 'curl -L https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -o /usr/local/bin/yt-dlp && chmod a+rx /usr/local/bin/yt-dlp' > /dev/null 2>&1
EOF

cat >"$www_data_state" <<'EOF'
PATH=/before
# * * * * * cd /var/www/commented.example/admin/include && /usr/bin/php7.3 cron.php > /dev/null 2>&1
# BEGIN KVS CRON
* * * * * cd /var/www/legacy.example/admin/include && /usr/bin/php7.4 cron.php > /dev/null 2>&1
# END KVS CRON
* * * * * cd /var/www/example.com/admin/include && /usr/bin/php7.4 cron.php > /dev/null 2>&1
PATH=/after
30 2 * * * /usr/local/bin/www-data-unrelated
EOF

  crontab() {
    local user="root"
    local operation
    local state
    local next

    if [[ ${1:-} == "-u" ]]; then
      user="$2"
      shift 2
    fi
    operation="${1:-}"
    state="$TEST_CRON_DIR/$user"
    case $operation in
      -l)
        if [[ $user == root && $FAIL_ROOT_CRONTAB_READ == true ]]; then
          echo "root crontab read failed" >&2
          return 74
        fi
        if [[ $user == www-data && $FAIL_WWW_DATA_CRONTAB_READ == true ]]; then
          echo "www-data crontab read failed" >&2
          return 75
        fi
        [[ -f "$state" ]] && cat "$state"
        ;;
      -)
        if [[ $user == root && $FAIL_ROOT_CRONTAB == true ]]; then
          cat >/dev/null
          : > "$TEST_CRON_DIR/root-failed"
          return 47
        fi
        if [[ $user == www-data && $FAIL_WWW_DATA_ROLLBACK == true &&
              -f "$TEST_CRON_DIR/root-failed" ]]; then
          cat >/dev/null
          return 48
        fi
        next="$state.$BASHPID"
        cat >"$next"
        mv "$next" "$state"
        ;;
      *)
        return 64
        ;;
    esac
  }

  insert_cronjob >/dev/null
  insert_cronjob >/dev/null

  DOMAIN=second.example
  insert_cronjob >/dev/null
  insert_cronjob >/dev/null

  DOMAIN=example.com
  insert_cronjob >/dev/null

  assert_file_contains "$root_state" "/usr/local/bin/unrelated-job" "root crontab lost an unrelated job" || return 1
  assert_file_contains "$root_state" \
    "cd /var/www/neighbor.example/admin/include-backups && /usr/bin/php cleanup_cron.php" \
    "a non-KVS root cron was migrated as a KVS job" || return 1
  if grep -Fq '/var/www/neighbor.example/admin/include-backups' "$www_data_state"; then
    fail "a non-KVS root cron was copied to www-data"
    return 1
  fi
  if grep -Eq '/admin/include[[:space:]]+&&[[:space:]]+/usr/bin/php[0-9.]*[[:space:]]+cron\.php([[:space:]]|$)' \
      "$root_state"; then
    fail "KVS cron still runs from root's crontab"
    return 1
  fi
  count=$(grep -Fc "yt-dlp/releases/latest/download/yt-dlp" "$root_state" || true)
  assert_equal "1" "$count" "root yt-dlp updater is not idempotent" || return 1
  active_count=$(grep -v '^[[:space:]]*#' "$www_data_state" | grep -Fc "cron.php" || true)
  assert_equal "5" "$active_count" "www-data KVS cron did not preserve all active site jobs" || return 1
  count=$(grep -Fc "/var/www/example.com/admin/include" "$www_data_state" || true)
  assert_equal "1" "$count" "first site KVS cron is not idempotent" || return 1
  count=$(grep -Fc "/var/www/second.example/admin/include" "$www_data_state" || true)
  assert_equal "1" "$count" "second site KVS cron is not idempotent" || return 1
  count=$(grep -Fc "/var/www/legacy.example/admin/include" "$www_data_state" || true)
  assert_equal "1" "$count" "legacy KVS cron for another domain was removed" || return 1
  count=$(grep -Fc "/var/www/root-only.example/admin/include" "$www_data_state" || true)
  assert_equal "1" "$count" "another domain's root KVS cron was not migrated" || return 1
  active_count=$(grep -v '^[[:space:]]*#' "$www_data_state" |
    grep -Fc "/var/www/commented.example/admin/include" || true)
  assert_equal "1" "$active_count" "a commented job blocked an active root migration" || return 1
  assert_file_contains "$www_data_state" \
    '# * * * * * cd /var/www/commented.example/admin/include' \
    "a commented www-data job was not preserved" || return 1
  assert_file_contains "$www_data_state" "/usr/bin/php7.4 cron.php" "migrated cron lost its original PHP binary" || return 1
  if grep -v '^[[:space:]]*#' "$www_data_state" | grep -Fq "/usr/bin/php7.3 cron.php"; then
    fail "a root duplicate replaced the existing www-data job"
    return 1
  fi
  assert_file_contains "$www_data_state" "# BEGIN KVS CRON: example.com" "first site marker is not domain-specific" || return 1
  assert_file_contains "$www_data_state" "# BEGIN KVS CRON: second.example" "second site marker is not domain-specific" || return 1
  assert_file_contains "$www_data_state" "/usr/bin/php8.1 cron.php" "www-data KVS cron uses the wrong PHP binary" || return 1
  assert_file_contains "$www_data_state" "/usr/local/bin/www-data-unrelated" \
    "an unrelated www-data job was removed" || return 1
  job_line=$(grep -nF '/var/www/legacy.example/admin/include' "$www_data_state" |
    grep -v '^[[:space:]]*#' | head -n 1 | cut -d: -f1)
  path_after_line=$(grep -nFx 'PATH=/after' "$www_data_state" | cut -d: -f1)
  [ "$job_line" -lt "$path_after_line" ] ||
    fail "cron normalization changed the environment of an existing site job" || return 1
  job_line=$(grep -nF '/var/www/example.com/admin/include' "$www_data_state" |
    head -n 1 | cut -d: -f1)
  [ "$job_line" -lt "$path_after_line" ] ||
    fail "cron update changed the environment of the current site job" || return 1

  root_before_read_failure=$(cat "$root_state")
  www_before_read_failure=$(cat "$www_data_state")
  DOMAIN=read-failure.example
  FAIL_ROOT_CRONTAB_READ=true
  insert_cronjob >/dev/null 2>&1
  status=$?
  FAIL_ROOT_CRONTAB_READ=false
  assert_equal "74" "$status" "a root crontab read failure was ignored" || return 1
  assert_equal "$root_before_read_failure" "$(cat "$root_state")" \
    "a root read failure changed root's crontab" || return 1
  assert_equal "$www_before_read_failure" "$(cat "$www_data_state")" \
    "a root read failure changed www-data's crontab" || return 1

  FAIL_WWW_DATA_CRONTAB_READ=true
  insert_cronjob >/dev/null 2>&1
  status=$?
  FAIL_WWW_DATA_CRONTAB_READ=false
  assert_equal "75" "$status" "a www-data crontab read failure was ignored" || return 1
  assert_equal "$root_before_read_failure" "$(cat "$root_state")" \
    "a www-data read failure changed root's crontab" || return 1
  assert_equal "$www_before_read_failure" "$(cat "$www_data_state")" \
    "a www-data read failure changed www-data's crontab" || return 1

  www_data_before_failed_root=$(cat "$www_data_state")
  DOMAIN=failed.example
  FAIL_ROOT_CRONTAB=true
  insert_cronjob >/dev/null 2>&1
  status=$?
  FAIL_ROOT_CRONTAB=false
  rm -f "$TEST_CRON_DIR/root-failed"
  assert_equal "47" "$status" "a failed root crontab update returned the wrong status" || return 1
  assert_equal "$www_data_before_failed_root" "$(cat "$www_data_state")" \
    "a failed root crontab update did not restore www-data" || return 1

  DOMAIN=double-failure.example
  FAIL_ROOT_CRONTAB=true
  FAIL_WWW_DATA_ROLLBACK=true
  insert_cronjob >"$temp_dir/double-failure-output" 2>&1
  status=$?
  FAIL_ROOT_CRONTAB=false
  FAIL_WWW_DATA_ROLLBACK=false
  assert_equal "48" "$status" "a failed rollback was not surfaced" || return 1
  assert_file_contains "$temp_dir/double-failure-output" \
    "Failed to restore www-data crontab" "a failed rollback was not reported" || return 1
}

test_restore_preserves_backup_until_success() {
  local temp_dir
  local install_dir
  local backup_dir
  local status
  temp_dir=$(mktemp -d)
  trap 'rm -rf "$temp_dir"' RETURN
  install_dir="$temp_dir/install"
  backup_dir="$temp_dir/backup"
  mkdir -p "$backup_dir/kvs-archive"
  printf 'configuration\n' >"$backup_dir/.env"
  printf 'archive\n' >"$backup_dir/kvs-archive/KVS_7.0.2_[example.com].zip"

  restore_user_data "$install_dir" "$backup_dir" >/dev/null 2>&1
  status=$?
  [[ $status -ne 0 ]] || fail "restore unexpectedly succeeded without a clone destination" || return 1
  [[ -f "$backup_dir/.env" ]] || fail "failed restore deleted the .env backup" || return 1
  [[ -f "$backup_dir/kvs-archive/KVS_7.0.2_[example.com].zip" ]] || fail "failed restore deleted the archive backup" || return 1

  mkdir -p "$install_dir/docker"
  restore_user_data "$install_dir" "$backup_dir" >/dev/null
  status=$?
  assert_equal "0" "$status" "restore failed with a valid clone destination" || return 1
  assert_file_contains "$install_dir/docker/.env" "configuration" "restore did not copy .env" || return 1
  [[ -f "$install_dir/docker/kvs-archive/KVS_7.0.2_[example.com].zip" ]] || fail "restore did not copy the KVS archive" || return 1
  [[ ! -e "$backup_dir" ]] || fail "successful restore did not remove its temporary backup" || return 1
}

test_failed_clone_keeps_user_backup() {
  local temp_dir
  local status
  temp_dir=$(mktemp -d)
  trap 'rm -rf "$temp_dir"' RETURN
  export KVS_INSTALL_DIR="$temp_dir/install"
  export KVS_BACKUP_DIR="$temp_dir/backup"
  mkdir -p "$KVS_INSTALL_DIR/docker/kvs-archive"
  printf 'configuration\n' >"$KVS_INSTALL_DIR/docker/.env"
  printf 'archive\n' >"$KVS_INSTALL_DIR/docker/kvs-archive/KVS_7.0.2_[example.com].zip"

  docker() { return 0; }
  git() {
    [[ ${1:-} == "clone" ]] && return 37
    return 0
  }

  dockerInstall >/dev/null 2>&1
  status=$?

  assert_equal "37" "$status" "dockerInstall did not preserve the clone failure status" || return 1
  assert_equal "700" "$(stat -c '%a' "$KVS_BACKUP_DIR")" "backup directory permissions are not private" || return 1
  assert_equal "600" "$(stat -c '%a' "$KVS_BACKUP_DIR/.env")" "backed-up .env permissions are not private" || return 1
  [[ -f "$KVS_BACKUP_DIR/.env" ]] || fail "failed clone deleted the .env backup" || return 1
  [[ -f "$KVS_BACKUP_DIR/kvs-archive/KVS_7.0.2_[example.com].zip" ]] || fail "failed clone deleted the archive backup" || return 1
}

test_phpmyadmin_failure_preserves_installation() {
  local temp_dir
  local install_dir
  local status
  temp_dir=$(mktemp -d)
  trap 'rm -rf "$temp_dir"' RETURN
  install_dir="$temp_dir/phpmyadmin"
  mkdir -p "$install_dir"
  printf 'working-version\n' >"$install_dir/index.php"

  curl() { return 22; }

  updatephpMyAdmin "$install_dir" "https://invalid.test/downloads/" >/dev/null 2>&1
  status=$?

  assert_equal "22" "$status" "phpMyAdmin update did not preserve the download failure status" || return 1
  assert_file_contains "$install_dir/index.php" "working-version" "failed phpMyAdmin update destroyed the working installation" || return 1
}

test_phpmyadmin_success_swaps_staged_installation() {
  local temp_dir
  local install_dir
  local fixture_dir
  local fixture_archive
  local expected_uid
  local expected_gid
  local actual_mode
  local actual_uid
  local actual_gid
  local status
  umask 077
  temp_dir=$(mktemp -d)
  trap 'rm -rf "$temp_dir"' RETURN
  install_dir="$temp_dir/phpmyadmin"
  fixture_dir="$temp_dir/fixture/phpMyAdmin-test"
  fixture_archive="$temp_dir/phpmyadmin-fixture.tar.gz"
  mkdir -p "$install_dir" "$fixture_dir"
  chmod 0755 "$install_dir"
  expected_uid=$(stat -c '%u' "$install_dir")
  expected_gid=$(stat -c '%g' "$install_dir")
  printf 'working-version\n' >"$install_dir/old-sentinel"
  printf 'new-version\n' >"$fixture_dir/index.php"
  cat >"$fixture_dir/config.sample.inc.php" <<'EOF'
<?php
$cfg['blowfish_secret'] = '';
EOF
  tar czf "$fixture_archive" -C "$temp_dir/fixture" phpMyAdmin-test
  export TEST_PMA_ARCHIVE="$fixture_archive"

  curl() {
    local output=""
    local argument
    local previous=""

    if [[ $* == *"downloads.test"* ]]; then
      printf '<a href="https://files.phpmyadmin.net/phpMyAdmin/test/phpMyAdmin-test-all-languages.tar.gz">download</a>\n'
      return 0
    fi
    for argument in "$@"; do
      if [[ $previous == "-o" ]]; then
        output="$argument"
        break
      fi
      previous="$argument"
    done
    [[ -n "$output" ]] || return 64
    cp "$TEST_PMA_ARCHIVE" "$output"
  }
  export TEST_PMA_CHOWN_LOG="$temp_dir/chown.log"
  chown() { printf '%s\n' "$*" >> "$TEST_PMA_CHOWN_LOG"; }
  openssl() { printf 'fixed-test-secret\n'; }

  updatephpMyAdmin "$install_dir" "https://downloads.test/" >/dev/null 2>&1
  status=$?

  assert_equal "0" "$status" "valid staged phpMyAdmin update failed" || return 1
  [[ ! -e "$install_dir/old-sentinel" ]] || fail "successful phpMyAdmin update retained old content" || return 1
  assert_file_contains "$install_dir/index.php" "new-version" "successful phpMyAdmin update did not install new content" || return 1
  assert_file_contains "$install_dir/config.inc.php" "fixed-test-secret" "successful phpMyAdmin update did not generate its config" || return 1
  actual_mode=$(stat -c '%a' "$install_dir")
  actual_uid=$(stat -c '%u' "$install_dir")
  actual_gid=$(stat -c '%g' "$install_dir")
  assert_equal "755" "$actual_mode" "phpMyAdmin update did not preserve the installation mode under umask 077" || return 1
  assert_equal "$expected_uid" "$actual_uid" "phpMyAdmin update changed the installation owner" || return 1
  assert_equal "$expected_gid" "$actual_gid" "phpMyAdmin update changed the installation group" || return 1
  grep -Eq "^${expected_uid}:${expected_gid} .*/new$" "$TEST_PMA_CHOWN_LOG" ||
    fail "phpMyAdmin staging directory did not receive the preserved owner and group" || return 1
}

test_nginx_cleanup_uses_scoped_paths() {
  local temp_dir
  local current_dir
  local nginx_dir
  temp_dir=$(mktemp -d)
  trap 'rm -rf "$temp_dir"' RETURN
  current_dir="$temp_dir/current"
  nginx_dir="$temp_dir/etc/nginx"
  mkdir -p "$current_dir/conf.d" "$nginx_dir/conf.d"
  printf 'keep\n' >"$current_dir/conf.d/user-sentinel"
  printf 'remove\n' >"$nginx_dir/conf.d/old-config"

  cd "$current_dir" || return 1
  reset_nginx_configuration_dirs "$nginx_dir/conf.d" "$nginx_dir/globals"

  [[ -f "$current_dir/conf.d/user-sentinel" ]] || fail "NGINX cleanup deleted a relative conf.d directory" || return 1
  [[ ! -e "$nginx_dir/conf.d/old-config" ]] || fail "NGINX cleanup retained the old configured directory" || return 1
  [[ -d "$nginx_dir/conf.d" && -d "$nginx_dir/globals" ]] || fail "NGINX cleanup did not recreate required directories" || return 1
  if grep -Eq 'rm -rf[[:space:]]+conf\.d' "$INSTALLER"; then
    fail "installer still contains a relative rm -rf conf.d"
    return 1
  fi
}

test_runtime_input_stays_quiet_without_a_terminal() {
  local output

  # setsid detaches from the controlling terminal the way nohup, cron or a
  # CI runner would: /dev/tty exists but cannot be opened.
  # shellcheck disable=SC2016  # The inner shell expands $1 and $(cat).
  output=$(setsid bash -c 'source "$1"; initialize_runtime_input; echo "stdin=$(cat)"' _ "$INSTALLER" <<< "piped" 2>&1)
  assert_equal "stdin=piped" "$output" "a detached run must keep its piped stdin without complaining"
}

run_test() {
  local name="$1"
  local function_name="$2"

  if ("$function_name"); then
    echo "PASS: $name"
    return 0
  fi
  echo "FAIL: $name" >&2
  return 1
}

failures=0
test_import_source_given_needs_no_archive() {
  (
    unset IMPORT_REMOTE_HOST IMPORT_ARCHIVE IMPORT_SITE_DIR IMPORT_CHOICE
    import_source_given && exit 1
    IMPORT_REMOTE_HOST=old.example.com import_source_given || exit 2
    IMPORT_ARCHIVE=/root/site.tar import_source_given || exit 3
    IMPORT_SITE_DIR=/var/www/old import_source_given || exit 4
    IMPORT_CHOICE=4 import_source_given || exit 5
    IMPORT_CHOICE=1 import_source_given && exit 6
    exit 0
  ) || fail "an import source in the environment must be recognized (case $?)"
}

run_test "installation failures stop the pipeline" test_install_failure_stops_pipeline || failures=$((failures + 1))
run_test "visual progress failures are non-fatal" test_visual_progress_failure_is_nonfatal || failures=$((failures + 1))
run_test "headless PHP detection" test_headless_php_detection || failures=$((failures + 1))
run_test "PHP choice for unencoded archives" test_php_version_choice_for_unencoded_archive || failures=$((failures + 1))
run_test "certificate names follow the www record" test_certificate_names_follow_the_www_record || failures=$((failures + 1))
run_test "yt-dlp step is repeatable" test_yt_dlp_step_is_repeatable || failures=$((failures + 1))
run_test "package steps stop when apt fails" test_package_steps_stop_when_apt_fails || failures=$((failures + 1))
run_test "nginx step needs a usable mime.types" test_nginx_step_needs_a_usable_mime_types || failures=$((failures + 1))
run_test "auto-updates follow upstream repositories" test_auto_updates_follow_upstream_repositories || failures=$((failures + 1))
run_test "KVS system settings select nginx" test_kvs_system_settings_select_nginx || failures=$((failures + 1))
run_test "archive extraction skips an installed site" test_archive_extraction_skips_an_installed_site || failures=$((failures + 1))
run_test "database file configuration is anchored" test_database_file_configuration_is_anchored || failures=$((failures + 1))
run_test "acme issue reuses a valid certificate" test_acme_issue_reuses_a_valid_certificate || failures=$((failures + 1))
run_test "port check accepts the installer nginx" test_port_check_accepts_the_installer_nginx || failures=$((failures + 1))
run_test "KVS servers follow the site URL" test_kvs_servers_follow_the_site_url || failures=$((failures + 1))
run_test "domain validation respects MariaDB limits" test_domain_validation_respects_database_limit || failures=$((failures + 1))
run_test "KVS cron privilege and multi-site idempotence" test_cron_is_unprivileged_and_multisite_idempotent || failures=$((failures + 1))
run_test "backup survives failed restore" test_restore_preserves_backup_until_success || failures=$((failures + 1))
run_test "backup survives failed clone" test_failed_clone_keeps_user_backup || failures=$((failures + 1))
run_test "phpMyAdmin failure is non-destructive" test_phpmyadmin_failure_preserves_installation || failures=$((failures + 1))
run_test "phpMyAdmin staged update succeeds" test_phpmyadmin_success_swaps_staged_installation || failures=$((failures + 1))
run_test "NGINX cleanup is scoped" test_nginx_cleanup_uses_scoped_paths || failures=$((failures + 1))
run_test "runtime input stays quiet without a terminal" test_runtime_input_stays_quiet_without_a_terminal || failures=$((failures + 1))
run_test "an import source needs no archive" test_import_source_given_needs_no_archive || failures=$((failures + 1))

if ((failures != 0)); then
  echo "$failures test(s) failed" >&2
  exit 1
fi

echo "All kvs-install tests passed"

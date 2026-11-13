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

  # Issue #33: 7.0.3 archives can contain PHP 8.2-encoded files, which
  # cannot run on PHP 8.1. Use the PHP 8.3 runtime recommended by KVS.
  local version
  for version in 7.0.3 7.0.10 7.1.0 8.0.0; do
    rm "$archive"
    archive="$temp_dir/KVS_${version}_[example.com].zip"
    : >"$archive"
    installQuestions || fail "headless KVS $version detection failed" || return 1
    assert_equal "8.3" "$PHP" "KVS $version must default to PHP 8.3" || return 1
    assert_equal "/usr/lib/php/20230831" "$php_path" "KVS $version used the wrong PHP extension path" || return 1
  done

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

  rm "$archive"
  archive="$temp_dir/KVS_7.0.3_[example.com].zip"
  : >"$archive"
  configure_php_for_kvs_archive "$archive" </dev/null >/dev/null 2>&1 || return 1
  assert_equal "8.3" "$PHP" "encoded 7.0.3 must default to PHP 8.3 without prompting" || return 1
  IONCUBE=NO
  configure_php_for_kvs_archive "$archive" <<<"" >/dev/null 2>&1 || return 1
  assert_equal "8.3" "$PHP" "unencoded 7.0.3 must default to PHP 8.3 interactively" || return 1

  # An explicit compatible choice must not be described as guaranteed to fail.
  IONCUBE=YES
  KVS_PHP_VERSION=8.2
  configure_php_for_kvs_archive "$archive" >"$temp_dir/output" 2>&1 || return 1
  assert_equal "8.2" "$PHP" "encoded 7.0.3 must honor an explicit PHP 8.2 request" || return 1
  if grep -Fq 'refuses every encoded file' "$temp_dir/output"; then
    fail "a PHP 8.2 override for 7.0.3 must not be described as incompatible" || return 1
  fi

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

# The nginx step downloaded its files from main whatever copy ran, never
# checked a download, and restarted nginx with whatever came. It must take
# the files of the checkout it runs from, or of the branch KVS_INSTALL_BRANCH
# names, stop on the first file it cannot get, and let nginx check the
# result before a restart. Every stub refuses a path outside the test
# directory, so no version of the step can touch /etc/nginx here.
test_nginx_files_come_from_the_checkout_or_the_branch() {
  local temp_dir nginx_dir status file
  local -a files=(nginx.conf globals/general.conf globals/security.conf globals/php_fastcgi.conf
    globals/letsencrypt.conf globals/cloudflare-ip-list.conf)
  temp_dir=$(mktemp -d)
  trap 'rm -rf "$temp_dir"' RETURN
  nginx_dir="$temp_dir/nginx"
  APT_SOURCES_DIR="$temp_dir"
  KVS_NGINX_DIR="$nginx_dir"
  NGINX_MIME_TYPES="$temp_dir/mime.types"
  printf 'types {\n    text/css css;\n    application/javascript js;\n}\n' >"$NGINX_MIME_TYPES"
  VERSION_ID=13
  OS=debian
  DOMAIN=example.test
  USE_WWW=false
  PHP=8.4
  set_site_hostnames
  unset KVS_INSTALL_SELF KVS_INSTALL_BRANCH

  check_ports() { :; }
  gpg() { :; }
  lsb_release() { echo trixie; }
  apt-get() { return 0; }
  reset_nginx_configuration_dirs() {
    [[ "${1:-}" == "$nginx_dir/conf.d" && "${2:-}" == "$nginx_dir/globals" ]] || return 99
    rm -rf "$1" && mkdir -p "$1" "$2"
  }
  openssl() {
    [[ "$1 $2 $4" == "dhparam -out 2048" && "$3" == "$nginx_dir/"*/dhparam.pem ]] || return 97
    [[ -z "${OPENSSL_RC:-}" ]] || return "$OPENSSL_RC"
    : >"$3"
  }
  nginx() { printf 'nginx %s\n' "$*" >>"$temp_dir/calls"; return "${NGINX_RC:-0}"; }
  service() { printf 'service %s\n' "$*" >>"$temp_dir/calls"; }
  # curl serves the repository file of a raw URL, records the URL, and
  # fails with 22, its HTTP error status, for the file CURL_FAIL names. It
  # writes part of that file first, as an interrupted transfer does, so the
  # test sees what a failure leaves behind.
  curl() {
    local output="" url=""
    while [[ $# -gt 0 ]]; do
      case $1 in
        -o) output=$2; shift ;;
        https://*) url=$1 ;;
      esac
      shift
    done
    printf '%s\n' "$url" >>"$temp_dir/urls"
    [[ -n "$output" ]] || return 0
    [[ "$output" == "$temp_dir/"* ]] || return 98
    if [[ -n "${CURL_FAIL:-}" && "$url" == *"/conf/nginx/$CURL_FAIL" ]]; then
      printf 'partial' >"$output"
      return 22
    fi
    cp "$REPO_DIR/conf/nginx/${url#*/conf/nginx/}" "$output"
  }
  run_nginx_step() {
    rm -rf "$nginx_dir" "$temp_dir/calls" "$temp_dir/urls"
    mkdir -p "$nginx_dir"
    aptinstall_nginx >"$temp_dir/out" 2>&1
  }
  same_files() {
    [[ -f "$nginx_dir/dhparam.pem" ]] || fail "$1: no DH parameters" || return 1
    for file in "${files[@]}"; do
      cmp -s "$REPO_DIR/conf/nginx/$file" "$nginx_dir/$file" ||
        fail "$1: $file is not the copy of conf/nginx/$file" || return 1
    done
    for file in example.test.conf.disabled sslgen.conf; do
      [[ -s "$nginx_dir/conf.d/$file" ]] || fail "$1: conf.d/$file was not written" || return 1
      ! grep -qE 'domain\.tld|project_url|redirect_server_name|phpX\.X' "$nginx_dir/conf.d/$file" ||
        fail "$1: conf.d/$file kept a placeholder" || return 1
    done
  }

  # From a checkout: its own files, nothing downloaded but the signing key.
  run_nginx_step
  status=$?
  assert_equal "0" "$status" "the step from a checkout must succeed: $(cat "$temp_dir/out")" || return 1
  same_files "from a checkout" || return 1
  ! grep -q 'conf/nginx' "$temp_dir/urls" ||
    fail "a checkout downloaded nginx files: $(grep conf/nginx "$temp_dir/urls")" || return 1
  assert_equal $'nginx -t -q\nservice nginx restart' "$(cat "$temp_dir/calls")" \
    "nginx must check the configuration before the restart" || return 1

  # bash reading the script from a pipe names it "bash", which readlink -f
  # turns into a missing file of the current directory: the conf/nginx
  # there does not go with the script.
  ! KVS_INSTALL_SELF="$REPO_DIR/bash" nginx_conf_source_dir >/dev/null ||
    fail "a script read from a pipe took the files of the current directory" || return 1

  # A script alone downloads from main, or from the branch it was told.
  mkdir -p "$temp_dir/alone"
  KVS_INSTALL_SELF="$temp_dir/alone/kvs-install.sh"
  : >"$KVS_INSTALL_SELF"
  run_nginx_step
  status=$?
  assert_equal "0" "$status" "the step from a script alone must succeed: $(cat "$temp_dir/out")" || return 1
  same_files "from main" || return 1
  for file in "${files[@]}" conf.d/domain.conf conf.d/sslgen.conf; do
    assert_file_contains "$temp_dir/urls" \
      "https://raw.githubusercontent.com/MaximeMichaud/KVS-install/main/conf/nginx/$file" \
      "$file was not downloaded from main" || return 1
  done
  KVS_INSTALL_BRANCH=fix/example
  run_nginx_step
  status=$?
  assert_equal "0" "$status" "the step from a branch must succeed: $(cat "$temp_dir/out")" || return 1
  assert_file_contains "$temp_dir/urls" \
    "https://raw.githubusercontent.com/MaximeMichaud/KVS-install/fix/example/conf/nginx/globals/security.conf" \
    "the files must come from the branch KVS_INSTALL_BRANCH names" || return 1
  ! grep -q '/main/conf/nginx' "$temp_dir/urls" ||
    fail "a branch run still downloaded from main" || return 1

  # A re-run over a live site: one file that does not come, or DH
  # parameters that fail, stop the step before anything of the site is
  # touched. The failure names the file, the configuration nginx runs on
  # stays as it was, nothing of the attempt is left, and nginx is neither
  # checked nor restarted.
  for case in download dhparam; do
    rm -rf "$nginx_dir" "$temp_dir/calls" "$temp_dir/urls"
    mkdir -p "$nginx_dir/globals" "$nginx_dir/conf.d"
    for file in nginx.conf dhparam.pem globals/security.conf conf.d/example.test.conf; do
      printf 'live %s\n' "$file" >"$nginx_dir/$file"
    done
    (cd "$nginx_dir" && find . -type f -exec sha256sum {} + | sort) >"$temp_dir/live"
    if [[ "$case" == download ]]; then
      CURL_FAIL=globals/security.conf aptinstall_nginx >"$temp_dir/out" 2>&1
    else
      OPENSSL_RC=1 aptinstall_nginx >"$temp_dir/out" 2>&1
    fi
    status=$?
    [[ "$status" -ne 0 ]] || fail "a failed $case passed the step" || return 1
    if [[ "$case" == download ]]; then
      assert_file_contains "$temp_dir/out" "globals/security.conf" "the failure must name the file" || return 1
    fi
    assert_equal "$(cat "$temp_dir/live")" "$(cd "$nginx_dir" && find . -type f -exec sha256sum {} + | sort)" \
      "a failed $case must leave the live configuration as it was" || return 1
    assert_equal "" "$(find "$nginx_dir" -mindepth 1 -name '.kvs-install.*' -o -name '*.tmp')" \
      "a failed $case left a partial file or the staging directory" || return 1
    [[ ! -e "$temp_dir/calls" ]] || fail "nginx was touched after a failed $case: $(cat "$temp_dir/calls")" || return 1
  done

  # A step that succeeds over a live site replaces conf.d and leaves no
  # staging directory behind.
  run_nginx_step
  printf 'live\n' >"$nginx_dir/conf.d/example.test.conf"
  KVS_INSTALL_BRANCH=fix/example aptinstall_nginx >"$temp_dir/out" 2>&1 ||
    fail "a re-run over a live site failed: $(cat "$temp_dir/out")" || return 1
  [[ ! -e "$nginx_dir/conf.d/example.test.conf" ]] || fail "the re-run kept the enabled vhost" || return 1
  same_files "a re-run" || return 1
  assert_equal "" "$(find "$nginx_dir" -mindepth 1 -name '.kvs-install.*')" "the staging directory stayed" || return 1

  # The check of nginx gates the restart too.
  NGINX_RC=1
  run_nginx_step
  status=$?
  [[ "$status" -ne 0 ]] || fail "a configuration nginx rejects passed the step" || return 1
  assert_equal "nginx -t -q" "$(cat "$temp_dir/calls")" \
    "nginx must not be restarted on a configuration it rejects" || return 1

  # Enabling the site: a vhost nginx rejects goes back to .disabled with the
  # challenge server, and nginx keeps running; one it accepts replaces it.
  rm -f "$temp_dir/calls"
  enable_site_vhost >"$temp_dir/out" 2>&1
  status=$?
  [[ "$status" -ne 0 ]] || fail "a site vhost nginx rejects was enabled" || return 1
  [[ -f "$nginx_dir/conf.d/example.test.conf.disabled" && ! -e "$nginx_dir/conf.d/example.test.conf" ]] ||
    fail "a rejected site vhost was not put back to .disabled" || return 1
  [[ -f "$nginx_dir/conf.d/sslgen.conf" ]] || fail "the challenge server did not come back" || return 1
  assert_equal "nginx -t -q" "$(cat "$temp_dir/calls")" \
    "nginx must not be restarted on a vhost it rejects" || return 1
  NGINX_RC=0
  rm -f "$temp_dir/calls"
  enable_site_vhost >"$temp_dir/out" 2>&1 || fail "an accepted site vhost failed: $(cat "$temp_dir/out")" || return 1
  [[ -f "$nginx_dir/conf.d/example.test.conf" && ! -e "$nginx_dir/conf.d/example.test.conf.disabled" ]] ||
    fail "the site vhost was not enabled" || return 1
  [[ ! -e "$nginx_dir/conf.d/sslgen.conf" && ! -e "$nginx_dir/conf.d/sslgen.conf.off" ]] ||
    fail "the challenge server stayed" || return 1
  assert_equal $'nginx -t -q\nservice nginx restart' "$(cat "$temp_dir/calls")" \
    "the enabled site needs a check, then a restart" || return 1
  # Both ways install_acme.sh turns the site on go through that check.
  assert_equal "2" "$(declare -f install_acme.sh | grep -c enable_site_vhost)" \
    "install_acme.sh must enable the site through enable_site_vhost" || return 1
  ! declare -f install_acme.sh | grep -q 'conf.disabled' ||
    fail "install_acme.sh still moves the vhost itself" || return 1
  # The README says which nginx files KVS_INSTALL_BRANCH chooses.
  grep -q '^| .KVS_INSTALL_BRANCH. .*nginx files' <<<"$(tr -d '\r' <"$REPO_DIR/README.md")" ||
    fail "the README must say that KVS_INSTALL_BRANCH chooses the standalone nginx files" || return 1

  unset -f check_ports gpg lsb_release apt-get reset_nginx_configuration_dirs openssl nginx service curl \
    run_nginx_step same_files
  unset APT_SOURCES_DIR KVS_NGINX_DIR NGINX_MIME_TYPES KVS_INSTALL_SELF KVS_INSTALL_BRANCH NGINX_RC
}

# The update of the menu downloaded the script into the current directory,
# whatever copy was running, and ran what was there even when curl brought
# nothing: it must replace the running copy in place, and only with a
# complete script.
test_the_self_update_replaces_the_running_copy_or_nothing() {
  local temp_dir script output status
  temp_dir=$(mktemp -d)
  trap 'rm -rf "$temp_dir"' RETURN
  mkdir -p "$temp_dir/home" "$temp_dir/bin"
  script="$temp_dir/bin/kvs-install.sh"
  printf '#!/bin/bash\necho old\n' >"$script"
  chmod +x "$script"
  # curl writes the file named by -o, or fails, as the test asks.
  curl() {
    local output=""
    while [[ $# -gt 0 ]]; do
      [[ "$1" == -o ]] && output="$2"
      shift
    done
    case ${CURL_CASE:-} in
      fails) return 6 ;;
      truncated) printf '#!/bin/bash\nif [ 1\n' >"$output" ;;
      *) printf '#!/bin/bash\necho new\n' >"$output" ;;
    esac
  }

  # The download fails: nothing changes, nothing lands where the command was typed.
  status=0
  output=$(cd "$temp_dir/home" && CURL_CASE=fails KVS_INSTALL_SELF="$script" update 2>&1) || status=$?
  [[ $status -eq 1 ]] || fail "a failed download must return 1, got $status: $output" || return 1
  [[ "$output" == *"could not be downloaded"* ]] || fail "the failed download must be explained: $output" || return 1
  [[ "$output" != *"Update Done."* ]] || fail "no success may be announced for a failed download" || return 1
  assert_equal old "$(bash "$script")" "the running copy must be left as it is" || return 1
  [[ -z "$(ls -A "$temp_dir/home")" ]] || fail "nothing may be written where the command was typed: $(ls -A "$temp_dir/home")" || return 1
  [[ "$(ls "$temp_dir/bin")" == kvs-install.sh ]] || fail "no temporary file may be left next to the copy: $(ls "$temp_dir/bin")" || return 1

  # A truncated download is refused the same way.
  status=0
  output=$(cd "$temp_dir/home" && CURL_CASE=truncated KVS_INSTALL_SELF="$script" update 2>&1) || status=$?
  [[ $status -eq 1 && "$output" == *"not a complete script"* ]] || fail "a truncated script must be refused: $output" || return 1
  assert_equal old "$(bash "$script")" "a truncated download must not replace the copy" || return 1

  # A complete download replaces the copy in place and runs it.
  status=0
  output=$(cd "$temp_dir/home" && KVS_INSTALL_SELF="$script" update 2>&1) || status=$?
  [[ $status -eq 0 ]] || fail "the update must run the new copy, got $status: $output" || return 1
  [[ "$output" == *"Update Done."*new* ]] || fail "the new copy must run after the replacement: $output" || return 1
  assert_equal new "$(bash "$script")" "the running copy must be the new script" || return 1
  [[ -z "$(ls -A "$temp_dir/home")" ]] || fail "the download must land next to the copy, not in the current directory" || return 1
  unset -f curl
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

test_ioncube_loader_is_added_once_and_a_failure_stops_the_step() {
  local temp_dir fpm cli status err
  temp_dir=$(mktemp -d)
  trap 'rm -rf "$temp_dir"' RETURN

  IONCUBE=YES
  PHP=8.1
  php_path="$temp_dir/ext"
  IONCUBE_WORK_DIR="$temp_dir/work"
  KVS_PHP_INI_DIR="$temp_dir/etc-php"
  fpm="$KVS_PHP_INI_DIR/$PHP/fpm/php.ini"
  cli="$KVS_PHP_INI_DIR/$PHP/cli/php.ini"
  mkdir -p "$php_path" "$IONCUBE_WORK_DIR" "$(dirname "$fpm")" "$(dirname "$cli")"
  : >"$fpm"
  : >"$cli"

  # Stand in for the network and the service: curl writes the tarball to its
  # -o path and logs the URL, tar lays the loader down under the -C
  # directory, systemctl is a no-op, dpkg reports TEST_ARCH. Each honours a
  # *_RC or *_SKIP override so a failure can be forced.
  TEST_CURL_LOG="$temp_dir/curl.log"
  curl() {
    local a prev="" out=""
    for a in "$@"; do
      [ "$prev" = "-o" ] && out="$a"
      prev="$a"
    done
    printf '%s\n' "$*" >>"$TEST_CURL_LOG"
    { [ "${CURL_RC:-0}" -eq 0 ] && [ -n "$out" ]; } && printf 'tarball\n' >"$out"
    return "${CURL_RC:-0}"
  }
  tar() {
    local a prev="" cdir=""
    for a in "$@"; do
      [ "$prev" = "-C" ] && cdir="$a"
      prev="$a"
    done
    if [ "${TAR_RC:-0}" -eq 0 ] && [ "${TAR_SKIP_LOADER:-0}" -eq 0 ]; then
      mkdir -p "$cdir/ioncube"
      printf 'loader\n' >"$cdir/ioncube/ioncube_loader_lin_$PHP.so"
    fi
    return "${TAR_RC:-0}"
  }
  systemctl() { return "${SYSTEMCTL_RC:-0}"; }
  dpkg() { [ "$1" = --print-architecture ] && echo "${TEST_ARCH:-amd64}"; }

  install_ioncube >/dev/null 2>&1 || fail "the ionCube step must succeed" || return 1
  grep -Fq 'ioncube_loaders_lin_x86-64.tar.gz' "$TEST_CURL_LOG" ||
    fail "an amd64 server must download the x86-64 loaders" || return 1
  [ -f "$php_path/ioncube_loader_lin_$PHP.so" ] ||
    fail "the loader must be copied into the extension directory" || return 1
  assert_equal "1" "$(grep -c 'zend_extension=.*ioncube' "$fpm")" \
    "the FPM php.ini must gain exactly one loader line" || return 1
  assert_equal "1" "$(grep -c 'zend_extension=.*ioncube' "$cli")" \
    "the CLI php.ini must gain exactly one loader line" || return 1
  { [ ! -e "$IONCUBE_WORK_DIR/ioncube" ] && [ ! -e "$IONCUBE_WORK_DIR/ioncube_loaders_lin_x86-64.tar.gz" ]; } ||
    fail "the download and the extracted directory must be cleaned up" || return 1

  # A second run must not add the line again.
  install_ioncube >/dev/null 2>&1 || fail "a re-run of the ionCube step must succeed" || return 1
  assert_equal "1" "$(grep -c 'zend_extension=.*ioncube' "$fpm")" \
    "a re-run must not load ionCube twice in the FPM php.ini" || return 1
  assert_equal "1" "$(grep -c 'zend_extension=.*ioncube' "$cli")" \
    "a re-run must not load ionCube twice in the CLI php.ini" || return 1

  # A failed download must stop the step and append nothing.
  : >"$fpm"
  : >"$cli"
  CURL_RC=22 install_ioncube >/dev/null 2>&1
  status=$?
  [ "$status" -ne 0 ] || fail "a failed download must fail the step" || return 1
  assert_equal "0" "$(grep -c 'zend_extension=.*ioncube' "$fpm")" \
    "a failed download must not touch the FPM php.ini" || return 1

  # A tarball that does not hold the loader must also stop the step and
  # append nothing.
  TAR_SKIP_LOADER=1 install_ioncube >/dev/null 2>&1
  status=$?
  [ "$status" -ne 0 ] || fail "a missing loader must fail the step" || return 1
  { [ ! -s "$fpm" ] && [ ! -s "$cli" ]; } ||
    fail "a tarball without the loader must not touch php.ini" || return 1

  # A loader already enabled with spaces around the =, or in the SAPI's
  # conf.d (the phpenmod layout), counts as present: nothing is appended.
  printf 'zend_extension = /opt/ioncube/ioncube_loader_lin_8.1.so\n' >"$fpm"
  : >"$cli"
  mkdir -p "$(dirname "$cli")/conf.d"
  printf '; ionCube\nzend_extension=ioncube_loader_lin_8.1.so\n' >"$(dirname "$cli")/conf.d/00-ioncube.ini"
  install_ioncube >/dev/null 2>&1 || fail "the ionCube step must succeed over an enabled loader" || return 1
  assert_equal "1" "$(grep -cE 'zend_extension[[:space:]]*=.*ioncube' "$fpm")" \
    "a loader line written with spaces must not be added again" || return 1
  [ ! -s "$cli" ] || fail "a loader enabled in conf.d must not be added to php.ini" || return 1
  rm -rf "$(dirname "$cli")/conf.d"

  # An aarch64 server gets the aarch64 loaders; an architecture ionCube does
  # not ship fails before anything is downloaded or appended.
  : >"$fpm"
  : >"$cli"
  : >"$TEST_CURL_LOG"
  TEST_ARCH=arm64 install_ioncube >/dev/null 2>&1 || fail "the ionCube step must succeed on arm64" || return 1
  grep -Fq 'ioncube_loaders_lin_aarch64.tar.gz' "$TEST_CURL_LOG" ||
    fail "an arm64 server must download the aarch64 loaders" || return 1
  : >"$fpm"
  : >"$cli"
  : >"$TEST_CURL_LOG"
  TEST_ARCH=riscv64 install_ioncube >/dev/null 2>&1
  status=$?
  [ "$status" -ne 0 ] || fail "an architecture without ionCube loaders must fail the step" || return 1
  [ ! -s "$TEST_CURL_LOG" ] || fail "nothing must be downloaded for an unsupported architecture" || return 1
  { [ ! -s "$fpm" ] && [ ! -s "$cli" ]; } ||
    fail "an unsupported architecture must not touch php.ini" || return 1

  # A missing php.ini is reported, and the other SAPI is still configured.
  rm -f "$cli"
  err=$(install_ioncube 2>&1 >/dev/null) || fail "a missing CLI php.ini must not fail the step" || return 1
  grep -Fq "$cli not found" <<<"$err" || fail "a missing php.ini must be reported" || return 1
  assert_equal "1" "$(grep -c 'zend_extension=.*ioncube' "$fpm")" \
    "the FPM php.ini must still be configured when the CLI one is missing" || return 1

  unset -f curl tar systemctl dpkg
  unset IONCUBE PHP php_path IONCUBE_WORK_DIR KVS_PHP_INI_DIR CURL_RC TAR_RC TAR_SKIP_LOADER SYSTEMCTL_RC TEST_ARCH TEST_CURL_LOG
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

test_setup_db_file_is_restricted_to_the_php_user() {
  local temp_dir file body
  temp_dir=$(mktemp -d)
  trap 'rm -rf "$temp_dir"' RETURN
  file="$temp_dir/setup_db.php"

  printf "define('DB_PASS','secret');\n" >"$file"
  chmod 644 "$file"
  restrict_setup_db_file "$file" || fail "restricting setup_db.php failed" || return 1
  assert_equal 600 "$(stat -c %a "$file")" "setup_db.php must be mode 600" || return 1

  # A missing file is not an error: nothing to restrict.
  restrict_setup_db_file "$temp_dir/missing.php" || fail "a missing setup_db.php must not fail" || return 1

  # install_KVS must restrict the file, and after it has configured it.
  body=$(declare -f install_KVS)
  case "$body" in
    *configure_kvs_database_file*restrict_setup_db_file*) ;;
    *) fail "install_KVS must call restrict_setup_db_file after configure_kvs_database_file" || return 1 ;;
  esac
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
  CERTIFICATE_MODE=""
  MOCK_STALE=0
  MOCK_MISMATCH=0
  mariadb() {
    case "$*" in
      *"NOT LIKE"*) printf '%s\n' "$MOCK_STALE" ;;
      *COALESCE*) printf '%s\n' "$MOCK_MISMATCH" ;;
      *"COUNT(*)"*) printf '2\n' ;;
      *) cat >>"$temp_dir/sql" ;;
    esac
  }

  # Paths and URLs come before the certificate step, with the TLS check off
  # whatever certificate was asked for.
  configure_kvs_servers >/dev/null 2>&1 || fail "server configuration failed" || return 1
  assert_file_contains "$temp_dir/sql" "'https://example.com/contents/'" "server URLs must follow the site URL" || return 1
  assert_file_contains "$temp_dir/sql" "'^https?://(www[.])?example[.]com(:[0-9]+)?/contents/'" "seeded www and plain http URLs must be matched" || return 1
  assert_file_contains "$temp_dir/sql" "REPLACE(path, '%PROJECT_PATH%', '/var/www/example.com')" "server paths must follow the site" || return 1
  assert_file_contains "$temp_dir/sql" "streaming_skip_ssl_check = 1" "the TLS check must stay off before the certificate step" || return 1

  URL=www.example.com
  : >"$temp_dir/sql"
  configure_kvs_servers >/dev/null 2>&1 || fail "www server configuration failed" || return 1
  assert_file_contains "$temp_dir/sql" "'https://www.example.com/contents/'" "the www choice must reach the server URLs" || return 1

  # After the certificate step the check follows what the site serves: on
  # for the certificate the CA issued, off for a self-signed one, asked for
  # or fallen back to from Let's Encrypt.
  for mode in public:0 selfsigned:1; do
    CERTIFICATE_MODE=${mode%%:*}
    : >"$temp_dir/sql"
    configure_kvs_servers_tls >/dev/null 2>&1 || fail "the TLS check failed for $CERTIFICATE_MODE" || return 1
    assert_file_contains "$temp_dir/sql" "streaming_skip_ssl_check = ${mode##*:}" \
      "a $CERTIFICATE_MODE certificate must give streaming_skip_ssl_check=${mode##*:}" || return 1
  done
  MOCK_MISMATCH=1
  configure_kvs_servers_tls >/dev/null 2>&1 && { fail "a TLS check the servers did not take passed"; return 1; }
  MOCK_MISMATCH=0
  CERTIFICATE_MODE=""
  configure_kvs_servers_tls >/dev/null 2>&1 && { fail "the TLS check was set before the certificate step"; return 1; }

  MOCK_STALE=1
  configure_kvs_servers >/dev/null 2>&1
  status=$?
  assert_equal "1" "$status" "a stale server URL must fail the step" || return 1

  unset -f mariadb
  unset MOCK_STALE MOCK_MISMATCH DOMAIN URL KVS_PATH SSL_PROVIDER CERTIFICATE_MODE
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

# The new clone takes the .env and the archive before it replaces the
# installation, and the backup stays until it has: a restore that fails (no
# docker directory in the clone) and one that succeeds both keep it. Once
# the new copy is in place the backup goes, and the restore is said only
# when there was something to restore, which a first installation lacks.
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
  [[ -f "$backup_dir/.env" && -f "$backup_dir/kvs-archive/KVS_7.0.2_[example.com].zip" ]] ||
    fail "the backup went before the new copy replaced the installation" || return 1

  drop_user_data_backup "$backup_dir" >"$temp_dir/out"
  [[ ! -e "$backup_dir" ]] || fail "the temporary backup was not removed once the new copy was in place" || return 1
  assert_file_contains "$temp_dir/out" "Restored .env and kvs-archive" "the restore was not said" || return 1
  mkdir "$backup_dir"
  drop_user_data_backup "$backup_dir" >"$temp_dir/out"
  [[ ! -e "$backup_dir" ]] || fail "an empty temporary backup was not removed" || return 1
  [[ ! -s "$temp_dir/out" ]] || fail "a first installation was told its .env and archive were restored: $(cat "$temp_dir/out")" || return 1
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

# whatisdomain no longer leaves the shell in /root, so the phpMyAdmin install
# must not depend on the current directory: started from a directory root
# cannot write to, the archive was saved there, the download and extraction
# failed unchecked and phpMyAdmin was silently missing.
test_phpmyadmin_install_downloads_outside_the_current_directory() {
  local temp_dir
  local start_dir
  local install_dir
  local fixture_dir
  local fixture_archive
  local output
  local status
  temp_dir=$(mktemp -d)
  trap 'chmod -R u+w "$temp_dir"; rm -rf "$temp_dir"' RETURN
  start_dir="$temp_dir/start"
  install_dir="$temp_dir/phpmyadmin"
  fixture_dir="$temp_dir/fixture/phpMyAdmin-test"
  fixture_archive="$temp_dir/phpmyadmin-fixture.tar.gz"
  mkdir -p "$start_dir" "$fixture_dir"
  printf 'new-version\n' >"$fixture_dir/index.php"
  cat >"$fixture_dir/config.sample.inc.php" <<'EOF'
<?php
$cfg['blowfish_secret'] = '';
EOF
  tar czf "$fixture_archive" -C "$temp_dir/fixture" phpMyAdmin-test
  export TEST_PMA_ARCHIVE="$fixture_archive" TEST_PMA_OUTPUT_LOG="$temp_dir/output.log"

  curl() {
    local previous=""
    local argument

    if [[ $* == *"downloads.test"* ]]; then
      printf '<a href="https://files.phpmyadmin.net/phpMyAdmin/test/phpMyAdmin-test-all-languages.tar.gz">download</a>\n'
      return 0
    fi
    for argument in "$@"; do
      if [[ $previous == "-o" ]]; then
        printf '%s\n' "$argument" >"$TEST_PMA_OUTPUT_LOG"
        cp "$TEST_PMA_ARCHIVE" "$argument"
        return
      fi
      previous="$argument"
    done
    return 64
  }
  chown() { :; }
  openssl() { printf 'fixed-test-secret\n'; }
  webserver=""

  chmod 555 "$start_dir"
  (cd "$start_dir" && aptinstall_phpmyadmin "$install_dir" "https://downloads.test/") >/dev/null 2>&1
  status=$?
  chmod 755 "$start_dir"

  assert_equal "0" "$status" "phpMyAdmin installation from a read-only directory failed" || return 1
  [[ -z "$(ls -A "$start_dir")" ]] || fail "the phpMyAdmin archive was written to the current directory" || return 1
  output=$(cat "$TEST_PMA_OUTPUT_LOG" 2>/dev/null)
  [[ $output == /* ]] || fail "the phpMyAdmin archive must be downloaded to an absolute path, got '$output'" || return 1
  [[ ! -e $output ]] || fail "the downloaded phpMyAdmin archive was left behind" || return 1
  assert_file_contains "$install_dir/index.php" "new-version" "phpMyAdmin was not installed" || return 1
  assert_file_contains "$install_dir/config.inc.php" "fixed-test-secret" "phpMyAdmin config was not generated" || return 1

  # A failed download fails the step instead of leaving phpMyAdmin missing.
  curl() {
    [[ $* == *"downloads.test"* ]] || return 22
    printf '<a href="https://files.phpmyadmin.net/phpMyAdmin/test/phpMyAdmin-test-all-languages.tar.gz">download</a>\n'
  }
  (cd "$start_dir" && aptinstall_phpmyadmin "$temp_dir/phpmyadmin-failed" "https://downloads.test/") >/dev/null 2>&1
  status=$?
  [[ $status -ne 0 ]] || fail "a failed phpMyAdmin download must fail the step" || return 1
  [[ -z "$(ls -A "$start_dir")" ]] || fail "a failed phpMyAdmin download left files in the current directory" || return 1
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

# The gum repository must never stay in the apt sources without its key:
# apt-get update then fails with "is not signed" for every later step.
test_gum_repository_leaves_with_its_key() {
  local temp_dir
  local keyring list
  temp_dir=$(mktemp -d)
  trap 'rm -rf "$temp_dir"' RETURN
  mkdir -p "$temp_dir/bin" "$temp_dir/keyrings" "$temp_dir/sources"
  ln -s "$(command -v mkdir)" "$temp_dir/bin/mkdir"
  ln -s "$(command -v rm)" "$temp_dir/bin/rm"
  ln -s "$(command -v cat)" "$temp_dir/bin/cat"
  # The function sees only the stubs below and the few tools it needs: gum
  # and gpg are found through functions or not at all.
  run_install_gum() {
    local PATH="$temp_dir/bin"
    install_gum
  }
  APT_KEYRINGS_DIR="$temp_dir/keyrings"
  APT_SOURCES_DIR="$temp_dir/sources"
  keyring="$temp_dir/keyrings/charm.gpg"
  list="$temp_dir/sources/charm.list"
  PROGRESS_GUM_AVAILABLE=false
  apt-get() {
    printf '%s\n' "$*" >>"$temp_dir/apt-calls"
    [[ "$1" == update && -e "$temp_dir/apt-update-fails" ]] && return 100
    return 0
  }
  apt_install() { printf 'install %s\n' "$*" >>"$temp_dir/apt-calls"; }

  # No gpg on the host: nothing is written, the run goes on.
  curl() { fail "curl must not run without gpg"; }
  run_install_gum >/dev/null || fail "install_gum must not fail the installer" || return 1
  [[ ! -e "$list" && ! -e "$keyring" ]] || fail "no list nor keyring must be written without gpg" || return 1
  [[ ! -e "$temp_dir/apt-calls" ]] || fail "apt must not run without gpg" || return 1

  # The key cannot be fetched: no list is written, so later apt runs are safe.
  curl() { return 7; }
  gpg() { return 2; }
  run_install_gum >/dev/null || fail "a failed key fetch must not fail the installer" || return 1
  [[ ! -e "$list" ]] || fail "the list must not be written when the key fetch fails" || return 1
  [[ ! -e "$keyring" ]] || fail "an empty keyring must not be left behind" || return 1
  [[ ! -e "$temp_dir/apt-calls" ]] || fail "apt must not run without the key" || return 1
  assert_equal false "$PROGRESS_GUM_AVAILABLE" "gum must not be reported available" || return 1

  # The key is there but the repository does not install gum: both leave.
  curl() { printf 'KEY\n'; }
  gpg() {
    local output
    while [[ $# -gt 0 ]]; do
      [[ "$1" == -o ]] && output="$2"
      shift
    done
    cat >"$output"
  }
  : >"$temp_dir/apt-update-fails"
  run_install_gum >/dev/null || fail "a failed apt update must not fail the installer" || return 1
  [[ ! -e "$list" ]] || fail "the list must leave when apt-get update fails" || return 1
  [[ ! -e "$keyring" ]] || fail "the keyring must leave with the list" || return 1
  assert_equal false "$PROGRESS_GUM_AVAILABLE" "gum must not be reported available after a failed update" || return 1

  # Everything works: the list names the keyring and gum is available.
  rm -f "$temp_dir/apt-update-fails" "$temp_dir/apt-calls"
  run_install_gum >/dev/null || fail "install_gum failed although everything works" || return 1
  [[ -s "$keyring" ]] || fail "the keyring must be written" || return 1
  assert_file_contains "$list" "deb [signed-by=$keyring] https://repo.charm.sh/apt/ * *" \
    "the list must name the keyring it was written with" || return 1
  assert_file_contains "$temp_dir/apt-calls" "install -qq gum" "gum must be installed" || return 1
  assert_equal true "$PROGRESS_GUM_AVAILABLE" "gum must be reported available" || return 1
}

# A failed database import must stop provision_kvs_database, keep _INSTALL/ so
# the import can be retried, and a re-run must import again instead of leaving a
# site with no tables because the database happens to exist. A database that
# holds tables without the INITIAL_VERSION row install_db.sql ends with was cut
# part way: it must stop the install, not pass for a finished one. A re-run over
# an installed site, whose _INSTALL/ the first run removed, must succeed.
test_failed_db_import_keeps_install_files_and_retries() {
  local temp_dir domain path state status
  temp_dir=$(mktemp -d)
  trap 'rm -rf "$temp_dir"' RETURN

  domain="imp.example.com"
  path="$temp_dir/www"
  mkdir -p "$path/admin/include"
  printf "<?php\n\$config['tables_prefix']=\"kt2_\";\n" >"$path/admin/include/setup.php"
  red=""; normal=""; green=""; yellow=""

  state="$temp_dir/state"
  mkdir -p "$state"
  # A programmable mariadb: the import connects as the site user (-u ...), every
  # other call carries -e. State files decide what the database looks like:
  # table_count, count_fail, marker (the INITIAL_VERSION row of kt2_options),
  # import_fail and import_cut (the import stops before the marker).
  mariadb() {
    local args="$*"
    if [[ "$args" == "-u "* ]]; then
      : >"$state/import_attempted"
      [ -f "$state/import_fail" ] && return 1
      if [ -f "$state/import_cut" ]; then
        echo 3 >"$state/table_count"
        return 0
      fi
      echo 5 >"$state/table_count"
      echo 7.0.2 >"$state/marker"
      return 0
    fi
    case "$args" in
      *information_schema.tables*)
        [ -f "$state/count_fail" ] && return 1
        cat "$state/table_count" 2>/dev/null || echo 0
        return 0 ;;
      *"INITIAL_VERSION"*)
        [[ "$args" == *"\`kt2_options\`"* ]] || return 1
        cat "$state/marker" 2>/dev/null
        return 0 ;;
      *"USE "*)
        [ -f "$state/db_exists" ] && return 0 || return 1 ;;
      *"SELECT User FROM mysql.user"*)
        [ -f "$state/user_exists" ] && echo "$domain"
        return 0 ;;
      *"CREATE DATABASE"*)
        : >"$state/db_exists"; return 0 ;;
    esac
    return 0
  }
  reset_install() {
    mkdir -p "$path/_INSTALL"
    printf 'CREATE TABLE x(id INT);\n' >"$path/_INSTALL/install_db.sql"
    rm -f "$state/import_attempted" "$state/import_fail" "$state/import_cut" "$state/count_fail"
  }

  # Run 1: a fresh database whose import fails.
  reset_install
  echo 0 >"$state/table_count"
  : >"$state/import_fail"
  status=0
  provision_kvs_database "$path" "$domain" fixedpass || status=$?
  [[ $status -ne 0 ]] || fail "a failed import must make provision_kvs_database fail" || return 1
  [[ -f "$path/_INSTALL/install_db.sql" ]] ||
    fail "_INSTALL/ must be kept after a failed import" || return 1
  [[ -f "$state/import_attempted" ]] || fail "the import must have been attempted" || return 1

  # Run 2: the database now exists but is still empty; the import succeeds.
  rm -f "$state/import_fail" "$state/import_attempted"
  status=0
  provision_kvs_database "$path" "$domain" fixedpass || status=$?
  [[ $status -eq 0 ]] || fail "a re-run must succeed once the import works (status $status)" || return 1
  [[ -f "$state/import_attempted" ]] ||
    fail "an existing but empty database must be imported on re-run" || return 1
  [[ ! -d "$path/_INSTALL" ]] ||
    fail "_INSTALL/ must be removed after a successful import" || return 1

  # Run 3: an installed site re-run: complete database, _INSTALL/ already gone.
  rm -f "$state/import_attempted"
  status=0
  provision_kvs_database "$path" "$domain" fixedpass || status=$?
  [[ $status -eq 0 ]] ||
    fail "a re-run over an installed site without _INSTALL/ must succeed (status $status)" || return 1
  [[ ! -f "$state/import_attempted" ]] ||
    fail "a complete database must not be imported again" || return 1

  # Run 4: complete database, _INSTALL/ back (archive extracted again): no
  # import, _INSTALL/ removed.
  reset_install
  status=0
  provision_kvs_database "$path" "$domain" fixedpass || status=$?
  [[ $status -eq 0 ]] || fail "a complete database must not fail (status $status)" || return 1
  [[ ! -f "$state/import_attempted" ]] ||
    fail "a complete database must not be imported again" || return 1
  [[ ! -d "$path/_INSTALL" ]] || fail "_INSTALL/ must be removed over a complete database" || return 1

  # Run 5: an import cut part way left 3 tables and no INITIAL_VERSION row.
  reset_install
  echo 3 >"$state/table_count"
  rm -f "$state/marker"
  status=0
  provision_kvs_database "$path" "$domain" fixedpass >/dev/null 2>&1 || status=$?
  [[ $status -ne 0 ]] || fail "tables without INITIAL_VERSION must stop the install" || return 1
  [[ ! -f "$state/import_attempted" ]] ||
    fail "a partly imported database must not be imported over" || return 1
  [[ -f "$path/_INSTALL/install_db.sql" ]] ||
    fail "_INSTALL/ must be kept over a partly imported database" || return 1

  # Run 6: the table count cannot be read: an error, not an empty database.
  reset_install
  echo 0 >"$state/table_count"
  : >"$state/count_fail"
  status=0
  provision_kvs_database "$path" "$domain" fixedpass >/dev/null 2>&1 || status=$?
  [[ $status -ne 0 ]] || fail "an unreadable table count must stop the install" || return 1
  [[ ! -f "$state/import_attempted" ]] || fail "an unreadable table count must not import" || return 1
  [[ -d "$path/_INSTALL" ]] || fail "_INSTALL/ must be kept when the table count fails" || return 1

  # Run 7: an empty database and no install_db.sql to import.
  reset_install
  rm -f "$path/_INSTALL/install_db.sql"
  status=0
  provision_kvs_database "$path" "$domain" fixedpass >/dev/null 2>&1 || status=$?
  [[ $status -ne 0 ]] || fail "an empty database without install_db.sql must fail" || return 1

  # Run 8: the import returns success but stopped before the INITIAL_VERSION row.
  reset_install
  : >"$state/import_cut"
  status=0
  provision_kvs_database "$path" "$domain" fixedpass >/dev/null 2>&1 || status=$?
  [[ $status -ne 0 ]] || fail "an import without INITIAL_VERSION afterwards must fail" || return 1
  [[ -f "$path/_INSTALL/install_db.sql" ]] ||
    fail "_INSTALL/ must be kept when the import did not complete" || return 1
}

# A re-run of install_KVS over an installed site (the first run removed
# _INSTALL/, setup_db.php holds the password at 0600) must succeed and keep
# setup_db.php at 0600; a failed database step must not leave it at the 0755 of
# the blanket chmod either.
test_install_rerun_keeps_setup_db_restricted() {
  local temp_dir site status
  temp_dir=$(mktemp -d)
  trap 'rm -rf "$temp_dir"' RETURN
  red=""; normal=""; green=""; yellow=""
  # Never run install_KVS against the real /var/www.
  [[ "$(declare -f install_KVS)" == *KVS_WWW_ROOT* ]] ||
    fail "install_KVS must take its web root from KVS_WWW_ROOT" || return 1
  DOMAIN=site.example.com URL=site.example.com PHP=8.3 KVS_WWW_ROOT="$temp_dir/www"
  site="$temp_dir/www/$DOMAIN"
  mkdir -p "$site/admin/include"
  printf "<?php\n\$config['project_url']=\"https://site.example.com\";\n" >"$site/admin/include/setup.php"
  printf "<?php\ndefine('DB_LOGIN','site.example.com');\ndefine('DB_PASS','RealPass123');\ndefine('DB_DEVICE','site.example.com');\n" \
    >"$site/admin/include/setup_db.php"
  chmod 600 "$site/admin/include/setup_db.php"
  chown() { :; }
  mariadb() {
    [ -f "$temp_dir/db_down" ] && return 1
    case "$*" in
      *information_schema.tables*) echo 180 ;;
      *INITIAL_VERSION*) echo 7.0.2 ;;
      *"SELECT User FROM mysql.user"*) printf 'User\nsite.example.com\n' ;;
    esac
    return 0
  }

  status=0
  install_KVS >/dev/null 2>&1 || status=$?
  assert_equal 0 "$status" "a re-run over an installed site must succeed" || return 1
  assert_equal 600 "$(stat -c %a "$site/admin/include/setup_db.php")" \
    "setup_db.php must stay 0600 after a re-run" || return 1

  : >"$temp_dir/db_down"
  status=0
  install_KVS >/dev/null 2>&1 || status=$?
  [[ $status -ne 0 ]] || fail "an unreachable database must fail the step" || return 1
  assert_equal 600 "$(stat -c %a "$site/admin/include/setup_db.php")" \
    "setup_db.php must stay 0600 when the database step fails" || return 1
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

# Ubuntu ships /etc/debian_version too: the OS check read its VERSION_ID
# through the Debian release gate and stopped on "Debian 24.04 is not
# supported". The distribution id of os-release decides, and every
# distribution but Debian takes the Docker installation.
test_os_check_sends_ubuntu_to_the_docker_installation() {
  local temp_dir
  local output
  local status
  temp_dir=$(mktemp -d)
  trap 'rm -rf "$temp_dir"' RETURN

  printf 'ID=ubuntu\nID_LIKE=debian\nVERSION_ID="24.04"\n' >"$temp_dir/os-release"
  output=$(
    OS_RELEASE_FILE="$temp_dir/os-release" checkOS >"$temp_dir/out" 2>&1 || exit $?
    printf '%s %s\n' "$IS_DEBIAN" "$OS"
  )
  status=$?
  [[ $status -eq 0 ]] || fail "the OS check refused Ubuntu 24.04 (status $status): $(cat "$temp_dir/out")" || return 1
  assert_equal "false ubuntu" "$output" "Ubuntu must take the Docker installation as a non-Debian system" || return 1
  grep -q 'Detected: ubuntu' "$temp_dir/out" || fail "the detected distribution was not shown" || return 1
  ! grep -q 'Debian 24.04' "$temp_dir/out" || fail "Ubuntu was reported as a Debian release" || return 1

  printf 'ID=debian\nVERSION_ID="13"\n' >"$temp_dir/os-release"
  output=$(
    OS_RELEASE_FILE="$temp_dir/os-release" checkOS >"$temp_dir/out" 2>&1 || exit $?
    printf '%s %s\n' "$IS_DEBIAN" "$OS"
  )
  status=$?
  [[ $status -eq 0 ]] || fail "the OS check refused Debian 13 (status $status)" || return 1
  assert_equal "true debian" "$output" "Debian 13 must keep both installations" || return 1

  printf 'ID=debian\nVERSION_ID="11"\n' >"$temp_dir/os-release"
  (OS_RELEASE_FILE="$temp_dir/os-release" checkOS) >"$temp_dir/out" 2>&1
  status=$?
  [[ $status -eq 1 ]] || fail "Debian 11 must stop the installer (status $status)" || return 1
  grep -q 'Debian 11 is not supported' "$temp_dir/out" || fail "the unsupported Debian release was not named" || return 1

  output=$(
    OS_RELEASE_FILE="$temp_dir/missing" checkOS >"$temp_dir/out" 2>&1 || exit $?
    printf '%s %s\n' "$IS_DEBIAN" "$OS"
  )
  status=$?
  [[ $status -eq 0 ]] || fail "a host without os-release must still get the Docker installation (status $status)" || return 1
  assert_equal "false unknown" "$output" "a host without os-release is unknown and takes the Docker installation" || return 1
}

# A question asked again until the answer is valid never ends when the
# input is over (answers piped in that ran out, a detached run): the
# installer stops and says so instead.
test_a_question_with_no_answer_left_stops_the_installer() {
  local output
  local status

  # shellcheck disable=SC2016  # The inner shell expands $1.
  output=$(timeout 20 bash -c 'source "$1"; IS_DEBIAN=true; INSTALL_TYPE=""; HEADLESS=""; chooseInstallationType' _ "$INSTALLER" </dev/null 2>&1)
  status=$?
  [[ $status -eq 1 ]] || fail "the installer must stop at the end of its input (status $status): $(tail -n 3 <<< "$output")" || return 1
  grep -q 'no answer left on standard input' <<< "$output" || fail "the end of the input was not reported" || return 1
  [[ $(grep -c 'Choose installation type:' <<< "$output") -eq 1 ]] || fail "the question must be asked once, not again and again" || return 1
}

# sh kvs-install.sh runs dash on Debian and Ubuntu, which stopped on a
# syntax error further down the file: the installer says it needs bash.
test_the_installer_says_it_needs_bash() {
  local output
  local status

  if ! command -v dash >/dev/null 2>&1; then
    echo "  (dash is not installed here, the case is left to the CI runner)"
    return 0
  fi
  output=$(dash "$INSTALLER" 2>&1 </dev/null)
  status=$?
  [[ $status -eq 1 ]] || fail "dash must be refused with status 1 (status $status): $(head -n 2 <<< "$output")" || return 1
  grep -q 'needs bash' <<< "$output" || fail "the installer must say it needs bash: $output" || return 1
  ! grep -q 'Syntax error' <<< "$output" || fail "dash must not reach a syntax error" || return 1
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

test_the_wrapper_installs_the_requested_branch() {
  local temp_dir
  local log
  temp_dir=$(mktemp -d)
  trap 'rm -rf "$temp_dir"' RETURN
  log="$temp_dir/git.log"
  git() {
    printf '%s\n' "$*" >>"$log"
    [[ ${1:-} == clone ]] && mkdir -p "${@: -1}"
    return 0
  }

  (
    KVS_INSTALL_BRANCH=import-without-archive clone_kvs_install "$temp_dir/install" >/dev/null 2>&1 || exit 1
    grep -q '^clone --branch import-without-archive https://github.com/MaximeMichaud/KVS-install.git ' "$log" || exit 2
    [[ -d "$temp_dir/install" ]] || exit 3
    : >"$log"
    unset KVS_INSTALL_BRANCH
    clone_kvs_install "$temp_dir/install" >/dev/null 2>&1 || exit 4
    grep -q '^clone --branch main ' "$log" || exit 5
    : >"$log"
    KVS_INSTALL_BRANCH=import-without-archive update_kvs_install >/dev/null 2>&1 || exit 6
    [[ "$(cat "$log")" == $'fetch origin import-without-archive\ncheckout import-without-archive\npull --ff-only origin import-without-archive' ]] || exit 7
    : >"$log"
    update_kvs_install >/dev/null 2>&1 || exit 8
    [[ "$(cat "$log")" == "pull" ]] || exit 9
    exit 0
  ) || fail "the wrapper must install and update the requested branch (case $?)"
}

# Menu option 2 ("Add another KVS website") runs the native install_KVS. On a
# Docker host that re-owns /var/www away from the container user, loosens the
# running site's setup_db.php and rewrites its setup.php paths, silently
# breaking the stack. It must refuse there and point at the multi-site tool,
# while a native host still reaches install_KVS.
test_menu_add_site_refuses_on_a_docker_host() {
  local temp_dir docker_dir native_dir out status
  temp_dir=$(mktemp -d)
  trap 'rm -rf "$temp_dir"' RETURN

  # Stand in for the destructive native install path.
  whatisdomain() { : >"$temp_dir/native-ran"; }
  install_KVS() { : >"$temp_dir/native-ran"; }

  # The containers' Compose labels, or none: never the real Docker daemon.
  export TEST_WORKING_DIRS=""
  docker() {
    [[ $1 == ps ]] || return 1
    [[ -z $TEST_WORKING_DIRS ]] || tr ' ' '\n' <<<"$TEST_WORKING_DIRS"
  }

  # A Docker host keeps its Compose project under the install directory.
  docker_dir="$temp_dir/docker-host"
  mkdir -p "$docker_dir/docker"
  : >"$docker_dir/docker/docker-compose.yml"

  out=$(KVS_INSTALL_DIR="$docker_dir" MENU_OPTION=2 manageMenu 2>&1)
  status=$?

  [[ $status -ne 0 ]] || fail "menu option 2 should refuse on a Docker host" || return 1
  [[ ! -e "$temp_dir/native-ran" ]] || fail "menu option 2 ran the native install on a Docker host" || return 1
  grep -Fq "$docker_dir/docker/multi-site/site-manager.sh" <<<"$out" ||
    fail "the refusal should point to the Docker multi-site tool" || return 1

  # Installed under a KVS_INSTALL_DIR this run does not repeat: the stack is
  # found from its containers' working_dir label, the primary's or a site's.
  native_dir="$temp_dir/native-host"
  mkdir -p "$native_dir" "$docker_dir/docker/multi-site/sites/b.example"
  : >"$docker_dir/docker/setup.sh"
  : >"$docker_dir/docker/multi-site/site-manager.sh"
  for TEST_WORKING_DIRS in "/srv/other-project $docker_dir/docker" "$docker_dir/docker/multi-site/sites/b.example"; do
    out=$(KVS_INSTALL_DIR="$native_dir" MENU_OPTION=2 manageMenu 2>&1)
    status=$?
    [[ $status -ne 0 ]] || fail "menu option 2 should refuse a Docker stack found from its containers" || return 1
    [[ ! -e "$temp_dir/native-ran" ]] || fail "menu option 2 ran the native install over a running Docker stack" || return 1
    grep -Fq "$docker_dir/docker/multi-site/site-manager.sh" <<<"$out" ||
      fail "the refusal should name the multi-site tool of the stack found" || return 1
  done

  # A native host has no Compose project: option 2 still reaches install_KVS,
  # unrelated Compose projects included.
  TEST_WORKING_DIRS="/srv/other-project"
  KVS_INSTALL_DIR="$native_dir" MENU_OPTION=2 manageMenu >/dev/null 2>&1
  [[ -e "$temp_dir/native-ran" ]] || fail "menu option 2 should still install natively off a Docker host" || return 1
  unset -f docker
  unset TEST_WORKING_DIRS
}

# A failed ACME issuance fell back to a self-signed certificate under the
# "SSL certificates configured" step, before which the storage servers had
# already been told to verify TLS: KVS's storage checks then failed, and
# nothing said the site was not on a real certificate. The fallback is now
# recorded and reported with commands that do install the certificate, and
# the storage TLS check follows it in a step of its own.
test_certificate_fallback_is_reported_and_followed() {
  local temp_dir out status order expected
  temp_dir=$(mktemp -d)
  trap 'rm -rf "$temp_dir"' RETURN
  DOMAIN=example.com
  SSL_PROVIDER=letsencrypt
  EMAIL=admin@example.com
  # acme.sh keeps state as the real one does: a certificate issued once makes
  # the next --issue exit 2 (still valid, skipped); ZeroSSL refuses to issue
  # before an account has an email. Each "<what>-fails-once" file makes that
  # command fail one time.
  {
    printf '#!/bin/bash\ns=%q\n' "$temp_dir"
    cat <<'STUB'
printf '%s\n' "$*" >>"$s/acme-calls"
once() { [[ -e "$s/$1-fails-once" ]] && rm -f "$s/$1-fails-once"; }
case "$1" in
  --register-account) [[ "$3" == *@* ]] || exit 1; : >"$s/registered" ;;
  --issue)
    [[ -e "$s/needs-account" && ! -e "$s/registered" ]] && exit 1
    once issue && exit 1
    [[ -e "$s/issued" ]] && exit 2
    : >"$s/issued" ;;
  --install-cert) once install && exit 1; : >"$s/installed" ;;
esac
exit 0
STUB
  } >"$temp_dir/acme.sh"
  chmod +x "$temp_dir/acme.sh"
  generate_selfsigned_cert() { : >"$temp_dir/selfsigned"; }
  reset_acme() { rm -f "$temp_dir"/{issued,installed,registered,needs-account,selfsigned,acme-calls,*-fails-once}; }

  reset_acme
  CERTIFICATE_MODE=""
  issue_site_certificate "$temp_dir/acme.sh" --issue -d example.com >/dev/null 2>&1 ||
    fail "a certificate issued and installed must succeed" || return 1
  assert_equal "public" "$CERTIFICATE_MODE" "an installed certificate is public" || return 1
  [[ ! -e "$temp_dir/selfsigned" ]] || fail "a self-signed certificate replaced the issued one" || return 1
  grep -q -- '--install-cert --ecc -d example.com' "$temp_dir/acme-calls" || fail "the certificate was not installed" || return 1

  # acme.sh exit 2: still valid, installed again, still public.
  rm -f "$temp_dir/installed"
  CERTIFICATE_MODE=""
  issue_site_certificate "$temp_dir/acme.sh" --issue -d example.com >/dev/null 2>&1 ||
    fail "a still valid certificate must succeed" || return 1
  assert_equal "public" "$CERTIFICATE_MODE" "a reused certificate is public" || return 1
  [[ -e "$temp_dir/installed" ]] || fail "a still valid certificate was not installed" || return 1

  # A refused issue, a failed install over an issued certificate, and ZeroSSL
  # without an email: each falls back, says so, and the commands it prints,
  # run one after the other as the warning says, install the certificate.
  for case in issue install zerossl; do
    reset_acme
    SSL_PROVIDER=letsencrypt
    EMAIL=admin@example.com
    case $case in
      issue) : >"$temp_dir/issue-fails-once" ;;
      install) : >"$temp_dir/install-fails-once" ;;
      zerossl) SSL_PROVIDER=zerossl EMAIL="" && : >"$temp_dir/needs-account" ;;
    esac
    CERTIFICATE_MODE=""
    issue_site_certificate "$temp_dir/acme.sh" --issue -d example.com >"$temp_dir/out" 2>&1
    status=$?
    out=$(cat "$temp_dir/out")
    assert_equal "0" "$status" "the self-signed fallback keeps the install going ($case)" || return 1
    assert_equal "selfsigned" "$CERTIFICATE_MODE" "a failed $case falls back to self-signed" || return 1
    [[ -e "$temp_dir/selfsigned" && ! -e "$temp_dir/installed" ]] ||
      fail "no self-signed certificate after a failed $case" || return 1
    grep -q "WARNING: no $SSL_PROVIDER certificate for example.com" <<<"$out" ||
      fail "a failed $case must be reported loudly: $out" || return 1
    grep -q "acme.sh's own cron may not do it before a renewal, if ever" <<<"$out" ||
      fail "the warning must say that acme.sh's cron may not install the certificate" || return 1
    if [[ "$case" == zerossl ]]; then
      grep -Fq -- "--register-account -m <your email>" <<<"$out" ||
        fail "ZeroSSL without an email must start with the account: $out" || return 1
    else
      ! grep -q -- "--register-account" <<<"$out" ||
        fail "the account command was printed for $case" || return 1
    fi
    # The indented lines, pasted into a shell as they are: each line runs
    # whatever the one before returned, a line ending in a continuation
    # joins the next.
    : >"$temp_dir/acme-calls"
    sed -n 's/^  //p' "$temp_dir/out" | sed 's/<your email>/admin@example.com/' | bash >/dev/null 2>&1
    [[ -e "$temp_dir/installed" ]] ||
      fail "the printed commands did not install the certificate after a failed $case: $(tr '\n' ' ' <"$temp_dir/acme-calls")" || return 1
  done
  # An email given to ZeroSSL went to acme.sh --install: no account command.
  reset_acme
  SSL_PROVIDER=zerossl
  EMAIL=admin@example.com
  : >"$temp_dir/issue-fails-once"
  issue_site_certificate "$temp_dir/acme.sh" --issue -d example.com >"$temp_dir/out" 2>&1
  ! grep -q -- "--register-account" "$temp_dir/out" ||
    fail "the account command was printed although ZeroSSL has an email" || return 1

  # SSL_PROVIDER=selfsigned skips acme.sh: install_acme.sh records the mode
  # itself, and the TLS step after it leaves the check off instead of
  # refusing to run. install_acme.sh creates /etc/nginx/ssl/<domain>; the
  # mkdir stub answers for that path and refuses any other.
  (
    KVS_NGINX_DIR="$temp_dir/nginx"
    command mkdir -p "$KVS_NGINX_DIR/conf.d"
    : >"$KVS_NGINX_DIR/conf.d/example.com.conf.disabled"
    : >"$KVS_NGINX_DIR/conf.d/sslgen.conf"
    mkdir() { [[ "$*" == "-p /etc/nginx/ssl/example.com" ]] || return 99; }
    nginx() { :; }
    service() { :; }
    mariadb() {
      case "$*" in
        *COALESCE*) printf '0\n' ;;
        *) cat >>"$temp_dir/tls-sql" ;;
      esac
    }
    SSL_PROVIDER=selfsigned
    CERTIFICATE_MODE=""
    install_acme.sh >"$temp_dir/out" 2>&1 || { fail "the self-signed certificate step failed: $(cat "$temp_dir/out")"; exit 1; }
    [[ "$CERTIFICATE_MODE" == selfsigned ]] || { fail "SSL_PROVIDER=selfsigned left the mode '$CERTIFICATE_MODE'"; exit 1; }
    configure_kvs_servers_tls >"$temp_dir/out" 2>&1 ||
      { fail "the TLS step failed after a self-signed certificate step: $(cat "$temp_dir/out")"; exit 1; }
    grep -q 'streaming_skip_ssl_check = 1' "$temp_dir/tls-sql" ||
      { fail "the TLS check must stay off for SSL_PROVIDER=selfsigned"; exit 1; }
  ) || return 1

  # The final summary repeats the fallback and the TLS note, only when the
  # site fell back from the provider that was asked for.
  (
    curl() { printf '192.0.2.1\n'; }
    for case in letsencrypt:selfsigned:yes zerossl:selfsigned:yes selfsigned:selfsigned:no letsencrypt:public:no; do
      IFS=: read -r SSL_PROVIDER CERTIFICATE_MODE expected <<<"$case"
      out=$(URL=example.com AUTOPACKAGEUPDATE=NO setupdone 2>&1)
      if [[ "$expected" == yes ]]; then
        grep -q "The $SSL_PROVIDER certificate could not be issued or installed" <<<"$out" &&
          grep -q "skip the TLS check until the real one is in place" <<<"$out" ||
          { fail "the summary must repeat the fallback and the TLS note ($case): $out"; exit 1; }
      else
        ! grep -q "could not be issued" <<<"$out" || { fail "the summary reported a fallback for $case"; exit 1; }
      fi
    done
  ) || return 1

  # The step order, with every step stubbed in a subshell that keeps the
  # stubs. The storage servers get their paths and URLs before the cron,
  # with the TLS check off; the check follows the certificate step. A failed
  # certificate step stops there: the cron already finds configured servers.
  order="$temp_dir/order"
  expected="aptupdate aptinstall whatisdomain check_dns_configuration install_yt-dlp aptinstall_php aptinstall_memcached aptinstall_nginx aptinstall_mariadb aptinstall_phpmyadmin install_KVS configure_kvs_system_settings configure_kvs_servers install_ioncube insert_cronjob install_acme.sh"
  for ACME_RC in 0 1; do
    rm -f "$order"
    (
      install_gum() { :; }
      installQuestions() { :; }
      progress_header() { :; }
      progress_step() { :; }
      progress_done() { :; }
      progress_success() { :; }
      setupdone() { :; }
      for step in aptupdate aptinstall whatisdomain check_dns_configuration install_yt-dlp \
        aptinstall_php aptinstall_memcached aptinstall_nginx aptinstall_mariadb aptinstall_phpmyadmin \
        install_KVS configure_kvs_system_settings configure_kvs_servers install_ioncube insert_cronjob \
        configure_kvs_servers_tls configure_dynamic_php_fpm autoUpdate; do
        eval "$step() { printf '%s\\n' $step >>\"\$order\"; }"
      done
      install_acme.sh() { printf 'install_acme.sh\n' >>"$order"; return "$ACME_RC"; }
      script >/dev/null 2>&1
    )
    status=$?
    if ((ACME_RC == 0)); then
      assert_equal "0" "$status" "the stubbed pipeline failed" || return 1
      assert_equal "$expected configure_kvs_servers_tls configure_dynamic_php_fpm autoUpdate" "$(tr '\n' ' ' <"$order" | sed 's/ $//')" \
        "the steps must run in this order" || return 1
      assert_equal "$PROGRESS_TOTAL_STEPS" "$(wc -l <"$order")" "PROGRESS_TOTAL_STEPS must count the steps" || return 1
    else
      [[ "$status" -ne 0 ]] || fail "a failed certificate step passed the install" || return 1
      assert_equal "$expected" "$(tr '\n' ' ' <"$order" | sed 's/ $//')" \
        "a failed certificate step must stop the install after it" || return 1
    fi
  done

  unset -f generate_selfsigned_cert reset_acme
  unset DOMAIN SSL_PROVIDER CERTIFICATE_MODE EMAIL ACME_RC
}

# The native PHP settings were sed edits of php.ini on commented lines, but
# stock php.ini-production has max_execution_time = 30 and max_input_time = 60
# uncommented, so both stayed: long admin actions hit the 30 s limit. nginx
# also had no fastcgi_read_timeout and gave up after its 60 s default. The
# settings are now a conf.d file PHP-FPM reads after php.ini, whatever php.ini
# holds, and the nginx include waits 300 s like the Docker vhost.
test_php_settings_override_the_stock_php_ini() {
  local temp_dir fpm conf status readme
  temp_dir=$(mktemp -d)
  trap 'rm -rf "$temp_dir"' RETURN
  KVS_PHP_INI_DIR="$temp_dir/etc-php"
  PHP=8.3
  webserver=nginx
  VERSION_ID=13
  fpm="$KVS_PHP_INI_DIR/$PHP/fpm"
  mkdir -p "$fpm/conf.d"
  # The relevant lines of php.ini-production, as PHP 8.4 ships them.
  printf '%s\n' 'max_execution_time = 30' 'max_input_time = 60' ';max_input_vars = 1000' \
    'memory_limit = 128M' 'post_max_size = 8M' 'upload_max_filesize = 2M' \
    ';opcache.interned_strings_buffer=8' >"$fpm/php.ini"
  cp "$fpm/php.ini" "$temp_dir/php.ini.orig"

  curl() { :; }
  gpg() { :; }
  tee() { cat >/dev/null; }
  lsb_release() { echo trixie; }
  apt_get() { :; }
  apt_install() { :; }
  systemctl() { printf '%s\n' "$*" >>"$temp_dir/systemctl"; return "${SYSTEMCTL_RC:-0}"; }

  APT_SOURCES_DIR="$temp_dir" aptinstall_php >/dev/null 2>&1
  status=$?
  assert_equal "0" "$status" "the PHP step must succeed" || return 1
  conf="$fpm/conf.d/99-kvs.ini"
  [[ -f "$conf" ]] || fail "no KVS settings file in the FPM conf.d" || return 1
  # What PHP-FPM ends up with: php.ini, then conf.d in name order, last wins.
  effective() {
    cat "$fpm/php.ini" "$fpm"/conf.d/*.ini |
      sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" | tail -n 1
  }
  assert_equal "300" "$(effective max_execution_time)" "max_execution_time" || return 1
  assert_equal "360" "$(effective max_input_time)" "max_input_time" || return 1
  assert_equal "10000" "$(effective max_input_vars)" "max_input_vars" || return 1
  assert_equal "512M" "$(effective memory_limit)" "memory_limit" || return 1
  assert_equal "2048M" "$(effective post_max_size)" "post_max_size" || return 1
  assert_equal "2048M" "$(effective upload_max_filesize)" "upload_max_filesize" || return 1
  assert_equal "16" "$(effective opcache.interned_strings_buffer)" "opcache.interned_strings_buffer" || return 1
  grep -Fq "restart php$PHP-fpm" "$temp_dir/systemctl" || fail "PHP-FPM was not restarted" || return 1

  # A re-run writes the same file and nothing more.
  APT_SOURCES_DIR="$temp_dir" aptinstall_php >/dev/null 2>&1 || fail "a re-run of the PHP step failed" || return 1
  assert_equal "1" "$(find "$fpm/conf.d" -type f | wc -l)" "one settings file after a re-run" || return 1

  # The file wins over php.ini, so a value an administrator raised there
  # goes back to the KVS one on every run. The file, the output of the step
  # and the README say where local values go instead: a file sorting after
  # it, which a re-run keeps and which still wins.
  assert_file_contains "$conf" "99-local.ini" "the settings file must say where local values go" || return 1
  APT_SOURCES_DIR="$temp_dir" aptinstall_php >"$temp_dir/out" 2>&1 || fail "the PHP step failed" || return 1
  assert_file_contains "$temp_dir/out" "$fpm/conf.d/99-local.ini" "the step must say where local values go" || return 1
  # Read whole first: grep -q stops at the first match, and the SIGPIPE of
  # tr would fail the pipeline under pipefail.
  readme=$(tr -d '\r' <"$REPO_DIR/README.md")
  grep -q 'conf.d/99-kvs.ini.*99-local.ini' <<<"$readme" ||
    fail "the README must say where local PHP values go" || return 1
  printf 'memory_limit = 1024M\n' >"$fpm/conf.d/99-local.ini"
  APT_SOURCES_DIR="$temp_dir" aptinstall_php >/dev/null 2>&1 || fail "a re-run with local values failed" || return 1
  assert_equal "1024M" "$(effective memory_limit)" "a later local file must win over 99-kvs.ini" || return 1
  # The same order with PHP itself, when the runner has one: it reads the
  # files of its scan directory in name order.
  if command -v php >/dev/null 2>&1; then
    assert_equal "1024M 10000" \
      "$(PHP_INI_SCAN_DIR="$fpm/conf.d" php -c "$fpm/php.ini" -r 'echo ini_get("memory_limit"), " ", ini_get("max_input_vars");')" \
      "PHP must read 99-local.ini after 99-kvs.ini" || return 1
  fi
  rm -f "$fpm/conf.d/99-local.ini"

  # A restart that fails fails the step. aptinstall_php already ended with
  # the restart before the settings moved to conf.d, so this only guards
  # the new order, the settings file written first.
  SYSTEMCTL_RC=1 APT_SOURCES_DIR="$temp_dir" aptinstall_php >/dev/null 2>&1
  status=$?
  [[ $status -ne 0 ]] || fail "a failed PHP-FPM restart must fail the step" || return 1

  # A settings file that cannot be written fails the step before the
  # restart: conf.d taken by a file, then the temporary copy taken by a
  # directory. Neither depends on permissions, so both fail as root too.
  for blocked in conf.d tmp; do
    rm -rf "$fpm/conf.d"
    if [[ "$blocked" == conf.d ]]; then
      : >"$fpm/conf.d"
    else
      mkdir -p "$fpm/conf.d/99-kvs.ini.tmp"
    fi
    : >"$temp_dir/systemctl"
    APT_SOURCES_DIR="$temp_dir" aptinstall_php >"$temp_dir/out" 2>&1
    status=$?
    [[ $status -ne 0 ]] || fail "a settings file that cannot be written ($blocked) passed the step" || return 1
    [[ ! -s "$temp_dir/systemctl" ]] || fail "PHP-FPM was restarted without its settings ($blocked)" || return 1
    if [[ "$blocked" == tmp ]]; then
      assert_file_contains "$temp_dir/out" "Could not write $fpm/conf.d/99-kvs.ini" "the failure must name the file" || return 1
      [[ ! -e "$fpm/conf.d/99-kvs.ini" ]] || fail "a failed write left a settings file" || return 1
    fi
  done
  rm -rf "$fpm/conf.d"

  # nginx waits as long as PHP may run, as the Docker vhost does.
  grep -Eq '^fastcgi_read_timeout[[:space:]]+300;$' "$REPO_DIR/conf/nginx/globals/php_fastcgi.conf" ||
    fail "the native fastcgi include must wait 300 s for PHP" || return 1

  unset -f curl gpg tee lsb_release apt_get apt_install systemctl effective
  unset KVS_PHP_INI_DIR SYSTEMCTL_RC
}

# The www redirect vhost of the native install answered every request with
# 444: its server_name is a wildcard and it compared $host with $server_name,
# which holds that pattern. Rendered as the installer writes it, the redirect
# server selects the other hosts by server_name alone, in both www modes;
# tests/integration_origin_security.sh proves the 301 on a real nginx.
test_site_vhost_redirects_every_other_host() {
  local temp_dir file block
  temp_dir=$(mktemp -d)
  trap 'rm -rf "$temp_dir"' RETURN
  file="$temp_dir/site.conf"

  for USE_WWW in false true; do
    DOMAIN=example.com
    PHP=8.3
    set_site_hostnames
    cp "$REPO_DIR/conf/nginx/conf.d/domain.conf" "$file"
    render_nginx_site_config "$file" || fail "the site vhost could not be rendered" || return 1
    if [[ "$USE_WWW" == true ]]; then
      assert_equal "www.example.com|.example.com" "$URL|$REDIRECT_SERVER_NAME" "www mode host names" || return 1
    else
      assert_equal "example.com|*.example.com" "$URL|$REDIRECT_SERVER_NAME" "default host names" || return 1
    fi
    grep -Eq "^[[:space:]]*server_name[[:space:]]+$URL;" "$file" || fail "the site server must answer on $URL" || return 1
    block=$(awk '/^# subdomains redirect/,/^}/' "$file" | grep -v '^[[:space:]]*#')
    grep -Fq "server_name             $REDIRECT_SERVER_NAME;" <<<"$block" ||
      fail "the redirect server must select $REDIRECT_SERVER_NAME" || return 1
    grep -Fq "return                  301 https://$URL\$request_uri;" <<<"$block" ||
      fail "the redirect server must send the other hosts to https://$URL" || return 1
    if grep -Fq "\$server_name" <<<"$block"; then
      fail "the redirect server compares the host with its wildcard server_name ($USE_WWW)" || return 1
    fi
    grep -Eq 'domain\.tld|project_url|redirect_server_name|phpX\.X' "$file" &&
      { fail "a placeholder is left in the rendered vhost"; return 1; }
    grep -Fq 'fastcgi_pass unix:/var/run/php/php8.3-fpm.sock;' "$file" || fail "the PHP socket is not set" || return 1
  done
  USE_WWW=false
}

run_test "installation failures stop the pipeline" test_install_failure_stops_pipeline || failures=$((failures + 1))
run_test "gum repository leaves with its key" test_gum_repository_leaves_with_its_key || failures=$((failures + 1))
run_test "visual progress failures are non-fatal" test_visual_progress_failure_is_nonfatal || failures=$((failures + 1))
run_test "headless PHP detection" test_headless_php_detection || failures=$((failures + 1))
run_test "PHP choice for unencoded archives" test_php_version_choice_for_unencoded_archive || failures=$((failures + 1))
run_test "certificate names follow the www record" test_certificate_names_follow_the_www_record || failures=$((failures + 1))
run_test "yt-dlp step is repeatable" test_yt_dlp_step_is_repeatable || failures=$((failures + 1))
run_test "package steps stop when apt fails" test_package_steps_stop_when_apt_fails || failures=$((failures + 1))
run_test "nginx step needs a usable mime.types" test_nginx_step_needs_a_usable_mime_types || failures=$((failures + 1))
run_test "nginx files come from the checkout or the branch" test_nginx_files_come_from_the_checkout_or_the_branch || failures=$((failures + 1))
run_test "the self-update replaces the running copy or nothing" test_the_self_update_replaces_the_running_copy_or_nothing || failures=$((failures + 1))
run_test "auto-updates follow upstream repositories" test_auto_updates_follow_upstream_repositories || failures=$((failures + 1))
run_test "the ionCube loader is added once and a failure stops the step" test_ioncube_loader_is_added_once_and_a_failure_stops_the_step || failures=$((failures + 1))
run_test "KVS system settings select nginx" test_kvs_system_settings_select_nginx || failures=$((failures + 1))
run_test "archive extraction skips an installed site" test_archive_extraction_skips_an_installed_site || failures=$((failures + 1))
run_test "database file configuration is anchored" test_database_file_configuration_is_anchored || failures=$((failures + 1))
run_test "setup_db.php is restricted to the PHP user" test_setup_db_file_is_restricted_to_the_php_user || failures=$((failures + 1))
run_test "menu add-site refuses on a Docker host" test_menu_add_site_refuses_on_a_docker_host || failures=$((failures + 1))
run_test "acme issue reuses a valid certificate" test_acme_issue_reuses_a_valid_certificate || failures=$((failures + 1))
run_test "port check accepts the installer nginx" test_port_check_accepts_the_installer_nginx || failures=$((failures + 1))
run_test "KVS servers follow the site URL" test_kvs_servers_follow_the_site_url || failures=$((failures + 1))
run_test "domain validation respects MariaDB limits" test_domain_validation_respects_database_limit || failures=$((failures + 1))
run_test "KVS cron privilege and multi-site idempotence" test_cron_is_unprivileged_and_multisite_idempotent || failures=$((failures + 1))
run_test "the backup stays until the new copy is in place" test_restore_preserves_backup_until_success || failures=$((failures + 1))
run_test "backup survives failed clone" test_failed_clone_keeps_user_backup || failures=$((failures + 1))
run_test "phpMyAdmin failure is non-destructive" test_phpmyadmin_failure_preserves_installation || failures=$((failures + 1))
run_test "phpMyAdmin staged update succeeds" test_phpmyadmin_success_swaps_staged_installation || failures=$((failures + 1))
run_test "phpMyAdmin install downloads outside the current directory" test_phpmyadmin_install_downloads_outside_the_current_directory || failures=$((failures + 1))
run_test "NGINX cleanup is scoped" test_nginx_cleanup_uses_scoped_paths || failures=$((failures + 1))
run_test "runtime input stays quiet without a terminal" test_runtime_input_stays_quiet_without_a_terminal || failures=$((failures + 1))
run_test "an import source needs no archive" test_import_source_given_needs_no_archive || failures=$((failures + 1))
run_test "the wrapper installs the requested branch" test_the_wrapper_installs_the_requested_branch || failures=$((failures + 1))
run_test "the OS check sends Ubuntu to the Docker installation" test_os_check_sends_ubuntu_to_the_docker_installation || failures=$((failures + 1))
run_test "a question with no answer left stops the installer" test_a_question_with_no_answer_left_stops_the_installer || failures=$((failures + 1))
run_test "the installer says it needs bash" test_the_installer_says_it_needs_bash || failures=$((failures + 1))
run_test "a failed database import is not reported as success" test_failed_db_import_keeps_install_files_and_retries || failures=$((failures + 1))
run_test "an install re-run keeps setup_db.php restricted" test_install_rerun_keeps_setup_db_restricted || failures=$((failures + 1))
run_test "the site vhost redirects every other host" test_site_vhost_redirects_every_other_host || failures=$((failures + 1))
run_test "PHP settings override the stock php.ini" test_php_settings_override_the_stock_php_ini || failures=$((failures + 1))
run_test "a certificate fallback is reported and followed" test_certificate_fallback_is_reported_and_followed || failures=$((failures + 1))

if ((failures != 0)); then
  echo "$failures test(s) failed" >&2
  exit 1
fi

echo "All kvs-install tests passed"

#!/bin/bash
# shellcheck disable=SC1091,SC2034,SC2154,SC2329
# README documents the standalone headless run with database_ver=12.3. The
# defaults read DATABASE_VER only, so the documented variable was ignored
# and the default series was installed whatever the operator asked for.

set -o pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly TEST_DIR
REPO_DIR=$(cd "$TEST_DIR/.." && pwd)
readonly REPO_DIR
readonly INSTALLER="$REPO_DIR/kvs-install.sh"

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

# Runs the headless defaults in a fresh shell holding only the given
# variables and prints the MariaDB series they selected.
selected_database_version() {
  # shellcheck disable=SC2016  # The inner shell expands $1 and $database_ver.
  env -i PATH="$PATH" HEADLESS=y "$@" \
    bash -c 'source "$1"; initialize_runtime_defaults; printf "%s" "$database_ver"' _ "$INSTALLER"
}

test_documented_database_ver_is_honoured() {
  assert_equal "11.4" "$(selected_database_version database_ver=11.4)" \
    "database_ver from the environment was ignored"
}

test_uppercase_database_ver_still_works() {
  assert_equal "11.8" "$(selected_database_version DATABASE_VER=11.8)" \
    "DATABASE_VER from the environment is no longer honoured"
}

test_default_is_the_latest_lts() {
  assert_equal "12.3" "$(selected_database_version)" "the default MariaDB series changed"
}

test_documented_certificate_settings() {
  local section result default_provider selfsigned
  local -a assignments
  section=$(awk '/^#### Standalone Headless/ { active=1; next }
    active && /^#/ { exit } active { sub(/\r$/, ""); print }' "$REPO_DIR/README.md")
  # Read the example as environment assignments without executing README text.
  mapfile -t assignments < <(sed -nE 's/^([[:alnum:]_]+=[^[:space:]]+) +\\$/\1/p' <<< "$section")
  # shellcheck disable=SC2016 # The isolated shell reads the documented environment.
  result=$(env -i PATH="$PATH" "${assignments[@]}" bash -c '
    source "$1"; initialize_runtime_defaults
    printf "%s %s %s %s" "$HEADLESS" "$INSTALL_TYPE" "$SSL_PROVIDER" "$EMAIL"
  ' _ "$INSTALLER")
  [[ "$result" == "y 2 zerossl "*@* ]] || fail "the standalone example selected: $result" || return 1

  # Exercise the documented account setup and issuance against a local CLI
  # double. Check each argument at the acme.sh boundary, including the email.
  local provider
  for provider in zerossl letsencrypt; do
    local -a overrides=()
    if [[ "$provider" == letsencrypt ]]; then
      overrides=(SSL_PROVIDER=letsencrypt EMAIL=renewal@example.test)
    fi
    result=$(env -i PATH="$PATH" "${assignments[@]}" "${overrides[@]}" bash -s -- "$INSTALLER" "$provider" <<'BASH'
source "$1"
initialize_runtime_defaults
DOMAIN=site.example.test
expected_provider=$2
expected_email=admin@example.com
[[ "$expected_provider" == letsencrypt ]] && expected_email=renewal@example.test
mkdir() { :; }; ufw() { :; }; cd() { :; }; git() { :; }; chown() { :; }; service() { :; }
enable_site_vhost() { :; }
generate_selfsigned_cert() { exit 65; }
# This argument test has no certificate cache. The deployment test below
# exercises the OpenSSL check against real certificates and keys.
check_acme_certificate() { :; }
./acme.sh() {
  [[ $# == 5 && $1 == --install && $2 == -m && $3 == "$expected_email" &&
     $4 == --server && $5 == "$expected_provider" ]] || exit 65
  echo account
}
/root/.acme.sh/acme.sh() {
  case $1 in
    --issue)
      [[ $# == 9 && $2 == -d && $3 == "$DOMAIN" && $4 == -w && $5 == /var/www/_letsencrypt &&
         $6 == --keylength && $7 == ec-256 && $8 == --server && $9 == "$expected_provider" ]] || exit 65
      echo issuance ;;
    --install-cert) return 0 ;;
    *) exit 65 ;;
  esac
}
install_acme.sh
BASH
    ) || { fail "invalid account or issuance arguments for $provider"; return 1; }
    if ! grep -Fxq account <<< "$result" || ! grep -Fxq issuance <<< "$result"; then
      fail "missing account or issuance call for $provider"
      return 1
    fi
  done

  # The other two choices in the standalone instructions are also usable.
  default_provider=$(grep -ow 'SSL_PROVIDER=letsencrypt' <<< "$section")
  selfsigned=$(grep -ow 'SSL_PROVIDER=selfsigned' <<< "$section")
  # shellcheck disable=SC2016
  result=$(env -i PATH="$PATH" HEADLESS=y bash -c '
    source "$1"; initialize_runtime_defaults; printf "SSL_PROVIDER=%s" "$SSL_PROVIDER"
  ' _ "$INSTALLER")
  assert_equal "$result" "$default_provider" "undocumented native default" || return 1
  [[ -n "$selfsigned" ]] || fail "missing standalone self-signed choice" || return 1
  # Block all host operations. The public ACME path would reach cd /root.
  # shellcheck disable=SC2016
  result=$(env -i PATH="$PATH" HEADLESS=y "$selfsigned" bash -c '
    source "$1"; initialize_runtime_defaults
    mkdir() { :; }; ufw() { exit 65; }; cd() { exit 65; }
    generate_selfsigned_cert() { echo generated; }; enable_site_vhost() { echo enabled; }
    install_acme.sh
  ' _ "$INSTALLER") || return 1
  assert_equal $'generated\nenabled' "$result" "documented self-signed mode reached the wrong path"
}

test_reused_certificate_authority() (
  # shellcheck source=kvs-install.sh
  source "$INSTALLER"
  DOMAIN=site.example.test
  local work acme stored requested layout outcome
  work=$(mktemp -d) || return 1
  trap 'rm -rf "$work"' EXIT
  acme="$work/acme client"
  local live="$work/live" cache="$work/cached pair"
  mkdir -p "$live" "$cache" || return 1
  export ACME_FIXTURE="$work" DOMAIN
  generate_selfsigned_cert() { touch "$work/selfsigned"; }
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 \
    -subj /CN=issuer.example.test -keyout "$work/ca.key" -out "$work/ca.pem" 2>/dev/null || return 1
  openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -subj "/CN=$DOMAIN" -keyout "$work/leaf.key" -out "$work/leaf.csr" 2>/dev/null || return 1
  openssl x509 -req -in "$work/leaf.csr" -CA "$work/ca.pem" -CAkey "$work/ca.key" \
    -set_serial 1 -days 1 -out "$work/leaf.pem" 2>/dev/null || return 1
  cat > "$acme" <<'SH'
#!/bin/bash
set -eu
cache="$ACME_FIXTURE/cached pair" live="$ACME_FIXTURE/live"
case "$1" in
  --issue) [[ "$*" != *--force* ]] || exit 61; exit "${ISSUE_STATUS:-2}" ;;
  --info)
    [[ $# == 4 && $2 == -d && $3 == "$DOMAIN" && $4 == --ecc ]]
    echo "DOMAIN_CONF=$cache/$DOMAIN.conf"
    echo "Le_API=$(cat "$ACME_FIXTURE/authority")" ;;
  --install-cert)
    [[ $# == 10 && $2 == --ecc && $3 == -d && $4 == "$DOMAIN" &&
       $5 == --key-file && $6 == "/etc/nginx/ssl/$DOMAIN/key.pem" &&
       $7 == --fullchain-file && $8 == "/etc/nginx/ssl/$DOMAIN/cert.pem" &&
       $9 == --reloadcmd && ${10} == 'service nginx force-reload' ]]
    cp "$cache/$DOMAIN.key" "$live/key.pem"
    cp "$cache/fullchain.cer" "$live/cert.pem"
    printf '%s\n' "$6" "$8" "${10}" > "$ACME_FIXTURE/deploy-settings" ;;
  --renew)
    [[ $# == 7 && $2 == -d && $3 == "$DOMAIN" && $4 == --ecc &&
       $5 == --server && $6 == "$REQUESTED" && $7 == --force ]]
    echo "$NEW_AUTHORITY" > "$ACME_FIXTURE/authority"
    if [[ -e "$ACME_FIXTURE/fail-csr" ]]; then
      cp "$ACME_FIXTURE/ca.key" "$cache/$DOMAIN.key"
      exit 1
    fi ;;
  *) exit 64 ;;
esac
SH
  chmod +x "$acme"
  for requested in zerossl letsencrypt; do
    SSL_PROVIDER=$requested
    export REQUESTED="$requested"
    case "$requested" in
      zerossl) NEW_AUTHORITY="https://acme.$requested.com/v2/DV90" ;;
      letsencrypt) NEW_AUTHORITY="https://acme-v02.api.$requested.org/directory" ;;
    esac
    export NEW_AUTHORITY
    stored="https://previous.example.test/$requested"
    echo "$stored" > "$work/authority"
    cat "$work/leaf.pem" "$work/ca.pem" > "$cache/fullchain.cer"
    cp "$work/leaf.key" "$cache/$DOMAIN.key"
    for layout in missing restored leaf combined; do
      rm -f "$work/deploy-settings" "$live/"{cert,key}.pem
      case "$layout" in
        missing) ;;
        restored) cp "$cache/fullchain.cer" "$live/cert.pem" ;;
        leaf) cp "$work/leaf.pem" "$live/cert.pem" ;;
        combined) { cat "$work/leaf.pem"; echo; cat "$work/ca.pem"; } > "$live/cert.pem" ;;
      esac
      if [[ "$layout" != missing ]]; then
        cp "$work/leaf.key" "$live/key.pem"
        openssl verify -CAfile "$work/ca.pem" -verify_hostname "$DOMAIN" "$live/cert.pem" >/dev/null || return 1
      fi
      issue_site_certificate "$acme" --issue > "$work/log" 2>&1 || { cat "$work/log"; return 1; }
      [[ $(<"$work/authority") == "$stored" && -s "$work/deploy-settings" ]] &&
        cmp "$live/key.pem" "$work/leaf.key" && cmp "$live/cert.pem" "$cache/fullchain.cer" ||
        fail "did not register and deploy the cached pair for $layout" || return 1
      grep -Fq "$stored" "$work/log" || fail "notice omitted the current authority" || return 1
    done

    sed -n 's/^  //p' "$work/log" > "$work/switch.sh"
    rm "$work/deploy-settings"
    bash "$work/switch.sh" && [[ $(<"$work/authority") == "$NEW_AUTHORITY" && -s "$work/deploy-settings" ]] ||
      fail "printed commands did not switch the CA and deploy its certificate" || return 1
    rm "$work/deploy-settings"
    issue_site_certificate "$acme" --issue > "$work/log" 2>&1 || return 1
    [[ -s "$work/deploy-settings" ]] && ! grep -Fq -- '--force' "$work/log" ||
      fail "same-CA skip must deploy without offering a switch" || return 1

    echo "$stored" > "$work/authority"
    touch "$work/fail-csr"
    rm "$work/deploy-settings"
    if bash "$work/switch.sh"; then fail "ignored the failed renewal"; return 1; fi
    rm "$work/fail-csr"
    [[ $(<"$work/authority") == "$NEW_AUTHORITY" && ! -e "$work/deploy-settings" ]] ||
      fail "manual switch continued past a failed CSR" || return 1
    for outcome in 0 2 unreadable; do
      if [[ "$outcome" == unreadable ]]; then
        : > "$cache/$DOMAIN.key"
        : > "$cache/fullchain.cer"
        outcome=2
      fi
      if ISSUE_STATUS=$outcome issue_site_certificate "$acme" --issue > "$work/log" 2>&1; then
        fail "accepted an invalid cached pair after issue status $outcome"
        return 1
      fi
      [[ ! -e "$work/deploy-settings" && ! -e "$work/selfsigned" ]] &&
        cmp "$live/key.pem" "$work/leaf.key" && cmp "$live/cert.pem" <(cat "$work/leaf.pem" "$work/ca.pem") ||
        fail "changed the live pair after a failed rotation" || return 1
      grep -Fq "$cache/$DOMAIN.key" "$work/log" && grep -Fq "$cache/fullchain.cer" "$work/log" ||
        fail "diagnostic omitted a cached filename" || return 1
    done
  done
)

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
run_test "reusing a certificate keeps its renewal authority visible" test_reused_certificate_authority || failures=$((failures + 1))
run_test "documented native certificate choices" test_documented_certificate_settings || failures=$((failures + 1))
run_test "documented database_ver is honoured" test_documented_database_ver_is_honoured || failures=$((failures + 1))
run_test "DATABASE_VER still works" test_uppercase_database_ver_still_works || failures=$((failures + 1))
run_test "default is the latest LTS" test_default_is_the_latest_lts || failures=$((failures + 1))

if ((failures != 0)); then
  echo "$failures test(s) failed" >&2
  exit 1
fi

echo "All headless default tests passed"

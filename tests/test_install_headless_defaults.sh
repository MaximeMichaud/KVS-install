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

# acme.sh deploys with "cat source > destination". The double does the same,
# so a destination linked to the cache is emptied unless the installer stops.
test_linked_certificate_destinations() (
  # shellcheck source=kvs-install.sh
  source "$INSTALLER"
  DOMAIN=site.example.test SSL_PROVIDER=letsencrypt
  local work acme cache live layout status nginx_dir
  work=$(mktemp -d) || return 1
  trap 'rm -rf "$work"' EXIT
  acme="$work/acme client"
  cache="$work/cached pair"
  nginx_dir="$work/nginx dir"
  live="$nginx_dir/ssl/$DOMAIN"
  mkdir -p "$live" "$cache" || return 1
  export LINK_FIXTURE="$work" DOMAIN
  generate_selfsigned_cert() { touch "$work/selfsigned"; }
  cat > "$acme" <<'SH'
#!/bin/bash
set -eu
cache="$LINK_FIXTURE/cached pair"
case "$1" in
  --issue) exit "$ISSUE_STATUS" ;;
  --info) echo "DOMAIN_CONF=$cache/$DOMAIN.conf" ;;
  --install-cert)
    [[ $5 == --key-file && $7 == --fullchain-file ]]
    cat "$cache/$DOMAIN.key" > "$6"
    cat "$cache/fullchain.cer" > "$8"
    touch "$LINK_FIXTURE/deployed" ;;
  *) exit 64 ;;
esac
SH
  chmod +x "$acme"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 \
    -subj "/CN=$DOMAIN" -keyout "$work/key" -out "$work/chain" 2>/dev/null || return 1

  for layout in symlinks relative hardlinks leaf ca; do
    for ISSUE_STATUS in 0 2; do
      export ISSUE_STATUS
      rm -f "$work/deployed" "$live/"{key,cert}.pem "$cache"/*
      cp "$work/key" "$cache/$DOMAIN.key"
      cp "$work/chain" "$cache/fullchain.cer"
      cp "$work/chain" "$cache/$DOMAIN.cer"
      cp "$work/chain" "$cache/ca.cer"
      cp "$work/key" "$live/key.pem"
      cp "$work/chain" "$live/cert.pem"
      case "$layout" in
        symlinks)
          ln -sf "$cache/$DOMAIN.key" "$live/key.pem"
          ln -sf "$cache/fullchain.cer" "$live/cert.pem" ;;
        relative) ln -sf "../../../cached pair/$DOMAIN.key" "$live/key.pem" ;;
        hardlinks) ln -f "$cache/fullchain.cer" "$live/cert.pem" ;;
        leaf) ln -sf "$cache/$DOMAIN.cer" "$live/cert.pem" ;;
        ca) ln -sf "$cache/ca.cer" "$live/cert.pem" ;;
      esac
      status=0
      KVS_NGINX_DIR="$nginx_dir" issue_site_certificate "$acme" --issue > "$work/log" 2>&1 || status=$?
      assert_equal 1 "$status" "deployed over the cache ($layout, issue status $ISSUE_STATUS)" || return 1
      [[ ! -e "$work/deployed" && ! -e "$work/selfsigned" ]] ||
        fail "deployed or replaced a pair linked to the cache ($layout)" || return 1
      cmp -s "$work/key" "$cache/$DOMAIN.key" && cmp -s "$work/chain" "$cache/fullchain.cer" &&
        cmp -s "$work/key" "$live/key.pem" && cmp -s "$work/chain" "$live/cert.pem" ||
        fail "changed the cached or served pair ($layout)" || return 1

      # The printed commands separate the files; the next run then deploys.
      sed -n 's/^  //p' "$work/log" > "$work/separate.sh"
      [[ -s "$work/separate.sh" ]] || fail "no command printed for $layout: $(<"$work/log")" || return 1
      bash "$work/separate.sh" || fail "the printed commands failed for $layout" || return 1
      [[ ! -L "$live/key.pem" && ! -L "$live/cert.pem" ]] || fail "a link is left for $layout" || return 1
      KVS_NGINX_DIR="$nginx_dir" issue_site_certificate "$acme" --issue > "$work/log" 2>&1 ||
        fail "refused separate files after the printed commands ($layout): $(<"$work/log")" || return 1
      [[ -e "$work/deployed" ]] && cmp -s "$work/key" "$cache/$DOMAIN.key" &&
        cmp -s "$work/chain" "$cache/fullchain.cer" && cmp -s "$work/key" "$live/key.pem" &&
        cmp -s "$work/chain" "$live/cert.pem" || fail "did not deploy separate files ($layout)" || return 1
    done
  done
)

# acme.sh --install-cert saves every destination and the reload command it
# is given and clears the ones it is not given. The double stores them in the
# same file format, deploys the same way and runs the reload command.
test_saved_acme_deployment_settings() (
  # shellcheck source=kvs-install.sh
  source "$INSTALLER"
  DOMAIN=site.example.test SSL_PROVIDER=letsencrypt EMAIL=admin@example.test
  local work acme cache live conf status own='service nginx force-reload' saved expected nginx_dir served
  work=$(mktemp -d) || return 1
  trap 'rm -rf "$work"' EXIT
  acme="$work/acme-client"
  cache="$work/cached pair"
  nginx_dir="$work/nginx dir"
  live="$nginx_dir/ssl/$DOMAIN"
  conf="$cache/$DOMAIN.conf"
  mkdir -p "$live" "$cache" "$work/other service" "$work/bin" || return 1
  export SAVED_FIXTURE="$work" DOMAIN
  # shellcheck disable=SC2016
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$SAVED_FIXTURE/services"\n[ "$1" != broken ] && [ ! -e "$SAVED_FIXTURE/$1-down" ]\n' > "$work/bin/service"
  chmod +x "$work/bin/service"
  PATH="$work/bin:$PATH"
  generate_selfsigned_cert() { touch "$work/selfsigned"; }
  cat > "$acme" <<'SH'
#!/bin/bash
set -eu
cache="$SAVED_FIXTURE/cached pair"
conf="$cache/$DOMAIN.conf"
case "$1" in
  --issue) exit "${ISSUE_STATUS:-2}" ;;
  --info) echo "DOMAIN_CONF=$conf" ;;
  --install-cert)
    [[ $2 == --ecc && $3 == -d && $4 == "$DOMAIN" ]]
    shift 4
    cert="" key="" ca="" chain="" reload=""
    while (($#)); do
      case "$1" in
        --cert-file) cert=$2 ;; --key-file) key=$2 ;; --ca-file) ca=$2 ;;
        --fullchain-file) chain=$2 ;; --reloadcmd) reload=$2 ;; *) exit 64 ;;
      esac
      shift 2
    done
    {
      grep -v -e '^Le_Real' -e '^Le_ReloadCmd=' "$conf" || :
      printf "Le_RealCertPath='%s'\nLe_RealCACertPath='%s'\nLe_RealKeyPath='%s'\n" "$cert" "$ca" "$key"
      printf "Le_ReloadCmd='%s'\n" "${reload:+__ACME_BASE64__START_$(printf '%s' "$reload" | base64 -w 0)__ACME_BASE64__END_}"
      printf "Le_RealFullChainPath='%s'\n" "$chain"
    } > "$conf.new"
    mv "$conf.new" "$conf"
    [[ -z "$cert" ]] || cat "$cache/$DOMAIN.cer" > "$cert"
    [[ -z "$ca" ]] || cat "$cache/ca.cer" > "$ca"
    [[ -z "$key" ]] || cat "$cache/$DOMAIN.key" > "$key"
    [[ -z "$chain" ]] || cat "$cache/fullchain.cer" > "$chain"
    [[ -z "$reload" ]] || sh -c "$reload" ;;
  *) exit 64 ;;
esac
SH
  chmod +x "$acme"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 \
    -subj "/CN=$DOMAIN" -keyout "$cache/$DOMAIN.key" -out "$cache/fullchain.cer" 2>/dev/null || return 1
  cp "$cache/fullchain.cer" "$cache/$DOMAIN.cer"
  cp "$cache/fullchain.cer" "$cache/ca.cer"
  # Sets "saved" to the recorded reload command, decoded.
  recorded() {
    saved=$(sed -n "s/^Le_ReloadCmd='__ACME_BASE64__START_\(.*\)__ACME_BASE64__END_'\$/\1/p" "$conf" | base64 -d)
  }
  record() {
    "$acme" --install-cert --ecc -d "$DOMAIN" --key-file "$live/key.pem" --fullchain-file "$live/cert.pem" "$@" >/dev/null
    : > "$work/services"
    rm -f "$work/other service/"*.pem
  }
  run() {
    status=0
    KVS_NGINX_DIR="$nginx_dir" issue_site_certificate "$acme" --issue -d "$DOMAIN" > "$work/log" 2>&1 || status=$?
  }

  # No saved settings: the installer's own destinations and reload command.
  echo "Le_Domain='$DOMAIN'" > "$conf"
  : > "$work/services"
  ISSUE_STATUS=0 run
  recorded
  assert_equal "0:$own:nginx force-reload" "$status:$saved:$(<"$work/services")" "first deployment" || return 1
  grep -Fxq "Le_RealCertPath=''" "$conf" && grep -Fxq "Le_RealCACertPath=''" "$conf" &&
    grep -Fxq "Le_Domain='$DOMAIN'" "$conf" || fail "first deployment saved other destinations" || return 1

  # Destinations and a second service added by the operator survive a
  # re-run, a fresh issue included, and both services are reloaded once.
  for ISSUE_STATUS in 2 0; do
    export ISSUE_STATUS
    record --cert-file "$work/other service/cert.pem" --ca-file "$work/other service/ca.pem" \
      --reloadcmd "$own && service 'other one' reload"
    run
    recorded
    assert_equal "0:$own && service 'other one' reload" "$status:$saved" "re-run with added settings ($ISSUE_STATUS)" || return 1
    grep -Fxq "Le_RealCertPath='$work/other service/cert.pem'" "$conf" &&
      grep -Fxq "Le_RealCACertPath='$work/other service/ca.pem'" "$conf" &&
      grep -Fxq "Le_RealKeyPath='$live/key.pem'" "$conf" && grep -Fxq "Le_RealFullChainPath='$live/cert.pem'" "$conf" ||
      fail "the added destinations were not kept: $(<"$conf")" || return 1
    cmp -s "$cache/$DOMAIN.cer" "$work/other service/cert.pem" && cmp -s "$cache/ca.cer" "$work/other service/ca.pem" ||
      fail "the added destinations were not deployed" || return 1
    assert_equal "nginx force-reload"$'\n'"other one reload" "$(<"$work/services")" "reloads of a re-run ($ISSUE_STATUS)" || return 1
  done
  export ISSUE_STATUS=2

  # A command that never reloaded nginx runs after the installer's own; a
  # second run changes nothing more. Its last line is a comment and its
  # first uses ||: the joined command must still parse and group them.
  expected="service broken reload || service other reload"$'\n'"# end"
  record --reloadcmd "$expected"
  run
  recorded
  assert_equal "0:nginx force-reload"$'\n'"broken reload"$'\n'"other reload" "$status:$(<"$work/services")" "joined reload command" || return 1
  [[ "$saved" == "$own"* && "$saved" == *"$expected"* ]] || fail "joined command lost a part: $saved" || return 1
  expected=$saved
  run
  recorded
  assert_equal "0:$expected" "$status:$saved" "joined command must stay as it is on the next run" || return 1
  # The saved part is one group: a failed nginx reload runs none of it.
  touch "$work/nginx-down"
  : > "$work/services"
  run
  rm "$work/nginx-down"
  assert_equal "1:nginx force-reload"$'\n'"nginx force-reload" "$status:$(<"$work/services")" "failed nginx reload before a joined command" || return 1
  grep -Fxq "Could not deploy the still-valid certificate for $DOMAIN" "$work/log" && ! grep -Fq WARNING "$work/log" ||
    fail "a failed nginx reload was not reported as a failed deployment: $(<"$work/log")" || return 1

  # A command that only mentions the nginx reload is joined like any other.
  expected="service other reload # was: $own"
  record --reloadcmd "$expected"
  run
  recorded
  assert_equal "0:nginx force-reload"$'\n'"other reload" "$status:$(<"$work/services")" "command naming the nginx reload in a comment" || return 1
  [[ "$saved" == "$own && {"* ]] || fail "a mention of the nginx reload was taken for the reload: $saved" || return 1
  # Syntax errors must leave the saved deployment and live pair alone.
  sh() { printf '%s\n' "$*" >> "$work/sh-calls"; command sh "$@"; }
  local invalid name filename dest
  # Run the native pipeline with its configuration reset against a live fixture.
  full_rerun() (
    install_gum() { :; }; installQuestions() { :; }; progress_header() { :; }
    /root/.acme.sh/acme.sh() { "$SAVED_FIXTURE/acme-client" "$@"; }
    run_install_step() {
      case $3 in
        aptinstall_nginx) reset_nginx_configuration_dirs "$nginx_dir/conf.d" "$nginx_dir/globals" ;;
        install_acme.sh) issue_site_certificate /root/.acme.sh/acme.sh --issue ;;
      esac
    }
    script
  )
  mkdir -p "$nginx_dir/conf.d"
  echo 'active site' > "$nginx_dir/conf.d/$DOMAIN.conf"
  local -a invalid_hooks=("service other reload \\" 'service nginx force-reload && (')
  if ! command sh -n <<< 'items=(a b)' 2>/dev/null; then invalid_hooks+=('items=(a b)'); fi
  for invalid in "${invalid_hooks[@]}"; do
    printf "Le_ReloadCmd='__ACME_BASE64__START_%s__ACME_BASE64__END_'\n" "$(printf %s "$invalid" | base64 -w 0)" > "$conf"
    for name in Key FullChain Cert CACert; do
      filename="$work/other service/$name.pem"
      rm -f -- "$filename"
      if [[ $invalid == "$own"* && ( $name == Key || $name == Cert ) ]]; then continue; fi
      printf "Le_Real%sPath='__ACME_BASE64__START_%s__ACME_BASE64__END_'\n" "$name" \
        "$(printf %s "$filename" | base64 -w 0)" >> "$conf"
    done
    cp "$conf" "$work/conf.before"
    : > "$work/services"
    : > "$work/sh-calls"
    run
    [[ $status != 0 && ! -s $work/services ]] && cmp -s "$conf" "$work/conf.before" ||
      fail "invalid hook replaced settings or ran a reload" || return 1
    grep -Fxq -- -n "$work/sh-calls" && grep -Fq "$invalid" "$work/log" ||
      fail "the invalid hook was not checked by sh and diagnosed" || return 1
    if full_rerun > "$work/log" 2>&1 || ! grep -Fxq 'active site' "$nginx_dir/conf.d/$DOMAIN.conf" ||
        ! cmp -s "$conf" "$work/conf.before" || [[ -s $work/services ]]; then
      fail "the full re-run changed the site before refusing an invalid hook"
      return 1
    fi
    if ! grep -Fq "The nginx configuration and saved certificate settings are unchanged." "$work/log" ||
        ! grep -Fq "Installation step failed: Checking the saved certificate reload hook (exit status 1)" "$work/log"; then
      fail "the early refusal did not report the failed step and preserved settings"
      return 1
    fi
    sed -n 's/^  \(.* --install-cert \)/\1/p' "$work/log" > "$work/repair.sh"
    [[ -s $work/repair.sh ]] || { fail "no command to replace the invalid hook"; return 1; }
    (
      /root/.acme.sh/acme.sh() { "$SAVED_FIXTURE/acme-client" "$@"; }
      # shellcheck source=/dev/null
      source "$work/repair.sh"
    ) || { fail "could not run the hook repair"; return 1; }
    recorded
    assert_equal "$own:nginx force-reload" "$saved:$(<"$work/services")" "repaired reload" || return 1
    for name in Key FullChain Cert CACert; do
      dest=$(acme_saved_setting "$conf" "Le_Real${name}Path")
      if [[ $invalid == "$own"* && ( $name == Key || $name == Cert ) ]]; then
        [[ -z $dest ]] || { fail "hook repair added a $name destination"; return 1; }
        continue
      fi
      [[ $dest == "$work/other service/$name.pem" && -s $dest ]] ||
        { fail "hook repair changed the $name destination"; return 1; }
    done
  done
  unset -f sh

  # A kept setting that fails is not the site's failure. With the cached
  # pair in place for nginx the run goes on as public; with another pair
  # served it stops and leaves that pair alone. Never a self-signed one.
  for ISSUE_STATUS in 2 0; do
    export ISSUE_STATUS
    rm -f "$work/selfsigned"
    record --reloadcmd "$own && service other reload"
    touch "$work/other-down"
    CERTIFICATE_MODE=""
    run
    rm "$work/other-down"
    assert_equal "0:public:nginx force-reload"$'\n'"other reload"$'\n'"nginx force-reload" "$status:$CERTIFICATE_MODE:$(<"$work/services")" \
      "failed added reload command ($ISSUE_STATUS)" || return 1
    grep -F WARNING "$work/log" | grep -Fq "other" && [[ ! -e "$work/selfsigned" ]] ||
      fail "a failed added reload command was not reported, or fell back ($ISSUE_STATUS): $(<"$work/log")" || return 1
    # The same with nginx itself failing: a failed deployment, no fallback.
    record --reloadcmd "$own && service other reload"
    touch "$work/nginx-down"
    CERTIFICATE_MODE=""
    run
    rm "$work/nginx-down"
    assert_equal "1:" "$status:$CERTIFICATE_MODE" "failed nginx reload with a kept command ($ISSUE_STATUS)" || return 1
    grep -q "^Could not deploy .* for $DOMAIN" "$work/log" && [[ ! -e "$work/selfsigned" ]] ||
      fail "a failed nginx reload with a kept command was not a failed deployment ($ISSUE_STATUS)" || return 1

    mkdir -p "$work/removed"
    record --cert-file "$work/removed/cert.pem"
    rm -r "$work/removed"
    CERTIFICATE_MODE=""
    run
    assert_equal "0:public" "$status:$CERTIFICATE_MODE" "added destination removed, cached pair served ($ISSUE_STATUS)" || return 1
    grep -F WARNING "$work/log" | grep -Fq "$work/removed/cert.pem" && [[ ! -e "$work/selfsigned" ]] ||
      fail "a removed added destination was not reported, or fell back ($ISSUE_STATUS)" || return 1

    for served in cached key.pem cert.pem; do
      mkdir -p "$work/removed"
      local removed=--cert-file kept=--ca-file
      if [[ $served == cert.pem ]]; then removed=--ca-file; kept=--cert-file; fi
      record "$removed" "$work/removed/cert.pem" "$kept" "$work/other service/kept.pem" --reloadcmd "$own && service other reload"
      rm -r "$work/removed"
      if [[ $served != cached ]]; then echo "previous $served" > "$live/$served"; fi
      CERTIFICATE_MODE=""
      run
      if [[ $served == cached ]]; then
        assert_equal "0:public" "$status:$CERTIFICATE_MODE" "removed destination, cached pair served" || return 1
      else
        assert_equal "1::previous $served" "$status:$CERTIFICATE_MODE:$(<"$live/$served")" \
          "added destination removed, another $served served ($ISSUE_STATUS)" || return 1
      fi
      grep -Fq "$work/removed/cert.pem" "$work/log" && [[ ! -e "$work/selfsigned" ]] ||
        fail "the failing destination was not named, or fell back ($served, $ISSUE_STATUS)" || return 1
      sed -n 's/^  \(.* --install-cert \)/\1/p' "$work/log" > "$work/repair.sh"
      if [[ ! -s $work/repair.sh ]] || ! bash "$work/repair.sh"; then
        fail "no working repair command for $removed"
        return 1
      fi
      recorded
      if ! grep -Fq "='$work/other service/kept.pem'" "$conf" ||
          [[ $saved != "$own && service other reload" || ! -s "$work/other service/kept.pem" ]] ||
          grep -Fq "$work/removed/cert.pem" "$conf" ||
          ! cmp -s "$cache/$DOMAIN.key" "$live/key.pem" || ! cmp -s "$cache/fullchain.cer" "$live/cert.pem"; then
        fail "repair did not deploy the pair and retain the other settings ($removed)"
        return 1
      fi
    done
  done
  export ISSUE_STATUS=2

  # A command saved without base64 by an old acme.sh is read too.
  record
  sed -i "s/^Le_ReloadCmd=.*/Le_ReloadCmd='$own \&\& service old reload'/" "$conf"
  run
  recorded
  assert_equal "0:$own && service old reload" "$status:$saved" "plain saved command" || return 1

  # The commands printed for a CA switch and after a failed issue keep the
  # added settings as well.
  for ISSUE_STATUS in 2 1; do
    export ISSUE_STATUS
    SSL_PROVIDER=zerossl
    record --cert-file "$work/other service/cert.pem" --reloadcmd "$own; service other reload"
    run
    assert_equal 0 "$status" "run before the printed command ($ISSUE_STATUS)" || return 1
    "$acme" --install-cert --ecc -d "$DOMAIN" --key-file "$live/key.pem" --fullchain-file "$live/cert.pem" >/dev/null
    rm -f "$work/other service/cert.pem"
    sed -n 's/^  \(.* --install-cert \)/\1/p' "$work/log" > "$work/printed.sh"
    bash "$work/printed.sh" >/dev/null || fail "the printed command failed ($ISSUE_STATUS): $(<"$work/printed.sh")" || return 1
    recorded
    assert_equal "$own; service other reload" "$saved" "reload command of the printed command ($ISSUE_STATUS)" || return 1
    grep -Fxq "Le_RealCertPath='$work/other service/cert.pem'" "$conf" && [[ -s "$work/other service/cert.pem" ]] ||
      fail "the printed command dropped the added destination ($ISSUE_STATUS)" || return 1
    SSL_PROVIDER=letsencrypt
  done
  export ISSUE_STATUS=2

  # acme.sh holds one key and one full chain destination: the installer's
  # replace others, and the run says which ones.
  record
  sed -i -e "s|^Le_RealKeyPath=.*|Le_RealKeyPath='$work/other service/key.pem'|" \
    -e "s|^Le_RealFullChainPath=.*|Le_RealFullChainPath='$work/other service/chain.pem'|" "$conf"
  run
  assert_equal 0 "$status" "run over other key and chain destinations" || return 1
  grep -F "$work/other service/key.pem" "$work/log" | grep -Fq "$live/key.pem" &&
    grep -F "$work/other service/chain.pem" "$work/log" | grep -Fq "$live/cert.pem" ||
    fail "replaced destinations were not named: $(<"$work/log")" || return 1
  grep -Fxq "Le_RealKeyPath='$live/key.pem'" "$conf" || fail "the site key destination was not saved" || return 1
  run
  ! grep -Fq " replaces " "$work/log" || fail "a replacement was reported for the site's own destinations" || return 1

  # An added destination that is a cached file is refused like the site's.
  record --cert-file "$work/other service/cert.pem" --ca-file "$work/other service/ca.pem"
  ln -s "$cache/ca.cer" "$work/other service/ca.pem"
  cp "$conf" "$work/conf.before"
  rm -f "$work/selfsigned"
  run
  assert_equal 1 "$status" "deployed over a cached file through an added destination" || return 1
  cmp -s "$conf" "$work/conf.before" && [[ -s "$cache/ca.cer" && ! -e "$work/selfsigned" ]] &&
    grep -Fq "$work/other service/ca.pem is the same file as $cache/ca.cer" "$work/log" ||
    fail "an added destination linked to the cache was not refused cleanly: $(<"$work/log")" || return 1
)

# Start with normal signal dispositions even when the suite itself is a background job.
test_selfsigned_signals() {
  env --default-signal=HUP,INT,TERM,PIPE bash -s -- "$INSTALLER" <<'SH'
set -eu
source "$1"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
DOMAIN=site.example.test SSL_PROVIDER=selfsigned KVS_NGINX_DIR="$work/nginx"
live="$KVS_NGINX_DIR/ssl/$DOMAIN"
mkdir -p "$live" "$work/bin"
openssl req -x509 -nodes -days 1 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
  -subj "/CN=$DOMAIN" -keyout "$work/key" -out "$work/cert" 2>/dev/null
# Signal the waiting shell before the child publishes the key. A default signal
# handler can leave this child running even after the shell's EXIT trap finishes.
cat > "$work/bin/mv" <<'MV'
#!/bin/bash
if [[ $3 == */new.key ]]; then
  kill -s "$sig" "$PPID"
  sleep 0.2
  command -p mv "$@" && touch "$done_file"
else
  exec /bin/mv "$@"
fi
MV
chmod +x "$work/bin/mv"
export sig done_file="$work/renamed"
for sig in HUP INT TERM; do
  cp "$work/key" "$live/key.pem"
  cp "$work/cert" "$live/cert.pem"
  rm -f "$done_file"
  status=0
  PATH="$work/bin:$PATH" generate_selfsigned_cert > "$work/log" 2>&1 || status=$?
  for ((i=0; i<100; ++i)); do [[ ! -f $done_file ]] || break; sleep 0.02; done
  if [[ ! -f $done_file || $status != $((128 + $(kill -l "$sig"))) ]] ||
      ! cmp -s "$work/key" "$live/key.pem" || ! cmp -s "$work/cert" "$live/cert.pem" ||
      ! grep -Fq "Restored the previous key" "$work/log"; then
    echo "FAIL: $sig during the external key rename" >&2
    exit 1
  fi
done

mv() {
  command mv "$@" || return $?
  case $fault:$3 in
    broken:*/new.key) exec 2> >(exit 0); wait "$!"; kill -TERM "$BASHPID" ;;
    second:*/new.key|first:*/new.key|both:*/new.crt) kill -TERM "$BASHPID" ;;
  esac
}
ln() {
  if [[ $fault == second && ${!#} == */restore-key ]]; then kill -HUP "$BASHPID"; fi
  command ln "$@"
}
rm() {
  command rm "$@" || return $?
  if [[ $fault == cleanup && ${!#} == */previous-key ]]; then kill -TERM "$BASHPID"; fi
}
for fault in broken second first both cleanup; do
  cp "$work/key" "$live/key.pem"
  cp "$work/cert" "$live/cert.pem"
  if [[ $fault == first ]]; then rm "$live/key.pem" "$live/cert.pem"; fi
  status=0
  generate_selfsigned_cert > "$work/log" 2>&1 || status=$?
  if [[ $status != 143 ]]; then echo "FAIL: $fault returned $status" >&2; exit 1; fi
  case $fault in
    broken|second)
      cmp "$work/key" "$live/key.pem" && cmp "$work/cert" "$live/cert.pem" || exit 1 ;;
    first)
      [[ ! -e $live/key.pem && ! -e $live/cert.pem ]] || exit 1 ;;
    both|cleanup)
      ! cmp -s "$work/key" "$live/key.pem" || exit 1
      openssl pkey -in "$live/key.pem" -pubout > "$work/pub"
      openssl x509 -in "$live/cert.pem" -pubkey -noout | cmp - "$work/pub"
      grep -Fq 'The new matching certificate and key are in place.' "$work/log"
      backup=$(sed -n 's/^Previous certificate and key saved in //p' "$work/log")
      cmp "$backup/key.pem" "$work/key"
      cmp "$backup/cert.pem" "$work/cert" ;;
  esac
done
SH
}

test_selfsigned_destinations() (
  # shellcheck source=/dev/null
  source "$INSTALLER"
  local work live entry fault status previous stages recovery backup=''
  work=$(mktemp -d) || return 1
  trap 'rm -rf "$work"' EXIT
  DOMAIN=site.example.test
  KVS_NGINX_DIR="$work/nginx"
  live="$KVS_NGINX_DIR/ssl/$DOMAIN"
  mkdir -p "$live" "$work/cache" || return 1
  command openssl req -x509 -nodes -days 1 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
    -subj "/CN=$DOMAIN" -keyout "$work/cache/key" -out "$work/cache/cert" 2>/dev/null || return 1
  (cd "$work/cache" && sha256sum key cert) > "$work/cache.sha"
  enable_site_vhost() { touch "$work/enabled"; }
  mkdir() { [[ $# == 2 && $1 == -p && $2 == "$live" ]] || exit 97; command mkdir "$@"; }
  openssl() {
    if [[ $1 == req ]]; then
      case $fault in
        generation) return 43 ;;
        hostname) set -- "${@:1:$#-1}" /CN=other.example.test ;;
      esac
    fi
    command openssl "$@" || return $?
    if [[ $1 == req && $fault == mismatch ]]; then
      while [[ $1 != -keyout ]]; do shift; done
      cp "$work/cache/key" "$2"
    fi
  }
  mv() {
    if [[ $fault == publication || $fault == rollback || $fault == rollback_signal ]]; then
      if [[ ${!#} == "$live/cert.pem" ]]; then return 44; fi
    fi
    if [[ $fault == rollback && $3 == */previous-key ]]; then return 45; fi
    command mv "$@" || return $?
    if [[ $fault == signal && $3 == */new.key || $fault == rollback_signal && $3 == */previous-key ]]; then
      kill -TERM "$BASHPID"
    fi
  }
  run_selfsigned() {
    if [[ $1 == requested ]]; then
      SSL_PROVIDER=selfsigned install_acme.sh
    else
      SSL_PROVIDER=letsencrypt issue_site_certificate false --issue
    fi
  }
  for entry in requested fallback; do
    rm -f "$live/key.pem" "$live/cert.pem" "$work/enabled"
    ln -s "../../../cache/key" "$live/key.pem" && ln "$work/cache/cert" "$live/cert.pem" || return 1
    previous=$(stat -c '%i' "$live/key.pem")
    stages=$(find "$live" -maxdepth 1 -name '.selfsigned.*' | sort)
    for fault in generation hostname mismatch publication; do
      status=0
      run_selfsigned "$entry" > "$work/log" 2>&1 || status=$?
      if [[ $status == 0 || ( $fault == generation && $status != 43 ) || -e $work/enabled ||
            $(stat -c '%i' "$live/key.pem") != "$previous" || ! $live/cert.pem -ef $work/cache/cert ||
            $(find "$live" -maxdepth 1 -name '.selfsigned.*' | sort) != "$stages" ]] ||
          ! (cd "$work/cache" && sha256sum -c "$work/cache.sha" >/dev/null); then
        fail "failed $fault changed the old pair or did not stop ($entry)"
        return 1
      fi
    done
    fault=signal
    status=0
    run_selfsigned "$entry" > "$work/log" 2>&1 || status=$?
    recovery=$(sed -n 's/^Interrupted while replacing the pair. Certificate staging directory: //p' "$work/log")
    if [[ $status != 143 || $recovery != "$live/.selfsigned."* ||
          $(stat -c '%i' "$recovery/previous-key") != "$previous" ||
          $(stat -c '%i' "$live/key.pem") != "$previous" || ! $live/cert.pem -ef $work/cache/cert ]]; then
      fail "interrupt did not restore the pair and name the recovery directory ($entry)"
      return 1
    fi
    if [[ $entry == requested ]]; then
      cmp "$recovery/key.pem" "$work/cache/key" && cmp "$recovery/cert.pem" "$work/cache/cert" || return 1
    fi
    rm -r -- "$recovery"
    fault=rollback_signal
    status=0
    run_selfsigned "$entry" > "$work/log" 2>&1 || status=$?
    recovery=$(sed -n 's/^Interrupted while replacing the pair. Certificate staging directory: //p' "$work/log")
    if [[ $status != 143 || $recovery != "$live/.selfsigned."* ||
          $(stat -c '%i' "$live/key.pem") != "$previous" || ! $live/cert.pem -ef $work/cache/cert ]]; then
      fail "interrupt after rollback deleted the restored pair ($entry)"
      return 1
    fi
    rm -r -- "$recovery"
    fault=rollback
    if run_selfsigned "$entry" > "$work/log" 2>&1; then fail "rollback failure succeeded"; return 1; fi
    recovery=$(sed -n 's/^Could not restore .* Its previous entry is at \(.*\)\.$/\1/p' "$work/log")
    [[ $recovery == "$live/.selfsigned."*/previous-key && $(stat -c '%i' "$recovery") == "$previous" ]] ||
      { fail "rollback failure lost the previous entry ($entry)"; return 1; }
    command mv -fT -- "$recovery" "$live/key.pem" && rm -r -- "${recovery%/*}" || return 1
    fault=none
    run_selfsigned "$entry" > "$work/log" 2>&1 || { cat "$work/log"; return 1; }
    [[ ! -L $live/key.pem && ! $live/cert.pem -ef $work/cache/cert ]] || return 1
    (cd "$work/cache" && sha256sum -c "$work/cache.sha" >/dev/null) || return 1
    openssl pkey -in "$live/key.pem" -pubout > "$work/pub" || return 1
    openssl x509 -in "$live/cert.pem" -pubkey -noout | cmp -s - "$work/pub" || return 1
    if [[ $entry == requested ]]; then
      backup=$(sed -n 's/^Previous certificate and key saved in //p' "$work/log")
      [[ $backup == "$live/"* && $(stat -c %a "$backup") == 700 ]] || return 1
      cmp "$backup/key.pem" "$work/cache/key" && cmp "$backup/cert.pem" "$work/cache/cert" || return 1
      run_selfsigned "$entry" > "$work/log" 2>&1 || return 1
      [[ -d $backup && $(sed -n 's/^Previous certificate and key saved in //p' "$work/log") != "$backup" ]] || return 1
    else
      [[ $(find "$live" -maxdepth 1 -name '.selfsigned.*' | sort) == "$stages" ]] ||
        { fail "unused certificate staging directory after fallback"; return 1; }
    fi
  done
  ln -s "$work" "$work/alias" || return 1
  KVS_NGINX_DIR="$work/alias/nginx"
  live="$KVS_NGINX_DIR/ssl/$DOMAIN"
  if run_selfsigned requested > "$work/log" 2>&1; then fail "accepted a linked parent"; return 1; fi
  KVS_NGINX_DIR="$work/nginx"
  live="$KVS_NGINX_DIR/ssl/$DOMAIN"
  chmod 777 "$live" || return 1
  if run_selfsigned requested > "$work/log" 2>&1; then fail "accepted a writable parent"; return 1; fi
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
run_test "interrupted certificate publication" test_selfsigned_signals || failures=$((failures + 1))
run_test "self-signed generation protects linked destinations" test_selfsigned_destinations || failures=$((failures + 1))
run_test "certificate destinations linked to the acme.sh cache are refused" test_linked_certificate_destinations || failures=$((failures + 1))
run_test "acme.sh settings added by the operator survive a re-run" test_saved_acme_deployment_settings || failures=$((failures + 1))
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

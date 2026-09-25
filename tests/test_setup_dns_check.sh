#!/bin/bash
# shellcheck disable=SC2034
# The DNS check of docker/setup.sh compared every record with the answer of
# one lookup service; an empty answer (service down, slow, no internet)
# made every record a mismatch against nothing and a headless run with
# DNS_CHOICE=3 exited (seen on a real migration pass). The public address
# now comes from the first service that answers with an IPv4, and an
# unknown address skips the comparison instead of failing it.
set -u

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd "$TEST_DIR/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# The two functions, as the script defines them.
awk '/^public_ipv4\(\) \{/,/^}/; /^check_dns\(\) \{/,/^}/' "$ROOT_DIR/docker/setup.sh" > "$WORK/dns.sh"
grep -q 'public_ipv4()' "$WORK/dns.sh" || fail "public_ipv4 is not defined in docker/setup.sh"
grep -q 'check_dns()' "$WORK/dns.sh" || fail "check_dns is not defined in docker/setup.sh"

# curl answers with the IP of STUB_IP from the service named in STUB_OK
# (the trace service answers several lines like the real one) and fails
# for every other service; getent resolves both names to STUB_DNS_IP.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/curl" <<'STUB'
#!/bin/bash
url=${*: -1}
[ -n "${STUB_OK:-}" ] && [[ "$url" == *"$STUB_OK"* ]] || exit 7
case "$url" in
    *cdn-cgi/trace*) printf 'fl=1f\nh=1.1.1.1\nip=%s\nts=1\n' "$STUB_IP" ;;
    *) printf '%s\n' "$STUB_IP" ;;
esac
STUB
cat > "$WORK/bin/getent" <<'STUB'
#!/bin/bash
printf '%s\t%s\n' "${STUB_DNS_IP:-}" "$2"
STUB
chmod +x "$WORK/bin/curl" "$WORK/bin/getent"

run_check() {
    # shellcheck disable=SC2016
    PATH="$WORK/bin:$PATH" STUB_OK="$1" STUB_IP="$2" STUB_DNS_IP="$3" bash -c '
        CYAN=; GREEN=; RED=; YELLOW=; NC=; DOMAIN=example.com
        include_www_for_domain() { return 0; }
        source "$1"
        check_dns
        echo "status=$?"
    ' _ "$WORK/dns.sh" 2>&1
}

out=$(run_check "" "" 203.0.113.7)
grep -q 'status=2' <<< "$out" || fail "no lookup service answering must return 2, got: $out"
grep -q 'Could not determine the public IP' <<< "$out" || fail "the unknown public IP must be reported"
grep -q 'MISMATCH' <<< "$out" && fail "an unknown public IP must not be reported as a mismatch"

out=$(run_check "1.1.1.1/cdn-cgi/trace" 203.0.113.7 203.0.113.7)
grep -q 'status=0' <<< "$out" || fail "the second lookup service must be used when the first fails, got: $out"
grep -q 'Server IP: 203.0.113.7' <<< "$out" || fail "the trace answer must yield the ip= line only"

out=$(run_check "api.ipify.org" 203.0.113.7 198.51.100.9)
grep -q 'status=1' <<< "$out" || fail "records pointing elsewhere must still be a mismatch, got: $out"
grep -q 'MISMATCH' <<< "$out" || fail "the mismatch must be reported"

# The retry loop around the check, as the script runs it: under set -e, a
# mismatch must reach the DNS_CHOICE handling instead of ending the setup.
awk '/^# DNS Check with retry loop/,/^done$/' "$ROOT_DIR/docker/setup.sh" > "$WORK/loop.sh"
grep -q '^while true; do' "$WORK/loop.sh" || fail "the DNS retry loop is not where the test expects it"
grep -q '^    if check_dns; then' "$WORK/loop.sh" || fail "check_dns must run as a condition, a plain call exits under set -e"

run_loop() {
    # shellcheck disable=SC2016
    PATH="$WORK/bin:$PATH" STUB_OK="api.ipify.org" STUB_IP=203.0.113.7 STUB_DNS_IP=198.51.100.9 DNS_CHOICE="$1" bash -c '
        set -e
        CYAN=; GREEN=; RED=; YELLOW=; NC=; DOMAIN=example.com
        include_www_for_domain() { return 1; }
        source "$1"
        source "$2"
        echo "reached the next step"
    ' _ "$WORK/dns.sh" "$WORK/loop.sh" 2>&1
    echo "exit=$?"
}

out=$(run_loop 2)
grep -q 'Continuing without valid DNS' <<< "$out" || fail "DNS_CHOICE=2 must continue past a mismatch, got: $out"
grep -q 'reached the next step' <<< "$out" || fail "the setup must go on after DNS_CHOICE=2, got: $out"
grep -q 'exit=0' <<< "$out" || fail "the loop must not fail the run with DNS_CHOICE=2"

out=$(run_loop 3)
grep -q 'reached the next step' <<< "$out" && fail "DNS_CHOICE=3 must stop the setup"
grep -q 'exit=1' <<< "$out" || fail "DNS_CHOICE=3 must exit 1, got: $out"

echo "PASS: DNS check public IP fallback"

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

# The functions, as the script defines them.
awk '/^dns_nameservers\(\) \{/,/^}/; /^dns_records\(\) \{/,/^}/; /^public_ipv4\(\) \{/,/^}/; /^check_dns\(\) \{/,/^}/; /^validate_dns_settings\(\) \{/,/^}/' \
    "$ROOT_DIR/docker/setup.sh" > "$WORK/dns.sh"
grep -q 'public_ipv4()' "$WORK/dns.sh" || fail "public_ipv4 is not defined in docker/setup.sh"
grep -q 'check_dns()' "$WORK/dns.sh" || fail "check_dns is not defined in docker/setup.sh"
grep -q 'validate_dns_settings()' "$WORK/dns.sh" || fail "validate_dns_settings is not defined in docker/setup.sh"

# curl answers with the IP of STUB_IP from the service named in STUB_OK
# (the trace service answers several lines like the real one) and fails
# for every other service. getent behaves like glibc's for a name that has
# an AAAA record besides its A record: "hosts" answers the IPv6 address
# first, "ahostsv4" the IPv4 address STUB_DNS_IP, one line per socket type.
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
dns=false
if [ "${1:-} ${2:-}" = "-s dns" ]; then dns=true; shift 2; fi
case "$2" in
    example.com) records=${STUB_DNS_IP:-} ;;
    www.example.com) records=${STUB_WWW_IP-${STUB_DNS_IP:-}} ;;
    *) exit 2 ;;
esac
case "$1" in
    hosts) printf '%s\t%s\n' "${STUB_DNS_IPV6:-2001:db8::1}" "$2" ;;
    ahostsv4)
        if [ "$dns" = false ]; then records=${STUB_HOSTS_IP:-$records}; fi
        for ip in $records; do
            printf '%s\tSTREAM %s\n%s\tDGRAM\n%s\tRAW\n' "$ip" "$2" "$ip" "$ip"
        done ;;
    *) exit 2 ;;
esac
STUB
# Both clients print sectioned DNS replies. Glue has the queried type too.
cat > "$WORK/bin/dig" <<'STUB'
#!/bin/bash
if [ "${0##*/}" = host ]; then
    [ "$#" = 7 ] && [ "$1 $2 $3 $4" = '-v -W 2 -t' ] || exit 2
    type=$5 name=$6 server=$7
else
    [ "$#" = 9 ] && [ "$1 $2 $3 $4 $5 $6" = '+time=2 +tries=1 +noall +comments +answer +authority' ] || exit 2
    server=${7#@} name=$8 type=$9
fi
printf '%s\n' "$server $name $type" >> "$DNS_CALLS"
case "$server" in
    192.0.2.54) response=${FIRST_DNS_RESPONSE:-error} ;;
    192.0.2.53|2001:db8::53) response=${LAST_DNS_RESPONSE:-answer} ;;
    *) exit 2 ;;
esac
case "$name $type" in
    'example.com. A') records=${STUB_DNS_IP:-} ;;
    'www.example.com. A') records=${STUB_WWW_IP-${STUB_DNS_IP:-}} ;;
    *) exit 2 ;;
esac
if [ "${0##*/}" = host ] && [ "${DNS_RCODE:-}" = NXDOMAIN ]; then
    echo "Host $name not found: 3(NXDOMAIN)"
    exit 1
fi
printf ';; ->>HEADER<<- opcode: QUERY, status: %s, id: 1\n' "${DNS_RCODE:-NOERROR}"
case "$response" in
    error) exit 1 ;;
    referral)
        printf ';; flags: qr rd;\n;; AUTHORITY SECTION:\nexample.com. 60 IN NS ns.example.com.\n'
        printf ';; ADDITIONAL SECTION:\nns.example.com. 60 IN A 192.0.2.88\n' ;;
    empty) echo ';; flags: qr rd ra;' ;;
    authoritative) echo ';; flags: qr aa rd;' ;;
    answer)
        printf ';; flags: qr rd ra;\n;; ANSWER SECTION:\n%s 60 IN CNAME alias.example.com.\n' "$name"
        for ip in $records; do printf 'alias.example.com. 60 IN %s %s\n' "$type" "$ip"; done
        if [ -z "$records" ]; then
            printf ';; AUTHORITY SECTION:\nexample.com. 60 IN SOA ns.example.com. admin.example.com. 1 60 60 3600 60\n'
        fi ;;
esac
STUB
cp "$WORK/bin/dig" "$WORK/bin/host"
export DNS_CALLS="$WORK/dns.calls"
write_resolvers() {
    printf 'nameserver %s\n' "$@" > "$WORK/resolv.conf"
}
write_resolvers 127.0.0.53 ::1 192.0.2.54 192.0.2.53
sed -i "s|/etc/resolv.conf|$WORK/resolv.conf|g;s|/run/systemd/resolve/resolv.conf|$WORK/upstream|g" "$WORK/dns.sh"
mkdir "$WORK/tools"
for tool in bash awk sed head; do ln -s "$(command -v "$tool")" "$WORK/tools/$tool"; done
chmod +x "$WORK/bin/"*

run_check() {
    # shellcheck disable=SC2016
    PATH="$WORK/bin:$WORK/tools" STUB_OK="$1" STUB_IP="$2" STUB_DNS_IP="$3" bash -c '
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

out=$(STUB_HOSTS_IP=192.0.2.88 run_check https 203.0.113.7 203.0.113.7)
grep -Fxq 'status=0' <<< "$out" || fail "a hosts-file address hid matching DNS records: $out"

# A local stub can synthesize a different A record. Only the configured
# upstream is compared. Without a direct query the result is indeterminate.
for client in dig host; do
    if [ "$client" = host ]; then mv "$WORK/bin/dig" "$WORK/dig.saved"; fi
    : > "$DNS_CALLS"
    out=$(STUB_HOSTS_IP=127.0.1.1 run_check https 203.0.113.7 203.0.113.7)
    grep -Fxq 'status=0' <<< "$out" || fail "$client did not use upstream DNS: $out"
    grep -Eq '^@?192\.0\.2\.54 example\.com\. A$' "$DNS_CALLS" || fail "$client skipped resolver order"
    grep -Eq '^@?192\.0\.2\.53 www\.example\.com\. A$' "$DNS_CALLS" || fail "$client missed www"
    if grep -Eq '127\.|::1' "$DNS_CALLS"; then fail "$client contacted a loopback stub"; fi
    for response in referral empty; do
        out=$(FIRST_DNS_RESPONSE=$response run_check https 203.0.113.7 203.0.113.7)
        grep -Fxq 'status=0' <<< "$out" || fail "$client did not retry a $response reply: $out"
        out=$(FIRST_DNS_RESPONSE=$response LAST_DNS_RESPONSE=$response run_check https 203.0.113.7 '')
        grep -Fxq 'status=2' <<< "$out" || fail "$client mistook an inconclusive $response for missing A: $out"
    done
    out=$(FIRST_DNS_RESPONSE=authoritative run_check https 203.0.113.7 203.0.113.7)
    grep -Fq 'MISMATCH -> no A record' <<< "$out" || fail "$client ignored authoritative NODATA: $out"
    out=$(run_check https 203.0.113.7 '')
    grep -Fq 'MISMATCH -> no A record' <<< "$out" || fail "$client ignored recursive NODATA: $out"
    write_resolvers 127.0.0.53
    printf 'search example.test\n nameserver 2001:db8::53 # upstream\n' > "$WORK/upstream"
    : > "$DNS_CALLS"
    out=$(run_check https 203.0.113.7 203.0.113.7)
    { grep -Fxq 'status=0' <<< "$out" && grep -Fxq '2001:db8::53 example.com. A' "$DNS_CALLS"; } ||
        fail "$client missed the upstream behind the systemd stub: $out"
    write_resolvers 127.0.0.53 ::1 192.0.2.54 192.0.2.53
    : > "$DNS_CALLS"
    out=$(LAST_DNS_RESPONSE=error run_check https 203.0.113.7 '')
    { grep -Fxq 'status=2' <<< "$out" && ! grep -Fq '2001:db8::53' "$DNS_CALLS"; } ||
        fail "$client used systemd upstreams despite configured direct servers: $out"
    rm "$WORK/upstream"
    out=$(DNS_RCODE=SERVFAIL run_check https 203.0.113.7 '')
    grep -Fxq 'status=2' <<< "$out" || fail "$client treated SERVFAIL as missing A: $out"
    out=$(DNS_RCODE=NXDOMAIN run_check https 203.0.113.7 '')
    grep -Fq 'MISMATCH -> no A record' <<< "$out" || fail "$client ignored NXDOMAIN: $out"
done
mv "$WORK/bin/host" "$WORK/host.saved"
out=$(run_check https 203.0.113.7 198.51.100.9)
{ grep -Fq 'Cannot verify public DNS' <<< "$out" && grep -Fxq 'status=2' <<< "$out"; } || fail "missing DNS tools: $out"
mv "$WORK/host.saved" "$WORK/bin/host"
mv "$WORK/dig.saved" "$WORK/bin/dig"
write_resolvers 127.0.0.53 0:0:0:0:0:0:0:1
: > "$DNS_CALLS"
out=$(run_check https 203.0.113.7 198.51.100.9)
{ grep -Fxq 'status=2' <<< "$out" && [ ! -s "$DNS_CALLS" ]; } || fail "stub-only configuration: $out"
write_resolvers 192.0.2.53
for addr in 127.0.1.1 169.254.2.1 0.0.0.0; do
    out=$(run_check https 203.0.113.7 "203.0.113.7 $addr")
    { grep -Fq 'Cannot verify public DNS' <<< "$out" && grep -Fxq 'status=2' <<< "$out"; } || fail "local A $addr: $out"
done
out=$(STUB_WWW_IP=127.0.1.1 run_check https 203.0.113.7 198.51.100.9)
grep -Fxq 'status=1' <<< "$out" || fail "local www answer hid a definite apex mismatch"

for records in '203.0.113.7 192.0.2.8 192.0.2.8 192.0.2.9' '192.0.2.8 192.0.2.9 203.0.113.7'; do
    for name in example.com www.example.com; do
        if [ "$name" = example.com ]; then apex=$records; www=203.0.113.7; else apex=203.0.113.7; www=$records; fi
        out=$(STUB_WWW_IP="$www" run_check https 203.0.113.7 "$apex")
        grep -Fxq 'status=1' <<< "$out" || fail "mixed A records for $name passed: $out"
        line=$(grep -F "  $name: MISMATCH" <<< "$out")
        for ip in 192.0.2.8 192.0.2.9; do
            [ "$(grep -Fo "$ip" <<< "$line" | wc -l)" -eq 1 ] ||
                fail "the mismatch for $name must name $ip once: $out"
        done
    done
done

# A name with no A record at all: the mismatch names what is missing.
out=$(run_check "api.ipify.org" 203.0.113.7 "")
grep -q 'status=1' <<< "$out" || fail "a name without an A record is a mismatch, got: $out"
grep -q 'MISMATCH.*-> no A record' <<< "$out" || fail "a missing A record must be named, got: $out"

# The retry loop around the check, as the script runs it: under set -e, a
# mismatch must reach the DNS_CHOICE handling instead of ending the setup.
awk '/^prompt_read\(\) \{/,/^}/; /^# DNS Check with retry loop/,/^done$/' "$ROOT_DIR/docker/setup.sh" > "$WORK/loop.sh"
grep -q '^while true; do' "$WORK/loop.sh" || fail "the DNS retry loop is not where the test expects it"
grep -q '^prompt_read()' "$WORK/loop.sh" || fail "prompt_read is not defined in docker/setup.sh"
grep -q '^    if check_dns; then' "$WORK/loop.sh" || fail "check_dns must run as a condition, a plain call exits under set -e"

run_loop() {
    # shellcheck disable=SC2016
    PATH="$WORK/bin:$PATH" STUB_OK="api.ipify.org" STUB_IP=203.0.113.7 STUB_DNS_IP=198.51.100.9 DNS_CHOICE="$1" bash -c '
        set -e
        CYAN=; GREEN=; RED=; YELLOW=; NC=; DOMAIN=example.com
        include_www_for_domain() { return 1; }
        source "$1"
        validate_dns_settings || exit 1
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

# DNS_CHOICE given beforehand: an unknown value is an error before any
# lookup, and 1 retries a bounded number of times with a pause, then stops.
# Both used to loop at once and for ever (about 1300 lookups in 3 seconds).
cat > "$WORK/bin/sleep" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$SLEEP_LOG"
STUB
cat > "$WORK/bin/dig-fixed-later" <<'STUB'
#!/bin/bash
# The records point here from the CHECKS_UNTIL_FIXED-th check on.
[ "$*" = "+time=2 +tries=1 +noall +comments +answer +authority @192.0.2.53 example.com. A" ] || exit 2
count=$(($(cat "$CHECK_COUNT" 2>/dev/null || echo 0) + 1))
echo "$count" > "$CHECK_COUNT"
if [ "$count" -ge "$CHECKS_UNTIL_FIXED" ]; then ip=203.0.113.7; else ip=198.51.100.9; fi
printf ';; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 1\n;; ANSWER SECTION:\nexample.com. 60 IN A %s\n' "$ip"
STUB
chmod +x "$WORK/bin/sleep" "$WORK/bin/dig-fixed-later"

# run_loop_env <DNS_CHOICE> [VAR=value...]: the loop with the given
# environment, after the check the setup makes at its start; counts the
# lookups and the pauses. DOTENV names a .env sourced between the two, as
# the setup does several times.
run_loop_env() {
    local choice=$1
    shift
    : > "$WORK/curl.log"
    : > "$WORK/sleep.log"
    # shellcheck disable=SC2016
    env PATH="$WORK/bin:${loop_tools:-$PATH}" STUB_OK="api.ipify.org" STUB_IP=203.0.113.7 STUB_DNS_IP=198.51.100.9 \
        DNS_CHOICE="$choice" SLEEP_LOG="$WORK/sleep.log" CURL_LOG="$WORK/curl.log" "$@" timeout 20 bash -c '
        set -e
        CYAN=; GREEN=; RED=; YELLOW=; NC=; DOMAIN=example.com
        include_www_for_domain() { return 1; }
        curl() { echo x >> "$CURL_LOG"; command curl "$@"; }
        source "$1"
        validate_dns_settings || exit 1
        if [ -n "${DOTENV:-}" ]; then
            # shellcheck source=/dev/null
            source "$DOTENV"
        fi
        source "$2"
        echo "reached the next step"
    ' _ "$WORK/dns.sh" "$WORK/loop.sh" < /dev/null 2>&1
    echo "exit=$?"
}

out=$(run_loop_env 3 STUB_DNS_IP=127.0.1.1)
{ grep -q 'reached the next step' <<< "$out" && grep -q 'Cannot verify public DNS' <<< "$out"; } ||
    fail "a local A answer stopped strict setup: $out"

# A negative DNS answer does not depend on knowing the server address.
# Use only the fixture clients, including when dig is absent.
ln -s "$(command -v timeout)" "$WORK/tools/timeout"
for client in dig host; do
    if [ "$client" = host ]; then mv "$WORK/bin/dig" "$WORK/dig.saved"; fi
    for rcode in NOERROR NXDOMAIN; do
        out=$(loop_tools="$WORK/tools" run_loop_env 3 STUB_OK= STUB_DNS_IP= \
            LAST_DNS_RESPONSE=authoritative DNS_RCODE="$rcode")
        { grep -Fxq 'exit=1' <<< "$out" && grep -Fq 'MISMATCH -> no A record' <<< "$out" &&
            ! grep -Fq 'DNS check skipped' <<< "$out"; } || fail "$client missing-unknown-ip ($rcode): $out"
    done
    out=$(loop_tools="$WORK/tools" run_loop_env 3 STUB_OK= LAST_DNS_RESPONSE=referral)
    { grep -Fxq 'exit=0' <<< "$out" && grep -Fq 'DNS check skipped' <<< "$out"; } ||
        fail "$client inconclusive-unknown-ip: $out"
done
mv "$WORK/dig.saved" "$WORK/bin/dig"

out=$(run_loop_env yes)
grep -qx 'exit=1' <<< "$out" || fail "an unknown DNS_CHOICE must stop the setup, got: $out"
grep -q 'ERROR: DNS_CHOICE=yes is not one of 1 (retry), 2 (continue anyway) or 3 (exit)' <<< "$out" ||
    fail "an unknown DNS_CHOICE must be named, got: $out"
[ ! -s "$WORK/curl.log" ] || fail "an unknown DNS_CHOICE must be refused before any lookup"
grep -q 'reached the next step' <<< "$out" && fail "an unknown DNS_CHOICE must not let the setup go on"

out=$(run_loop_env 1 DNS_RETRY_ATTEMPTS=2 DNS_RETRY_DELAY=7)
grep -qx 'exit=1' <<< "$out" || fail "DNS_CHOICE=1 must stop once its retries are used, got: $out"
grep -q 'still do not point to this server after the retries of DNS_CHOICE=1' <<< "$out" ||
    fail "the end of the retries must be named, got: $out"
[ "$(grep -c 'DNS not configured correctly' <<< "$out")" -eq 3 ] || fail "DNS_CHOICE=1 with 2 retries must check 3 times, got: $out"
[ "$(cat "$WORK/sleep.log")" = "$(printf '7\n7')" ] || fail "each retry must wait DNS_RETRY_DELAY first, got: $(cat "$WORK/sleep.log")"

out=$(run_loop_env 1)
grep -qx 'exit=1' <<< "$out" || fail "DNS_CHOICE=1 must be bounded by default, got: $out"
[ "$(grep -c 'DNS not configured correctly' <<< "$out")" -eq 11 ] || fail "DNS_CHOICE=1 must retry 10 times by default"
[ "$(sort -u "$WORK/sleep.log")" = 30 ] && [ "$(wc -l < "$WORK/sleep.log")" -eq 10 ] ||
    fail "the default retries must wait 30 seconds each, got: $(tr '\n' ' ' < "$WORK/sleep.log")"

cp "$WORK/bin/dig" "$WORK/dig.mismatch"
cp "$WORK/bin/dig-fixed-later" "$WORK/bin/dig"
out=$(run_loop_env 1 CHECK_COUNT="$WORK/check-count" CHECKS_UNTIL_FIXED=3)
cp "$WORK/dig.mismatch" "$WORK/bin/dig"
rm -f "$WORK/check-count"
grep -q 'DNS configuration OK' <<< "$out" || fail "a retry that finds the records must go on, got: $out"
grep -q 'reached the next step' <<< "$out" || fail "the setup must go on once the records point here, got: $out"
[ "$(wc -l < "$WORK/sleep.log")" -eq 2 ] || fail "two retries must have waited before the records pointed here"

# The counts are decimal: a leading zero made bash read them as octal, so
# 08 ended the setup with an arithmetic error and 010 gave 8 retries.
out=$(run_loop_env 1 DNS_RETRY_ATTEMPTS=08 DNS_RETRY_DELAY=09)
grep -q 'value too great for base' <<< "$out" && fail "DNS_RETRY_ATTEMPTS=08 must not be read as octal, got: $out"
[ "$(grep -c 'DNS not configured correctly' <<< "$out")" -eq 9 ] || fail "DNS_RETRY_ATTEMPTS=08 must retry 8 times, got: $out"
[ "$(sort -u "$WORK/sleep.log")" = 9 ] || fail "DNS_RETRY_DELAY=09 must wait 9 seconds, got: $(tr '\n' ' ' < "$WORK/sleep.log")"
out=$(run_loop_env 1 DNS_RETRY_ATTEMPTS=010)
[ "$(grep -c 'DNS not configured correctly' <<< "$out")" -eq 11 ] || fail "DNS_RETRY_ATTEMPTS=010 must retry 10 times, got: $out"

# A DNS setting added to .env by hand, which the setup sources after its
# first check: it is checked again before the loop. An unknown DNS_CHOICE
# from there took the loop's "ask again" arm on every mismatch, the busy
# loop once more (about 2000 lookups in five seconds), and a count with a
# leading zero was octal again.
printf 'DOMAIN=example.com\nDNS_CHOICE=yes\n' > "$WORK/dotenv"
out=$(run_loop_env '' DOTENV="$WORK/dotenv")
grep -qx 'exit=124' <<< "$out" && fail "DNS_CHOICE=yes in .env must not loop, got $(wc -l < "$WORK/curl.log") lookups"
grep -qx 'exit=1' <<< "$out" || fail "DNS_CHOICE=yes in .env must stop the setup, got: $(tail -n 3 <<< "$out")"
grep -q 'ERROR: DNS_CHOICE=yes is not one of 1 (retry), 2 (continue anyway) or 3 (exit)' <<< "$out" ||
    fail "DNS_CHOICE=yes in .env must be named, got: $(tail -n 3 <<< "$out")"
[ ! -s "$WORK/curl.log" ] || fail "DNS_CHOICE=yes in .env must be refused before any lookup"
printf 'DNS_RETRY_ATTEMPTS=010\nDNS_RETRY_DELAY=07\n' > "$WORK/dotenv"
out=$(run_loop_env 1 DOTENV="$WORK/dotenv")
[ "$(grep -c 'DNS not configured correctly' <<< "$out")" -eq 11 ] || fail "DNS_RETRY_ATTEMPTS=010 in .env must retry 10 times, got: $out"
[ "$(sort -u "$WORK/sleep.log")" = 7 ] || fail "DNS_RETRY_DELAY=07 in .env must wait 7 seconds, got: $(tr '\n' ' ' < "$WORK/sleep.log")"
printf 'DNS_RETRY_DELAY=soon\n' > "$WORK/dotenv"
out=$(run_loop_env 1 DOTENV="$WORK/dotenv")
{ grep -qx 'exit=1' <<< "$out" && grep -qF 'ERROR: DNS_RETRY_DELAY=soon is not a number of seconds' <<< "$out"; } ||
    fail "DNS_RETRY_DELAY=soon in .env must stop the setup, got: $(tail -n 3 <<< "$out")"
rm -f "$WORK/dotenv"

# A count that is not a whole number is refused before any lookup instead
# of being replaced by the default in silence.
for setting in DNS_RETRY_ATTEMPTS=abc DNS_RETRY_ATTEMPTS=-1 DNS_RETRY_DELAY=5m DNS_RETRY_DELAY=1234567 DNS_RETRY_DELAY=' 5'; do
    out=$(run_loop_env 1 "$setting")
    grep -qx 'exit=1' <<< "$out" || fail "$setting must stop the setup, got: $out"
    grep -qF "ERROR: ${setting} is not a number of" <<< "$out" || fail "$setting must be named, got: $out"
    [ ! -s "$WORK/curl.log" ] || fail "$setting must be refused before any lookup"
done
echo "PASS: DNS_CHOICE given beforehand is checked, and its retries are bounded and paced"

# The question after a mismatch: an answer the loop does not know and a
# retry that still mismatches are asked again (the loop once kept the first
# answer and never asked again), and the end of the input stops the setup
# instead of asking forever.
run_loop_answers() {
    : > "$WORK/sleep.log"
    # shellcheck disable=SC2016
    PATH="$WORK/bin:$PATH" STUB_OK="api.ipify.org" STUB_IP=203.0.113.7 STUB_DNS_IP=198.51.100.9 DNS_CHOICE="" SLEEP_LOG="$WORK/sleep.log" timeout 20 bash -c '
        set -e
        CYAN=; GREEN=; RED=; YELLOW=; NC=; DOMAIN=example.com
        include_www_for_domain() { return 1; }
        source "$1"
        validate_dns_settings || exit 1
        source "$2"
        echo "reached the next step"
    ' _ "$WORK/dns.sh" "$WORK/loop.sh" 2>&1
    echo "exit=$?"
}

out=$(printf 'x\n2\n' | run_loop_answers)
grep -q 'reached the next step' <<< "$out" || fail "an unknown answer must be asked again, got: $out"
[ "$(grep -c 'Select \[1-3\]:' <<< "$out")" -eq 2 ] || fail "the question must be asked once more after an unknown answer, got: $out"

out=$(printf '1\n2\n' | run_loop_answers)
grep -q 'reached the next step' <<< "$out" || fail "a retry that still mismatches must ask again, got: $out"
[ "$(grep -c 'Select \[1-3\]:' <<< "$out")" -eq 2 ] || fail "the question must be asked again after a retry, got: $out"
[ ! -s "$WORK/sleep.log" ] || fail "a retry chosen at the terminal must not wait, got: $(cat "$WORK/sleep.log")"

out=$(run_loop_answers < /dev/null)
grep -q 'exit=1' <<< "$out" || fail "the end of the input must stop the setup, got: $out"
grep -q 'no answer left on standard input' <<< "$out" || fail "the end of the input must be named, got: $out"
grep -q 'reached the next step' <<< "$out" && fail "the setup must not go on without an answer"

echo "PASS: DNS check public IP fallback"

# The whole setup, with a typo in a DNS setting: it must stop before it
# changes anything. The check sat at the DNS step, after .env had been
# rewritten and, on a re-run, after the running stack of the site was
# stopped for the port check. The run here is a re-run over an installed
# site; docker logs every call it gets.
make_site() {
    local case_dir=$1
    mkdir -p "$case_dir/docker/kvs-archive" "$case_dir/bin" "$case_dir/logs"
    cp "$ROOT_DIR/docker/.env.example" "$case_dir/docker/.env.example"
    sed -e 's/^DOMAIN=.*/DOMAIN=mysite.test/' -e 's/^SITE_PREFIX=.*/SITE_PREFIX=kvs/' \
        -e 's/^COMPOSE_PROJECT_NAME=.*/COMPOSE_PROJECT_NAME=kvs/' -e 's/^SSL_PROVIDER=.*/SSL_PROVIDER=selfsigned/' \
        -e 's/^MARIADB_ROOT_PASSWORD=.*/MARIADB_ROOT_PASSWORD=Generated1/' \
        -e 's/^MARIADB_PASSWORD=.*/MARIADB_PASSWORD=Generated2/' \
        "$ROOT_DIR/docker/.env.example" > "$case_dir/docker/.env"
    cp "$case_dir/docker/.env" "$case_dir/env.before"
    : > "$case_dir/docker/kvs-archive/KVS_7.0.2_mysite.test.zip"
    # shellcheck disable=SC2016  # Literal text of setup.sh.
    sed -e "s|/opt/kvs/logs|$case_dir/logs|g" -e 's/if \[ "$EUID" -ne 0 \]; then/if false; then/' \
        "$ROOT_DIR/docker/setup.sh" > "$case_dir/setup.sh"
    cat > "$case_dir/bin/docker" <<STUB
#!/bin/bash
printf '%s\\n' "\$*" >> "$case_dir/docker.log"
[ "\${1:-}" = --version ] && { echo "Docker version 28.0.0, build test"; exit 0; }
[ "\${1:-} \${2:-}" = "compose version" ] && { echo "Docker Compose version v2.35.0"; exit 0; }
exit 0
STUB
    printf '#!/bin/bash\nexit 0\n' > "$case_dir/bin/curl"
    printf '#!/bin/bash\nexit 0\n' > "$case_dir/bin/ss"
    chmod 755 "$case_dir/setup.sh" "$case_dir/bin/docker" "$case_dir/bin/curl" "$case_dir/bin/ss"
    cp "$ROOT_DIR/docker/bin/resolve-bases.sh" "$case_dir/bin/"
    cp "$ROOT_DIR/docker/images.lock" "$case_dir/"
    cp "$WORK/bin/"{getent,dig,host} "$case_dir/bin/"
    : > "$case_dir/docker.log"
}

# run_setup <case> <headless|interactive> [VAR=value...]: the setup copy of
# the case, with nothing on its input; prints its output and exit=<status>.
run_setup() {
    local case_dir="$WORK/site-$1" mode=$2
    shift 2
    local -a headless=()
    [ "$mode" = headless ] && headless=(HEADLESS=y DOMAIN=mysite.test EMAIL=ops@mysite.test)
    make_site "$case_dir"
    timeout 120 env -C "$case_dir/docker" -u HEADLESS -u DNS_CHOICE -u DNS_RETRY_ATTEMPTS -u DNS_RETRY_DELAY \
        -u COMPOSE_PROJECT_NAME -u COMPOSE_PROFILES -u SITE_PREFIX -u SSL_PROVIDER \
        PATH="$case_dir/bin:/usr/bin:/bin" PREFLIGHT_BYPASS=y GEOIP_CHOICE=2 "${headless[@]}" "$@" \
        "$case_dir/setup.sh" < /dev/null 2>&1
    echo "exit=$?"
}

# untouched <case> <setting> <output>: stopped with the setting named, .env
# as it was, and no docker call.
untouched() {
    local case_dir="$WORK/site-$1"
    grep -qx 'exit=1' <<< "$3" || fail "$1: $2 must stop the setup, got: $(tail -n 3 <<< "$3")"
    grep -qF "ERROR: $2 is not" <<< "$3" || fail "$1: $2 must be named, got: $(tail -n 3 <<< "$3")"
    cmp -s "$case_dir/env.before" "$case_dir/docker/.env" ||
        fail "$1: $2 must be refused before .env is written, got: $(diff "$case_dir/env.before" "$case_dir/docker/.env" | head -n 4)"
    [ ! -s "$case_dir/docker.log" ] ||
        fail "$1: $2 must be refused before Docker is called, got: $(head -n 3 "$case_dir/docker.log")"
}

out=$(run_setup typo-headless headless DNS_CHOICE=yes)
untouched typo-headless DNS_CHOICE=yes "$out"
out=$(run_setup typo-interactive interactive DNS_CHOICE=yes)
untouched typo-interactive DNS_CHOICE=yes "$out"
grep -q 'Select \[' <<< "$out" && fail "an exported DNS_CHOICE typo must be refused before the first question, got: $out"
out=$(run_setup attempts-typo headless DNS_CHOICE=1 DNS_RETRY_ATTEMPTS=ten)
untouched attempts-typo DNS_RETRY_ATTEMPTS=ten "$out"
out=$(run_setup delay-typo headless DNS_CHOICE=1 DNS_RETRY_DELAY=30s)
untouched delay-typo DNS_RETRY_DELAY=30s "$out"

# Valid values, leading zeros included, pass the early check.
out=$(run_setup valid headless DNS_CHOICE=1 DNS_RETRY_ATTEMPTS=08 DNS_RETRY_DELAY=010)
grep -q 'is not a number of\|is not one of' <<< "$out" && fail "valid DNS settings must be accepted, got: $out"
grep -q 'SSL Certificate Provider' <<< "$out" || fail "valid DNS settings must let the setup go on, got: $(tail -n 3 <<< "$out")"
echo "PASS: a DNS setting with a typo stops the setup before it changes anything"

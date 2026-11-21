#!/bin/bash
# shellcheck disable=SC2034  # Installer functions read these settings.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"

fail() { echo "FAIL: $*" >&2; exit 1; }
readme="$root/README.md"
if head -n 1 "$readme" | grep -Fq 'Tested with'; then fail "unqualified versions in the title"; fi
grep -Fq 'For older unencoded files,' "$readme" || fail "missing Docker override scope"
grep -Fq "an explicit \`KVS_PHP_VERSION\`" "$readme" || fail "missing Docker override"
minimum=$(sed -n 's/^KVS_MIN=//p' "$root/.github/release.env")
[[ "$minimum" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "invalid release minimum"
for doc in "$readme" "$root/cli/README.md"; do
    grep -Fq "current release minimum is KVS $minimum" "$doc" || fail "$doc: expected KVS $minimum for upgrades"
done

# Read the minimum Docker recommends when the default PHP is unavailable,
# then exercise the installers on that release and the one immediately below.
docker_check() (
    # shellcheck source=/dev/null
    source <(sed -n '/^readonly SUPPORTED_PHP_VERSIONS=/p; /^php_version_is_supported() {/,/^}/p; /^kvs_documented_php_version() {/,/^}/p; /^saved_php_version() {/,/^}/p; /^refuse_unbuildable_kvs_php() {/,/^}/p' "$root/docker/setup.sh")
    RED='' NC='' IMPORT_MODE=true KVS_PHP_VERSION='' IMPORT_SITE_VERSION=$1
    refuse_unbuildable_kvs_php
)
if docker_check 5.5.1 > refusal; then fail "expected a standalone-only default"; fi
first=$(sed -nE 's/^  - Use an archive, or for an import a site, of KVS ([0-9.]+) or newer,.*/\1/p' refusal)
[[ "$first" =~ ^([0-9]+\.[0-9]+)\.([1-9][0-9]*)$ ]] || fail "missing Docker setup boundary"
older=${BASH_REMATCH[1]}.$((BASH_REMATCH[2] - 1))
grep -Fq "With the default PHP runtime, Docker setup supports KVS $first and newer." "$readme" || fail "Docker minimum differs"

native_php() (
    # The installer defines its own supported PHP list.
    # shellcheck source=/dev/null
    source "$root/kvs-install.sh"
    IONCUBE=YES KVS_PHP_VERSION='' HEADLESS=y
    touch "KVS_$1.zip"
    configure_php_for_kvs_archive "KVS_$1.zip" && printf '%s' "$PHP"
)
old_php=$(native_php "$older")
new_php=$(native_php "$first")
[ "$old_php" != "$new_php" ] || fail "standalone PHP boundary differs"
grep -Fq "Standalone installs PHP $old_php for KVS $older and older." "$readme" || fail "standalone PHP differs"
if docker_check "$older" > refusal; then fail "Docker accepted KVS $older by default"; fi
grep -Fq "needs PHP $old_php" refusal || fail "unexpected reason for refusal"
docker_check "$first" || fail "Docker refused KVS $first"
echo "KVS version documentation agrees with both installers and the release minimum."

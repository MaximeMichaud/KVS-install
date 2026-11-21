#!/bin/bash
set -eu

cd "$(dirname "$0")/.."
features=$(sed -n '/^## Features/,/^## /p' README.md | tr -d '\r')
pool=$(grep -F 'PHP-FPM pool' <<<"$features")
[[ "$pool" == *'standalone installer'*'worker limits'*'pool mode'* ]] &&
  [[ "$pool" == *'Docker'*'dynamic'* ]] &&
  [[ "$pool" != *static* ]] || {
    echo "The feature list must distinguish native worker sizing from Docker's dynamic pool." >&2
    exit 1
  }

# Compare the advertised utilities with the native package request.
# shellcheck source=../kvs-install.sh disable=SC1091
source ./kvs-install.sh
apt_install() { printf '%s\n' "$@"; }
requested=$(aptinstall)
for tool in ncdu vnstat nload; do
  if grep -wq "$tool" <<<"$features" && ! grep -Fxq "$tool" <<<"$requested"; then
    echo "The feature list advertises $tool, absent from the native package request." >&2
    exit 1
  fi
done

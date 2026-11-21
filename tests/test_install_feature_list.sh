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

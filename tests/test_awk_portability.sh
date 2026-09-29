#!/bin/bash
# The scripts run their awk programs with the awk of the machine: mawk on
# Debian and Ubuntu, whose version 1.3.4 20200120 (Debian 12, Ubuntu 22.04)
# has no interval expressions and reads [0-9]{8} as a digit followed by
# "{8}". Such a pattern never matched there: --resume-import refused every
# staged dump as missing its final marker. No awk regular expression of
# the scripts may use one.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
mapfile -t scripts < <(git ls-files '*.sh')
# An awk match (~ /.../, !~ /.../) or a regex argument of match, sub, gsub
# or split holding {n} or {n,m}. The =~ of bash is not awk and may.
if grep -nE '(^|[^=])!?~[[:space:]]*/[^/]*\{[0-9]+(,[0-9]*)?\}|(^|[^A-Za-z_])(match|sub|gsub|split)\([^/]*/[^/]*\{[0-9]+(,[0-9]*)?\}' "${scripts[@]}"; then
    echo "FAIL: an awk regular expression above uses an interval expression, which Debian 12 mawk does not support" >&2
    exit 1
fi
echo "PASS: no awk regular expression uses an interval expression"

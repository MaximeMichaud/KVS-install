#!/bin/bash
# whatisdomain unzipped the whole KVS archive into a fixed /root/tmp, read the
# licence domain from it, then removed /root/tmp, so anything a user already
# kept there was destroyed; it also copied from the current directory, so it
# silently found nothing when run from anywhere but /root. It now reads the one
# member it needs with unzip -p, writes nothing, and looks in KVS_ARCHIVE_DIR.
set -u

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd "$TEST_DIR/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

command -v unzip > /dev/null 2>&1 ||
    { echo "ok - unzip is not installed here, the case is left to the CI runner"; exit 0; }
command -v zip > /dev/null 2>&1 ||
    { echo "ok - zip is not installed here, the case is left to the CI runner"; exit 0; }

# The function, the archive finder and the host names helper it leans on,
# as kvs-install.sh defines them (each closes with a column-zero brace).
awk '
    /^find_kvs_archive\(\) \{/,/^}/
    /^set_site_hostnames\(\) \{/,/^}/
    /^function whatisdomain\(\) \{/,/^}/
' "$ROOT_DIR/kvs-install.sh" > "$WORK/fn.sh"
grep -q 'find_kvs_archive()' "$WORK/fn.sh" || fail "find_kvs_archive is not defined in kvs-install.sh"
grep -q 'whatisdomain()' "$WORK/fn.sh" || fail "whatisdomain is not defined in kvs-install.sh"

# The destructive fixed directory and the directory wipe must be gone from the
# code (comments that explain the old behaviour are allowed to name them).
code=$(grep -vE '^[[:space:]]*#' "$WORK/fn.sh")
grep -q '/root/tmp' <<< "$code" && fail "whatisdomain must not touch /root/tmp any more"
grep -q 'rm -rf' <<< "$code" && fail "whatisdomain must not remove a directory"

# Build a KVS archive whose internal setup.php carries SETUP_DOMAIN (empty for
# none), under a file name holding NAME_DOMAIN, in its own directory.
make_kvs_archive() {
    local dir=$1 name_domain=$2 setup_domain=$3 stage
    mkdir -p "$dir"
    stage=$(mktemp -d "$WORK/stage.XXXXXX")
    mkdir -p "$stage/admin/include"
    if [[ -n "$setup_domain" ]]; then
        # shellcheck disable=SC2016  # $config is PHP source, written literally.
        printf '<?php\n$config[%cproject_licence_domain%c]="%s";\n' "'" "'" "$setup_domain" \
            > "$stage/admin/include/setup.php"
    else
        printf '<?php\n// no licence domain here\n' > "$stage/admin/include/setup.php"
    fi
    (cd "$stage" && zip -q -r "$dir/KVS_7.0.2_[${name_domain}].zip" admin)
    rm -rf "$stage"
}

# Run the function against an archive directory, from a working directory that
# holds no archive of its own, so a copy from "here" would find nothing.
run_whatisdomain() {
    local archive_dir=$1 cwd="$WORK/elsewhere"
    mkdir -p "$cwd"
    (
        cd "$cwd" || exit 97
        KVS_ARCHIVE_DIR="$archive_dir" bash -c '
            DOMAIN=""; URL=""; REDIRECT_SERVER_NAME=""; USE_WWW="false"
            validate_kvs_domain() { return 0; }
            source "$1"
            whatisdomain
            echo "status=$?"
            echo "DOMAIN=$DOMAIN"
        ' _ "$WORK/fn.sh" 2>&1
    )
}

# setup.php wins over the file name: the member is really read from the zip.
make_kvs_archive "$WORK/a" "namedomain.example.com" "insidedomain.example.com"
out=$(run_whatisdomain "$WORK/a")
grep -q 'status=0' <<< "$out" || fail "a readable archive must succeed: $out"
grep -q '^DOMAIN=insidedomain.example.com$' <<< "$out" ||
    fail "the domain must come from the archive's setup.php: $out"
# Nothing is unpacked beside the archive.
[[ ! -e "$WORK/a/admin" ]] || fail "the archive must not be extracted onto disk"
[[ "$(find "$WORK/a" -mindepth 1 | wc -l)" -eq 1 ]] || fail "only the archive may be in the directory"

# No licence domain inside: the archive file name is the fallback.
make_kvs_archive "$WORK/b" "filedomain.example.com" ""
out=$(run_whatisdomain "$WORK/b")
grep -q 'status=0' <<< "$out" || fail "the filename fallback must succeed: $out"
grep -q '^DOMAIN=filedomain.example.com$' <<< "$out" ||
    fail "the domain must fall back to the archive file name: $out"

echo "ok - whatisdomain reads the domain from the archive without unpacking or deleting anything"

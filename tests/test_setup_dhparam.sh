#!/bin/bash
# D4: the DH parameters step of docker/setup.sh, run on its own with the real
# run_step on both of its paths (with gum and without). An empty directory at
# nginx/dhparam.pem (what Docker leaves when the stack starts while the file
# is missing) is replaced by a complete file; any other directory stops the
# step, a complete file is kept, and a failed generation leaves no file. The
# block is cut out of setup.sh by its markers, so the test runs the shipped
# code; openssl is a stub that writes or checks a marker line.
set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SETUP="$REPO_ROOT/docker/setup.sh"
TMP_ROOT=$(mktemp -d /tmp/kvs-setup-dhparam.XXXXXX)
trap 'rm -rf "$TMP_ROOT"' EXIT
status=0

fail() {
    echo "FAIL: $1" >&2
    status=1
}

block="$TMP_ROOT/block.sh"
{
    echo 'GREEN= RED= NC= CYAN= YELLOW='
    echo "DEBUG_LOG=$TMP_ROOT/debug.log"
    echo 'progress_bar() { :; }'
    sed -n '/^report_step_failure() {/,/^}/p' "$SETUP"
    sed -n '/^run_step() {/,/^}/p' "$SETUP"
    sed -n '/^progress_bar "Generating DH parameters"/,/^fi$/p' "$SETUP"
    echo 'echo BLOCK-DONE'
} > "$block"
grep -q 'openssl dhparam -out' "$block" || { echo "FAIL: the DH parameters block was not found in setup.sh" >&2; exit 1; }

# run_block <gum|nogum> <openssl behaviour: ok|fail>; prints the block output.
run_block() {
    local mode="$1" behaviour="$2" bin="$CASE_DIR/bin"
    mkdir -p "$bin"
    cat > "$bin/openssl" <<SH
#!/bin/bash
[ "\$1" = dhparam ] || exit 97
case "\$2" in
    -out)
        [ "$behaviour" = ok ] || { : > "\$3"; echo 'generation failed' >&2; exit 3; }
        printf 'VALID-DHPARAM generated\n' > "\$3"
        ;;
    -check) grep -q '^VALID-DHPARAM' "\$5" 2>/dev/null ;;
    *) exit 97 ;;
esac
SH
    if [ "$mode" = gum ]; then
        # gum spin ... -- <command>: run the command the way gum does.
        cat > "$bin/gum" <<'SH'
#!/bin/bash
[ "$1" = spin ] || exit 0
while [ "$#" -gt 0 ] && [ "$1" != -- ]; do shift; done
shift
exec "$@"
SH
    fi
    chmod +x "$bin"/*
    # GUM_BIN is what the setup sets once it has found a gum that runs.
    local gum_bin=
    [ "$mode" = gum ] && gum_bin="$bin/gum"
    (cd "$CASE_DIR/docker" && PATH="$bin:/usr/bin:/bin" GUM_BIN="$gum_bin" bash -e "$block") > "$CASE_DIR/output.log" 2>&1
}

# new_case <name>: a docker directory with an empty nginx directory.
new_case() {
    CASE_DIR="$TMP_ROOT/$1"
    mkdir -p "$CASE_DIR/docker/nginx"
    DHP="$CASE_DIR/docker/nginx/dhparam.pem"
}

for mode in nogum gum; do
    # An empty directory left by Docker's bind mount becomes a complete file.
    new_case "empty-dir-$mode"
    mkdir "$DHP"
    if run_block "$mode" ok && [ -f "$DHP" ] && grep -Fxq 'VALID-DHPARAM generated' "$DHP" &&
        [ ! -e "$DHP.tmp" ]; then
        echo "PASS: an empty directory at dhparam.pem is replaced by a complete file ($mode)"
    else
        fail "an empty directory at dhparam.pem must be replaced by a complete file ($mode): $(tail -n 3 "$CASE_DIR/output.log")"
    fi

    # A directory with something in it stops the run and is left alone.
    new_case "full-dir-$mode"
    mkdir "$DHP"
    echo keep > "$DHP/operator-file"
    if ! run_block "$mode" ok && [ -d "$DHP" ] && [ "$(ls -A "$DHP")" = operator-file ] &&
        ! grep -q BLOCK-DONE "$CASE_DIR/output.log" &&
        grep -q 'is a directory that is not empty' "$CASE_DIR/output.log"; then
        echo "PASS: a non-empty directory at dhparam.pem stops the run ($mode)"
    else
        fail "a non-empty directory at dhparam.pem must stop the run untouched ($mode): $(tail -n 3 "$CASE_DIR/output.log")"
    fi

    # A complete file is kept as it is, without a new generation.
    new_case "valid-$mode"
    printf 'VALID-DHPARAM operator\n' > "$DHP"
    if run_block "$mode" ok && grep -Fxq 'VALID-DHPARAM operator' "$DHP" &&
        grep -q 'DH parameters already exist' "$CASE_DIR/output.log"; then
        echo "PASS: a complete dhparam.pem is kept ($mode)"
    else
        fail "a complete dhparam.pem must be kept ($mode): $(tail -n 3 "$CASE_DIR/output.log")"
    fi

    # A failed generation stops the run and promotes nothing.
    new_case "failed-$mode"
    if ! run_block "$mode" fail && [ ! -e "$DHP" ] && ! grep -q BLOCK-DONE "$CASE_DIR/output.log"; then
        echo "PASS: a failed generation stops the run and leaves no dhparam.pem ($mode)"
    else
        fail "a failed generation must stop the run without a dhparam.pem ($mode): $(tail -n 3 "$CASE_DIR/output.log")"
    fi
done

exit "$status"

#!/bin/bash
# shellcheck disable=SC1091,SC2034,SC2329
set -eo pipefail
source "$(dirname "$0")/../kvs-install.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

DOMAIN=example.test URL=example.test PHP=8.3
KVS_WWW_ROOT="$work/www" KVS_ARCHIVE_DIR="$work/upload dir" KVS_NGINX_DIR="$work/nginx"
site="$KVS_WWW_ROOT/$DOMAIN"
rules="$KVS_NGINX_DIR/globals/kvs.conf"
archive="$KVS_ARCHIVE_DIR/KVS_7.0_[example.test].zip"
mkdir -p "$site/admin/include" "$KVS_ARCHIVE_DIR" "$KVS_NGINX_DIR/globals" "$work/payload/_INSTALL"
echo 'existing settings' > "$site/admin/include/setup.php"
touch "$site/admin/include/setup_db.php"
chown() { :; }
provision_kvs_database() { touch "$work/db"; }
make_archive() {
    rm -f "$archive"
    (cd "$work/payload" && zip -qr "$archive" .)
}
echo 'rewrite ^/old$ /new permanent;' > "$work/payload/_INSTALL/nginx_config.txt"
echo 'stock file' > "$work/payload/stock"
make_archive
install_KVS || fail "copied site failed"
cmp "$work/payload/_INSTALL/nginx_config.txt" "$rules" || fail "copied site lacks its archive rules"
[[ ! -e "$site/stock" && -f "$archive" ]] || fail "existing site was extracted again"
echo 'next release' > "$work/payload/_INSTALL/nginx_config.txt"
make_archive
install_KVS || fail "refresh failed"
cmp "$work/payload/_INSTALL/nginx_config.txt" "$rules" || fail "managed rules were not refreshed"

# A local edit and a legacy installation with no recorded digest both win.
echo 'rewrite ^/custom$ /custom.php last;' > "$rules"
cp "$rules" "$work/custom"
keep_custom() {
    install_KVS > "$work/output" 2>&1 || fail "rerun with local rules failed"
    cmp "$work/custom" "$rules" || fail "operator rules were overwritten"
    grep -Fq "Keeping existing nginx rewrites" "$work/output" || fail "missing preservation notice"
}
keep_custom
rm "$rules.sha256"
keep_custom
: > "$rules"
: > "$work/custom"
keep_custom
rm "$rules"

zip_members() {
    python3 - "$archive" "$@" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as archive:
    for member in sys.argv[2:]:
        archive.writestr(member, "prefixed rules\n")
PY
}
zip_members ./_INSTALL/nginx_config.txt
install_KVS || fail "prefixed archive member was missed"
grep -Fxq 'prefixed rules' "$rules" || fail "wrong prefixed member content"

# A bad replacement must leave the usable include in place and stop before
# database provisioning, which removes the installation payload on success.
cp "$rules" "$work/good"
reject() {
    rm -f "$work/db"
    if install_KVS; then fail "accepted $1"; fi
    [[ ! -e "$work/db" ]] || fail "continued to database after $1"
    cmp "$rules" "$work/good" || fail "damaged the previous rules on $1"
    [[ -f "$rules.sha256" ]] || fail "lost the previous digest on $1"
    [[ -z $(find "$(dirname "$rules")" -name 'kvs.conf.*' ! -name 'kvs.conf.sha256') ]] ||
        fail "left temporary rewrites on $1"
}
zip_members ./_INSTALL/nginx_config.txt _INSTALL/nginx_config.txt
reject "two rewrite members"
zip_members _INSTALL/nginx_config.txt _INSTALL/nginx_config.txt
reject "a repeated rewrite member"
make_archive
unzip() {
    if [[ $1 == -p ]]; then echo partial; return 2; fi
    command unzip "$@"
}
reject "a member that fails its CRC after writing data"
unset -f unzip
cp "$archive" "$KVS_ARCHIVE_DIR/KVS_second.zip"
reject "ambiguous archives"
rm "$KVS_ARCHIVE_DIR/KVS_second.zip"
: > "$work/payload/_INSTALL/nginx_config.txt"
make_archive
reject "empty archive member"
rm "$work/payload/_INSTALL/nginx_config.txt"
make_archive
reject "missing archive member"
printf 'broken' > "$archive"
reject "a corrupt archive"
rm "$archive"
install_KVS || fail "a rerun with working rules needs no upload"
rm "$rules"
if install_KVS; then fail "accepted a site without any rewrite source"; fi
mkdir "$rules"
if install_KVS; then fail "mistook a directory for a working include"; fi
rmdir "$rules"

mkdir -p "$site/_INSTALL"
: > "$site/_INSTALL/nginx_config.txt"
if install_KVS; then fail "accepted empty extracted rules"; fi
echo 'rewrite ^/fresh$ /new permanent;' > "$site/_INSTALL/nginx_config.txt"
install_KVS || fail "extracted rules failed"
cmp "$site/_INSTALL/nginx_config.txt" "$rules"
[[ $(stat -c %a "$rules") == 644 ]] || fail "unexpected mode for nginx rules"
# These untracked, already-extracted rules must not be marked as shipped.
[[ ! -e "$rules.sha256" ]] || fail "recorded unverified extracted rules as shipped"
rm "$rules"
# A fresh installation consumes its archive and uses the extracted member.
rm -r "$site"
mkdir -p "$work/payload/admin/include"
touch "$work/payload/admin/include/"{setup,setup_db}.php
echo 'fresh archive rules' > "$work/payload/_INSTALL/nginx_config.txt"
make_archive
install_KVS || fail "fresh installation failed"
cmp "$work/payload/_INSTALL/nginx_config.txt" "$rules"
[[ ! -e "$archive" && -f "$site/stock" ]] || fail "fresh archive was not installed"
[[ -s "$rules.sha256" ]] || fail "fresh installation did not record the archive digest"
# A failed database step leaves _INSTALL for the next invocation.
install_KVS || fail "could not resume provisioning"
digest=$(sha256sum < "$rules")
[[ -f "$rules.sha256" && $(<"$rules.sha256") == "${digest%% *}" ]] || fail "resume lost the managed digest"
rm -r "$site/_INSTALL"

for failed_file in "$rules" "$rules.sha256"; do
    echo "release before failure at ${failed_file##*/}" > "$work/payload/_INSTALL/nginx_config.txt"
    make_archive
    mv() {
        if [[ ${!#} == "$failed_file" ]]; then
            if flock -n "${rules%/*}" true; then touch "$work/unlocked"; fi
            return 1
        fi
        command mv "$@"
    }
    if install_KVS; then fail "ignored publication failure at $failed_file"; fi
    unset -f mv
    [[ ! -e "$work/unlocked" ]] || fail "a second publisher could enter during the two renames"
    echo "release after failure at ${failed_file##*/}" > "$work/payload/_INSTALL/nginx_config.txt"
    make_archive
    install_KVS || fail "could not recover interrupted publication"
    cmp "$work/payload/_INSTALL/nginx_config.txt" "$rules" || fail "lost tracked rules after publication failure"
    digest=$(sha256sum < "$rules")
    [[ $(<"$rules.sha256") == "${digest%% *}" && $(stat -c %a "$rules.sha256") == 600 ]] ||
        fail "rules and digest disagree after recovery"
done

# A local edit between failure and recovery must still win.
mv() { [[ ${!#} != "$rules.sha256" ]] && command mv "$@"; }
echo "one more release" > "$work/payload/_INSTALL/nginx_config.txt"
make_archive
if install_KVS; then fail "ignored fingerprint failure"; fi
unset -f mv
echo local > "$rules"
cp "$rules" "$work/custom"
keep_custom

rm -r "$site"
zip_members admin/include/setup_db.php _INSTALL/nginx_config.txt ./_INSTALL/nginx_config.txt
if install_KVS; then fail "fresh installation accepted ambiguous rewrite members"; fi
[[ ! -e "$site/admin" && -f "$archive" ]] || fail "ambiguous archive was consumed or extracted"
# Interrupt each rename on a first install. A retry must establish provenance
# from the retained ZIP even if there is no pending digest yet.
for failed_file in "$rules.sha256.pending" "$rules" "$rules.sha256"; do
    rm -rf "$site"
    rm -f "$rules" "$rules.sha256"
    make_archive
    mv() { [[ ${!#} != "$failed_file" ]] && command mv "$@"; }
    if install_KVS; then fail "ignored first-install failure at $failed_file"; fi
    unset -f mv
    [[ -f "$archive" ]] || fail "consumed the ZIP before publishing the rules and digest"
    install_KVS || fail "could not resume first publication"
    cmp "$work/payload/_INSTALL/nginx_config.txt" "$rules" || fail "lost initial rules during recovery"
    digest=$(sha256sum < "$rules")
    [[ -f "$rules.sha256" && $(<"$rules.sha256") == "${digest%% *}" ]] || fail "lost initial digest during recovery"
    rm -r "$site/_INSTALL"
    echo "next release after ${failed_file##*/}" > "$work/payload/_INSTALL/nginx_config.txt"
    make_archive
    install_KVS || fail "could not apply next upload after recovery"
    cmp "$work/payload/_INSTALL/nginx_config.txt" "$rules" || fail "ignored next upload after recovery"
done

# Editing the extracted input after failure must not give that edit a
# shipped fingerprint just because the ZIP is still there.
rm -rf "$site"
rm -f "$rules" "$rules.sha256"
make_archive
mv() { [[ ${!#} != "$rules.sha256.pending" ]] && command mv "$@"; }
if install_KVS; then fail "ignored failed digest preparation"; fi
unset -f mv
echo custom > "$site/_INSTALL/nginx_config.txt"
install_KVS || fail "could not recover locally edited extracted rules"
[[ $(<"$rules") == custom && ! -e "$rules.sha256" ]] || fail "trusted an edited input as shipped"
echo 'ok - native nginx receives complete KVS rewrites'

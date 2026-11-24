#!/bin/bash
set -eo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=/dev/null
source ./kvs-install.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
KVS_WWW_ROOT="$work/www"
DOMAIN=example.test
export PHP=${PROJECT_URL_PHP_VERSION:-8.3}
site="$KVS_WWW_ROOT/$DOMAIN"
export KVS_NGINX_DIR="$work/nginx" KVS_ARCHIVE_DIR="$work/archives"
mkdir -p "$site/admin/include" "$KVS_ARCHIVE_DIR" "$KVS_NGINX_DIR/globals"
printf '# Existing rewrites\n' >"$KVS_NGINX_DIR/globals/kvs.conf"
file="$site/admin/include/setup.php"
printf "define('DB_PASS','configured');\n" >"$site/admin/include/setup_db.php"
# The full native install and Add a site both work without ACL utilities.
# shellcheck disable=SC2329 # Called by aptinstall in the sourced installer.
apt_install() { printf '%s\n' "$@"; }
aptinstall >"$work/packages"
if grep -Fxq acl "$work/packages"; then echo 'FAIL: unexpected native acl prerequisite' >&2; exit 1; fi
unset -f apt_install
# Simulate the site's account, while exercising real ownership preservation.
mkdir "$work/bin"
cat >"$work/bin/chown" <<'SH'
#!/bin/sh
case " $* " in *' www-data:www-data '*) exit 0 ;; esac
exec /usr/bin/chown "$@"
SH
chmod +x "$work/bin/chown"
export PATH="$work/bin:$PATH"
provision_kvs_database() { touch "$work/provisioned"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
first_lines() { printf '%s\r\n' '<?php' "\$config['other_url'] = 'https://old.test';"; }

# Keep the neighbouring setting, the trailing comment and the CRLF file intact.
mobile_branch() {
  sed 's/$/\r/' <<'PHP'
if ($_SERVER['HTTP_HOST'] == 'm.' . $config['project_licence_domain'])
{
	$config['project_url'] = (strpos($config['project_url'], 'https:') !== false ? 'https:' : 'http:') . "//m." . $config['project_licence_domain'];
}
PHP
}
for URL in example.test www.example.test; do
  while IFS='|' read -r prefix literal suffix; do
    { first_lines; printf '%s%s%s // canonical\r\n' "$prefix" "$literal" "$suffix"; mobile_branch; } >"$file"
    chmod 640 "$file"
    install_KVS >/dev/null || fail "install failed for $prefix$literal"
    [[ $(stat -c %a "$file") == 640 ]] || fail 'mode of installed setup.php changed'
    for quote in "'" '"'; do
      { first_lines; printf '%s%s%s%s%s // canonical\r\n' "$prefix" "$quote" "https://$URL" "$quote" "$suffix"; mobile_branch; } >"$work/expected"
      if cmp -s "$work/expected" "$file"; then break; fi
    done
    cmp -s "$work/expected" "$file" || fail "incorrect project URL or damaged neighbouring text for $prefix$literal"
  done <<'PHP'
$config['project_url']=|"https://old.test"|;
$config['project_url']=|"http://old.test/path"|;
$config['project_url']=|'https://old.test'|;
$config['project_url'] = |"https://old.test"|;
  $config [ 'project_url' ] = |'https://old.test'| ;
$config["project_url"] = |'http://old.test'|;
PHP
done

# Exercise extraction as well as a re-run with the stock mobile branch.
rm -f "$work/provisioned"
sed -i "s#https://$URL#http://archive.example.test#" "$file"
mkdir "$site/_INSTALL"
printf '# Stock rewrites\n' >"$site/_INSTALL/nginx_config.txt"
(cd "$site" && zip -q "$KVS_ARCHIVE_DIR/KVS_fixture.zip" admin/include/setup{,_db}.php _INSTALL/nginx_config.txt)
rm -r "$site"
install_KVS >/dev/null || fail 'fresh archive failed'
cmp "$work/expected" "$file" && [[ -f "$work/provisioned" ]] || fail 'fresh archive was not provisioned intact'

# GNU sed must edit the target of the symlink with its existing access rights.
mv "$file" "$work/site config.php"
ln -s "$work/site config.php" "$file"
printf '%s\n' '<?php' 'exit(17);' >"$file"
cat >>"$file" <<'PHP'
/*
$config['project_url'] = 'https://comment.test';
*/
if ($mobile) $config['project_url'] = 'https://m.example.test';
$config['project_url'] = 'https://old.test';
PHP
acl_fixture=false
if command -v setfacl >/dev/null && command -v getfacl >/dev/null; then
  chmod 600 "$file"
  setfacl -m u:33:r "$file"
  getfacl -cpn -- "$file" >"$work/access.acl"
  acl_fixture=true
else
  echo 'SKIP: named ACL fixture requires setfacl and getfacl'
  chmod 640 "$file"
fi
# Exercise a different group where the test account belongs to one.
for group in $(id -G); do
  if [[ $group != "$(id -g)" ]]; then chgrp "$group" "$file"; break; fi
done
ln "$work/site config.php" "$work/old-inode"
cp "$file" "$work/before"
metadata=$(stat -Lc '%u:%g:%a' "$file")
install_KVS >/dev/null || fail 'valid main assignment after a conditional failed'
[[ -L "$file" && ! "$file" -ef "$work/old-inode" ]] || fail 'the symlink or atomic replace was lost'
cmp "$work/before" "$work/old-inode" || fail 'existing inode modified'
[[ $(stat -Lc '%u:%g:%a' "$file") == "$metadata" ]] || fail 'ownership or mode changed'
if "$acl_fixture"; then
  getfacl -cpn -- "$file" | cmp "$work/access.acl" - || fail 'named access ACL changed on publication'
fi
grep -Fq "'https://m.example.test';" "$file" || fail 'conditional literal changed'
grep -Fq "'https://comment.test';" "$file" || fail 'comment changed'
grep -Fq "https://$URL" "$file" || fail 'main assignment not updated'

refuse() {
  local reason=$1 fixture=${2:-$1} prior
  rm -f "$work/provisioned"
  cp "$file" "$work/before"
  prior=$(stat -Lc '%i:%u:%g:%a' "$file")
  if install_KVS >"$work/log" 2>&1; then fail "accepted $fixture"; fi
  grep -Ei "project_url.*$reason" "$work/log" >/dev/null || fail "missing $reason diagnostic for $fixture"
  cmp "$work/before" "$file" && [[ -L "$file" && $(stat -Lc '%i:%u:%g:%a' "$file") == "$prior" ]] ||
    fail "live file changed on refusal: $fixture"
  if "$acl_fixture"; then
    getfacl -cpn -- "$file" | cmp "$work/access.acl" - || fail 'named access ACL changed on refusal'
  fi
  [[ ! -e "$work/provisioned" ]] || fail 'provisioned after refusal'
}
cat >"$file" <<'PHP'
<?php
$config['project_path']="/PATH";
$config['project_title']="KVS";
PHP
refuse missing
cat >>"$file" <<'PHP'
if ($mobile):
    $config['project_url'] = 'https://m.example.test';
endif;
PHP
refuse missing
cat >"$file" <<'PHP'
<?php
if ($mobile) {
    $config['project_url'] = 'https://m.example.test';
} else {
    $config['project_url'] = 'https://www.example.test';
}
PHP
refuse ambiguous
cat >"$file" <<'PHP'
<?php
$config['project_url'] = "https://$host";
PHP
refuse computed
cat >"$file" <<'PHP'
<?php
$config['project_url'] = 'https://' . getenv('HOST');
PHP
refuse computed
cat >>"$file" <<'PHP'
$config['project_url'] = 'https://old.test';
PHP
refuse ambiguous

# Identical literals on the same physical line must be distinguished by position.
cat >"$file" <<'PHP'
<?php
$neighbor = 'old'; $config['project_url'] = 'old'; if ($mobile) $config['project_url'] = 'old';
PHP
sed "s|project_url'] = 'old'|project_url'] = 'https://$URL'|" "$file" >"$work/expected"
install_KVS >/dev/null || fail 'same-line literals were refused'
cmp "$work/expected" "$file" || fail 'wrong literal edited on a shared line'

# Compare the entire file, including the PHP tag, comparison and adjacent literals.
for prefix in '<?php ' $'<?php\r\n$mobile = $count > 0; '; do
  old="'http://old.test/a|#&\\\\ x<y>'"
  new="https://new.example.test/a|#&\\ x<y>"
  printf '%s%s\r\n' "$prefix" "\$x=$old; \$config['project_url']=$old; \$y=$old; ?>tail" >"$file"
  printf '%s%s\r\n' "$prefix" "\$x=$old; \$config['project_url']='https://new.example.test/a|#&\\\\ x<y>'; \$y=$old; ?>tail" >"$work/expected"
  set_kvs_project_url "$file" "$new" || fail 'GNU sed literal match failed'
  cmp "$work/expected" "$file" || fail 'incorrect edit on a shared PHP line'
done

# The token may start on a later line and itself span more than one line.
cat >"$file" <<'PHP'
<?php
$config['project_path']="/PATH";
$config['project_title']="KVS";
$config['php']="/usr/local/bin/php7.4";
$config['project_url'] =
    /* ~ [x] (.+) \1 & */ 'old
value';
PHP
install_KVS >/dev/null || fail 'multiline literal with a comment was refused'
cat >"$work/expected" <<PHP
<?php
\$config['project_path']="$site";
\$config['project_title']="$DOMAIN";
\$config['php']="/usr/bin/php$PHP";
\$config['project_url'] =
    /* ~ [x] (.+) \1 & */ 'https://$URL';
PHP
cmp "$work/expected" "$file" || fail 'incorrect path, title, PHP binary or URL'

# A closing PHP tag terminates the assignment and may be followed by output.
cat >"$file" <<'PHP'
<?php
if ($mobile) $config['project_url'] = 'https://m.example.test';
$config['project_url'] = 'http://old.test' ?>outside
PHP
sed "s|http://old.test|https://$URL|" "$file" >"$work/expected"
install_KVS >/dev/null || fail 'valid literal before closing tag was refused'
cmp "$work/expected" "$file" || fail 'closing tag, output or conditional assignment changed'

for operator in '.=' '+=' '-=' '*=' '/=' '%=' '**=' '&=' '|=' '^=' '<<=' '>>=' '??='; do
  cat >"$file" <<PHP
<?php
\$config['project_url'] = 'https://old.test';
\$config['project_url'] $operator '/subsite';
PHP
  refuse computed
done
cat >"$file" <<'PHP'
<?php
$config['project_url'] = 'https://old.test';
$effective = ($config['project_url'] .= '/subsite');
PHP
refuse computed

for statement in \
  "{ \$config['project_url'] .= '/subsite'; }" \
  "try {} finally { \$config['project_url'] += 1; }" \
  "if (\$mobile) \$config['project_url'] ??= '/mobile';" \
  "\$effective = (\$config[('project_url')] .= '/subsite');" \
  "((\$config))[ /* key */ ((\"project_url\")) ] .= '/subsite';"; do
  printf '%s\n' '<?php' "\$config['project_url'] = 'https://old.test';" "$statement" >"$file"
  refuse computed
done

main="\$config['project_url'] = 'https://old.test';"
for key in "b'project_url'" 'B"project_url"' '"project\x5furl"' '"\160roject\u{5f}url"'; do
  printf '%s\n' '<?php' "$main" "\$config[$key] = 'second';" >"$file"
  refuse ambiguous "duplicate key $key"
  printf '%s\n' '<?php' "$main" "\$config[$key] .= '/mobile';" >"$file"
  refuse computed "compound key $key"
done

write="\$config['project_url'] = 'second';"
for statement in \
  "{ $write }" "try { $write } finally {}" "try {} catch (Exception \$e) { $write }" \
  "try {} finally { $write }" "foreach ([] as \$x) { $write }" "for (;;) { $write }" \
  "while (false) $write" "do { $write } while (false);" "switch (1) { case 1: $write }" \
  "function f() { $write }" "\$f = function () { $write };" "\$effective = $write" \
  "if (true) { { $write } }" "if (true) \$effective = $write" "if (true) { \$effective = $write }" \
  "if (true) { \$config['project_url'] = (\$effective = 'second'); }" \
  "if (true) while (false) if (true) {} else { $write }" \
  "if (true): while (false): $write endwhile; endif;"; do
  printf '%s\n' '<?php' "$main" "$statement" >"$file"
  refuse ambiguous "$statement"
done

# Writes without an assignment operator next to the key: destructuring and
# foreach targets, and an override that is an operand of and, or, xor.
target="\$config['project_url']"
for statement in \
  "[$target] = ['second'];" "list($target) = ['second'];" "list('k' => $target) = ['k' => 'second'];" \
  "[\$x, [\$y, [$target]]] = [1, [2, ['second']]];" "[, &$target] = \$pair;" \
  "[\$config[b'project_url']] = ['second'];" "[((\$config))[('project_url')]] = ['second'];" \
  "foreach (['second'] as $target) {}" "foreach (['second'] as \$key => $target);" \
  "foreach (['second' => 1] as $target => \$value) {}" "foreach ([['second']] as [\$x, $target]): endforeach;" \
  "foreach ([['second']] as list($target)) {}" "if (true) [$target] = ['second'];" \
  "if (true) { [$target] = ['second']; }" "\$x = [$target] = ['second'];" \
  "if (true) { $target = 'second' and strlen('x'); }" "if (true) $target = \$url or exit;" \
  "if (true): $target = \$url xor \$x; endif;" \
  "[\"{\$key}\" => $target] = ['k' => 'second'];" "[\"\${key}\" => $target] = ['k' => 'second'];" \
  "foreach ([
#[Pure]
fn() => 1] as $target) {}"; do
  printf '%s\n' '<?php' "$main" "$statement" >"$file"
  php -l "$file" >/dev/null || fail "fixture does not parse: $statement"
  refuse ambiguous "$statement"
done

# Reads in the same positions stay accepted, and logical operators inside a
# group or a closure of an override's value.
cat >"$file" <<'PHP'
<?php
$config['project_url'] = 'https://old.test';
$list = [$config['project_url'], 'x'];
$map = ['k' => $config['project_url'], $config['project_url'] => 1];
foreach ([$config['project_url']] as $value) { $seen[$config['project_url']] = $value; }
foreach ($list as $key => $value) echo $config['project_url'];
foreach (array_map(fn($x) => $config['project_url'], $list) as $value) {}
$seen[$config['project_url']] = [1];
$object->seen[0][$config['project_url']] = 1;
[$first] = [$config['project_url']];
list($a, $b) = [$config['project_url'], 2];
$text = "{$config['project_url']}/x";
if ([$config['project_url']] == $list) { $f = function () use ($config) { return [$config['project_url']]; }; }
if ($mobile) { $config['project_url'] = ($a and $b) ? 'm' : 'n'; }
if ($mobile) $config['project_url'] = $f(function () { return 1 and 2; }, [1 or 2]);
elseif ($tablet) $config['project_url'] = function () { return 1 xor 2; };
foreach ($f(function ($x) { foreach ($x as $y) {} }) ?: $config['project_url'] as $value) {}
PHP
php -l "$file" >/dev/null || fail 'read fixture does not parse'
sed "s|https://old.test|https://$URL|" "$file" >"$work/expected"
install_KVS >/dev/null || fail 'a read of project_url was refused'
cmp "$work/expected" "$file" || fail 'a read of project_url changed'

# Only the main literal changes, including with nested, unbraced and alternative bodies.
cat >"$file" <<'PHP'
<?php
$config[B"project_url"] = 'https://old.test';
if ($mobile) { $x = 1; if ($tablet) $config[b'project_url'] = 'tablet'; }
elseif ($tablet) $config['project_url'] = 'tablet';
else { $x = 1; $config['project_url'] = 'other'; }
if ($mobile): $config['project_url'] = 'mobile';
elseif ($tablet): $config['project_url'] = 'tablet';
else: $config['project_url'] = 'other'; endif;
$config["\project_url"] = 'another key';
PHP
sed "s|https://old.test|https://$URL|" "$file" >"$work/expected"
install_KVS >/dev/null || fail 'valid if, elseif or else override was refused'
cmp "$work/expected" "$file" || fail 'a conditional override or another key changed'

# The initial restriction of setup_db.php precedes URL editing and provisioning.
rm -f "$work/provisioned"
cp "$file" "$work/before"
prior=$(stat -Lc %i "$file")
# shellcheck disable=SC2329 # Called by restrict_setup_db_file in the sourced installer.
chmod() {
  if [[ $1 == 600 && $2 == "$site/admin/include/setup_db.php" && ! -e $work/chmod-failed ]]; then
    touch "$work/chmod-failed"
    return 47
  fi
  command chmod "$@"
}
rc=0; install_KVS >"$work/log" 2>&1 || rc=$?
unset -f chmod
[[ $rc == 47 && -e $work/chmod-failed && ! -e $work/provisioned ]] || fail 'initial database chmod failure did not stop provisioning'
cmp "$work/before" "$file" && [[ $(stat -Lc %i "$file") == "$prior" ]] || fail 'edited setup.php after failed chmod'

cat >"$file" <<'PHP'
<?php
$config['project_url'] = 'https://old.test';
PHP
# An operator's directory default ACL follows the platform's sed -i behavior.
if "$acl_fixture"; then
  printf 'old\n' >"$work/reference"
  setfacl -b "$file"
  chmod 640 "$file" "$work/reference"
  setfacl -m d:u:34:r "$work"
  sed -i --follow-symlinks 's/old/new/' "$work/reference"
  install_KVS >/dev/null || fail 'default ACL prevented the edit'
  getfacl -acpn -- "$work/reference" >"$work/reference.acl"
  getfacl -acpn -- "$file" | cmp "$work/reference.acl" - || fail 'default ACL handling differs from GNU sed'
  setfacl -k "$work"
  setfacl -b "$file"
  chmod 600 "$file"
  setfacl -m u:33:r "$file"
fi

# With neither PHP CLI on PATH, the install must stop with status 127.
mkdir "$work/no-php"
for tool in chown chmod find flock grep mktemp openssl realpath rm sed sha256sum stat touch; do
  ln -s "$(type -P "$tool")" "$work/no-php/$tool"
done
prior=$(stat -Lc '%i:%u:%g:%a' "$file")
cp "$file" "$work/before"
rc=0
PATH="$work/no-php" PHP=8.1 set_kvs_project_url "$file" "https://$URL" >"$work/log" 2>&1 || rc=$?
[[ $rc == 127 && $(stat -Lc '%i:%u:%g:%a' "$file") == "$prior" ]] || fail 'missing PHP CLI did not stop publication with 127'
cmp "$work/before" "$file" || fail 'missing PHP CLI changed the live configuration'
grep -q php "$work/log" || fail 'missing PHP CLI was not diagnosed'
ln -s "$(command -v php)" "$work/no-php/php"
PATH="$work/no-php" PHP=8.1 set_kvs_project_url "$file" "https://$URL" || fail 'unversioned PHP fallback failed'
mv "$work/no-php/php" "$work/no-php/php8.1"
printf '#!/bin/sh\nexit 99\n' >"$work/no-php/php"
chmod +x "$work/no-php/php"
PATH="$work/no-php" PHP=8.1 set_kvs_project_url "$file" "https://$URL" || fail 'versioned PHP CLI was not preferred'

# The menu skips package installation. Exercise it with PHP but no ACL tools.
docker_install_dir() { return 1; }
whatisdomain() { :; }
rm -f "$work/provisioned"
PATH="$work/no-php" PHP=8.1 MENU_OPTION=2 manageMenu >/dev/null || fail 'Add a site without getfacl failed'
[[ -f $work/provisioned ]] || fail 'Add a site skipped provisioning'

# Prove the edit on scratch first, then independently check the live read-back.
cat >"$file" <<'PHP'
<?php
$config['project_url'] = 'https://old.test';
PHP
sed() {
  if [[ ${!#} == "$file" ]]; then
    if [[ " $* " == *' -i '* ]]; then
      touch "$work/live-edit"
      if [[ $no_op == live ]]; then return 0; fi
    elif [[ $no_op == scratch ]]; then
      cat "$file"
      return
    fi
  fi
  command sed "$@"
}
for no_op in scratch live; do
  rm -f "$work/live-edit"
  refuse verification
  if [[ $no_op == scratch && -e $work/live-edit ]]; then fail 'edited the live file before the dry run passed'; fi
  if [[ $no_op == live && ! -e $work/live-edit ]]; then fail 'did not exercise the live read-back'; fi
done
echo 'Native project URL checks passed'

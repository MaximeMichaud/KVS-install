#!/bin/bash
# shellcheck disable=SC1091,SC2034,SC2154,SC2329
# The Docker path of kvs-install.sh runs on a fresh host. git, which the
# clone of the repository needs, and unzip, which the setup preflight
# requires, are not part of a minimal Debian or Ubuntu: the installer must
# install them before the clone instead of stopping on "git: command not
# found".

set -o pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly TEST_DIR
REPO_DIR=$(cd "$TEST_DIR/.." && pwd)
readonly REPO_DIR
readonly INSTALLER="$REPO_DIR/kvs-install.sh"

# shellcheck source=../kvs-install.sh
source "$INSTALLER"

fail() {
  echo "FAIL: $*" >&2
  return 1
}

# A PATH holding the tools dockerInstall uses and nothing else, so the
# command probe sees the host as it is. apt-get records its calls and
# provides git and unzip the way the package manager would; the git stub
# lays out a clone with a stub setup and an archive; docker and systemctl
# succeed silently.
make_host() {
  local bin="$1"
  local tool

  mkdir -p "$bin"
  for tool in mkdir mktemp rmdir rm cp mv chmod ls find head sed cat; do
    ln -s "$(command -v "$tool")" "$bin/$tool"
  done
  for tool in docker systemctl; do
    printf '#!/bin/bash\nexit 0\n' >"$bin/$tool"
    chmod +x "$bin/$tool"
  done
  cat >"$bin/git.stub" <<'EOF'
#!/bin/bash
[[ "$1" == clone ]] || exit 0
target="${*: -1}"
mkdir -p "$target/.git" "$target/docker/kvs-archive"
printf '#!/bin/bash\necho setup-ran\n' >"$target/docker/setup.sh"
printf 'DOMAIN=example.com\n' >"$target/docker/.env.example"
: >"$target/docker/kvs-archive/KVS_7.0.2_[example.com].zip"
EOF
  cat >"$bin/apt-get" <<EOF
#!/bin/bash
printf '%s\\n' "\$*" >>"$bin/apt-get.log"
[[ "\$1" == install ]] || exit 0
cp "$bin/git.stub" "$bin/git"
printf '#!/bin/bash\\nexit 0\\n' >"$bin/unzip"
chmod +x "$bin/git" "$bin/unzip"
EOF
  chmod +x "$bin/apt-get"
}

test_docker_path_installs_git_and_unzip_before_the_clone() {
  local temp_dir
  local bin
  local status
  temp_dir=$(mktemp -d)
  trap 'rm -rf "$temp_dir"' RETURN
  bin="$temp_dir/bin"
  make_host "$bin"
  export KVS_INSTALL_DIR="$temp_dir/install"
  export KVS_BACKUP_DIR="$temp_dir/backup"

  (PATH="$bin"; dockerInstall) >"$temp_dir/out" 2>&1
  status=$?

  [[ $status -eq 0 ]] ||
    fail "the Docker path failed on a host without git (status $status): $(tail -n 2 "$temp_dir/out")" || return 1
  grep -q '^install .*git' "$bin/apt-get.log" 2>/dev/null ||
    fail "git was not installed before the clone" || return 1
  grep -q '^install .*unzip' "$bin/apt-get.log" ||
    fail "unzip was not installed for the setup preflight" || return 1
  [[ -d "$KVS_INSTALL_DIR/.git" ]] || fail "the repository was not cloned" || return 1
  grep -q 'setup-ran' "$temp_dir/out" || fail "the Docker setup did not run after the clone" || return 1
}

test_docker_path_leaves_apt_alone_when_the_tools_exist() {
  local temp_dir
  local bin
  local status
  temp_dir=$(mktemp -d)
  trap 'rm -rf "$temp_dir"' RETURN
  bin="$temp_dir/bin"
  make_host "$bin"
  cp "$bin/git.stub" "$bin/git"
  printf '#!/bin/bash\nexit 0\n' >"$bin/unzip"
  chmod +x "$bin/git" "$bin/unzip"
  export KVS_INSTALL_DIR="$temp_dir/install"
  export KVS_BACKUP_DIR="$temp_dir/backup"

  (PATH="$bin"; dockerInstall) >"$temp_dir/out" 2>&1
  status=$?

  [[ $status -eq 0 ]] || fail "the Docker path failed with git and unzip present (status $status)" || return 1
  [[ ! -e "$bin/apt-get.log" ]] || fail "apt-get was called although git and unzip are installed" || return 1
  grep -q 'setup-ran' "$temp_dir/out" || fail "the Docker setup did not run" || return 1
}

run_test() {
  local name="$1"
  local function_name="$2"

  if ("$function_name"); then
    echo "PASS: $name"
    return 0
  fi
  echo "FAIL: $name" >&2
  return 1
}

failures=0
run_test "Docker path installs git and unzip before the clone" test_docker_path_installs_git_and_unzip_before_the_clone || failures=$((failures + 1))
run_test "Docker path leaves apt alone when the tools exist" test_docker_path_leaves_apt_alone_when_the_tools_exist || failures=$((failures + 1))

if ((failures != 0)); then
  echo "$failures test(s) failed" >&2
  exit 1
fi

echo "All Docker prerequisite tests passed"

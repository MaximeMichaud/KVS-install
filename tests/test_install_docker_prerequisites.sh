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
  for tool in mkdir mktemp rmdir rm cp mv chmod ls find head sed cat sleep; do
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
  # Empty, as mktemp makes it when KVS_BACKUP_DIR is not set.
  mkdir "$KVS_BACKUP_DIR"

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
  # A first installation has no .env or archive to keep.
  ! grep -q 'Restored .env and kvs-archive' "$temp_dir/out" ||
    fail "a first installation was told its .env and archive were restored" || return 1
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

# get.docker.com runs as a pipeline whose status is the shell's, and the
# shell has nothing to run when curl brings nothing back: the installer
# must look for the docker command afterwards instead of announcing a
# success and then blaming the missing Compose plugin.
test_docker_path_stops_when_the_docker_script_installs_nothing() {
  local temp_dir
  local bin
  local status
  temp_dir=$(mktemp -d)
  trap 'rm -rf "$temp_dir"' RETURN
  bin="$temp_dir/bin"
  make_host "$bin"
  rm "$bin/docker"
  ln -s "$(command -v sh)" "$bin/sh"
  # get.docker.com out of reach: curl fails and the pipeline feeds sh nothing.
  printf '#!/bin/bash\necho "curl: (6) Could not resolve host: get.docker.com" >&2\nexit 6\n' >"$bin/curl"
  chmod +x "$bin/curl"
  export KVS_INSTALL_DIR="$temp_dir/install"
  export KVS_BACKUP_DIR="$temp_dir/backup"
  mkdir "$KVS_BACKUP_DIR"

  (PATH="$bin"; dockerInstall) >"$temp_dir/out" 2>&1
  status=$?

  [[ $status -ne 0 ]] || fail "the Docker path went on although Docker was not installed" || return 1
  grep -q 'Docker was not installed' "$temp_dir/out" ||
    fail "the failed Docker installation was not reported: $(tail -n 3 "$temp_dir/out")" || return 1
  ! grep -q 'Docker installed successfully' "$temp_dir/out" ||
    fail "a success was announced for an installation that did nothing" || return 1
  ! grep -q 'Docker Compose plugin not found' "$temp_dir/out" ||
    fail "the missing Docker was blamed on the Compose plugin" || return 1
  ! grep -q '^install' "$bin/apt-get.log" 2>/dev/null || fail "the installer went on to the prerequisites without Docker" || return 1

  # The script installed Docker: the path goes on as before.
  printf '#!/bin/bash\nexit 0\n' >"$bin/docker.stub"
  chmod +x "$bin/docker.stub"
  printf '#!/bin/bash\necho "cp %s/docker.stub %s/docker"\n' "$bin" "$bin" >"$bin/curl"

  (PATH="$bin"; dockerInstall) >"$temp_dir/out" 2>&1
  status=$?

  [[ $status -eq 0 ]] ||
    fail "the Docker path failed after its script installed Docker (status $status): $(tail -n 3 "$temp_dir/out")" || return 1
  grep -q 'Docker installed successfully' "$temp_dir/out" || fail "the installed Docker was not announced" || return 1
  grep -q 'setup-ran' "$temp_dir/out" || fail "the Docker setup did not run after the installation" || return 1
}

# unattended-upgrades or cloud-init holds the dpkg lock for the first minutes
# of a fresh host, and apt-get fails at once: the installer must wait for it
# instead of stopping on "Could not get lock", and stop as before on any
# other apt failure.
test_a_busy_apt_lock_is_waited_for() {
  local temp_dir
  local bin
  temp_dir=$(mktemp -d)
  trap 'rm -rf "$temp_dir"' RETURN
  bin="$temp_dir/bin"
  make_host "$bin"
  cat >"$bin/apt-get" <<EOF
#!/bin/bash
printf '%s\\n' "\$*" >>"$bin/apt-get.log"
if [[ \$(grep -c . "$bin/apt-get.log") -le 2 ]]; then
  echo "E: Could not get lock /var/lib/dpkg/lock-frontend. It is held by process 1234 (unattended-upgr)" >&2
  exit 100
fi
[[ "\$1" == install ]] || exit 0
cp "$bin/git.stub" "$bin/git"
printf '#!/bin/bash\\nexit 0\\n' >"$bin/unzip"
chmod +x "$bin/git" "$bin/unzip"
EOF
  chmod +x "$bin/apt-get"
  ln -s "$(command -v grep)" "$bin/grep"

  (PATH="$bin"; KVS_APT_LOCK_PAUSE=0 ensure_docker_prerequisites) >"$temp_dir/out" 2>&1 ||
    fail "the prerequisites must install once the lock is free: $(cat "$temp_dir/out")" || return 1
  [[ $(grep -c '^update' "$bin/apt-get.log") -eq 3 ]] ||
    fail "apt-get update must be run again while the lock is held: $(cat "$bin/apt-get.log")" || return 1
  grep -q '^install .*git' "$bin/apt-get.log" || fail "the packages must be installed after the wait" || return 1
  [[ $(grep -c 'holds the apt lock' "$temp_dir/out") -eq 2 ]] ||
    fail "each wait must be announced: $(cat "$temp_dir/out")" || return 1
  grep -q 'Could not get lock' "$temp_dir/out" || fail "apt's own message must stay visible" || return 1

  # Any other failure comes back at once, with apt's message.
  rm -f "$bin/git" "$bin/unzip" "$bin/apt-get.log"
  cat >"$bin/apt-get" <<EOF
#!/bin/bash
printf '%s\\n' "\$*" >>"$bin/apt-get.log"
echo "E: Unable to locate package nonsense" >&2
exit 100
EOF
  chmod +x "$bin/apt-get"
  if (PATH="$bin"; KVS_APT_LOCK_PAUSE=0 ensure_docker_prerequisites) >"$temp_dir/out" 2>&1; then
    fail "an apt failure that is not a lock must stop the installer" || return 1
  fi
  [[ $(grep -c . "$bin/apt-get.log") -eq 1 ]] || fail "no second try for another failure: $(cat "$bin/apt-get.log")" || return 1
  grep -q 'Unable to locate package' "$temp_dir/out" || fail "apt's message must be shown: $(cat "$temp_dir/out")" || return 1
}

failures=0
run_test "Docker path installs git and unzip before the clone" test_docker_path_installs_git_and_unzip_before_the_clone || failures=$((failures + 1))
run_test "A busy apt lock is waited for" test_a_busy_apt_lock_is_waited_for || failures=$((failures + 1))
run_test "Docker path leaves apt alone when the tools exist" test_docker_path_leaves_apt_alone_when_the_tools_exist || failures=$((failures + 1))
run_test "Docker path stops when the Docker script installs nothing" test_docker_path_stops_when_the_docker_script_installs_nothing || failures=$((failures + 1))

if ((failures != 0)); then
  echo "$failures test(s) failed" >&2
  exit 1
fi

echo "All Docker prerequisite tests passed"

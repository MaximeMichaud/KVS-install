#!/bin/bash
# shellcheck disable=SC1091,SC2034,SC2154,SC2329
# A second run of kvs-install.sh over a working Docker site pulls the
# repository in /opt/kvs and re-clones it when the pull fails. The old copy
# must only go once the new clone exists: with GitHub unreachable both the
# pull and the clone fail, and the site keeps its Compose files, its .env
# and its staged import instead of losing the whole directory.

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

# The host tools are not under test here.
ensure_docker_prerequisites() { :; }
docker() { return 0; }

# A working installation: a clone with its Compose file, the .env holding
# the generated passwords, the archive and an import staged for the second
# pass of a migration.
seed_installation() {
  local install_dir="$1"

  mkdir -p "$install_dir/.git" "$install_dir/docker/kvs-archive" "$install_dir/docker/import"
  printf 'services: {}\n' >"$install_dir/docker/docker-compose.yml"
  printf 'MARIADB_PASSWORD=secret\n' >"$install_dir/docker/.env"
  printf 'archive\n' >"$install_dir/docker/kvs-archive/KVS_7.0.2_[example.com].zip"
  printf 'staged\n' >"$install_dir/docker/import/site.tar"
}

test_unreachable_remote_keeps_the_installed_copy() {
  local temp_dir
  local status
  temp_dir=$(mktemp -d)
  trap 'rm -rf "$temp_dir"' RETURN
  export KVS_INSTALL_DIR="$temp_dir/install"
  export KVS_BACKUP_DIR="$temp_dir/backup"
  seed_installation "$KVS_INSTALL_DIR"

  # GitHub unreachable: neither the pull nor a fresh clone can succeed.
  git() {
    case ${1:-} in
      pull) return 1 ;;
      clone) return 128 ;;
    esac
    return 0
  }

  (dockerInstall) >"$temp_dir/out" 2>&1
  status=$?

  [[ $status -ne 0 ]] || fail "dockerInstall reported success without a repository" || return 1
  [[ -f "$KVS_INSTALL_DIR/docker/docker-compose.yml" ]] ||
    fail "a failed re-clone deleted the Compose files of the running site" || return 1
  [[ -f "$KVS_INSTALL_DIR/docker/.env" ]] || fail "a failed re-clone deleted .env" || return 1
  [[ -f "$KVS_INSTALL_DIR/docker/import/site.tar" ]] ||
    fail "a failed re-clone deleted the staged import" || return 1
  [[ ! -e "$KVS_INSTALL_DIR.clone" ]] || fail "a failed clone left its staging directory behind" || return 1
}

test_successful_reclone_replaces_the_copy_and_restores_user_data() {
  local temp_dir
  local status
  temp_dir=$(mktemp -d)
  trap 'rm -rf "$temp_dir"' RETURN
  export KVS_INSTALL_DIR="$temp_dir/install"
  export KVS_BACKUP_DIR="$temp_dir/backup"
  seed_installation "$KVS_INSTALL_DIR"

  # Diverged history: the pull fails, a fresh clone works.
  git() {
    local target="${*: -1}"

    case ${1:-} in
      pull) return 1 ;;
      clone)
        mkdir -p "$target/.git" "$target/docker"
        printf 'fresh\n' >"$target/docker/docker-compose.yml"
        printf 'DOMAIN=example.com\n' >"$target/docker/.env.example"
        printf '#!/bin/bash\necho setup-ran\n' >"$target/docker/setup.sh"
        ;;
    esac
    return 0
  }

  (dockerInstall) >"$temp_dir/out" 2>&1
  status=$?

  [[ $status -eq 0 ]] || fail "dockerInstall failed after a successful re-clone (status $status)" || return 1
  [[ "$(cat "$KVS_INSTALL_DIR/docker/docker-compose.yml")" == "fresh" ]] ||
    fail "the re-clone did not replace the installed copy" || return 1
  grep -q 'MARIADB_PASSWORD=secret' "$KVS_INSTALL_DIR/docker/.env" ||
    fail "the re-clone lost the .env of the site" || return 1
  [[ -f "$KVS_INSTALL_DIR/docker/kvs-archive/KVS_7.0.2_[example.com].zip" ]] ||
    fail "the re-clone lost the KVS archive" || return 1
  grep -q 'setup-ran' "$temp_dir/out" || fail "the Docker setup did not run after the re-clone" || return 1
  [[ ! -e "$KVS_INSTALL_DIR.clone" ]] || fail "the staging directory was left behind" || return 1
  [[ ! -e "$KVS_BACKUP_DIR" ]] || fail "the temporary backup was not removed after the restore" || return 1
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
run_test "unreachable remote keeps the installed copy" test_unreachable_remote_keeps_the_installed_copy || failures=$((failures + 1))
run_test "successful re-clone replaces the copy and restores user data" test_successful_reclone_replaces_the_copy_and_restores_user_data || failures=$((failures + 1))

if ((failures != 0)); then
  echo "$failures test(s) failed" >&2
  exit 1
fi

echo "All Docker re-clone tests passed"

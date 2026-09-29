#!/bin/bash
# shellcheck disable=SC1091,SC2034,SC2154,SC2329
# A second run of kvs-install.sh over a working Docker site pulls the
# repository in /opt/kvs. When the pull fails on a branch rewritten
# upstream, the copy moves to the branch as the repository has it and keeps
# the files the setup wrote there; only a copy that cannot fetch at all is
# cloned again. The old copy must only go once the new clone exists: with
# GitHub unreachable the pull, the fetch and the clone fail, and the site
# keeps its Compose files, its .env and its staged import instead of
# losing the whole directory.

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

  # GitHub unreachable: no pull, no fetch and no fresh clone can succeed.
  git() {
    case ${1:-} in
      pull | fetch) return 1 ;;
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

  # A copy whose repository no longer fetches (a damaged .git, an origin
  # that moved) while GitHub answers: a fresh clone works.
  git() {
    local target="${*: -1}"

    case ${1:-} in
      pull | fetch) return 1 ;;
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

# A repository standing in for GitHub, with the ignore rules of this one:
# what the setup writes in the copy is ignored or untracked there as well.
make_upstream() {
  local upstream="$1"
  local branch="$2"

  mkdir -p "$upstream/docker"
  cp "$REPO_DIR/.gitignore" "$upstream/.gitignore"
  cp "$REPO_DIR/docker/.gitignore" "$upstream/docker/.gitignore"
  printf 'services: {}\n' >"$upstream/docker/docker-compose.yml"
  printf 'DOMAIN=example.com\n' >"$upstream/docker/.env.example"
  printf '#!/bin/bash\necho setup-ran\n' >"$upstream/docker/setup.sh"
  git -C "$upstream" init -q -b "$branch" &&
    git -C "$upstream" add -A &&
    git -C "$upstream" commit -q -m first
}

# rewritten_branch_case <temp dir> <branch> <KVS_INSTALL_BRANCH>
rewritten_branch_case() {
  local temp_dir="$1"
  local branch="$2"
  local upstream="$temp_dir/upstream"
  local status
  local kept

  export KVS_INSTALL_BRANCH="$3"
  export KVS_INSTALL_DIR="$temp_dir/install"
  export KVS_BACKUP_DIR="$temp_dir/backup"
  make_upstream "$upstream" "$branch" || return 1
  git clone -q --branch "$branch" "$upstream" "$KVS_INSTALL_DIR" || return 1

  # What the first pass of a migration leaves in the copy.
  mkdir -p "$KVS_INSTALL_DIR/docker/kvs-archive" "$KVS_INSTALL_DIR/docker/import" "$KVS_INSTALL_DIR/logs"
  printf 'MARIADB_PASSWORD=secret\n' >"$KVS_INSTALL_DIR/docker/.env"
  printf 'archive\n' >"$KVS_INSTALL_DIR/docker/kvs-archive/KVS_7.0.2_[example.com].zip"
  printf 'ssh://root@old.example.com:22/var/www/website\n' >"$KVS_INSTALL_DIR/docker/import/example.com.source"
  printf 'server {}\n' >"$KVS_INSTALL_DIR/docker/import/example.com.old-nginx.conf"
  printf 'rows\n' >"$KVS_INSTALL_DIR/logs/import-rows.txt"
  printf 'services: {}\n' >"$KVS_INSTALL_DIR/docker/docker-compose.override.yml"
  # And an edit of a tracked file, which the repository version replaces.
  printf 'DOMAIN=edited.example.com\n' >"$KVS_INSTALL_DIR/docker/.env.example"

  # The branch is squashed and force pushed: the copy can no longer pull.
  printf 'services: {kvs: {}}\n' >"$upstream/docker/docker-compose.yml"
  git -C "$upstream" commit -q -a --amend -m squashed || return 1

  # A new clone takes the same repository instead of GitHub.
  git() {
    if [[ ${1:-} == clone ]]; then
      echo clone >>"$temp_dir/clones"
      command git clone -q --branch "$branch" "$upstream" "${*: -1}"
      return
    fi
    command git "$@"
  }

  (dockerInstall) >"$temp_dir/out" 2>&1
  status=$?
  unset -f git

  [[ $status -eq 0 ]] || fail "dockerInstall failed on the $branch branch (status $status)" || return 1
  grep -q 'setup-ran' "$temp_dir/out" || fail "the Docker setup did not run" || return 1
  [[ "$(git -C "$KVS_INSTALL_DIR" rev-parse HEAD)" == "$(git -C "$upstream" rev-parse HEAD)" ]] ||
    fail "the copy is not on the $branch branch as the repository has it" || return 1
  [[ "$(git -C "$KVS_INSTALL_DIR" branch --show-current)" == "$branch" ]] ||
    fail "the copy left the $branch branch" || return 1
  for kept in docker/import/example.com.source docker/import/example.com.old-nginx.conf \
    logs/import-rows.txt docker/docker-compose.override.yml; do
    [[ -f "$KVS_INSTALL_DIR/$kept" ]] || fail "the update of the $branch branch lost $kept" || return 1
  done
  grep -q 'MARIADB_PASSWORD=secret' "$KVS_INSTALL_DIR/docker/.env" ||
    fail "the update lost the .env of the site" || return 1
  [[ -f "$KVS_INSTALL_DIR/docker/kvs-archive/KVS_7.0.2_[example.com].zip" ]] ||
    fail "the update lost the KVS archive" || return 1
  grep -q 'DOMAIN=example.com' "$KVS_INSTALL_DIR/docker/.env.example" ||
    fail "the local edit of a tracked file stayed" || return 1
  grep -A1 'Local changes to these files' "$temp_dir/out" | grep -q 'docker/.env.example' ||
    fail "the edited file was replaced without being named" || return 1
  [[ ! -e "$temp_dir/clones" ]] || fail "the copy was cloned again although the repository answered" || return 1
  [[ ! -e "$KVS_BACKUP_DIR" ]] || fail "the temporary backup was left behind" || return 1
}

# The branch was rewritten upstream (squashed, force pushed): the pull fails
# although the repository answers. The copy moves to the branch as the
# repository now has it and keeps what the setup wrote there, where a new
# clone kept the .env and the archive only. Without the marker naming where
# the site came from, the second pass of a migration refused the site
# directory as not empty.
test_rewritten_branch_keeps_the_files_the_setup_wrote() {
  local temp_dir
  temp_dir=$(mktemp -d)
  trap 'rm -rf "$temp_dir"' RETURN
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
  export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

  mkdir -p "$temp_dir/main" "$temp_dir/branch"
  (rewritten_branch_case "$temp_dir/main" main "") || return 1
  (rewritten_branch_case "$temp_dir/branch" import-without-archive import-without-archive) || return 1
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
run_test "rewritten branch keeps the files the setup wrote" test_rewritten_branch_keeps_the_files_the_setup_wrote || failures=$((failures + 1))

if ((failures != 0)); then
  echo "$failures test(s) failed" >&2
  exit 1
fi

echo "All Docker re-clone tests passed"

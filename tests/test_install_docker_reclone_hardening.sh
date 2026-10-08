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

# kvsctl backup and kvsctl restore need no adoption: on a stack kvsctl does
# not manage, they leave the archives in backups/ and the logs and the lock
# in kvsctl/, and no state. The installer updates such a stack like any
# other.
seed_kvsctl_data() {
  local install_dir="$1"

  mkdir -p "$install_dir/backups" "$install_dir/kvsctl/logs"
  printf 'dump\n' >"$install_dir/backups/backup-unknown-20261007-010000.tar"
  printf 'backup\n' >"$install_dir/kvsctl/logs/20261007-010000-backup.log"
  : >"$install_dir/kvsctl/lock"
}

# The identity of each file kvsctl wrote, inode and content: a file moved
# keeps its inode, a copy gets a new one.
kvsctl_data_identity() {
  local install_dir="$1"
  local file

  for file in backups/backup-unknown-20261007-010000.tar kvsctl/logs/20261007-010000-backup.log kvsctl/lock; do
    [[ -f "$install_dir/$file" ]] || return 1
    printf '%s %s %s\n' "$file" "$(stat -c %i "$install_dir/$file")" "$(cksum <"$install_dir/$file")"
  done
}

# A git that cannot pull or fetch, as for a copy whose repository is
# damaged or that is no checkout at all, and whose clone works.
git_that_clones_only() {
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

# A copy cloned again keeps what kvsctl wrote there, as it keeps the .env
# and the archive. A backup is as large as the database: the files are
# moved, never copied, and nothing is left beside the installation. A path
# given with a trailing slash names the same installation: the new clone
# and the files of kvsctl wait beside it, not inside the directory the clone
# replaces.
test_reclone_keeps_the_backups_and_logs_of_kvsctl() {
  local temp_dir
  local status
  local layout
  local install_dir
  local before
  temp_dir=$(mktemp -d)
  trap 'rm -rf "$temp_dir"' RETURN

  git() { git_that_clones_only "$@"; }

  for layout in checkout plain slash; do
    install_dir="$temp_dir/$layout/install"
    export KVS_INSTALL_DIR="$install_dir"
    [[ $layout != slash ]] || KVS_INSTALL_DIR="$install_dir/"
    export KVS_BACKUP_DIR="$temp_dir/$layout/backup"
    seed_installation "$install_dir"
    [[ $layout == checkout ]] || rm -rf "$install_dir/.git"
    seed_kvsctl_data "$install_dir"
    before=$(kvsctl_data_identity "$install_dir")

    (
      dockerInstall
      status=$?
      trap -p INT HUP TERM >"$temp_dir/traps"
      exit "$status"
    ) >"$temp_dir/out" 2>&1
    status=$?

    [[ $status -eq 0 ]] || fail "dockerInstall failed ($layout, status $status): $(cat "$temp_dir/out")" || return 1
    [[ "$(cat "$install_dir/docker/docker-compose.yml")" == "fresh" ]] ||
      fail "the copy was not cloned again ($layout)" || return 1
    [[ ! -s "$temp_dir/traps" ]] || fail "the swap left its traps behind ($layout): $(cat "$temp_dir/traps")" || return 1
    [[ "$(kvsctl_data_identity "$install_dir")" == "$before" ]] ||
      fail "the new clone lost or copied what kvsctl wrote ($layout): $(find "$install_dir" -path '*/.git' -prune -o -print)" || return 1
    grep -q 'MARIADB_PASSWORD=secret' "$install_dir/docker/.env" ||
      fail "the new clone lost the .env of the site ($layout)" || return 1
    grep -Fq 'Kept the files of kvsctl in the new copy' "$temp_dir/out" ||
      fail "the installer did not say it kept the files of kvsctl ($layout): $(cat "$temp_dir/out")" || return 1
    [[ -z "$(find "$temp_dir/$layout" -mindepth 1 -maxdepth 1 -name 'install.*')" ]] ||
      fail "something was left beside the installation ($layout): $(ls -A "$temp_dir/$layout")" || return 1
    [[ -z "$(find "$install_dir" -mindepth 1 -maxdepth 1 -name '.[ck]*')" ]] ||
      fail "something was left inside the installation ($layout): $(ls -A "$install_dir")" || return 1
  done
}

# Once the new copy is in place, what kvsctl wrote and cannot go back into
# it stays in the directory that holds it, which the installer names, and
# the rest goes back. The update goes on: neither the setup nor the site
# needs those files.
test_kvsctl_data_that_cannot_move_back_is_named() {
  local temp_dir
  local status
  local install_dir
  local holding
  local backup_inode
  local log_inode
  temp_dir=$(mktemp -d)
  trap 'rm -rf "$temp_dir"' RETURN

  git() { git_that_clones_only "$@"; }

  install_dir="$temp_dir/install"
  export KVS_INSTALL_DIR="$install_dir"
  export KVS_BACKUP_DIR="$temp_dir/backup"
  seed_installation "$install_dir"
  rm -rf "$install_dir/.git"
  seed_kvsctl_data "$install_dir"
  backup_inode=$(stat -c %i "$install_dir/backups/backup-unknown-20261007-010000.tar")
  log_inode=$(stat -c %i "$install_dir/kvsctl/logs/20261007-010000-backup.log")
  # kvsctl/, the first to go back, does not go back into the new clone.
  mv() {
    [[ ${*: -1} != "$install_dir/kvsctl" ]] || return 1
    command mv "$@"
  }

  (dockerInstall) >"$temp_dir/out" 2>&1
  status=$?
  unset -f mv

  [[ $status -eq 0 ]] || fail "the update stopped although the new copy was in place (status $status): $(cat "$temp_dir/out")" || return 1
  [[ "$(cat "$install_dir/docker/docker-compose.yml")" == "fresh" ]] || fail "the copy was not cloned again" || return 1
  grep -q 'MARIADB_PASSWORD=secret' "$install_dir/docker/.env" || fail "the new clone lost the .env of the site" || return 1
  grep -q 'setup-ran' "$temp_dir/out" || fail "the Docker setup did not run: $(cat "$temp_dir/out")" || return 1
  [[ "$(stat -c %i "$install_dir/backups/backup-unknown-20261007-010000.tar" 2>/dev/null)" == "$backup_inode" ]] ||
    fail "backups/ did not go back into the new clone: $(find "$temp_dir" -path '*/.git' -prune -o -print)" || return 1
  holding=$(find "$temp_dir" -mindepth 1 -maxdepth 1 -name 'install.kvsctl.*')
  [[ -n "$holding" && "$(stat -c %i "$holding/kvsctl/logs/20261007-010000-backup.log" 2>/dev/null)" == "$log_inode" ]] ||
    fail "the logs of kvsctl are not kept, moved, beside the installation: $(find "$temp_dir" -name '*.log')" || return 1
  grep -Fq "$holding/kvsctl could not go back to $install_dir/kvsctl: move it there" "$temp_dir/out" ||
    fail "the directory that holds the logs of kvsctl is not named: $(cat "$temp_dir/out")" || return 1
  ! grep -Fq 'No new copy was installed' "$temp_dir/out" ||
    fail "the installer said no new copy was installed: $(cat "$temp_dir/out")" || return 1
}

# What cannot be renamed into the new clone stops the swap before anything
# is removed: a directory on another filesystem (a disk mounted there) would
# be copied, and a rename that fails puts back what already moved.
test_kvsctl_data_that_cannot_move_stops_the_reclone() {
  local temp_dir
  local status
  local kind
  local before
  temp_dir=$(mktemp -d)
  trap 'rm -rf "$temp_dir"' RETURN

  git() { git_that_clones_only "$@"; }

  for kind in mounted unmovable; do
    export KVS_INSTALL_DIR="$temp_dir/$kind/install"
    export KVS_BACKUP_DIR="$temp_dir/$kind/backup"
    seed_installation "$KVS_INSTALL_DIR"
    rm -rf "$KVS_INSTALL_DIR/.git"
    seed_kvsctl_data "$KVS_INSTALL_DIR"
    before=$(kvsctl_data_identity "$KVS_INSTALL_DIR")
    if [[ $kind == mounted ]]; then
      # backups/ is the mount point of another filesystem.
      stat() {
        if [[ ${*: -1} == "$KVS_INSTALL_DIR/backups" ]]; then
          echo 4242
          return 0
        fi
        command stat "$@"
      }
    else
      mv() {
        [[ ${*: -2:1} != "$KVS_INSTALL_DIR/backups" ]] || return 1
        command mv "$@"
      }
    fi

    (dockerInstall) >"$temp_dir/out" 2>&1
    status=$?
    unset -f stat mv

    [[ $status -ne 0 ]] || fail "dockerInstall swapped the copy although backups/ could not move ($kind)" || return 1
    grep -Fq "$KVS_INSTALL_DIR/backups" "$temp_dir/out" ||
      fail "the refusal does not name backups/ ($kind): $(cat "$temp_dir/out")" || return 1
    [[ "$(cat "$KVS_INSTALL_DIR/docker/docker-compose.yml")" == "services: {}" ]] ||
      fail "the installed copy was replaced ($kind)" || return 1
    [[ "$(kvsctl_data_identity "$KVS_INSTALL_DIR")" == "$before" ]] ||
      fail "the files of kvsctl are not where they were ($kind): $(find "$temp_dir/$kind")" || return 1
    [[ -z "$(find "$temp_dir/$kind" -mindepth 1 -maxdepth 1 -name 'install.*')" ]] ||
      fail "something was left beside the installation ($kind): $(ls -A "$temp_dir/$kind")" || return 1
    [[ $kind != mounted ]] || grep -Fq 'another filesystem' "$temp_dir/out" ||
      fail "the refusal does not say why backups/ cannot move: $(cat "$temp_dir/out")" || return 1
  done
}

# A swap that fails once the files of kvsctl are set aside puts them back
# into the copy it leaves, where they were.
test_failed_swap_puts_the_kvsctl_data_back() {
  local temp_dir
  local status
  local install_dir
  local before
  temp_dir=$(mktemp -d)
  trap 'rm -rf "$temp_dir"' RETURN

  git() { git_that_clones_only "$@"; }

  install_dir="$temp_dir/install"
  export KVS_INSTALL_DIR="$install_dir"
  export KVS_BACKUP_DIR="$temp_dir/backup"
  seed_installation "$install_dir"
  rm -rf "$install_dir/.git"
  seed_kvsctl_data "$install_dir"
  before=$(kvsctl_data_identity "$install_dir")
  # The installed copy cannot be removed: a file in it is immutable, say.
  rm() {
    [[ ${*: -1} != "$install_dir" ]] || return 1
    command rm "$@"
  }

  (dockerInstall) >"$temp_dir/out" 2>&1
  status=$?
  unset -f rm

  [[ $status -ne 0 ]] || fail "dockerInstall went on although the copy could not be replaced" || return 1
  [[ "$(cat "$install_dir/docker/docker-compose.yml")" == "services: {}" ]] ||
    fail "the installed copy was replaced" || return 1
  [[ "$(kvsctl_data_identity "$install_dir")" == "$before" ]] ||
    fail "the files of kvsctl did not go back into the installed copy: $(find "$temp_dir" -path '*/.git' -prune -o -print)" || return 1
  [[ -z "$(find "$temp_dir" -mindepth 1 -maxdepth 1 -name 'install.kvsctl.*')" ]] ||
    fail "the files of kvsctl were left beside the installation: $(ls -A "$temp_dir")" || return 1
  grep -Fq 'No new copy was installed' "$temp_dir/out" ||
    fail "the installer did not say no new copy was installed: $(cat "$temp_dir/out")" || return 1
}

# An interrupt between the set-aside and the move back (Ctrl-C, a closed
# terminal, a kill) first moves the files of kvsctl back into whatever copy
# stands there, then stops the installer with the status of the signal:
# the old copy while they move aside (Ctrl-C reaches the subshell that
# moves them too) and before it is removed, an installation directory that
# holds them alone once it is gone, the new copy while they go back. The
# .env and the archive stay in the installation whatever the moment: the
# new copy takes them before it replaces the old one (an interrupt as they
# go into it leaves the old copy), and once the old copy is gone they go
# back into the installation directory, the backup named. The installer
# run again without that backup (under /tmp by default, which a reboot may
# empty) keeps them instead of writing a new .env.
test_interrupted_swap_moves_the_kvsctl_data_back() {
  local temp_dir
  local status
  local moment
  local expected
  local install_dir
  local before
  temp_dir=$(mktemp -d)
  trap 'rm -rf "$temp_dir"' RETURN

  git() { git_that_clones_only "$@"; }

  for moment in restoring moving-aside set-aside removed moving-back; do
    install_dir="$temp_dir/$moment/install"
    export KVS_INSTALL_DIR="$install_dir"
    export KVS_BACKUP_DIR="$temp_dir/$moment/backup"
    seed_installation "$install_dir"
    rm -rf "$install_dir/.git"
    seed_kvsctl_data "$install_dir"
    before=$(kvsctl_data_identity "$install_dir")
    case $moment in
      restoring)
        expected=130
        cp() {
          [[ ${*: -2:1} != "$KVS_BACKUP_DIR/.env" ]] || kill -INT "$installer_pid"
          command cp "$@"
        }
        ;;
      moving-aside)
        expected=130
        mv() {
          command mv "$@" || return
          [[ ${*: -1} != "$install_dir".kvsctl.*/backups ]] || {
            kill -INT "$installer_pid"
            kill -INT "$BASHPID"
          }
        }
        ;;
      set-aside)
        expected=143
        rm() {
          [[ ${*: -1} != "$install_dir" ]] || kill -TERM "$installer_pid"
          command rm "$@"
        }
        ;;
      removed)
        expected=129
        rm() {
          command rm "$@" || return
          [[ ${*: -1} != "$install_dir" ]] || kill -HUP "$installer_pid"
        }
        ;;
      moving-back)
        expected=130
        mv() {
          command mv "$@" || return
          [[ ${*: -1} != "$install_dir/kvsctl" ]] || kill -INT "$installer_pid"
        }
        ;;
    esac

    (installer_pid=$BASHPID && dockerInstall) >"$temp_dir/out" 2>&1
    status=$?
    unset -f mv rm cp

    [[ $status -eq $expected ]] ||
      fail "the installer did not stop with status $expected ($moment, status $status): $(cat "$temp_dir/out")" || return 1
    [[ "$(kvsctl_data_identity "$install_dir")" == "$before" ]] ||
      fail "the files of kvsctl are not back in the installation ($moment): $(find "$temp_dir/$moment" -path '*/.git' -prune -o -print)" || return 1
    [[ -z "$(find "$temp_dir/$moment" -mindepth 1 -maxdepth 1 -name 'install.kvsctl.*')" ]] ||
      fail "the files of kvsctl were left beside the installation ($moment): $(ls -A "$temp_dir/$moment")" || return 1
    grep -qx 'MARIADB_PASSWORD=secret' "$install_dir/docker/.env" 2>/dev/null ||
      fail "the installation lost its .env ($moment): $(find "$temp_dir/$moment" -path '*/.git' -prune -o -print)" || return 1
    [[ -f "$install_dir/docker/kvs-archive/KVS_7.0.2_[example.com].zip" ]] ||
      fail "the installation lost its archive ($moment): $(find "$temp_dir/$moment" -path '*/.git' -prune -o -print)" || return 1
    ! grep -q 'setup-ran' "$temp_dir/out" || fail "the setup ran after the interrupt ($moment)" || return 1
    if [[ $moment != restoring ]]; then
      grep -Fq "Moved the files of kvsctl back into $install_dir from $install_dir.kvsctl." "$temp_dir/out" ||
        fail "the installer did not say it moved them back ($moment): $(cat "$temp_dir/out")" || return 1
      grep -Fq "User data also remains in $KVS_BACKUP_DIR" "$temp_dir/out" ||
        fail "the installer did not name the backup of the .env and the archive ($moment): $(cat "$temp_dir/out")" || return 1
    fi
    [[ $moment == removed ]] || ! grep -Fq 'Put back into' "$temp_dir/out" ||
      fail "the installer put back a .env or an archive the installation still had ($moment): $(cat "$temp_dir/out")" || return 1
    case $moment in
      restoring | moving-aside | set-aside)
        [[ "$(cat "$install_dir/docker/docker-compose.yml")" == "services: {}" ]] ||
          fail "the old copy is not what stands in the installation ($moment)" || return 1
        ;;
      removed)
        [[ "$(find "$install_dir" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort | paste -sd' ')" == "backups docker kvsctl" ]] ||
          fail "the installation directory holds more than the files of kvsctl and the user data: $(ls -A "$install_dir")" || return 1
        [[ "$(find "$install_dir/docker" -mindepth 1 -printf '%P\n' | sort | paste -sd' ')" == ".env kvs-archive kvs-archive/KVS_7.0.2_[example.com].zip" ]] ||
          fail "the docker directory holds more than the .env and the archive: $(find "$install_dir/docker")" || return 1
        grep -Fq "Put back into $install_dir/docker what the update had saved in $KVS_BACKUP_DIR: .env kvs-archive/KVS_7.0.2_[example.com].zip" "$temp_dir/out" ||
          fail "the installer did not say it put the .env and the archive back: $(cat "$temp_dir/out")" || return 1
        ;;
      moving-back)
        [[ "$(cat "$install_dir/docker/docker-compose.yml")" == "fresh" ]] ||
          fail "the new copy is not what stands in the installation ($moment)" || return 1
        ;;
    esac

    export KVS_BACKUP_DIR="$temp_dir/$moment/backup-again"
    (dockerInstall) >"$temp_dir/out" 2>&1
    status=$?
    [[ $status -eq 0 ]] ||
      fail "the installer run again failed ($moment, status $status): $(cat "$temp_dir/out")" || return 1
    grep -q 'setup-ran' "$temp_dir/out" || fail "the setup did not run again ($moment): $(cat "$temp_dir/out")" || return 1
    grep -qx 'MARIADB_PASSWORD=secret' "$install_dir/docker/.env" ||
      fail "the installer run again lost the .env of the site ($moment): $(cat "$install_dir/docker/.env")" || return 1
    [[ -f "$install_dir/docker/kvs-archive/KVS_7.0.2_[example.com].zip" ]] ||
      fail "the installer run again lost the archive ($moment)" || return 1
    [[ "$(kvsctl_data_identity "$install_dir")" == "$before" ]] ||
      fail "the installer run again lost the files of kvsctl ($moment): $(find "$temp_dir/$moment" -path '*/.git' -prune -o -print)" || return 1
  done
}

# The installer writes through a tee (initialize_runtime_output). Ctrl-C, a
# closed terminal or a kill reaches the whole foreground job, the tee with
# it. The tee ignores Ctrl-C (tee -i), so the files of kvsctl come back and
# the installer says so on the screen and in the log before it stops; a
# closed terminal or a kill ends the tee, and the report of the removal the
# signal stopped then meets a closed pipe: the files still come back. Job
# control gives the run a process group of its own, as a terminal does, and
# the removal of the old copy waits five seconds for the signal.
test_a_signal_to_the_whole_run_moves_the_kvsctl_data_back() {
  local temp_dir
  local status
  local signal
  local install_dir
  local before
  local run
  local attempt
  local said
  temp_dir=$(mktemp -d)
  trap 'rm -rf "$temp_dir"' RETURN

  git() { git_that_clones_only "$@"; }
  rm() {
    if [[ ${*: -1} == "$KVS_INSTALL_DIR" ]]; then
      : >"$KVS_INSTALL_DIR/../removing"
      sleep 5
    fi
    command rm "$@"
  }

  for signal in INT HUP TERM; do
    install_dir="$temp_dir/$signal/install"
    export KVS_INSTALL_DIR="$install_dir"
    export KVS_BACKUP_DIR="$temp_dir/$signal/backup"
    seed_installation "$install_dir"
    command rm -rf "$install_dir/.git"
    seed_kvsctl_data "$install_dir"
    before=$(kvsctl_data_identity "$install_dir")

    set -m
    (
      TERM=dumb initialize_runtime_output "$temp_dir/$signal/log"
      dockerInstall
    ) >"$temp_dir/out" 2>&1 &
    run=$!
    set +m
    for ((attempt = 0; attempt < 100; attempt++)); do
      [[ ! -e "$temp_dir/$signal/removing" ]] || break
      sleep 0.05
    done
    kill -s "$signal" -- "-$run"
    status=0
    wait "$run" 2>/dev/null || status=$?
    command rm -f "$temp_dir/$signal/removing"

    [[ $status -eq $((128 + $(kill -l "$signal"))) ]] ||
      fail "$signal did not stop the installer with its status (status $status): $(cat "$temp_dir/$signal/log")" || return 1
    [[ "$(kvsctl_data_identity "$install_dir")" == "$before" ]] ||
      fail "the files of kvsctl are not back in the installation ($signal): $(find "$temp_dir/$signal" -path '*/.git' -prune -o -print)" || return 1
    [[ -z "$(find "$temp_dir/$signal" -mindepth 1 -maxdepth 1 -name 'install.kvsctl.*')" ]] ||
      fail "the files of kvsctl were left beside the installation ($signal): $(ls -A "$temp_dir/$signal")" || return 1
    [[ $signal == INT ]] || continue
    # The tee writes what the installer said once its input is closed.
    said="Moved the files of kvsctl back into $install_dir from $install_dir.kvsctl."
    for ((attempt = 0; attempt < 100; attempt++)); do
      grep -Fq "$said" "$temp_dir/$signal/log" && grep -Fq "$said" "$temp_dir/out" && break
      sleep 0.05
    done
    grep -Fq "$said" "$temp_dir/$signal/log" ||
      fail "Ctrl-C kept the installer from saying it moved the files of kvsctl back, in the log: $(cat "$temp_dir/$signal/log")" || return 1
    grep -Fq "$said" "$temp_dir/out" ||
      fail "Ctrl-C kept the installer from saying it moved the files of kvsctl back, on the screen: $(cat "$temp_dir/out")" || return 1
  done
}

# Ctrl-C reaches the tee of the log too. Bash 5.3 starts a coprocess with
# SIGINT ignored, where 5.2 leaves it at its default, and under job control
# neither ignores it: the tee has to ignore it itself, whatever the bash,
# or what the installer prints once interrupted reaches neither the screen
# nor the log. Job control also gives the coprocess a process group of its
# own, which takes the signal alone here.
test_the_log_tee_ignores_ctrl_c() {
  local temp_dir
  local attempt
  temp_dir=$(mktemp -d)
  trap 'rm -rf "$temp_dir"' RETURN

  (
    set -m
    TERM=dumb initialize_runtime_output "$temp_dir/log"
    set +m
    echo before
    for ((attempt = 0; attempt < 100; attempt++)); do
      grep -qx before "$temp_dir/log" && break
      sleep 0.05
    done
    kill -INT -- "-$mytee_PID"
    sleep 0.2
    echo after
  ) >"$temp_dir/out" 2>&1
  for ((attempt = 0; attempt < 100; attempt++)); do
    grep -qx after "$temp_dir/log" && grep -qx after "$temp_dir/out" && break
    sleep 0.05
  done
  grep -qx before "$temp_dir/log" || fail "the tee of the log never wrote: $(cat "$temp_dir/log")" || return 1
  grep -qx after "$temp_dir/log" || fail "Ctrl-C ended the tee of the log: $(cat "$temp_dir/log")" || return 1
  grep -qx after "$temp_dir/out" || fail "Ctrl-C ended the tee of the screen: $(cat "$temp_dir/out")" || return 1
}

# An update stopped outright (kill -9, a power cut) runs no trap, and the
# files of kvsctl stay beside the installation, where kvsctl does not look.
# The next run of the installer moves them back before anything else,
# whatever it then does: an update by git, a new clone, a clone where the
# old copy was already removed (its .env and archive waiting in
# KVS_BACKUP_DIR). One the installation has again stays aside, named, and
# the update goes on. A holding directory left empty (the update stopped
# as it made it) goes without a word.
test_a_later_run_moves_back_what_an_update_left_aside() {
  local temp_dir
  local status
  local layout
  local install_dir
  local holding
  local before
  local held
  local log_inode
  temp_dir=$(mktemp -d)
  trap 'rm -rf "$temp_dir"' RETURN

  for layout in checkout plain gone again empty; do
    install_dir="$temp_dir/$layout/install"
    holding="$install_dir.kvsctl.Ab12Cd"
    export KVS_INSTALL_DIR="$install_dir"
    export KVS_BACKUP_DIR="$temp_dir/$layout/backup"
    seed_installation "$install_dir"
    printf '#!/bin/bash\necho setup-ran\n' >"$install_dir/docker/setup.sh"
    seed_kvsctl_data "$install_dir"
    before=$(kvsctl_data_identity "$install_dir")
    log_inode=$(stat -c %i "$install_dir/kvsctl/logs/20261007-010000-backup.log")
    mkdir "$holding"
    [[ $layout == empty ]] || mv "$install_dir/kvsctl" "$install_dir/backups" "$holding/"
    # The repository answers: a checkout pulls, a plain copy is cloned again.
    git() {
      [[ ${1:-} != clone ]] || git_that_clones_only "$@"
    }
    case $layout in
      plain) rm -rf "$install_dir/.git" ;;
      gone)
        mkdir -p "$KVS_BACKUP_DIR"
        mv "$install_dir/docker/.env" "$install_dir/docker/kvs-archive" "$KVS_BACKUP_DIR/"
        rm -rf "$install_dir"
        ;;
      again)
        held=$(stat -c %i "$holding/backups/backup-unknown-20261007-010000.tar")
        mkdir "$install_dir/backups"
        printf 'newer\n' >"$install_dir/backups/backup-unknown-20261008-010000.tar"
        ;;
    esac

    (dockerInstall) >"$temp_dir/out" 2>&1
    status=$?

    [[ $status -eq 0 ]] || fail "dockerInstall failed ($layout, status $status): $(cat "$temp_dir/out")" || return 1
    grep -q 'setup-ran' "$temp_dir/out" || fail "the Docker setup did not run ($layout): $(cat "$temp_dir/out")" || return 1
    grep -q 'MARIADB_PASSWORD=secret' "$install_dir/docker/.env" || fail "the update lost the .env of the site ($layout)" || return 1
    if [[ $layout == again ]]; then
      [[ "$(stat -c %i "$install_dir/kvsctl/logs/20261007-010000-backup.log" 2>/dev/null)" == "$log_inode" ]] ||
        fail "kvsctl/ did not come back beside a backups/ that could not: $(find "$temp_dir/$layout" -path '*/.git' -prune -o -print)" || return 1
      [[ "$(ls -A "$install_dir/backups")" == backup-unknown-20261008-010000.tar ]] ||
        fail "the backups/ of the installation changed: $(ls -A "$install_dir/backups")" || return 1
      [[ "$(stat -c %i "$holding/backups/backup-unknown-20261007-010000.tar" 2>/dev/null)" == "$held" ]] ||
        fail "the backups/ set aside did not stay where it was: $(find "$temp_dir/$layout" -path '*/.git' -prune -o -print)" || return 1
      grep -Fq "$holding/backups could not go back: $install_dir/backups exists again" "$temp_dir/out" ||
        fail "the backups/ left aside is not named: $(cat "$temp_dir/out")" || return 1
      continue
    fi
    [[ "$(kvsctl_data_identity "$install_dir")" == "$before" ]] ||
      fail "the files of kvsctl are not back in the installation ($layout): $(find "$temp_dir/$layout" -path '*/.git' -prune -o -print)" || return 1
    [[ -z "$(find "$temp_dir/$layout" -mindepth 1 -maxdepth 1 -name 'install.*')" ]] ||
      fail "something was left beside the installation ($layout): $(ls -A "$temp_dir/$layout")" || return 1
    if [[ $layout == empty ]]; then
      ! grep -Fq 'Moved the files of kvsctl back' "$temp_dir/out" ||
        fail "the installer said it moved back files from an empty directory: $(cat "$temp_dir/out")" || return 1
      continue
    fi
    grep -Fq "Moved the files of kvsctl back into $install_dir from $holding" "$temp_dir/out" ||
      fail "the installer did not say it moved them back ($layout): $(cat "$temp_dir/out")" || return 1
  done
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
  # Executable in the repository, as this one tracks it.
  chmod 0755 "$upstream/docker/setup.sh"
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
  seed_kvsctl_data "$KVS_INSTALL_DIR"
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
    logs/import-rows.txt docker/docker-compose.override.yml \
    backups/backup-unknown-20261007-010000.tar kvsctl/logs/20261007-010000-backup.log kvsctl/lock; do
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
  # Everything the installation keeps there is ignored, the backups and the
  # logs of kvsctl and the logs of the setup included, so git status of the
  # copy names nothing. The rules hold at the top only: cli/cmd/kvsctl/ is
  # code of the repository.
  [[ -z "$(git -C "$KVS_INSTALL_DIR" status --porcelain --untracked-files=all)" ]] ||
    fail "git status of the updated copy is not clean: $(git -C "$KVS_INSTALL_DIR" status --porcelain --untracked-files=all)" || return 1
  ! git -C "$upstream" check-ignore -q --no-index cli/cmd/kvsctl/main.go ||
    fail "the ignore rules of kvsctl also ignore cli/cmd/kvsctl/" || return 1
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

# An installation kvsctl adopted or upgraded runs the files and the images
# of a release. The installer must refuse it before anything changes: no
# git command, no Docker install, no backup, the files, the state and the
# backups of kvsctl in place, and the way to upgrade named. A copy that is
# not a git checkout (which the installer would clone again) is refused the
# same way. Either file of kvsctl marks it, as for docker/setup.sh: the
# state alone (adopted, no release installed yet) or the release override
# alone.
test_kvsctl_managed_install_is_refused() {
  local temp_dir
  local status
  local layout
  local files
  local marker
  temp_dir=$(mktemp -d)
  trap 'rm -rf "$temp_dir"' RETURN

  git() {
    echo "git $*" >>"$temp_dir/calls"
    return 0
  }
  curl() {
    echo "curl $*" >>"$temp_dir/calls"
    return 0
  }

  for layout in checkout plain; do
    for files in release adopted override; do
      export KVS_INSTALL_DIR="$temp_dir/$layout-$files/install"
      export KVS_BACKUP_DIR="$temp_dir/$layout-$files/backup"
      seed_installation "$KVS_INSTALL_DIR"
      [[ $layout == checkout ]] || rm -rf "$KVS_INSTALL_DIR/.git"
      mkdir -p "$KVS_INSTALL_DIR/kvsctl" "$KVS_INSTALL_DIR/backups"
      printf 'backup\n' >"$KVS_INSTALL_DIR/backups/kvs-26.10.0.tar"
      if [[ $files != override ]]; then
        printf '{"current":"26.10.0"}\n' >"$KVS_INSTALL_DIR/kvsctl/state.json"
      fi
      if [[ $files != adopted ]]; then
        printf 'services: {}\n' >"$KVS_INSTALL_DIR/docker/docker-compose.release.yml"
      fi

      (dockerInstall) >"$temp_dir/out" 2>&1
      status=$?

      [[ $status -ne 0 ]] || fail "dockerInstall accepted an installation kvsctl manages ($layout, $files)" || return 1
      grep -Fq "kvsctl manages the installation in $KVS_INSTALL_DIR" "$temp_dir/out" ||
        fail "the refusal does not say why ($layout, $files): $(cat "$temp_dir/out")" || return 1
      if [[ $files == override ]]; then
        marker="$KVS_INSTALL_DIR/docker/docker-compose.release.yml"
      else
        marker="$KVS_INSTALL_DIR/kvsctl/state.json"
      fi
      grep -Fq "($marker)" "$temp_dir/out" ||
        fail "the refusal does not name the file of kvsctl it found ($layout, $files): $(cat "$temp_dir/out")" || return 1
      grep -Fq 'kvsctl upgrade' "$temp_dir/out" || fail "the refusal does not point at kvsctl upgrade ($layout, $files)" || return 1
      [[ ! -e "$temp_dir/calls" ]] || fail "the refused update still ran: $(cat "$temp_dir/calls")" || return 1
      [[ ! -e "$KVS_BACKUP_DIR" ]] || fail "the refused update backed up the user data ($layout, $files)" || return 1
      [[ -f "$KVS_INSTALL_DIR/backups/kvs-26.10.0.tar" && -f "$KVS_INSTALL_DIR/docker/.env" ]] ||
        fail "the refused update touched the backups of kvsctl or the .env ($layout, $files)" || return 1
      [[ $files == override || -f "$KVS_INSTALL_DIR/kvsctl/state.json" ]] ||
        fail "the refused update touched the state of kvsctl ($layout, $files)" || return 1
      [[ $files == adopted || -f "$KVS_INSTALL_DIR/docker/docker-compose.release.yml" ]] ||
        fail "the refused update touched the files of the release ($layout, $files)" || return 1
    done
  done
}

# kvsctl backup and kvsctl restore run on any installation, and every kvsctl
# run that changes one holds the lock in kvsctl/lock; one that did not
# finish leaves kvsctl/journal.json for kvsctl recover. The installer must
# change nothing while either holds: no git command, no Docker install, no
# backup, nothing moved, what an earlier update left aside included, and
# the reason named, for the journal with the way out when recover leaves the
# run to be finished by hand. A run that holds the lock while its journal is
# there is running, not interrupted. A check that cannot take the lock
# (flock fails) cannot tell, and stops too. A lock no run holds stops
# nothing (the other cases of this suite run with one), nor one held shared,
# as kvsctl status holds it while it reads.
test_a_kvsctl_run_is_refused() {
  local temp_dir
  local status
  local layout
  local state
  local before
  local expected
  temp_dir=$(mktemp -d)
  trap 'exec 9<&-; rm -rf "$temp_dir"' RETURN

  git() {
    echo "git $*" >>"$temp_dir/calls"
    return 0
  }
  curl() {
    echo "curl $*" >>"$temp_dir/calls"
    return 0
  }

  for layout in checkout plain; do
    for state in running interrupted both; do
      export KVS_INSTALL_DIR="$temp_dir/$layout-$state/install"
      export KVS_BACKUP_DIR="$temp_dir/$layout-$state/backup"
      seed_installation "$KVS_INSTALL_DIR"
      [[ $layout == checkout ]] || rm -rf "$KVS_INSTALL_DIR/.git"
      seed_kvsctl_data "$KVS_INSTALL_DIR"
      [[ $state == running ]] || printf '{"action":"restore"}\n' >"$KVS_INSTALL_DIR/kvsctl/journal.json"
      # The backups an update killed outright left aside stay there too.
      mkdir "$KVS_INSTALL_DIR.kvsctl.Ab12Cd"
      mv "$KVS_INSTALL_DIR/backups" "$KVS_INSTALL_DIR.kvsctl.Ab12Cd/"
      before=$(find "$temp_dir/$layout-$state" -printf '%p %i %s\n' | sort)
      if [[ $state == interrupted ]]; then
        expected="An interrupted kvsctl run left $KVS_INSTALL_DIR/kvsctl/journal.json: run 'kvsctl recover' first. Where recover says to finish by hand and that takes this installer, remove that file, then run the installer again. Nothing was changed."
      else
        expected="kvsctl is running on the installation in $KVS_INSTALL_DIR (it holds $KVS_INSTALL_DIR/kvsctl/lock): wait until it is done; 'kvsctl status' shows what it does. Nothing was changed."
        # Held as kvsctl holds it, on a descriptor of its own.
        exec 9<"$KVS_INSTALL_DIR/kvsctl/lock"
        flock --exclusive 9 || fail "the lock could not be taken" || return 1
      fi

      (dockerInstall) >"$temp_dir/out" 2>&1
      status=$?
      exec 9<&-

      [[ $status -ne 0 ]] || fail "dockerInstall went on beside kvsctl ($layout, $state)" || return 1
      grep -Fq "$expected" "$temp_dir/out" ||
        fail "the refusal does not say why ($layout, $state): $(cat "$temp_dir/out")" || return 1
      [[ ! -e "$temp_dir/calls" ]] || fail "the refused update still ran ($layout, $state): $(cat "$temp_dir/calls")" || return 1
      [[ "$(find "$temp_dir/$layout-$state" -printf '%p %i %s\n' | sort)" == "$before" ]] ||
        fail "the refused update changed the installation ($layout, $state): $(find "$temp_dir/$layout-$state")" || return 1
    done
  done

  # An update killed while it had the files of kvsctl aside kept the
  # journal there: they come back first, and the journal stops the update.
  export KVS_INSTALL_DIR="$temp_dir/aside/install"
  export KVS_BACKUP_DIR="$temp_dir/aside/backup"
  seed_installation "$KVS_INSTALL_DIR"
  seed_kvsctl_data "$KVS_INSTALL_DIR"
  printf '{"action":"restore"}\n' >"$KVS_INSTALL_DIR/kvsctl/journal.json"
  mkdir "$KVS_INSTALL_DIR.kvsctl.Ef34Gh"
  mv "$KVS_INSTALL_DIR/backups" "$KVS_INSTALL_DIR/kvsctl" "$KVS_INSTALL_DIR.kvsctl.Ef34Gh/"
  (dockerInstall) >"$temp_dir/out" 2>&1
  status=$?
  [[ $status -ne 0 ]] || fail "dockerInstall went on after it brought back the journal of a kvsctl run" || return 1
  grep -Fq "An interrupted kvsctl run left $KVS_INSTALL_DIR/kvsctl/journal.json: run 'kvsctl recover' first." "$temp_dir/out" ||
    fail "the journal brought back does not stop the update: $(cat "$temp_dir/out")" || return 1
  [[ -f "$KVS_INSTALL_DIR/kvsctl/journal.json" && -f "$KVS_INSTALL_DIR/backups/backup-unknown-20261007-010000.tar" &&
    ! -e "$KVS_INSTALL_DIR.kvsctl.Ef34Gh" ]] ||
    fail "the files of kvsctl did not come back: $(find "$temp_dir/aside")" || return 1
  [[ ! -e "$temp_dir/calls" && ! -e "$KVS_BACKUP_DIR" ]] ||
    fail "the update went on after the journal came back: $(cat "$temp_dir/calls" 2>/dev/null)" || return 1

  # A flock that fails other than on a held lock, as when it cannot open the
  # file: the update stops and says why.
  export KVS_INSTALL_DIR="$temp_dir/unknown/install"
  export KVS_BACKUP_DIR="$temp_dir/unknown/backup"
  seed_installation "$KVS_INSTALL_DIR"
  seed_kvsctl_data "$KVS_INSTALL_DIR"
  before=$(find "$temp_dir/unknown" -printf '%p %i %s\n' | sort)
  flock() { return 66; }
  (dockerInstall) >"$temp_dir/out" 2>&1
  status=$?
  unset -f flock
  [[ $status -ne 0 ]] || fail "dockerInstall went on although it could not tell whether kvsctl runs" || return 1
  grep -Fq "Could not tell whether kvsctl is running: flock $KVS_INSTALL_DIR/kvsctl/lock failed with status 66. Nothing was changed." "$temp_dir/out" ||
    fail "the refusal does not say the check could not tell: $(cat "$temp_dir/out")" || return 1
  [[ ! -e "$temp_dir/calls" ]] || fail "the update went on although it could not tell whether kvsctl runs: $(cat "$temp_dir/calls")" || return 1
  [[ "$(find "$temp_dir/unknown" -printf '%p %i %s\n' | sort)" == "$before" ]] ||
    fail "the refused update changed the installation (unknown): $(find "$temp_dir/unknown")" || return 1

  # Held shared, as kvsctl status holds it while it reads: no run, and the
  # update goes on.
  export KVS_INSTALL_DIR="$temp_dir/watched/install"
  export KVS_BACKUP_DIR="$temp_dir/watched/backup"
  seed_installation "$KVS_INSTALL_DIR"
  seed_kvsctl_data "$KVS_INSTALL_DIR"
  printf '#!/bin/bash\necho setup-ran\n' >"$KVS_INSTALL_DIR/docker/setup.sh"
  exec 9<"$KVS_INSTALL_DIR/kvsctl/lock"
  flock --shared 9 || fail "the lock could not be taken shared" || return 1
  (dockerInstall) >"$temp_dir/out" 2>&1
  status=$?
  exec 9<&-
  [[ $status -eq 0 ]] || fail "dockerInstall stopped beside a shared hold of the kvsctl lock (status $status): $(cat "$temp_dir/out")" || return 1
  grep -q 'setup-ran' "$temp_dir/out" || fail "the Docker setup did not run beside a shared hold of the kvsctl lock: $(cat "$temp_dir/out")" || return 1
  rm -f "$temp_dir/calls"

  # Without kvsctl the update goes on, as before kvsctl.
  export KVS_INSTALL_DIR="$temp_dir/none/install"
  export KVS_BACKUP_DIR="$temp_dir/none/backup"
  seed_installation "$KVS_INSTALL_DIR"
  printf '#!/bin/bash\necho setup-ran\n' >"$KVS_INSTALL_DIR/docker/setup.sh"
  (dockerInstall) >"$temp_dir/out" 2>&1
  status=$?
  [[ $status -eq 0 ]] || fail "dockerInstall failed on an installation kvsctl never ran on (status $status): $(cat "$temp_dir/out")" || return 1
  grep -q 'setup-ran' "$temp_dir/out" || fail "the Docker setup did not run without kvsctl: $(cat "$temp_dir/out")" || return 1
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
run_test "an installation kvsctl manages is refused" test_kvsctl_managed_install_is_refused || failures=$((failures + 1))
run_test "a kvsctl run in progress or cut short is refused" test_a_kvsctl_run_is_refused || failures=$((failures + 1))
run_test "a new clone keeps the backups and the logs of kvsctl" test_reclone_keeps_the_backups_and_logs_of_kvsctl || failures=$((failures + 1))
run_test "files of kvsctl that cannot move stop the new clone" test_kvsctl_data_that_cannot_move_stops_the_reclone || failures=$((failures + 1))
run_test "files of kvsctl that cannot move back are named" test_kvsctl_data_that_cannot_move_back_is_named || failures=$((failures + 1))
run_test "a failed swap puts the files of kvsctl back" test_failed_swap_puts_the_kvsctl_data_back || failures=$((failures + 1))
run_test "an interrupted swap moves the files of kvsctl back" test_interrupted_swap_moves_the_kvsctl_data_back || failures=$((failures + 1))
run_test "a signal to the whole run moves the files of kvsctl back" test_a_signal_to_the_whole_run_moves_the_kvsctl_data_back || failures=$((failures + 1))
run_test "the tee of the log ignores Ctrl-C" test_the_log_tee_ignores_ctrl_c || failures=$((failures + 1))
run_test "a later run moves back what an update left aside" test_a_later_run_moves_back_what_an_update_left_aside || failures=$((failures + 1))

if ((failures != 0)); then
  echo "$failures test(s) failed" >&2
  exit 1
fi

echo "All Docker re-clone tests passed"

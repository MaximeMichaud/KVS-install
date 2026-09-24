#!/bin/bash
# shellcheck disable=SC1091,SC2034,SC2154,SC2329
# README documents the standalone headless run with database_ver=11.8. The
# defaults read DATABASE_VER only, so the documented variable was ignored
# and MariaDB 11.8 was installed whatever the operator asked for.

set -o pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly TEST_DIR
REPO_DIR=$(cd "$TEST_DIR/.." && pwd)
readonly REPO_DIR
readonly INSTALLER="$REPO_DIR/kvs-install.sh"

fail() {
  echo "FAIL: $*" >&2
  return 1
}

assert_equal() {
  local expected="$1"
  local actual="$2"
  local message="$3"

  [[ "$actual" == "$expected" ]] || fail "$message (expected '$expected', got '$actual')"
}

# Runs the headless defaults in a fresh shell holding only the given
# variables and prints the MariaDB series they selected.
selected_database_version() {
  # shellcheck disable=SC2016  # The inner shell expands $1 and $database_ver.
  env -i PATH="$PATH" HEADLESS=y "$@" \
    bash -c 'source "$1"; initialize_runtime_defaults; printf "%s" "$database_ver"' _ "$INSTALLER"
}

test_documented_database_ver_is_honoured() {
  assert_equal "10.11" "$(selected_database_version database_ver=10.11)" \
    "database_ver from the environment was ignored"
}

test_uppercase_database_ver_still_works() {
  assert_equal "10.6" "$(selected_database_version DATABASE_VER=10.6)" \
    "DATABASE_VER from the environment is no longer honoured"
}

test_default_is_the_latest_lts() {
  assert_equal "11.8" "$(selected_database_version)" "the default MariaDB series changed"
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
run_test "documented database_ver is honoured" test_documented_database_ver_is_honoured || failures=$((failures + 1))
run_test "DATABASE_VER still works" test_uppercase_database_ver_still_works || failures=$((failures + 1))
run_test "default is the latest LTS" test_default_is_the_latest_lts || failures=$((failures + 1))

if ((failures != 0)); then
  echo "$failures test(s) failed" >&2
  exit 1
fi

echo "All headless default tests passed"

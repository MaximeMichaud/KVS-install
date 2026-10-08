#!/bin/bash
# shellcheck disable=SC2016  # The patterns are literal lines of the workflows.
# The release workflow cannot run outside GitHub, so this checks the wiring
# that once went wrong or that a release depends on: nothing is built before
# the tests of the tagged commit pass, and the same tests run on every pull
# request, the release scripts on the coreutils of the runner too, with
# govulncheck for kvsctl, whose tests also run on a change of the stack
# files they read and compare the .env reading of kvsctl with docker
# compose; the signing keys and the manifest the release extends
# are checked before any image is pushed; the bundle pins every image
# by digest, the manifest records the commit, the notes, the highlights and
# the minimums of .github/release.env, a second signing key is optional, the
# previous manifest is checked with the API token and the new one against
# the keys kvsctl ships with, then read by the kvsctl of the release, before
# anything is published, a candidate gets its assets as a draft, two runs
# never publish at once, the matrix builds php-fpm and cron for the same PHP
# series, only linux/amd64 binaries are built, the Go toolchain is exactly
# the one cli/go.mod names, and the lock of the base images is checked every
# week.
#
# The jobs, steps and triggers are read as YAML, where GitHub reads them, so
# a trigger left in a comment, a condition on a job or a step, or a test
# allowed to fail is caught, not taken for the line it once was. A step the
# release relies on is compared line by line, so a check turned off by an
# "|| true" at the end of a line is caught as well.
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
RELEASE="$ROOT_DIR/.github/workflows/release.yml"
TESTS="$ROOT_DIR/.github/workflows/tests.yml"
GO="$ROOT_DIR/.github/workflows/go.yml"
fail() { echo "FAIL: $*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || fail "jq is required"
python3 -c 'import yaml' 2>/dev/null ||
    fail "python3 with PyYAML (python3-yaml) is required to read the workflows"

has() {
    local file=$1 pattern=$2 why=$3
    grep -Fq -- "$pattern" "$file" || fail "$why: '$pattern' is missing from ${file#"$ROOT_DIR"/}"
}

# A workflow as JSON. PyYAML reads the key "on" as true, a YAML 1.1 boolean,
# so it gets its name back.
workflow_json() {
    python3 -c '
import json
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as source:
    workflow = yaml.safe_load(source)
if True in workflow:
    workflow["on"] = workflow.pop(True)
json.dump(workflow, sys.stdout)
' "$1"
}
release=$(workflow_json "$RELEASE")
tests=$(workflow_json "$TESTS")
go=$(workflow_json "$GO")

# holds <workflow> <why> <jq filter> [jq option...]: the filter is true.
holds() {
    local json=$1 why=$2 filter=$3
    shift 3
    jq -e "$@" "$filter" <<<"$json" >/dev/null || fail "$why"
}

# A job of the gate runs whatever happened before it and fails the run when
# it fails: no condition, which always() would turn into a job that runs
# after failed tests, and no continue-on-error.
unconditional_job() {
    local json=$1 name=$2 job=$3
    holds "$json" "the $job job of $name must run on no condition and fail when it fails" \
        '.jobs[$job] | (has("if") or has("continue-on-error")) | not' --arg job "$job"
}

# So does every step of a test job, in the default shell, which stops at the
# first command that fails.
unconditional_steps() {
    local json=$1 name=$2 job=$3
    holds "$json" "no step of the $job job of $name may be skipped, allowed to fail or given a shell" \
        '[.jobs[$job].steps[] | select(has("if") or has("continue-on-error") or has("shell"))] == []' \
        --arg job "$job"
}

# The tests gate everything that leaves the runner.
holds "$release" "the release must run the kvsctl tests" '.jobs.go.uses == "./.github/workflows/go.yml"'
holds "$release" "the release must run the shell suites" '.jobs.suites.uses == "./.github/workflows/tests.yml"'
for job in go suites keys images cli publish; do
    unconditional_job "$release" release.yml "$job"
done
for job in prepare keys images cli; do
    unconditional_steps "$release" release.yml "$job"
done
# The publish job too, but for its two steps that are conditional on
# purpose: the keys are removed whatever happened before, and a candidate
# is published by a step of its own.
holds "$release" "no step of the publish job may be skipped, allowed to fail or given a shell, but the removal of the keys and the publication of a candidate" \
    '[.jobs.publish.steps[] | select(has("continue-on-error") or has("shell")
        or (has("if") and ((.if == "always()" and .run == $forget)
            or (.if == $candidate and .run == $publish) | not)))] == []' \
    --arg forget 'rm -f "${RUNNER_TEMP}/release.key" "${RUNNER_TEMP}/release-next.key"' \
    --arg candidate "needs.prepare.outputs.prerelease == 'true'" \
    --arg publish 'gh release edit "$TAG" --repo "$GITHUB_REPOSITORY" --draft=false --latest=false'
for job in images cli publish; do
    holds "$release" "the $job job must wait for the go and suites jobs" \
        '(["go", "suites"] - (.jobs[$job].needs | if type == "string" then [.] else . end)) == []' \
        --arg job "$job"
done
holds "$go" "the release must be able to call the kvsctl tests" '.on | has("workflow_call")'
holds "$tests" "the release must be able to call the shell suites" '.on | has("workflow_call")'
holds "$tests" "the shell suites must run on every pull request, with no filter" \
    '.on | has("pull_request") and .pull_request == null'
holds "$tests" "the shell suites must run on a push to any branch" '.on.push == {"branches": ["**"]}'
unconditional_job "$tests" tests.yml suites
unconditional_steps "$tests" tests.yml suites
unconditional_job "$go" go.yml build
unconditional_steps "$go" go.yml build
# As uid 1000, which the scripts the suites exercise give the site's files
# to, and the runner user is not (tests/test_release_suites_user.sh).
holds "$tests" "the shell suites must run every suite as uid 1000, with CI set" \
    'any(.jobs.suites.steps[]; .run == ".github/scripts/as-uid-1000.sh tests/run.sh"
        and (.env.CI | tostring) == "true")'
holds "$tests" "the Dockerfiles must be checked against the lock" \
    'any(.jobs.suites.steps[]; .run == "./docker/bin/resolve-bases.sh --check-dockerfiles")'
holds "$go" "the kvsctl tests must run, with the race detector" \
    'any(.jobs.build.steps[]; .run == "go test -race ./...")'
holds "$go" "govulncheck must check kvsctl, in a version of its own" \
    'any(.jobs.build.steps[]; .run // "" | test("^go run golang.org/x/vuln/cmd/govulncheck@v[0-9]+\\.[0-9]+\\.[0-9]+ \\./\\.\\.\\.$"))'
# The kvsctl tests read these files of the repository: the dump and replay
# tests run the MariaDB of the lock, the .env tests read the example, which
# they compare with docker compose, and the entrypoints, and a test runs the
# publish check on the compose file, the lock and release.env through
# release-images.sh. A change of one of them runs the kvsctl tests too.
holds "$go" "the kvsctl tests must run on a push and a pull request that change kvsctl or a file of the repository they read" \
    '($read - .on.push.paths) == [] and ($read - .on.pull_request.paths) == []' \
    --argjson read '["cli/**", "docker/images.lock", "docker/docker-compose.yml", "docker/.env.example", "docker/php/docker-entrypoint.sh", "docker/cron/docker-entrypoint.sh", ".github/release.env", ".github/scripts/release-images.sh"]'
# The test that reads the example runs only with KVSCTL_COMPOSE_PARITY=1,
# and skips where there is no docker compose, which a step before the tests
# has to find instead.
holds "$go" "the kvsctl tests must run with KVSCTL_COMPOSE_PARITY=1, after a step that wants docker compose" \
    '.jobs.build.steps
        | (map(.run == "docker compose version") | index(true)) as $compose
        | (map(.run == "go test -race ./..." and ((.env.KVSCTL_COMPOSE_PARITY // "") | tostring) == "1")
            | index(true)) as $test
        | $compose != null and $test != null and $compose < $test'
dotenv_test="$ROOT_DIR/cli/internal/dotenv/dotenv_test.go"
if ! grep -Fq 'os.Getenv("KVSCTL_COMPOSE_PARITY") != "1"' "$dotenv_test" ||
    ! grep -Fq 'filepath.Join("..", "..", "..", "docker", ".env.example")' "$dotenv_test"; then
    fail "${dotenv_test#"$ROOT_DIR"/} must read docker/.env.example when KVSCTL_COMPOSE_PARITY is 1, which the kvsctl workflow sets"
fi
# The release jobs run the scripts on the coreutils of the runner, uutils
# from Ubuntu 26.04 on, which the suites job replaces with GNU coreutils.
unconditional_job "$tests" tests.yml release-scripts
unconditional_steps "$tests" tests.yml release-scripts
holds "$tests" "the release script suites must run on the coreutils of the runner, with CI set" \
    '(.jobs["release-scripts"].steps | any(.run // "" | contains("coreutils")) | not)
        and any(.jobs["release-scripts"].steps[]; (.run // "" | contains("for suite in tests/test_release_*.sh; do"))
            and (.env.CI | tostring) == "true")'
echo "PASS: the tests of the tagged commit gate the images, the binaries and the release"

# The signing keys are checked in the release environment, and the manifest
# the release extends in the prepare job, before any image is pushed.
holds "$release" "the keys job must read both signing keys in the release environment, after prepare" \
    '.jobs.keys.environment == "release" and .jobs.keys.needs == "prepare"
        and any(.jobs.keys.steps[]; .run == "./.github/scripts/release-signing-keys.sh"
            and .env.KVSCTL_RELEASE_KEY == "${{ secrets.KVSCTL_RELEASE_KEY }}"
            and .env.KVSCTL_RELEASE_KEY_NEXT == "${{ secrets.KVSCTL_RELEASE_KEY_NEXT }}")'
holds "$release" "Go must be set up before the keys job reads the secrets with kvsctl-release" \
    '.jobs.keys.steps | (map(.uses // "" | startswith("actions/setup-go@")) | index(true)) as $go
        | (map(.run == "./.github/scripts/release-signing-keys.sh") | index(true)) as $keys
        | $go != null and $keys != null and $go < $keys'
holds "$release" "the images job must wait for the signing keys" '.jobs.images.needs | index("keys") != null'
holds "$release" "the prepare job must check the manifest the release extends, with the API token" \
    'any(.jobs.prepare.steps[]; .name == "the previous manifest" and .env.GH_TOKEN == "${{ secrets.GITHUB_TOKEN }}"
        and .run == $run)' \
    --arg run './.github/scripts/verify-manifest.sh \
  "https://github.com/${GITHUB_REPOSITORY}/releases/latest/download" \
  "${RUNNER_TEMP}/previous.json"
./.github/scripts/release-previous.sh "${RUNNER_TEMP}/previous.json"
'
holds "$release" "Go must be set up before the prepare job verifies the previous manifest" \
    '.jobs.prepare.steps | (map(.uses // "" | startswith("actions/setup-go@")) | index(true)) as $go
        | (map(.name == "the previous manifest") | index(true)) as $previous
        | $go != null and $previous != null and $go < $previous'
echo "PASS: the signing keys and the previous manifest are checked before any image is pushed"

has "$RELEASE" './.github/scripts/release-env.sh "$VERSION"' "the prepare job must check release.env"
has "$RELEASE" '--images "$images" --digests "$digests" --out "$bundle"' "the bundle must pin every image by digest"
has "$RELEASE" 'commit=$(git rev-parse --verify "${TAG}^{commit}")' "the commit must be read on a line of its own"
has "$RELEASE" '--commit "$commit"' "the manifest must record the commit"
has "$RELEASE" '--notes "$NOTES"' "the manifest must carry NOTES"
for knob in MIN_FROM DATABASE ONE_WAY KVS_MIN KVSCTL_MIN COMPOSE_MIN ANNOUNCE_KEY HIGHLIGHT_1 HIGHLIGHT_2 HIGHLIGHT_3; do
    has "$RELEASE" "\"\$${knob}\"" "the publish job must read $knob"
done
has "$RELEASE" 'arguments+=(--kvsctl-min "$KVSCTL_MIN")' "the manifest must carry KVSCTL_MIN"
has "$RELEASE" 'arguments+=(--highlight "$highlight")' "the manifest must carry the highlights"
has "$RELEASE" 'KVSCTL_RELEASE_KEY_NEXT: ${{ secrets.KVSCTL_RELEASE_KEY_NEXT }}' "the second signing key must be read"
has "$RELEASE" 'arguments+=(--key "${RUNNER_TEMP}/release-next.key")' "the second signing key must sign"
# Byte for byte, the way the keys job reads them.
has "$RELEASE" 'printf '"'"'%s'"'"' "$KVSCTL_RELEASE_KEY" > "${RUNNER_TEMP}/release.key"' "the signing key must be written as the secret holds it"
has "$RELEASE" 'printf '"'"'%s'"'"' "$KVSCTL_RELEASE_KEY_NEXT" > "${RUNNER_TEMP}/release-next.key"' "the second signing key must be written as the secret holds it"
has "$RELEASE" 'keys=$(../.github/scripts/release-public-keys.sh)' "the new manifest must be checked against the embedded keys"
has "$RELEASE" 'go run ./cmd/kvsctl-release verify --all' "every signature must match a key kvsctl ships with"
has "$RELEASE" 'rm -f "${RUNNER_TEMP}/release.key" "${RUNNER_TEMP}/release-next.key"' "both keys must be removed"
has "$RELEASE" 'group: release' "release runs must not overlap"
has "$RELEASE" 'cancel-in-progress: false' "a release run must never be cancelled by the next one"
has "$RELEASE" '--ignore-tags . --strip header' "the notes must be one section"
has "$RELEASE" './.github/scripts/release-notes-range.sh "$TAG"' "the notes must start at the previous stable release"
grep -Eq '^ +version: v[0-9]+\.[0-9]+\.[0-9]+$' "$RELEASE" || fail "the git-cliff version must be pinned"
if grep -n -e '--notes-file' -e 'mariadb-from' "$RELEASE"; then
    fail "the publish job still passes a flag kvsctl-release no longer uses this way"
fi

# The previous manifest is checked with the API token, which tells a first
# release from a latest release that is not a stack release.
holds "$release" "the previous manifest must be checked with the API token" \
    'any(.jobs.publish.steps[]; .name == "the previous manifest" and .env.GH_TOKEN == "${{ secrets.GITHUB_TOKEN }}")'
holds "$release" "the tag must be checked against the existing releases with the API token" \
    'any(.jobs.prepare.steps[]; .name == "validate the tag" and .env.GH_TOKEN == "${{ secrets.GITHUB_TOKEN }}")'

# The publish job signs, checks the new manifest, has the kvsctl of the
# release read it, uploads every asset to a draft, and publishes a candidate
# last, in that order.
order=$(jq -r '.jobs.publish.steps | to_entries
    | [ (.[] | select(.value.run // "" | contains("go run ./cmd/kvsctl-release manifest")) | .key),
        (.[] | select(.value.run // "" | contains("go run ./cmd/kvsctl-release verify --all")) | .key),
        (.[] | select(.value.run // "" | contains("TestShippedRelease")) | .key),
        (.[] | select(.value.uses // "" | startswith("softprops/action-gh-release@")) | .key),
        (.[] | select(.value.name == "publish the candidate") | .key) ]
    | map(tostring) | join(" ")' <<<"$release")
read -r sign check shipped assets candidate extra <<<"$order"
[ -n "$candidate" ] && [ -z "${extra:-}" ] ||
    fail "the publish job must sign, check, try, upload and publish a candidate once each, steps found: $order"
[ "$sign" -lt "$check" ] && [ "$check" -lt "$shipped" ] && [ "$shipped" -lt "$assets" ] ||
    fail "the manifest must be checked (step $check) and read by the kvsctl of the release (step $shipped) between signing (step $sign) and the upload (step $assets)"

# The kvsctl of the release reads the manifest with the keys it embeds
# alone, and the test that picks the images of every series has to pass,
# which a skip would not show. Each line is a whole line of the step, with
# pipefail set first and the check of the PASS line last, so nothing after
# it decides how the step ends.
shipped_run=$(jq -r --argjson step "$shipped" '.jobs.publish.steps[$step].run' <<<"$release")
shipped_lines=$(awk '{ sub(/^ +/, ""); print }' <<<"$shipped_run")
for line in 'set -o pipefail' 'unset KVSCTL_RELEASE_KEY' \
    '"$kvsctl" releases --json --manifest "file://${dist}/manifest.json" > "${RUNNER_TEMP}/releases.json"' \
    'if ! jq -e --arg version "$VERSION" '"'"'any(.[]; .version == $version)'"'"' "${RUNNER_TEMP}/releases.json" > /dev/null; then' \
    'keys=$(../.github/scripts/release-public-keys.sh)' \
    "KVSCTL_SHIPPED_DIR=\"\$dist\" KVSCTL_SHIPPED_VERSION=\"\$VERSION\" KVSCTL_SHIPPED_KEYS=\"\$keys\" \\" \
    "go test -count=1 -run '^TestShippedRelease\$' -v ./cmd/kvsctl-release | tee \"\${RUNNER_TEMP}/shipped.log\"" \
    "grep -q '^--- PASS: TestShippedRelease ' \"\${RUNNER_TEMP}/shipped.log\""; do
    grep -Fqx -- "$line" <<<"$shipped_lines" || fail "the kvsctl of the release must be tried on its manifest: the line '$line' is missing"
done
[ "$(sed -n 1p <<<"$shipped_lines")" = 'set -o pipefail' ] ||
    fail "the step that tries the kvsctl of the release must set pipefail first"
[ "$(sed '/^$/d' <<<"$shipped_lines" | tail -n 1)" = "grep -q '^--- PASS: TestShippedRelease ' \"\${RUNNER_TEMP}/shipped.log\"" ] ||
    fail "the step that tries the kvsctl of the release must end with the check of the PASS line"
if grep -n '^set +' <<<"$shipped_lines"; then
    fail "the step that tries the kvsctl of the release must stop at the first command that fails"
fi
holds "$release" "the kvsctl of the release must be tried where the binaries were built" \
    '.jobs.publish.steps[$step]["working-directory"] == "cli"' --argjson step "$shipped"
# The check of the signatures ends with kvsctl-release verify, whose status
# is the status of the step.
holds "$release" "the step that checks the manifest against the keys kvsctl ships with must end with kvsctl-release verify --all" \
    '.jobs.publish.steps[$step] | .["working-directory"] == "cli" and (.run | endswith($verify))' \
    --argjson step "$check" \
    --arg verify 'go run ./cmd/kvsctl-release verify --all \
  --manifest ../dist/manifest.json \
  --signature ../dist/manifest.json.sig \
  "${pub_args[@]}"
'
grep -q '^func TestShippedRelease(t \*testing.T) {$' "$ROOT_DIR/cli/cmd/kvsctl-release/shipped_test.go" ||
    fail "cli/cmd/kvsctl-release/shipped_test.go must hold the TestShippedRelease the publish job runs"
echo "PASS: the publish job pins, records, signs and checks the release, and tries it with its kvsctl"

# Assets reach a draft only, which immutable releases require: the action
# drafts a stable release itself, a candidate is drafted explicitly and
# published once its assets are up.
holds "$release" "a candidate must be created as a draft" \
    'any(.jobs.publish.steps[]; (.uses // "" | startswith("softprops/action-gh-release@"))
        and .with.draft == "${{ needs.prepare.outputs.prerelease }}")'
holds "$release" "only a candidate is published by its own step, never as the latest release, with the API token" \
    'any(.jobs.publish.steps[]; .name == "publish the candidate" and .if == $condition and .run == $command
        and .env.GH_TOKEN == "${{ secrets.GITHUB_TOKEN }}" and .env.TAG == "${{ needs.prepare.outputs.tag }}")' \
    --arg condition "needs.prepare.outputs.prerelease == 'true'" \
    --arg command 'gh release edit "$TAG" --repo "$GITHUB_REPOSITORY" --draft=false --latest=false'
[ "$assets" -lt "$candidate" ] ||
    fail "the candidate must be published after its assets are uploaded (step $assets), not at step $candidate"
echo "PASS: every asset is uploaded to a draft that is published last"

# The images job pushes php-fpm and cron for each PHP series of its matrix.
# A series with only one of them, or without a base in the lock, would fail
# after the other images were pushed under the version.
matrix_series() {
    jq -r --arg service "$1" '.jobs.images.strategy.matrix.include[] | select(.service == $service) | .php' \
        <<<"$release" | sort
}
php_series=$(matrix_series php)
cron_series=$(matrix_series cron)
[ -n "$php_series" ] || fail "no PHP series read from the matrix of release.yml"
[ "$php_series" = "$cron_series" ] ||
    fail "release.yml builds php for $(paste -sd' ' <<<"$php_series") and cron for $(paste -sd' ' <<<"$cron_series")"
for series in $php_series; do
    for base in php-fpm php-cli; do
        "$ROOT_DIR/docker/bin/resolve-bases.sh" --get "$base" "$series" >/dev/null 2>&1 ||
            fail "release.yml builds PHP $series, which docker/images.lock gives no $base base"
    done
done
echo "PASS: the matrix builds php-fpm and cron, on a locked base, for the same PHP series"

for workflow in "$RELEASE" "$ROOT_DIR/.github/workflows/go.yml"; do
    # Outside comments: one says why the images are amd64 only.
    if grep -nE '^[^#]*arm64' "$workflow"; then
        fail "${workflow#"$ROOT_DIR"/} still builds for arm64, whose images are never published"
    fi
done
has "$RELEASE" 'CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath' "the binaries are built for linux/amd64"
has "$RELEASE" '--cli "linux-amd64=${base}/kvsctl-linux-amd64"' "the manifest lists the linux/amd64 binary"
for workflow in "$RELEASE" "$ROOT_DIR/.github/workflows/go.yml"; do
    has "$workflow" 'go-version-file: cli/go.mod' "setup-go must read cli/go.mod"
    has "$workflow" 'want=$(go mod edit -json | jq -r '"'"'.Toolchain // ("go" + .Go)'"'"')' "the toolchain must be checked"
done
grep -Eq '^go [0-9]+\.[0-9]+\.[0-9]+$' "$ROOT_DIR/cli/go.mod" ||
    fail "cli/go.mod must name a Go patch release, which setup-go then installs exactly"
echo "PASS: linux/amd64 binaries, built with the Go release cli/go.mod names"

DOCKER="$ROOT_DIR/.github/workflows/docker.yml"
has "$DOCKER" 'schedule:' "the lock must be checked on a schedule"
has "$DOCKER" 'run: ./docker/bin/resolve-bases.sh --check' "the scheduled job must check the lock"
has "$DOCKER" "if: github.event_name == 'schedule' || github.event_name == 'workflow_dispatch'" "only the lock job runs on the schedule"
[ "$(grep -c "if: github.event_name == 'push' || github.event_name == 'pull_request'" "$DOCKER")" -eq 2 ] ||
    fail "hadolint and the image builds must keep running on push and pull requests only"
echo "PASS: images.lock is checked against the registries every week"

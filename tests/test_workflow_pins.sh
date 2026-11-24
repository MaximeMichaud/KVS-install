#!/bin/bash
# Every action a workflow runs is pinned to a commit, not to a tag its owner
# can move: the release and docker jobs hold write access to the repository,
# its releases and the GHCR images, so a moved tag would run someone else's
# code with that access. Each pin keeps the full version it stands for in a
# comment, which Renovate reads to propose the next commit, and renovate.json
# asks for digest pins. The images a workflow runs (docker run or create,
# wherever the shell runs it, sh -c included, a job container or service,
# the BuildKit of setup-buildx-action) are pinned by tag and digest under a
# custom manager that updates both, whichever of .yml and .yaml the workflow
# ends in, and ShellCheck runs the release of the pre-commit hook.
# An update that changes a digest and keeps the version means a tag was
# moved: renovate.json never merges it by itself. No checkout leaves its
# token in .git/config, as no job pushes with git, and every workflow sets
# the permissions of its token instead of the repository default: read
# access, except the two release jobs that publish.
#
# The workflows are read as YAML for the jobs and steps, and as text for the
# version comments, which YAML drops.
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fail() { echo "FAIL: $*" >&2; exit 1; }

python3 -c 'import yaml' 2>/dev/null ||
    fail "python3 with PyYAML (python3-yaml) is required to read the workflows"

# Prints what is wrong with the workflows, renovate.json and the pre-commit
# configuration under the directory $1, and fails if anything is.
check_workflows() {
    python3 - "$1" <<'PY'
import json
import pathlib
import re
import shlex
import sys

import yaml

root = pathlib.Path(sys.argv[1])
workflows = sorted([*(root / ".github" / "workflows").glob("*.yml"),
                    *(root / ".github" / "workflows").glob("*.yaml")])
if not workflows:
    sys.exit("FAIL: no workflow found")
problems = []
pinned = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40}$")
comment = re.compile(r"^\s*(?:-\s+)?uses:\s*(\S+)\s+#\s*v?\d+\.\d+\.\d+\s*$")
image_pin = re.compile(r"^([a-z0-9][a-z0-9._/-]*):(v?\d+\.\d+(?:\.\d+)?)@(sha256:[0-9a-f]{64})$")
renovate = json.loads((root / "renovate.json").read_text(encoding="utf-8"))
checkouts = 0
uses_count = 0
images = []  # (workflow, where, name, tag, digest)

# The flags of docker itself and of docker run and docker create (Docker 29
# --help). A global flag outside these sets, or a short one of run or
# create, cannot be read; a long flag of run or create without "=" and not
# in its boolean set takes the next word.
GLOBAL_FLAGS = ({"--debug", "--tls", "--tlsverify", "--version", "--help"},
                {"--config", "--context", "--host", "--log-level", "--tlscacert", "--tlscert", "--tlskey"},
                set("Dvh"), set("cHl"))
RUN_FLAGS = ({"--detach", "--disable-content-trust", "--help", "--init", "--interactive", "--no-healthcheck",
              "--oom-kill-disable", "--privileged", "--publish-all", "--quiet", "--read-only", "--rm",
              "--sig-proxy", "--tty", "--use-api-socket"},
             None, set("diPqt"), set("acehlmpuvw"))


def skip_flags(words, j, flags):
    """The index of the first word from j on that is no flag or flag value,
    the way the docker CLI reads them (a cluster of short flags, a value
    joined to its short flag, -- ending the flags), or None when a flag is
    not in flags (long boolean, long with a value or None for any other,
    short boolean, short with a value)."""
    long_boolean, long_value, short_boolean, short_value = flags
    while j < len(words) and words[j].startswith("-") and words[j] != "-":
        flag = words[j]
        j += 1
        if flag == "--":
            break
        if flag.startswith("--"):
            if "=" in flag or flag in long_boolean:
                continue
            if long_value is not None and flag not in long_value:
                return None
            j += 1
            continue
        for k, letter in enumerate(flag[1:], 2):
            if letter in short_boolean:
                continue
            if letter not in short_value:
                return None
            if k == len(flag):
                j += 1
            break
    return j


PUNCTUATION = "();<>|&`"


def shell_words(text):
    """The words of a shell line, split around ; & | ( ) < > and backquotes
    as well as spaces, their quotes removed, or None when the line cannot be
    split."""
    lexer = shlex.shlex(text, posix=True, punctuation_chars=PUNCTUATION)
    lexer.whitespace_split = True
    try:
        return list(lexer)
    except ValueError:
        return None


def docker_images(script):
    """(command, image) for every docker run and docker create of a step
    script, its image None when it cannot be read: after a ; or a |, inside
    $(...) or backquotes, and inside a quoted word that is a command line of
    its own, such as "$(docker run ...)" or the script of sh -c."""
    for line in re.sub(r"\\\n", " ", script).splitlines():
        words = shell_words(line)
        if words is None:
            yield "run", None
            continue
        yield from words_images(words)


def words_images(words):
    for i, word in enumerate(words):
        # A word that still holds a space or a tab once its quotes are gone,
        # such as "$(docker run ...)" or the script of sh -c, is read again
        # as a line of its own; each reading removes a level of quotes.
        if re.search(r"\s", word):
            inner = shell_words(word)
            if inner is not None:
                yield from words_images(inner)
            elif "docker" in word:
                yield "run", None
        if word.rsplit("/", 1)[-1] != "docker":
            continue
        j = skip_flags(words, i + 1, GLOBAL_FLAGS)
        if j is None:
            # Flags this test cannot read, before a run or a create.
            if {"run", "create"} & set(words[i + 1:]):
                yield "run or create", None
            continue
        if j < len(words) and words[j] == "container":
            j += 1
        if j >= len(words) or words[j] not in ("run", "create"):
            continue
        command = words[j]
        j = skip_flags(words, j + 1, RUN_FLAGS)
        yield command, words[j] if j is not None and j < len(words) else None


# The jobs whose token may write, and to what: the images job pushes the
# release images to GHCR and the publish job creates the GitHub release.
TOKEN_WRITES = {
    ("release.yml", "images"): {"packages"},
    ("release.yml", "publish"): {"contents"},
}


def token_writes(permissions):
    """The scopes a permissions block gives more than read access to."""
    if isinstance(permissions, dict):
        return sorted(scope for scope, level in permissions.items() if level not in ("read", "none"))
    # The only short form that gives no write access.
    return [] if permissions == "read-all" else [f"every scope ({permissions})"]


for path in workflows:
    name = path.relative_to(root)
    text = path.read_text(encoding="utf-8")
    workflow = yaml.safe_load(text)
    jobs = workflow.get("jobs") or {}
    # A workflow without permissions gets the repository default token,
    # which can write.
    if "permissions" not in workflow and not all("permissions" in job for job in jobs.values()):
        problems.append(f"{name}: no permissions block at the top or on every job, "
                        "so its jobs get the default token of the repository")
    # A block that is there can still give write access. The top one is
    # what a job added later gets, so it gives none; a job's own block
    # replaces the top one whole, and gives none either outside
    # TOKEN_WRITES, which holds no entry that is not used.
    if "permissions" in workflow:
        scopes = token_writes(workflow["permissions"])
        if scopes:
            problems.append(f"{name}: the permissions at the top give write access to {', '.join(scopes)}; "
                            "give it to the job that needs it")
    allowed_here = {job_name: allowed for (file, job_name), allowed in TOKEN_WRITES.items() if file == path.name}
    for job_name in allowed_here.keys() - jobs.keys():
        problems.append(f"{name}: TOKEN_WRITES of this test names the job {job_name}, which is not there")
    for job_name, job in jobs.items():
        # Without a block of its own, a job gets the top one.
        scopes = set(token_writes(job["permissions"])) if "permissions" in job else set()
        allowed = allowed_here.get(job_name, set())
        if scopes - allowed:
            problems.append(f"{name} job {job_name}: its token gets write access to {', '.join(sorted(scopes - allowed))}, "
                            "which TOKEN_WRITES of this test does not allow")
        if allowed - scopes:
            problems.append(f"{name} job {job_name}: TOKEN_WRITES of this test allows write access to "
                            f"{', '.join(sorted(allowed - scopes))}, which the job no longer has")
    found = []
    for job_name, job in jobs.items():
        if "uses" in job:
            found.append((f"job {job_name}", job["uses"], None))
        # The image of a job container, and of each service, given alone
        # or as the image key of a mapping.
        run_in = [("container", job.get("container"))]
        run_in += [(f"service {service}", spec) for service, spec in (job.get("services") or {}).items()]
        matrix = (job.get("strategy") or {}).get("matrix") or {}
        run_in += [("source_image", image) for image in matrix.get("source_image", [])]
        for what, spec in run_in:
            if spec is None:
                continue
            image = spec.get("image") if isinstance(spec, dict) else spec
            pin = image_pin.match(str(image))
            if not pin:
                problems.append(f"{name} job {job_name}: the {what} image {image} is not pinned by tag and digest")
                continue
            images.append((name, f"job {job_name} {what}", *pin.groups()))
        for step in job.get("steps") or []:
            if "uses" in step:
                found.append((f"job {job_name}", step["uses"], step))
            if "run" in step:
                for command, image in docker_images(str(step["run"])):
                    if image is None:
                        problems.append(f"{name} job {job_name}: a docker {command} whose image cannot be read")
                        continue
                    pin = image_pin.match(image)
                    if not pin:
                        problems.append(f"{name} job {job_name}: docker {command} {image} is not pinned by tag and digest")
                        continue
                    images.append((name, f"job {job_name}", *pin.groups()))
    for where, ref, step in found:
        uses_count += 1
        if ref.startswith("./"):
            continue
        if not pinned.match(ref):
            problems.append(f"{name} {where}: {ref} is not pinned to a 40-hex commit")
        with_ = (step or {}).get("with") or {}
        if ref.startswith("actions/checkout@"):
            checkouts += 1
            if with_.get("persist-credentials") is not False:
                problems.append(f"{name} {where}: actions/checkout keeps its token (persist-credentials: false is missing)")
        if ref.startswith("docker/setup-buildx-action@"):
            # Without an image, the builder runs moby/buildkit:buildx-stable-1.
            buildkit = re.fullmatch(r"image=(\S+)", str(with_.get("driver-opts", "")).strip())
            pin = image_pin.match(buildkit.group(1)) if buildkit else None
            if not pin or pin.group(1) != "moby/buildkit":
                problems.append(f"{name} {where}: setup-buildx-action does not run a moby/buildkit image pinned by tag and digest")
            else:
                images.append((name, where, *pin.groups()))
        if ref.startswith("ludeeus/action-shellcheck@"):
            shellcheck = with_.get("version")
            if not re.fullmatch(r"v\d+\.\d+\.\d+", str(shellcheck)):
                problems.append(f"{name} {where}: action-shellcheck downloads ShellCheck {shellcheck or 'stable'}, not a fixed release")
    # The version each pin stands for, in full, on its own line: Renovate reads it.
    for number, line in enumerate(text.splitlines(), 1):
        if not re.match(r"^\s*(?:-\s+)?uses:\s*", line):
            continue
        ref = line.split("uses:", 1)[1].split("#", 1)[0].strip()
        if ref.startswith("./"):
            continue
        if not comment.match(line):
            problems.append(f"{name}:{number}: the pin of {ref} has no full version comment (vX.Y.Z)")

if uses_count == 0 or checkouts == 0 or not images:
    problems.append("no action, no checkout or no image found: the workflows were not read")

if "helpers:pinGitHubActionDigests" not in renovate.get("extends", []):
    problems.append("renovate.json does not extend helpers:pinGitHubActionDigests")


def extracted(relative, text):
    """What the custom managers of renovate.json read in a file, the way
    Renovate applies them: (depName, currentValue, currentDigest, datasource)."""
    for manager in renovate.get("customManagers", []):
        patterns = [re.compile(p.strip("/")) for p in manager.get("managerFilePatterns", [])]
        if not any(p.search(relative) for p in patterns):
            continue
        for match_string in manager.get("matchStrings", []):
            regex = re.compile(re.sub(r"\(\?<([A-Za-z]+)>", r"(?P<\1>", match_string))
            for found in regex.finditer(text):
                groups = found.groupdict()
                yield (groups.get("depName") or manager.get("depNameTemplate"),
                       groups.get("currentValue"), groups.get("currentDigest"),
                       manager.get("datasourceTemplate"))


MATCHERS = {"matchManagers", "matchDepNames", "matchPackageNames", "matchUpdateTypes", "matchDatasources"}


def update_config(manager, dep, update_type, datasource):
    """The automerge, group and approval of one update, from the packageRules
    applied in order. Only the matchers above are read: a rule with another
    one fails the test instead of being misread."""
    config = {"automerge": renovate.get("automerge", False), "groupName": None,
              "dependencyDashboardApproval": False}
    for rule in renovate.get("packageRules", []):
        unknown = {key for key in rule if key.startswith("match")} - MATCHERS
        if unknown:
            problems.append(f"renovate.json: a package rule uses {sorted(unknown)}, which this test does not read")
            continue
        values = {"matchManagers": manager, "matchDepNames": dep, "matchPackageNames": dep,
                  "matchUpdateTypes": update_type, "matchDatasources": datasource}
        if all(values[key] in rule[key] or (key == "matchPackageNames" and "*" in rule[key])
               for key in MATCHERS if key in rule):
            for key in config:
                if key in rule:
                    config[key] = rule[key]
    return config


def moved_tag_held(label, *update):
    config = update_config(*update)
    if (config["automerge"] is not False or config["dependencyDashboardApproval"] is not True or
            config["groupName"] == "all non-major dependencies"):
        problems.append(f"renovate.json: a digest update of {label} that keeps its version (a moved tag) "
                        f"is {config}, not held for approval apart from the weekly pull request")


# Every pinned image is read by a custom manager with its tag and digest,
# and a moved tag of it is never merged by itself.
for workflow, where, image, tag, digest in images:
    text = (root / workflow).read_text(encoding="utf-8")
    if (image, tag, digest, "docker") not in set(extracted(str(workflow), text)):
        problems.append(f"{workflow} {where}: no custom manager of renovate.json updates {image}:{tag} and its digest")
    # The same pin in a workflow that ends in .yaml.
    if (image, tag, digest, "docker") not in set(extracted(".github/workflows/any.yaml", f"{image}:{tag}@{digest}")):
        problems.append(f"no custom manager of renovate.json updates {image}:{tag} in a .yaml workflow")
    moved_tag_held(image, "custom.regex", image, "digest", "docker")
moved_tag_held("an action", "github-actions", "actions/checkout", "digest", "github-tags")
# Only those: a new release of an action, and the digest updates of other
# managers or images, stay in the weekly pull request merged once CI passes.
for label, update in (("an action release", ("github-actions", "actions/checkout", "patch", "github-tags")),
                      ("another image", ("custom.regex", "debian", "digest", "docker")),
                      ("a Go module", ("gomod", "golang.org/x/term", "digest", "go"))):
    config = update_config(*update)
    if config["automerge"] is not True or config["dependencyDashboardApproval"] is not False:
        problems.append(f"renovate.json: {label} is {config}, no longer merged once CI passes")

# ShellCheck in CI is the release of the pre-commit hook, and Renovate reads
# it as that same package, so both move in one pull request.
hooks = yaml.safe_load((root / ".pre-commit-config.yaml").read_text(encoding="utf-8"))
hook_rev = next((repo.get("rev") for repo in hooks.get("repos", [])
                 if repo.get("repo") == "https://github.com/koalaman/shellcheck-precommit"), None)
push_yml = (root / ".github" / "workflows" / "push.yml").read_text(encoding="utf-8")
read = {(dep, value, source) for dep, value, _, source in extracted(".github/workflows/push.yml", push_yml)}
if not hook_rev or ("koalaman/shellcheck-precommit", hook_rev, "github-tags") not in read:
    problems.append(f"push.yml does not run the ShellCheck of the pre-commit hook ({hook_rev}) under a custom manager of renovate.json")

if problems:
    print("FAIL: " + "\nFAIL: ".join(problems), file=sys.stderr)
    sys.exit(1)
print(f"PASS: {uses_count} action references, every external one pinned to a commit with its full version, "
      f"{checkouts} checkouts without a kept token, every workflow with its own permissions, "
      f"write access for {len(TOKEN_WRITES)} release jobs only, "
      f"{len(images)} images pinned by tag and digest and updated by Renovate, ShellCheck {hook_rev} "
      "as in the pre-commit hook, and a moved tag never merged by itself")
PY
}

check_workflows "$ROOT_DIR"

# A docker run or create of an image pinned by tag only is found wherever the
# shell runs it: after a ;, inside $(...) or backquotes, quoted or not, in the
# script of sh -c or bash -c, behind the global flags of docker, as docker
# create or docker container create, and after a cluster of short flags. Each line is the run step of a workflow added to a
# copy of the repository's, which must fail and name the image; the same
# lines on the pinned hadolint image of docker.yml must pass.
fixture_root=$(mktemp -d /tmp/kvs-workflow-pins.XXXXXX)
trap 'rm -rf "$fixture_root"' EXIT
mkdir -p "$fixture_root/.github"
cp -R "$ROOT_DIR/.github/workflows" "$fixture_root/.github/workflows"
cp "$ROOT_DIR/renovate.json" "$ROOT_DIR/.pre-commit-config.yaml" "$fixture_root/"
hadolint=$(grep -o -m 1 'hadolint/hadolint:v[0-9.]*@sha256:[0-9a-f]\{64\}' "$ROOT_DIR/.github/workflows/docker.yml") ||
    fail "the pinned hadolint image of docker.yml was not found"
check_step() {
    printf 'name: fixture\non: push\npermissions:\n  contents: read\njobs:\n  fixture:\n    runs-on: ubuntu-latest\n    steps:\n      - run: |\n          %s\n' \
        "$1" > "$fixture_root/.github/workflows/fixture.yml"
    check_workflows "$fixture_root" > "$fixture_root/out" 2>&1
}
# shellcheck disable=SC2016  # Literal workflow steps, run by no shell here.
steps=(
    'true;docker run IMAGE'
    'echo $(docker run IMAGE)'
    'docker --log-level debug run IMAGE'
    'docker --tls run IMAGE'
    'docker -D run IMAGE'
    'docker create IMAGE'
    'id=`docker run -d IMAGE`'
    'docker -H unix:///run/docker.sock -D container create -itv /tmp:/tmp IMAGE'
    '/usr/bin/docker -ldebug run -e=A=1 --rm IMAGE sh'
    'id="$(docker run -d IMAGE)"'
    'echo "`docker run IMAGE`"'
    "sh -c 'docker run IMAGE'"
    'bash -c "docker run --rm IMAGE true"'
)
for step in "${steps[@]}"; do
    unpinned=${step//IMAGE/alpine:3.22}
    case "$step" in *create*) command=create ;; *) command=run ;; esac
    if check_step "$unpinned"; then
        fail "a step running '$unpinned' passed: $(cat "$fixture_root/out")"
    fi
    grep -Fq "fixture.yml job fixture: docker $command alpine:3.22 is not pinned by tag and digest" "$fixture_root/out" ||
        fail "'$unpinned' must be reported as docker $command alpine:3.22: $(cat "$fixture_root/out")"
    check_step "${step//IMAGE/$hadolint}" ||
        fail "a step running '${step//IMAGE/$hadolint}' was refused: $(cat "$fixture_root/out")"
done
# A global flag this test does not know could take the next word or not: the
# docker run behind it is reported rather than guessed at. A docker that is
# no command, as in find docker -name, is left alone.
if check_step "docker --unknown x run $hadolint"; then
    fail "a docker run behind an unknown global flag passed: $(cat "$fixture_root/out")"
fi
grep -Fq 'fixture.yml job fixture: a docker run or create whose image cannot be read' "$fixture_root/out" ||
    fail "a docker run behind an unknown global flag must be reported: $(cat "$fixture_root/out")"
check_step 'find docker -name Dockerfile' ||
    fail "find docker -name was taken for a docker command: $(cat "$fixture_root/out")"
# A quoted command line that cannot be split is reported when it names
# docker, and left alone otherwise.
if check_step "sh -c \"echo it's docker run $hadolint\""; then
    fail "a quoted docker command that cannot be split passed: $(cat "$fixture_root/out")"
fi
grep -Fq 'fixture.yml job fixture: a docker run whose image cannot be read' "$fixture_root/out" ||
    fail "a quoted docker command that cannot be split must be reported: $(cat "$fixture_root/out")"
check_step "echo \"it's fine\"" ||
    fail "a quoted line without docker that cannot be split was refused: $(cat "$fixture_root/out")"
echo "PASS: a docker run or create of an image pinned by tag only is found after a ;, in \$(...) or backquotes, quoted or not, in sh -c, behind global flags and short flag clusters"

# The token of a job is read-only: a permissions block that gives write
# access, at the top or on a job, in the mapping or the short form, is
# refused and named. The fixture job is called publish, as the release job
# that may write is: the allowance belongs to release.yml.
check_permissions() {
    printf 'name: fixture\non: push\n%sjobs:\n  publish:\n    runs-on: ubuntu-latest\n%s    steps:\n      - run: "true"\n' \
        "$1" "$2" > "$fixture_root/.github/workflows/fixture.yml"
    check_workflows "$fixture_root" > "$fixture_root/out" 2>&1
}
top_read=$'permissions:\n  contents: read\n'
refused=(
    $'permissions:\n  contents: write\n||: the permissions at the top give write access to contents'
    $'permissions: write-all\n||: the permissions at the top give write access to every scope (write-all)'
    $'permissions:\n  contents: read\n  id-token: write\n||: the permissions at the top give write access to id-token'
    "${top_read}|"$'    permissions:\n      contents: write\n| job publish: its token gets write access to contents,'
    "${top_read}|"$'    permissions:\n      contents: read\n      packages: write\n| job publish: its token gets write access to packages,'
    "${top_read}|"$'    permissions: write-all\n| job publish: its token gets write access to every scope (write-all),'
    $'|    permissions:\n      contents: write\n| job publish: its token gets write access to contents,'
    $'permissions:\n  contents: write\n|    permissions:\n      contents: read\n|: the permissions at the top give write access to contents'
)
for case in "${refused[@]}"; do
    IFS='|' read -r -d '' top job message < <(printf '%s\0' "$case") || true
    if check_permissions "$top" "$job"; then
        fail "a workflow with these permissions passed: ${top}${job}"
    fi
    grep -Fq ".github/workflows/fixture.yml${message}" "$fixture_root/out" ||
        fail "these permissions must be reported as '${message}': $(cat "$fixture_root/out")"
done
accepted=(
    "${top_read}|"
    $'permissions: read-all\n|'
    $'permissions: {}\n|'
    "${top_read}|"$'    permissions:\n      contents: none\n      packages: read\n'
    $'|    permissions:\n      contents: read\n'
    $'|    permissions: {}\n'
)
for case in "${accepted[@]}"; do
    IFS='|' read -r -d '' top job < <(printf '%s\0' "$case") || true
    check_permissions "$top" "$job" ||
        fail "a workflow with read-only permissions was refused: ${top}${job}: $(cat "$fixture_root/out")"
done
rm "$fixture_root/.github/workflows/fixture.yml"
# The same on the repository's own workflows: write access added to one of
# them is refused, and so is an allowance the release job no longer uses.
mutate_workflow() {
    local file=$1 from=$2 to=$3 message=$4
    cp "$ROOT_DIR/.github/workflows/$file" "$fixture_root/.github/workflows/$file"
    python3 - "$fixture_root/.github/workflows/$file" "$from" "$to" <<'PY'
import pathlib
import sys

path, old, new = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
text = path.read_text(encoding="utf-8")
if text.count(old) != 1:
    sys.exit(f"FAIL: {old!r} is not there once in {path.name}")
path.write_text(text.replace(old, new), encoding="utf-8")
PY
    if check_workflows "$fixture_root" > "$fixture_root/out" 2>&1; then
        fail "$file passed with '$to'"
    fi
    grep -Fq "$message" "$fixture_root/out" ||
        fail "$file with '$to' must be reported as '$message': $(cat "$fixture_root/out")"
    cp "$ROOT_DIR/.github/workflows/$file" "$fixture_root/.github/workflows/$file"
}
mutate_workflow tests.yml $'\npermissions:\n  contents: read\n' $'\npermissions:\n  contents: write\n' \
    '.github/workflows/tests.yml: the permissions at the top give write access to contents'
mutate_workflow release.yml $'      contents: read\n      packages: write\n' $'      contents: write\n      packages: write\n' \
    '.github/workflows/release.yml job images: its token gets write access to contents,'
mutate_workflow release.yml $'      contents: write\n      packages: read\n' $'      contents: read\n      packages: read\n' \
    '.github/workflows/release.yml job publish: TOKEN_WRITES of this test allows write access to contents, which the job no longer has'
mutate_workflow release.yml $'  publish:\n    name: publish\n' $'  publishing:\n    name: publish\n' \
    '.github/workflows/release.yml: TOKEN_WRITES of this test names the job publish, which is not there'
check_workflows "$fixture_root" > "$fixture_root/out" 2>&1 ||
    fail "the copy of the repository's workflows no longer passes: $(cat "$fixture_root/out")"
echo "PASS: a token with write access is refused at the top of a workflow and on a job, in the mapping and the short form, outside the two release jobs that publish"

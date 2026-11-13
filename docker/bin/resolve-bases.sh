#!/usr/bin/env bash
#
# Resolve every image this stack builds on, or runs, to an immutable digest
# and write docker/images.lock. The lock is what makes a build here and a
# build in the CI produce the same bytes: a tag moves, a digest does not.
#
#   resolve-bases.sh                    regenerate docker/images.lock, the
#                                       base defaults of the Dockerfiles and
#                                       the images the compose files pin
#   resolve-bases.sh --check            fail if the lock is not what the
#                                       registry serves today, or a
#                                       Dockerfile default or a pinned
#                                       compose image is not the lock
#   resolve-bases.sh --check-dockerfiles
#                                       only the Dockerfile defaults and the
#                                       pinned compose images against the
#                                       lock, and every Dockerfile under
#                                       docker/ listed below and built on
#                                       its default (no registry, no docker)
#   resolve-bases.sh --get NAME SERIES  print one pinned reference
#
# The tag of each entry is a human decision and lives in the tables below.
# Bump a tag here, run the script, commit the lock, the Dockerfiles and the
# compose files: the default of every Dockerfile, and the image of every
# service of COMPOSE_IMAGES, follows the entry of its name and series.

set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
LOCK_FILE=${IMAGES_LOCK:-${SCRIPT_DIR}/../images.lock}
DOCKER_DIR=${RESOLVE_BASES_DOCKER_DIR:-${SCRIPT_DIR}/..}

# The PHP series the PHP-FPM and cron images build when no PHP_VERSION is
# given: the default of their PHP_VERSION argument, and of PHP_VERSION in
# the compose files.
DEFAULT_PHP_SERIES=8.1

# Dockerfiles whose base build argument defaults to an entry of the lock, as
# file<TAB>argument<TAB>name<TAB>series of the entry. A plain "docker build",
# Compose and the release CI build from that default (the CI passes
# PHP_BASE only for the PHP series it publishes), so it has to be the
# locked reference. The entry is found by its name and series, never by the
# tag the default names: after a tag bump in the tables below, the default
# still names the old tag, and the entry of the new one replaces it.
DOCKERFILES=(
    "php/Dockerfile	PHP_BASE	php-fpm	${DEFAULT_PHP_SERIES}"
    "cron/Dockerfile	PHP_BASE	php-cli	${DEFAULT_PHP_SERIES}"
    "nginx/Dockerfile	NGINX_BASE	nginx	-"
    "init/Dockerfile	DEBIAN_BASE	debian	-"
    "manticore/Dockerfile	MANTICORE_BASE	manticore	-"
)

# Compose services whose image is an entry of the lock, as
# file<TAB>service<TAB>name<TAB>series of the entry. phpmyadmin-init runs
# init.sh with the BusyBox tools of its Alpine, the one the tests run it
# with and a release pins: a stack without a release would otherwise run
# whatever alpine:latest is on the day it pulls.
COMPOSE_IMAGES=(
    "docker-compose.yml	phpmyadmin-init	alpine	-"
    "multi-site/docker-compose.site.yml.template	phpmyadmin-init	alpine	-"
)

# name<TAB>series<TAB>tag. "-" is the series of an image that does not vary.
# php-fpm and php-cli carry one line per series setup.sh may select
# (SUPPORTED_PHP_VERSIONS). PHP 7.4 has none: its php:7.4-* images are
# Debian 11, which lacks packages the PHP-FPM and cron images install.
BUILD_BASES=(
    "php-fpm	8.1	php:8.1-fpm"
    "php-fpm	8.2	php:8.2-fpm"
    "php-fpm	8.3	php:8.3-fpm"
    "php-fpm	8.4	php:8.4-fpm"
    "php-cli	8.1	php:8.1-cli"
    "php-cli	8.2	php:8.2-cli"
    "php-cli	8.3	php:8.3-cli"
    "php-cli	8.4	php:8.4-cli"
    "nginx	-	nginx:mainline"
    "debian	-	debian:trixie-slim"
    "manticore	-	manticoresearch/manticore:29.9.0"
)

# Images the compose file runs as they are. They are not build bases, but a
# release pins them too, so they are resolved here as well. mariadb carries
# one line per series setup.sh offers (MARIADB_LTS_VERSIONS), each on the
# newest patch tag of its series: a stack keeps its series across releases,
# so a series missing here is a stack no release can upgrade.
RUNTIME_IMAGES=(
    "mariadb	11.4	mariadb:11.4.13"
    "mariadb	11.8	mariadb:11.8.9"
    "mariadb	12.3	mariadb:12.3.3"
    "memcached	-	memcached:1.6.45-alpine"
    "dragonfly	-	docker.dragonflydb.io/dragonflydb/dragonfly:v1.35.1"
    "acme	-	neilpang/acme.sh:3.1.6"
    "alpine	-	alpine:3.24.2"
)

die() {
    printf 'resolve-bases: %s\n' "$*" >&2
    exit 1
}

require_docker() {
    command -v docker >/dev/null 2>&1 ||
        die "docker is required to read a registry digest"
    docker buildx version >/dev/null 2>&1 ||
        die "docker buildx is required (docker buildx imagetools inspect)"
    command -v sha256sum >/dev/null 2>&1 ||
        die "sha256sum is required to compute the digest of a manifest"
}

# Print the digest of the manifest a tag points at. For a multi-platform tag
# this is the index digest, which is what FROM and docker pull accept. The
# digest of a manifest is the sha256 of its bytes, which --raw prints as the
# registry served them: buildx fetches that one manifest. A --format template
# would make it fetch the index again and every manifest the index lists,
# one per platform and one per attestation, and Docker Hub counts manifest
# fetches against its pull limit.
resolve_digest() {
    local ref=$1 sum

    sum=$(docker buildx imagetools inspect --raw "$ref" 2>/dev/null | sha256sum) ||
        die "cannot read the digest of $ref"
    # No answer at all has a sha256 too, but it is no manifest.
    [ "$sum" != "$(sha256sum </dev/null)" ] || die "$ref returned an empty manifest"
    printf 'sha256:%s' "${sum%% *}"
}

# Bash runs a command substitution without errexit, and the lock is built
# inside one: every failure is passed on by hand, or a registry that refuses
# an answer (a rate limit) would leave a lock line with no digest, and
# --check would call the lock stale instead of naming the failure.
emit_table() {
    local entry name series tag digest

    for entry in "$@"; do
        IFS=$'\t' read -r name series tag <<<"$entry"
        digest=$(resolve_digest "$tag") || return 1
        printf '%s\t%s\t%s@%s\n' "$name" "$series" "$tag" "$digest"
    done
}

generate() {
    cat <<'HEADER'
# Generated by docker/bin/resolve-bases.sh. Do not edit by hand.
#
# name<TAB>series<TAB>reference@digest
#
# A tag moves, a digest does not. Every Dockerfile takes its base as a build
# argument (PHP_BASE, NGINX_BASE, DEBIAN_BASE, MANTICORE_BASE) whose default
# is the line below for the default series, so a plain "docker build" and the
# release CI resolve the same bytes. Building another PHP series means
# passing the PHP_BASE of that series:
#
#   docker build --build-arg PHP_VERSION=8.3 \
#       --build-arg PHP_BASE="$(docker/bin/resolve-bases.sh --get php-fpm 8.3)" \
#       docker/php
#
# PHP 7.4 has no line: its php:7.4-* images are Debian 11, which lacks
# packages the PHP-FPM and cron images install, and receive no security
# update. setup.sh refuses a KVS archive that needs it.
HEADER
    printf '#\n# Resolved on %s.\n\n' "$(date -u +%Y-%m-%d)"
    printf '# Build bases\n'
    emit_table "${BUILD_BASES[@]}" || return 1
    printf '\n# Images the compose file runs unchanged\n'
    emit_table "${RUNTIME_IMAGES[@]}" || return 1
}

# The reference the lock pins for an entry, by its name and series.
lock_entry() {
    local lock=$1 want_name=$2 want_series=$3 name series ref

    while IFS=$'\t' read -r name series ref; do
        case "$name" in ''|'#'*) continue ;; esac
        if [ "$name" = "$want_name" ] && [ "$series" = "$want_series" ]; then
            printf '%s\n' "$ref"
            return 0
        fi
    done <"$lock"
    return 1
}

# Print what keeps a Dockerfile from building on its base argument, one line
# each, and fail if anything does. The default of ARG <arg> is what the lock
# pins, so it must be declared once, before the first FROM: a second ARG
# <arg>= line replaces the first default for the global FROM, and one in a
# stage is read by no FROM. Every FROM names ${<arg>}, ${<name>} of an
# argument declared once before the first FROM and after ARG <arg>=, with
# the default ${<arg>} or ${<arg>:-...} (PHP_FROM of the php and cron
# images), or a stage defined before it, by name: Docker expands the default
# of a global argument with the arguments declared before it only. COPY
# --from names an earlier stage or its number, and every from= of RUN
# --mount an earlier stage, never an image.
#
# The lines are read with these rules of the Dockerfile parser of Docker,
# for its default escape character: a byte order mark is dropped, and so are
# carriage returns at the end of a line; a line ending in a backslash
# continues on the next line, joined as it is; comment and blank lines are
# skipped without ending a continuation. Instructions match in any case, the
# flags of FROM, COPY, RUN and ADD lose their quotes and backslashes and end
# at a lone --, and a mount is read as the CSV field list it is, its keys in
# any case. The words are split on spaces and tabs only, so what Docker
# could read another way is refused instead: a NUL byte, a line holding a
# vertical tab, a form feed or a carriage return, a byte outside printable
# ASCII anywhere, comments included (Docker takes a no-break or an
# ideographic space for a space, even between the # and the name of a parser
# directive), a comment that reads as a syntax or escape parser directive,
# which changes how the file is read, a flag with a quote that runs past its
# word or a backslash at its end, either of which makes Docker read the next
# word into the flag, and a word Docker takes for a heredoc, whose body is
# not instructions: digits, <<, an optional dash and a name without < in one
# word, or a word of digits and << followed by another word, the name (with
# a dash as well, which Docker does not take for one). Quotes are not
# followed there, so a << between spaces is refused even inside a quoted
# "$((1 << 3))", which Docker does not read as a heredoc.
dockerfile_structure() {
    local nul

    # BusyBox awk ends a line at a NUL byte and never reads what follows it
    # on that line, which Docker does: the file is refused before awk reads
    # it, with the line of its first NUL. awk reads all that od prints, so
    # od never dies on a closed pipe, and a failure of either fails the check.
    if ! nul=$(od -An -v -tu1 "$1" | awk '{
        for (i = 1; i <= NF && !found; i++) {
            if ($i == 0) found = line + 1
            else if ($i == 10) line++
        }
    } END { if (found) print found }'); then
        printf 'cannot be read with od, which looks for a NUL byte\n'
        return 1
    fi
    if [ -n "$nul" ]; then
        printf 'line %s: holds a NUL byte, which this check does not read\n' "$nul"
        return 1
    fi
    LC_ALL=C awk -v arg="$2" -v bom="$(printf '\357\273\277')" '
        function problem(message) { print message; bad = 1 }
        function is_stage(source) { return tolower(source) in stages }
        # A stage number names one of the stages defined so far.
        function is_stage_number(source) { return source ~ /^[0-9]+$/ && source + 0 < froms }
        # ${<arg>}, or ${<arg>:-<default>} as one expansion.
        function derives(value,    prefix, i, c, depth) {
            if (value == "${" arg "}") return 1
            prefix = "${" arg ":-"
            if (index(value, prefix) != 1) return 0
            depth = 1
            for (i = length(prefix) + 1; i <= length(value); i++) {
                c = substr(value, i, 1)
                if (c == "{") depth++
                if (c == "}") {
                    depth--
                    if (depth == 0) return i == length(value)
                }
            }
            return 0
        }
        function base_ref(ref,    name) {
            if (ref == "${" arg "}") return 1
            if (ref !~ /^\$\{[A-Za-z_][A-Za-z0-9_]*\}$/) return 0
            name = substr(ref, 3, length(ref) - 3)
            return (name in derived) && declared[name] == 1
        }
        # A flag word without its quotes, a backslash keeping the character
        # after it. unclosed is set when a quote runs past the word.
        function unquote(word,    out, i, c, quote) {
            out = ""
            quote = ""
            for (i = 1; i <= length(word); i++) {
                c = substr(word, i, 1)
                if (c == "\\") {
                    if (i < length(word)) out = out substr(word, ++i, 1)
                } else if (quote != "") {
                    if (c == quote) quote = ""
                    else out = out c
                } else if (c == "\"" || c == "\047") {
                    quote = c
                } else {
                    out = out c
                }
            }
            unclosed = quote != ""
            return out
        }
        # A flag word of an instruction without its quotes and backslashes,
        # or "" when Docker could read more into it: a quote that runs past
        # the word keeps the spaces after it, and a backslash at its end
        # joins the next word to it.
        function flag(raw, instruction,    word) {
            word = unquote(raw)
            if (unclosed || raw ~ /\\$/) {
                problem("line " start ": " instruction " " raw " has a quote or a backslash this check does not read")
                return ""
            }
            return word
        }
        # The fields of a CSV record into fields[1..n], or -1 when it is not
        # one: a quoted field is closed by a lone quote, "" stands for a quote,
        # and a quote inside an unquoted field is an error.
        function csv(record, fields,    n, i, c, field, quoted, closed) {
            n = 0
            i = 1
            while (1) {
                field = ""
                if (substr(record, i, 1) == "\"") {
                    closed = 0
                    for (i++; i <= length(record); i++) {
                        c = substr(record, i, 1)
                        if (c != "\"") { field = field c; continue }
                        if (substr(record, i + 1, 1) == "\"") { field = field c; i++; continue }
                        closed = 1
                        i++
                        break
                    }
                    if (!closed) return -1
                    c = substr(record, i, 1)
                    if (c != "," && c != "") return -1
                } else {
                    for (; i <= length(record); i++) {
                        c = substr(record, i, 1)
                        if (c == ",") break
                        if (c == "\"") return -1
                        field = field c
                    }
                }
                fields[++n] = field
                if (substr(record, i, 1) != ",") return n
                i++
            }
        }
        function mount(value, instruction,    fields, n, i, key, source) {
            n = csv(value, fields)
            if (n < 0) {
                problem("line " start ": " instruction " --mount=" value " is not a field list this check reads")
                return
            }
            for (i = 1; i <= n; i++) {
                key = fields[i]
                sub(/=.*/, "", key)
                if (tolower(key) != "from" || index(fields[i], "=") == 0) continue
                source = substr(fields[i], length(key) + 2)
                if (!is_stage(source))
                    problem("line " start ": " instruction " --mount from=" source " is not an earlier stage")
            }
        }
        function read_instruction(line,    n, w, name, i, value, ref, word, source, rest) {
            sub(/^[ \t]+/, "", line)
            sub(/[ \t]+$/, "", line)
            n = split(line, w, /[ \t]+/)
            name = toupper(w[1])
            # A heredoc: a word of digits, << and an optional dash followed
            # by another word, the name (Docker reads "<<- x" as none, but
            # it is refused all the same), or digits, <<, an optional dash,
            # then a name without "<" in one word (so neither << alone nor a
            # <<< here-string).
            for (i = 1; i <= n; i++) {
                if (w[i] ~ /^[0-9]*<<-?$/ && i < n) {
                    problem("line " start ": " name " has a heredoc (" w[i] " " w[i + 1] "), whose body this check does not read")
                    break
                }
                if (!match(w[i], /^[0-9]*<<-?/)) continue
                rest = substr(w[i], RLENGTH + 1)
                if (rest != "" && index(rest, "<") == 0) {
                    problem("line " start ": " name " has a heredoc (" w[i] "), whose body this check does not read")
                    break
                }
            }
            if (name == "ARG") {
                for (i = 2; i <= n; i++) {
                    if (w[i] !~ /^[A-Za-z_][A-Za-z0-9_]*=/) continue
                    ref = w[i]
                    sub(/=.*/, "", ref)
                    value = substr(w[i], length(ref) + 2)
                    declared[ref]++
                    if (froms == 0) global[ref]++
                    # Derived only from the one ARG <arg>= already declared.
                    if (ref != arg && froms == 0 && global[arg] == 1 && derives(value)) {
                        derived[ref] = 1
                        if (!(ref in ever_derived)) {
                            ever_derived[ref] = 1
                            derived_order[++derived_count] = ref
                        }
                    } else {
                        delete derived[ref]
                    }
                }
            } else if (name == "FROM") {
                # Its flags are read like those of COPY: a lone -- ends them.
                for (i = 2; i <= n && w[i] ~ /^--/; i++)
                    if (flag(w[i], name) == "--") { i++; break }
                ref = w[i]
                if (!base_ref(ref) && !is_stage(ref))
                    problem("line " start ": FROM " ref " does not build on ${" arg "} or an earlier stage")
                if (i + 2 <= n && toupper(w[i + 1]) == "AS") stages[tolower(w[i + 2])] = 1
                froms++
            } else if (name == "COPY" || name == "RUN" || name == "ADD") {
                for (i = 2; i <= n && w[i] ~ /^--/; i++) {
                    word = flag(w[i], name)
                    if (word == "--") break
                    if (index(word, "--from=") == 1) {
                        source = substr(word, 8)
                        if (!is_stage(source) && !is_stage_number(source))
                            problem("line " start ": " name " --from=" source " is not an earlier stage")
                    } else if (index(word, "--mount=") == 1) {
                        mount(substr(word, 9), name)
                    }
                }
            }
        }
        {
            raw = $0
            if (NR == 1 && index(raw, bom) == 1) raw = substr(raw, length(bom) + 1)
            sub(/\r+$/, "", raw)
            unread = raw ~ /[\013\014\015]/
            if (unread)
                problem("line " NR ": holds a vertical tab, a form feed or a carriage return, which this check does not read")
            trimmed = raw
            sub(/^[ \t]+/, "", trimmed)
            # Comments included: "#<no-break space>escape=`" is a directive.
            if (!unread && raw ~ /[^\t -~]/)
                problem("line " NR ": holds a byte outside printable ASCII, which this check does not read")
            if (trimmed ~ /^#/) {
                if (tolower(trimmed) ~ /^#[ \t]*(syntax|escape)[ \t]*=/)
                    problem("line " NR ": the parser directive " trimmed " changes how the file is read, which this check does not follow")
                next
            }
            if (trimmed == "") next
            if (continued) {
                line = line raw
            } else {
                start = NR
                line = trimmed
            }
            continued = line ~ /\\[ \t]*$/
            if (continued) {
                sub(/\\[ \t]*$/, "", line)
                next
            }
            read_instruction(line)
        }
        END {
            if (continued) read_instruction(line)
            if (declared[arg] != 1) problem("declares ARG " arg "= " (declared[arg] + 0) " times instead of once")
            else if (global[arg] != 1) problem("declares ARG " arg "= after the first FROM, where no FROM reads it")
            for (i = 1; i <= derived_count; i++)
                if (declared[derived_order[i]] != 1)
                    problem("declares ARG " derived_order[i] "= " declared[derived_order[i]] " times instead of once")
            if (!froms) problem("has no FROM line")
            exit bad
        }' "$1"
}

# Every Dockerfile under the docker directory is in DOCKERFILES, and each of
# them builds on its base argument. Prints what is wrong and fails if
# anything is, before anything is resolved or compared.
dockerfile_structures() {
    local found listed entry file arg path problems line status=0

    # Dockerfile.dockerignore is the ignore file of a Dockerfile, not one.
    found=$(cd "$DOCKER_DIR" && find . ! -type d \( -name Dockerfile -o -name 'Dockerfile.*' \
        -o -name '*.Dockerfile' -o -name '*.dockerfile' -o -name Containerfile \) \
        ! -name '*.dockerignore' -print) ||
        die "cannot list the Dockerfiles under $DOCKER_DIR"
    listed=$'\n'
    for entry in "${DOCKERFILES[@]}"; do
        listed+="./${entry%%$'\t'*}"$'\n'
    done
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        case "$listed" in *$'\n'"$path"$'\n'*) continue ;; esac
        printf 'resolve-bases: %s is not in DOCKERFILES, so nothing checks what it builds on\n' "${path#./}" >&2
        status=1
    done <<<"$found"
    for entry in "${DOCKERFILES[@]}"; do
        IFS=$'\t' read -r file arg _ <<<"$entry"
        path="${DOCKER_DIR}/${file}"
        [ -f "$path" ] || die "$path does not exist"
        if ! problems=$(dockerfile_structure "$path" "$arg"); then
            while IFS= read -r line; do
                printf 'resolve-bases: %s %s\n' "$file" "$line" >&2
            done <<<"$problems"
            status=1
        fi
    done
    return "$status"
}

# Compare (check) or align (write) the base default of every Dockerfile with
# the lock.
dockerfile_bases() {
    local mode=$1 lock=$2 entry file arg name series path line ref locked status=0

    [ -f "$lock" ] || die "$lock does not exist"
    for entry in "${DOCKERFILES[@]}"; do
        IFS=$'\t' read -r file arg name series <<<"$entry"
        path="${DOCKER_DIR}/${file}"
        [ -f "$path" ] || die "$path does not exist"
        line=$(grep -m 1 -E "^ARG ${arg}=" "$path") ||
            die "$path has no ARG ${arg}= line"
        ref=${line#*=}
        locked=$(lock_entry "$lock" "$name" "$series") ||
            die "$file builds on the $name $series entry, which $lock does not have"
        [ "$ref" != "$locked" ] || continue
        if [ "$mode" = write ]; then
            sed -i "s|^ARG ${arg}=.*\$|ARG ${arg}=${locked}|" "$path"
            printf 'updated %s\n' "$file"
        else
            printf 'resolve-bases: %s: %s=%s, the lock pins %s\n' "$file" "$arg" "$ref" "$locked" >&2
            status=1
        fi
    done
    return "$status"
}

# The line number and the reference of the image of a service in a compose
# file, tab separated: the image key of the service block, which ends at the
# next key of the service level or above. Comments do not end it.
service_image() {
    awk -v service="  $2:" '
        $0 == service { inside = 1; next }
        inside && /^[^ #]|^ [^ #]|^  [^ #]/ { exit }
        inside && /^    image: / { sub(/^    image: /, ""); print NR "\t" $0; found = 1; exit }
        END { exit !found }' "$1"
}

# Compare (check) or align (write) the image of every service of
# COMPOSE_IMAGES with the lock.
compose_images() {
    local mode=$1 lock=$2 entry file service name series path found number ref locked status=0

    [ -f "$lock" ] || die "$lock does not exist"
    for entry in "${COMPOSE_IMAGES[@]}"; do
        IFS=$'\t' read -r file service name series <<<"$entry"
        path="${DOCKER_DIR}/${file}"
        [ -f "$path" ] || die "$path does not exist"
        found=$(service_image "$path" "$service") ||
            die "$path has no image line for the service $service"
        number=${found%%$'\t'*}
        ref=${found#*$'\t'}
        locked=$(lock_entry "$lock" "$name" "$series") ||
            die "$file runs the $name $series entry for $service, which $lock does not have"
        [ "$ref" != "$locked" ] || continue
        if [ "$mode" = write ]; then
            sed -i "${number}s|^    image: .*\$|    image: ${locked}|" "$path"
            printf 'updated %s\n' "$file"
        else
            printf 'resolve-bases: %s: the image of %s is %s, the lock pins %s\n' "$file" "$service" "$ref" "$locked" >&2
            status=1
        fi
    done
    return "$status"
}

lookup() {
    local want_name=$1 want_series=${2:--}

    [ -f "$LOCK_FILE" ] || die "$LOCK_FILE does not exist"
    lock_entry "$LOCK_FILE" "$want_name" "$want_series" ||
        die "no entry for $want_name $want_series in $LOCK_FILE"
}

# The structure of every Dockerfile, then, when it holds, its base default
# against the lock.
check_dockerfiles() {
    dockerfile_structures || return 1
    dockerfile_bases check "$LOCK_FILE"
}

# Stop when a Dockerfile default or a compose image is not the lock: the
# checks name each of them first, then the first failure stops the script.
stop_off_lock() {
    [ "$1" -eq 1 ] || die "a Dockerfile does not build on the lock; run docker/bin/resolve-bases.sh"
    [ "$2" -eq 1 ] || die "a compose file does not run the image of the lock; run docker/bin/resolve-bases.sh"
}

main() {
    local generated dockerfiles_ok=1 compose_ok=1

    case "${1:-}" in
        --get)
            [ $# -ge 2 ] || die "--get needs a name and an optional series"
            lookup "$2" "${3:--}"
            ;;
        --check)
            require_docker
            [ -f "$LOCK_FILE" ] || die "$LOCK_FILE does not exist"
            check_dockerfiles || dockerfiles_ok=0
            compose_images check "$LOCK_FILE" || compose_ok=0
            generated=$(generate) || exit 1
            # The generation date is the only line allowed to differ.
            if diff -u \
                <(grep -v '^# Resolved on ' "$LOCK_FILE") \
                <(printf '%s\n' "$generated" | grep -v '^# Resolved on '); then
                echo "images.lock matches the registry"
            else
                die "images.lock is stale; run docker/bin/resolve-bases.sh"
            fi
            stop_off_lock "$dockerfiles_ok" "$compose_ok"
            ;;
        --check-dockerfiles)
            check_dockerfiles || dockerfiles_ok=0
            compose_images check "$LOCK_FILE" || compose_ok=0
            stop_off_lock "$dockerfiles_ok" "$compose_ok"
            echo "the Dockerfiles build on the lock and the compose files run its images"
            ;;
        ''|--write)
            # A default nothing builds on is not worth a lock line: the
            # Dockerfiles are checked before anything is resolved or written.
            dockerfile_structures ||
                die "a Dockerfile does not build on its base argument; nothing was written"
            require_docker
            # Resolved in full before anything is written, so a failure
            # leaves the lock as it was.
            generated=$(generate) || exit 1
            printf '%s\n' "$generated" >"${LOCK_FILE}.tmp"
            mv -- "${LOCK_FILE}.tmp" "$LOCK_FILE"
            printf 'wrote %s\n' "$LOCK_FILE"
            dockerfile_bases write "$LOCK_FILE"
            compose_images write "$LOCK_FILE"
            ;;
        -h|--help)
            # The comment at the top of this file, up to its first blank line.
            awk 'NR > 1 && /^#/ { print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
}

main "$@"

"""Compare local COPY inputs by their installed paths in the two PHP images."""

import json
import posixpath
import re
import shlex
import sys
from pathlib import Path


def copied_files(context, service_only):
    files = {}
    lines = (context / "Dockerfile").read_text().splitlines(keepends=True)
    instructions = "".join(line for line in lines if not line.lstrip().startswith("#"))
    for line in instructions.replace("\\\n", " ").splitlines():
        copy = re.match(r"^\s*COPY\s+(.+)$", line, re.IGNORECASE)
        if not copy:
            continue
        args = copy[1].strip()
        flags = []
        while args.startswith("--"):
            flag, args = args.split(None, 1)
            flags.append(flag)
        if any(flag.startswith("--from=") for flag in flags):
            continue
        *sources, dest = json.loads(args) if args.startswith("[") else shlex.split(args)
        if not sources or not dest.startswith("/"):
            sys.exit(f"{context}/Dockerfile: expected COPY of local files to an absolute path: {line}")
        for source in sources:
            # Docker resolves sources from the build context, even with a leading slash.
            path = context / posixpath.normpath("/" + source.lstrip("/")).lstrip("/")
            target = posixpath.normpath(posixpath.join(dest, path.name) if dest.endswith("/") else dest)
            if target in service_only:
                continue
            if target in files or not path.is_file():
                sys.exit(f"{context}/Dockerfile: expected one local file for {target}: {line}")
            files[target] = path
    return files


def main(php, cron):
    entrypoint = "/usr/local/bin/docker-entrypoint.sh"
    php_files = copied_files(php, {entrypoint, "/usr/local/lib/kvs/fpm-config.sh"})
    cron_files = copied_files(cron, {
        entrypoint, "/etc/cron.d/kvs-cron", "/etc/cron.d/yt-dlp-update",
        "/etc/cron.d/cron-log-rotate", "/usr/local/bin/yt-dlp-update",
        "/usr/local/bin/kvs-cron-run", "/usr/local/bin/kvs-cron-health",
    })
    for dest in sorted(php_files.keys() | cron_files.keys()):
        if dest not in php_files or dest not in cron_files:
            missing = php if dest not in php_files else cron
            sys.exit(f"{missing}/Dockerfile: missing local COPY for {dest}")
        left, right = php_files[dest], cron_files[dest]
        if left.read_bytes() != right.read_bytes():
            sys.exit(f"Different files for {dest}: {left} and {right}")


if __name__ == "__main__":
    main(Path(sys.argv[1]), Path(sys.argv[2]))

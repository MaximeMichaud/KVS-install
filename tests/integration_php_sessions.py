#!/usr/bin/env python3
"""Check that PHP sessions outlive a recreated PHP-FPM container.

Run with python3 tests/integration_php_sessions.py IMAGE [--previous-image
IMAGE]. The php-fpm service of docker/docker-compose.yml, as Compose renders
it, runs under a temporary Compose project with the stack's php.ini and the
php-sessions volume, a synthetic PHP script and no application data. A
session is written, the container recreated the way an upgrade recreates
it, then removed and created again, and the session must still be there;
the garbage collector of PHP must still remove an expired one. Without the
volume, as with a compose file older than it, the sessions must work from
/tmp, and a recreated container loses them, as before. --previous-image,
an image released before the volume, must work on the volume Compose now
mounts, and IMAGE must then take that volume over.
"""

import argparse
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
SESSIONS = "/var/lib/php/sessions"
# Settings exported by the caller would change what Compose reads.
ENV = {key: value for key, value in os.environ.items() if not key.startswith("COMPOSE_")}


def run(*args, check=True):
    return subprocess.run(args, check=check, capture_output=True, text=True, timeout=120, env=ENV)


def record(kind, data):
    return struct.pack("!BBHHBB", 1, kind, 1, len(data), 0, 0) + data


def read_exact(connection, size):
    data = b""
    while len(data) < size:
        chunk = connection.recv(size - len(data))
        if not chunk:
            raise EOFError("FPM closed the request")
        data += chunk
    return data


def request(port, query="", session=None):
    params = {
        "SCRIPT_FILENAME": "/var/www/kvs/session.php",
        "SCRIPT_NAME": "/session.php",
        "REQUEST_METHOD": "GET",
        "QUERY_STRING": query,
        "REQUEST_URI": "/session.php" + ("?" + query if query else ""),
        "SERVER_PROTOCOL": "HTTP/1.1",
        "GATEWAY_INTERFACE": "CGI/1.1",
        "SERVER_NAME": "localhost",
        "SERVER_PORT": "80",
    }
    if session:
        params["HTTP_COOKIE"] = "PHPSESSID=" + session
    pairs = b"".join(
        bytes([len(key), len(value)]) + key.encode() + value.encode()
        for key, value in params.items()
    )
    payload = record(1, struct.pack("!HB5x", 1, 0))
    payload += record(4, pairs) + record(4, b"") + record(5, b"")
    stdout = b""
    with socket.create_connection(("127.0.0.1", port), timeout=5) as connection:
        connection.sendall(payload)
        while True:
            _, kind, _, size, padding, _ = struct.unpack("!BBHHBB", read_exact(connection, 8))
            data = read_exact(connection, size)
            read_exact(connection, padding)
            if kind == 6:
                stdout += data
            if kind == 3:
                return json.loads(stdout.split(b"\r\n\r\n", 1)[1])


class Project:
    """A Compose project running the rendered php-fpm service alone."""

    def __init__(self, work, service, with_volume):
        self.name = "kvs-sessions-test-" + uuid.uuid4().hex[:12]
        self.file = work / (self.name + ".json")
        self.service = service
        self.with_volume = with_volume

    def compose(self, *args, check=True):
        return run("docker", "compose", "-p", self.name, "-f", str(self.file), *args, check=check)

    def start(self, image, *options):
        service = dict(self.service, image=image, pull_policy="never", restart="no")
        if not self.with_volume:
            service["volumes"] = [v for v in service["volumes"] if v["target"] != SESSIONS]
        project = {"services": {"php-fpm": service}}
        if self.with_volume:
            project["volumes"] = {"php-sessions": {}}
        self.file.write_text(json.dumps(project))
        self.compose("up", "-d", *options, "php-fpm")
        self.container = self.compose("ps", "-q", "php-fpm").stdout.strip()
        address = self.compose("port", "php-fpm", "9000").stdout.strip()
        self.port = int(address.rsplit(":", 1)[1])
        for _ in range(100):
            try:
                return request(self.port)
            except (OSError, EOFError, IndexError, ValueError):
                time.sleep(0.1)
        raise AssertionError("FPM never answered")

    def logs(self):
        result = self.compose("logs", "--no-color", "php-fpm", check=False)
        return result.stdout + result.stderr

    def execute(self, *args, user="root"):
        return run("docker", "exec", "-u", user, self.container, *args).stdout.strip()

    def remove(self):
        self.compose("down", "--volumes", "--remove-orphans", check=False)


def rendered_service(webroot):
    with tempfile.NamedTemporaryFile("w", suffix=".env") as env_file:
        env_file.write("DOMAIN=sessions.fixture.test\nSITE_PREFIX=kvs-sessions\n"
                       "MARIADB_PASSWORD=fixture\nMARIADB_ROOT_PASSWORD=fixture\n")
        env_file.flush()
        rendered = json.loads(run("docker", "compose", "--env-file", env_file.name, "-f",
                                  str(ROOT / "docker/docker-compose.yml"),
                                  "config", "--format", "json").stdout)
    service = rendered["services"]["php-fpm"]
    volumes = [v for v in service["volumes"]
               if v["target"] in ("/usr/local/etc/php/conf.d/kvs.ini", SESSIONS)]
    assert sorted(v["target"] for v in volumes) == ["/usr/local/etc/php/conf.d/kvs.ini", SESSIONS], \
        "docker-compose.yml must mount php.ini and the php-sessions volume in php-fpm"
    volumes.append(dict(type="bind", source=str(webroot), target="/var/www/kvs", read_only=True))
    environment = dict(service["environment"], KVS_MEMCACHE_LOOPBACK="false",
                       YT_DLP_AUTO_UPDATE="no", PHP_FPM_MAX_CHILDREN="2",
                       PHP_FPM_START_SERVERS="1", PHP_FPM_MIN_SPARE_SERVERS="1",
                       PHP_FPM_MAX_SPARE_SERVERS="1")
    # Only the runtime of the service: its name, network, database and
    # build belong to a real stack.
    return dict(environment=environment, volumes=volumes, ports=["127.0.0.1::9000"])


def check_volume(work, service, image):
    project = Project(work, service, with_volume=True)
    try:
        assert project.start(image)["path"] == SESSIONS, "the sessions must go to the volume"
        assert f"PHP sessions kept in the php-sessions volume ({SESSIONS})" in project.logs()
        first = request(project.port, "set=kept")
        assert project.execute("stat", "-c", "%U:%G %a", SESSIONS) == "www-data:www-data 700"
        assert project.execute("stat", "-c", "%U %a", f"{SESSIONS}/sess_{first['id']}") == "www-data 600"
        before = project.container
        # What an upgrade does when the image or the service changes.
        project.start(image, "--force-recreate")
        assert project.container != before, "compose did not recreate the container"
        assert request(project.port, session=first["id"])["token"] == "kept", \
            "the session was lost when the container was recreated"
        project.compose("down")
        project.start(image)
        assert request(project.port, session=first["id"])["token"] == "kept", \
            "the session was lost when the container was removed and created again"
        expired = request(project.port, "set=expired")["id"]
        project.execute("touch", "-d", "-2 days", f"{SESSIONS}/sess_{expired}", user="www-data")
        deleted = request(project.port, "gc=1", session=first["id"])["deleted"]
        assert deleted >= 1, f"the garbage collector removed {deleted} sessions"
        names = project.execute("ls", SESSIONS).split()
        assert f"sess_{expired}" not in names and f"sess_{first['id']}" in names, names
    except Exception:
        print(project.logs())
        raise
    finally:
        project.remove()


def check_without_volume(work, service, image):
    project = Project(work, service, with_volume=False)
    try:
        assert project.start(image)["path"] == "", "without the volume the sessions stay in /tmp"
        assert f"no volume is mounted on {SESSIONS}, so the PHP sessions stay in /tmp" in project.logs()
        first = request(project.port, "set=lost")
        assert request(project.port, session=first["id"])["token"] == "lost"
        project.start(image, "--force-recreate")
        assert request(project.port, session=first["id"])["token"] is None, \
            "a session in /tmp cannot outlive its container: the check is broken"
    except Exception:
        print(project.logs())
        raise
    finally:
        project.remove()


def check_previous_image(work, service, image, previous):
    project = Project(work, service, with_volume=True)
    try:
        # The image of the previous release ignores the volume Compose now
        # mounts, which Docker creates owned by root, and keeps working.
        assert project.start(previous)["path"] == "", "the previous image must keep the sessions in /tmp"
        old = request(project.port, "set=old")
        assert request(project.port, session=old["id"])["token"] == "old", \
            "the previous image lost its sessions on the new compose file"
        assert project.start(image)["path"] == SESSIONS
        assert project.execute("stat", "-c", "%U:%G %a", SESSIONS) == "www-data:www-data 700", \
            "the entrypoint must take over the volume the previous image created"
        new = request(project.port, "set=new")
        project.start(image, "--force-recreate")
        assert request(project.port, session=new["id"])["token"] == "new"
    except Exception:
        print(project.logs())
        raise
    finally:
        project.remove()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("image")
    parser.add_argument("--previous-image")
    args = parser.parse_args()
    for image in filter(None, (args.image, args.previous_image)):
        run("docker", "image", "inspect", image)
    with tempfile.TemporaryDirectory(prefix="php-sessions-") as directory:
        work = Path(directory)
        work.chmod(0o755)
        webroot = work / "www"
        webroot.mkdir(mode=0o755)
        (webroot / "session.php").write_text("""<?php
header('Content-Type: application/json');
session_start();
if (isset($_GET['set'])) {
    $_SESSION['token'] = $_GET['set'];
}
echo json_encode([
    'id' => session_id(),
    'token' => $_SESSION['token'] ?? null,
    'path' => session_save_path(),
    'deleted' => isset($_GET['gc']) ? session_gc() : null,
]);
""")
        (webroot / "session.php").chmod(0o644)
        service = rendered_service(webroot)
        check_volume(work, service, args.image)
        print(f"PASS: {args.image} keeps its sessions in the php-sessions volume across recreations")
        check_without_volume(work, service, args.image)
        print(f"PASS: {args.image} keeps its sessions in /tmp without the volume")
        if args.previous_image:
            check_previous_image(work, service, args.image, args.previous_image)
            print(f"PASS: {args.previous_image} works on the new compose file and {args.image} takes the volume over")


if __name__ == "__main__":
    main()

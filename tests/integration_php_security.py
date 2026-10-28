#!/usr/bin/env python3
"""Check a built PHP/cron image and, for FPM, real consecutive requests.

Run with python3 tests/integration_php_security.py IMAGE
VERSION [--fpm]. Uses only temporary containers and synthetic PHP scripts.
"""

import argparse
import json
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import time
import uuid


def docker(*args, check=True):
    return subprocess.run(
        ["docker", *args], check=check, capture_output=True, text=True, timeout=90
    )


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


def request(port, query=""):
    params = {
        "SCRIPT_FILENAME": "/security-test/probe.php",
        "SCRIPT_NAME": "/probe.php",
        "REQUEST_METHOD": "GET",
        "QUERY_STRING": query,
        "REQUEST_URI": "/probe.php" + ("?" + query if query else ""),
        "SERVER_PROTOCOL": "HTTP/1.1",
        "GATEWAY_INTERFACE": "CGI/1.1",
        "SERVER_NAME": "localhost",
        "SERVER_PORT": "80",
    }
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
            _, kind, _, size, padding, _ = struct.unpack(
                "!BBHHBB", read_exact(connection, 8)
            )
            data = read_exact(connection, size)
            read_exact(connection, padding)
            if kind == 6:
                stdout += data
            if kind == 3:
                return stdout


def check_fpm(image, version, ioncube):
    name = "kvs-php-security-" + uuid.uuid4().hex[:12]
    with tempfile.TemporaryDirectory(prefix="php-security-") as directory:
        root = Path(directory)
        root.chmod(0o755)
        script = root / "probe.php"
        script.write_text("""<?php
if (isset($_GET['oom'])) {
    register_shutdown_function(static function () {
        file_put_contents('/var/www/kvs/security-unsafe-shutdown', 'unsafe');
    });
    str_repeat('x', 16 * 1024 * 1024);
}
header('Content-Type: application/json');
echo json_encode([
    'version' => PHP_VERSION, 'pid' => getmypid(),
    'ioncube' => extension_loaded('ionCube Loader'),
    'opcache' => extension_loaded('Zend OPcache'),
    'imagick' => extension_loaded('imagick'),
    'memcached' => extension_loaded('memcached'),
    'gd' => extension_loaded('gd'),
    'ftp' => function_exists('ftp_ssl_connect'),
]);
""")
        script.chmod(0o644)
        try:
            docker(
                "run", "-d", "--name", name, "--memory", "1g",
                "-p", "127.0.0.1::9000", "-v", directory + ":/security-test:ro",
                "-e", "KVS_MEMCACHE_LOOPBACK=false", "-e", "YT_DLP_AUTO_UPDATE=no",
                "-e", "IONCUBE=" + ioncube, "-e", "PHP_MEMORY_LIMIT=8M",
                "-e", "PHP_FPM_MAX_CHILDREN=1", "-e", "PHP_FPM_START_SERVERS=1",
                "-e", "PHP_FPM_MIN_SPARE_SERVERS=1", "-e", "PHP_FPM_MAX_SPARE_SERVERS=1",
                image,
            )
            docker("exec", name, "chmod", "0777", "/var/www/kvs")
            port = int(docker("port", name, "9000/tcp").stdout.strip().rsplit(":", 1)[1])

            def healthy():
                for _ in range(100):
                    try:
                        response = request(port)
                        data = json.loads(response.split(b"\r\n\r\n", 1)[1])
                        assert data["version"] == version, data
                        assert data["ioncube"] == (ioncube == "yes"), data
                        assert all(data[key] for key in ("opcache", "imagick", "memcached", "gd", "ftp")), data
                        return data
                    except (OSError, EOFError):
                        time.sleep(0.1)
                raise AssertionError("FPM never became ready")

            first = healthy()
            second = healthy()
            assert second["pid"] == first["pid"], "Requests must reuse the single worker"
            if version.startswith("8.1."):
                try:
                    request(port, "oom=1")
                except (EOFError, OSError):
                    pass
                after = healthy()
                assert after["pid"] != first["pid"], "The backport must terminate the exhausted worker"
                sentinel = docker(
                    "exec", name, "test", "!", "-e",
                    "/var/www/kvs/security-unsafe-shutdown", check=False,
                )
                assert sentinel.returncode == 0, "Unsafe shutdown callback ran after OOM"
            checks = "consecutive requests"
            if version.startswith("8.1."):
                checks += " and worker recovery"
            print(f"PASS: FPM {version}, ionCube={ioncube}, {checks}")
        except Exception:
            logs = docker("logs", name, check=False)
            print(logs.stdout + logs.stderr)
            raise
        finally:
            docker("rm", "-f", name, check=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image")
    parser.add_argument("version")
    parser.add_argument("--fpm", action="store_true")
    args = parser.parse_args()
    result = docker(
        "run", "--rm", "--network", "none", "--entrypoint", "php", args.image,
        "-r", 'echo json_encode([PHP_VERSION, extension_loaded("ionCube Loader"), '
        'extension_loaded("imagick"), extension_loaded("memcached"), '
        'extension_loaded("mysqli"), extension_loaded("pdo_mysql"), '
        'function_exists("ftp_connect"), function_exists("ftp_ssl_connect")]);',
    )
    data = json.loads(result.stdout)
    assert data == [args.version, True, True, True, True, True, True, True], data
    if args.version.startswith("8.1."):
        result = docker(
            "run", "--rm", "--network", "none", "--entrypoint", "php", args.image,
            "-n", "-d", "memory_limit=8M", "-r",
            'register_shutdown_function(static function () { echo "unsafe-shutdown"; }); '
            'str_repeat("x", 16 * 1024 * 1024);', check=False,
        )
        assert result.returncode == 1, result
        assert "Allowed memory size" in result.stderr, result
        assert "unsafe-shutdown" not in result.stdout + result.stderr, result
    print(f"PASS: {args.image}, PHP {args.version}, extensions and security baseline")
    if args.fpm:
        for ioncube in ("yes", "no"):
            check_fpm(args.image, args.version, ioncube)


if __name__ == "__main__":
    main()

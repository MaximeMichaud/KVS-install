#!/usr/bin/env python3
"""Check a built PHP/cron image and, for FPM, real consecutive requests.

Run with python3 tests/integration_php_security.py IMAGE
VERSION [--fpm]. Uses only temporary containers and synthetic PHP scripts.
FPM runs with the php.ini of the stack, mounted where Compose mounts it.
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

ROOT = Path(__file__).resolve().parents[1]


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


def request(port, query="", script="/probe.php"):
    params = {
        "SCRIPT_FILENAME": "/security-test" + script,
        "SCRIPT_NAME": script,
        "REQUEST_METHOD": "GET",
        "QUERY_STRING": query,
        "REQUEST_URI": script + ("?" + query if query else ""),
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
        archive = root / "probe.phar"
        archive.write_text(script.read_text())
        archive.chmod(0o644)
        try:
            docker(
                "run", "-d", "--name", name, "--memory", "1g",
                "-p", "127.0.0.1::9000", "-v", directory + ":/security-test:ro",
                "-v", str(ROOT / "docker/php/php.ini") + ":/usr/local/etc/php/conf.d/kvs.ini:ro",
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
            # Only .php files run, and only the script asked for: an uploaded
            # probe.phar does not, nor does probe.php for probe.php/x.php.
            refused = request(port, script="/probe.phar")
            assert b"Status: 403" in refused and b'"version"' not in refused, refused
            missing = request(port, script="/probe.php/x.php")
            assert b"Status: 404" in missing and b'"version"' not in missing, missing
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
            checks = "consecutive requests, no .phar or PATH_INFO script"
            if version.startswith("8.1."):
                checks += " and worker recovery"
            print(f"PASS: FPM {version}, ionCube={ioncube}, {checks}")
        except Exception:
            logs = docker("logs", name, check=False)
            print(logs.stdout + logs.stderr)
            raise
        finally:
            docker("rm", "-f", name, check=False)


# A FastCGI client for docker exec, so the requests come from inside the
# container as the user they are run as, with no port published.
FASTCGI_CLIENT = r"""<?php
[, $address, $script] = $argv;
$connection = @stream_socket_client($address, $code, $message, 5);
if (!$connection) {
    fwrite(STDERR, "connect: $message\n");
    exit(2);
}
$record = static fn ($kind, $data) => pack('CCnnCx', 1, $kind, 1, strlen($data), 0) . $data;
$params = '';
foreach (['SCRIPT_FILENAME' => $script, 'SCRIPT_NAME' => '/index.php',
    'REQUEST_METHOD' => 'GET', 'REQUEST_URI' => '/index.php', 'QUERY_STRING' => '',
    'SERVER_PROTOCOL' => 'HTTP/1.1', 'GATEWAY_INTERFACE' => 'CGI/1.1'] as $key => $value) {
    $params .= chr(strlen($key)) . chr(strlen($value)) . $key . $value;
}
fwrite($connection, $record(1, pack('nCx5', 1, 0)) . $record(4, $params) . $record(4, '') . $record(5, ''));
while (strlen($header = (string) fread($connection, 8)) === 8) {
    $fields = unpack('Cversion/Ckind/nid/nsize/Cpadding/Creserved', $header);
    $data = $fields['size'] ? stream_get_contents($connection, $fields['size']) : '';
    if ($fields['padding']) {
        stream_get_contents($connection, $fields['padding']);
    }
    if ($fields['kind'] === 6) {
        echo $data;
    }
    if ($fields['kind'] === 3) {
        exit(0);
    }
}
exit(3);
"""

PHPMYADMIN = "/usr/share/phpmyadmin"
PHPMYADMIN_SOCKET = "unix://" + PHPMYADMIN + "/.kvs-fpm/php-fpm.sock"


def check_phpmyadmin_pool(image):
    """phpMyAdmin runs apart from the site's PHP (php/docker-entrypoint.sh).

    The phpmyadmin-data volume starts the way an earlier release left it,
    config.inc.php and tmp/ owned by the site's user, code the site's PHP
    could add in config.inc.php, a template planted in tmp/. The pool does
    not start on that config.inc.php. Once it is written anew, root's, as
    phpmyadmin-init does, nginx's workers (GID 101) reach the pool through
    its socket and it runs as kvs-phpmyadmin; the site's user cannot open
    that socket, read the configuration, even once OPcache holds it, nor
    write anything.
    """
    name = "kvs-php-phpmyadmin-" + uuid.uuid4().hex[:12]
    volume = name + "-data"
    legacy_secret = "kvs-legacy-blowfish-" + uuid.uuid4().hex  # pragma: allowlist secret
    secret = "kvs-blowfish-" + uuid.uuid4().hex  # pragma: allowlist secret
    with tempfile.TemporaryDirectory(prefix="php-phpmyadmin-") as directory:
        root = Path(directory)
        root.chmod(0o755)
        client = root / "fastcgi.php"
        client.write_text(FASTCGI_CLIENT)
        client.chmod(0o644)
        try:
            docker("volume", "create", volume)
            docker(
                "run", "--rm", "--network", "none", "--entrypoint", "sh",
                "-v", volume + ":" + PHPMYADMIN, "-e", "SECRET=" + legacy_secret, image, "-ceu", """
root=/usr/share/phpmyadmin
mkdir -p "$root/tmp/twig"
printf '%s\\n' "<?php \\$cfg['blowfish_secret'] = '$SECRET';" \\
    'file_put_contents("/tmp/planted-ran", "ran");' > "$root/config.inc.php"
printf '%s\\n' '<?php' 'session_start();' \\
    '$cfg = [];' '@include __DIR__ . "/config.inc.php";' \\
    'echo json_encode(["uid" => posix_geteuid(), "secret" => $cfg["blowfish_secret"] ?? null,' \\
    '    "sessions" => session_save_path(), "upload" => ini_get("upload_tmp_dir")]);' \\
    > "$root/index.php"
echo '<?php echo "planted";' > "$root/tmp/twig/planted.php"
chown -R 1000:1000 "$root/config.inc.php" "$root/tmp"
chmod 600 "$root/config.inc.php"
chmod 644 "$root/index.php"
""",
            )
            docker(
                "run", "-d", "--name", name, "--network", "none", "--memory", "1g",
                "-v", volume + ":" + PHPMYADMIN, "-v", directory + ":/kvs-test:ro",
                "-v", str(ROOT / "docker/php/php.ini") + ":/usr/local/etc/php/conf.d/kvs.ini:ro",
                "-e", "KVS_MEMCACHE_LOOPBACK=false", "-e", "YT_DLP_AUTO_UPDATE=no",
                "-e", "PHP_FPM_MAX_CHILDREN=2", "-e", "PHP_FPM_START_SERVERS=1",
                "-e", "PHP_FPM_MIN_SPARE_SERVERS=1", "-e", "PHP_FPM_MAX_SPARE_SERVERS=1",
                image,
            )

            def fastcgi(user, address):
                return docker(
                    "exec", "-u", user, name, "php", "/kvs-test/fastcgi.php",
                    address, PHPMYADMIN + "/index.php", check=False,
                )

            # The config.inc.php the site's user owned is neither served nor
            # taken over: phpmyadmin-init has to tell it apart and write it anew.
            for _ in range(100):
                logs = docker("logs", name, check=False)
                if "ready to handle connections" in logs.stdout + logs.stderr:
                    break
                time.sleep(0.1)
            logs = docker("logs", name, check=False)
            assert "config.inc.php may have been written by another user than root" in logs.stderr, logs
            assert "phpMyAdmin runs in its own PHP-FPM pool" not in logs.stdout, logs.stdout
            unserved = fastcgi("101:101", PHPMYADMIN_SOCKET)
            assert unserved.returncode == 2, unserved
            legacy = docker("exec", name, "stat", "-c", "%u:%g:%a", PHPMYADMIN + "/config.inc.php").stdout
            assert legacy.strip() == "1000:1000:600", legacy
            # What phpmyadmin-init writes in its place, then a restart.
            docker(
                "exec", "-e", "SECRET=" + secret, name, "sh", "-ceu", """
root=/usr/share/phpmyadmin
printf '%s\\n' "<?php \\$cfg['blowfish_secret'] = '$SECRET';" > "$root/.config.inc.php.new"
chown 0:999 "$root/.config.inc.php.new"
chmod 640 "$root/.config.inc.php.new"
mv -f "$root/.config.inc.php.new" "$root/config.inc.php"
""",
            )
            docker("restart", name)
            for _ in range(100):
                served = fastcgi("101:101", PHPMYADMIN_SOCKET)
                if served.returncode == 0:
                    break
                time.sleep(0.1)
            else:
                raise AssertionError("the phpMyAdmin pool never answered nginx's group: " + served.stderr)
            # docker() reads text, which turns the \r\n of the headers into \n.
            data = json.loads(served.stdout.split("\n\n", 1)[1])
            assert data == {
                "uid": 999, "secret": secret,
                "sessions": "/var/lib/kvs-phpmyadmin/sessions",
                "upload": "/var/lib/kvs-phpmyadmin/tmp",
            }, data

            refused = fastcgi("1000:1000", PHPMYADMIN_SOCKET)
            assert refused.returncode == 2 and "Permission denied" in refused.stderr, refused
            # The site's pool runs phpMyAdmin's script as the site's user, after
            # the phpMyAdmin pool put config.inc.php in the OPcache memory both
            # share: the configuration must stay out of its reach.
            for _ in range(100):
                site = fastcgi("1000:1000", "tcp://127.0.0.1:9000")
                if site.returncode == 0:
                    break
                time.sleep(0.1)
            assert site.returncode == 0, site
            assert secret not in site.stdout, site.stdout
            assert '"uid":1000' in site.stdout, site.stdout

            owners = docker(
                "exec", name, "stat", "-c", "%n %u:%g:%a %F",
                PHPMYADMIN, PHPMYADMIN + "/config.inc.php", PHPMYADMIN + "/tmp",
                PHPMYADMIN + "/.kvs-fpm", PHPMYADMIN + "/.kvs-fpm/php-fpm.sock",
            ).stdout.splitlines()
            assert owners == [
                PHPMYADMIN + " 0:0:755 directory",
                PHPMYADMIN + "/config.inc.php 0:999:640 regular file",
                PHPMYADMIN + "/tmp 999:999:700 directory",
                PHPMYADMIN + "/.kvs-fpm 0:0:755 directory",
                PHPMYADMIN + "/.kvs-fpm/php-fpm.sock 999:101:660 socket",
            ], owners
            planted = docker("exec", name, "find", PHPMYADMIN + "/tmp", "-name", "planted.php").stdout
            assert planted == "", "the template the site's user planted in tmp/ was kept"
            ran = docker("exec", name, "test", "-e", "/tmp/planted-ran", check=False)
            assert ran.returncode != 0, "the code the site's user added to config.inc.php ran"
            for command in (
                "echo x >> /usr/share/phpmyadmin/config.inc.php",
                "cat /usr/share/phpmyadmin/config.inc.php",
                "touch /usr/share/phpmyadmin/tmp/x",
                "touch /usr/share/phpmyadmin/x",
                "rm /usr/share/phpmyadmin/.kvs-fpm/php-fpm.sock",
                "ls /var/lib/kvs-phpmyadmin/sessions",
            ):
                attempt = docker("exec", "-u", "1000:1000", name, "sh", "-c", command, check=False)
                assert attempt.returncode != 0, f"the site's user could run: {command}"
            print("PASS: phpMyAdmin runs in its own pool, out of the site's reach")
        except Exception:
            logs = docker("logs", name, check=False)
            print(logs.stdout + logs.stderr)
            raise
        finally:
            docker("rm", "-f", name, check=False)
            docker("volume", "rm", "-f", volume, check=False)


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
        check_phpmyadmin_pool(args.image)


if __name__ == "__main__":
    main()

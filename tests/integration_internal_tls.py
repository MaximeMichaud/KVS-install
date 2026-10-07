#!/usr/bin/env python3
"""Exercise Docker's internal TLS trust using real NGINX and PHP runtimes.

Uses only synthetic files and an isolated, internal Docker network. The three
images must already exist locally; no application data or external URL is used.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
WORK = Path(tempfile.mkdtemp(prefix="kvs-internal-tls-"))
WORK.chmod(0o755)
PROJECT = f"kvs-tls-test-{os.getpid()}"
DOMAIN = "site.fixture.test"
IMAGES = {
    "nginx": os.environ.get("KVS_TLS_TEST_NGINX_IMAGE", "kvs-internal-tls-nginx-test:local"),
    "php-fpm": os.environ.get("KVS_TLS_TEST_PHP_IMAGE", "php:8.1-fpm"),
    "cron": os.environ.get("KVS_TLS_TEST_CRON_IMAGE", "php:8.1-cli"),
}
# Compose requires nonempty database placeholders even though this fixture
# removes MariaDB. The generated project name is not a real credential.
ENV = dict(os.environ, DOMAIN=DOMAIN, SITE_PREFIX=PROJECT, SSL_PROVIDER="selfsigned",
           MODE="single", COMPOSE_PROFILES="", COMPOSE_FILE="", MARIADB_PASSWORD=PROJECT,
           MARIADB_ROOT_PASSWORD=PROJECT, IONCUBE="NO")
RESULTS = []


def run(*args, check=True, **kwargs):
    result = subprocess.run(list(map(str, args)), text=True, capture_output=True,
                            env=ENV, **kwargs)
    if check and result.returncode:
        raise RuntimeError(f"{args[:3]}: {result.stderr[-3000:]} {result.stdout[-1000:]}")
    return result


def compose(*args, **kwargs):
    return run("docker", "compose", "-p", PROJECT, "-f", WORK / "compose.json", *args, **kwargs)


def execute(service, *args, **kwargs):
    return compose("exec", "-T", service, *args, **kwargs)


def record(name):
    RESULTS.append(name)
    print("PASS: " + name, flush=True)


def eventually(check, timeout=30):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        try:
            if check():
                return
        except (ValueError, RuntimeError) as error:
            last = str(error)
        time.sleep(0.4)
    raise AssertionError(f"condition timed out: {last}")


def probe(service, path="/get_file/test", host=DOMAIN, port=443):
    output = execute(service, "php", "/fixture/probe.php", f"https://{host}:{port}{path}")
    return json.loads(output.stdout)


def good():
    return all(probe(service)["ok"] for service in ("php-fpm", "cron"))


def fingerprint():
    return execute("nginx", "openssl", "x509", "-in", f"/etc/nginx/ssl/{DOMAIN}/cert.pem",
                   "-noout", "-fingerprint", "-sha256").stdout.strip()


def generate(directory, prefix, domain=DOMAIN):
    run("openssl", "req", "-x509", "-nodes", "-newkey", "rsa:2048", "-days", "2",
        "-subj", f"/CN={domain}", "-addext", f"subjectAltName=DNS:{domain}",
        "-addext", "basicConstraints=critical,CA:FALSE", "-addext", "extendedKeyUsage=serverAuth",
        "-keyout", directory / f"{prefix}.key", "-out", directory / f"{prefix}.pem")


try:
    for image in IMAGES.values():
        run("docker", "image", "inspect", image)
    generate(WORK, "unknown")
    generate(WORK, "wrong", domain="wrong.fixture.test")
    run("openssl", "req", "-new", "-key", WORK / "unknown.key", "-subj", f"/CN={DOMAIN}",
        "-out", WORK / "expired.csr")
    (WORK / "index.txt").touch()
    (WORK / "serial").write_text("1000\n")
    (WORK / "ca.conf").write_text(f'''[ca]
default_ca=test
[test]
database={WORK}/index.txt
serial={WORK}/serial
new_certs_dir={WORK}
certificate={WORK}/unknown.pem
private_key={WORK}/unknown.key
default_md=sha256
policy=names
x509_extensions=extensions
[names]
commonName=supplied
[extensions]
subjectAltName=DNS:{DOMAIN}
basicConstraints=critical,CA:FALSE
''')
    run("openssl", "ca", "-batch", "-selfsign", "-notext", "-config", WORK / "ca.conf",
        "-in", WORK / "expired.csr", "-out", WORK / "expired.pem",
        "-startdate", "20000101000000Z", "-enddate", "20000102000000Z")
    run("openssl", "req", "-x509", "-nodes", "-newkey", "rsa:2048", "-days", "3",
        "-subj", "/CN=Fixture private CA", "-addext", "basicConstraints=critical,CA:TRUE",
        "-keyout", WORK / "ca.key", "-out", WORK / "ca.crt")
    run("openssl", "req", "-new", "-nodes", "-newkey", "rsa:2048", "-subj", f"/CN={DOMAIN}",
        "-keyout", WORK / "issued.key", "-out", WORK / "issued.csr")
    (WORK / "extensions.txt").write_text(f"subjectAltName=DNS:{DOMAIN}\nbasicConstraints=critical,CA:FALSE\n")
    run("openssl", "x509", "-req", "-in", WORK / "issued.csr", "-CA", WORK / "ca.crt",
        "-CAkey", WORK / "ca.key", "-CAcreateserial", "-days", "2",
        "-extfile", WORK / "extensions.txt", "-out", WORK / "issued.pem")
    (WORK / "media.bin").write_bytes(b"synthetic-media\n" * 4096)
    (WORK / "probe.php").write_text('''<?php
$url = $argv[1] ?? 'https://site.fixture.test/get_file/test';
$c = curl_init($url);
curl_setopt_array($c, [CURLOPT_RETURNTRANSFER => true, CURLOPT_FOLLOWLOCATION => true,
    CURLOPT_TIMEOUT => 3, CURLOPT_SSL_VERIFYPEER => true, CURLOPT_SSL_VERIFYHOST => 2,
    CURLOPT_PROXY => '', CURLOPT_CERTINFO => true]);
$body = curl_exec($c);
$error = curl_errno($c);
$verify = curl_getinfo($c, CURLINFO_SSL_VERIFYRESULT);
$code = curl_getinfo($c, CURLINFO_HTTP_CODE);
curl_close($c);
$stream = @file_get_contents($url, false, stream_context_create(['ssl' => [
    'verify_peer' => true, 'verify_peer_name' => true], 'http' => ['timeout' => 3]]));
header('Content-Type: application/json');
echo json_encode(['ok' => $body !== false && $code === 200 && $verify === 0 && $stream === $body,
    'errno' => $error, 'verify' => $verify, 'http' => $code,
    'bytes' => $body === false ? 0 : strlen($body)]);
''')
    (WORK / "site.tpl").write_text('''server {
    listen 80;
    listen 443 ssl;
    server_name ${DOMAIN};
    ssl_certificate /etc/nginx/ssl/${DOMAIN}/cert.pem;
    ssl_certificate_key /etc/nginx/ssl/${DOMAIN}/key.pem;
    root /fixture;
    location /get_file/ { return 302 https://${DOMAIN}/media.bin; }
    location = /probe.php {
        include /etc/nginx/fastcgi_params;
        fastcgi_param SCRIPT_FILENAME /fixture/probe.php;
        fastcgi_pass php-fpm:9000;
    }
}
server {
    listen 444 ssl;
    ssl_certificate /fixture/unknown.pem;
    ssl_certificate_key /fixture/unknown.key;
    root /fixture;
}
''')
    rendered = json.loads(run("docker", "compose", "--env-file", "/dev/null", "-f",
                              ROOT / "docker/docker-compose.yml", "config", "--format", "json").stdout)
    services = {}
    for name in IMAGES:
        service = rendered["services"][name]
        service.pop("build", None)
        service.pop("ports", None)
        service["image"] = IMAGES[name]
        service["pull_policy"] = "never"
        service["restart"] = "no"
        service["environment"].update(KVS_MEMCACHE_LOOPBACK="false", CERTIFICATE_RELOAD_INTERVAL="1")
        service["volumes"] = [v for v in service["volumes"] if v["target"] in
                              {"/etc/nginx/ssl", "/run/kvs-internal-tls", "/usr/local/lib/kvs-tls"}]
        service["volumes"].append({"type": "bind", "source": str(WORK), "target": "/fixture", "read_only": True})
        service["depends_on"].pop("mariadb", None)
        if name == "nginx":
            service["networks"]["kvs-network"]["aliases"].append("wrong.fixture.test")
            service["volumes"].append({"type": "bind", "source": str(WORK / "site.tpl"),
                                       "target": "/etc/nginx/templates/kvs.conf.tpl", "read_only": True})
        else:
            source = "php" if name == "php-fpm" else "cron"
            service["entrypoint"] = ["bash", "/fixture-entrypoint.sh"]
            service["volumes"].append({"type": "bind", "source": str(ROOT / "docker" / source / "docker-entrypoint.sh"),
                                       "target": "/fixture-entrypoint.sh", "read_only": True})
            service["volumes"].append({"type": "bind", "source": str(WORK / "ca.crt"),
                                       "target": "/usr/local/share/ca-certificates/fixture-ca.crt", "read_only": True})
            service["command"] = ["php-fpm"] if name == "php-fpm" else ["sleep", "infinity"]
        services[name] = service
    config = {"services": services, "volumes": {"acme-certs": {}, "internal-tls": {}},
              "networks": {"kvs-network": {"internal": True}}}
    (WORK / "compose.json").write_text(json.dumps(config))
    compose("up", "-d", "--no-build")
    eventually(good)
    record("fresh empty volumes: PHP and cron verify TLS and read the full redirected body")
    plain = compose("run", "--rm", "--no-deps", "--entrypoint", "php", "php-fpm",
                    "/fixture/probe.php", f"https://{DOMAIN}/get_file/test")
    assert json.loads(plain.stdout)["errno"] == 60
    record("negative control: identical PHP without trust bootstrap fails with cURL 60")
    missing = compose("run", "--rm", "--no-deps", "-e", "DOMAIN=missing.fixture.test", "-e",
                      "KVS_TLS_WAIT_SECONDS=0", "php-fpm", "true", check=False)
    assert missing.returncode != 0 and "refusing to start" in missing.stderr
    record("missing initial publication prevents application startup")
    for service in ("php-fpm", "cron"):
        assert probe(service, "/media.bin", port=444)["errno"] == 60
        assert probe(service, "/media.bin", host="wrong.fixture.test")["errno"] == 60
        assert execute(service, "test", "-e", "/etc/nginx/ssl", check=False).returncode != 0
        assert execute(service, "touch", f"/run/kvs-internal-tls/{DOMAIN}.pem", check=False).returncode != 0
    record("unknown certificates and wrong hostnames fail; applications cannot read keys or write trust")
    eventually(lambda: json.loads(execute("nginx", "curl", "-fsS", "http://127.0.0.1/probe.php").stdout)["ok"])
    record("real FPM request verifies TLS using the default system trust store")
    before = fingerprint()
    (WORK / "old.pem").write_text(execute("nginx", "cat", f"/etc/nginx/ssl/{DOMAIN}/cert.pem").stdout)
    for name in ("wrong", "expired"):
        refused = execute("nginx", "env", f"KVS_TLS_CERT_FILE=/fixture/{name}.pem", "sh",
                          "/usr/local/lib/kvs-tls/internal-trust.sh", "publish", check=False)
        assert refused.returncode != 0
        assert good()
    record("publisher rejects expired and wrong-host certificates without replacing valid trust")
    compose("restart", "nginx", "php-fpm", "cron")
    eventually(good)
    assert fingerprint() == before
    record("container restart retains the certificate and strict verification")
    compose("up", "-d", "--no-deps", "--force-recreate", "php-fpm", "cron")
    # NGINX resolves the changed FPM container when its workers reload.
    execute("nginx", "nginx", "-s", "reload")
    eventually(good)
    record("recreated PHP and cron containers reinstall trust from the persistent public volume")
    execute("nginx", "sh", "-c", f'''
        set -eu
        d=/etc/nginx/ssl/{DOMAIN}
        openssl req -x509 -nodes -newkey rsa:2048 -days 365 -subj /CN={DOMAIN} \\
            -addext subjectAltName=DNS:{DOMAIN} -addext basicConstraints=critical,CA:FALSE \\
            -keyout "$d/new.key" -out "$d/new.pem" 2>/dev/null
        mv "$d/new.key" "$d/key.pem"
        mv "$d/new.pem" "$d/cert.pem"
    ''')
    after = fingerprint()
    assert after != before
    eventually(lambda: all(execute(s, "openssl", "x509", "-in",
                                   "/usr/local/share/ca-certificates/kvs-internal-site.crt",
                                   "-noout", "-fingerprint", "-sha256").stdout.strip() == after
                           for s in ("php-fpm", "cron")))
    eventually(good)
    eventually(lambda: json.loads(execute("nginx", "curl", "-fsS", "http://127.0.0.1/probe.php").stdout)["ok"])
    for service in ("php-fpm", "cron"):
        assert execute(service, "openssl", "verify", "-CAfile", "/etc/ssl/certs/ca-certificates.crt",
                       "/fixture/old.pem", check=False).returncode != 0
    record("certificate replacement reloads NGINX and updates trust in running FPM and cron")
    execute("nginx", "sh", "-c", f"printf broken > /run/kvs-internal-tls/{DOMAIN}.pem")
    eventually(lambda: all(probe(s)["errno"] == 60 for s in ("php-fpm", "cron")))
    record("corrupt trust publication revokes the old certificate and fails closed")
    execute("nginx", "sh", "/usr/local/lib/kvs-tls/internal-trust.sh", "publish")
    eventually(good)
    record("valid publication recovers verification without restarting the application")
    execute("nginx", "sh", "-c", f"rm /run/kvs-internal-tls/{DOMAIN}.pem")
    eventually(lambda: all(probe(s)["errno"] == 60 for s in ("php-fpm", "cron")))
    execute("nginx", "sh", "/usr/local/lib/kvs-tls/internal-trust.sh", "publish")
    eventually(good)
    record("missing publication fails closed and is recoverable")
    # Public/none modes must remove a previous private trust anchor.
    for provider in ("letsencrypt", "none"):
        for service in ("php-fpm", "cron"):
            execute(service, "env", f"SSL_PROVIDER={provider}", "sh",
                    "/usr/local/lib/kvs-tls/internal-trust.sh", "sync")
            assert execute(service, "test", "-e", "/usr/local/share/ca-certificates/kvs-internal-site.crt",
                           check=False).returncode != 0
        # The running self-signed watcher intentionally restores its own mode.
        compose("restart", "php-fpm", "cron")
        eventually(good)
    record("public and Caddy modes remove installation-owned private trust")
    execute("nginx", "sh", "-c", f'''
        set -eu
        d=/etc/nginx/ssl/{DOMAIN}
        cp /fixture/unknown.key "$d/key.pem"
        cp /fixture/unknown.pem "$d/cert.pem"
    ''')
    eventually(lambda: execute("nginx", "openssl", "x509", "-in", f"/etc/nginx/ssl/{DOMAIN}/cert.pem",
                              "-noout", "-checkend", "604800", check=False).returncode == 0)
    eventually(good)
    record("self-signed certificate nearing expiry is renewed automatically and trusted")
    execute("nginx", "sh", "-c", f'''
        set -eu
        d=/etc/nginx/ssl/{DOMAIN}
        cp /fixture/issued.key "$d/key.pem"
        cp /fixture/issued.pem "$d/cert.pem"
    ''')
    eventually(lambda: all(execute(s, "test", "-e", "/usr/local/share/ca-certificates/kvs-internal-site.crt",
                                   check=False).returncode != 0 for s in ("php-fpm", "cron")))
    eventually(good)
    after = fingerprint()
    assert execute("nginx", "openssl", "x509", "-in", f"/etc/nginx/ssl/{DOMAIN}/cert.pem",
                   "-noout", "-issuer").stdout.strip() == "issuer=CN=Fixture private CA"
    record("retained CA-issued certificate uses operator-provided CA trust and revokes the self-signed leaf")
    compose("down")
    compose("up", "-d", "--no-build")
    eventually(good)
    assert fingerprint() == after
    record("full down/up preserves certificates and restores strict verification")
    print(f"PASS: {len(RESULTS)} lifecycle checks; report: {WORK / 'results.json'}", flush=True)
finally:
    if (WORK / "compose.json").exists():
        (WORK / "containers.log").write_text(compose("logs", "--no-color", check=False).stdout)
        compose("down", "-v", "--remove-orphans", check=False)
    (WORK / "results.json").write_text(json.dumps({"passed": RESULTS}, indent=2) + "\n")
    # Retain only nonsensitive test evidence; even fixture private keys are removed.
    for path in WORK.glob("*.key"):
        path.unlink()

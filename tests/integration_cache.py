#!/usr/bin/env python3
"""Check direct cache access and legacy loopback through real FPM and cron.

Uses synthetic files and internal Docker networks, with no published port or
application database. Images must already exist locally. Set KVS_CACHE_TEST_PHP_IMAGE,
KVS_CACHE_TEST_CRON_IMAGE and KVS_CACHE_TEST_NGINX_IMAGE to built stack images;
the backend image overrides are KVS_CACHE_TEST_DRAGONFLY_IMAGE and
KVS_CACHE_TEST_MEMCACHED_IMAGE. KVS_CACHE_TEST_AUDIT_FILES optionally lists locally
extracted audit connectivity blocks, separated by os.pathsep.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
WORK = Path(tempfile.mkdtemp(prefix="kvs-cache-"))
WORK.chmod(0o755)
PROJECT = f"kvs-cache-test-{os.getpid()}"
IMAGES = {
    "php-fpm": os.environ.get("KVS_CACHE_TEST_PHP_IMAGE", "kvs-cache-test-php:local"),
    "cron": os.environ.get("KVS_CACHE_TEST_CRON_IMAGE", "kvs-cache-test-cron:local"),
    "nginx": os.environ.get("KVS_CACHE_TEST_NGINX_IMAGE", "kvs-cache-test-nginx:local"),
}
ENV = dict(os.environ, DOMAIN="cache.fixture.test", SITE_PREFIX=PROJECT,
           COMPOSE_FILE="", COMPOSE_PROFILES="", MODE="single", IONCUBE="YES",
           SSL_PROVIDER="selfsigned", USE_WWW="false", MARIADB_PASSWORD=PROJECT,
           MARIADB_ROOT_PASSWORD=PROJECT)
RESULTS = []


def run(*args, check=True, **kwargs):
    result = subprocess.run(list(map(str, args)), text=True, capture_output=True,
                            env=ENV, timeout=120, **kwargs)
    if check and result.returncode:
        raise RuntimeError(f"{args[:3]}: {result.stderr[-2000:]} {result.stdout[-1000:]}")
    return result


def compose(*args, **kwargs):
    return run("docker", "compose", "-p", PROJECT, "-f", WORK / "compose.yaml", *args, **kwargs)


def record(name, **details):
    RESULTS.append(dict(name=name, **details))
    print("PASS: " + name, flush=True)


def eventually(check, timeout=35):
    deadline = time.monotonic() + timeout
    last = ""
    while time.monotonic() < deadline:
        try:
            if check():
                return
        except (ValueError, RuntimeError, AssertionError) as error:
            last = str(error)
        time.sleep(0.3)
    raise AssertionError(f"condition timed out: {last}")


def execute(service, *args, **kwargs):
    return compose("exec", "-T", service, *args, **kwargs)


def http_probe(host=None, legacy=True):
    query = f"?legacy={'yes' if legacy else 'no'}"
    if host is not None:
        query += f"&host={host}"
    result = execute("php-fpm", "curl", "-fsS", f"http://nginx/cache-probe.php{query}")
    data = json.loads(result.stdout)
    assert data["ok"] and data["sapi"] == "fpm-fcgi", data
    return data


def mount(source, target, readonly=True):
    return dict(type="bind", source=str(source), target=target, read_only=readonly)


try:
    lock = [line.split("\t") for line in (ROOT / "docker/images.lock").read_text().splitlines()
            if line and not line.startswith("#")]
    for backend in ("dragonfly", "memcached"):
        default = next(fields[2] for fields in lock if fields[0] == backend)
        IMAGES[backend] = os.environ.get(f"KVS_CACHE_TEST_{backend.upper()}_IMAGE", default)
    for image in IMAGES.values():
        run("docker", "image", "inspect", image)
    for layout in ("single", "multi"):
        for backend in ("dragonfly", "memcached"):
            label = f"{layout}/{backend}"
            site = WORK / "site"
            if site.exists():
                shutil.rmtree(site)
            (site / "admin/include").mkdir(parents=True)
            setup = site / "admin/include/setup.php"
            setup.write_text('''<?php
$config['project_path'] = '/old/site';
$config['project_url'] = 'https://old.fixture.test';
$config['memcache_server'] = '127.0.0.1';
$config['memcache_port'] = '11211';
''')
            shutil.copyfile(ROOT / "tests/fixtures/cache-probe.php", site / "cache-probe.php")
            for i, audit in enumerate(filter(None, os.environ.get("KVS_CACHE_TEST_AUDIT_FILES", "").split(os.pathsep))):
                shutil.copyfile(audit, site / f"audit-{i}.php")
            (site / "cron-result").mkdir(mode=0o777)
            (WORK / "cron-job").write_text("* * * * * root php /fixture/cache-probe.php > /fixture/cron-result/result.json 2> /fixture/cron-result/error.log\n")
            (WORK / "nginx.conf").write_text('''events {}
http { server { listen 80; location = /cache-probe.php {
    include /etc/nginx/fastcgi_params;
    fastcgi_param SCRIPT_FILENAME /fixture/cache-probe.php;
    fastcgi_pass php-fpm:9000;
} } }
''')
            source = ROOT / ("docker/docker-compose.yml" if layout == "single" else
                             "docker/multi-site/docker-compose.site.yml.template")
            rendered = json.loads(run("docker", "compose", "--env-file", "/dev/null", "-p", PROJECT,
                                      "-f", source, "--profile", backend, "config", "--format", "json").stdout)
            services = {}
            for name in ("php-fpm", "cron", backend):
                service = rendered["services"][name]
                # Keep the real network aliases and runtime environment; remove
                # host/application resources and unrelated service dependencies.
                service = {key: value for key, value in service.items()
                           if key in ("environment", "networks", "command", "ulimits")}
                service.update(image=IMAGES[name], pull_policy="never", restart="no")
                if name in ("php-fpm", "cron"):
                    directory = "php" if name == "php-fpm" else "cron"
                    service["environment"].update(YT_DLP_AUTO_UPDATE="no", IONCUBE="YES")
                    service["entrypoint"] = ["bash", "/fixture-entrypoint.sh"]
                    service["command"] = ["php-fpm"] if name == "php-fpm" else ["cron", "-f"]
                    service["volumes"] = [mount(site, "/fixture", False), mount(site, "/var/www/kvs", False),
                        mount(ROOT / f"docker/{directory}/docker-entrypoint.sh", "/fixture-entrypoint.sh")]
                    if name == "cron":
                        service["volumes"].append(mount(WORK / "cron-job", "/fixture-cron-job"))
                services[name] = service
            networks = {name: {"internal": True} for name in rendered["networks"]}
            services["nginx"] = dict(image=IMAGES["nginx"], pull_policy="never", restart="no",
                entrypoint=["nginx", "-g", "daemon off;"], networks=list(networks),
                volumes=[mount(WORK / "nginx.conf", "/etc/nginx/nginx.conf")])
            services["init"] = dict(image=IMAGES["php-fpm"], pull_policy="never", restart="no",
                entrypoint=["bash", "/init/docker-entrypoint.d/10-config-php.sh"],
                environment={key: ENV[key] for key in ("DOMAIN", "USE_WWW", "MARIADB_PASSWORD")}, networks=list(networks),
                volumes=[mount(site, "/var/www/kvs", False), mount(ROOT / "docker/init", "/init")])
            (WORK / "compose.yaml").write_text(json.dumps(dict(name=PROJECT, services=services, networks=networks)))
            (WORK / ".env").write_text(f"COMPOSE_FILE=compose.yaml\nCOMPOSE_PROJECT_NAME={PROJECT}\n")
            try:
                compose("run", "--rm", "--no-deps", "init")
                first = setup.read_bytes()
                assert 'memcache_server\'] = "cache"' in first.decode(), setup.read_text()
                compose("run", "--rm", "--no-deps", "init")
                assert setup.read_bytes() == first, "initialization is not idempotent"
                record(f"{label}: real init migrates localhost to cache and stays idempotent")
                compose("up", "-d", "--no-build", backend, "php-fpm", "cron", "nginx")
                # System crontabs must belong to root. A bind mount retains the
                # workstation user's uid, which cron correctly refuses to run.
                execute("cron", "install", "-o", "0", "-g", "0", "-m", "644",
                        "/fixture-cron-job", "/etc/cron.d/kvs-cache-fixture")
                eventually(lambda: http_probe()["ok"])
                # Existing installations do not rerun init on upgrade. Exercise
                # the real kvsctl migration command and its unavailable-backend
                # refusal, restoration and retry against this same Compose stack.
                setup.write_text(setup.read_text().replace('memcache_server\'] = "cache"',
                                                          'memcache_server\'] = "127.0.0.1"'))
                ENV.update(KVSCTL_CACHE_RUNTIME_DIR=str(WORK), KVSCTL_CACHE_RUNTIME_BACKEND=backend)
                run("go", "test", "-race", "./internal/upgrade", "-run", "^TestCacheCommandRealDocker$",
                    "-count=1", "-v", cwd=ROOT / "cli")
                assert 'memcache_server\'] = "cache"' in setup.read_text()
                record(f"{label}: cache migration helper migrates, refuses an unavailable cache, restores and retries")
                direct = http_probe()
                legacy = http_probe("127.0.0.1")
                assert direct["host"] == "cache"
                record(f"{label}: real FPM audit, page cache, set/get, multi-get and cleanup pass", direct=direct, legacy=legacy)
                cli = json.loads(execute("cron", "php", "/fixture/cache-probe.php").stdout)
                assert cli["ok"] and cli["host"] == "cache" and cli["sapi"] == "cli", cli
                assert cli["peer_runtime"] == "shared-runtime", cli
                assert http_probe()["peer_runtime"] == "shared-runtime"
                record(f"{label}: cron PHP uses direct cache; both routes share values")
                # Wait for an actual cron tick, not just a direct PHP invocation.
                def ticked():
                    path = site / "cron-result/result.json"
                    if not path.exists() or not path.stat().st_size:
                        return False
                    result = json.loads(path.read_text())
                    assert result["ok"] and result["host"] == "cache", result
                    return True
                eventually(ticked, timeout=75)
                record(f"{label}: scheduled cron tick completed cache operations")
                for service in ("php-fpm", "cron"):
                    execute(service, "pkill", "-x", "socat")
                for service in ("php-fpm", "cron"):
                    execute(service, "php", "-r",
                        "$s=@fsockopen('127.0.0.1',11211,$e,$m,1); exit($s ? 1 : 0);")
                # Repeat all application operations after proving localhost is gone.
                assert http_probe(legacy=False)["ok"]
                result = json.loads(execute("cron", "php", "/fixture/cache-probe.php", "cache", "no").stdout)
                assert result["ok"]
                record(f"{label}: configured cache remains reachable with the relay stopped")
            finally:
                compose("down", "--volumes", "--remove-orphans")
    (WORK.parent / "cache-integration-results.json").write_text(json.dumps(RESULTS, indent=2))
    print(f"PASS: {len(RESULTS)} cache integration checks; all temporary containers removed", flush=True)
finally:
    if (WORK / "compose.yaml").exists():
        compose("down", "--volumes", "--remove-orphans")
    shutil.rmtree(WORK)

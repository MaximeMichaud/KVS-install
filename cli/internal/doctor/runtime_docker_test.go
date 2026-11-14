package doctor

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"
)

// The database and cron checks against real containers: a PHP-FPM image and
// a MariaDB image, and a cron image when one is given, all already on this
// machine (nothing is pulled), on an internal network, through the probes
// doctor runs. CI does not set these variables; run it by hand:
//
//	KVSCTL_DOCTOR_PHP_IMAGE=<php image> KVSCTL_DOCTOR_MARIADB_IMAGE=mariadb:<tag> \
//	KVSCTL_DOCTOR_CRON_IMAGE=<cron image> go test -run RealDocker ./internal/doctor
func TestDatabaseAndCronProbesRealDocker(t *testing.T) {
	php, mariadb, cron := os.Getenv("KVSCTL_DOCTOR_PHP_IMAGE"), os.Getenv("KVSCTL_DOCTOR_MARIADB_IMAGE"), os.Getenv("KVSCTL_DOCTOR_CRON_IMAGE")
	if php == "" || mariadb == "" {
		t.Skip("set KVSCTL_DOCTOR_PHP_IMAGE and KVSCTL_DOCTOR_MARIADB_IMAGE (and KVSCTL_DOCTOR_CRON_IMAGE) to local images")
	}
	docker := func(args ...string) string {
		t.Helper()
		out, err := exec.Command("docker", args...).CombinedOutput()
		if err != nil {
			t.Fatalf("docker %s: %v: %s", strings.Join(args, " "), err, out)
		}
		return strings.TrimSpace(string(out))
	}
	for _, image := range []string{php, mariadb, cron} {
		if image != "" {
			docker("image", "inspect", "--format", "{{.Id}}", image)
		}
	}
	suffix := make([]byte, 4)
	_, _ = rand.Read(suffix)
	name := "kvsctl-doctor-" + hex.EncodeToString(suffix)
	// Cleanups run last in, first out: the containers, then the volume and
	// the network they use.
	docker("network", "create", "--internal", name)
	t.Cleanup(func() { _ = exec.Command("docker", "network", "rm", name).Run() })
	docker("volume", "create", name)
	t.Cleanup(func() { _ = exec.Command("docker", "volume", "rm", name).Run() })
	db, fpm, crond := name+"-db", name+"-php", name+"-cron"
	t.Cleanup(func() { _ = exec.Command("docker", "rm", "-f", db, fpm, crond).Run() })
	docker("run", "-d", "--pull", "never", "--name", db, "--network", name, "--network-alias", "mariadb",
		"-e", "MARIADB_ROOT_PASSWORD=root-test", "-e", "MARIADB_DATABASE=kvs", "-e", "MARIADB_USER=kvs", "-e", "MARIADB_PASSWORD=kvs-test", mariadb) // pragma: allowlist secret - throwaway test database
	docker("run", "-d", "--pull", "never", "--name", fpm, "--network", name, "-v", name+":/var/www/kvs", "--entrypoint", "sleep", php, "infinity")
	if cron != "" {
		docker("run", "-d", "--pull", "never", "--name", crond, "--network", "none", "-v", name+":/var/www/kvs", "--entrypoint", "cron", cron, "-f")
	}
	// The site's files as kvs-init leaves them: uid 1000, and setup_db.php
	// 0600.
	asRoot := func(script string) { t.Helper(); docker("exec", fpm, "sh", "-c", script) }
	asRoot(`set -e
mkdir -p /var/www/kvs/admin/include
cd /var/www/kvs/admin/include
printf '%s\n' '<?php' 'define("DB_HOST", "mariadb");' 'define("DB_LOGIN", "kvs");' 'define("DB_PASS", "kvs-test");' 'define("DB_DEVICE", "kvs");' > setup_db.php
printf '%s\n' '<?php' '$config["tables_prefix_multi"] = "wrong_";' '$config["tables_prefix"] = "ktvs_";' > setup.php
printf '%s\n' '<?php' > cron.php
chown -R 1000:1000 /var/www/kvs
chmod 0600 setup_db.php`)
	sql := func(query string) {
		t.Helper()
		docker("exec", db, "mariadb", "-ukvs", "-pkvs-test", "-h127.0.0.1", "kvs", "-e", query)
	}
	deadline := time.Now().Add(3 * time.Minute)
	for exec.Command("docker", "exec", db, "mariadb", "-ukvs", "-pkvs-test", "-h127.0.0.1", "kvs", "-e", "SELECT 1").Run() != nil {
		if time.Now().After(deadline) {
			t.Fatal("MariaDB did not accept the site's credentials in time")
		}
		time.Sleep(time.Second)
	}

	probes := newRunner(Options{}).probe
	check := func(id string) Result {
		t.Helper()
		r, f := fixture(t)
		r.opts.Only, r.opts.Timeout = []string{id}, time.Minute
		// The probes doctor runs, not the fixture's.
		r.probe.exec, r.probe.execAs = probes.exec, probes.execAs
		for i := range f.states {
			switch f.states[i].Service {
			case "php-fpm":
				f.states[i].ID = fpm
			case "mariadb":
				f.states[i].ID, f.states[i].Name = db, db
			case "cron":
				f.states[i].ID = crond
			}
		}
		return resultByID(t, r.run(context.Background()), id)
	}
	expect := func(id, status, message string) {
		t.Helper()
		if got := check(id); got.Status != status || !strings.Contains(got.Message, message) {
			t.Fatalf("%s: %+v, want %s with %q", id, got, status, message)
		}
	}

	// A database the site's credentials reach, with no KVS table, then
	// with one of the two.
	expect("database", Fail, "no ktvs_admin_users table")
	sql("CREATE TABLE ktvs_admin_users (user_id INT)")
	expect("database", Fail, "no ktvs_videos table")
	sql("CREATE TABLE ktvs_videos (video_id INT)")
	expect("database", OK, "KVS tables")

	// setup_db.php only root reads: the site cannot run, and root's view
	// must not hide it.
	asRoot("chown 0:0 /var/www/kvs/admin/include/setup_db.php && chmod 0600 /var/www/kvs/admin/include/setup_db.php")
	expect("database", Fail, "www-data, cannot read")
	asRoot("chown 1000:1000 /var/www/kvs/admin/include/setup_db.php")
	expect("database", OK, "KVS tables")
	asRoot("chown 0:0 /var/www/kvs/admin/include/setup.php && chmod 0600 /var/www/kvs/admin/include/setup.php")
	expect("database", Fail, "www-data, cannot read")
	asRoot("chown 1000:1000 /var/www/kvs/admin/include/setup.php && chmod 0644 /var/www/kvs/admin/include/setup.php")

	// The prefix setup.php names, not the default one.
	asRoot(`sed -i 's/"tables_prefix"] = "ktvs_"/"tables_prefix"] = "kvs7_"/' /var/www/kvs/admin/include/setup.php`)
	expect("database", Fail, "no kvs7_admin_users table")
	sql("CREATE TABLE kvs7_admin_users (user_id INT); CREATE TABLE kvs7_videos (video_id INT)")
	expect("database", OK, "KVS tables")

	// A lock held past the probe's 3 s read timeout, as a long write, an
	// ALTER or a restore holds one: the tables are there, the query failed.
	asDBRoot := func(args ...string) *exec.Cmd {
		return exec.Command("docker", append([]string{"exec", db, "mariadb", "-uroot", "-proot-test", "-h127.0.0.1", "kvs"}, args...)...) // pragma: allowlist secret - throwaway test database
	}
	locker := asDBRoot("-e", "LOCK TABLES kvs7_videos WRITE; SELECT SLEEP(12)")
	if err := locker.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = locker.Wait() })
	taken := time.Now().Add(time.Minute)
	for {
		out, _ := asDBRoot("-N", "-e", "SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE INFO LIKE 'SELECT SLEEP%'").Output()
		if strings.TrimSpace(string(out)) == "1" {
			break
		}
		if time.Now().After(taken) {
			t.Fatal("the lock was never taken")
		}
		time.Sleep(200 * time.Millisecond)
	}
	if got := check("database"); got.Status != Fail || !strings.Contains(got.Message, "could not query") || len(got.Details) != 1 || !strings.HasPrefix(got.Details[0], "Reading kvs7_videos failed with MariaDB error ") {
		t.Fatalf("database with kvs7_videos locked: %+v", got)
	} else {
		t.Logf("database with kvs7_videos locked: %s", got.Details[0])
	}
	if err := locker.Wait(); err != nil {
		t.Fatalf("the lock: %v", err)
	}
	expect("database", OK, "KVS tables")

	// SELECT denied on one table: the site's credentials cannot read it.
	if out, err := asDBRoot("-e", "REVOKE ALL PRIVILEGES ON kvs.* FROM 'kvs'@'%'; GRANT SELECT ON kvs.kvs7_admin_users TO 'kvs'@'%'").CombinedOutput(); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	expect("database", Fail, "no kvs7_videos table")
	if out, err := asDBRoot("-e", "GRANT ALL PRIVILEGES ON kvs.* TO 'kvs'@'%'").CombinedOutput(); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	expect("database", OK, "KVS tables")

	if cron == "" {
		return
	}
	expect("cron", OK, "KVS schedule")
	asRoot("chown 0:0 /var/www/kvs/admin/include/cron.php && chmod 0600 /var/www/kvs/admin/include/cron.php")
	expect("cron", Fail, "www-data, cannot read admin/include/cron.php")
}

package instance

import (
	"maps"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// The .env is read the way compose reads it, with the environment kvsctl
// gives its compose commands: a value an older shell exported never wins
// over the file, and a key kvsctl owns never comes from the shell.
func TestReadEnvReadsWhatComposeReads(t *testing.T) {
	t.Setenv("DOMAIN", "from-an-older-shell.example")
	t.Setenv("KVS_PHP_FPM_IMAGE", "registry.example/other@sha256:0")
	t.Setenv("FROM_SHELL", "kept")
	env := "export DOMAIN=example.com # the site\r\n" +
		"HTTPS_PORT=8443 # behind the proxy\n" +
		"SITE_URL=https://${DOMAIN}:${HTTPS_PORT}/\n" +
		"LITERAL='a $literal'\n" +
		"ESCAPED=\"tab\\there\"\n" +
		"FROM_SHELL\n" +
		"KVS_PHP_FPM_IMAGE\n" +
		"EXTRA_OPTIONS=${EXTRA_JSON:-{}}\n"
	inst := newInstance(t, env)
	want := map[string]string{
		"DOMAIN": "example.com", "HTTPS_PORT": "8443", "SITE_URL": "https://example.com:8443/",
		"LITERAL": "a $literal", "ESCAPED": "tab\there", "FROM_SHELL": "kept",
		"EXTRA_OPTIONS": "{}",
	}
	if !maps.Equal(inst.Env, want) {
		t.Errorf("Env = %q\nwant %q", inst.Env, want)
	}
	if inst.HTTPSPort() != "8443" || inst.Domain() != "example.com" {
		t.Errorf("port %q, domain %q", inst.HTTPSPort(), inst.Domain())
	}
	// A file compose refuses is refused, and named.
	if err := os.WriteFile(inst.EnvPath, []byte("DOMAIN=example.com\nBAD KEY=1\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadEnv(inst.EnvPath); err == nil || !strings.Contains(err.Error(), ".env cannot be read, by docker compose either") {
		t.Errorf("a .env compose refuses: %v", err)
	}
}

// SetEnv and UnsetEnv find a key in every form compose reads it, export
// lines included, and leave the rest of the line and of the file alone.
func TestSetAndUnsetEnvHandleExportLines(t *testing.T) {
	inst := newInstance(t, "DOMAIN=example.com\nexport KVS_PHP_FPM_IMAGE=r/php@sha256:1 # pinned\nexport PHP_VERSION=8.1 # series\n")
	if err := inst.SetEnv("PHP_VERSION", "8.3"); err != nil {
		t.Fatal(err)
	}
	if err := inst.UnsetEnv("KVS_PHP_FPM_IMAGE"); err != nil {
		t.Fatal(err)
	}
	got, _ := os.ReadFile(inst.EnvPath)
	if string(got) != "DOMAIN=example.com\nexport PHP_VERSION=8.3 # series\n" {
		t.Errorf(".env =\n%s", got)
	}
	again, err := ReadEnv(inst.EnvPath)
	if err != nil || again["PHP_VERSION"] != "8.3" || again["KVS_PHP_FPM_IMAGE"] != "" {
		t.Errorf("read back: %q %v", again, err)
	}
	if !maps.Equal(inst.Env, again) {
		t.Errorf("in memory %q, on disk %q", inst.Env, again)
	}
	// A value the scripts would read differently from compose is refused,
	// and the file stays as it was.
	if err := inst.SetEnv("PHP_VERSION", "8.3\nIONCUBE=NO"); err == nil {
		t.Error("a value with a line break must be refused")
	}
	if now, _ := os.ReadFile(inst.EnvPath); string(now) != string(got) {
		t.Errorf("a refused value changed .env:\n%s", now)
	}
	// So is a whole .env compose would not read, which CheckEnv tells
	// without writing anything.
	bad := []byte("DOMAIN=example.com\nBAD KEY=1\n")
	if err := inst.CheckEnv(bad); err == nil || !strings.Contains(err.Error(), "would not be read by docker compose") {
		t.Errorf("CheckEnv of an unreadable .env: %v", err)
	}
	if err := inst.CheckEnv([]byte("DOMAIN=example.com\nexport A=1 # c\n")); err != nil {
		t.Errorf("CheckEnv of a readable .env: %v", err)
	}
	if err := inst.ReplaceEnv(bad); err == nil || !strings.Contains(err.Error(), "would not be read by docker compose") {
		t.Errorf("an unreadable .env was written: %v", err)
	}
	if now, _ := os.ReadFile(inst.EnvPath); string(now) != string(got) {
		t.Errorf("a refused .env replaced the live one:\n%s", now)
	}
}

// An upgrade or its rollback writes back the value a key had, an empty one
// included, wherever the operator put it: a setting that shares its line
// with an inline comment or with another setting is written so that compose
// reads what was written, and so does kvsctl, each setting of a shared line
// on a line of its own. A line the shell of the scripts would read
// otherwise has the edit refused, named, and .env left as it was.
func TestSetEnvKeepsWhatSharesTheLine(t *testing.T) {
	inst := newInstance(t, "DOMAIN=example.com\nKVS_PHP_FPM_IMAGE=\"\" # emptied by hand\nA=\"1\" B=2\nC=\"3\" D=4\nE=5\nF=6\nG=7 F=8\n")
	if err := inst.SetEnv("KVS_PHP_FPM_IMAGE", ""); err != nil {
		t.Fatal(err)
	}
	if err := inst.SetEnv("A", "x"); err != nil {
		t.Fatal(err)
	}
	if err := inst.UnsetEnv("D"); err != nil {
		t.Fatal(err)
	}
	got, _ := os.ReadFile(inst.EnvPath)
	if want := "DOMAIN=example.com\nKVS_PHP_FPM_IMAGE=\"\" # emptied by hand\nA=x\nB=2\nC=\"3\"\nE=5\nF=6\nG=7 F=8\n"; string(got) != want {
		t.Errorf(".env =\n%q\nwant\n%q", got, want)
	}
	want := map[string]string{"DOMAIN": "example.com", "KVS_PHP_FPM_IMAGE": "", "A": "x", "B": "2", "C": "3", "E": "5", "F": "6", "G": "7 F=8"}
	if !maps.Equal(inst.Env, want) {
		t.Errorf("Env = %q\nwant %q", inst.Env, want)
	}
	if again, err := ReadEnv(inst.EnvPath); err != nil || !maps.Equal(again, want) {
		t.Errorf("read back: %q, %v", again, err)
	}
	// The shell reads F=8 in the value of G, after the setting of F.
	err := inst.SetEnv("F", "9")
	if err == nil || !strings.Contains(err.Error(), inst.EnvPath+": F: line 8: ") {
		t.Errorf("SetEnv over a setting only the shell reads: %v", err)
	}
	if now, _ := os.ReadFile(inst.EnvPath); string(now) != string(got) || !maps.Equal(inst.Env, want) {
		t.Errorf("a refused edit changed .env:\n%s\n%q", now, inst.Env)
	}
}

// What an upgrade writes to .env, its rollback takes back with the opposite
// edit, which must go through as well: a key the shell alone reads in
// another value cannot be added, since it would stay to the shell once
// removed, and a key removed above a value that ends with a backslash is
// added back after a line feed that ends that value's line.
func TestEnvEditsCanBeTakenBack(t *testing.T) {
	inst := newInstance(t, "DOMAIN=example.com\nNOTE=see COMPOSE_FILE=docker-compose.yml\nKVS_CRON_IMAGE=r/cron:1.0.0\nPATTERN=a\\\n")
	before, _ := os.ReadFile(inst.EnvPath)
	err := inst.SetEnv("COMPOSE_FILE", "docker-compose.yml:docker-compose.release.yml")
	if err == nil || !strings.Contains(err.Error(), inst.EnvPath+": COMPOSE_FILE: line 2: ") {
		t.Errorf("SetEnv of a key the shell alone reads in another value: %v", err)
	}
	if now, _ := os.ReadFile(inst.EnvPath); string(now) != string(before) {
		t.Errorf("a refused edit changed .env:\n%s", now)
	}
	if err := inst.UnsetEnv("KVS_CRON_IMAGE"); err != nil {
		t.Fatal(err)
	}
	if err := inst.SetEnv("KVS_CRON_IMAGE", "r/cron:1.0.0"); err != nil {
		t.Fatalf("the rollback of UnsetEnv: %v", err)
	}
	got, _ := os.ReadFile(inst.EnvPath)
	if want := "DOMAIN=example.com\nNOTE=see COMPOSE_FILE=docker-compose.yml\nPATTERN=a\\\n\nKVS_CRON_IMAGE=r/cron:1.0.0\n"; string(got) != want {
		t.Errorf(".env =\n%q\nwant\n%q", got, want)
	}
	if inst.Env["KVS_CRON_IMAGE"] != "r/cron:1.0.0" {
		t.Errorf("Env = %q", inst.Env)
	}
}

// MergeEnv reads both files like compose: a key the live file sets in any
// form is not added again, which would override it, being the last one.
func TestMergeEnvReadsBothFilesLikeCompose(t *testing.T) {
	inst := newInstance(t, "DOMAIN=example.com\r\nexport CACHE_TTL=42\r\nLEFT_TO_ENV\r\n")
	example := filepath.Join(t.TempDir(), ".env.example")
	body := "# Cache.\nCACHE_TTL=300 # seconds\n\n" +
		"# Shell.\nLEFT_TO_ENV=x\n\n" +
		"# New.\nexport NEW_KEY=\"two words\" # c\nOTHER='$literal'\n"
	if err := os.WriteFile(example, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	added, err := inst.MergeEnv(example)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(added, ",") != "NEW_KEY,OTHER" {
		t.Errorf("added = %v", added)
	}
	got, _ := os.ReadFile(inst.EnvPath)
	want := "DOMAIN=example.com\r\nexport CACHE_TTL=42\r\nLEFT_TO_ENV\r\n" +
		"\r\n# New.\r\nexport NEW_KEY=\"two words\" # c\r\n\r\nOTHER='$literal'\r\n"
	if string(got) != want {
		t.Errorf(".env =\n%q\nwant\n%q", got, want)
	}
	if inst.Env["CACHE_TTL"] != "42" || inst.Env["NEW_KEY"] != "two words" || inst.Env["OTHER"] != "$literal" {
		t.Errorf("Env = %q", inst.Env)
	}
}

// The words IonCube() reads as an encoded site are the ones the php and
// cron entrypoints keep the loader for, through the default compose gives
// an empty or unset IONCUBE (IONCUBE=${IONCUBE:-YES}).
func TestIonCubeAgreesWithTheEntrypoints(t *testing.T) {
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Skip("bash is not installed")
	}
	compose, err := os.ReadFile("../../../docker/docker-compose.yml")
	if err != nil {
		t.Fatal(err)
	}
	if n := strings.Count(string(compose), "- IONCUBE=${IONCUBE:-YES}"); n != 2 {
		t.Fatalf("docker-compose.yml passes IONCUBE=${IONCUBE:-YES} to %d services, this test models 2", n)
	}
	values := []string{"unset", "", "yes", "YES", "Yes", "true", "TRUE", "1", "on", "On", "no", "NO", "false", "0", "off", "disabled", "maybe", " yes", "y"}
	fn := regexp.MustCompile(`(?ms)^apply_ioncube_setting\(\) \{\n.*?^\}\n`)
	for _, script := range []string{"../../../docker/php/docker-entrypoint.sh", "../../../docker/cron/docker-entrypoint.sh"} {
		data, err := os.ReadFile(script)
		if err != nil {
			t.Fatal(err)
		}
		body := fn.Find(data)
		if body == nil {
			t.Fatalf("%s has no apply_ioncube_setting", script)
		}
		for _, value := range values {
			confd := t.TempDir()
			disabled := filepath.Join(confd, "00-ioncube.ini.disabled")
			if err := os.WriteFile(disabled, []byte("zend_extension=ioncube\n"), 0o644); err != nil {
				t.Fatal(err)
			}
			code := strings.ReplaceAll(string(body), "/usr/local/etc/php/conf.d", confd) + "apply_ioncube_setting\n"
			cmd := exec.Command(bash, "-c", code)
			// What compose passes the container.
			passed := value
			if value == "unset" || value == "" {
				passed = "YES"
			}
			cmd.Env = append(os.Environ(), "IONCUBE="+passed)
			if out, err := cmd.CombinedOutput(); err != nil {
				t.Fatalf("%s with IONCUBE=%q: %v: %s", script, passed, err, out)
			}
			_, err := os.Stat(filepath.Join(confd, "00-ioncube.ini"))
			loader := err == nil
			inst := &Instance{Env: map[string]string{"IONCUBE": value}}
			if value == "unset" {
				inst.Env = map[string]string{}
			}
			if inst.IonCube() != loader {
				t.Errorf("%s: IONCUBE=%q keeps the loader %v, IonCube() says %v", filepath.Base(filepath.Dir(script)), value, loader, inst.IonCube())
			}
		}
	}
}

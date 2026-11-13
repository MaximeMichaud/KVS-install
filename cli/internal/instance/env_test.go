package instance

import (
	"maps"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
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

// kvsctl runs its compose commands with PWD naming the docker directory as
// it was reached, a link kept (dockerx.composeEnv), and compose expands
// ${PWD} in the .env from that PWD. kvsctl reads the .env with the same one,
// whatever directory it was started in, and with none in its environment.
func TestReadEnvExpandsPWDAsComposeDoes(t *testing.T) {
	const env = "DOMAIN=example.com\nCOMPOSE_FILE=${PWD}/docker-compose.yml\n"
	real := newInstance(t, env)
	link := filepath.Join(t.TempDir(), "kvs")
	if err := os.Symlink(real.Root, link); err != nil {
		t.Fatal(err)
	}
	elsewhere := t.TempDir()
	t.Chdir(elsewhere)
	if os.Getenv("PWD") != elsewhere {
		t.Fatalf("PWD = %q, want the directory the test runs in, %q", os.Getenv("PWD"), elsewhere)
	}
	check := func(when string) {
		t.Helper()
		for _, root := range []string{real.Root, link} {
			inst, err := Detect(root)
			if err != nil {
				t.Fatal(err)
			}
			want := filepath.Join(root, "docker", "docker-compose.yml")
			if got := inst.Env["COMPOSE_FILE"]; got != want {
				t.Errorf("%s, from %s: COMPOSE_FILE = %q, compose reads %q", when, root, got, want)
			}
			// A .env kvsctl writes is read again the same way.
			if err := inst.SetEnv("KVS_STACK_VERSION", "26.10.0"); err != nil {
				t.Fatal(err)
			}
			if got := inst.Env["COMPOSE_FILE"]; got != want {
				t.Errorf("%s, from %s, once written: COMPOSE_FILE = %q, compose reads %q", when, root, got, want)
			}
		}
	}
	check("PWD elsewhere")
	t.Setenv("PWD", "")
	if err := os.Unsetenv("PWD"); err != nil {
		t.Fatal(err)
	}
	check("no PWD")
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

// The lines MergeEnv adds end with CRLF only in a live file saved with
// CRLF throughout (dotenv.LineBreak): a CRLF in a comment pasted above or
// at the end, on the last setting, or on the line before a last line that
// has no break, gives them no carriage return, which the shell of the
// scripts (set -a; . .env) reads into the value. The last line keeps its
// own line break, and gets a line feed when it has none.
func TestMergeEnvEndsTheLinesAddedWithCRLFOnlyInACRLFFile(t *testing.T) {
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Skip("bash is not installed")
	}
	cases := []struct {
		name, live, want string
		shell            map[string]string
	}{
		{"a CRLF comment above lines that end with a line feed",
			"# pasted header\r\nDOMAIN=example.com\nSITE_PREFIX=kvs\n",
			"# pasted header\r\nDOMAIN=example.com\nSITE_PREFIX=kvs\n\n# New.\nNEW_KEY=1\n",
			map[string]string{"DOMAIN": "example.com", "SITE_PREFIX": "kvs", "NEW_KEY": "1"}},
		{"a CRLF line before a last line without its break",
			"DOMAIN=example.com\r\nA=",
			"DOMAIN=example.com\r\nA=\n\n# New.\nNEW_KEY=1\n",
			map[string]string{"A": "", "NEW_KEY": "1"}},
		{"a CRLF comment pasted at the end",
			"DOMAIN=example.com\nSITE_PREFIX=kvs\n# pasted note\r\n",
			"DOMAIN=example.com\nSITE_PREFIX=kvs\n# pasted note\r\n\n# New.\nNEW_KEY=1\n",
			map[string]string{"DOMAIN": "example.com", "SITE_PREFIX": "kvs", "NEW_KEY": "1"}},
		{"a last setting that ends with CRLF",
			"DOMAIN=example.com\nA=1\r\n\n",
			"DOMAIN=example.com\nA=1\r\n\n# New.\nNEW_KEY=1\n",
			map[string]string{"DOMAIN": "example.com", "A": "1\r", "NEW_KEY": "1"}},
	}
	example := filepath.Join(t.TempDir(), ".env.example")
	if err := os.WriteFile(example, []byte("# New.\nNEW_KEY=1\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	for _, tc := range cases {
		inst := newInstance(t, tc.live)
		if added, err := inst.MergeEnv(example); err != nil || strings.Join(added, ",") != "NEW_KEY" {
			t.Errorf("%s: added %v, %v", tc.name, added, err)
			continue
		}
		got, _ := os.ReadFile(inst.EnvPath)
		if string(got) != tc.want {
			t.Errorf("%s: .env =\n%q\nwant\n%q", tc.name, got, tc.want)
		}
		script := `set -a; . "$1" >/dev/null 2>&1; shift; for k; do printf '%s=%s\0' "$k" "${!k-unset}"; done`
		keys := slices.Sorted(maps.Keys(tc.shell))
		out, err := exec.Command(bash, append([]string{"-c", script, "bash", inst.EnvPath}, keys...)...).Output()
		if err != nil {
			t.Fatal(err)
		}
		read := map[string]string{}
		for _, entry := range strings.Split(strings.TrimSuffix(string(out), "\x00"), "\x00") {
			key, value, _ := strings.Cut(entry, "=")
			read[key] = value
		}
		if !maps.Equal(read, tc.shell) {
			t.Errorf("%s: the shell reads %q from %q, want %q", tc.name, read, got, tc.shell)
		}
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

// MergeEnv and SetEnv add their lines before a word with no = that ends
// the live .env, which a line break after it would turn into a key compose
// takes from its environment: the word stays the last line, and kvsctl
// reads every setting as before. An upgrade that removes a key there, and
// its rollback that puts the key back, both go through.
func TestEnvEditsKeepALastWordWithoutEqualsLast(t *testing.T) {
	t.Setenv("DOMAIN", "old.example.com")
	const live = "DOMAIN=example.com\nKVS_CRON_IMAGE=r/cron:1.0.0\nDOMAIN"
	inst := newInstance(t, live)
	example := filepath.Join(t.TempDir(), ".env.example")
	if err := os.WriteFile(example, []byte("# New.\nNEW_KEY=1\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if added, err := inst.MergeEnv(example); err != nil || strings.Join(added, ",") != "NEW_KEY" {
		t.Fatalf("MergeEnv: added %v, %v", added, err)
	}
	if err := inst.SetEnv("KVS_STACK_VERSION", "26.10.0"); err != nil {
		t.Fatal(err)
	}
	const want = "DOMAIN=example.com\nKVS_CRON_IMAGE=r/cron:1.0.0\n\n# New.\nNEW_KEY=1\nKVS_STACK_VERSION=26.10.0\nDOMAIN"
	if got, _ := os.ReadFile(inst.EnvPath); string(got) != want {
		t.Errorf(".env =\n%q\nwant\n%q", got, want)
	}
	if inst.Env["DOMAIN"] != "example.com" || inst.Env["NEW_KEY"] != "1" || inst.Env["KVS_STACK_VERSION"] != "26.10.0" {
		t.Errorf("Env = %q", inst.Env)
	}
	if err := inst.UnsetEnv("KVS_CRON_IMAGE"); err != nil {
		t.Fatal(err)
	}
	if err := inst.SetEnv("KVS_CRON_IMAGE", "r/cron:1.0.0"); err != nil {
		t.Fatalf("the rollback of UnsetEnv: %v", err)
	}
	if inst.Env["KVS_CRON_IMAGE"] != "r/cron:1.0.0" || inst.Env["DOMAIN"] != "example.com" {
		t.Errorf("Env = %q", inst.Env)
	}
}

// Where no line can go before that word, after a setting on its line or
// on a line the shell joins to the one before, MergeEnv and SetEnv refuse,
// and so does UnsetEnv, whose rollback would have to add the key back
// there: the file stays as it was.
func TestEnvEditsRefuseWhereNoLineCanGoBeforeTheLastWord(t *testing.T) {
	for _, live := range []string{"DOMAIN=example.com\nKVS_CRON_IMAGE=r/cron:1.0.0\nNOTE=\"a\" DOMAIN", "DOMAIN=example.com\nKVS_CRON_IMAGE=r/cron:1.0.0\nNOTE=a\\\nDOMAIN"} {
		inst := newInstance(t, live)
		example := filepath.Join(t.TempDir(), ".env.example")
		if err := os.WriteFile(example, []byte("# New.\nNEW_KEY=1\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		if added, err := inst.MergeEnv(example); err == nil || !strings.Contains(err.Error(), inst.EnvPath+": NEW_KEY: line 3: ") || added != nil {
			t.Errorf("%q: MergeEnv added %v, %v", live, added, err)
		}
		if err := inst.SetEnv("KVS_STACK_VERSION", "26.10.0"); err == nil || !strings.Contains(err.Error(), "KVS_STACK_VERSION: line 3: ") {
			t.Errorf("%q: SetEnv: %v", live, err)
		}
		if err := inst.UnsetEnv("KVS_CRON_IMAGE"); err == nil || !strings.Contains(err.Error(), "KVS_CRON_IMAGE: line 3: ") {
			t.Errorf("%q: UnsetEnv: %v", live, err)
		}
		if got, _ := os.ReadFile(inst.EnvPath); string(got) != live {
			t.Errorf(".env = %q, want it left as %q", got, live)
		}
	}
}

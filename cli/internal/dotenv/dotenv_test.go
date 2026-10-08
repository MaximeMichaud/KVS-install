package dotenv

import (
	"bytes"
	"fmt"
	"maps"
	"math/rand"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"sort"
	"strconv"
	"strings"
	"testing"
)

// parityEnviron is the environment the cases are read with: a variable a
// .env refers to, one it leaves to the environment, and one that a shell
// which sourced an older .env exported and the file assigns too.
var parityEnviron = []string{
	"KVSCTL_PARITY_ENV=from the environment",
	"KVSCTL_PARITY_BARE=bare value",
	"PLAIN=from an older shell",
	"PHP_VERSION=8.1",
}

// parityCases are .env files of the forms operators write, and what docker
// compose 5.5.1 reads from each, with parityEnviron isolated the way kvsctl
// runs compose: the values below are its output (docker compose config
// --environment), and TestComposeParity compares them with compose itself.
var parityCases = []struct {
	name string
	data string
	want map[string]string
}{
	{
		name: "the forms of a hand-edited .env",
		data: "# comment line\n" +
			"   # indented comment\n" +
			"PLAIN=value\n" +
			"SPACED = spaced value  \n" +
			"HTTPS_PORT=8443 # behind the proxy\n" +
			"DOMAIN=example.com  # main site\n" +
			"INLINE_TAB=a\t#b\n" +
			"HASH_NO_SPACE=a#b\n" +
			"LEAD=   leading\n" +
			"EMPTY=\n" +
			"EMPTY_COMMENT= # only a comment\n" +
			"export PHP_VERSION=8.3\n" +
			"export\tTABBED=tab\n" +
			"YAML: yaml value\n" +
			"SQ='single $PLAIN \\n # not a comment'\n" +
			"SQ_ESC='it\\'s'\n" +
			"DQ=\"double \\\"quoted\\\" # not a comment\"\n" +
			"DQ_ESC=\"a\\tb|c\\\\d\\$e\\x\\'\"\n" +
			"DQ_OCT=\"\\0123|\\012|\\0|\\0777\"\n" +
			"CRLF=crlf value\r\n" +
			"REF=${PLAIN}-$PLAIN\n" +
			"REF_DQ=\"${PLAIN}!\"\n" +
			"REF_SQ='${PLAIN}'\n" +
			"DOLLAR=$$PLAIN\n" +
			"DEFAULT=${MISSING:-def}\n" +
			"DEFAULT_EMPTY=${EMPTY:-was empty}\n" +
			"DEFAULT_UNSET_ONLY=${EMPTY-not used}\n" +
			"ALT=${PLAIN:+alt}\n" +
			"ALT_UNSET=${MISSING:+alt}\n" +
			"NESTED=${MISSING:-${PLAIN}-x}\n" +
			"TWO=${MISSING:-a}${PLAIN}\n" +
			"LATER=${DEFINED_LATER}\n" +
			"DEFINED_LATER=later\n" +
			"BARE_DOLLAR=a$1b$-c$\n" +
			"DOTS.AND-DASH=ok\n" +
			"OVERRIDE=first\n" +
			"OVERRIDE=second\n" +
			"FROM_ENV=${KVSCTL_PARITY_ENV}\n" +
			"KVSCTL_PARITY_BARE\n" +
			"AFTER_QUOTE=\"q\" # trailing comment\n" +
			"LAST=end\n",
		want: map[string]string{
			"PLAIN":              "value",
			"SPACED":             "spaced value",
			"HTTPS_PORT":         "8443",
			"DOMAIN":             "example.com",
			"INLINE_TAB":         "a\t#b",
			"HASH_NO_SPACE":      "a#b",
			"LEAD":               "leading",
			"EMPTY":              "",
			"EMPTY_COMMENT":      "# only a comment",
			"PHP_VERSION":        "8.3",
			"TABBED":             "tab",
			"YAML":               "yaml value",
			"SQ":                 `single $PLAIN \n # not a comment`,
			"SQ_ESC":             "it's",
			"DQ":                 `double "quoted" # not a comment`,
			"DQ_ESC":             "a\tb|c\\d$e\\x\\'",
			"DQ_OCT":             "S|\\12|\\|\\777",
			"CRLF":               "crlf value",
			"REF":                "value-value",
			"REF_DQ":             "value!",
			"REF_SQ":             "${PLAIN}",
			"DOLLAR":             "$PLAIN",
			"DEFAULT":            "def",
			"DEFAULT_EMPTY":      "was empty",
			"DEFAULT_UNSET_ONLY": "",
			"ALT":                "alt",
			"ALT_UNSET":          "",
			"NESTED":             "value-x",
			"TWO":                "avalue",
			"LATER":              "",
			"DEFINED_LATER":      "later",
			"BARE_DOLLAR":        "a$1b$-c$",
			"DOTS.AND-DASH":      "ok",
			"OVERRIDE":           "second",
			"FROM_ENV":           "from the environment",
			"KVSCTL_PARITY_BARE": "bare value",
			"AFTER_QUOTE":        "q",
			"LAST":               "end",
		},
	},
	{
		name: "a file saved on Windows",
		data: "\uFEFFDOMAIN=example.com\r\nexport USE_WWW=true\r\nQUOTED=\"a b\"\r\nMULTI=\"one\ntwo\"\r\n",
		want: map[string]string{"DOMAIN": "example.com", "USE_WWW": "true", "QUOTED": "a b", "MULTI": "one\ntwo"},
	},
	{
		name: "a last line without its line break",
		data: "DOMAIN=example.com\nSITE_PREFIX=kvs-example",
		want: map[string]string{"DOMAIN": "example.com", "SITE_PREFIX": "kvs-example"},
	},
	{
		name: "a key named export, and export alone on a line",
		data: "export=1\nexport\nAFTER=2\n",
		want: map[string]string{"export": "1", "AFTER": "2"},
	},
	{
		// Compose 2.19.0 to 2.24.6 read BRACKETS as "[{]}", INSIDE as
		// "x{y}" and AFTER_OPEN as "{}x}": the brace counting of compose
		// changed in 2.24.7.
		name: "defaults that hold braces",
		data: "SET=set\n" +
			"EMPTY_OBJECT=${OPTS:-{}}\n" +
			"BRACKETS=${A:-[{}]}\n" +
			"OPEN=${A:-a{b}\n" +
			"INSIDE=${A:-x{}y}\n" +
			"LEADING=${A:-{x}\n" +
			"NESTED=${A:-${B:-{}}}\n" +
			"CLOSED=${A:-{x}}\n" +
			"JSON=${A:-{\"k\":\"v\"}}\n" +
			"CUT=${A:-a}b}\n" +
			"EMPTY_CUT=${A:-}}\n" +
			"AROUND=prefix{${A:-x}}\n" +
			"TWO=${A:-x}${B:-{}}\n" +
			"ALT_SET=${SET:+{}}\n" +
			"ALT_UNSET=${A:+{}}\n" +
			"UNSET_ONLY=${A-{}}\n" +
			"DOUBLE=${A:-{{}}}\n" +
			"DEEP=${A:-${B:-${C:-{}}}}\n" +
			"QUOTED=\"${A:-[{}]}\"\n" +
			"SET_WINS=${SET:-{}}\n" +
			"AFTER_OPEN=${A:-{}}x}\n",
		want: map[string]string{
			"SET":          "set",
			"EMPTY_OBJECT": "{}",
			"BRACKETS":     "[{}]",
			"OPEN":         "a{b",
			"INSIDE":       "x{}y",
			"LEADING":      "{x",
			"NESTED":       "{}",
			"CLOSED":       "{x}",
			"JSON":         `{"k":"v"}`,
			"CUT":          "ab}",
			"EMPTY_CUT":    "}",
			"AROUND":       "prefix{x}",
			"TWO":          "x{}",
			"ALT_SET":      "{}",
			"ALT_UNSET":    "",
			"UNSET_ONLY":   "{}",
			"DOUBLE":       "{{}}",
			"DEEP":         "{}",
			"QUOTED":       "[{}]",
			"SET_WINS":     "set",
			"AFTER_OPEN":   "{}}x",
		},
	},
}

// parityErrors are .env files compose refuses to read: ReadEnv must refuse
// them as well, rather than read values the containers never get.
var parityErrors = []struct{ name, data string }{
	{"a space inside a key", "MY KEY=1\n"},
	{"a character no key takes", "MY@KEY=1\n"},
	{"an unterminated quote", "A=\"open\nB=2\n"},
	{"a required variable unset", "A=${MISSING:?set it in .env}\n"},
	{"a required variable unset, no message", "A=${MISSING?}\n"},
	{"an empty template", "A=${}\n"},
	{"a template with a digit first", "A=${1A}\n"},
	{"a template with a dot", "A=${B.C}\n"},
	{"an unclosed template", "A=${B\n"},
	{"a default with no brace after it on its line", "A=${B:-x\n"},
	{"a default cut by a line break in quotes", "A=\"${B:-{\n}\"\n"},
	{"export and nothing else", "A=1\nexport   "},
}

func TestParseReadsWhatComposeReads(t *testing.T) {
	for _, tc := range parityCases {
		got, err := Parse([]byte(tc.data), Lookup(parityEnviron, []byte(tc.data), nil))
		if err != nil {
			t.Errorf("%s: %v", tc.name, err)
			continue
		}
		if !maps.Equal(got, tc.want) {
			t.Errorf("%s:\n got %q\nwant %q", tc.name, got, tc.want)
		}
	}
	for _, tc := range parityErrors {
		if got, err := Parse([]byte(tc.data), nil); err == nil {
			t.Errorf("%s: compose refuses %q, Parse read %q", tc.name, tc.data, got)
		}
	}
}

// TestComposeParity runs docker compose itself on every case, with the
// environment kvsctl gives it, and compares what it reads with Parse. It
// needs docker compose (no engine: config reads files only), and runs when
// KVSCTL_COMPOSE_PARITY=1, so the suite does not depend on the version of
// compose of the machine running it. Compose 2.30.0 to 5.6.0 pass it; an
// older one fails it with its own message: 2.29.7 refuses the key
// DOTS.AND-DASH, and 2.27.0 has no config --environment.
func TestComposeParity(t *testing.T) {
	if os.Getenv("KVSCTL_COMPOSE_PARITY") != "1" {
		t.Skip("set KVSCTL_COMPOSE_PARITY=1 to compare with docker compose")
	}
	if err := exec.Command("docker", "compose", "version").Run(); err != nil {
		t.Skipf("docker compose is not available: %v", err)
	}
	base := append([]string{"PATH=" + os.Getenv("PATH"), "HOME=" + t.TempDir(), "DOCKER_CONFIG=" + t.TempDir()}, parityEnviron...)
	for _, tc := range parityCases {
		data := []byte(tc.data)
		read, want, err := compareWithCompose(t, data, base)
		if err != nil {
			t.Errorf("%s: %v", tc.name, err)
			continue
		}
		if !maps.Equal(read, want) {
			t.Errorf("%s: compose and Parse differ:\ncompose %q\n  Parse %q", tc.name, read, want)
		}
	}
	for _, tc := range parityErrors {
		data := []byte(tc.data)
		out, err := composeEnvironment(t, data, Isolate(base, data, nil))
		if err == nil {
			t.Errorf("%s: compose read it:\n%s", tc.name, out)
		}
	}
	// The template of the stack reads alike too.
	example, err := os.ReadFile(filepath.Join("..", "..", "..", "docker", ".env.example"))
	if err != nil {
		t.Fatal(err)
	}
	read, want, err := compareWithCompose(t, example, base)
	if err != nil {
		t.Fatalf("docker/.env.example: %v", err)
	}
	if !maps.Equal(read, want) {
		t.Errorf("docker/.env.example: compose and Parse differ:\ncompose %q\n  Parse %q", read, want)
	}
}

// compareWithCompose reads data as the project .env with docker compose,
// in the environment kvsctl gives it, and with Parse: what compose
// reports, and what it must report from what Parse read. Compose reports
// the environment it runs with merged with the file, the environment
// first.
func compareWithCompose(t *testing.T, data []byte, base []string) (read, want map[string]string, err error) {
	t.Helper()
	env := Isolate(base, data, nil)
	out, err := composeEnvironment(t, data, env)
	if err != nil {
		return nil, nil, fmt.Errorf("compose refused it: %w", err)
	}
	got, err := Parse(data, Lookup(base, data, nil))
	if err != nil {
		return nil, nil, err
	}
	want = map[string]string{}
	for _, entry := range env {
		key, value, _ := strings.Cut(entry, "=")
		want[key] = value
	}
	for key, value := range got {
		if _, ok := want[key]; !ok {
			want[key] = value
		}
	}
	// The docker CLI and compose add a few of their own.
	added := []string{"COMPOSE_PROJECT_NAME", "PWD", "DOCKER_CLI_PLUGIN_ORIGINAL_CLI_COMMAND", "DOCKER_CLI_PLUGIN_SOCKET"}
	read = parseEnvironment(out, append(slices.Collect(maps.Keys(want)), added...))
	for _, key := range added {
		if _, set := want[key]; !set {
			delete(read, key)
		}
	}
	return read, want, nil
}

// composeEnvironment runs docker compose config --environment on a project
// whose .env is data.
func composeEnvironment(t *testing.T, data []byte, env []string) (string, error) {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "compose.yaml"), []byte("services:\n  app:\n    image: alpine\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, ".env"), data, 0o600); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command("docker", "compose", "config", "--environment")
	cmd.Dir, cmd.Env = dir, env
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		// What compose says is the difference a refused case prints.
		if said := strings.TrimSpace(stderr.String()); said != "" {
			return "", fmt.Errorf("%w: %s", err, said)
		}
		return "", err
	}
	return string(out), nil
}

// A file compose refuses fails a case with what compose said, which tells
// a compose that reads the file otherwise from one that cannot run the
// test at all.
func TestComposeEnvironmentKeepsWhatComposeSaid(t *testing.T) {
	dir := t.TempDir()
	stub := "#!/bin/sh\necho 'line 1: unexpected character' >&2\nexit 15\n"
	if err := os.WriteFile(filepath.Join(dir, "docker"), []byte(stub), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	if _, err := composeEnvironment(t, []byte("A=1\n"), []string{"PATH=" + os.Getenv("PATH")}); err == nil || err.Error() != "exit status 15: line 1: unexpected character" {
		t.Fatalf("a file compose refuses: %v", err)
	}
}

// parseEnvironment reads the KEY=value lines compose prints, a value that
// spans lines included: a line that does not start with one of keys
// continues the value above it.
func parseEnvironment(out string, keys []string) map[string]string {
	sort.Slice(keys, func(i, j int) bool { return len(keys[i]) > len(keys[j]) })
	read := map[string]string{}
	current := ""
	for _, line := range strings.Split(strings.TrimSuffix(out, "\n"), "\n") {
		key := ""
		for _, k := range keys {
			if strings.HasPrefix(line, k+"=") {
				key = k
				break
			}
		}
		if key == "" {
			if current != "" {
				read[current] += "\n" + line
			}
			continue
		}
		current = key
		read[key] = strings.TrimPrefix(line, key+"=")
	}
	return read
}

func TestAssignedAndIsolate(t *testing.T) {
	env := []byte("DOMAIN=example.com\nKVS_PHP_FPM_IMAGE=r/php@sha256:1\nexport HTTPS_PORT=8443\nSECRET_FROM_ENV\n")
	example := []byte("DOMAIN=\nIONCUBE=YES\n")
	if got := Assigned(env); !maps.Equal(got, map[string]bool{"DOMAIN": true, "KVS_PHP_FPM_IMAGE": true, "HTTPS_PORT": true}) {
		t.Errorf("Assigned = %v", got)
	}
	environ := []string{
		"PATH=/usr/bin", "HOME=/root", "DOCKER_HOST=unix:///run/docker.sock",
		"DOMAIN=old.example.com", "HTTPS_PORT=443", "IONCUBE=NO", "SECRET_FROM_ENV=s",
		"KVS_CRON_IMAGE=r/cron@sha256:old", "COMPOSE_FILE=old.yml", "COMPOSE_ENV_FILES=other.env",
		"COMPOSE_DISABLE_ENV_FILE=1", "MARIADB_VERSION=11.4", "PHP_FPM_BASE=php@sha256:old",
		"KVS_STACK_VERSION=1.0.0", "LANG=C.UTF-8",
	}
	kept := Isolate(environ, env, example)
	want := []string{"PATH=/usr/bin", "HOME=/root", "DOCKER_HOST=unix:///run/docker.sock", "SECRET_FROM_ENV=s", "LANG=C.UTF-8"}
	if !slices.Equal(kept, want) {
		t.Errorf("Isolate kept %q, want %q", kept, want)
	}
	lookup := Lookup(environ, env, example)
	if v, ok := lookup("SECRET_FROM_ENV"); !ok || v != "s" {
		t.Errorf("a key the .env leaves to the environment: %q %v", v, ok)
	}
	if _, ok := lookup("DOMAIN"); ok {
		t.Error("a key the .env assigns must come from the file")
	}
	// A key alone on its line that kvsctl owns is still kvsctl's.
	if got := Isolate([]string{"COMPOSE_FILE=old.yml"}, []byte("COMPOSE_FILE\n"), nil); len(got) != 0 {
		t.Errorf("Isolate kept %q", got)
	}
}

func TestSet(t *testing.T) {
	bash, _ := exec.LookPath("bash")
	cases := []struct{ name, data, key, value, want string }{
		{"a new key", "DOMAIN=example.com\n", "COMPOSE_FILE", "a.yml:b.yml", "DOMAIN=example.com\nCOMPOSE_FILE=a.yml:b.yml\n"},
		{"a new key after a last line without its break", "DOMAIN=example.com", "A", "1", "DOMAIN=example.com\nA=1\n"},
		{"an empty file", "", "A", "1", "A=1\n"},
		{"a key in place", "A=1\nB=2\nC=3\n", "B", "two", "A=1\nB=two\nC=3\n"},
		{"an exported key", "export PHP_VERSION=8.1\n", "PHP_VERSION", "8.3", "export PHP_VERSION=8.3\n"},
		{"an inline comment", "HTTPS_PORT=443 # the proxy\n", "HTTPS_PORT", "8443", "HTTPS_PORT=8443 # the proxy\n"},
		{"a quoted value", "A=\"x y\" # c\n", "A", "z", "A=z # c\n"},
		{"a spaced key", "A = 1\n", "A", "2", "A=2\n"},
		{"a key left to the environment", "A\nB=2\n", "A", "1", "A=1\nB=2\n"},
		{"every setting of a key", "A=1\nA=2\n", "A", "3", "A=3\nA=3\n"},
		{"a value with blanks", "A=1\n", "A", "two words", "A=\"two words\"\n"},
		{"a CRLF file", "A=1\r\nB=2\r\n", "C", "3", "A=1\r\nB=2\r\nC=3\r\n"},
		{"a CRLF line", "A=1\r\nB=2\r\n", "A", "9", "A=9\r\nB=2\r\n"},
		{"a multi-line value", "A=\"one\ntwo\"\nB=2\n", "A", "1", "A=1\nB=2\n"},
		{"a dollar", "A=1\n", "A", "a$b", "A='a$b'\n"},
		{"a backquote", "A=1\n", "A", "a`b`", "A='a`b`'\n"},
		{"a backslash", "A=1\n", "A", `a\b\\c`, `A='a\b\\c'` + "\n"},
		{"a double quote", "A=1\n", "A", `say "hi"`, `A='say "hi"'` + "\n"},
		{"a single quote", "A=1\n", "A", "it's", "A=\"it's\"\n"},
		{"a tilde", "A=1\n", "A", "~/x", "A=\"~/x\"\n"},
	}
	for _, tc := range cases {
		got, err := Set([]byte(tc.data), tc.key, tc.value)
		if err != nil || string(got) != tc.want {
			t.Errorf("%s: got %q, %v; want %q", tc.name, got, err, tc.want)
			continue
		}
		// What was written reads back as the value given, in compose and
		// in the shell of the scripts (set -a; . .env), which does not
		// read a CRLF file the same way whatever kvsctl writes.
		env, err := Parse(got, nil)
		if err != nil || env[tc.key] != tc.value {
			t.Errorf("%s: %q reads back as %q, %v", tc.name, got, env[tc.key], err)
		}
		if bash != "" && !strings.Contains(string(got), "\r") {
			file := filepath.Join(t.TempDir(), ".env")
			if err := os.WriteFile(file, got, 0o600); err != nil {
				t.Fatal(err)
			}
			out, err := exec.Command(bash, "-c", `set -a; . "$1"; printf %s "${!2}"`, "bash", file, tc.key).Output()
			if err != nil || string(out) != tc.value {
				t.Errorf("%s: the shell reads %q as %q, %v", tc.name, got, out, err)
			}
		}
	}
	for _, value := range []string{"a\nb", "a\tb", `it's "x"`, "it's $HOME", `a\`} {
		if _, err := Set([]byte("A=1\n"), "A", value); err == nil {
			t.Errorf("%q was written although compose and the shell read it differently", value)
		}
	}
	if _, err := Set([]byte("A=\"open\n"), "B", "1"); err == nil {
		t.Error("a file compose cannot read was edited")
	}
}

func TestUnset(t *testing.T) {
	cases := []struct{ name, data, key, want string }{
		{"a key", "A=1\nB=2\nC=3\n", "B", "A=1\nC=3\n"},
		{"an exported key with a comment", "# keep\nexport B=2 # x\nC=3\n", "B", "# keep\nC=3\n"},
		{"every setting", "B=1\nA=1\nB=2\n", "B", "A=1\n"},
		{"a multi-line value", "A=\"one\ntwo\"\nB=2\n", "A", "B=2\n"},
		{"a key left to the environment", "  A\nB=2\n", "A", "B=2\n"},
		{"the last line without its break", "A=1\nB=2", "B", "A=1\n"},
		{"a setting that shares its line", "A=\"x\" B=2\n", "A", "B=2\n"},
		{"both settings of a line", "A=\"x\" A=2\nB=3\n", "A", "B=3\n"},
	}
	for _, tc := range cases {
		got, found, err := Unset([]byte(tc.data), tc.key)
		if err != nil || !found || string(got) != tc.want {
			t.Errorf("%s: got %q, %v, %v; want %q", tc.name, got, found, err, tc.want)
		}
	}
	if got, found, err := Unset([]byte("A=1\n"), "B"); err != nil || found || string(got) != "A=1\n" {
		t.Errorf("a key that is not there: %q %v %v", got, found, err)
	}
}

// lineEdit is an edit of a setting that shares its line with an inline
// comment or another setting: Set of value, or Unset, the text it writes and
// what every key reads as afterwards, in compose and in the shell of the
// scripts alike. An empty value is "" in want, an unset key absent. shell
// is what the shell reads when the operator wrote another setting of the
// line in a form it reads otherwise whatever kvsctl does, nil when it reads
// want.
type lineEdit struct {
	name, data, key, value string
	unset                  bool
	text                   string
	want, shell            map[string]string
}

func (tc lineEdit) edit() ([]byte, error) {
	if tc.unset {
		out, _, err := Unset([]byte(tc.data), tc.key)
		return out, err
	}
	return Set([]byte(tc.data), tc.key, tc.value)
}

var lineEdits = []lineEdit{
	{name: "an emptied value before a comment", data: "KEY=\"\" # emptied by hand\n", key: "KEY", value: "",
		text: "KEY=\"\" # emptied by hand\n", want: map[string]string{"KEY": ""}},
	{name: "a setting after the value", data: "A=\"1\" B=2\n", key: "A", value: "x",
		text: "A=x\nB=2\n", want: map[string]string{"A": "x", "B": "2"}},
	{name: "an emptied value before a setting", data: "A=\"1\" B=2\n", key: "A", value: "",
		text: "A=\nB=2\n", want: map[string]string{"A": "", "B": "2"}},
	{name: "a setting right after the quote", data: "A=\"1\"B=2\n", key: "A", value: "x",
		text: "A=x\nB=2\n", want: map[string]string{"A": "x", "B": "2"}},
	{name: "a setting glued to the quote before it", data: "A=\"1\"B=2\n", key: "B", value: "x",
		text: "A=\"1\"\nB=x\n", want: map[string]string{"A": "1", "B": "x"}},
	{name: "a comment right after the quote", data: "A=\"1\"# c\n", key: "A", value: "x",
		text: "A=x # c\n", want: map[string]string{"A": "x"}},
	{name: "a tab before the comment", data: "A=\"1\"\t# c\n", key: "A", value: "x",
		text: "A=x # c\n", want: map[string]string{"A": "x"}},
	{name: "a value with blanks before a comment", data: "A=1 # c\n", key: "A", value: "two words",
		text: "A=\"two words\" # c\n", want: map[string]string{"A": "two words"}},
	{name: "a no-break space after the value", data: "A=1\u00a0 # c\nB=2\n", key: "A", value: "3",
		text: "A=3 # c\nB=2\n", want: map[string]string{"A": "3", "B": "2"}},
	{name: "blanks at the end of the line", data: "A=1 \t\nB=2\n", key: "A", value: "3",
		text: "A=3\nB=2\n", want: map[string]string{"A": "3", "B": "2"}},
	{name: "the second setting of a line", data: "B=\"2\" A=1 # c\n", key: "A", value: "x",
		text: "B=\"2\"\nA=x # c\n", want: map[string]string{"A": "x", "B": "2"}},
	{name: "both settings of a line", data: "A=\"1\" A=2\n", key: "A", value: "x y",
		text: "A=\"x y\"\nA=\"x y\"\n", want: map[string]string{"A": "x y"}},
	{name: "an export line with a setting after it", data: "export A=\"1\" B=2\n", key: "A", value: "x",
		text: "export A=x\nexport B=2\n", want: map[string]string{"A": "x", "B": "2"}},
	{name: "a key left to the environment after the value", data: "A=\"1\" C\n", key: "A", value: "x",
		text: "A=x\nC\n", want: map[string]string{"A": "x"}},
	{name: "an export statement after the value", data: "A=\"1\" export C=3\n", key: "A", value: "x",
		text: "A=x\nexport C=3\n", want: map[string]string{"A": "x", "C": "3"}},
	{name: "a setting after an export statement of its line", data: "A=\"1\" export B=\"2\" C=3\n", key: "C", value: "x",
		text: "A=\"1\"\nexport B=\"2\"\nexport C=x\n", want: map[string]string{"A": "1", "B": "2", "C": "x"}},
	{name: "settings written as yaml", data: "A: \"1\" B: 2\n", key: "A", value: "x",
		text: "A=x\nB: 2\n", want: map[string]string{"A": "x", "B": "2"}, shell: map[string]string{"A": "x"}},
	{name: "a no-break space before the key", data: "\u00a0A=1\n", key: "A", value: "2",
		text: "A=2\n", want: map[string]string{"A": "2"}},
	{name: "spaces and tabs before the key", data: " \tA=1\n", key: "A", value: "2",
		text: " \tA=2\n", want: map[string]string{"A": "2"}},
	{name: "a byte order mark before the key", data: "\uFEFFA=1\nB=2\n", key: "A", value: "3",
		text: "A=3\nB=2\n", want: map[string]string{"A": "3", "B": "2"}},
	{name: "a CRLF line with a comment", data: "A=\"\" # c\r\nB=2\r\n", key: "A", value: "",
		text: "A=\"\" # c\r\nB=2\r\n", want: map[string]string{"A": "", "B": "2"}},
	{name: "a CRLF line with two settings", data: "A=\"1\" B=2\r\nC=3\r\n", key: "A", value: "x",
		text: "A=x\r\nB=2\r\nC=3\r\n", want: map[string]string{"A": "x", "B": "2", "C": "3"}},
	{name: "the second setting of a line, before an export line", data: "A=\"x\" B=2\nexport C=3\n", key: "B", unset: true,
		text: "A=\"x\"\nexport C=3\n", want: map[string]string{"A": "x", "C": "3"}},
	{name: "the second setting of a line, before a key left to the environment", data: "A=\"x\" B=2 # b\nC\n", key: "B", unset: true,
		text: "A=\"x\"\nC\n", want: map[string]string{"A": "x"}},
	{name: "the second setting of the last line", data: "A=\"x\" B=2", key: "B", unset: true,
		text: "A=\"x\"", want: map[string]string{"A": "x"}},
	{name: "the first setting of a line", data: "A=\"x\" B=2\nC=3\n", key: "A", unset: true,
		text: "B=2\nC=3\n", want: map[string]string{"B": "2", "C": "3"}},
	{name: "the setting that holds the export keyword of its line", data: "export A=\"1\" C='s' C\n", key: "A", unset: true,
		text: "export C='s'\nexport C\n", want: map[string]string{"C": "s"}},
	{name: "a setting between two others", data: "A=\"\"export B='s'  C=1\n", key: "B", unset: true,
		text: "A=\"\"\nexport C=1\n", want: map[string]string{"A": "", "C": "1"}},
}

// shellReads is what the shell of the scripts (set -a; . .env) reads from
// data for keys, the ones it leaves unset out.
func shellReads(t *testing.T, bash string, data []byte, keys []string) map[string]string {
	t.Helper()
	file := filepath.Join(t.TempDir(), ".env")
	if err := os.WriteFile(file, data, 0o600); err != nil {
		t.Fatal(err)
	}
	script := `set -a; . "$1" >/dev/null 2>&1; shift; for k; do if [ -n "${!k+set}" ]; then printf '%s=%s\0' "$k" "${!k}"; fi; done`
	// A name the shell cannot hold, which compose takes, is one it leaves
	// unset.
	keys = slices.DeleteFunc(slices.Clone(keys), func(k string) bool { return !shellName(k) })
	out, err := exec.Command(bash, append([]string{"-c", script, "bash", file}, keys...)...).Output()
	if err != nil {
		t.Fatalf("bash: %v", err)
	}
	read := map[string]string{}
	for _, entry := range strings.Split(strings.TrimSuffix(string(out), "\x00"), "\x00") {
		if key, value, ok := strings.Cut(entry, "="); ok {
			read[key] = value
		}
	}
	return read
}

// An edit rewrites the whole setting, so that what follows its value on the
// line reads as it did: an inline comment stays a comment, in compose too,
// where it would become the value after an empty one. A line that holds
// other settings is written again with each on a line of its own: the
// shell reads a line as one command, where a setting sticks to a value in
// quotes right before it, runs as a command when it is no assignment (a
// key alone, a setting written as yaml) and hands the assignments before
// it to that command, and takes the settings after an export keyword as
// its arguments.
func TestEditsKeepWhatSharesTheLine(t *testing.T) {
	bash, _ := exec.LookPath("bash")
	for _, tc := range lineEdits {
		got, err := tc.edit()
		if err != nil || string(got) != tc.text {
			t.Errorf("%s: got %q, %v; want %q", tc.name, got, err, tc.text)
			continue
		}
		if read, err := Parse(got, nil); err != nil || !maps.Equal(read, tc.want) {
			t.Errorf("%s: compose reads %q as %q, %v; want %q", tc.name, got, read, err, tc.want)
		}
		if bash == "" || strings.Contains(tc.data, "\r") {
			continue
		}
		keys := slices.Sorted(maps.Keys(Assigned([]byte(tc.data + "\n" + string(got)))))
		keys = append(keys, "C")
		want := tc.want
		if tc.shell != nil {
			want = tc.shell
		}
		if read := shellReads(t, bash, got, keys); !maps.Equal(read, want) {
			t.Errorf("%s: the shell reads %q as %q, want %q", tc.name, got, read, want)
		}
	}
	for _, key := range []string{"DOTS.AND-DASH", "1A", "A-B", ""} {
		if _, err := Set([]byte("A=1\n"), key, "x"); err == nil {
			t.Errorf("%q was set although the shell cannot set a variable of that name", key)
		}
	}
}

// A line of the operator's that the shell reads otherwise than compose, in
// a way that reaches the setting written, the lines around it or the edit
// that takes it back, has the edit refused and named, the file left as it
// was; one that does not reach them is no reason to refuse.
func TestEditsRefuseWhatTheShellWouldReadOtherwise(t *testing.T) {
	bash, _ := exec.LookPath("bash")
	cases := []struct {
		name, data, key, value string
		unset                  bool
		line                   int
		text                   string
	}{
		{name: "a setting of the key in a value out of quotes after the last one", data: "C=1\nA=1 C=2\n", key: "C", value: "x", line: 2},
		{name: "a setting of the key only the shell reads, removed", data: "A=1;C=2\n", key: "C", unset: true, line: 1},
		{name: "a key with a tab after the last setting", data: "A=1\nexport B\tA='s'\n", key: "A", value: "x", line: 2},
		{name: "another setting in the value on the line written again", data: "A=\"1\" B=2 C=3\n", key: "A", value: "x", line: 1},
		{name: "another setting in the value replaced", data: "A=1 C=2\nC=2\n", key: "A", value: "x", line: 1},
		{name: "a backslash on the line before", data: "B=x\\\nA=1\n", key: "A", value: "y", line: 1},
		{name: "a backslash on the line before one removed", data: "B=x\\\nA=1\nC=2\n", key: "A", unset: true, line: 1},
		{name: "a backslash on the line written again", data: "A=x\\\nB=1 C=2\n", key: "A", value: "y", line: 1},
		{name: "a backslash right at the end, before the line added", data: "B=x\\", key: "A", value: "y", line: 1},
		{name: "a setting of the key only the shell reads, with no setting of the key", data: "A=1 C=2\n", key: "C", value: "x", line: 1},
		{name: "a setting of the key only the shell reads before the last one", data: "A=1 C=2\nC=1\n", key: "C", value: "x", line: 1},
		{name: "a setting of the key in its own value", data: "C=1 C=2\n", key: "C", value: "x", text: "C=x\n"},
		{name: "a setting of the key in its own value, removed", data: "C=1 C=2\nA=1\n", key: "C", unset: true, text: "A=1\n"},
		{name: "a backslash and a line feed before the line added", data: "B=x\\\n", key: "A", value: "y", text: "B=x\\\n\nA=y\n"},
		{name: "a backslash and a blank line before the line added", data: "B=x\\\n\n", key: "A", value: "y", text: "B=x\\\n\nA=y\n"},
		{name: "a backslash and blanks that end the file before the line added", data: "B=x\\\n  ", key: "A", value: "y", text: "B=x\\\n  \nA=y\n"},
		{name: "two backslashes on the line before", data: "B=x\\\\\nA=1\n", key: "A", value: "y", text: "B=x\\\\\nA=y\n"},
		{name: "a backslash before a blank on the line before", data: "B=x\\ \nA=1\n", key: "A", value: "y", text: "B=x\\ \nA=y\n"},
	}
	for _, tc := range cases {
		var got []byte
		var err error
		if tc.unset {
			got, _, err = Unset([]byte(tc.data), tc.key)
		} else {
			got, err = Set([]byte(tc.data), tc.key, tc.value)
		}
		if tc.line > 0 {
			if err == nil || !strings.HasPrefix(err.Error(), fmt.Sprintf("%s: line %d: ", tc.key, tc.line)) || got != nil {
				t.Errorf("%s: got %q, %v; want line %d named and nothing written", tc.name, got, err, tc.line)
			}
			if bash != "" && err != nil {
				refused(t, bash, []byte(tc.data), tc.key, err)
			}
			continue
		}
		if err != nil || string(got) != tc.text {
			t.Errorf("%s: got %q, %v; want %q", tc.name, got, err, tc.text)
			continue
		}
		read, _ := Parse(got, nil)
		readers := map[string]map[string]string{"compose": read}
		if bash != "" {
			readers["the shell"] = shellReads(t, bash, got, []string{tc.key})
		}
		for reader, read := range readers {
			if value, set := read[tc.key]; set == tc.unset || value != tc.value {
				t.Errorf("%s: %s reads %s=%q (%v) from %q", tc.name, reader, tc.key, value, set, got)
			}
		}
	}
}

// Random files of the forms compose reads, several settings on a line
// included, edited by Set and Unset: afterwards compose and the shell of the
// scripts both read the key edited as it was set, or not at all, and every
// other key compose reads as before, which both read alike before from the
// same setting, they still read alike. Each value written is told apart by
// a number of its own, so that two settings never read alike by chance; an
// empty one can, and is left out of that comparison. An edit is refused only
// for a line that compose and the shell read otherwise (refused), and one
// that goes through can be taken back.
func TestEditsLeaveTheShellReadingWhatComposeReads(t *testing.T) {
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Skip("bash is not installed")
	}
	keys := []string{"A", "B", "C"}
	values := []string{`"1_%d"`, `'s_%d'`, `""`, `"two words_%d"`, `"$A"`, "1_%d", "", "two words_%d", "$B", "x;C=1_%d", `x_%d\`}
	gaps := []string{" ", "", "\t", "  ", "\u00a0"}
	leads := []string{"", "", " ", "\u00a0"}
	written := []string{"x", "", "a b", "#h", "it's", "$x"}
	r := rand.New(rand.NewSource(20261007))
	edits := 0
	for edits < 300 {
		var b strings.Builder
		for range 1 + r.Intn(2) {
			b.WriteString(leads[r.Intn(len(leads))])
			settings := 1 + r.Intn(3)
			for s := range settings {
				if r.Intn(4) == 0 {
					b.WriteString("export ")
				}
				key, value := keys[r.Intn(len(keys))], values[r.Intn(len(values))]
				if strings.Contains(value, "%d") {
					value = fmt.Sprintf(value, b.Len())
				}
				switch r.Intn(8) {
				case 0:
					b.WriteString(key)
				case 1:
					b.WriteString(key + ": " + value)
				default:
					b.WriteString(key + "=" + value)
				}
				if s < settings-1 {
					b.WriteString(gaps[r.Intn(len(gaps))])
				}
			}
			if r.Intn(3) == 0 {
				b.WriteString(" # c")
			}
			b.WriteString("\n")
		}
		data := []byte(b.String())
		before, err := Parse(data, nil)
		if err != nil {
			continue
		}
		edits++
		key, value, unset := keys[r.Intn(len(keys))], written[r.Intn(len(written))], r.Intn(3) == 0
		var out []byte
		if unset {
			out, _, err = Unset(data, key)
		} else {
			out, err = Set(data, key, value)
		}
		if err != nil {
			refused(t, bash, data, key, err)
			continue
		}
		after, err := Parse(out, nil)
		if err != nil {
			t.Errorf("%q gave %q, which compose cannot read: %v", data, out, err)
			continue
		}
		shellBefore, shellAfter := shellReads(t, bash, data, keys), shellReads(t, bash, out, keys)
		got, inCompose := after[key]
		read, inShell := shellAfter[key]
		switch {
		case unset && (inCompose || inShell):
			t.Errorf("%q, Unset %s: %q still sets it: compose %q, the shell %q", data, key, out, after, shellAfter)
		case !unset && (!inCompose || got != value || !inShell || read != value):
			t.Errorf("%q, Set %s %q: %q reads %s as %q in compose and %q in the shell", data, key, value, out, key, got, read)
		}
		for _, other := range keys {
			if other == key {
				continue
			}
			was, wasSet := before[other]
			shellWas, shellWasSet := shellBefore[other]
			now, nowSet := after[other]
			shellNow, shellNowSet := shellAfter[other]
			if !bytes.Contains(data, []byte("$")) && (now != was || nowSet != wasSet) {
				t.Errorf("%q, edit of %s: %q has compose read %s as %q (%v), %q (%v) before", data, key, out, other, now, nowSet, was, wasSet)
			}
			alike := was == shellWas && wasSet == shellWasSet && (!wasSet || was != "")
			if alike && now == was && nowSet == wasSet && (shellNow != now || shellNowSet != nowSet) {
				t.Errorf("%q, edit of %s: %q has compose read %s as %q (%v) and the shell %q (%v), alike before", data, key, out, other, now, nowSet, shellNow, shellNowSet)
			}
		}
		// A rollback takes the edit back with the opposite one: Set of the
		// value compose read before, or Unset of a key the edit added. It
		// goes through as well (a value no form writes is the operator's
		// own, and left out), and compose reads what it read before.
		old, had := before[key]
		var back []byte
		switch {
		case had:
			if _, err := quote(old); err != nil {
				continue
			}
			back, err = Set(out, key, old)
		case !unset:
			back, _, err = Unset(out, key)
		default:
			continue
		}
		if err != nil {
			t.Errorf("%q, edit of %s: %q, the edit that takes it back is refused: %v", data, key, out, err)
			continue
		}
		if again, err := Parse(back, nil); err != nil || !bytes.Contains(data, []byte("$")) && !maps.Equal(again, before) {
			t.Errorf("%q, edit of %s taken back: %q has compose read %q, %v; %q before", data, key, back, again, err, before)
		}
	}
}

// refused checks the refusal of an edit of key in data: the line it names,
// followed by a setting of key when the refusal is about a backslash that
// joins the next line to it, is read otherwise by compose and by the shell.
func refused(t *testing.T, bash string, data []byte, key string, err error) {
	t.Helper()
	var n int
	keys := []string{"A", "B", "C", key}
	msg := err.Error()
	if _, scanErr := fmt.Sscanf(msg, key+": line %d:", &n); scanErr != nil {
		t.Errorf("%q: the edit of %s was refused: %v", data, key, err)
		return
	}
	part := []byte(strings.Split(string(data), "\n")[n-1] + "\n")
	switch {
	case strings.Contains(msg, "for a setting"):
		_, rest, _ := strings.Cut(msg, "may take ")
		name, rest, _ := strings.Cut(rest, "=")
		_, quoted, _ := strings.Cut(rest, "reads as part of ")
		quoted, _, _ = strings.Cut(quoted, ":")
		holder, unquoteErr := strconv.Unquote(quoted)
		if unquoteErr != nil {
			t.Errorf("%q: the edit of %s was refused: %v", data, key, err)
			return
		}
		keys = append(keys, name, holder)
	case strings.Contains(msg, "backslash"):
		part = append(part, key+"=1\n"...)
	default:
		t.Errorf("%q: the edit of %s was refused: %v", data, key, err)
		return
	}
	compose := map[string]string{}
	read, _ := Parse(part, nil)
	for _, k := range keys {
		if v, ok := read[k]; ok {
			compose[k] = v
		}
	}
	if maps.Equal(compose, shellReads(t, bash, part, keys)) {
		t.Errorf("%q: the edit of %s was refused for %q, which compose and the shell read alike: %v", data, key, part, err)
	}
}

// TestEditsKeepWhatSharesTheLineInCompose holds the edits of lineEdits to
// docker compose itself, like TestComposeParity.
func TestEditsKeepWhatSharesTheLineInCompose(t *testing.T) {
	if os.Getenv("KVSCTL_COMPOSE_PARITY") != "1" {
		t.Skip("set KVSCTL_COMPOSE_PARITY=1 to compare with docker compose")
	}
	if err := exec.Command("docker", "compose", "version").Run(); err != nil {
		t.Skipf("docker compose is not available: %v", err)
	}
	base := []string{"PATH=" + os.Getenv("PATH"), "HOME=" + t.TempDir(), "DOCKER_CONFIG=" + t.TempDir()}
	for _, tc := range lineEdits {
		got, err := tc.edit()
		if err != nil {
			t.Errorf("%s: %v", tc.name, err)
			continue
		}
		read, want, err := compareWithCompose(t, got, base)
		if err != nil {
			t.Errorf("%s: %v", tc.name, err)
			continue
		}
		if !maps.Equal(read, want) {
			t.Errorf("%s: compose and Parse differ on %q:\ncompose %q\n  Parse %q", tc.name, got, read, want)
		}
		for key, value := range tc.want {
			if read[key] != value {
				t.Errorf("%s: compose reads %s=%q from %q, want %q", tc.name, key, read[key], got, value)
			}
		}
		for _, key := range []string{"A", "B", "C", "KEY"} {
			if _, set := tc.want[key]; !set {
				if value, found := read[key]; found {
					t.Errorf("%s: compose reads %s=%q from %q, want it unset", tc.name, key, value, got)
				}
			}
		}
	}
}

// Graft is how restore --env keeps the live settings kvsctl manages over an
// archived .env: what compose reads from the result is the archived value
// of every other key and the live value of the managed ones, whatever form
// either file writes them in.
func TestGraft(t *testing.T) {
	managed := func(key string) bool { return strings.HasPrefix(key, "KVS_") }
	cases := []struct{ name, data, donor, want string }{
		{"export lines",
			"DOMAIN=example.com\nexport KVS_PHP_FPM_IMAGE=r/php:1.0.0@sha256:aaaa\nexport KVS_STACK_VERSION=1.0.0\n",
			"DOMAIN=other.example\nexport KVS_PHP_FPM_IMAGE=r/php:1.1.0@sha256:bbbb\nexport KVS_STACK_VERSION=1.1.0\n",
			"DOMAIN=example.com\nexport KVS_PHP_FPM_IMAGE=r/php:1.1.0@sha256:bbbb\nexport KVS_STACK_VERSION=1.1.0\n"},
		{"a value on several lines that looks like a setting",
			"NOTE=\"first\nKVS_STACK_VERSION=0.9.0\"\nKVS_STACK_VERSION=1.0.0\n",
			"KVS_STACK_VERSION=1.1.0\n",
			"NOTE=\"first\nKVS_STACK_VERSION=0.9.0\"\nKVS_STACK_VERSION=1.1.0\n"},
		{"comments, quotes and CRLF",
			"# the site\r\nDOMAIN=example.com # main\r\n  KVS_CRON_IMAGE='r/cron:1.0.0'\r\nA=1\r\n",
			"KVS_CRON_IMAGE=\"r/cron:1.1.0\" # pinned\n",
			"# the site\r\nDOMAIN=example.com # main\r\n  KVS_CRON_IMAGE=\"r/cron:1.1.0\" # pinned\r\nA=1\r\n"},
		{"a key set twice in each",
			"KVS_X=1\nA=1\nKVS_X=2\n",
			"KVS_X=8\nKVS_X=9\n",
			"KVS_X=9\nA=1\n"},
		{"a key only one file sets",
			"KVS_OLD=1\nA=1",
			"KVS_NEW=2\nB=2\n",
			"A=1\nKVS_NEW=2\n"},
		{"keys after a setting on their line",
			"A=\"x\" KVS_X=1 # c\nB=\"y\" KVS_OLD=1\nC\n",
			"KVS_X=2\n",
			"A=\"x\"\nKVS_X=2\nB=\"y\"\nC\n"},
		{"keys taken from a line they share",
			"export KVS_X=1 # c\nKVS_Y=1\n",
			"export A=\"x\" KVS_X=\"2\" KVS_Z=3 # live\n",
			"export KVS_X=\"2\"\nexport KVS_Z=3 # live\n"},
		{"keys added after a value that ends with a backslash",
			"DOMAIN=example.com\nPATTERN=a\\\n",
			"KVS_STACK_VERSION=1.1.0\nKVS_X=2\n",
			"DOMAIN=example.com\nPATTERN=a\\\n\nKVS_STACK_VERSION=1.1.0\nKVS_X=2\n"},
	}
	for _, tc := range cases {
		got, kept, err := Graft([]byte(tc.data), []byte(tc.donor), managed)
		if err != nil || string(got) != tc.want {
			t.Errorf("%s: got %q, %v; want %q", tc.name, got, err, tc.want)
			continue
		}
		read, err := Parse(got, nil)
		if err != nil {
			t.Errorf("%s: %q: %v", tc.name, got, err)
			continue
		}
		archived, _ := Parse([]byte(tc.data), nil)
		live, _ := Parse([]byte(tc.donor), nil)
		want := map[string]string{}
		var keys []string
		for k, v := range archived {
			if !managed(k) {
				want[k] = v
			}
		}
		for k, v := range live {
			if managed(k) {
				want[k] = v
			}
		}
		for k := range Assigned([]byte(tc.data + "\n" + tc.donor)) {
			if managed(k) {
				keys = append(keys, k)
			}
		}
		slices.Sort(keys)
		if !maps.Equal(read, want) || !slices.Equal(kept, keys) {
			t.Errorf("%s: compose reads %v from the result, want %v; kept %q, want %q", tc.name, read, want, kept, keys)
		}
	}
	if _, _, err := Graft([]byte("A=\"open\n"), []byte("KVS_X=1\n"), managed); err == nil {
		t.Error("an archived file compose cannot read was merged")
	}
	// The shell reads a key added after a value that ends with a backslash
	// on its own; with that backslash right at the end, where the shell
	// reads it as itself, the keys are not added.
	if bash, err := exec.LookPath("bash"); err == nil {
		got, _, err := Graft([]byte("PATTERN=a\\\n"), []byte("KVS_X=1\n"), managed)
		if read := shellReads(t, bash, got, []string{"PATTERN", "KVS_X"}); err != nil || read["KVS_X"] != "1" || read["PATTERN"] != "a" {
			t.Errorf("the shell reads %q from %q, %v", read, got, err)
		}
	}
	if got, _, err := Graft([]byte("PATTERN=a\\"), []byte("KVS_X=1\n"), managed); err == nil || !strings.HasPrefix(err.Error(), "KVS_X: line 1: the value of PATTERN ends with a backslash") {
		t.Errorf("keys added after a backslash at the end: %q, %v", got, err)
	}
}

package main

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/MaximeMichaud/KVS-install/cli/internal/manifest"
)

func TestParseImages(t *testing.T) {
	specs, err := parseImages("nginx=r/nginx:26.10.0, php-fpm@8.1=r/php:26.10.0-php8.1\ncron@8.1=r/cron:26.10.0-php8.1,mariadb=mariadb:11.8.3")
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, s := range specs {
		got = append(got, s.Key()+" -> "+s.Ref)
	}
	want := []string{
		"nginx -> r/nginx:26.10.0",
		"php-fpm@8.1 -> r/php:26.10.0-php8.1",
		"cron@8.1 -> r/cron:26.10.0-php8.1",
		"mariadb -> mariadb:11.8.3",
	}
	if strings.Join(got, "; ") != strings.Join(want, "; ") {
		t.Errorf("parseImages = %v, want %v", got, want)
	}
	if specs[1].Series != "8.1" || specs[0].Series != "" {
		t.Errorf("the series must come from the @ part: %+v", specs)
	}
	if specs, err := parseImages(""); err != nil || len(specs) != 0 {
		t.Errorf("an empty list is not an error: %v %v", specs, err)
	}
	// A reference that already carries a digest keeps its @.
	pinnedRef, err := parseImages("nginx=r/nginx:26.10.0@sha256:aaa")
	if err != nil || pinnedRef[0].Ref != "r/nginx:26.10.0@sha256:aaa" || pinnedRef[0].Series != "" {
		t.Errorf("a digest in the reference is not a series: %+v %v", pinnedRef, err)
	}
	for _, bad := range []string{"nginx", "nginx=", "=ref", "php-fpm@=ref", "nginx=a,nginx=b", "php-fpm@8.1=a,php-fpm@8.1=b", "php-fpm=a,php-fpm@8.1=b"} {
		if _, err := parseImages(bad); err == nil {
			t.Errorf("parseImages(%q) must fail", bad)
		}
	}
}

func TestParseDigests(t *testing.T) {
	// The workflow writes the services that do not vary as "nginx@=...".
	digests, err := parseDigests("nginx@=sha256:aaa php-fpm@8.1=sha256:bbb\ncron@8.1=sha256:ccc,mariadb=sha256:ddd")
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]string{"nginx": "sha256:aaa", "php-fpm@8.1": "sha256:bbb", "cron@8.1": "sha256:ccc", "mariadb": "sha256:ddd"}
	for key, digest := range want {
		if digests[key] != digest {
			t.Errorf("digest of %s = %q, want %q", key, digests[key], digest)
		}
	}
	if len(digests) != len(want) {
		t.Errorf("parseDigests = %v", digests)
	}
	for _, bad := range []string{"nginx", "nginx=aaa", "=sha256:aaa"} {
		if _, err := parseDigests(bad); err == nil {
			t.Errorf("parseDigests(%q) must fail", bad)
		}
	}
}

func TestRenderOverrideWithVariants(t *testing.T) {
	specs, err := parseImages("nginx=r/nginx:26.10.0,php-fpm@8.1=r/php:26.10.0-php8.1,cron@8.1=r/cron:26.10.0-php8.1,mariadb=mariadb:11.8.3")
	if err != nil {
		t.Fatal(err)
	}
	digests, err := parseDigests("nginx=sha256:aaa,mariadb=sha256:ddd")
	if err != nil {
		t.Fatal(err)
	}
	built := map[string]bool{}
	for _, service := range builtByDefault {
		built[service] = true
	}
	out := renderOverride("26.10.0", specs, digests, built)
	header, body, found := strings.Cut(out, "services:\n")
	if !found {
		t.Fatalf("no services section:\n%s", out)
	}
	for _, want := range []string{"26.10.0", "build: !reset null", "2.24", "COMPOSE_FILE", "PHP series"} {
		if !strings.Contains(header, want) {
			t.Errorf("the header does not explain %q:\n%s", want, header)
		}
	}
	want := `  nginx:
    build: !reset null
    image: "r/nginx:26.10.0@sha256:aaa"
  php-fpm:
    build: !reset null
    image: "${KVS_PHP_FPM_IMAGE}"
  cron:
    build: !reset null
    image: "${KVS_CRON_IMAGE}"
  mariadb:
    image: "mariadb:11.8.3@sha256:ddd"
`
	if body != want {
		t.Errorf("override =\n%s\nwant\n%s", body, want)
	}
}

func TestRenderOverrideWithoutVariants(t *testing.T) {
	specs, err := parseImages("nginx=r/nginx:0.2.0,php-fpm=r/php:0.2.0")
	if err != nil {
		t.Fatal(err)
	}
	built := map[string]bool{"nginx": true, "php-fpm": true}
	out := renderOverride("0.2.0", specs, nil, built)
	_, body, _ := strings.Cut(out, "services:\n")
	want := `  nginx:
    build: !reset null
    image: "r/nginx:0.2.0"
  php-fpm:
    build: !reset null
    image: "r/php:0.2.0"
`
	if body != want {
		t.Errorf("override =\n%s\nwant\n%s", body, want)
	}
	if strings.Contains(out, "${") {
		t.Error("a release without variants pins the reference directly")
	}
	// A service the base compose file does not build keeps no build key.
	_, body, _ = strings.Cut(renderOverride("0.2.0", specs, nil, map[string]bool{"nginx": true}), "services:\n")
	if strings.Count(body, "!reset") != 1 {
		t.Errorf("only the built services lose their build section:\n%s", body)
	}
}

func TestEnvVar(t *testing.T) {
	cases := map[string]string{
		"php-fpm":   "KVS_PHP_FPM_IMAGE",
		"cron":      "KVS_CRON_IMAGE",
		"kvs-init":  "KVS_KVS_INIT_IMAGE",
		"manticore": "KVS_MANTICORE_IMAGE",
	}
	for service, want := range cases {
		if got := envVar(service); got != want {
			t.Errorf("envVar(%s) = %s, want %s", service, got, want)
		}
	}
}

func TestLoadSignersDerivesTheKeyID(t *testing.T) {
	dir := t.TempDir()
	if err := keygen([]string{"--out", dir}); err != nil {
		t.Fatal(err)
	}
	other := filepath.Join(dir, "other")
	if err := keygen([]string{"--out", other}); err != nil {
		t.Fatal(err)
	}
	keyPath := filepath.Join(dir, "release.key")
	encoded, err := os.ReadFile(filepath.Join(dir, "release.pub"))
	if err != nil {
		t.Fatal(err)
	}
	raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(encoded)))
	if err != nil {
		t.Fatal(err)
	}
	pub := ed25519.PublicKey(raw)
	signers, err := loadSigners([]string{keyPath}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(signers) != 1 || signers[0].id != manifest.KeyID(pub) {
		t.Fatalf("key id = %q, want %q", signers[0].id, manifest.KeyID(pub))
	}
	if len(signers[0].id) != 8 {
		t.Errorf("a derived key id is eight hex characters, got %q", signers[0].id)
	}
	named, err := loadSigners([]string{keyPath, filepath.Join(other, "release.key")}, []string{"r1"})
	if err != nil {
		t.Fatal(err)
	}
	if named[0].id != "r1" || named[1].id == "r1" {
		t.Errorf("--key-id pairs by position: %q %q", named[0].id, named[1].id)
	}
	if _, err := loadSigners([]string{keyPath}, []string{"r1", "r2"}); err == nil {
		t.Error("more key ids than keys must fail")
	}
	if _, err := loadSigners([]string{keyPath, keyPath}, nil); err == nil {
		t.Error("the same key twice must fail")
	}
	if _, err := loadSigners(nil, nil); err == nil {
		t.Error("signing without a key must fail")
	}
}

func TestSignManifestIsReadBack(t *testing.T) {
	dir := t.TempDir()
	if err := keygen([]string{"--out", dir}); err != nil {
		t.Fatal(err)
	}
	second := filepath.Join(dir, "next")
	if err := keygen([]string{"--out", second}); err != nil {
		t.Fatal(err)
	}
	signers, err := loadSigners([]string{filepath.Join(dir, "release.key"), filepath.Join(second, "release.key")}, []string{"r1", "r2"})
	if err != nil {
		t.Fatal(err)
	}
	raw := []byte(`{"schema":2,"channel":"stable","updated":"2026-10-15T12:00:00Z","releases":[{"version":"26.10.0","date":"2026-10-15","bundle":{"url":"file:///b.tar.gz","sha256":"0000000000000000000000000000000000000000000000000000000000000000"},"images":[{"service":"nginx","ref":"r/nginx:26.10.0","digest":"sha256:aaa","size":5}]}]}`)
	sig, err := signManifest(raw, signers)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(strings.TrimSpace(string(sig)), "[") || !strings.Contains(string(sig), `"key_id": "r2"`) {
		t.Fatalf("the signature file must be the JSON list:\n%s", sig)
	}
	path := filepath.Join(dir, "manifest.json")
	if err := os.WriteFile(path, raw, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path+".sig", sig, 0o644); err != nil {
		t.Fatal(err)
	}
	doc, err := manifest.Fetch("file://" + path)
	if err != nil {
		t.Fatal(err)
	}
	for _, s := range signers {
		if err := doc.VerifyAny([]ed25519.PublicKey{s.priv.Public().(ed25519.PublicKey)}); err != nil {
			t.Errorf("key %s must verify the file it signed: %v", s.id, err)
		}
	}
	if doc.Manifest == nil || doc.Manifest.Latest().Version != "26.10.0" {
		t.Error("the verified document must carry the manifest")
	}
}

func TestFirstParagraph(t *testing.T) {
	notes := "### Features\n\n- add the Manticore search backend\n  and drop the internal one\n\n### Fixes\n\n- something else\n"
	if got := firstParagraph(notes); got != "add the Manticore search backend and drop the internal one" {
		t.Errorf("firstParagraph = %q", got)
	}
	if got := firstParagraph("\n\nplain   text\nover two lines\n\nrest\n"); got != "plain text over two lines" {
		t.Errorf("firstParagraph = %q", got)
	}
	if got := firstParagraph("# Title\n"); got != "" {
		t.Errorf("a file of headings gives no note, got %q", got)
	}
}

func TestParseAnnouncedKeys(t *testing.T) {
	dir := t.TempDir()
	if err := keygen([]string{"--out", dir}); err != nil {
		t.Fatal(err)
	}
	encoded, err := os.ReadFile(filepath.Join(dir, "release.pub"))
	if err != nil {
		t.Fatal(err)
	}
	pub := strings.TrimSpace(string(encoded))
	keys, err := parseAnnouncedKeys([]string{"r2=" + pub + "@2026-11-01"})
	if err != nil {
		t.Fatal(err)
	}
	if len(keys) != 1 || keys[0].ID != "r2" || keys[0].Pub != pub || keys[0].ValidFrom != "2026-11-01" {
		t.Errorf("announced key = %+v", keys)
	}
	if keys, err := parseAnnouncedKeys([]string{"r2=" + pub}); err != nil || keys[0].ValidFrom != "" {
		t.Errorf("the date is optional: %+v %v", keys, err)
	}
	for _, bad := range []string{"r2", "=" + pub, "r2=not-base64", "r2=" + pub + "@tomorrow"} {
		if _, err := parseAnnouncedKeys([]string{bad}); err == nil {
			t.Errorf("parseAnnouncedKeys(%q) must fail", bad)
		}
	}
}

// registryStub answers the two distribution API calls registryDigest makes,
// with a digest derived from the path so every image gets its own.
func registryStub() *httptest.Server {
	mux := http.NewServeMux()
	mux.HandleFunc("/v2/", func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.Contains(r.URL.Path, "/manifests/"):
			w.Header().Set("Docker-Content-Digest", stubDigest(r.URL.Path))
			w.Header().Set("Content-Type", "application/vnd.oci.image.manifest.v1+json")
			fmt.Fprint(w, `{"mediaType":"application/vnd.oci.image.manifest.v1+json","config":{"digest":"sha256:config","size":3},"layers":[{"digest":"sha256:layer","size":97}]}`)
		case strings.Contains(r.URL.Path, "/blobs/"):
			fmt.Fprint(w, `{"rootfs":{"diff_ids":["sha256:diff"]}}`)
		default:
			http.NotFound(w, r)
		}
	})
	return httptest.NewServer(mux)
}

func stubDigest(path string) string {
	sum := sha256.Sum256([]byte(path))
	return "sha256:" + hex.EncodeToString(sum[:])
}

func TestManifestCommandWritesVariants(t *testing.T) {
	registry := registryStub()
	defer registry.Close()
	host := strings.TrimPrefix(registry.URL, "http://")
	dir := t.TempDir()
	if err := keygen([]string{"--out", dir}); err != nil {
		t.Fatal(err)
	}
	bundlePath := filepath.Join(dir, "kvs-stack-26.10.0.tar.gz")
	if err := os.WriteFile(bundlePath, []byte("a bundle"), 0o644); err != nil {
		t.Fatal(err)
	}
	notesPath := filepath.Join(dir, "RELEASE_NOTES.md")
	if err := os.WriteFile(notesPath, []byte("### Features\n\n- Manticore replaces the internal search\n\n### Fixes\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	site := filepath.Join(dir, "site")
	nginx := host + "/kvs-install/nginx:26.10.0"
	php := host + "/kvs-install/php:26.10.0-php8.1"
	cron := host + "/kvs-install/cron:26.10.0-php8.1"
	args := []string{
		"--key", filepath.Join(dir, "release.key"), "--key-id", "r1",
		"--out", site, "--version", "26.10.0",
		"--bundle", bundlePath, "--bundle-url", "file://" + bundlePath,
		"--images", fmt.Sprintf("nginx=%s,php-fpm@8.1=%s,cron@8.1=%s", nginx, php, cron),
		"--digests", "nginx@=" + stubDigest("/v2/kvs-install/nginx/manifests/26.10.0"),
		"--notes-file", notesPath, "--notes-url", "https://example.test/26.10.0",
		"--highlight", "Manticore is the default search backend",
		"--php-series", "8.1,8.2", "--mariadb-from", "11.4,11.8",
		"--compose-min", "2.24.0", "--min-from", "26.9.0", "--kvs-min", "7.0.0",
		"--database", "migrates", "--one-way",
	}
	if err := manifestCmd(args); err != nil {
		t.Fatal(err)
	}
	doc, err := manifest.Fetch("file://" + filepath.Join(site, "manifest.json"))
	if err != nil {
		t.Fatal(err)
	}
	encoded, err := os.ReadFile(filepath.Join(dir, "release.pub"))
	if err != nil {
		t.Fatal(err)
	}
	keys, err := manifest.ParseKeys([]string{strings.TrimSpace(string(encoded))})
	if err != nil {
		t.Fatal(err)
	}
	if err := doc.VerifyAny(keys); err != nil {
		t.Fatal(err)
	}
	m := doc.Manifest
	if m.Schema != manifest.Schema || m.Updated == "" {
		t.Errorf("schema %d, updated %q", m.Schema, m.Updated)
	}
	rel := m.Latest()
	if len(rel.Images) != 1 || rel.Images[0].Service != "nginx" {
		t.Errorf("images = %+v, only the service that does not vary belongs there", rel.Images)
	}
	if rel.Images[0].Size != 100 || len(rel.Images[0].Layers) != 1 {
		t.Errorf("the size and the layers come from the registry: %+v", rel.Images[0])
	}
	series := rel.Variants[manifest.VariantPHP]["8.1"]
	if len(series) != 2 || series[0].Service != "php-fpm" || series[1].Service != "cron" {
		t.Fatalf("variants = %+v", rel.Variants)
	}
	images, err := rel.ImagesFor("8.1")
	if err != nil || len(images) != 3 {
		t.Errorf("ImagesFor(8.1) = %d images: %v", len(images), err)
	}
	if _, err := rel.ImagesFor("8.2"); err == nil {
		t.Error("a series that is announced but not published must still be refused")
	}
	if rel.Requires.PHP != "8.1" || strings.Join(rel.Requires.PHPSeries, ",") != "8.1,8.2" {
		t.Errorf("requires = %+v", rel.Requires)
	}
	if strings.Join(rel.Requires.MariaDBFrom, ",") != "11.4,11.8" || rel.Requires.ComposeMin != "2.24.0" {
		t.Errorf("requires = %+v", rel.Requires)
	}
	if !rel.OneWay || rel.Database != "migrates" {
		t.Errorf("one_way %v, database %q", rel.OneWay, rel.Database)
	}
	if rel.Notes != "Manticore replaces the internal search" || rel.NotesURL == "" || len(rel.Highlights) != 1 {
		t.Errorf("notes %q, url %q, highlights %v", rel.Notes, rel.NotesURL, rel.Highlights)
	}
	if len(doc.Signatures) != 1 || doc.Signatures[0].KeyID != "r1" {
		t.Errorf("signatures = %+v", doc.Signatures)
	}
	// A digest the registry does not confirm stops the release.
	bad := append([]string{}, args...)
	for i, a := range bad {
		if a == "--digests" {
			bad[i+1] = "nginx@=sha256:0000"
		}
	}
	if err := manifestCmd(bad); err == nil {
		t.Error("a digest the registry does not confirm must be refused")
	}
	unknown := append([]string{}, args...)
	for i, a := range unknown {
		if a == "--digests" {
			unknown[i+1] = "php@8.1=" + stubDigest("/v2/kvs-install/php/manifests/26.10.0-php8.1")
		}
	}
	if err := manifestCmd(unknown); err == nil {
		t.Error("a digest naming an image --images does not build must be refused")
	}
	tooMany := append(append([]string{}, args...), "--highlight", "two", "--highlight", "three", "--highlight", "four")
	if err := manifestCmd(tooMany); err == nil {
		t.Error("more than three highlights must be refused")
	}
}

// verify accepts a manifest signed by any of the keys given and refuses one
// signed by none of them, in both forms the signature file takes.
func TestVerifyCommand(t *testing.T) {
	dir := t.TempDir()
	zeros := strings.Repeat("0", 64)
	raw := []byte(`{"schema":2,"channel":"stable","updated":"2026-09-24T09:00:00Z","releases":[
 {"version":"0.1.0","date":"2026-09-01","bundle":{"url":"file:///b1.tar.gz","sha256":"` + zeros + `"},"images":[{"service":"nginx","ref":"r/nginx:0.1.0","digest":"sha256:aaa","size":5}]}
]}`)
	pub, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	otherPub, _, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	manifestPath := filepath.Join(dir, "manifest.json")
	if err := os.WriteFile(manifestPath, raw, 0o600); err != nil {
		t.Fatal(err)
	}
	sig := base64.StdEncoding.EncodeToString(ed25519.Sign(priv, raw))
	forms := map[string]string{
		"legacy": sig + "\n",
		"json":   fmt.Sprintf(`[{"key_id":%q,"alg":"ed25519","sig":%q}]`, manifest.KeyID(pub), sig),
	}
	good := base64.StdEncoding.EncodeToString(pub)
	other := base64.StdEncoding.EncodeToString(otherPub)
	for name, content := range forms {
		sigPath := filepath.Join(dir, name+".sig")
		if err := os.WriteFile(sigPath, []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
		if err := verify([]string{"--manifest", manifestPath, "--signature", sigPath, "--pub", other, "--pub", "main=" + good}); err != nil {
			t.Errorf("%s form, the right key among two: %v", name, err)
		}
		if err := verify([]string{"--manifest", manifestPath, "--signature", sigPath, "--pub", other}); err == nil {
			t.Errorf("%s form, a key that did not sign was accepted", name)
		}
	}
	if err := verify([]string{"--manifest", manifestPath}); err == nil {
		t.Error("missing flags were accepted")
	}
}

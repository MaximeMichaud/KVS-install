package manifest

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const zeros = "0000000000000000000000000000000000000000000000000000000000000000"

const sample = `{"schema":2,"channel":"stable","updated":"2026-09-24T09:00:00Z","releases":[
 {"version":"0.1.0","date":"2026-09-01","bundle":{"url":"file:///b1.tar.gz","sha256":"` + zeros + `"},"images":[{"service":"nginx","ref":"r/nginx:0.1.0","digest":"sha256:aaa","size":5}]},
 {"version":"0.3.0","date":"2026-09-20","bundle":{"url":"file:///b3.tar.gz","sha256":"` + zeros + `"},"images":[{"service":"php-fpm","ref":"r/php:0.3.0","digest":"sha256:abc","size":10}],"requires":{"min_from":"0.2.0"}},
 {"version":"0.2.0","date":"2026-09-10","bundle":{"url":"file:///b2.tar.gz","sha256":"` + zeros + `"},"images":[{"service":"nginx","ref":"r/nginx:0.2.0","digest":"sha256:bbb","size":5}]}
]}`

// plain is a release whose images do not vary with the installation.
const plain = `{"schema":2,"channel":"stable","updated":"2026-09-24T09:00:00Z","releases":[
 {"version":"0.1.0","date":"2026-09-01","bundle":{"url":"file:///b1.tar.gz","sha256":"` + zeros + `"},"images":[
  {"service":"nginx","ref":"r/nginx:0.1.0","digest":"sha256:aaa","size":5},
  {"service":"php-fpm","ref":"r/php:0.1.0","digest":"sha256:bbb","size":7}]}
]}`

const variants = `{"schema":2,"channel":"stable","updated":"2026-10-15T12:00:00Z","keys":[{"id":"r2","pub":"%PUB%","valid_from":"2026-11-01"}],"releases":[
 {"version":"26.10.0","date":"2026-10-15","notes":"Manticore replaces the internal search","notes_url":"https://example.test/26.10.0","highlights":["Manticore is the default search backend"],
  "bundle":{"url":"file:///b.tar.gz","sha256":"` + zeros + `"},
  "images":[{"service":"nginx","ref":"r/nginx:26.10.0","digest":"sha256:aaa","size":5}],
  "variants":{"php":{
   "8.1":[{"service":"php-fpm","ref":"r/php:26.10.0-php8.1","digest":"sha256:b81","size":9},{"service":"cron","ref":"r/cron:26.10.0-php8.1","digest":"sha256:c81","size":8}],
   "8.10":[{"service":"php-fpm","ref":"r/php:26.10.0-php8.10","digest":"sha256:b810","size":9},{"service":"cron","ref":"r/cron:26.10.0-php8.10","digest":"sha256:c810","size":8}],
   "8.2":[{"service":"php-fpm","ref":"r/php:26.10.0-php8.2","digest":"sha256:b82","size":9},{"service":"cron","ref":"r/cron:26.10.0-php8.2","digest":"sha256:c82","size":8}]},
   "mariadb":{
   "11.8":[{"service":"mariadb","ref":"mariadb:11.8.9","digest":"sha256:d118","size":7}],
   "12.3":[{"service":"mariadb","ref":"mariadb:12.3.2","digest":"sha256:d123","size":7}]}},
  "requires":{"php":"8.1","php_series":["8.1","8.2","8.10"],"compose_min":"2.24.0"},
  "commit":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "database":"migrates","one_way":true}
]}`

func TestParseSortsAndValidates(t *testing.T) {
	m, err := Parse([]byte(sample))
	if err != nil {
		t.Fatal(err)
	}
	if m.Latest().Version != "0.3.0" {
		t.Errorf("latest = %s", m.Latest().Version)
	}
	between := m.Between("0.1.0", "0.3.0")
	if len(between) != 2 || between[0].Version != "0.2.0" || between[1].Version != "0.3.0" {
		t.Errorf("Between = %+v", between)
	}
	if m.Find("0.2.0") == nil || m.Find("9.9.9") != nil {
		t.Error("Find is wrong")
	}
	bad := strings.Replace(sample, `"schema":2`, `"schema":3`, 1)
	_, err = Parse([]byte(bad))
	if err == nil || !strings.Contains(err.Error(), "update-cli") {
		t.Errorf("a newer schema must be refused with the update message, got %v", err)
	}
	bad = strings.Replace(sample, `"digest":"sha256:abc"`, `"digest":"abc"`, 1)
	if _, err := Parse([]byte(bad)); err == nil {
		t.Error("an image without a sha256 digest must be refused")
	}
	bad = strings.Replace(sample, `"service":"php-fpm",`, "", 1)
	if _, err := Parse([]byte(bad)); err == nil {
		t.Error("an image without a service must be refused")
	}
	bad = strings.Replace(sample, `"images":[{"service":"php-fpm","ref":"r/php:0.3.0","digest":"sha256:abc","size":10}]`, `"images":[]`, 1)
	if _, err := Parse([]byte(bad)); err == nil {
		t.Error("a release without an image must be refused")
	}
	bad = strings.Replace(sample, `"updated":"2026-09-24T09:00:00Z"`, `"updated":"2026-09-24"`, 1)
	if _, err := Parse([]byte(bad)); err == nil {
		t.Error("an updated time that is not RFC3339 must be refused")
	}
	bad = strings.Replace(sample, `"updated":"2026-09-24T09:00:00Z",`, "", 1)
	if _, err := Parse([]byte(bad)); err == nil {
		t.Error("a manifest without an updated time must be refused")
	}
	bad = strings.Replace(sample, `"schema":2`, `"schema":1`, 1)
	if _, err := Parse([]byte(bad)); err == nil {
		t.Error("a manifest of an older schema must be refused")
	}
	bad = strings.Replace(sample, `"images":[{"service":"nginx","ref":"r/nginx:0.2.0","digest":"sha256:bbb","size":5}]`, `"images":[{"service":"nginx","ref":"r/nginx:0.2.0","digest":"sha256:bbb","size":5},{"service":"nginx","ref":"r/nginx:0.2.1","digest":"sha256:bbc","size":5}]`, 1)
	if _, err := Parse([]byte(bad)); err == nil {
		t.Error("a release naming a service twice must be refused")
	}
}

func TestImagesForWithoutVariants(t *testing.T) {
	m, err := Parse([]byte(plain))
	if err != nil {
		t.Fatal(err)
	}
	r := m.Latest()
	if r.Version != "0.1.0" || len(r.Images) != 2 {
		t.Fatalf("release = %+v", r)
	}
	if len(r.Series()) != 0 || len(r.Values(VariantMariaDB)) != 0 {
		t.Errorf("a release without variants publishes no series, got %v and %v", r.Series(), r.Values(VariantMariaDB))
	}
	for _, values := range []map[string]string{nil, {VariantPHP: "8.1"}, {VariantPHP: "8.4", VariantMariaDB: "11.8"}} {
		images, err := r.ImagesFor(values)
		if err != nil {
			t.Fatalf("ImagesFor(%v): %v", values, err)
		}
		if len(images) != 2 {
			t.Errorf("ImagesFor(%v) = %d images, a release without variants returns its whole list", values, len(images))
		}
	}
}

func TestImagesForVariants(t *testing.T) {
	pub, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	raw := strings.Replace(variants, "%PUB%", base64.StdEncoding.EncodeToString(pub), 1)
	m, err := Parse([]byte(raw))
	if err != nil {
		t.Fatal(err)
	}
	if len(m.Keys) != 1 || m.Keys[0].ID != "r2" || m.Keys[0].ValidFrom != "2026-11-01" {
		t.Errorf("announced keys = %+v", m.Keys)
	}
	r := m.Latest()
	if !r.OneWay || r.Database != "migrates" || r.NotesURL == "" || len(r.Highlights) != 1 {
		t.Errorf("release = %+v", r)
	}
	if r.Requires.ComposeMin != "2.24.0" || len(r.Requires.PHPSeries) != 3 || r.Commit == "" {
		t.Errorf("requires = %+v, commit %q", r.Requires, r.Commit)
	}
	if got := strings.Join(r.Series(), " "); got != "8.1 8.2 8.10" {
		t.Errorf("Series = %q, they must be ordered as numbers", got)
	}
	if got := strings.Join(r.Values(VariantMariaDB), " "); got != "11.8 12.3" {
		t.Errorf("MariaDB values = %q", got)
	}
	images, err := r.ImagesFor(map[string]string{VariantPHP: "8.2", VariantMariaDB: "12.3"})
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, img := range images {
		names = append(names, img.Service+"="+img.Ref)
	}
	want := "nginx=r/nginx:26.10.0 mariadb=mariadb:12.3.2 php-fpm=r/php:26.10.0-php8.2 cron=r/cron:26.10.0-php8.2"
	if got := strings.Join(names, " "); got != want {
		t.Errorf("ImagesFor(8.2, 12.3) = %q, want %q", got, want)
	}
	if len(r.Images) != 1 {
		t.Error("ImagesFor must not append to the release's own list")
	}
	_, err = r.ImagesFor(map[string]string{VariantPHP: "8.4", VariantMariaDB: "12.3"})
	if err == nil || !strings.Contains(err.Error(), "PHP 8.4") || !strings.Contains(err.Error(), "8.1, 8.2, 8.10") {
		t.Errorf("an unpublished series must be refused naming the published ones, got %v", err)
	}
	_, err = r.ImagesFor(map[string]string{VariantPHP: "8.1", VariantMariaDB: "11.4"})
	if err == nil || !strings.Contains(err.Error(), "MariaDB 11.4") || !strings.Contains(err.Error(), "11.8, 12.3") {
		t.Errorf("an unpublished MariaDB series must be refused naming the published ones, got %v", err)
	}
	if _, err := r.ImagesFor(map[string]string{VariantMariaDB: "11.8"}); err == nil {
		t.Error("an unknown PHP series must be refused when the release has PHP variants")
	}
	unknownAxis := strings.Replace(raw, `"mariadb":{`, `"arch":{`, 1)
	unknownAxis = strings.ReplaceAll(unknownAxis, `"service":"mariadb"`, `"service":"blob"`)
	um, err := Parse([]byte(unknownAxis))
	if err != nil {
		t.Fatalf("a manifest with an axis this build does not know must still parse: %v", err)
	}
	if _, err := um.Latest().ImagesFor(map[string]string{VariantPHP: "8.1"}); err == nil || !strings.Contains(err.Error(), "update-cli") {
		t.Errorf("installing a release that varies by an unknown axis must be refused with the update message, got %v", err)
	}
	mismatch := strings.Replace(raw, `"12.3":[{"service":"mariadb"`, `"12.3":[{"service":"mariadb2"`, 1)
	if _, err := Parse([]byte(mismatch)); err == nil {
		t.Error("values of one axis naming different services must be refused")
	}
	both := strings.Replace(raw, `"images":[{"service":"nginx","ref":"r/nginx:26.10.0","digest":"sha256:aaa","size":5}]`, `"images":[{"service":"nginx","ref":"r/nginx:26.10.0","digest":"sha256:aaa","size":5},{"service":"mariadb","ref":"mariadb:11.8.9","digest":"sha256:d118","size":7}]`, 1)
	if _, err := Parse([]byte(both)); err == nil {
		t.Error("a service both in the plain list and in a variant must be refused")
	}
	badCommit := strings.Replace(raw, `"commit":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"`, `"commit":"main"`, 1)
	if _, err := Parse([]byte(badCommit)); err == nil {
		t.Error("a commit that is not a git commit id must be refused")
	}
	bad := strings.Replace(raw, `"8.2":[{"service":"php-fpm","ref":"r/php:26.10.0-php8.2","digest":"sha256:b82","size":9},{"service":"cron","ref":"r/cron:26.10.0-php8.2","digest":"sha256:c82","size":8}]`, `"8.2":[]`, 1)
	if _, err := Parse([]byte(bad)); err == nil {
		t.Error("a series without an image must be refused")
	}
	bad = strings.Replace(raw, `"8.2":`, `"":`, 1)
	if _, err := Parse([]byte(bad)); err == nil {
		t.Error("a variant value without a name must be refused")
	}
}

func TestFetchAndVerify(t *testing.T) {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	path := filepath.Join(dir, "manifest.json")
	if err := os.WriteFile(path, []byte(sample), 0o644); err != nil {
		t.Fatal(err)
	}
	sig := ed25519.Sign(priv, []byte(sample))
	if err := os.WriteFile(path+".sig", []byte(base64.StdEncoding.EncodeToString(sig)+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := Fetch("file://" + path); err == nil {
		t.Fatal("a bare base64 signature file must be refused: only the JSON form is published")
	}
	file, err := json.Marshal([]Signature{{KeyID: KeyID(pub), Alg: AlgEd25519, Sig: base64.StdEncoding.EncodeToString(sig)}})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path+".sig", file, 0o644); err != nil {
		t.Fatal(err)
	}
	doc, err := Fetch("file://" + path)
	if err != nil {
		t.Fatal(err)
	}
	if err := doc.Verify(pub); err != nil {
		t.Fatal(err)
	}
	other, _, _ := ed25519.GenerateKey(rand.Reader)
	if err := doc.Verify(other); err == nil {
		t.Error("another key must not verify the manifest")
	}
	if err := doc.VerifyAny([]ed25519.PublicKey{other, pub}); err != nil {
		t.Errorf("a signature must be tried against every key: %v", err)
	}
	if err := doc.VerifyAny(nil); err == nil {
		t.Error("verifying without a key must fail")
	}
	if err := os.WriteFile(path, []byte(strings.Replace(sample, "stable", "edited", 1)), 0o644); err != nil {
		t.Fatal(err)
	}
	doc, err = Fetch("file://" + path)
	if err != nil {
		t.Fatal(err)
	}
	if err := doc.Verify(pub); err == nil {
		t.Error("an edited manifest must not verify")
	}
}

// A manifest over the size kvsctl reads is refused as such, from a file or
// a server alike, rather than cut and then refused as a bad signature.
func TestReadRefusesALargerFile(t *testing.T) {
	exact := bytes.Repeat([]byte("x"), maxFile)
	larger := append(bytes.Clone(exact), 'x')
	dir := t.TempDir()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/larger" {
			_, _ = w.Write(larger)
			return
		}
		_, _ = w.Write(exact)
	}))
	defer srv.Close()
	for name, data := range map[string][]byte{"exact": exact, "larger": larger} {
		if err := os.WriteFile(filepath.Join(dir, name), data, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	for _, url := range []string{"file://" + filepath.Join(dir, "exact"), srv.URL + "/exact"} {
		if data, err := read(context.Background(), url); err != nil || len(data) != maxFile {
			t.Errorf("%s: %d bytes, %v", url, len(data), err)
		}
	}
	for _, url := range []string{"file://" + filepath.Join(dir, "larger"), srv.URL + "/larger"} {
		if _, err := read(context.Background(), url); err == nil || !strings.Contains(err.Error(), "larger than 8 MiB") {
			t.Errorf("%s: %v", url, err)
		}
	}
	if _, err := Fetch("file://" + filepath.Join(dir, "larger")); err == nil || !strings.HasPrefix(err.Error(), "manifest: ") || !strings.Contains(err.Error(), "larger than 8 MiB") {
		t.Errorf("Fetch: %v", err)
	}
}

func TestVerifyJSONSignatures(t *testing.T) {
	oldPub, oldPriv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	newPub, newPriv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	path := filepath.Join(dir, "manifest.json")
	if err := os.WriteFile(path, []byte(sample), 0o644); err != nil {
		t.Fatal(err)
	}
	file, err := json.Marshal([]Signature{
		{KeyID: KeyID(oldPub), Alg: AlgEd25519, Sig: base64.StdEncoding.EncodeToString(ed25519.Sign(oldPriv, []byte(sample)))},
		{KeyID: KeyID(newPub), Alg: AlgEd25519, Sig: base64.StdEncoding.EncodeToString(ed25519.Sign(newPriv, []byte(sample)))},
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path+".sig", append(file, '\n'), 0o644); err != nil {
		t.Fatal(err)
	}
	doc, err := Fetch("file://" + path)
	if err != nil {
		t.Fatal(err)
	}
	if len(doc.Signatures) != 2 {
		t.Fatal("the JSON file must be read as a list of signatures")
	}
	for name, key := range map[string]ed25519.PublicKey{"the outgoing key": oldPub, "the incoming key": newPub} {
		if err := doc.VerifyAny([]ed25519.PublicKey{key}); err != nil {
			t.Errorf("%s must verify a release signed by both: %v", name, err)
		}
	}
	if doc.Manifest == nil || doc.Manifest.Latest().Version != "0.3.0" {
		t.Error("a verified document must carry the parsed manifest")
	}
	stranger, _, _ := ed25519.GenerateKey(rand.Reader)
	err = doc.VerifyAny([]ed25519.PublicKey{stranger})
	if err == nil {
		t.Fatal("an unknown key must not verify")
	}
	if !strings.Contains(err.Error(), KeyID(oldPub)) || !strings.Contains(err.Error(), KeyID(newPub)) {
		t.Errorf("the failure must name the key ids it tried, got %q", err)
	}
	// One signature alone, written as a JSON object rather than a list.
	one, err := json.Marshal(Signature{KeyID: KeyID(newPub), Alg: AlgEd25519, Sig: base64.StdEncoding.EncodeToString(ed25519.Sign(newPriv, []byte(sample)))})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path+".sig", one, 0o644); err != nil {
		t.Fatal(err)
	}
	doc, err = Fetch("file://" + path)
	if err != nil {
		t.Fatal(err)
	}
	if err := doc.VerifyAny([]ed25519.PublicKey{newPub}); err != nil {
		t.Errorf("a single JSON signature must verify: %v", err)
	}
	if err := os.WriteFile(path+".sig", []byte(`[{"key_id":"r1","alg":"ml-dsa","sig":"nope"}]`), 0o644); err != nil {
		t.Fatal(err)
	}
	doc, err = Fetch("file://" + path)
	if err != nil {
		t.Fatal(err)
	}
	err = doc.VerifyAny([]ed25519.PublicKey{newPub})
	if err == nil || !strings.Contains(err.Error(), "r1") {
		t.Errorf("an unreadable signature must fail naming the key id, got %v", err)
	}
}

func TestParseKeysAndKeyID(t *testing.T) {
	pub, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	encoded := base64.StdEncoding.EncodeToString(pub)
	keys, err := ParseKeys([]string{encoded, "r2=" + encoded, "  "})
	if err != nil {
		t.Fatal(err)
	}
	if len(keys) != 2 {
		t.Fatalf("ParseKeys returned %d keys", len(keys))
	}
	for i, k := range keys {
		if !k.Equal(pub) {
			t.Errorf("key %d does not decode to the public key", i)
		}
	}
	if _, err := ParseKeys([]string{"not base64!"}); err == nil {
		t.Error("a key that is not base64 must be refused")
	}
	if _, err := ParseKeys([]string{base64.StdEncoding.EncodeToString([]byte("short"))}); err == nil {
		t.Error("a key of the wrong length must be refused")
	}
	if _, err := ParseKeys(nil); err == nil {
		t.Error("an empty key set must be refused")
	}
	id := KeyID(pub)
	if len(id) != 8 || id != KeyID(pub) {
		t.Errorf("KeyID = %q, it must be eight stable hex characters", id)
	}
}

// Between stops at the target: an upgrade to an older release than the
// newest must not take the requirements of the releases above it.
func TestBetweenStopsAtTheTarget(t *testing.T) {
	m, err := Parse([]byte(sample))
	if err != nil {
		t.Fatal(err)
	}
	if got := m.Between("0.1.0", "0.2.0"); len(got) != 1 || got[0].Version != "0.2.0" {
		t.Errorf("Between(0.1.0, 0.2.0) = %+v, want 0.2.0 alone", got)
	}
	if got := m.Between("0.2.0", "0.2.0"); len(got) != 0 {
		t.Errorf("Between(0.2.0, 0.2.0) = %+v, want nothing", got)
	}
}

// Every check of a manifest refuses with its own message, so no check
// passes a test for another one.
func TestParseRefusesWithItsReason(t *testing.T) {
	pub, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	withVariants := strings.Replace(variants, "%PUB%", base64.StdEncoding.EncodeToString(pub), 1)
	for _, c := range []struct {
		name, from, old, new, want string
	}{
		{"bundle sha256", sample, `"url":"file:///b1.tar.gz","sha256":"` + zeros + `"`, `"url":"file:///b1.tar.gz","sha256":"abc"`, "release 0.1.0 has no bundle with a sha256"},
		{"bundle url", sample, `"url":"file:///b1.tar.gz",`, `"url":"",`, "release 0.1.0 has no bundle with a sha256"},
		{"version", sample, `"version":"0.2.0"`, `"version":"0.2"`, `version "0.2" is not MAJOR.MINOR.PATCH`},
		{"twice", sample, `"version":"0.2.0"`, `"version":"0.1.0"`, "release 0.1.0 is listed twice"},
		{"no release", plain, plain[strings.Index(plain, `"releases":[`):], `"releases":[]}`, "manifest lists no release"},
		{"no reference", sample, `"ref":"r/nginx:0.1.0"`, `"ref":""`, "release 0.1.0: the image of nginx has no reference"},
		{"no updated time", sample, `"updated":"2026-09-24T09:00:00Z",`, "", "manifest carries no updated time"},
		{"axis without a name", withVariants, `"mariadb":{`, `"":{`, "release 26.10.0 has a variant without a name"},
		{"value twice", withVariants, `"11.8":[{"service":"mariadb","ref":"mariadb:11.8.9","digest":"sha256:d118","size":7}]`, `"11.8":[{"service":"mariadb","ref":"mariadb:11.8.9","digest":"sha256:d118","size":7},{"service":"mariadb","ref":"mariadb:11.8.8","digest":"sha256:d117","size":7}]`, "release 26.10.0: variant mariadb 11.8 names mariadb twice"},
		{"key without an id", withVariants, `"id":"r2"`, `"id":""`, "manifest announces a key without an id or without its public half"},
		{"key that is no key", withVariants, `"pub":"` + base64.StdEncoding.EncodeToString(pub) + `"`, `"pub":"bm90IGEga2V5"`, "manifest key r2: release key"},
		{"kvsctl_min", sample, `"requires":{"min_from":"0.2.0"}`, `"requires":{"min_from":"0.2.0","kvsctl_min":"soon"}`, `release 0.3.0: kvsctl_min: version "soon" is not MAJOR.MINOR.PATCH`},
	} {
		bad := strings.Replace(c.from, c.old, c.new, 1)
		if bad == c.from {
			t.Fatalf("%s: the case changes nothing", c.name)
		}
		if _, err := Parse([]byte(bad)); err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: %v, want %q", c.name, err, c.want)
		}
	}
	m, err := Parse([]byte(strings.Replace(sample, `"requires":{"min_from":"0.2.0"}`, `"requires":{"min_from":"0.2.0","kvsctl_min":"26.11.0"}`, 1)))
	if err != nil || m.Find("0.3.0").Requires.KvsctlMin != "26.11.0" {
		t.Errorf("kvsctl_min is not read: %v", err)
	}
}

// The signature file is refused as such when it says nothing.
func TestLoadRefusesAnEmptySignature(t *testing.T) {
	for _, c := range []struct{ sig, want string }{
		{"", "manifest signature is empty"},
		{" \n", "manifest signature is empty"},
		{"[]", "manifest signature lists no signature"},
		{"c2ln", "manifest signature is not a JSON signature file"},
	} {
		if _, err := Load([]byte(sample), []byte(c.sig)); err == nil || err.Error() != c.want {
			t.Errorf("signature %q: %v, want %q", c.sig, err, c.want)
		}
	}
}

// A signature that names another algorithm is never checked as an ed25519
// one, even when its bytes would pass.
func TestVerifyRefusesAnotherAlgorithm(t *testing.T) {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	sig, err := json.Marshal([]Signature{{KeyID: KeyID(pub), Alg: "ml-dsa", Sig: base64.StdEncoding.EncodeToString(ed25519.Sign(priv, []byte(sample)))}})
	if err != nil {
		t.Fatal(err)
	}
	doc, err := Load([]byte(sample), sig)
	if err != nil {
		t.Fatal(err)
	}
	if err := doc.VerifyAny([]ed25519.PublicKey{pub}); err == nil || !strings.Contains(err.Error(), "1 of the signatures are not a readable ed25519 signature") {
		t.Errorf("a signature of another algorithm: %v", err)
	}
}

// A server that answers anything but 200 is named with its answer.
func TestReadNamesTheAnswerOfTheServer(t *testing.T) {
	srv := httptest.NewServer(http.NotFoundHandler())
	defer srv.Close()
	if _, err := read(context.Background(), srv.URL+"/manifest.json"); err == nil || !strings.Contains(err.Error(), "answered 404 Not Found") {
		t.Errorf("a 404: %v", err)
	}
}

// A manifest read is left as soon as its context ends, which is how a
// Ctrl-C stops a server that does not answer.
func TestFetchContextEndsWithItsContext(t *testing.T) {
	asked := make(chan struct{}, 1)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case asked <- struct{}{}:
		default:
		}
		<-r.Context().Done()
	}))
	defer srv.Close()
	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		<-asked
		cancel()
	}()
	start := time.Now()
	_, err := FetchContext(ctx, srv.URL+"/manifest.json")
	if !errors.Is(err, context.Canceled) {
		t.Errorf("a cancelled read: %v", err)
	}
	if took := time.Since(start); took > 10*time.Second {
		t.Errorf("the read took %s after its context ended", took)
	}
}

// A list is the one of a release candidate by its channel, or, signed
// before candidates named their channel, by its newest release.
func TestCandidate(t *testing.T) {
	for _, c := range []struct {
		channel  string
		releases []Release
		want     bool
	}{
		{ChannelStable, []Release{{Version: "26.10.1"}, {Version: "26.10.0-rc1"}}, false},
		{ChannelStable, []Release{{Version: "26.11.0-rc1"}, {Version: "26.10.1"}}, true},
		{ChannelCandidate, []Release{{Version: "26.10.1"}}, true},
		{ChannelCandidate, nil, true},
		{ChannelStable, nil, false},
	} {
		if got := (&Manifest{Channel: c.channel, Releases: c.releases}).Candidate(); got != c.want {
			t.Errorf("channel %s, releases %v: candidate %v, want %v", c.channel, c.releases, got, c.want)
		}
	}
	if err := (&Manifest{Channel: ChannelCandidate}).CheckChannel(DefaultURL); err == nil || !strings.Contains(err.Error(), "is the one of a release candidate (channel candidate)") {
		t.Errorf("a candidate list without a release at the default URL: %v", err)
	}
}

// LessSeries orders a series before its own longer form, and text it cannot
// read as numbers as text.
func TestLessSeries(t *testing.T) {
	for _, c := range []struct {
		a, b string
		less bool
	}{
		{"8.2", "8.10", true},
		{"8.10", "8.2", false},
		{"8", "8.1", true},
		{"8.1", "8", false},
		{"8.1", "8.1", false},
		{"a", "b", true},
		{"b", "a", false},
		{"x.1", "x.2", true},
		{"x.2", "x.1", false},
	} {
		if got := LessSeries(c.a, c.b); got != c.less {
			t.Errorf("LessSeries(%q, %q) = %v", c.a, c.b, got)
		}
	}
}

// update-cli reads the frozen part of a manifest whatever its schema: a
// later format that changes everything else still names the kvsctl builds,
// which is how a binary already out finds the one that reads it.
func TestParseCLIReadsALaterFormat(t *testing.T) {
	later := `{"schema":3,"channel":"stable","updated":"2027-03-01T08:00:00Z","signing":{"scheme":"something new"},
 "keys":[{"id":"r3","valid_from":"2027-04-01","pub":{"ed25519":"moved"}}],
 "releases":[
  {"version":"27.3.0","cli":{"linux-amd64":{"url":"https://example.com/27.3.0/kvsctl-linux-amd64","sha256":"` + zeros + `","size":"big"}},"bundle":"elsewhere","images":"a string now","requires":["php 8.4"]},
  {"version":"27.4.0-rc1","cli":{"linux-amd64":{"url":"https://example.com/27.4.0-rc1/kvsctl-linux-amd64","sha256":"` + zeros + `"}}},
  {"version":"27.2.0"}
 ]}`
	if _, err := Parse([]byte(later)); err == nil || !strings.Contains(err.Error(), "this manifest needs a newer kvsctl (schema 3, this build reads 2): run 'kvsctl update-cli'") {
		t.Fatalf("check and upgrade must send a later schema to update-cli, whatever shape its other fields take: %v", err)
	}
	m, err := ParseCLI([]byte(later))
	if err != nil {
		t.Fatal(err)
	}
	if m.Channel != ChannelStable || m.Updated != "2027-03-01T08:00:00Z" || len(m.Keys) != 1 || m.Keys[0].ID != "r3" || m.Keys[0].ValidFrom != "2027-04-01" {
		t.Errorf("channel %q, updated %q, keys %+v", m.Channel, m.Updated, m.Keys)
	}
	var versions []string
	for _, r := range m.Releases {
		versions = append(versions, r.Version)
	}
	if got := strings.Join(versions, " "); got != "27.4.0-rc1 27.3.0 27.2.0" {
		t.Errorf("releases %s, want them newest first", got)
	}
	if got := m.Find("27.3.0").CLI["linux-amd64"]; got.URL != "https://example.com/27.3.0/kvsctl-linux-amd64" || got.SHA256 != zeros || got.Size != 0 {
		t.Errorf("the build of 27.3.0, whose size is not a number: %+v", got)
	}
	if m.LatestStable().Version != "27.3.0" {
		t.Errorf("latest stable %s", m.LatestStable().Version)
	}
	// A size given as a number of bytes bounds the download of the build.
	sized, err := ParseCLI([]byte(strings.Replace(later, `"size":"big"`, `"size":19876543`, 1)))
	if err != nil {
		t.Fatal(err)
	}
	if got := sized.Find("27.3.0").CLI["linux-amd64"].Size; got != 19876543 {
		t.Errorf("the size of the build of 27.3.0: %d", got)
	}
	for _, c := range []struct{ old, new, want string }{
		{`"updated":"2027-03-01T08:00:00Z"`, `"updated":"2027-03-01"`, `manifest was updated "2027-03-01", which is not an RFC3339 time`},
		{`"version":"27.2.0"`, `"version":"27.3.0"`, "release 27.3.0 is listed twice"},
		{`"version":"27.2.0"`, `"version":"27.2"`, `version "27.2" is not MAJOR.MINOR.PATCH`},
		{later[strings.Index(later, `"releases":[`):], `"releases":[]}`, "manifest lists no release"},
		{`"cli":{"linux-amd64":{"url":"https://example.com/27.3.0/kvsctl-linux-amd64"`, `"cli":{"linux-amd64":{"url":3`, "manifest is not valid JSON"},
	} {
		if _, err := ParseCLI([]byte(strings.Replace(later, c.old, c.new, 1))); err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: %v, want %q", c.new, err, c.want)
		}
	}
}

// A release writes again every release before it through Release, so the
// order of its fields is part of the bytes signed: requires comes last, as
// kvsctl-release has written it since kvsctl_min exists.
func TestReleaseKeepsTheOrderOfItsFields(t *testing.T) {
	image := Image{Service: "nginx", Ref: "r/nginx:26.10.0", Digest: "sha256:aaa", Size: 5}
	raw, err := json.Marshal(Release{
		Version: "26.10.0", Date: "2026-10-15", Commit: strings.Repeat("a", 40),
		Notes: "notes", NotesURL: "https://example.test/26.10.0", Highlights: []string{"one line"},
		Bundle:   Asset{URL: "file:///b.tar.gz", SHA256: zeros, Size: 1},
		Images:   []Image{image},
		Variants: map[string]map[string][]Image{VariantPHP: {"8.1": {image}}},
		Database: "migrates", OneWay: true,
		CLI:      map[string]Asset{"linux-amd64": {URL: "file:///kvsctl", SHA256: zeros, Size: 1}},
		Requires: Requires{MinFrom: "26.9.0", KvsctlMin: "26.10.0"},
	})
	if err != nil {
		t.Fatal(err)
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	if _, err := dec.Token(); err != nil {
		t.Fatal(err)
	}
	var keys []string
	for dec.More() {
		key, err := dec.Token()
		if err != nil {
			t.Fatal(err)
		}
		keys = append(keys, key.(string))
		var value json.RawMessage
		if err := dec.Decode(&value); err != nil {
			t.Fatal(err)
		}
	}
	want := "version date commit notes notes_url highlights bundle images variants database one_way cli requires"
	if got := strings.Join(keys, " "); got != want {
		t.Errorf("a release writes its fields as %s, and the manifests signed so far have %s", got, want)
	}
}

// VerifyCLI checks the signature before it reads anything.
func TestVerifyCLIChecksTheSignature(t *testing.T) {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	later := strings.Replace(sample, `"schema":2`, `"schema":3`, 1)
	sig, err := json.Marshal([]Signature{{KeyID: KeyID(pub), Alg: AlgEd25519, Sig: base64.StdEncoding.EncodeToString(ed25519.Sign(priv, []byte(later)))}})
	if err != nil {
		t.Fatal(err)
	}
	doc, err := Load([]byte(later), sig)
	if err != nil {
		t.Fatal(err)
	}
	if m, err := doc.VerifyCLI([]ed25519.PublicKey{pub}); err != nil || m.Latest().Version != "0.3.0" {
		t.Fatalf("a later schema signed by a known key: %v", err)
	}
	other, _, _ := ed25519.GenerateKey(rand.Reader)
	if _, err := doc.VerifyCLI([]ed25519.PublicKey{other}); err == nil || !strings.Contains(err.Error(), "does not match any release key") {
		t.Errorf("another key: %v", err)
	}
	if _, err := doc.VerifyCLI(nil); err == nil {
		t.Error("no key must verify nothing")
	}
}

// The default URL serves the stable channel alone; a URL the operator
// names may serve a candidate; a channel this build does not know is
// refused anywhere.
func TestCheckChannel(t *testing.T) {
	other := "https://example.com/candidate/manifest.json"
	stable := []Release{{Version: "26.10.1"}, {Version: "26.10.0-rc1"}, {Version: "26.9.0"}}
	candidate := []Release{{Version: "26.11.0-rc1"}, {Version: "26.10.1"}}
	for _, c := range []struct {
		channel, url string
		releases     []Release
		want         string
	}{
		{ChannelStable, DefaultURL, stable, ""},
		{ChannelStable, other, stable, ""},
		{ChannelCandidate, other, candidate, ""},
		{ChannelStable, other, candidate, ""},
		{ChannelCandidate, DefaultURL, candidate, "is the one of a release candidate (channel candidate), and that URL serves stable releases only: a candidate was published as the latest release by mistake"},
		{ChannelStable, DefaultURL, candidate, "names the release candidate 26.11.0-rc1 as its newest release, and that URL serves stable releases only"},
		{"beta", other, stable, `is of channel "beta", which this kvsctl does not read`},
		{"", DefaultURL, stable, `is of channel "", which this kvsctl does not read`},
	} {
		err := (&Manifest{Channel: c.channel, Releases: c.releases}).CheckChannel(c.url)
		if c.want == "" && err != nil || c.want != "" && (err == nil || !strings.Contains(err.Error(), c.want)) {
			t.Errorf("channel %q at %s, newest %s: %v, want %q", c.channel, c.url, c.releases[0].Version, err, c.want)
		}
	}
}

// A release candidate is the latest release, never the latest stable one.
func TestLatestStable(t *testing.T) {
	m := &Manifest{Releases: []Release{{Version: "26.11.0-rc2"}, {Version: "26.11.0-rc1"}, {Version: "26.10.1"}, {Version: "26.10.0"}}}
	if m.Latest().Version != "26.11.0-rc2" || m.LatestStable().Version != "26.10.1" {
		t.Errorf("latest %s, latest stable %s", m.Latest().Version, m.LatestStable().Version)
	}
	m.Releases = m.Releases[:2]
	if got := m.LatestStable(); got != nil {
		t.Errorf("candidates only: latest stable %s", got.Version)
	}
}

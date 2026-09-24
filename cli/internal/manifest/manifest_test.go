package manifest

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const zeros = "0000000000000000000000000000000000000000000000000000000000000000"

const sample = `{"schema":2,"channel":"stable","updated":"2026-09-24T09:00:00Z","releases":[
 {"version":"0.1.0","date":"2026-09-01","bundle":{"url":"file:///b1.tar.gz","sha256":"` + zeros + `"},"images":[{"service":"nginx","ref":"r/nginx:0.1.0","digest":"sha256:aaa","size":5}]},
 {"version":"0.3.0","date":"2026-09-20","bundle":{"url":"file:///b3.tar.gz","sha256":"` + zeros + `"},"images":[{"service":"php-fpm","ref":"r/php:0.3.0","digest":"sha256:abc","size":10}],"requires":{"min_from":"0.2.0"}},
 {"version":"0.2.0","date":"2026-09-10","bundle":{"url":"file:///b2.tar.gz","sha256":"` + zeros + `"},"images":[{"service":"nginx","ref":"r/nginx:0.2.0","digest":"sha256:bbb","size":5}]}
]}`

// schema1 is a manifest written before variants and before the updated time
// became mandatory: it must still read.
const schema1 = `{"schema":1,"channel":"stable","releases":[
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
   "8.2":[{"service":"php-fpm","ref":"r/php:26.10.0-php8.2","digest":"sha256:b82","size":9},{"service":"cron","ref":"r/cron:26.10.0-php8.2","digest":"sha256:c82","size":8}]}},
  "requires":{"php":"8.1","php_series":["8.1","8.2","8.10"],"mariadb_from":["11.4","11.8"],"compose_min":"2.24.0"},
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
		t.Error("a schema 2 manifest without an updated time must be refused")
	}
}

func TestParseSchema1(t *testing.T) {
	m, err := Parse([]byte(schema1))
	if err != nil {
		t.Fatal(err)
	}
	r := m.Latest()
	if r.Version != "0.1.0" || len(r.Images) != 2 {
		t.Fatalf("release = %+v", r)
	}
	if len(r.Series()) != 0 {
		t.Errorf("a release without variants publishes no series, got %v", r.Series())
	}
	for _, series := range []string{"", "8.1", "8.4"} {
		images, err := r.ImagesFor(series)
		if err != nil {
			t.Fatalf("ImagesFor(%q): %v", series, err)
		}
		if len(images) != 2 {
			t.Errorf("ImagesFor(%q) = %d images, a release without variants returns its whole list", series, len(images))
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
	if r.Requires.ComposeMin != "2.24.0" || len(r.Requires.MariaDBFrom) != 2 || len(r.Requires.PHPSeries) != 3 {
		t.Errorf("requires = %+v", r.Requires)
	}
	if got := strings.Join(r.Series(), " "); got != "8.1 8.2 8.10" {
		t.Errorf("Series = %q, they must be ordered as numbers", got)
	}
	images, err := r.ImagesFor("8.2")
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, img := range images {
		names = append(names, img.Service+"="+img.Ref)
	}
	want := "nginx=r/nginx:26.10.0 php-fpm=r/php:26.10.0-php8.2 cron=r/cron:26.10.0-php8.2"
	if got := strings.Join(names, " "); got != want {
		t.Errorf("ImagesFor(8.2) = %q, want %q", got, want)
	}
	if len(r.Images) != 1 {
		t.Error("ImagesFor must not append to the release's own list")
	}
	_, err = r.ImagesFor("8.4")
	if err == nil || !strings.Contains(err.Error(), "8.1, 8.2, 8.10") {
		t.Errorf("an unpublished series must be refused naming the published ones, got %v", err)
	}
	if _, err := r.ImagesFor(""); err == nil {
		t.Error("an unknown series must be refused when the release has variants")
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

func TestFetchAndVerifyLegacySignature(t *testing.T) {
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
	doc, err := Fetch("file://" + path)
	if err != nil {
		t.Fatal(err)
	}
	if len(doc.Signature) != ed25519.SignatureSize || len(doc.Signatures) != 0 {
		t.Fatal("the legacy file must be read as one bare signature")
	}
	if err := doc.Verify(pub); err != nil {
		t.Fatal(err)
	}
	other, _, _ := ed25519.GenerateKey(rand.Reader)
	if err := doc.Verify(other); err == nil {
		t.Error("another key must not verify the manifest")
	}
	if err := doc.VerifyAny([]ed25519.PublicKey{other, pub}); err != nil {
		t.Errorf("a bare signature must be tried against every key: %v", err)
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
	if len(doc.Signatures) != 2 || len(doc.Signature) != 0 {
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

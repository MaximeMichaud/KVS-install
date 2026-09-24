// Package manifest reads and verifies the signed list of stack releases.
package manifest

import (
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/MaximeMichaud/KVS-install/cli/internal/semver"
)

// Schema is the newest manifest format this build understands. Parse reads
// every schema from 1 to this one: adding a field never bumps the number,
// only a change an older binary would read wrongly does.
const Schema = 2

// VariantPHP is the variant axis of the PHP series. The images that depend
// on the PHP the site was encoded for live under Release.Variants[VariantPHP],
// keyed by series ("8.1"), and the rest in Release.Images.
const VariantPHP = "php"

// AlgEd25519 is the only signature algorithm kvsctl verifies.
const AlgEd25519 = "ed25519"

// Image is one container image a release runs with.
type Image struct {
	// Service is the compose service the image belongs to.
	Service string `json:"service"`
	// Ref is the image name and tag as the compose override names it.
	Ref string `json:"ref"`
	// Digest is the sha256 the pulled image must carry.
	Digest string `json:"digest"`
	// Size is the compressed download size in bytes, for the progress bars.
	Size int64 `json:"size"`
	// Layers lists the image's layers so kvsctl counts only the ones the
	// machine lacks; an empty list means the whole Size may be downloaded.
	Layers []Layer `json:"layers,omitempty"`
}

// Layer is one layer of an image: its compressed digest and size in the
// registry, and the diff ID (uncompressed digest) the engine keeps locally.
type Layer struct {
	Digest string `json:"digest"`
	DiffID string `json:"diff_id"`
	Size   int64  `json:"size"`
}

// Asset is a downloadable file with its checksum.
type Asset struct {
	URL    string `json:"url"`
	SHA256 string `json:"sha256"`
	Size   int64  `json:"size,omitempty"`
}

// Key is a release signing key the manifest announces. It is information
// only: a manifest cannot introduce the key that signs it, so a binary
// trusts the keys it embeds and this list only tells the operator that a
// new key is coming and that update-cli brings the binary that knows it.
type Key struct {
	ID        string `json:"id"`
	Pub       string `json:"pub"`
	ValidFrom string `json:"valid_from,omitempty"`
}

// Requires lists what an instance needs before taking a release.
type Requires struct {
	// MinFrom is the oldest installed version that may upgrade directly.
	MinFrom string `json:"min_from,omitempty"`
	// PHP is the default PHP series of the release, the one a reader that
	// knows nothing of variants would report.
	PHP string `json:"php,omitempty"`
	// PHPSeries lists every PHP series the release publishes images for.
	PHPSeries []string `json:"php_series,omitempty"`
	// KVSMin is the oldest KVS version the release supports.
	KVSMin string `json:"kvs_min,omitempty"`
	// MariaDBFrom lists the on-disk MariaDB majors the release's image
	// accepts, since the server upgrades a datadir one major at a time and
	// never back.
	MariaDBFrom []string `json:"mariadb_from,omitempty"`
	// ComposeMin is the oldest Docker Compose that reads the release
	// override; "build: !reset null" needs 2.24.0.
	ComposeMin string `json:"compose_min,omitempty"`
}

// Release is one version of the stack.
type Release struct {
	Version string `json:"version"`
	Date    string `json:"date"`
	// Notes is one line, shown beside the version.
	Notes string `json:"notes,omitempty"`
	// NotesURL points at the full changelog, which never travels in the
	// manifest: the manifest is fetched on every status check.
	NotesURL string `json:"notes_url,omitempty"`
	// Highlights are at most three short lines for the confirmation screen.
	Highlights []string `json:"highlights,omitempty"`
	Bundle     Asset    `json:"bundle"`
	// Images are the images that do not vary with the instance.
	Images []Image `json:"images"`
	// Variants holds the images that do vary, by axis and then by value:
	// Variants["php"]["8.1"] is what an instance running PHP 8.1 pulls.
	Variants map[string]map[string][]Image `json:"variants,omitempty"`
	Requires Requires                      `json:"requires"`
	// Database is "migrates" when the release changes the schema, which
	// makes a rollback restore the backup.
	Database string `json:"database,omitempty"`
	// OneWay marks a release that cannot be undone by restarting the
	// previous images, a MariaDB major being the case: the rollback has to
	// recreate the volume and replay the dump. It is independent of
	// Database, which says whether the data itself changed.
	OneWay bool             `json:"one_way,omitempty"`
	CLI    map[string]Asset `json:"cli,omitempty"`
}

// Manifest is the signed document.
type Manifest struct {
	Schema  int    `json:"schema"`
	Channel string `json:"channel"`
	// Updated is when the list was written, RFC3339. It is what tells a
	// replayed old copy from a fresh one, so it is required from schema 2.
	Updated  string    `json:"updated"`
	Keys     []Key     `json:"keys,omitempty"`
	Releases []Release `json:"releases"`
}

// Signature is one entry of the signature file: which key signed, with
// which algorithm, and the signature itself in base64.
type Signature struct {
	KeyID string `json:"key_id"`
	Alg   string `json:"alg"`
	Sig   string `json:"sig"`
}

// Document is a fetched manifest with the bytes its signature covers.
type Document struct {
	Raw []byte
	// Signature is the signature of the legacy file, one bare base64 line
	// with no key id. It stays empty when the file is the JSON list.
	Signature []byte
	// Signatures is the JSON list of signatures, one entry per signing key,
	// which is what lets a rotation release carry the old key and the new
	// one at once. It stays empty when the file is the legacy form.
	Signatures []Signature
	Manifest   *Manifest
}

// Fetch reads the manifest at url and its detached signature at url+".sig".
// http(s) and file URLs are accepted.
func Fetch(url string) (*Document, error) {
	raw, err := read(url)
	if err != nil {
		return nil, fmt.Errorf("manifest: %w", err)
	}
	sig, err := read(url + ".sig")
	if err != nil {
		return nil, fmt.Errorf("manifest signature: %w", err)
	}
	return Load(raw, sig)
}

// Load builds the document from the manifest bytes and the signature file,
// for a caller that already holds both.
func Load(raw, sig []byte) (*Document, error) {
	doc := &Document{Raw: raw}
	if err := doc.readSignature(sig); err != nil {
		return nil, err
	}
	return doc, nil
}

// readSignature accepts both forms of manifest.json.sig: the JSON list of
// signatures, and the legacy file holding one bare base64 signature.
func (d *Document) readSignature(file []byte) error {
	trimmed := bytes.TrimSpace(file)
	if len(trimmed) == 0 {
		return errors.New("manifest signature is empty")
	}
	switch trimmed[0] {
	case '[':
		var sigs []Signature
		if err := json.Unmarshal(trimmed, &sigs); err != nil {
			return fmt.Errorf("manifest signature is not a list of signatures: %w", err)
		}
		if len(sigs) == 0 {
			return errors.New("manifest signature lists no signature")
		}
		d.Signatures = sigs
	case '{':
		var one Signature
		if err := json.Unmarshal(trimmed, &one); err != nil {
			return fmt.Errorf("manifest signature is not a signature: %w", err)
		}
		d.Signatures = []Signature{one}
	default:
		decoded, err := base64.StdEncoding.DecodeString(string(trimmed))
		if err != nil {
			return fmt.Errorf("manifest signature is not base64: %w", err)
		}
		d.Signature = decoded
	}
	return nil
}

// Verify checks the signature against the key and parses the manifest.
func (d *Document) Verify(pub ed25519.PublicKey) error {
	return d.VerifyAny([]ed25519.PublicKey{pub})
}

// VerifyAny checks the signature file against every key this build trusts
// and parses the manifest as soon as one of them matches. A key rotation is
// then a release signed by the outgoing key and the incoming one at once:
// binaries that know either of them accept it, and the ones that know
// neither say which key ids signed instead of failing silently.
func (d *Document) VerifyAny(keys []ed25519.PublicKey) error {
	if len(keys) == 0 {
		return errors.New("no release key to check the manifest signature with")
	}
	if err := d.verifySignature(keys); err != nil {
		return err
	}
	m, err := Parse(d.Raw)
	if err != nil {
		return err
	}
	d.Manifest = m
	return nil
}

func (d *Document) verifySignature(keys []ed25519.PublicKey) error {
	if len(d.Signatures) == 0 {
		if len(d.Signature) == ed25519.SignatureSize {
			for _, pub := range keys {
				if ed25519.Verify(pub, d.Raw, d.Signature) {
					return nil
				}
			}
		}
		return errors.New("manifest signature does not match the release key")
	}
	ids := make([]string, 0, len(d.Signatures))
	unreadable := 0
	for _, s := range d.Signatures {
		id := s.KeyID
		if id == "" {
			id = "(no key id)"
		}
		ids = append(ids, id)
		if s.Alg != "" && s.Alg != AlgEd25519 {
			unreadable++
			continue
		}
		raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(s.Sig))
		if err != nil || len(raw) != ed25519.SignatureSize {
			unreadable++
			continue
		}
		for _, pub := range keys {
			if ed25519.Verify(pub, d.Raw, raw) {
				return nil
			}
		}
	}
	msg := fmt.Sprintf("manifest signature does not match any release key this kvsctl knows (signed by %s)", strings.Join(ids, ", "))
	if unreadable > 0 {
		msg += fmt.Sprintf("; %d of the signatures are not a readable %s signature", unreadable, AlgEd25519)
	}
	return errors.New(msg)
}

// ParseKeys decodes release public keys written as base64, each of them
// optionally prefixed with its key id and an equals sign ("r1=KZYz...").
// The id is documentation for whoever reads the constant; verification
// tries every key anyway.
func ParseKeys(specs []string) ([]ed25519.PublicKey, error) {
	keys := make([]ed25519.PublicKey, 0, len(specs))
	for _, spec := range specs {
		spec = strings.TrimSpace(spec)
		if spec == "" {
			continue
		}
		// An equals sign that is not the base64 padding separates the id.
		if i := strings.Index(spec, "="); i >= 0 && i < len(spec)-1 {
			spec = spec[i+1:]
		}
		raw, err := base64.StdEncoding.DecodeString(spec)
		if err != nil {
			return nil, fmt.Errorf("release key %q is not base64: %w", spec, err)
		}
		if len(raw) != ed25519.PublicKeySize {
			return nil, fmt.Errorf("release key %q is %d bytes, an Ed25519 public key is %d", spec, len(raw), ed25519.PublicKeySize)
		}
		keys = append(keys, ed25519.PublicKey(raw))
	}
	if len(keys) == 0 {
		return nil, errors.New("no release key given")
	}
	return keys, nil
}

// KeyID is the short name of a public key: the first eight hex characters
// of the sha256 of its raw bytes. The signature file carries it so a
// failure names the key that signed.
func KeyID(pub ed25519.PublicKey) string {
	sum := sha256.Sum256(pub)
	return hex.EncodeToString(sum[:])[:8]
}

// Parse decodes and validates a manifest.
func Parse(raw []byte) (*Manifest, error) {
	var m Manifest
	if err := json.Unmarshal(raw, &m); err != nil {
		return nil, fmt.Errorf("manifest is not valid JSON: %w", err)
	}
	if m.Schema > Schema {
		return nil, fmt.Errorf("this manifest needs a newer kvsctl (schema %d, this build reads up to %d): run 'kvsctl update-cli'", m.Schema, Schema)
	}
	if m.Schema < 1 {
		return nil, fmt.Errorf("manifest carries no usable schema number (%d)", m.Schema)
	}
	switch {
	case m.Updated != "":
		if _, err := time.Parse(time.RFC3339, m.Updated); err != nil {
			return nil, fmt.Errorf("manifest was updated %q, which is not an RFC3339 time (2026-10-15T12:00:00Z)", m.Updated)
		}
	case m.Schema >= 2:
		return nil, errors.New("manifest carries no updated time, which is what tells a fresh list from an old copy replayed at the URL")
	}
	for _, k := range m.Keys {
		if k.ID == "" || k.Pub == "" {
			return nil, errors.New("manifest announces a key without an id or without its public half")
		}
		if _, err := ParseKeys([]string{k.Pub}); err != nil {
			return nil, fmt.Errorf("manifest key %s: %w", k.ID, err)
		}
	}
	if len(m.Releases) == 0 {
		return nil, errors.New("manifest lists no release")
	}
	seen := map[string]bool{}
	for i := range m.Releases {
		if err := checkRelease(&m.Releases[i], seen); err != nil {
			return nil, err
		}
	}
	sort.SliceStable(m.Releases, func(i, j int) bool {
		return semver.Less(m.Releases[j].Version, m.Releases[i].Version)
	})
	return &m, nil
}

func checkRelease(r *Release, seen map[string]bool) error {
	if _, err := semver.Parse(r.Version); err != nil {
		return err
	}
	if seen[r.Version] {
		return fmt.Errorf("release %s is listed twice", r.Version)
	}
	seen[r.Version] = true
	if r.Bundle.URL == "" || len(r.Bundle.SHA256) != 64 {
		return fmt.Errorf("release %s has no bundle with a sha256", r.Version)
	}
	count := 0
	for _, img := range r.Images {
		if err := checkImage(r.Version, img); err != nil {
			return err
		}
		count++
	}
	for _, axis := range sortedKeys(r.Variants) {
		if axis == "" {
			return fmt.Errorf("release %s has a variant without a name", r.Version)
		}
		byValue := r.Variants[axis]
		for _, value := range sortedKeys(byValue) {
			if value == "" {
				return fmt.Errorf("release %s: variant %s has an entry without a value", r.Version, axis)
			}
			if len(byValue[value]) == 0 {
				return fmt.Errorf("release %s: variant %s %s lists no image", r.Version, axis, value)
			}
			for _, img := range byValue[value] {
				if err := checkImage(r.Version, img); err != nil {
					return err
				}
				count++
			}
		}
	}
	if count == 0 {
		return fmt.Errorf("release %s names no image", r.Version)
	}
	return nil
}

func checkImage(version string, img Image) error {
	if img.Service == "" {
		return fmt.Errorf("release %s: image %q names no service", version, img.Ref)
	}
	if img.Ref == "" {
		return fmt.Errorf("release %s: the image of %s has no reference", version, img.Service)
	}
	if !strings.HasPrefix(img.Digest, "sha256:") {
		return fmt.Errorf("release %s: image %q has no sha256 digest", version, img.Ref)
	}
	return nil
}

// ImagesFor is the image set an instance running that PHP series pulls: the
// images that do not vary plus the ones published for the series. A release
// without variants ignores the series and returns its whole list, which is
// what a schema 1 release does.
func (r *Release) ImagesFor(phpSeries string) ([]Image, error) {
	byValue := r.Variants[VariantPHP]
	if len(byValue) == 0 {
		return append([]Image(nil), r.Images...), nil
	}
	published := strings.Join(r.Series(), ", ")
	if phpSeries == "" {
		return nil, fmt.Errorf("release %s publishes images per PHP series (%s) and the series of this installation is unknown", r.Version, published)
	}
	images, ok := byValue[phpSeries]
	if !ok {
		return nil, fmt.Errorf("release %s publishes no image for PHP %s (it publishes %s)", r.Version, phpSeries, published)
	}
	out := append([]Image(nil), r.Images...)
	return append(out, images...), nil
}

// Series lists the PHP series the release publishes images for, oldest
// first. It is empty for a release whose images do not vary.
func (r *Release) Series() []string {
	byValue := r.Variants[VariantPHP]
	out := make([]string, 0, len(byValue))
	for series := range byValue {
		out = append(out, series)
	}
	sort.Slice(out, func(i, j int) bool { return lessSeries(out[i], out[j]) })
	return out
}

// lessSeries orders "8.2" before "8.10", which a plain string sort would
// get backwards.
func lessSeries(a, b string) bool {
	pa, pb := strings.Split(a, "."), strings.Split(b, ".")
	for i := 0; i < len(pa) && i < len(pb); i++ {
		na, ea := strconv.Atoi(pa[i])
		nb, eb := strconv.Atoi(pb[i])
		if ea != nil || eb != nil {
			if pa[i] != pb[i] {
				return pa[i] < pb[i]
			}
			continue
		}
		if na != nb {
			return na < nb
		}
	}
	return len(pa) < len(pb)
}

func sortedKeys[V any](m map[string]V) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// Latest is the highest version listed.
func (m *Manifest) Latest() *Release {
	return &m.Releases[0]
}

// Find returns the release with that version.
func (m *Manifest) Find(version string) *Release {
	for i := range m.Releases {
		if m.Releases[i].Version == version {
			return &m.Releases[i]
		}
	}
	return nil
}

// Between lists the releases newer than from and up to and including to,
// oldest first, so an upgrade can refuse to skip a step that requires it.
func (m *Manifest) Between(from, to string) []Release {
	var out []Release
	for i := len(m.Releases) - 1; i >= 0; i-- {
		r := m.Releases[i]
		if semver.Less(from, r.Version) && !semver.Less(to, r.Version) {
			out = append(out, r)
		}
	}
	return out
}

func read(url string) ([]byte, error) {
	switch {
	case strings.HasPrefix(url, "file://"):
		return os.ReadFile(strings.TrimPrefix(url, "file://"))
	case strings.HasPrefix(url, "http://"), strings.HasPrefix(url, "https://"):
		client := &http.Client{Timeout: 30 * time.Second}
		resp, err := client.Get(url)
		if err != nil {
			return nil, err
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			return nil, fmt.Errorf("%s answered %s", url, resp.Status)
		}
		return io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	default:
		return nil, fmt.Errorf("unsupported URL %q (http, https or file)", url)
	}
}

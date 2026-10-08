// Package manifest reads and verifies the signed list of stack releases.
package manifest

import (
	"bytes"
	"context"
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
	"os/signal"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/MaximeMichaud/KVS-install/cli/internal/semver"
)

// Schema is the manifest format this build reads and writes. Adding a field
// never bumps the number; a change an older binary would read wrongly does,
// and check and upgrade on that binary then refuse the manifest and ask for
// update-cli. update-cli reads only the part of the format that never
// changes, whatever the number says (ParseCLI), so a newer schema never
// strands a binary that is already out. A release that needs a newer kvsctl
// without a new format says so in requires.kvsctl_min instead.
const Schema = 2

// The channels a manifest names. The manifest of a release candidate is the
// stable list of the day with the candidate added, signed with the same key,
// so its channel is what keeps it from passing for the stable list.
const (
	ChannelStable    = "stable"
	ChannelCandidate = "candidate"
)

// DefaultURL is the manifest of the release GitHub marks as the latest,
// which kvsctl reads unless --manifest or KVSCTL_MANIFEST_URL names another.
const DefaultURL = "https://github.com/MaximeMichaud/KVS-install/releases/latest/download/manifest.json"

// The variant axes: what a release publishes more than one image for,
// because the image depends on the installation. Release.Variants holds
// them by axis, then by value, and Release.Images the images every
// installation runs.
const (
	// VariantPHP is keyed by PHP series ("8.1"): an IonCube encoded site is
	// bound to the series its files were encoded for.
	VariantPHP = "php"
	// VariantMariaDB is keyed by MariaDB series ("11.8"): the server
	// rewrites its data files for a new series and an older server cannot
	// open them again, so a stack keeps its series until it asks to move.
	VariantMariaDB = "mariadb"
)

// knownAxes are the variant axes this build knows how to choose a value
// for. A manifest may carry another one; reading it is fine, installing a
// release that varies by it is not, because the choice would be a guess.
var knownAxes = map[string]string{
	VariantPHP:     "PHP",
	VariantMariaDB: "MariaDB",
}

// AxisLabel is how an axis is named to the operator: "PHP", "MariaDB".
func AxisLabel(axis string) string {
	if label, ok := knownAxes[axis]; ok {
		return label
	}
	return axis
}

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
	// ComposeMin is the oldest Docker Compose that reads the release
	// override. Its "build: !reset null" clears the build sections of the
	// compose file from Docker Compose 2.19.0 on, the minimum measured: 2.18
	// keeps a build from a directory named null, and fails to build it.
	ComposeMin string `json:"compose_min,omitempty"`
	// KvsctlMin is the oldest kvsctl that may install the release: check
	// and upgrade on an older one stop and ask for update-cli first. It is
	// how a release needs a newer kvsctl while the format stays the same.
	KvsctlMin string `json:"kvsctl_min,omitempty"`
}

// Release is one version of the stack.
type Release struct {
	Version string `json:"version"`
	Date    string `json:"date"`
	// Commit is the git commit the release was cut from. adopt compares it
	// with the checkout it records, so a checkout newer than a release is
	// never taken back to it by an upgrade.
	Commit string `json:"commit,omitempty"`
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
	// Variants["php"]["8.1"] is what an instance running PHP 8.1 pulls,
	// Variants["mariadb"]["11.8"] what one running MariaDB 11.8 pulls.
	Variants map[string]map[string][]Image `json:"variants,omitempty"`
	// Database is "migrates" when the release changes the schema, which
	// makes a rollback restore the backup.
	Database string `json:"database,omitempty"`
	// OneWay marks a release that cannot be undone by restarting the
	// previous images: the rollback has to recreate the MariaDB data
	// directory and replay the dump. It is independent of Database, which
	// says whether the data itself changed.
	OneWay bool             `json:"one_way,omitempty"`
	CLI    map[string]Asset `json:"cli,omitempty"`
	// Requires stays last: a release writes again every release before it
	// through this type, so a field moved here would change the signed
	// bytes of releases already published.
	Requires Requires `json:"requires"`
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
	// Signatures is the signature file: one entry per signing key, which is
	// what lets a rotation release carry the old key and the new one at
	// once.
	Signatures []Signature
	Manifest   *Manifest
}

// ErrInterrupted is the error of a Fetch an interrupt ended, and of any
// Fetch after it.
var ErrInterrupted = errors.New("the read of the manifest was interrupted")

// interrupted is set once an interrupt ended a Fetch.
var interrupted atomic.Bool

// Fetch reads the manifest at url and its detached signature at url+".sig".
// http(s) and file URLs are accepted. It is FetchContext for a caller with
// no context to give, and it ends at once at an interrupt (Ctrl-C,
// SIGTERM): a command that catches the signal to stop cleanly would
// otherwise wait for the timeout of the request, 30 seconds a file, before
// it could. The signal then takes its course, sent again once the read lets
// go of it: a process that does not catch it ends by it, as it would have
// without the read, and one that does gets ErrInterrupted, and the signal a
// second time, so a caller that counts them reads with FetchContext. A
// Fetch after an interrupted one, such as the update reminder that follows
// a command, fails at once: the command is on its way out.
func Fetch(url string) (*Document, error) {
	if interrupted.Load() {
		return nil, ErrInterrupted
	}
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, os.Interrupt, syscall.SIGTERM)
	ctx, cancel := context.WithCancel(context.Background())
	var caught os.Signal
	watched := make(chan struct{})
	go func() {
		defer close(watched)
		select {
		case caught = <-signals:
			cancel()
		case <-ctx.Done():
		}
	}()
	doc, err := FetchContext(ctx, url)
	signal.Stop(signals)
	cancel()
	<-watched
	if caught == nil {
		// One that came between the end of the read and Stop.
		select {
		case caught = <-signals:
		default:
		}
	}
	if caught == nil {
		return doc, err
	}
	interrupted.Store(true)
	if sig, ok := caught.(syscall.Signal); ok {
		raise(sig)
	}
	return nil, ErrInterrupted
}

// FetchContext reads the manifest and its signature as Fetch does, for as
// long as ctx lasts: a server that does not answer is left as soon as ctx
// ends, so the Ctrl-C of an operator stops the read at once instead of 30
// seconds later.
func FetchContext(ctx context.Context, url string) (*Document, error) {
	raw, err := read(ctx, url)
	if err != nil {
		return nil, fmt.Errorf("manifest: %w", err)
	}
	sig, err := read(ctx, url+".sig")
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

// readSignature reads manifest.json.sig: a JSON list of signatures, or one
// signature written as a JSON object.
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
		return errors.New("manifest signature is not a JSON signature file")
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

// VerifyCLI checks the signature the way VerifyAny does, then reads only
// the frozen part of the manifest (ParseCLI), whatever its schema: it is
// how update-cli reads every manifest a later release may publish.
func (d *Document) VerifyCLI(keys []ed25519.PublicKey) (*Manifest, error) {
	if len(keys) == 0 {
		return nil, errors.New("no release key to check the manifest signature with")
	}
	if err := d.verifySignature(keys); err != nil {
		return nil, err
	}
	return ParseCLI(d.Raw)
}

func (d *Document) verifySignature(keys []ed25519.PublicKey) error {
	if len(d.Signatures) == 0 {
		return errors.New("manifest signature lists no signature")
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
	// The schema is read before anything else: a later format may give any
	// other field another shape, and what this build has to say about it is
	// to update, not that the file is broken. The schema stays a number.
	var head struct {
		Schema int `json:"schema"`
	}
	if err := json.Unmarshal(raw, &head); err != nil {
		return nil, fmt.Errorf("manifest is not valid JSON: %w", err)
	}
	if head.Schema > Schema {
		return nil, fmt.Errorf("this manifest needs a newer kvsctl (schema %d, this build reads %d): run 'kvsctl update-cli'", head.Schema, Schema)
	}
	var m Manifest
	if err := json.Unmarshal(raw, &m); err != nil {
		return nil, fmt.Errorf("manifest is not valid JSON: %w", err)
	}
	if m.Schema < Schema {
		return nil, fmt.Errorf("manifest carries schema %d, which no release of kvsctl reads (this build reads %d)", m.Schema, Schema)
	}
	if m.Updated == "" {
		return nil, errors.New("manifest carries no updated time, which is what tells a fresh list from an old copy replayed at the URL")
	}
	if _, err := time.Parse(time.RFC3339, m.Updated); err != nil {
		return nil, fmt.Errorf("manifest was updated %q, which is not an RFC3339 time (2026-10-15T12:00:00Z)", m.Updated)
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

// cliFormat is the part of the manifest that never changes, whatever its
// schema: the channel, the updated time (RFC3339), the id and the date of
// every key announced, and the version and the kvsctl builds of every
// release, each build with its url and its sha256. A later format may add
// anything around them and change anything else, never these names or
// their shapes: they are how every kvsctl already out finds the build that
// reads that format, so update-cli reads them and nothing else. The size
// of a build is read too when it is a number: its length in bytes, which
// bounds the download. A later format may leave it out or give it another
// shape, which update-cli then ignores, never another meaning as a number.
type cliFormat struct {
	Channel string `json:"channel"`
	Updated string `json:"updated"`
	Keys    []struct {
		ID        string `json:"id"`
		ValidFrom string `json:"valid_from"`
	} `json:"keys"`
	Releases []struct {
		Version string `json:"version"`
		CLI     map[string]struct {
			URL    string          `json:"url"`
			SHA256 string          `json:"sha256"`
			Size   json.RawMessage `json:"size"`
		} `json:"cli"`
	} `json:"releases"`
}

// cliSize is the size of a kvsctl build when the manifest gives it as a
// number of bytes, 0 otherwise: a download then stops at the most kvsctl
// takes without a size.
func cliSize(raw json.RawMessage) int64 {
	var n int64
	if json.Unmarshal(raw, &n) != nil || n < 0 {
		return 0
	}
	return n
}

// ParseCLI reads the frozen part of a manifest (cliFormat) and ignores its
// schema and everything else. The manifest it returns carries the channel,
// the updated time, the keys announced (id and date) and, for every
// release, its version and its kvsctl builds, newest first, with their size
// when the manifest gives it as a number: enough to find the build to
// install and to judge the freshness of the list, nothing to install a stack
// release with.
func ParseCLI(raw []byte) (*Manifest, error) {
	var f cliFormat
	if err := json.Unmarshal(raw, &f); err != nil {
		return nil, fmt.Errorf("manifest is not valid JSON: %w", err)
	}
	if _, err := time.Parse(time.RFC3339, f.Updated); err != nil {
		return nil, fmt.Errorf("manifest was updated %q, which is not an RFC3339 time (2026-10-15T12:00:00Z)", f.Updated)
	}
	if len(f.Releases) == 0 {
		return nil, errors.New("manifest lists no release")
	}
	m := &Manifest{Channel: f.Channel, Updated: f.Updated}
	for _, k := range f.Keys {
		if k.ID != "" {
			m.Keys = append(m.Keys, Key{ID: k.ID, ValidFrom: k.ValidFrom})
		}
	}
	seen := map[string]bool{}
	for _, r := range f.Releases {
		if _, err := semver.Parse(r.Version); err != nil {
			return nil, err
		}
		if seen[r.Version] {
			return nil, fmt.Errorf("release %s is listed twice", r.Version)
		}
		seen[r.Version] = true
		rel := Release{Version: r.Version}
		for platform, build := range r.CLI {
			if rel.CLI == nil {
				rel.CLI = map[string]Asset{}
			}
			rel.CLI[platform] = Asset{URL: build.URL, SHA256: build.SHA256, Size: cliSize(build.Size)}
		}
		m.Releases = append(m.Releases, rel)
	}
	sort.SliceStable(m.Releases, func(i, j int) bool {
		return semver.Less(m.Releases[j].Version, m.Releases[i].Version)
	})
	return m, nil
}

// Candidate reports whether m is the list of a release candidate: its
// channel says so, or its newest release is a candidate, which is how a
// manifest signed before candidates named their channel shows one. The
// stable list of a release never gains a candidate after it.
func (m *Manifest) Candidate() bool {
	return m.Channel == ChannelCandidate || (len(m.Releases) > 0 && semver.IsPrerelease(m.Releases[0].Version))
}

// CheckChannel refuses a manifest whose channel is not one the URL it was
// read from serves. The default URL serves the stable list alone: the list
// of a candidate there, whatever channel it names (Candidate), means a
// candidate was marked as the latest release, which write access to the
// repository is enough for, and its signature does not tell the two lists
// apart. A URL the operator names may serve either, the manifest of a
// candidate to try included. A channel this build does not know is refused
// wherever it comes from.
func (m *Manifest) CheckChannel(url string) error {
	if m.Channel != ChannelStable && m.Channel != ChannelCandidate {
		return fmt.Errorf("the manifest at %s is of channel %q, which this kvsctl does not read: it reads %s, and %s from a URL given with --manifest", url, m.Channel, ChannelStable, ChannelCandidate)
	}
	if url != DefaultURL || !m.Candidate() {
		return nil
	}
	what := "is the one of a release candidate (channel " + ChannelCandidate + ")"
	if m.Channel != ChannelCandidate {
		what = "names the release candidate " + m.Releases[0].Version + " as its newest release"
	}
	return fmt.Errorf("the manifest at %s %s, and that URL serves stable releases only: a candidate was published as the latest release by mistake; wait until the latest release is a stable one again, or point --manifest at the manifest of the release to install", url, what)
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
	if r.Commit != "" && !commitRe.MatchString(r.Commit) {
		return fmt.Errorf("release %s: commit %q is not a git commit id", r.Version, r.Commit)
	}
	// A minimum that names no version would let any kvsctl through, the
	// opposite of what the release asks for.
	if min := r.Requires.KvsctlMin; min != "" {
		if _, err := semver.Parse(min); err != nil {
			return fmt.Errorf("release %s: kvsctl_min: %w", r.Version, err)
		}
	}
	// owner says where each service gets its image: the plain list or one
	// variant axis, never both, so an installation never pulls two images
	// for one container.
	owner := map[string]string{}
	count := 0
	for _, img := range r.Images {
		if err := checkImage(r.Version, img); err != nil {
			return err
		}
		if prev, seen := owner[img.Service]; seen {
			return fmt.Errorf("release %s names %s twice (%s)", r.Version, img.Service, prev)
		}
		owner[img.Service] = "images"
		count++
	}
	for _, axis := range sortedKeys(r.Variants) {
		if axis == "" {
			return fmt.Errorf("release %s has a variant without a name", r.Version)
		}
		byValue := r.Variants[axis]
		var services string
		for _, value := range sortedKeys(byValue) {
			if value == "" {
				return fmt.Errorf("release %s: variant %s has an entry without a value", r.Version, axis)
			}
			if len(byValue[value]) == 0 {
				return fmt.Errorf("release %s: variant %s %s lists no image", r.Version, axis, value)
			}
			var names []string
			for _, img := range byValue[value] {
				if err := checkImage(r.Version, img); err != nil {
					return err
				}
				names = append(names, img.Service)
				count++
			}
			sort.Strings(names)
			for i := 1; i < len(names); i++ {
				if names[i] == names[i-1] {
					return fmt.Errorf("release %s: variant %s %s names %s twice", r.Version, axis, value, names[i])
				}
			}
			// Every value of an axis replaces the same services, or an
			// installation would lose a service by moving to another value.
			list := strings.Join(names, ",")
			if services == "" {
				services = list
				for _, name := range names {
					if prev, seen := owner[name]; seen {
						return fmt.Errorf("release %s: %s is both in %s and in variant %s", r.Version, name, prev, axis)
					}
					owner[name] = "variant " + axis
				}
			} else if list != services {
				return fmt.Errorf("release %s: variant %s %s names %s where the other values name %s", r.Version, axis, value, list, services)
			}
		}
	}
	if count == 0 {
		return fmt.Errorf("release %s names no image", r.Version)
	}
	return nil
}

var commitRe = regexp.MustCompile(`^[0-9a-f]{40}([0-9a-f]{24})?$`)

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

// ImagesFor is the image set an installation pulls: the images that do not
// vary, then, for every axis the release varies by (in axis name order),
// the images published for the value the installation has. values maps an
// axis to that value, VariantPHP to "8.1" for instance; an axis the release
// does not vary by is ignored, and one it varies by needs a published value.
func (r *Release) ImagesFor(values map[string]string) ([]Image, error) {
	out := append([]Image(nil), r.Images...)
	for _, axis := range sortedKeys(r.Variants) {
		byValue := r.Variants[axis]
		if len(byValue) == 0 {
			continue
		}
		if _, known := knownAxes[axis]; !known {
			return nil, fmt.Errorf("release %s varies its images by %q, which this kvsctl does not know: run 'kvsctl update-cli'", r.Version, axis)
		}
		published := strings.Join(r.Values(axis), ", ")
		value := values[axis]
		if value == "" {
			return nil, fmt.Errorf("release %s publishes images per %s series (%s) and the series of this installation is unknown", r.Version, AxisLabel(axis), published)
		}
		images, ok := byValue[value]
		if !ok {
			return nil, fmt.Errorf("release %s publishes no image for %s %s (it publishes %s)", r.Version, AxisLabel(axis), value, published)
		}
		out = append(out, images...)
	}
	return out, nil
}

// Values lists the values the release publishes images for on one axis,
// oldest first. It is empty when the release does not vary by that axis.
func (r *Release) Values(axis string) []string {
	byValue := r.Variants[axis]
	out := make([]string, 0, len(byValue))
	for value := range byValue {
		out = append(out, value)
	}
	sort.Slice(out, func(i, j int) bool { return LessSeries(out[i], out[j]) })
	return out
}

// Series lists the PHP series the release publishes images for, oldest
// first. It is empty for a release whose images do not vary with PHP.
func (r *Release) Series() []string { return r.Values(VariantPHP) }

// LessSeries orders "8.2" before "8.10" and "11.8" before "12.3", which a
// plain string sort would get backwards.
func LessSeries(a, b string) bool {
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

// Latest is the highest version listed, a release candidate included.
func (m *Manifest) Latest() *Release {
	return &m.Releases[0]
}

// LatestStable is the highest version listed that is not a release
// candidate, nil when the manifest lists candidates only. A candidate is
// installed when its version is asked for, never as the default target.
func (m *Manifest) LatestStable() *Release {
	for i := range m.Releases {
		if v, err := semver.Parse(m.Releases[i].Version); err == nil && v.Pre == "" {
			return &m.Releases[i]
		}
	}
	return nil
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

// maxFile is the most kvsctl reads of a manifest or of its signature. A
// release of the current stack takes about 76 kB of the manifest, which
// lists every release, so this holds about 110 of them while a server that
// never stops sending cannot fill the memory. kvsctl-release signs up to
// this size, so it never goes lower (docs/releasing.md, "The size of the
// manifest").
const maxFile = 8 << 20

func read(ctx context.Context, url string) ([]byte, error) {
	var body io.Reader
	switch {
	case strings.HasPrefix(url, "file://"):
		f, err := os.Open(strings.TrimPrefix(url, "file://"))
		if err != nil {
			return nil, err
		}
		defer f.Close()
		body = f
	case strings.HasPrefix(url, "http://"), strings.HasPrefix(url, "https://"):
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
		if err != nil {
			return nil, err
		}
		client := &http.Client{Timeout: 30 * time.Second}
		resp, err := client.Do(req)
		if err != nil {
			return nil, err
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			return nil, fmt.Errorf("%s answered %s", url, resp.Status)
		}
		body = resp.Body
	default:
		return nil, fmt.Errorf("unsupported URL %q (http, https or file)", url)
	}
	// One byte past the limit tells a file that ends there from one that
	// was cut: a cut manifest would only fail later, as a bad signature or
	// bad JSON, which would send the operator looking in the wrong place.
	data, err := io.ReadAll(io.LimitReader(body, maxFile+1))
	if err != nil {
		return nil, err
	}
	if len(data) > maxFile {
		return nil, fmt.Errorf("%s is larger than %d MiB, the most kvsctl reads", url, maxFile>>20)
	}
	return data, nil
}

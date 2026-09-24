// kvsctl-release is the maintainer tool: it builds a release bundle from a
// git checkout, reads image digests and sizes from a registry, and signs
// the manifest kvsctl reads.
package main

import (
	"archive/tar"
	"compress/gzip"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
	"unicode"

	"github.com/MaximeMichaud/KVS-install/cli/internal/manifest"
	"github.com/MaximeMichaud/KVS-install/cli/internal/release"
	"github.com/MaximeMichaud/KVS-install/cli/internal/semver"
)

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	var err error
	switch os.Args[1] {
	case "keygen":
		err = keygen(os.Args[2:])
	case "bundle":
		err = bundle(os.Args[2:])
	case "manifest":
		err = manifestCmd(os.Args[2:])
	case "verify":
		err = verify(os.Args[2:])
	default:
		usage()
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "kvsctl-release:", err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, `usage:
  kvsctl-release keygen --out <dir>
      write release.key (PEM, private) and release.pub (base64)

  kvsctl-release bundle --repo <dir> --ref <git ref> --version <v> --out <file.tar.gz> \
      --images <svc=ref|svc@series=ref,...> [--digests <svc[@series]=sha256:...,...>] [--built <svc,...>]
      package the release files, the compose override pinning the images, and docker/RELEASE

  kvsctl-release verify --manifest manifest.json --signature manifest.json.sig --pub <base64|id=base64>...
      check a manifest against its signature file with the given public keys; one match is enough

  kvsctl-release manifest --key release.key --out <dir> --version <v> --bundle-url <url> --bundle <file.tar.gz> \
      --images <svc=ref|svc@series=ref,...> [--digests <svc[@series]=sha256:...,...>] [--previous manifest.json] \
      [--key <release.key>]... [--key-id <id>]... [--announce-key <id=base64[@YYYY-MM-DD]>]... \
      [--notes ..] [--notes-file RELEASE_NOTES.md] [--notes-url ..] [--highlight ..]... \
      [--php 8.1] [--php-series 8.1,8.2,8.3,8.4] [--min-from v] [--kvs-min v] [--mariadb-from 11.4,11.8] \
      [--compose-min 2.24.0] [--database none|migrates] [--one-way] [--channel stable] \
      [--cli os-arch=url,...] [--assets <dir>]

An image given as service@series=ref is a variant: it lands in
variants.php[series] of the manifest and reads its image from .env in the
compose override, because the PHP series an IonCube site was encoded for is
a property of the instance, not of the release. A plain service=ref does not
vary and is pinned directly.`)
}

// stringList is a flag given more than once.
type stringList []string

func (l *stringList) String() string { return strings.Join(*l, ",") }

func (l *stringList) Set(v string) error {
	*l = append(*l, v)
	return nil
}

func keygen(args []string) error {
	fs := flag.NewFlagSet("keygen", flag.ExitOnError)
	out := fs.String("out", ".", "directory for release.key and release.pub")
	fs.Parse(args)
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return err
	}
	der, err := x509.MarshalPKCS8PrivateKey(priv)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(*out, 0o700); err != nil {
		return err
	}
	keyPath := filepath.Join(*out, "release.key")
	if err := os.WriteFile(keyPath, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}), 0o600); err != nil {
		return err
	}
	pubPath := filepath.Join(*out, "release.pub")
	if err := os.WriteFile(pubPath, []byte(base64.StdEncoding.EncodeToString(pub)+"\n"), 0o644); err != nil {
		return err
	}
	fmt.Printf("private key: %s (keep it out of the repository)\npublic key:  %s\nkey id:      %s\n%s\n",
		keyPath, pubPath, manifest.KeyID(pub), base64.StdEncoding.EncodeToString(pub))
	return nil
}

func loadKey(path string) (ed25519.PrivateKey, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	block, _ := pem.Decode(data)
	if block == nil {
		return nil, errors.New("release key is not PEM")
	}
	key, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, err
	}
	priv, ok := key.(ed25519.PrivateKey)
	if !ok {
		return nil, errors.New("release key is not Ed25519")
	}
	return priv, nil
}

// signer is one release key with the id its signature carries.
type signer struct {
	id   string
	priv ed25519.PrivateKey
}

// loadSigners reads every --key. A --key-id given at the same position
// names that key; the others are named by the first eight hex characters of
// the sha256 of their public half, which is what kvsctl prints when no key
// it knows verifies.
func loadSigners(paths, ids []string) ([]signer, error) {
	if len(paths) == 0 {
		return nil, errors.New("--key is required")
	}
	if len(ids) > len(paths) {
		return nil, fmt.Errorf("%d --key-id for %d --key: they pair by position", len(ids), len(paths))
	}
	var out []signer
	seen := map[string]bool{}
	for i, path := range paths {
		priv, err := loadKey(path)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", path, err)
		}
		id := ""
		if i < len(ids) {
			id = strings.TrimSpace(ids[i])
		}
		if id == "" {
			id = manifest.KeyID(priv.Public().(ed25519.PublicKey))
		}
		if seen[id] {
			return nil, fmt.Errorf("key id %s is used twice", id)
		}
		seen[id] = true
		out = append(out, signer{id: id, priv: priv})
	}
	return out, nil
}

// signManifest writes the signature file: a JSON list with one entry per
// key, so a rotation release is signed by the outgoing key and the incoming
// one at once. A single key writes the same form; the bare base64 file of
// the first releases is legacy and is only still read.
func signManifest(raw []byte, signers []signer) ([]byte, error) {
	sigs := make([]manifest.Signature, 0, len(signers))
	for _, s := range signers {
		sigs = append(sigs, manifest.Signature{
			KeyID: s.id,
			Alg:   manifest.AlgEd25519,
			Sig:   base64.StdEncoding.EncodeToString(ed25519.Sign(s.priv, raw)),
		})
	}
	file, err := json.MarshalIndent(sigs, "", "  ")
	if err != nil {
		return nil, err
	}
	return append(file, '\n'), nil
}

// imageSpec is one --images entry: a service, the variant value when the
// image depends on the PHP series, and the image reference.
type imageSpec struct {
	Service string
	Series  string
	Ref     string
}

// Key is how an image is named in --digests and in the maps below.
func (s imageSpec) Key() string { return variantKey(s.Service, s.Series) }

func variantKey(service, series string) string {
	if series == "" {
		return service
	}
	return service + "@" + series
}

// fields splits a list written with commas, spaces or newlines, so a spec
// file produced by a workflow can be passed as it is.
func fields(spec string) []string {
	return strings.FieldsFunc(spec, func(r rune) bool { return r == ',' || unicode.IsSpace(r) })
}

// parseImages reads "nginx=ref,php-fpm@8.1=ref,cron@8.1=ref": a plain entry
// is an image every instance runs, an entry with a series is published once
// per PHP series.
func parseImages(spec string) ([]imageSpec, error) {
	var out []imageSpec
	seen := map[string]bool{}
	varies := map[string]bool{}
	plain := map[string]bool{}
	for _, item := range fields(spec) {
		left, ref, ok := strings.Cut(item, "=")
		if !ok || ref == "" {
			return nil, fmt.Errorf("image %q is not service=ref or service@series=ref", item)
		}
		service, series, hasSeries := strings.Cut(left, "@")
		if service == "" || (hasSeries && series == "") {
			return nil, fmt.Errorf("image %q is not service=ref or service@series=ref", item)
		}
		key := variantKey(service, series)
		if seen[key] {
			return nil, fmt.Errorf("image %s is given twice", key)
		}
		seen[key] = true
		if hasSeries {
			varies[service] = true
		} else {
			plain[service] = true
		}
		if varies[service] && plain[service] {
			return nil, fmt.Errorf("image %s is given both with and without a series", service)
		}
		out = append(out, imageSpec{Service: service, Series: series, Ref: ref})
	}
	return out, nil
}

// parseDigests reads "nginx=sha256:...,php-fpm@8.1=sha256:...", what the
// build step of the workflow reported for each image. The workflow writes
// the non-varying ones as "nginx@=sha256:...", which reads the same.
func parseDigests(spec string) (map[string]string, error) {
	out := map[string]string{}
	for _, item := range fields(spec) {
		left, digest, ok := strings.Cut(item, "=")
		if !ok {
			return nil, fmt.Errorf("digest %q is not service[@series]=sha256:...", item)
		}
		service, series, _ := strings.Cut(left, "@")
		if service == "" || !strings.HasPrefix(digest, "sha256:") {
			return nil, fmt.Errorf("digest %q is not service[@series]=sha256:...", item)
		}
		out[variantKey(service, series)] = digest
	}
	return out, nil
}

func splitList(spec string) []string {
	return fields(spec)
}

func bundle(args []string) error {
	fs := flag.NewFlagSet("bundle", flag.ExitOnError)
	repo := fs.String("repo", ".", "git checkout")
	ref := fs.String("ref", "HEAD", "git ref to package")
	version := fs.String("version", "", "release version")
	imageSpecs := fs.String("images", "", "service=ref or service@series=ref pairs pinned by docker-compose.release.yml")
	digestSpec := fs.String("digests", "", "service[@series]=sha256:... pairs; an image with a digest is pinned to it in the override")
	builtSpec := fs.String("built", strings.Join(builtByDefault, ","), "services the base compose file builds, whose build section the override has to clear")
	out := fs.String("out", "", "bundle file (.tar.gz)")
	fs.Parse(args)
	if *version == "" || *out == "" {
		return errors.New("--version and --out are required")
	}
	if _, err := semver.Parse(*version); err != nil {
		return err
	}
	specs, err := parseImages(*imageSpecs)
	if err != nil {
		return err
	}
	digests, err := parseDigests(*digestSpec)
	if err != nil {
		return err
	}
	built := map[string]bool{}
	for _, service := range splitList(*builtSpec) {
		built[service] = true
	}
	cmd := exec.Command("git", append([]string{"-C", *repo, "ls-tree", "-r", "-z", "--name-only", *ref, "--"}, release.Paths...)...)
	listing, err := cmd.Output()
	if err != nil {
		return fmt.Errorf("git ls-tree: %w", err)
	}
	var files []string
	for _, f := range strings.Split(string(listing), "\x00") {
		if f != "" {
			files = append(files, f)
		}
	}
	sort.Strings(files)
	f, err := os.Create(*out)
	if err != nil {
		return err
	}
	gz := gzip.NewWriter(f)
	tw := tar.NewWriter(gz)
	stamp := time.Now()
	for _, name := range files {
		content, err := exec.Command("git", "-C", *repo, "show", *ref+":"+name).Output()
		if err != nil {
			return fmt.Errorf("git show %s: %w", name, err)
		}
		mode := int64(0o644)
		modeOut, err := exec.Command("git", "-C", *repo, "ls-tree", *ref, "--", name).Output()
		if err == nil && strings.HasPrefix(string(modeOut), "100755") {
			mode = 0o755
		}
		if err := tw.WriteHeader(&tar.Header{Name: name, Mode: mode, Size: int64(len(content)), ModTime: stamp, Typeflag: tar.TypeReg}); err != nil {
			return err
		}
		if _, err := tw.Write(content); err != nil {
			return err
		}
	}
	// The version the files come from, readable without kvsctl and without
	// the state file: docker/RELEASE is what an operator reads on the
	// server to know which release laid these files down.
	added := map[string]string{"docker/RELEASE": *version + "\n"}
	if len(specs) > 0 {
		added["docker/"+releaseOverride] = renderOverride(*version, specs, digests, built)
	}
	for _, name := range sortedKeys(added) {
		content := added[name]
		if err := tw.WriteHeader(&tar.Header{Name: name, Mode: 0o644, Size: int64(len(content)), ModTime: stamp, Typeflag: tar.TypeReg}); err != nil {
			return err
		}
		if _, err := tw.Write([]byte(content)); err != nil {
			return err
		}
	}
	if err := tw.Close(); err != nil {
		return err
	}
	if err := gz.Close(); err != nil {
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	sum, size, err := fileSum(*out)
	if err != nil {
		return err
	}
	fmt.Printf("%s: %d files, %d bytes, sha256 %s\n", *out, len(files)+len(added), size, sum)
	return nil
}

// releaseOverride is the compose file the bundle carries; kvsctl adds it to
// COMPOSE_FILE when it applies the release.
const releaseOverride = "docker-compose.release.yml"

// builtByDefault are the services docker/docker-compose.yml builds on the
// server. The override clears their build section, or compose would build
// them again as soon as the pinned image is missing from the engine.
var builtByDefault = []string{"nginx", "php-fpm", "cron", "kvs-init", "manticore"}

// renderOverride writes the compose override that pins the images of a
// release. A service whose image varies with the PHP series reads it from
// .env, where kvsctl writes the image of the series the instance runs.
func renderOverride(version string, specs []imageSpec, digests map[string]string, built map[string]bool) string {
	var order []string
	image := map[string]string{}
	varies := map[string]bool{}
	for _, s := range specs {
		if _, seen := image[s.Service]; !seen {
			order = append(order, s.Service)
			image[s.Service] = pinned(s, digests)
		}
		if s.Series != "" {
			varies[s.Service] = true
		}
	}
	var b strings.Builder
	fmt.Fprintf(&b, "# Generated by kvsctl-release for stack %s: the images this release runs.\n", version)
	b.WriteString(`#
# kvsctl adds this file to COMPOSE_FILE, so every "docker compose" command of
# the installation, by hand or from the scripts, runs these images instead of
# building the services on the server. "build: !reset null" removes the build
# section the base compose file carries for them, which needs Docker Compose
# 2.24 or newer: that is the version requires.compose_min names in the
# manifest. An image written as ref@sha256:... is that exact image, so a tag
# pushed again later cannot change what runs.
`)
	if len(varies) > 0 {
		b.WriteString(`#
# The services whose image depends on the PHP series read it from .env, where
# kvsctl writes the image of the series this installation runs: the PHP an
# IonCube encoded site needs is a property of the instance, not of the
# release, so one override serves every published series.
`)
	}
	b.WriteString("services:\n")
	for _, service := range order {
		fmt.Fprintf(&b, "  %s:\n", service)
		if built[service] {
			b.WriteString("    build: !reset null\n")
		}
		if varies[service] {
			fmt.Fprintf(&b, "    image: %q\n", "${"+envVar(service)+"}")
			continue
		}
		fmt.Fprintf(&b, "    image: %q\n", image[service])
	}
	return b.String()
}

// pinned is the reference the override writes: the tag with its digest when
// one is known, the tag alone otherwise.
func pinned(s imageSpec, digests map[string]string) string {
	digest := digests[s.Key()]
	if digest == "" || strings.Contains(s.Ref, "@") {
		return s.Ref
	}
	return s.Ref + "@" + digest
}

// envVar is the .env variable carrying the image of a service that varies
// with the PHP series: KVS_PHP_FPM_IMAGE for php-fpm, KVS_CRON_IMAGE for
// cron.
func envVar(service string) string {
	return "KVS_" + strings.NewReplacer("-", "_", ".", "_").Replace(strings.ToUpper(service)) + "_IMAGE"
}

func sortedKeys[V any](m map[string]V) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func fileSum(path string) (string, int64, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", 0, err
	}
	defer f.Close()
	hash := sha256.New()
	n, err := io.Copy(hash, f)
	if err != nil {
		return "", 0, err
	}
	return hex.EncodeToString(hash.Sum(nil)), n, nil
}

// firstParagraph reduces a release notes file to the one line the manifest
// carries: the first block of text, markdown headings skipped and the lines
// joined. The rest of the file stays where it belongs, behind --notes-url,
// because the manifest is fetched on every status check.
func firstParagraph(text string) string {
	var out []string
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			if len(out) > 0 {
				break
			}
			continue
		}
		if len(out) == 0 && strings.HasPrefix(line, "#") {
			continue
		}
		out = append(out, line)
	}
	if len(out) > 0 {
		out[0] = strings.TrimPrefix(strings.TrimPrefix(out[0], "- "), "* ")
	}
	return strings.Join(strings.Fields(strings.Join(out, " ")), " ")
}

// parseAnnouncedKeys reads "r2=BASE64" or "r2=BASE64@2026-11-01". The list
// is information for the operator: a manifest cannot introduce the key that
// signs it, so kvsctl only reports that a new key is coming and update-cli
// brings the binary that trusts it.
func parseAnnouncedKeys(specs []string) ([]manifest.Key, error) {
	var out []manifest.Key
	for _, spec := range specs {
		id, rest, ok := strings.Cut(strings.TrimSpace(spec), "=")
		if !ok || id == "" || rest == "" {
			return nil, fmt.Errorf("announced key %q is not id=base64[@YYYY-MM-DD]", spec)
		}
		pub, validFrom, _ := strings.Cut(rest, "@")
		if _, err := manifest.ParseKeys([]string{pub}); err != nil {
			return nil, fmt.Errorf("announced key %s: %w", id, err)
		}
		if validFrom != "" {
			if _, err := time.Parse("2006-01-02", validFrom); err != nil {
				return nil, fmt.Errorf("announced key %s: %q is not a YYYY-MM-DD date", id, validFrom)
			}
		}
		out = append(out, manifest.Key{ID: id, Pub: pub, ValidFrom: validFrom})
	}
	return out, nil
}

func manifestCmd(args []string) error {
	fs := flag.NewFlagSet("manifest", flag.ExitOnError)
	var keyPaths, keyIDs, highlights, announce stringList
	fs.Var(&keyPaths, "key", "release.key; repeat it so a rotation release is signed by the outgoing and the incoming key")
	fs.Var(&keyIDs, "key-id", "id of the --key at the same position; derived from the key when absent")
	fs.Var(&highlights, "highlight", "one short line for the confirmation screen; at most three")
	fs.Var(&announce, "announce-key", "id=base64[@YYYY-MM-DD] of a key a later release will sign with; information only")
	out := fs.String("out", ".", "directory receiving manifest.json and manifest.json.sig")
	version := fs.String("version", "", "release version")
	notes := fs.String("notes", "", "release notes, one line")
	notesFile := fs.String("notes-file", "", "file whose first paragraph becomes the one line of notes, ignored when --notes is given")
	notesURL := fs.String("notes-url", "", "where the full changelog of this release lives")
	bundleURL := fs.String("bundle-url", "", "where kvsctl downloads the bundle")
	bundlePath := fs.String("bundle", "", "the bundle file, for its checksum")
	imageSpecs := fs.String("images", "", "service=ref or service@series=ref pairs; digests and sizes are read from the registry")
	digestSpec := fs.String("digests", "", "service[@series]=sha256:... the build reported; a digest the registry does not confirm is an error")
	previous := fs.String("previous", "", "existing manifest.json to extend")
	php := fs.String("php", "", "default PHP series of the release; the lowest published series when absent")
	phpSeries := fs.String("php-series", "", "every PHP series the release publishes images for; the published ones when absent")
	minFrom := fs.String("min-from", "", "oldest version that may upgrade directly")
	kvsMin := fs.String("kvs-min", "", "oldest KVS version supported")
	mariadbFrom := fs.String("mariadb-from", "", "on-disk MariaDB majors the release's image accepts, 11.4,11.8")
	composeMin := fs.String("compose-min", "", "oldest Docker Compose that reads the override, 2.24.0 for build: !reset null")
	database := fs.String("database", "", "none or migrates")
	oneWay := fs.Bool("one-way", false, "the release cannot be undone by restarting the previous images (a MariaDB major): the rollback recreates the volume and replays the dump, and --skip-backup becomes an error")
	cliSpec := fs.String("cli", "", "os-arch=url pairs of kvsctl binaries; their sha256 comes from --assets or from url+.sha256")
	assets := fs.String("assets", "", "directory holding the files named in --cli (by their base name) before they are published")
	channel := fs.String("channel", "stable", "channel name")
	fs.Parse(args)
	if len(keyPaths) == 0 || *version == "" || *bundleURL == "" || *bundlePath == "" {
		return errors.New("--key, --version, --bundle-url and --bundle are required")
	}
	if _, err := semver.Parse(*version); err != nil {
		return err
	}
	if len(highlights) > 3 {
		return fmt.Errorf("%d highlights: at most three fit the confirmation screen, the rest belongs behind --notes-url", len(highlights))
	}
	signers, err := loadSigners(keyPaths, keyIDs)
	if err != nil {
		return err
	}
	announced, err := parseAnnouncedKeys(announce)
	if err != nil {
		return err
	}
	channelSet := false
	fs.Visit(func(f *flag.Flag) {
		if f.Name == "channel" {
			channelSet = true
		}
	})
	m := &manifest.Manifest{Schema: manifest.Schema, Channel: *channel}
	if *previous != "" {
		data, err := os.ReadFile(*previous)
		if err != nil {
			return err
		}
		m, err = manifest.Parse(data)
		if err != nil {
			return err
		}
		m.Schema = manifest.Schema
		if channelSet || m.Channel == "" {
			m.Channel = *channel
		}
	}
	if len(announced) > 0 {
		m.Keys = announced
	}
	sum, size, err := fileSum(*bundlePath)
	if err != nil {
		return err
	}
	text := *notes
	if text == "" && *notesFile != "" {
		data, err := os.ReadFile(*notesFile)
		if err != nil {
			return err
		}
		text = firstParagraph(string(data))
	}
	rel := manifest.Release{
		Version:    *version,
		Date:       time.Now().UTC().Format("2006-01-02"),
		Notes:      text,
		NotesURL:   *notesURL,
		Highlights: highlights,
		Bundle:     manifest.Asset{URL: *bundleURL, SHA256: sum, Size: size},
		Requires: manifest.Requires{
			MinFrom:     *minFrom,
			PHP:         *php,
			KVSMin:      *kvsMin,
			MariaDBFrom: splitList(*mariadbFrom),
			ComposeMin:  *composeMin,
		},
		Database: *database,
		OneWay:   *oneWay,
	}
	specs, err := parseImages(*imageSpecs)
	if err != nil {
		return err
	}
	digests, err := parseDigests(*digestSpec)
	if err != nil {
		return err
	}
	for _, s := range specs {
		digest, imageSize, layers, err := registryDigest(s.Ref)
		if err != nil {
			return fmt.Errorf("%s: %w", s.Ref, err)
		}
		if want, ok := digests[s.Key()]; ok {
			if want != digest {
				return fmt.Errorf("%s: the build reported %s and the registry answers %s", s.Key(), want, digest)
			}
			delete(digests, s.Key())
		}
		img := manifest.Image{Service: s.Service, Ref: s.Ref, Digest: digest, Size: imageSize, Layers: layers}
		if s.Series == "" {
			rel.Images = append(rel.Images, img)
		} else {
			if rel.Variants == nil {
				rel.Variants = map[string]map[string][]manifest.Image{manifest.VariantPHP: {}}
			}
			rel.Variants[manifest.VariantPHP][s.Series] = append(rel.Variants[manifest.VariantPHP][s.Series], img)
		}
		fmt.Printf("%-18s %s %s %d bytes, %d layers\n", s.Key(), s.Ref, digest, imageSize, len(layers))
	}
	if len(digests) > 0 {
		return fmt.Errorf("--digests names %s, which --images does not build", strings.Join(sortedKeys(digests), ", "))
	}
	published := rel.Series()
	series := splitList(*phpSeries)
	if len(series) == 0 {
		series = published
	} else {
		for _, s := range published {
			if !slicesContains(series, s) {
				return fmt.Errorf("the release publishes images for PHP %s, which --php-series does not list", s)
			}
		}
	}
	rel.Requires.PHPSeries = series
	if rel.Requires.PHP == "" && len(published) > 0 {
		rel.Requires.PHP = published[0]
	}
	if *cliSpec != "" {
		rel.CLI = map[string]manifest.Asset{}
		for _, item := range fields(*cliSpec) {
			platform, url, ok := strings.Cut(item, "=")
			if !ok {
				return fmt.Errorf("cli %q is not os-arch=url", item)
			}
			sum, err := assetSum(url, *assets)
			if err != nil {
				return err
			}
			rel.CLI[platform] = manifest.Asset{URL: url, SHA256: sum}
		}
	}
	var releases []manifest.Release
	for _, r := range m.Releases {
		if r.Version != rel.Version {
			releases = append(releases, r)
		}
	}
	m.Releases = append(releases, rel)
	sort.SliceStable(m.Releases, func(i, j int) bool { return semver.Less(m.Releases[j].Version, m.Releases[i].Version) })
	m.Updated = time.Now().UTC().Format(time.RFC3339)
	raw, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		return err
	}
	if _, err := manifest.Parse(raw); err != nil {
		return err
	}
	if err := os.MkdirAll(*out, 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(*out, "manifest.json"), raw, 0o644); err != nil {
		return err
	}
	sig, err := signManifest(raw, signers)
	if err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(*out, "manifest.json.sig"), sig, 0o644); err != nil {
		return err
	}
	var ids []string
	for _, s := range signers {
		ids = append(ids, s.id)
	}
	fmt.Printf("%s: %d releases, latest %s, signed by %s\n", filepath.Join(*out, "manifest.json"), len(m.Releases), rel.Version, strings.Join(ids, ", "))
	return nil
}

func slicesContains(list []string, want string) bool {
	for _, item := range list {
		if item == want {
			return true
		}
	}
	return false
}

var refRe = regexp.MustCompile(`^(?:([^/]+\.[^/]+|[^/]+:[0-9]+|localhost)/)?([^:@]+)(?::([^@]+))?$`)

// registryDigest asks the registry for the digest, the compressed size and
// the layers of name:tag through the distribution API (anonymous token when
// asked). The diff IDs of the layers come from the image configuration.
func registryDigest(ref string) (string, int64, []manifest.Layer, error) {
	m := refRe.FindStringSubmatch(ref)
	if m == nil {
		return "", 0, nil, fmt.Errorf("cannot parse image reference %q", ref)
	}
	host, name, tag := m[1], m[2], m[3]
	if tag == "" {
		tag = "latest"
	}
	scheme := "https"
	switch {
	case host == "":
		host = "registry-1.docker.io"
		if !strings.Contains(name, "/") {
			name = "library/" + name
		}
	case strings.HasPrefix(host, "localhost") || strings.HasPrefix(host, "127.0.0.1"):
		scheme = "http"
	}
	base := fmt.Sprintf("%s://%s/v2/%s", scheme, host, name)
	accept := "application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json"
	body, headers, err := registryGet(base+"/manifests/"+tag, accept, "")
	if err != nil {
		return "", 0, nil, err
	}
	digest := headers.Get("Docker-Content-Digest")
	var doc struct {
		MediaType string `json:"mediaType"`
		Config    struct {
			Digest string `json:"digest"`
			Size   int64  `json:"size"`
		} `json:"config"`
		Layers []struct {
			Digest string `json:"digest"`
			Size   int64  `json:"size"`
		} `json:"layers"`
		Manifests []struct {
			Digest   string `json:"digest"`
			Platform struct {
				OS, Architecture string
			} `json:"platform"`
		} `json:"manifests"`
	}
	if err := json.Unmarshal(body, &doc); err != nil {
		return "", 0, nil, err
	}
	if len(doc.Manifests) > 0 {
		// A multi-platform index: keep the index digest (what docker pull
		// records) and read the linux/amd64 manifest for the layers.
		found := false
		for _, entry := range doc.Manifests {
			if entry.Platform.OS == "linux" && entry.Platform.Architecture == "amd64" {
				sub, _, err := registryGet(base+"/manifests/"+entry.Digest, accept, "")
				if err != nil {
					return "", 0, nil, err
				}
				if err := json.Unmarshal(sub, &doc); err != nil {
					return "", 0, nil, err
				}
				found = true
				break
			}
		}
		if !found {
			return "", 0, nil, errors.New("the index lists no linux/amd64 image")
		}
	}
	if digest == "" {
		sum := sha256.Sum256(body)
		digest = "sha256:" + hex.EncodeToString(sum[:])
	}
	if doc.Config.Digest == "" || len(doc.Layers) == 0 {
		return "", 0, nil, errors.New("the image manifest lists no configuration or no layer")
	}
	config, _, err := registryGet(base+"/blobs/"+doc.Config.Digest, "application/vnd.oci.image.config.v1+json, application/vnd.docker.container.image.v1+json, application/octet-stream", "")
	if err != nil {
		return "", 0, nil, fmt.Errorf("image configuration: %w", err)
	}
	var cfg struct {
		RootFS struct {
			DiffIDs []string `json:"diff_ids"`
		} `json:"rootfs"`
	}
	if err := json.Unmarshal(config, &cfg); err != nil {
		return "", 0, nil, fmt.Errorf("image configuration: %w", err)
	}
	if len(cfg.RootFS.DiffIDs) != len(doc.Layers) {
		return "", 0, nil, fmt.Errorf("the configuration lists %d diff ids for %d layers", len(cfg.RootFS.DiffIDs), len(doc.Layers))
	}
	size := doc.Config.Size
	var layers []manifest.Layer
	for n, l := range doc.Layers {
		size += l.Size
		layers = append(layers, manifest.Layer{Digest: l.Digest, DiffID: cfg.RootFS.DiffIDs[n], Size: l.Size})
	}
	return digest, size, layers, nil
}

func registryGet(url, accept, token string) ([]byte, http.Header, error) {
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return nil, nil, err
	}
	req.Header.Set("Accept", accept)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	client := &http.Client{Timeout: 60 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return nil, nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusUnauthorized && token == "" {
		// The registry names its token service: fetch an anonymous pull token.
		challenge := resp.Header.Get("WWW-Authenticate")
		realm, service, scope := authParam(challenge, "realm"), authParam(challenge, "service"), authParam(challenge, "scope")
		if realm == "" {
			return nil, nil, fmt.Errorf("%s: %s", url, resp.Status)
		}
		tokenBody, err := readURL(fmt.Sprintf("%s?service=%s&scope=%s", realm, service, scope))
		if err != nil {
			return nil, nil, err
		}
		var tokenDoc struct {
			Token       string `json:"token"`
			AccessToken string `json:"access_token"`
		}
		if err := json.Unmarshal(tokenBody, &tokenDoc); err != nil {
			return nil, nil, err
		}
		if tokenDoc.Token == "" {
			tokenDoc.Token = tokenDoc.AccessToken
		}
		return registryGet(url, accept, tokenDoc.Token)
	}
	if resp.StatusCode != http.StatusOK {
		return nil, nil, fmt.Errorf("%s: %s", url, resp.Status)
	}
	body, err := io.ReadAll(resp.Body)
	return body, resp.Header, err
}

func authParam(challenge, key string) string {
	re := regexp.MustCompile(key + `="([^"]*)"`)
	if m := re.FindStringSubmatch(challenge); m != nil {
		return m[1]
	}
	return ""
}

// assetSum is the sha256 of a file named in --cli: computed from the copy
// in the assets directory when one is given (the release assets are local
// when the manifest is signed), otherwise read from url+.sha256.
func assetSum(url, assets string) (string, error) {
	if assets != "" {
		local := filepath.Join(assets, filepath.Base(url))
		sum, _, err := fileSum(local)
		if err != nil {
			return "", fmt.Errorf("asset of %s: %w", url, err)
		}
		return sum, nil
	}
	shaBytes, err := readURL(url + ".sha256")
	if err != nil {
		return "", fmt.Errorf("%s.sha256: %w", url, err)
	}
	parts := strings.Fields(string(shaBytes))
	if len(parts) == 0 || len(parts[0]) != 64 {
		return "", fmt.Errorf("%s.sha256 holds no sha256", url)
	}
	return parts[0], nil
}

func readURL(url string) ([]byte, error) {
	if strings.HasPrefix(url, "file://") {
		return os.ReadFile(strings.TrimPrefix(url, "file://"))
	}
	client := &http.Client{Timeout: 60 * time.Second}
	resp, err := client.Get(url)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("%s: %s", url, resp.Status)
	}
	return io.ReadAll(resp.Body)
}

// verify checks a manifest file against its signature file with the public
// keys given, which is what the release workflow does with the previous
// manifest before building the next one on it.
func verify(args []string) error {
	fs := flag.NewFlagSet("verify", flag.ExitOnError)
	var pubs stringList
	manifestPath := fs.String("manifest", "", "manifest.json")
	sigPath := fs.String("signature", "", "manifest.json.sig")
	fs.Var(&pubs, "pub", "public key, base64 or id=base64; repeat it, one match is enough")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *manifestPath == "" || *sigPath == "" || len(pubs) == 0 {
		return errors.New("verify needs --manifest, --signature and at least one --pub")
	}
	raw, err := os.ReadFile(*manifestPath)
	if err != nil {
		return err
	}
	sig, err := os.ReadFile(*sigPath)
	if err != nil {
		return err
	}
	keys, err := manifest.ParseKeys(pubs)
	if err != nil {
		return err
	}
	doc, err := manifest.Load(raw, sig)
	if err != nil {
		return err
	}
	if err := doc.VerifyAny(keys); err != nil {
		return err
	}
	fmt.Printf("%s verified: schema %d, %d releases, latest %s, updated %s\n", *manifestPath, doc.Manifest.Schema, len(doc.Manifest.Releases), doc.Manifest.Latest().Version, doc.Manifest.Updated)
	return nil
}

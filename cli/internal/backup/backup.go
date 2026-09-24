// Package backup takes a database dump and the instance configuration
// before an upgrade, and restores the dump on request. The dump is
// streamed to disk through zstd and never held in memory: a real tube
// site has a multi-gigabyte database and the machine it runs on is
// usually small.
package backup

import (
	"archive/tar"
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/klauspost/compress/zstd"

	"github.com/MaximeMichaud/KVS-install/cli/internal/dockerx"
)

// Dump command run inside the MariaDB container; the password comes from
// the container's environment and never appears in a process list.
const dumpScript = `MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb-dump --single-transaction --quick --routines --triggers --events --default-character-set=utf8mb4 "$MARIADB_DATABASE"`

const restoreScript = `MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb "$MARIADB_DATABASE"`

// Format is the archive layout this build writes: a plain tar holding
// backup.json, the .env, the state and the compressed dump. Format 1 was
// the proof of concept, a .tar.zst holding a plain database.sql; it is
// still restored, for one release cycle.
const Format = 2

// Members of an archive.
const (
	metaName   = "backup.json"
	dumpName   = "database.sql.zst"
	legacyDump = "database.sql"
	envName    = ".env"
)

// stampLayout dates a backup file name, in UTC.
const stampLayout = "20060102-150405"

// ToolVersion is the kvsctl build recorded in backup.json; main sets it
// from its own version, and "unknown" stands for a build that does not.
var ToolVersion = "unknown"

// execFn runs a command inside a container. Tests replace it; everything
// else goes through the docker CLI as usual.
var execFn = dockerx.Exec

// Meta is backup.json: what the archive holds and where it comes from.
type Meta struct {
	Format          int       `json:"format"`
	Version         string    `json:"version"`
	Date            time.Time `json:"date"`
	Domain          string    `json:"domain,omitempty"`
	DumpBytes       int64     `json:"dump_bytes"`
	CompressedBytes int64     `json:"dump_compressed_bytes"`
	Tool            string    `json:"kvsctl"`
}

// Result describes a backup on disk.
type Result struct {
	Path     string
	Size     int64
	Duration time.Duration
}

// Info is one backup of a directory, as List reads it from the file name
// and, when the archive carries metadata, from backup.json.
type Info struct {
	Path    string
	Name    string
	Version string
	Date    time.Time
	Size    int64
	Domain  string
	// Legacy marks a proof-of-concept archive (.tar.zst).
	Legacy bool
}

// Create writes <dir>/backup-<version>-<stamp>.tar holding backup.json,
// the .env, the state file and database.sql.zst. The dump goes through
// zstd into a temporary file next to the archive, which is where its size
// comes from: a tar header needs it before the first byte of content.
func Create(ctx context.Context, dir, version, mariadbContainer, envPath, statePath string, report func(string)) (*Result, error) {
	start := time.Now()
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	path := filepath.Join(dir, fmt.Sprintf("backup-%s-%s.tar", version, start.UTC().Format(stampLayout)))
	dumpPath := path + ".dump.part"
	defer os.Remove(dumpPath)
	if report != nil {
		report("dumping the database")
	}
	raw, compressed, err := dumpTo(ctx, dumpPath, mariadbContainer)
	if err != nil {
		return nil, err
	}
	if raw == 0 {
		return nil, fmt.Errorf("the dump of %s is empty", mariadbContainer)
	}
	if report != nil {
		report(fmt.Sprintf("dumped %s, %s compressed", humanBytes(raw), humanBytes(compressed)))
	}
	meta := Meta{
		Format:          Format,
		Version:         version,
		Date:            start.UTC(),
		Domain:          domainOf(envPath),
		DumpBytes:       raw,
		CompressedBytes: compressed,
		Tool:            ToolVersion,
	}
	metaJSON, err := json.MarshalIndent(meta, "", "  ")
	if err != nil {
		return nil, err
	}
	tmp := path + ".part"
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return nil, err
	}
	tw := tar.NewWriter(f)
	fail := func(err error) (*Result, error) {
		tw.Close()
		f.Close()
		os.Remove(tmp)
		return nil, err
	}
	// backup.json comes first so reading what an archive holds never
	// walks past the dump.
	if err := addBytes(tw, metaName, append(metaJSON, '\n'), start); err != nil {
		return fail(err)
	}
	for _, extra := range []string{envPath, statePath} {
		data, err := os.ReadFile(extra)
		if err != nil {
			if errors.Is(err, os.ErrNotExist) {
				continue
			}
			return fail(err)
		}
		if err := addBytes(tw, filepath.Base(extra), data, start); err != nil {
			return fail(err)
		}
	}
	if err := addFile(tw, dumpName, dumpPath, compressed, start); err != nil {
		return fail(err)
	}
	if err := tw.Close(); err != nil {
		f.Close()
		os.Remove(tmp)
		return nil, err
	}
	if err := f.Close(); err != nil {
		os.Remove(tmp)
		return nil, err
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return nil, err
	}
	info, err := os.Stat(path)
	if err != nil {
		return nil, err
	}
	return &Result{Path: path, Size: info.Size(), Duration: time.Since(start)}, nil
}

// dumpTo streams mariadb-dump through zstd into path and returns the raw
// and the compressed size.
func dumpTo(ctx context.Context, path, mariadbContainer string) (raw, compressed int64, err error) {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return 0, 0, err
	}
	zw, err := zstd.NewWriter(f, zstd.WithEncoderLevel(zstd.SpeedDefault))
	if err != nil {
		f.Close()
		return 0, 0, err
	}
	counter := &countWriter{w: zw}
	if err := execFn(ctx, mariadbContainer, nil, counter, "sh", "-c", dumpScript); err != nil {
		zw.Close()
		f.Close()
		return 0, 0, err
	}
	if err := zw.Close(); err != nil {
		f.Close()
		return 0, 0, err
	}
	info, err := f.Stat()
	if err != nil {
		f.Close()
		return 0, 0, err
	}
	if err := f.Close(); err != nil {
		return 0, 0, err
	}
	return counter.n, info.Size(), nil
}

// RestoreDatabase replays the dump of a backup into the container,
// decompressed on the way in, one pipe from the file to mariadb.
func RestoreDatabase(ctx context.Context, path, mariadbContainer string) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	tr, closer, err := openArchive(f)
	if err != nil {
		return err
	}
	defer closer()
	for {
		hdr, err := tr.Next()
		if errors.Is(err, io.EOF) {
			return fmt.Errorf("%s holds no %s", path, dumpName)
		}
		if err != nil {
			return err
		}
		switch hdr.Name {
		case dumpName:
			zr, err := zstd.NewReader(tr)
			if err != nil {
				return err
			}
			defer zr.Close()
			return execFn(ctx, mariadbContainer, zr, io.Discard, "sh", "-c", restoreScript)
		case legacyDump:
			// The proof of concept wrote a .tar.zst holding a plain dump.
			return execFn(ctx, mariadbContainer, tr, io.Discard, "sh", "-c", restoreScript)
		}
	}
}

// RestoreEnv writes the .env an archive carries over the live one,
// atomically and with the mode the live file already has.
func RestoreEnv(ctx context.Context, path, envPath string) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	tr, closer, err := openArchive(f)
	if err != nil {
		return err
	}
	defer closer()
	for {
		hdr, err := tr.Next()
		if errors.Is(err, io.EOF) {
			return fmt.Errorf("%s holds no %s", path, envName)
		}
		if err != nil {
			return err
		}
		if hdr.Name != envName {
			continue
		}
		data, err := io.ReadAll(io.LimitReader(tr, 8<<20))
		if err != nil {
			return err
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		mode := os.FileMode(0o600)
		if info, err := os.Stat(envPath); err == nil {
			mode = info.Mode().Perm()
		}
		tmp := envPath + ".kvsctl.tmp"
		if err := os.WriteFile(tmp, data, mode); err != nil {
			return err
		}
		if err := os.Chmod(tmp, mode); err != nil {
			os.Remove(tmp)
			return err
		}
		if err := os.Rename(tmp, envPath); err != nil {
			os.Remove(tmp)
			return err
		}
		return nil
	}
}

// Describe reads backup.json and lists the members of an archive. A
// proof-of-concept archive has no metadata, so meta is nil there.
func Describe(path string) (*Meta, []string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, nil, err
	}
	defer f.Close()
	tr, closer, err := openArchive(f)
	if err != nil {
		return nil, nil, err
	}
	defer closer()
	var meta *Meta
	var names []string
	for {
		hdr, err := tr.Next()
		if errors.Is(err, io.EOF) {
			return meta, names, nil
		}
		if err != nil {
			return meta, names, err
		}
		names = append(names, hdr.Name)
		if hdr.Name != metaName {
			continue
		}
		data, err := io.ReadAll(io.LimitReader(tr, 64<<10))
		if err != nil {
			return nil, names, err
		}
		var m Meta
		if err := json.Unmarshal(data, &m); err != nil {
			return nil, names, fmt.Errorf("%s: %s is not valid JSON: %w", path, metaName, err)
		}
		meta = &m
	}
}

var nameRe = regexp.MustCompile(`^backup-(.+)-(\d{8}-\d{6})\.tar(\.zst)?$`)

// List reads the backups of a directory, newest first. Anything else the
// directory holds is skipped, including the .part files of a backup that
// was interrupted.
func List(dir string) ([]Info, error) {
	entries, err := os.ReadDir(dir)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var out []Info
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		m := nameRe.FindStringSubmatch(e.Name())
		if m == nil {
			continue
		}
		date, err := time.ParseInLocation(stampLayout, m[2], time.UTC)
		if err != nil {
			continue
		}
		stat, err := e.Info()
		if err != nil {
			continue
		}
		item := Info{
			Path:    filepath.Join(dir, e.Name()),
			Name:    e.Name(),
			Version: m[1],
			Date:    date,
			Size:    stat.Size(),
			Legacy:  m[3] != "",
		}
		if meta, _, err := Describe(item.Path); err == nil && meta != nil {
			item.Domain = meta.Domain
		}
		out = append(out, item)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Date.Equal(out[j].Date) {
			return out[i].Name > out[j].Name
		}
		return out[i].Date.After(out[j].Date)
	})
	return out, nil
}

// Latest is the newest backup of that version, or of any version when it
// is empty. It returns "" and no error when the directory holds none.
func Latest(dir, version string) (string, error) {
	list, err := List(dir)
	if err != nil {
		return "", err
	}
	for _, b := range list {
		if version == "" || b.Version == version {
			return b.Path, nil
		}
	}
	return "", nil
}

// Prune keeps the keep newest backups plus keepPath, and removes the rest
// along with the .part files of interrupted runs. It returns what it
// removed.
func Prune(dir string, keep int, keepPath string) (removed []string, err error) {
	if keep < 0 {
		keep = 0
	}
	list, err := List(dir)
	if err != nil {
		return nil, err
	}
	keepName := ""
	if keepPath != "" {
		keepName = filepath.Base(keepPath)
	}
	for i, b := range list {
		if i < keep || b.Name == keepName {
			continue
		}
		if err := os.Remove(b.Path); err != nil && !errors.Is(err, os.ErrNotExist) {
			return removed, err
		}
		removed = append(removed, b.Path)
	}
	entries, err := os.ReadDir(dir)
	if errors.Is(err, os.ErrNotExist) {
		return removed, nil
	}
	if err != nil {
		return removed, err
	}
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".part") {
			continue
		}
		path := filepath.Join(dir, e.Name())
		if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
			return removed, err
		}
		removed = append(removed, path)
	}
	return removed, nil
}

// openArchive reads either format: the plain tar this build writes, and
// the zstd compressed one of the proof of concept. The plain one keeps
// the file itself as the reader, so skipping a member is a seek and not a
// read of the whole dump.
func openArchive(f *os.File) (*tar.Reader, func(), error) {
	var magic [4]byte
	n, err := io.ReadFull(f, magic[:])
	if err != nil && !errors.Is(err, io.EOF) && !errors.Is(err, io.ErrUnexpectedEOF) {
		return nil, nil, err
	}
	if _, err := f.Seek(0, io.SeekStart); err != nil {
		return nil, nil, err
	}
	if n == 4 && magic == [4]byte{0x28, 0xb5, 0x2f, 0xfd} {
		zr, err := zstd.NewReader(f)
		if err != nil {
			return nil, nil, err
		}
		return tar.NewReader(zr), zr.Close, nil
	}
	return tar.NewReader(f), func() {}, nil
}

func addBytes(tw *tar.Writer, name string, data []byte, mod time.Time) error {
	if err := tw.WriteHeader(&tar.Header{Name: name, Mode: 0o600, Size: int64(len(data)), ModTime: mod, Typeflag: tar.TypeReg}); err != nil {
		return err
	}
	_, err := tw.Write(data)
	return err
}

func addFile(tw *tar.Writer, name, path string, size int64, mod time.Time) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	if err := tw.WriteHeader(&tar.Header{Name: name, Mode: 0o600, Size: size, ModTime: mod, Typeflag: tar.TypeReg}); err != nil {
		return err
	}
	n, err := io.Copy(tw, f)
	if err != nil {
		return err
	}
	if n != size {
		return fmt.Errorf("%s is %d bytes, expected %d", path, n, size)
	}
	return nil
}

// countWriter counts what goes through it, which is how the raw size of
// a dump is known without ever holding the dump.
type countWriter struct {
	w io.Writer
	n int64
}

func (c *countWriter) Write(p []byte) (int, error) {
	n, err := c.w.Write(p)
	c.n += int64(n)
	return n, err
}

// domainOf reads DOMAIN from an .env, so a backup says which site it
// belongs to without the rest of kvsctl.
func domainOf(path string) string {
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		key, value, ok := strings.Cut(strings.TrimSpace(scanner.Text()), "=")
		if !ok || strings.TrimSpace(key) != "DOMAIN" {
			continue
		}
		return strings.Trim(strings.TrimSpace(value), `"'`)
	}
	return ""
}

func humanBytes(n int64) string {
	const unit = 1000
	switch {
	case n >= unit*unit*unit:
		return fmt.Sprintf("%.2f GB", float64(n)/(unit*unit*unit))
	case n >= unit*unit:
		return fmt.Sprintf("%.0f MB", float64(n)/(unit*unit))
	case n >= unit:
		return fmt.Sprintf("%.0f kB", float64(n)/unit)
	default:
		return fmt.Sprintf("%d B", n)
	}
}

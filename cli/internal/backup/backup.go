// Package backup takes a database dump and the instance configuration
// before an upgrade, and restores the dump on request. The dump is
// streamed to disk through zstd and never held in memory: a real tube
// site has a multi-gigabyte database and the machine it runs on is
// usually small.
package backup

import (
	"archive/tar"
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/klauspost/compress/zstd"

	"github.com/MaximeMichaud/KVS-install/cli/internal/diskspace"
	"github.com/MaximeMichaud/KVS-install/cli/internal/dockerx"
)

// The commands below run inside the MariaDB container. The password comes
// from the container's environment and never appears in a process list.

// dumpScript dumps the database of the site in one transaction: a snapshot
// of every table at one point, which never holds the writes of the site.
const dumpScript = `MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb-dump --single-transaction --quick --routines --triggers --events --default-character-set=utf8mb4 "$MARIADB_DATABASE"`

// lockedDumpScript dumps a database that holds tables no transaction
// covers, MyISAM or Aria ones, which a site imported from an older server
// keeps: a snapshot would read each of them at another moment, and the
// archive would hold rows that point at rows it lacks. The dump locks every
// table of the database at once instead, so it reads them all at one point,
// as kvs-export.sh does for the same tables. The writes of the site wait
// until the dump ends and its reads go on. A global lock would also hold
// the other databases of the server and wait for every running query
// before it is granted, with the reads queued behind it; stopping the
// writers would take the whole site down for the length of the dump.
const lockedDumpScript = `MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb-dump --lock-tables --quick --routines --triggers --events --default-character-set=utf8mb4 "$MARIADB_DATABASE"`

// enginesScript counts the tables of the site on an engine that keeps no
// transactions, system-versioned ones included, and names those engines:
// "2<TAB>Aria, MyISAM". MEMORY tables do not count: their rows are gone at
// every restart of the server, so reading them at another moment loses
// nothing a restart would keep, and a single one would otherwise lock the
// whole site for every dump. Nor do sequences: one read later than the
// tables only gives a value past those they hold.
const enginesScript = `MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb --batch --skip-column-names -e "SELECT COUNT(*), COALESCE(GROUP_CONCAT(DISTINCT t.engine ORDER BY t.engine SEPARATOR ', '), '') FROM information_schema.tables t LEFT JOIN information_schema.engines e ON e.engine = t.engine WHERE t.table_schema = DATABASE() AND t.table_type IN ('BASE TABLE', 'SYSTEM VERSIONED') AND t.engine <> 'MEMORY' AND COALESCE(e.transactions, 'NO') <> 'YES'" "$MARIADB_DATABASE"`

// restoreScript replays what it reads into the database of the site:
// replayPreamble, then the dump.
const restoreScript = `MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb "$MARIADB_DATABASE"`

// replayPreamble comes before the dump in every replay. It takes a user
// lock whose name (the %s) lets probeScript find the connection of the
// replay, then empties the database: every table, view, sequence, routine
// and event goes, triggers with their tables, and the database itself stays
// with its character set and the grants on it. The dump creates again what
// it holds, so the database ends as the archive has it, without a table
// created since, and a replay cut short can run again from the start.
// Foreign keys are not checked while the tables go, as in the dump.
const replayPreamble = "DO GET_LOCK('%s', 0);\n" +
	"SET @kvsctl_foreign_key_checks = @@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS = 0;\n" +
	"DELIMITER ;;\n" +
	"BEGIN NOT ATOMIC\n" +
	"  FOR o IN (\n" +
	"    SELECT IF(table_type = 'VIEW', 'VIEW', 'TABLE') AS kind, table_name AS name FROM information_schema.tables\n" +
	"      WHERE table_schema = DATABASE() AND table_type IN ('BASE TABLE', 'SYSTEM VERSIONED', 'SEQUENCE', 'VIEW')\n" +
	"    UNION ALL SELECT routine_type, routine_name FROM information_schema.routines WHERE routine_schema = DATABASE()\n" +
	"    UNION ALL SELECT 'EVENT', event_name FROM information_schema.events WHERE event_schema = DATABASE()\n" +
	"  ) DO\n" +
	"    EXECUTE IMMEDIATE CONCAT('DROP ', o.kind, ' IF EXISTS `', REPLACE(o.name, '`', '``'), '`');\n" +
	"  END FOR;\n" +
	"END;;\n" +
	"DELIMITER ;\n" +
	"SET FOREIGN_KEY_CHECKS = @kvsctl_foreign_key_checks;\n"

// probeScript shows what the connection of a replay does, found by the
// user lock of replayPreamble, whose name is $1: one line with its command
// ("Query" while a statement runs, "Sleep" while it waits for input), the
// milliseconds it has spent in it and its state, and nothing once the
// connection is gone. The lock outlives LOCK TABLES, UNLOCK TABLES and the
// commits of the dump: only the end of the connection releases it.
const probeScript = `MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb --batch --skip-column-names -e "SELECT COMMAND, TIME_MS, STATE FROM information_schema.PROCESSLIST WHERE ID = IS_USED_LOCK('$1')"`

// endScript ends the connection of a replay that was stopped, found by its
// lock ($1), when the server still has it. Stopping a replay stops the
// docker CLI that ran it and not the mariadb client in the container,
// which goes on waiting for its statement, then runs what it had already
// read of the dump: behind a lock, whenever the lock goes, which may be in
// the middle of the next replay. A connection that ends between the lookup
// and the KILL is no error (1094, unknown thread).
const endScript = `MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb --batch --skip-column-names --delimiter=// -e "BEGIN NOT ATOMIC DECLARE id BIGINT UNSIGNED DEFAULT IS_USED_LOCK('$1'); DECLARE CONTINUE HANDLER FOR 1094 BEGIN END; IF id IS NOT NULL THEN EXECUTE IMMEDIATE CONCAT('KILL ', id); END IF; END"`

// sizeScript prints the bytes the tables of the site take, data and
// indexes, as information_schema counts them.
const sizeScript = `MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb --batch --skip-column-names -e 'SELECT CAST(COALESCE(SUM(data_length + index_length), 0) AS UNSIGNED) FROM information_schema.tables WHERE table_schema = DATABASE()' "$MARIADB_DATABASE"`

// dumpAttempts bounds the dumps a backup starts when a table changes its
// definition under the snapshot (error 1412): each attempt takes a new
// snapshot, which gets past a TRUNCATE or an ALTER that has finished.
const dumpAttempts = 3

// probeAttempts is how many questions in a row the server may leave
// without the connection of a replay, gone or not answered, before the
// replay counts as stalled: one docker exec that fails says little of a
// server at work, and stopping a replay that works costs it all.
const probeAttempts = 3

// Format is the archive layout this build writes and reads: a plain tar
// holding the compressed dump, the .env, the state and backup.json, which
// carries this number. Members are found by name, whatever their order.
const Format = 2

// Members of an archive.
const (
	metaName = "backup.json"
	dumpName = "database.sql.zst"
	envName  = ".env"
)

// blockSize is the tar block: every header is one, and every member's
// content is padded to a multiple of it.
const blockSize = 512

// stampLayout dates a backup file name, in UTC.
const stampLayout = "20060102-150405"

// ToolVersion is the kvsctl build recorded in backup.json; main sets it
// from its own version, and "unknown" stands for a build that does not.
var ToolVersion = "unknown"

// execFn runs a command inside a container. Tests replace it; everything
// else goes through the docker CLI as usual.
var execFn = dockerx.Exec

// flushDir flushes the directory an archive was renamed in. Tests replace
// it to fail once the archive has its name.
var flushDir = syncDir

// The bounds of a backup and of a replay. They are variables so the tests
// do not need gigabytes and minutes to reach them.
var (
	// progressInterval spaces the reports of a dump or a replay that is
	// still running.
	progressInterval = 30 * time.Second
	// stallTimeout ends a replay when the database took nothing from the
	// dump for that long and the server showed no statement of the replay
	// at work in that time: its connection idle, its statement waiting for
	// a lock or for room on the disk, or the connection gone. A replay has
	// no time limit otherwise: a big database takes as long as it takes,
	// and killing it half way would leave the site with half its tables.
	stallTimeout = 10 * time.Minute
	// probeTimeout bounds one question to the server about the connection
	// of a replay.
	probeTimeout = time.Minute
	// spaceCheckEvery is how much of the dump is written between two
	// checks of the free space.
	spaceCheckEvery int64 = 64 << 20
	// minFreeFloor and freeFloorPercent set the free space a backup never
	// takes its filesystem below: the larger of the two.
	minFreeFloor     int64 = 1 << 30
	freeFloorPercent int64 = 2
	// measureSpace reads the filesystem of the backup directory.
	measureSpace = diskspace.Measure
)

// Meta is backup.json: what the archive holds and where it comes from.
type Meta struct {
	Format  int    `json:"format"`
	Version string `json:"version"`
	// KVSVersion is the KVS version the site ran when the backup was
	// taken, as the files of the site give it; empty when it could not be
	// read. A replay takes the database back to the schema of that version,
	// whatever the files of the site run now.
	KVSVersion string    `json:"kvs_version,omitempty"`
	Date       time.Time `json:"date"`
	// Sequence numbers the archives of a backup directory in the order
	// they were written, from 1. It orders them where the date cannot: a
	// clock set back or ahead moves the date, never the sequence. Zero in
	// an archive written before kvsctl numbered them.
	Sequence        int64  `json:"sequence,omitempty"`
	Domain          string `json:"domain,omitempty"`
	DumpBytes       int64  `json:"dump_bytes"`
	CompressedBytes int64  `json:"dump_compressed_bytes"`
	Tool            string `json:"kvsctl"`
}

// Option adds to what Create records.
type Option func(*archiveInput)

// WithKVSVersion records the KVS version the site runs, so a replay can
// tell that it takes the database back across a KVS update. An empty
// version records nothing.
func WithKVSVersion(version string) Option {
	return func(in *archiveInput) { in.kvsVersion = version }
}

// WrittenError is a failure of Create once the archive has its name: the
// archive is complete at Path, but its name may not survive a power cut,
// or its size could not be read back. The archive stays, and a caller
// says so: this is no backup that left nothing behind.
type WrittenError struct {
	Path string
	// Err says what failed, after "but".
	Err error
}

func (e *WrittenError) Error() string { return fmt.Sprintf("%s is written but %v", e.Path, e.Err) }
func (e *WrittenError) Unwrap() error { return e.Err }

// Result describes a backup on disk.
type Result struct {
	Path     string
	Size     int64
	Duration time.Duration
}

// Info is one backup of a directory, as List reads it from the file name
// and from backup.json.
type Info struct {
	Path    string
	Name    string
	Version string
	Date    time.Time
	Size    int64
	Domain  string
	// KVSVersion and Sequence come from backup.json (see Meta), empty and
	// zero when the archive could not be read.
	KVSVersion string
	Sequence   int64
	// DumpBytes and CompressedBytes are the sizes of the dump, plain and
	// compressed, zero when the archive could not be read.
	DumpBytes, CompressedBytes int64
}

// Create writes <dir>/backup-<version>-<stamp>.tar: the dump of the
// database first, compressed as it streams out of mariadb-dump, then the
// .env, the state file and backup.json. The dump goes straight into the
// archive, so the disk never holds two copies of it: its tar header is a
// placeholder until the stream ends, then written over with the real size.
// While the dump streams, the free space of the filesystem is checked every
// 64 MiB, and the backup stops before it takes the filesystem below
// max(1 GiB, 2% of its size): the running database may live there too. The
// archive reaches the disk before it takes its name, and so does the name.
// report receives what the backup does, and how far the dump got at most
// every 30 seconds. The archive takes the next sequence number of the
// directory, which is what orders the archives. A failure once the
// archive has its name is a *WrittenError: the archive is on disk.
func Create(ctx context.Context, dir, version, mariadbContainer, envPath, statePath string, report func(string), opts ...Option) (*Result, error) {
	start := time.Now()
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	sequence, err := nextSequence(dir)
	if err != nil {
		return nil, err
	}
	path, err := freeName(dir, version, start)
	if err != nil {
		return nil, err
	}
	in := archiveInput{
		dir:       dir,
		version:   version,
		container: mariadbContainer,
		envPath:   envPath,
		statePath: statePath,
		start:     start,
		sequence:  sequence,
		report:    report,
	}
	for _, opt := range opts {
		opt(&in)
	}
	tmp := path + ".part"
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return nil, err
	}
	err = writeArchive(ctx, f, in)
	if err == nil {
		err = f.Sync()
	}
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err == nil {
		err = os.Rename(tmp, path)
	}
	if err != nil {
		os.Remove(tmp)
		return nil, err
	}
	if err := flushDir(dir); err != nil {
		return nil, &WrittenError{Path: path, Err: fmt.Errorf("its directory could not be flushed: %w", err)}
	}
	info, err := os.Stat(path)
	if err != nil {
		return nil, &WrittenError{Path: path, Err: fmt.Errorf("its size could not be read: %w", err)}
	}
	return &Result{Path: path, Size: info.Size(), Duration: time.Since(start)}, nil
}

// freeName names the archive after its version and its start, and moves
// the stamp a second on when a backup of the same second already took the
// name: a rename over it would replace that backup.
func freeName(dir, version string, start time.Time) (string, error) {
	for i := 0; i < 60; i++ {
		path := filepath.Join(dir, fmt.Sprintf("backup-%s-%s.tar", version, start.Add(time.Duration(i)*time.Second).UTC().Format(stampLayout)))
		_, err := os.Lstat(path)
		_, perr := os.Lstat(path + ".part")
		if errors.Is(err, os.ErrNotExist) && errors.Is(perr, os.ErrNotExist) {
			return path, nil
		}
	}
	return "", fmt.Errorf("no free backup name in %s for %s", dir, start.UTC().Format(stampLayout))
}

// nextSequence is the sequence number of the next archive of dir: one more
// than the highest the archives there carry, so a new archive comes after
// every one of them whatever their dates say.
func nextSequence(dir string) (int64, error) {
	list, err := List(dir)
	if err != nil {
		return 0, err
	}
	var highest int64
	for _, b := range list {
		highest = max(highest, b.Sequence)
	}
	return highest + 1, nil
}

// archiveInput is what goes into one archive.
type archiveInput struct {
	dir, version, container, envPath, statePath string
	kvsVersion                                  string
	start                                       time.Time
	sequence                                    int64
	report                                      func(string)
}

// say hands a line to the report of the backup, when it has one.
func (in archiveInput) say(msg string) {
	if in.report != nil {
		in.report(msg)
	}
}

// writeArchive writes the members into f, which is empty.
func writeArchive(ctx context.Context, f *os.File, in archiveInput) error {
	placeholder, err := dumpHeader(0, in.start)
	if err != nil {
		return err
	}
	if _, err := f.Write(placeholder); err != nil {
		return err
	}
	script, err := chooseDump(ctx, in)
	if err != nil {
		return err
	}
	in.say("dumping the database")
	var raw, compressed int64
	for attempt := 1; ; attempt++ {
		raw, compressed, err = dumpInto(ctx, f, in, script)
		table, changed := definitionChanged(err)
		if !changed || ctx.Err() != nil {
			break
		}
		if attempt == dumpAttempts {
			err = fmt.Errorf("the dump stopped %d times in a row on a table whose definition changed while it read the database (error 1412), the last time on %s: something empties or rebuilds tables (TRUNCATE, ALTER, OPTIMIZE) more often than a dump lasts; take the backup once that is over: %w", dumpAttempts, table, err)
			break
		}
		in.say(fmt.Sprintf("%s changed its definition while the dump read the database (error 1412, a TRUNCATE, ALTER or OPTIMIZE of it): the dump starts again, attempt %d of %d", table, attempt+1, dumpAttempts))
		// The next attempt writes over what this one wrote, behind the
		// placeholder.
		if err := f.Truncate(blockSize); err != nil {
			return err
		}
		if _, err := f.Seek(blockSize, io.SeekStart); err != nil {
			return err
		}
	}
	if err != nil {
		return err
	}
	if raw == 0 {
		return fmt.Errorf("the dump of %s is empty", in.container)
	}
	in.say(fmt.Sprintf("dumped %s, %s compressed", humanBytes(raw), humanBytes(compressed)))
	return finishArchive(f, raw, compressed, in)
}

// chooseDump picks the dump that reads every table of the database at one
// point: one transaction when every table takes part in transactions, a
// lock of the tables when some do not, which the operator is told since
// the writes of the site then wait.
func chooseDump(ctx context.Context, in archiveInput) (string, error) {
	var out bytes.Buffer
	if err := execFn(ctx, in.container, nil, &out, "sh", "-c", enginesScript); err != nil {
		return "", fmt.Errorf("the engines of the tables in %s could not be read: %w", in.container, err)
	}
	line := strings.TrimRight(out.String(), "\r\n")
	count, engines, _ := strings.Cut(line, "\t")
	n, err := strconv.Atoi(strings.TrimSpace(count))
	if err != nil || n < 0 {
		return "", fmt.Errorf("the engines of the tables in %s could not be read: the database answered %q", in.container, excerpt(line))
	}
	if n == 0 {
		return dumpScript, nil
	}
	tables := fmt.Sprintf("%d tables", n)
	if n == 1 {
		tables = "1 table"
	}
	if engines = strings.TrimSpace(engines); engines != "" {
		engines = " (" + engines + ")"
	}
	in.say(fmt.Sprintf("the database holds %s without transactions%s: the dump locks every table to read them all at one point, so the writes of the site wait until it ends", tables, engines))
	return lockedDumpScript, nil
}

// definitionChangedRe and changedTableRe read a dump that error 1412 ended:
// a table whose definition changed after the snapshot of the dump was
// taken, which mariadb-dump names whether it was dumping its rows or
// reading its definition.
var (
	definitionChangedRe = regexp.MustCompile(`Error 1412\b|\(1412\)`)
	changedTableRe      = regexp.MustCompile("(?i)(?:when dumping table|show create table) (`(?:[^`]|``)*`)")
)

// definitionChanged reports whether err is a dump that error 1412 ended,
// and the table it names ("a table" when it names none).
func definitionChanged(err error) (string, bool) {
	if err == nil || !definitionChangedRe.MatchString(err.Error()) {
		return "", false
	}
	if m := changedTableRe.FindStringSubmatch(err.Error()); m != nil {
		return "table " + m[1], true
	}
	return "a table", true
}

// finishArchive closes the dump member, which ends where f stands: its
// content is padded to a block and its real header goes over the
// placeholder. Then come the other members and the end of the archive.
func finishArchive(f *os.File, raw, compressed int64, in archiveInput) error {
	if pad := (blockSize - compressed%blockSize) % blockSize; pad > 0 {
		if _, err := f.Write(make([]byte, pad)); err != nil {
			return err
		}
	}
	header, err := dumpHeader(compressed, in.start)
	if err != nil {
		return err
	}
	if _, err := f.WriteAt(header, 0); err != nil {
		return err
	}
	tw := tar.NewWriter(f)
	for _, extra := range []string{in.envPath, in.statePath} {
		if extra == "" {
			continue
		}
		data, err := os.ReadFile(extra)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return err
		}
		if err := addBytes(tw, filepath.Base(extra), data, in.start); err != nil {
			return err
		}
	}
	meta, err := json.MarshalIndent(Meta{
		Format:          Format,
		Version:         in.version,
		KVSVersion:      in.kvsVersion,
		Date:            in.start.UTC(),
		Sequence:        in.sequence,
		Domain:          domainOf(in.envPath),
		DumpBytes:       raw,
		CompressedBytes: compressed,
		Tool:            ToolVersion,
	}, "", "  ")
	if err != nil {
		return err
	}
	if err := addBytes(tw, metaName, append(meta, '\n'), in.start); err != nil {
		return err
	}
	return tw.Close()
}

// dumpInto streams the dump script through zstd into f and returns the raw
// and the compressed size. A single encoder thread keeps the CPU for the
// database, which goes on serving the site, and still outruns the dump.
func dumpInto(ctx context.Context, f *os.File, in archiveInput, script string) (raw, compressed int64, err error) {
	ctx, cancel := context.WithCancelCause(ctx)
	defer cancel(nil)
	guard := &spaceGuard{w: f, dir: in.dir, report: in.report, cancel: cancel, lastReport: time.Now()}
	if err := guard.check(); err != nil {
		return 0, 0, err
	}
	zw, err := zstd.NewWriter(guard, zstd.WithEncoderLevel(zstd.SpeedDefault), zstd.WithEncoderConcurrency(1))
	if err != nil {
		return 0, 0, err
	}
	counter := &countWriter{w: zw}
	guard.raw = &counter.n
	err = execFn(ctx, in.container, nil, counter, "sh", "-c", script)
	if cerr := zw.Close(); err == nil {
		err = cerr
	}
	// Out of room is why the dump stopped, whatever the docker CLI said
	// once its output was cut.
	if gerr := guard.failure(); gerr != nil {
		return 0, 0, gerr
	}
	if err != nil {
		return 0, 0, err
	}
	return counter.n.Load(), guard.written(), nil
}

// spaceGuard writes the compressed dump into the archive, checks the free
// space of the filesystem every spaceCheckEvery bytes, and reports how far
// the dump got at most every progressInterval.
type spaceGuard struct {
	mu         sync.Mutex
	w          io.Writer
	dir        string
	n          int64
	nextCheck  int64
	raw        *atomic.Int64
	report     func(string)
	lastReport time.Time
	cancel     context.CancelCauseFunc
	err        error
}

func (g *spaceGuard) Write(p []byte) (int, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.err != nil {
		return 0, g.err
	}
	n, err := g.w.Write(p)
	g.n += int64(n)
	if err != nil {
		return n, err
	}
	if g.n >= g.nextCheck {
		if err := g.checkLocked(); err != nil {
			return n, err
		}
	}
	if g.report != nil && time.Since(g.lastReport) >= progressInterval {
		g.lastReport = time.Now()
		dumped := int64(0)
		if g.raw != nil {
			dumped = g.raw.Load()
		}
		g.report(fmt.Sprintf("dumped %s so far, %s compressed", humanBytes(dumped), humanBytes(g.n)))
	}
	return n, nil
}

// check measures the filesystem before the first byte.
func (g *spaceGuard) check() error {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.checkLocked()
}

// checkLocked stops the dump when the filesystem is below its floor. A
// filesystem that cannot be measured does not stop a backup: that says
// nothing about the room left.
func (g *spaceGuard) checkLocked() error {
	g.nextCheck = g.n + spaceCheckEvery
	space, err := measureSpace(g.dir)
	if err != nil {
		return nil
	}
	floor := max(minFreeFloor, space.Size*freeFloorPercent/100)
	if space.Avail >= floor {
		return nil
	}
	g.err = fmt.Errorf("only %s left on the filesystem of %s, which the running database may share: a backup stops below %s, so this one stopped after %s and its partial file is removed", humanBytes(space.Avail), g.dir, humanBytes(floor), humanBytes(g.n))
	if g.cancel != nil {
		g.cancel(g.err)
	}
	return g.err
}

func (g *spaceGuard) failure() error {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.err
}

func (g *spaceGuard) written() int64 {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.n
}

// dumpHeader is the tar header of the dump: one block in the GNU format,
// whatever the size. The dump streams in behind a placeholder, and this
// block is written over it once the size is known, so it must never grow:
// GNU writes a size of 8 GiB and more in base-256 within the same block,
// where the default format would add a PAX block in front and shift every
// byte of the dump.
func dumpHeader(size int64, mod time.Time) ([]byte, error) {
	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)
	hdr := &tar.Header{
		Name:     dumpName,
		Mode:     0o600,
		Size:     size,
		ModTime:  mod.UTC().Truncate(time.Second),
		Typeflag: tar.TypeReg,
		Format:   tar.FormatGNU,
	}
	if err := tw.WriteHeader(hdr); err != nil {
		return nil, err
	}
	if buf.Len() != blockSize {
		return nil, fmt.Errorf("the header of %s takes %d bytes, not one block", dumpName, buf.Len())
	}
	return buf.Bytes(), nil
}

// archive is an open backup: where the content of each member starts,
// read from the headers alone, and its backup.json. The archive is a plain
// tar, so stepping over the dump is a seek, not a read of gigabytes.
type archive struct {
	f       *os.File
	path    string
	names   []string
	members map[string]member
	meta    Meta
}

type member struct{ offset, size int64 }

func openArchive(path string) (*archive, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	a := &archive{f: f, path: path, members: map[string]member{}}
	if err := a.index(); err != nil {
		f.Close()
		return nil, err
	}
	return a, nil
}

func (a *archive) index() error {
	tr := tar.NewReader(a.f)
	for {
		hdr, err := tr.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return fmt.Errorf("%s: %w", a.path, err)
		}
		offset, err := a.f.Seek(0, io.SeekCurrent)
		if err != nil {
			return err
		}
		a.names = append(a.names, hdr.Name)
		if hdr.Typeflag == tar.TypeReg {
			a.members[hdr.Name] = member{offset: offset, size: hdr.Size}
		}
	}
	data, err := a.read(metaName, 64<<10)
	if err != nil {
		return err
	}
	if err := json.Unmarshal(data, &a.meta); err != nil {
		return fmt.Errorf("%s: %s is not valid JSON: %w", a.path, metaName, err)
	}
	if a.meta.Format != Format {
		return fmt.Errorf("%s is a backup of format %d, and this kvsctl reads format %d", a.path, a.meta.Format, Format)
	}
	return nil
}

// section is the content of a member, read independently of the others.
func (a *archive) section(name string) (*io.SectionReader, error) {
	m, ok := a.members[name]
	if !ok {
		return nil, fmt.Errorf("%s holds no %s: it is not a kvsctl backup", a.path, name)
	}
	return io.NewSectionReader(a.f, m.offset, m.size), nil
}

// read returns a small member whole, refusing one larger than limit.
func (a *archive) read(name string, limit int64) ([]byte, error) {
	r, err := a.section(name)
	if err != nil {
		return nil, err
	}
	if r.Size() > limit {
		return nil, fmt.Errorf("%s: %s is %d bytes, more than a kvsctl backup ever holds", a.path, name, r.Size())
	}
	return io.ReadAll(r)
}

func (a *archive) Close() error { return a.f.Close() }

// RestoreDatabase makes the database of the container what the archive
// holds: it empties the database, then replays the dump of the archive,
// decompressed on the way in, one pipe from the file to mariadb (see
// replayPreamble). A dump that holds nothing, or cannot be read from its
// start, is refused before the database is touched. progress, when set,
// receives the bytes of the dump replayed so far and the size backup.json
// gives the whole dump, at most every 30 seconds; it may be called from
// another goroutine. The replay has no time limit while the server works
// on it: one slow statement, an index rebuilt on a large table, is waited
// for. It is stopped once the database took nothing from the dump for 10
// minutes and the server showed no statement of the replay at work in that
// time: its connection idle, its statement waiting for a lock another
// connection keeps or for room on a full disk, or the connection not shown
// when asked three times. A replay that is stopped, by this or by the end
// of ctx, has its connection ended on the server too, so nothing of it
// runs afterwards.
func RestoreDatabase(ctx context.Context, path, mariadbContainer string, progress func(replayed, total int64)) error {
	a, err := openArchive(path)
	if err != nil {
		return err
	}
	defer a.Close()
	dump, err := a.section(dumpName)
	if err != nil {
		return err
	}
	zr, err := zstd.NewReader(dump, zstd.WithDecoderConcurrency(1))
	if err != nil {
		return err
	}
	defer zr.Close()
	// The preamble empties the database before the first statement of the
	// dump runs: a dump that cannot even start must not get that far.
	body := bufio.NewReader(zr)
	if _, err := body.Peek(1); errors.Is(err, io.EOF) {
		return fmt.Errorf("the dump of %s is empty: the database was not touched", filepath.Base(path))
	} else if err != nil {
		return fmt.Errorf("the dump of %s cannot be read, the database was not touched: %w", filepath.Base(path), err)
	}
	ctx, cancel := context.WithCancelCause(ctx)
	defer cancel(nil)
	// The questions to the server end with the replay.
	probeCtx, endProbes := context.WithCancel(ctx)
	defer endProbes()
	// A name no other connection holds: the server answers who holds it.
	lock := fmt.Sprintf("kvsctl-replay-%d-%d", os.Getpid(), time.Now().UnixNano())
	in := &replayReader{r: body, total: a.meta.DumpBytes, progress: progress, start: time.Now()}
	in.lastReport = in.start
	stop := make(chan struct{})
	watched := make(chan struct{})
	go func() {
		defer close(watched)
		in.watch(cancel, stop, func() sight { return serverSight(probeCtx, mariadbContainer, lock) })
	}()
	stdin := io.MultiReader(strings.NewReader(fmt.Sprintf(replayPreamble, lock)), in)
	err = execFn(ctx, mariadbContainer, stdin, io.Discard, "sh", "-c", restoreScript)
	close(stop)
	endProbes()
	<-watched
	if err != nil {
		var stalled *stallError
		if errors.As(context.Cause(ctx), &stalled) {
			err = stalled
		}
		if ctx.Err() != nil {
			if eerr := endConnection(ctx, mariadbContainer, lock); eerr != nil {
				err = fmt.Errorf("%w; its connection to the database could not be ended (%v), and the server may still run its last statement: end it, or restart the MariaDB container, before the archive is replayed again", err, eerr)
			}
		}
		return err
	}
	if !in.eof.Load() {
		return fmt.Errorf("mariadb ended at %s of the %s dump of %s without an error: the replay is incomplete", humanBytes(in.replayed.Load()), humanBytes(in.total), filepath.Base(path))
	}
	return nil
}

// replayReader feeds the dump to mariadb, counting what it takes and when
// it last took anything.
type replayReader struct {
	r          io.Reader
	total      int64
	progress   func(replayed, total int64)
	lastReport time.Time
	replayed   atomic.Int64
	// start is when the replay began. last is how long after start the
	// replay last moved, a read that gave the database bytes or a
	// statement the server showed at work on it: the monotonic clock, which
	// a change of the system time does not move. eof is set once the
	// database had the whole dump.
	start time.Time
	last  atomic.Int64
	eof   atomic.Bool
}

func (r *replayReader) Read(p []byte) (int, error) {
	n, err := r.r.Read(p)
	if n > 0 {
		r.moved(time.Since(r.start))
		replayed := r.replayed.Add(int64(n))
		if r.progress != nil && time.Since(r.lastReport) >= progressInterval {
			r.lastReport = time.Now()
			r.progress(replayed, r.total)
		}
	}
	if errors.Is(err, io.EOF) {
		r.eof.Store(true)
	}
	return n, err
}

// moved records that the replay moved at, after start, unless it is known
// to have moved later.
func (r *replayReader) moved(at time.Duration) {
	for {
		last := r.last.Load()
		if int64(at) <= last || r.last.CompareAndSwap(last, int64(at)) {
			return
		}
	}
}

// watch cancels the replay once it did not move for stallTimeout: the
// database took nothing from the dump, and the server showed no statement
// of the replay at work for that long, or could not show its connection
// probeAttempts times in a row. mariadb reads no input while a statement
// runs, however long the server takes over it, so a statement at work is
// progress, and so is the start of one, which ends the one before it: a
// connection idle, or a statement waiting, for less than stallTimeout is
// no stall. A statement that waits for what the replay does not control,
// a lock another connection keeps or room on a full disk, is not at work:
// the server lets it wait a day for the lock (lock_wait_timeout) and
// forever for the room, and nothing else would end the replay. Once the
// whole dump is handed over, what is left is the work of the server on its
// last statements, which is not watched.
func (r *replayReader) watch(cancel context.CancelCauseFunc, stop <-chan struct{}, look func() sight) {
	every := min(max(stallTimeout/20, 10*time.Millisecond), 30*time.Second)
	tick := time.NewTicker(every)
	defer tick.Stop()
	// unseen counts the questions in a row the server did not answer with
	// the connection of the replay.
	unseen := 0
	for {
		select {
		case <-stop:
			return
		case <-tick.C:
		}
		if r.eof.Load() {
			return
		}
		if r.still() < stallTimeout {
			unseen = 0
			continue
		}
		seen := look()
		select {
		case <-stop:
			// The replay ended while the server was asked.
			return
		default:
		}
		var why string
		switch {
		case seen.missing != "":
			if unseen++; unseen < probeAttempts {
				continue
			}
			why = seen.missing
		case seen.working():
			unseen = 0
			r.moved(time.Since(r.start))
			continue
		default:
			unseen = 0
			// The connection went idle, or the statement that waits
			// began, when the statement before it ended.
			r.moved(time.Since(r.start) - seen.since)
			if r.still() < stallTimeout {
				continue
			}
			why = seen.idle()
		}
		cancel(&stallError{idle: stallTimeout, replayed: r.replayed.Load(), total: r.total, why: why})
		return
	}
}

// still is how long the replay has not moved.
func (r *replayReader) still() time.Duration {
	return time.Since(r.start) - time.Duration(r.last.Load())
}

// sight is what the server showed of the connection of a replay.
type sight struct {
	// command and state are those of the process list: "Sleep" while the
	// connection waits for input, "Query" and what the statement does
	// while one runs.
	command, state string
	// since is how long the connection has been in its command: running
	// its statement, or idle since the last one ended.
	since time.Duration
	// missing says why the server did not show the connection, empty when
	// it did.
	missing string
}

// working tells a statement at work from an idle connection and from a
// statement that waits for something outside the replay, whose state
// says so: "Waiting for table metadata lock", "Waiting for table level
// lock", "Waiting for someone to free space" and the like, or "User lock".
func (s sight) working() bool {
	return s.command != "Sleep" && !strings.HasPrefix(s.state, "Waiting") && s.state != "User lock"
}

// idle says what the server showed of a replay that did not move.
func (s sight) idle() string {
	if s.command == "Sleep" {
		return "the connection of the replay has waited for input for " + roundIdle(s.since).String()
	}
	return fmt.Sprintf("the server shows the statement of the replay, begun %s ago, waiting (%s)", roundIdle(s.since), s.state)
}

// serverSight asks the server what the connection of the replay, which
// holds lock, does. When the server does not show the connection, because
// it is gone or the server does not answer, missing says so.
func serverSight(ctx context.Context, container, lock string) sight {
	ctx, cancel := context.WithTimeout(ctx, probeTimeout)
	defer cancel()
	var out bytes.Buffer
	if err := execFn(ctx, container, nil, &out, "sh", "-c", probeScript, "sh", lock); err != nil {
		return sight{missing: fmt.Sprintf("the database did not say whether the replay runs (%v)", err)}
	}
	line := strings.TrimRight(out.String(), "\r\n")
	if line == "" {
		return sight{missing: "the replay has no connection to the database any more"}
	}
	fields := strings.Split(line, "\t")
	if len(fields) < 2 {
		return sight{missing: fmt.Sprintf("the database answered %q about the replay", excerpt(line))}
	}
	ms, err := strconv.ParseFloat(fields[1], 64)
	if err != nil || ms < 0 {
		return sight{missing: fmt.Sprintf("the database answered %q about the replay", excerpt(line))}
	}
	seen := sight{command: fields[0], since: time.Duration(ms * float64(time.Millisecond))}
	if len(fields) > 2 {
		seen.state = fields[2]
	}
	return seen
}

// endConnection ends the connection of a replay that was stopped, when the
// server still has it (see endScript). ctx has ended by then: the question
// gets a bound of its own.
func endConnection(ctx context.Context, container, lock string) error {
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), probeTimeout)
	defer cancel()
	return execFn(ctx, container, nil, io.Discard, "sh", "-c", endScript, "sh", lock)
}

// roundIdle is d to the second, or to the millisecond under a second.
func roundIdle(d time.Duration) time.Duration {
	if d >= time.Second {
		return d.Round(time.Second)
	}
	return d.Round(time.Millisecond)
}

// stallError ends a replay the database stopped taking.
type stallError struct {
	idle            time.Duration
	replayed, total int64
	// why is what the server showed of the replay.
	why string
}

func (e *stallError) Error() string {
	msg := fmt.Sprintf("the database took nothing from the dump for %s, at %s of %s", e.idle, humanBytes(e.replayed), humanBytes(e.total))
	if e.why != "" {
		msg += ", and " + e.why
	}
	return msg + ": the replay was stopped, the archive is intact"
}

// RestoreEnv writes the .env an archive carries over the live one,
// atomically and with the mode the live file already has.
func RestoreEnv(ctx context.Context, path, envPath string) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	data, err := ArchivedEnv(path)
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
	if err := writeSynced(tmp, data, mode); err != nil {
		os.Remove(tmp)
		return err
	}
	if err := os.Rename(tmp, envPath); err != nil {
		os.Remove(tmp)
		return err
	}
	return syncDir(filepath.Dir(envPath))
}

// ArchivedEnv is the .env an archive carries, as it was when the backup
// was taken.
func ArchivedEnv(path string) ([]byte, error) {
	a, err := openArchive(path)
	if err != nil {
		return nil, err
	}
	defer a.Close()
	return a.read(envName, 8<<20)
}

// Describe reads backup.json and lists the members of an archive, in the
// order the archive holds them.
func Describe(path string) (*Meta, []string, error) {
	a, err := openArchive(path)
	if err != nil {
		return nil, nil, err
	}
	defer a.Close()
	meta := a.meta
	return &meta, a.names, nil
}

// DatabaseSize is what the tables of the site take in the container, data
// and indexes, as information_schema counts them: about what a replay
// writes again, and what a dump is a fraction of.
func DatabaseSize(ctx context.Context, mariadbContainer string) (int64, error) {
	var out bytes.Buffer
	if err := execFn(ctx, mariadbContainer, nil, &out, "sh", "-c", sizeScript); err != nil {
		return 0, err
	}
	size, err := strconv.ParseInt(strings.TrimSpace(out.String()), 10, 64)
	if err != nil {
		return 0, fmt.Errorf("the size of the database in %s is not a number: %q", mariadbContainer, strings.TrimSpace(out.String()))
	}
	return size, nil
}

var nameRe = regexp.MustCompile(`^backup-(.+)-(\d{8}-\d{6})\.tar$`)

// List reads the backups of a directory, the last written first (see
// newer). Anything else the directory holds is skipped, including the
// .part files of a backup that was interrupted.
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
		}
		if meta, _, err := Describe(item.Path); err == nil {
			item.Domain, item.DumpBytes, item.CompressedBytes = meta.Domain, meta.DumpBytes, meta.CompressedBytes
			item.KVSVersion, item.Sequence = meta.KVSVersion, meta.Sequence
		}
		out = append(out, item)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].newer(out[j]) })
	return out, nil
}

// newer orders two archives: by their sequence, which a clock set back or
// ahead does not move, then by the date of their name. An archive without
// a sequence was written before kvsctl numbered them, so before every
// archive that has one.
func (b Info) newer(than Info) bool {
	switch {
	case b.Sequence != than.Sequence:
		return b.Sequence > than.Sequence
	case !b.Date.Equal(than.Date):
		return b.Date.After(than.Date)
	}
	return b.Name > than.Name
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

// Prune keeps the keep newest backups plus every one of keepPaths, and
// removes the rest along with the .part files of interrupted runs. It
// returns what it removed. keepPaths are the archives something still
// needs whatever their age: the one a run just took, and the one a manual
// rollback of the installed version would replay.
func Prune(dir string, keep int, keepPaths ...string) (removed []string, err error) {
	if keep < 0 {
		keep = 0
	}
	list, err := List(dir)
	if err != nil {
		return nil, err
	}
	kept := map[string]bool{}
	for _, path := range keepPaths {
		if path != "" {
			kept[filepath.Base(path)] = true
		}
	}
	for i, b := range list {
		if i < keep || kept[b.Name] {
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

func addBytes(tw *tar.Writer, name string, data []byte, mod time.Time) error {
	if err := tw.WriteHeader(&tar.Header{Name: name, Mode: 0o600, Size: int64(len(data)), ModTime: mod.UTC().Truncate(time.Second), Typeflag: tar.TypeReg}); err != nil {
		return err
	}
	_, err := tw.Write(data)
	return err
}

// writeSynced writes a file and flushes it to disk before it is closed.
func writeSynced(path string, data []byte, mode os.FileMode) error {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, mode)
	if err != nil {
		return err
	}
	_, err = f.Write(data)
	if err == nil {
		err = f.Chmod(mode)
	}
	if err == nil {
		err = f.Sync()
	}
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	return err
}

// syncDir flushes a directory, which is what makes a rename in it survive
// a power cut.
func syncDir(dir string) error {
	d, err := os.Open(dir)
	if err != nil {
		return err
	}
	defer d.Close()
	return d.Sync()
}

// countWriter counts what goes through it, which is how the raw size of
// a dump is known without ever holding the dump.
type countWriter struct {
	w io.Writer
	n atomic.Int64
}

func (c *countWriter) Write(p []byte) (int, error) {
	n, err := c.w.Write(p)
	c.n.Add(int64(n))
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

// excerpt is the start of an answer that was not the one expected, short
// enough to quote in a message.
func excerpt(s string) string {
	const most = 200
	if len(s) <= most {
		return s
	}
	return s[:most] + "..."
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

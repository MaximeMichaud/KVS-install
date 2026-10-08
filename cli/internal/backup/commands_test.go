package backup

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/klauspost/compress/zstd"
)

// The commands a backup and a replay run in the MariaDB container, written
// out here rather than taken from the package: an edit of one of them has
// to be made twice, here on purpose. What they must keep: the password in
// the environment and never on a command line, the database of the site and
// no other, routines, triggers and events, utf8mb4, one point in time for
// every table, a replay that stops at the first error, and the connection
// of a replay that was stopped ended on the server.
const (
	wantEngines = `MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb --batch --skip-column-names -e "SELECT COUNT(*), COALESCE(GROUP_CONCAT(DISTINCT t.engine ORDER BY t.engine SEPARATOR ', '), '') FROM information_schema.tables t LEFT JOIN information_schema.engines e ON e.engine = t.engine WHERE t.table_schema = DATABASE() AND t.table_type IN ('BASE TABLE', 'SYSTEM VERSIONED') AND t.engine <> 'MEMORY' AND COALESCE(e.transactions, 'NO') <> 'YES'" "$MARIADB_DATABASE"`
	wantDump    = `MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb-dump --single-transaction --quick --routines --triggers --events --default-character-set=utf8mb4 "$MARIADB_DATABASE"`
	wantLocked  = `MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb-dump --lock-tables --quick --routines --triggers --events --default-character-set=utf8mb4 "$MARIADB_DATABASE"`
	wantReplay  = `MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb "$MARIADB_DATABASE"`
	wantProbe   = `MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb --batch --skip-column-names -e "SELECT COMMAND, TIME_MS, STATE FROM information_schema.PROCESSLIST WHERE ID = IS_USED_LOCK('$1')"`
	wantEnd     = `MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb --batch --skip-column-names --delimiter=// -e "BEGIN NOT ATOMIC DECLARE id BIGINT UNSIGNED DEFAULT IS_USED_LOCK('$1'); DECLARE CONTINUE HANDLER FOR 1094 BEGIN END; IF id IS NOT NULL THEN EXECUTE IMMEDIATE CONCAT('KILL ', id); END IF; END"`
	wantSize    = `MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb --batch --skip-column-names -e 'SELECT CAST(COALESCE(SUM(data_length + index_length), 0) AS UNSIGNED) FROM information_schema.tables WHERE table_schema = DATABASE()' "$MARIADB_DATABASE"`
)

// wantPreamble is what a replay sends before the dump, with the name of its
// lock for the %s.
const wantPreamble = "DO GET_LOCK('%s', 0);\n" +
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

// ran is one command a test saw run in a container.
type ran struct {
	name string
	args []string
}

func (r ran) is(name string, args ...string) bool {
	return r.name == name && slices.Equal(r.args, args)
}

func (r ran) String() string { return fmt.Sprintf("%s %q", r.name, r.args) }

// recorder stands for the container with the exact commands above: it
// records every command, answers those it knows, and fails any other.
type recorder struct {
	mu      sync.Mutex
	ran     []ran
	answers map[string]func(ctx context.Context, stdin io.Reader, stdout io.Writer) error
}

func newRecorder(t *testing.T) *recorder {
	r := &recorder{answers: map[string]func(context.Context, io.Reader, io.Writer) error{}}
	stubExec(t, func(ctx context.Context, name string, stdin io.Reader, stdout io.Writer, args ...string) error {
		r.mu.Lock()
		r.ran = append(r.ran, ran{name: name, args: slices.Clone(args)})
		var answer func(context.Context, io.Reader, io.Writer) error
		if len(args) >= 3 && args[0] == "sh" && args[1] == "-c" {
			answer = r.answers[args[2]]
		}
		r.mu.Unlock()
		if answer == nil {
			return fmt.Errorf("the test does not know %s %q", name, args)
		}
		return answer(ctx, stdin, stdout)
	})
	return r
}

// commands are the commands run so far.
func (r *recorder) commands() []ran {
	r.mu.Lock()
	defer r.mu.Unlock()
	return slices.Clone(r.ran)
}

// answer makes script answer what, whatever its input.
func (r *recorder) answer(script, what string) {
	r.answers[script] = func(_ context.Context, _ io.Reader, stdout io.Writer) error {
		_, err := io.WriteString(stdout, what)
		return err
	}
}

// A backup asks which engines the tables use, then runs the dump that
// reads them all at one point: one transaction when every table has
// transactions, a lock of the tables when some do not, and then it says
// that the writes of the site wait.
func TestTheCommandsOfABackup(t *testing.T) {
	plentyOfSpace(t)
	cases := []struct {
		engines, dump, said string
	}{
		{"0\t\n", wantDump, ""},
		{"2\tAria, MyISAM\n", wantLocked, "the database holds 2 tables without transactions (Aria, MyISAM): the dump locks every table to read them all at one point, so the writes of the site wait until it ends"},
		{"1\tMyISAM\n", wantLocked, "the database holds 1 table without transactions (MyISAM): the dump locks every table to read them all at one point, so the writes of the site wait until it ends"},
		{"3\n", wantLocked, "the database holds 3 tables without transactions: the dump locks every table to read them all at one point, so the writes of the site wait until it ends"},
	}
	for _, c := range cases {
		r := newRecorder(t)
		r.answer(wantEngines, c.engines)
		r.answer(c.dump, "CREATE TABLE t (id INT);\n")
		var reports []string
		dir := t.TempDir()
		if _, err := Create(context.Background(), dir, "0.2.0", "kvs-mariadb", writeEnv(t, dir), "", func(msg string) { reports = append(reports, msg) }); err != nil {
			t.Fatalf("engines %q: %v (ran %v)", c.engines, err, r.commands())
		}
		if got := r.commands(); len(got) != 2 || !got[0].is("kvs-mariadb", "sh", "-c", wantEngines) || !got[1].is("kvs-mariadb", "sh", "-c", c.dump) {
			t.Errorf("engines %q: ran %v", c.engines, got)
		}
		// The compressed size is the compressor's business.
		want := []string{"dumping the database", "dumped 25 B, "}
		if c.said != "" {
			want = append([]string{c.said}, want...)
		}
		if !saidThese(reports, want) {
			t.Errorf("engines %q: said %q, want %q", c.engines, reports, want)
		}
	}
}

// saidThese reports whether reports are want, the last one compared by its
// start alone.
func saidThese(reports, want []string) bool {
	n := len(want)
	return len(reports) == n && slices.Equal(reports[:n-1], want[:n-1]) && strings.HasPrefix(reports[n-1], want[n-1])
}

// What the engines of the tables are has to be known before the dump: a
// backup that cannot tell does not guess, and leaves nothing behind.
func TestCreateStopsWhenTheEnginesCannotBeRead(t *testing.T) {
	plentyOfSpace(t)
	for answer, want := range map[string]string{
		"":                           "the engines of the tables in kvs-mariadb could not be read: the test does not know",
		"ERROR 1045 (28000): denied": `the engines of the tables in kvs-mariadb could not be read: the database answered "ERROR 1045 (28000): denied"`,
	} {
		r := newRecorder(t)
		if answer != "" {
			r.answer(wantEngines, answer)
		}
		dir := t.TempDir()
		_, err := Create(context.Background(), dir, "0.2.0", "kvs-mariadb", writeEnv(t, dir), "", nil)
		if err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("answer %q: err = %v, want %q", answer, err, want)
		}
		if got := r.commands(); len(got) != 1 {
			t.Errorf("answer %q: ran %v, want the question alone", answer, got)
		}
		if left, _ := filepath.Glob(filepath.Join(dir, "backup-*")); len(left) != 0 {
			t.Errorf("answer %q: left behind %v", answer, left)
		}
	}
}

// A replay sends the preamble that empties the database, then the dump,
// to the database of the site; when the database takes nothing for the
// stall timeout, it asks the server about the connection that holds the
// lock the preamble took, and ends that connection once it stops the
// replay.
func TestTheCommandsOfAReplay(t *testing.T) {
	const sql = "CREATE TABLE t (id INT);\nINSERT INTO t VALUES (1);\n"
	path := createSQL(t, t.TempDir(), sql)
	setVar(t, &stallTimeout, 200*time.Millisecond)
	r := newRecorder(t)
	var input bytes.Buffer
	r.answers[wantReplay] = func(_ context.Context, stdin io.Reader, _ io.Writer) error {
		_, err := io.Copy(&input, stdin)
		return err
	}
	if err := RestoreDatabase(context.Background(), path, "kvs-mariadb", nil); err != nil {
		t.Fatal(err)
	}
	if got := r.commands(); len(got) != 1 || !got[0].is("kvs-mariadb", "sh", "-c", wantReplay) {
		t.Fatalf("ran %v", got)
	}
	m := regexp.MustCompile(`^DO GET_LOCK\('(kvsctl-replay-\d+-\d+)', 0\);\n`).FindStringSubmatch(input.String())
	if m == nil {
		t.Fatalf("the replay does not start with its lock:\n%s", input.String())
	}
	if want := fmt.Sprintf(wantPreamble, m[1]) + sql; input.String() != want {
		t.Fatalf("the replay sent\n%s\nwant\n%s", input.String(), want)
	}

	// A replay the database stops taking.
	r = newRecorder(t)
	locks := make(chan string, 1)
	r.answers[wantReplay] = func(ctx context.Context, stdin io.Reader, _ io.Writer) error {
		lock, err := readPreamble(stdin)
		locks <- lock
		if err != nil {
			return err
		}
		<-ctx.Done()
		return ctx.Err()
	}
	r.answer(wantProbe, "Sleep\t3000.000\t\n")
	r.answer(wantEnd, "")
	err := RestoreDatabase(guarded(t), path, "kvs-mariadb", nil)
	if err == nil || !strings.Contains(err.Error(), "the connection of the replay has waited for input for 3s") {
		t.Fatalf("err = %v", err)
	}
	lock := <-locks
	if got := r.commands(); len(got) != 3 || !got[1].is("kvs-mariadb", "sh", "-c", wantProbe, "sh", lock) || !got[2].is("kvs-mariadb", "sh", "-c", wantEnd, "sh", lock) {
		t.Errorf("ran %v, want the replay, the question about %s, then the end of its connection", got, lock)
	}
}

// DatabaseSize asks information_schema for the data and the indexes of the
// tables of the site.
func TestTheCommandOfDatabaseSize(t *testing.T) {
	r := newRecorder(t)
	r.answer(wantSize, "3160000000\n")
	if size, err := DatabaseSize(context.Background(), "kvs-mariadb"); err != nil || size != 3160000000 {
		t.Errorf("size %d, %v", size, err)
	}
	if len(r.ran) != 1 || !r.ran[0].is("kvs-mariadb", "sh", "-c", wantSize) {
		t.Errorf("ran %v", r.ran)
	}
}

// changed is how mariadb-dump stops at a table whose definition changed
// after its snapshot, as docker exec returns it.
const changed = "docker exec kvs-mariadb: exit status 3: mariadb-dump: Error 1412: Table definition has changed, please retry transaction when dumping table `ktvs_zz_work` at row: 0\n"

// dumpText is the dump an archive holds, decompressed.
func dumpText(t *testing.T, path string) string {
	t.Helper()
	a, err := openArchive(path)
	if err != nil {
		t.Fatal(err)
	}
	defer a.Close()
	section, err := a.section(dumpName)
	if err != nil {
		t.Fatal(err)
	}
	zr, err := zstd.NewReader(section)
	if err != nil {
		t.Fatal(err)
	}
	defer zr.Close()
	data, err := io.ReadAll(zr)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

// A table emptied or rebuilt after the snapshot of the dump stops it with
// error 1412; a new snapshot gets past it, so the dump starts again from
// the start, and the archive holds the last dump alone.
func TestCreateStartsTheDumpAgainAfterADefinitionChange(t *testing.T) {
	plentyOfSpace(t)
	dir := t.TempDir()
	attempts := 0
	const last = "-- the third dump\nCREATE TABLE t (id INT);\n"
	dump := newRandomDump()
	stubServer(t, &server{dump: func(ctx context.Context, script string, stdout io.Writer) error {
		attempts++
		if attempts < 3 {
			// 4 MiB of the dump, then the table that changed.
			for i := 0; i < 64; i++ {
				if _, err := stdout.Write(dump.next()); err != nil {
					return err
				}
			}
			if attempts == 2 {
				return errors.New("docker exec kvs-mariadb: exit status 2: mariadb-dump: Couldn't execute 'show create table `ktvs_zz_work`': Table definition has changed, please retry transaction (1412)\n")
			}
			return errors.New(changed)
		}
		_, err := io.WriteString(stdout, last)
		return err
	}})
	var reports []string
	result, err := Create(context.Background(), dir, "0.2.0", "kvs-mariadb", writeEnv(t, dir), "", func(msg string) { reports = append(reports, msg) })
	if err != nil {
		t.Fatal(err)
	}
	if attempts != 3 {
		t.Errorf("%d dumps, want 3", attempts)
	}
	if got := dumpText(t, result.Path); got != last {
		t.Errorf("the archive holds %d bytes of dump, want the last dump alone: %q", len(got), got[:min(len(got), 60)])
	}
	if result.Size > 64<<10 {
		t.Errorf("the archive takes %d bytes: what the stopped dumps wrote is still in it", result.Size)
	}
	want := []string{
		"dumping the database",
		"table `ktvs_zz_work` changed its definition while the dump read the database (error 1412, a TRUNCATE, ALTER or OPTIMIZE of it): the dump starts again, attempt 2 of 3",
		"table `ktvs_zz_work` changed its definition while the dump read the database (error 1412, a TRUNCATE, ALTER or OPTIMIZE of it): the dump starts again, attempt 3 of 3",
		"dumped 43 B, ",
	}
	if !saidThese(reports, want) {
		t.Errorf("said\n%s\nwant\n%s", strings.Join(reports, "\n"), strings.Join(want, "\n"))
	}
}

// A table that keeps changing ends the backup after three dumps, with an
// error that names it and says what to do.
func TestCreateGivesUpOnATableThatKeepsChanging(t *testing.T) {
	plentyOfSpace(t)
	dir := t.TempDir()
	attempts := 0
	stubServer(t, &server{dump: func(ctx context.Context, script string, stdout io.Writer) error {
		attempts++
		if _, err := io.WriteString(stdout, "-- some of the dump\n"); err != nil {
			return err
		}
		return errors.New(changed)
	}})
	_, err := Create(context.Background(), dir, "0.2.0", "kvs-mariadb", writeEnv(t, dir), "", nil)
	want := "the dump stopped 3 times in a row on a table whose definition changed while it read the database (error 1412), the last time on table `ktvs_zz_work`: something empties or rebuilds tables (TRUNCATE, ALTER, OPTIMIZE) more often than a dump lasts; take the backup once that is over: " + changed
	if err == nil || err.Error() != want {
		t.Errorf("err = %v\nwant %s", err, want)
	}
	if attempts != dumpAttempts {
		t.Errorf("%d dumps, want %d", attempts, dumpAttempts)
	}
	if left, _ := filepath.Glob(filepath.Join(dir, "backup-*")); len(left) != 0 {
		t.Errorf("left behind %v", left)
	}
}

// The table a 1412 names, whether the dump was reading its rows or its
// definition, and none when the message names none.
func TestDefinitionChanged(t *testing.T) {
	for msg, want := range map[string]string{
		changed: "table `ktvs_zz_work`",
		"mariadb-dump: Couldn't execute 'show create table `ktvs_a``b`': Table definition has changed, please retry transaction (1412)": "table `ktvs_a``b`",
		"mariadb-dump: Error 1412: Table definition has changed, please retry transaction":                                              "a table",
	} {
		if table, ok := definitionChanged(errors.New(msg)); !ok || table != want {
			t.Errorf("%q: %q, %v, want %q", msg, table, ok, want)
		}
	}
	for _, err := range []error{nil, errors.New("mariadb-dump: Got error: 2013: Lost connection when dumping table `t` at row: 1412")} {
		if table, ok := definitionChanged(err); ok {
			t.Errorf("%v: read as a definition change of %q", err, table)
		}
	}
}

// Any other failure of the dump, and a backup that was cancelled, end the
// backup at once. A 1412 that is a row number is no definition change.
func TestCreateStartsAgainForADefinitionChangeOnly(t *testing.T) {
	plentyOfSpace(t)
	lost := errors.New("docker exec kvs-mariadb: exit status 2: mariadb-dump: Error 2013: Lost connection to server during query when dumping table `ktvs_videos` at row: 1412\n")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	for _, c := range []struct {
		ctx context.Context
		err error
		end func()
	}{
		{context.Background(), lost, func() {}},
		{ctx, errors.New(changed), cancel},
	} {
		attempts := 0
		stubServer(t, &server{dump: func(context.Context, string, io.Writer) error {
			attempts++
			c.end()
			return c.err
		}})
		dir := t.TempDir()
		if _, err := Create(c.ctx, dir, "0.2.0", "kvs-mariadb", writeEnv(t, dir), "", nil); !errors.Is(err, c.err) {
			t.Errorf("err = %v, want %v as it is", err, c.err)
		}
		if attempts != 1 {
			t.Errorf("%v: %d dumps, want 1", c.err, attempts)
		}
	}
}

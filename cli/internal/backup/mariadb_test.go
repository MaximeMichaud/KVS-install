package backup

import (
	"bytes"
	"cmp"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/klauspost/compress/zstd"
)

// The tests of this file run the dump and the replay for real, against a
// MariaDB that docker/images.lock pins, in a container of their own that
// TestMain removes, or an interrupt, or the next run when this one dies
// before it can (see sweepLeftovers). They need Docker and are skipped
// without it; nothing else turns them off. KVSCTL_TEST_MARIADB_IMAGE runs
// them against another image, another series for instance.

// mariadb is the container the tests of this file share. Each test starts
// from an empty database of the site.
var mariadb struct {
	once  sync.Once
	name  string
	image string
	skip  string
	err   error
}

// created is the container once docker run made it, which TestMain and an
// interrupt both remove.
var created struct {
	sync.Mutex
	name string
}

// The labels of the container: whose tests made it, from which process on
// which host, so that a later run can tell one whose process is gone.
const (
	labelTests = "kvsctltest=backup"
	labelPID   = "kvsctltest.pid"
	labelHost  = "kvsctltest.host"
)

func TestMain(m *testing.M) {
	// An interrupt ends the tests at once: the container goes first.
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-signals
		removeMariaDB()
		os.Exit(1)
	}()
	code := m.Run()
	removeMariaDB()
	os.Exit(code)
}

// removeMariaDB removes the container of the tests, with its volume, if
// one was made. An engine that does not answer leaves it to the next run.
func removeMariaDB() {
	created.Lock()
	defer created.Unlock()
	if created.name != "" {
		ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
		defer cancel()
		_ = exec.CommandContext(ctx, "docker", "rm", "--force", "--volumes", created.name).Run()
		created.name = ""
	}
}

// sweepLeftovers removes the containers an earlier run of these tests made
// and could not remove, because its test binary died: a timeout panics
// past TestMain, and a SIGKILL leaves nothing to run. Only those of this
// host whose process is gone go; the container of a run still going, in
// another checkout for instance, stays.
func sweepLeftovers() {
	host, err := os.Hostname()
	if err != nil {
		return
	}
	out, err := exec.Command("docker", "ps", "--all", "--filter", "label="+labelTests, "--format", "{{.ID}}\t{{.Label \""+labelPID+"\"}}\t{{.Label \""+labelHost+"\"}}").Output()
	if err != nil {
		return
	}
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		f := strings.Split(line, "\t")
		if len(f) != 3 || f[2] != host {
			continue
		}
		if pid, err := strconv.Atoi(f[1]); err == nil && pid > 0 && !processAlive(pid) {
			_ = exec.Command("docker", "rm", "--force", "--volumes", f[0]).Run()
		}
	}
}

// processAlive reports whether pid names a process of this host, one of
// another user included.
func processAlive(pid int) bool {
	err := syscall.Kill(pid, 0)
	return err == nil || errors.Is(err, syscall.EPERM)
}

// The database of the site and its root password, as the stack sets them:
// the database is named after the domain, a dot included. The password
// opens the throwaway container of the tests and nothing else.
const (
	siteDatabase = "example.com"
	rootPassword = "kvsctl-test" // pragma: allowlist secret
)

// mariadbServer returns the container of the tests, started on first use.
func mariadbServer(t *testing.T) string {
	t.Helper()
	mariadb.once.Do(startMariaDB)
	if mariadb.skip != "" {
		t.Skip(mariadb.skip)
	}
	if mariadb.err != nil {
		t.Fatal(mariadb.err)
	}
	t.Logf("MariaDB %s in %s", mariadb.image, mariadb.name)
	return mariadb.name
}

func startMariaDB() {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if out, err := exec.CommandContext(ctx, "docker", "version", "--format", "{{.Server.Version}}").CombinedOutput(); err != nil {
		mariadb.skip = fmt.Sprintf("no Docker engine to run MariaDB on: %v: %s", err, bytes.TrimSpace(out))
		return
	}
	image, err := mariadbImage()
	if err != nil {
		mariadb.err = err
		return
	}
	sweepLeftovers()
	host, err := os.Hostname()
	if err != nil {
		mariadb.err = err
		return
	}
	name := fmt.Sprintf("kvsctltest-backup-%d-mariadb", os.Getpid())
	created.Lock()
	// A container that was created but did not start is removed all the
	// same.
	created.name = name
	created.Unlock()
	run := exec.Command("docker", "run", "--detach", "--name", name,
		"--label", labelTests, "--label", fmt.Sprintf("%s=%d", labelPID, os.Getpid()), "--label", labelHost+"="+host,
		"--env", "MARIADB_ROOT_PASSWORD="+rootPassword, "--env", "MARIADB_DATABASE="+siteDatabase,
		"--env", "MARIADB_INITDB_SKIP_TZINFO=1", image)
	if out, err := run.CombinedOutput(); err != nil {
		mariadb.err = fmt.Errorf("docker run %s: %v: %s", image, err, out)
		return
	}
	mariadb.name, mariadb.image = name, image
	// The image runs a first server without networking while it creates
	// the database: --connect waits for the real one.
	deadline := time.Now().Add(3 * time.Minute)
	for {
		if exec.Command("docker", "exec", name, "healthcheck.sh", "--connect", "--innodb_initialized").Run() == nil {
			return
		}
		if time.Now().After(deadline) {
			logs, _ := exec.Command("docker", "logs", "--tail", "40", name).CombinedOutput()
			mariadb.err = fmt.Errorf("%s (%s) did not start within 3 minutes:\n%s", name, image, logs)
			return
		}
		time.Sleep(500 * time.Millisecond)
	}
}

// mariadbImage is KVSCTL_TEST_MARIADB_IMAGE, or a MariaDB that
// docker/images.lock pins: the series the stack installs by default (the
// newest one when docker-compose.yml does not say), unless the engine
// holds the image of another pinned series and not that one, which saves
// a download.
func mariadbImage() (string, error) {
	if image := os.Getenv("KVSCTL_TEST_MARIADB_IMAGE"); image != "" {
		return image, nil
	}
	root := filepath.Join("..", "..", "..", "docker")
	lock, err := os.ReadFile(filepath.Join(root, "images.lock"))
	if err != nil {
		return "", err
	}
	pinned := map[string]string{}
	var series []string
	for _, line := range strings.Split(string(lock), "\n") {
		if f := strings.Split(line, "\t"); len(f) == 3 && f[0] == "mariadb" {
			pinned[f[1]] = f[2]
			series = append(series, f[1])
		}
	}
	if len(series) == 0 {
		return "", fmt.Errorf("docker/images.lock pins no MariaDB")
	}
	slices.SortFunc(series, func(a, b string) int { return cmp.Compare(seriesNumber(b), seriesNumber(a)) })
	compose, _ := os.ReadFile(filepath.Join(root, "docker-compose.yml"))
	if m := regexp.MustCompile(`image: mariadb:\$\{MARIADB_VERSION:-([0-9.]+)\}`).FindSubmatch(compose); m != nil {
		if i := slices.Index(series, string(m[1])); i > 0 {
			series = append(append([]string{series[i]}, series[:i]...), series[i+1:]...)
		}
	}
	for _, s := range series {
		if exec.Command("docker", "image", "inspect", pinned[s]).Run() == nil {
			return pinned[s], nil
		}
	}
	return pinned[series[0]], nil
}

// seriesNumber orders MariaDB series: 11.8 before 12.3.
func seriesNumber(series string) int {
	var major, minor int
	_, _ = fmt.Sscanf(series, "%d.%d", &major, &minor)
	return major*1000 + minor
}

// inSite runs sql in the database of the site, as root, and returns what
// it printed; asRoot runs it outside of any database.
func inSite(t *testing.T, sql string) string {
	t.Helper()
	out, err := trySQL(sql, `"$MARIADB_DATABASE"`)
	if err != nil {
		t.Fatal(err)
	}
	return out
}

func asRoot(t *testing.T, sql string) string {
	t.Helper()
	out, err := trySQL(sql, "")
	if err != nil {
		t.Fatal(err)
	}
	return out
}

// trySQL runs sql as root in database, which may be empty, and returns
// what it printed. It may run outside of the test goroutine. The client
// speaks utf8mb4, as a site does: before 11.6 its default is another.
func trySQL(sql, database string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	cmd := exec.CommandContext(ctx, "docker", "exec", "-i", mariadb.name, "sh", "-c", `MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb --batch --skip-column-names --default-character-set=utf8mb4 `+database)
	cmd.Stdin = strings.NewReader(sql)
	var out, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &stderr
	if err := cmd.Run(); err != nil {
		return "", fmt.Errorf("mariadb: %v: %s\nfor:\n%s", err, stderr.String(), sql)
	}
	return out.String(), nil
}

// emptySite gives the test an empty database of the site, with a collation
// of its own: a replay has to keep it.
func emptySite(t *testing.T) {
	t.Helper()
	asRoot(t, "DROP DATABASE IF EXISTS `"+siteDatabase+"`;\nCREATE DATABASE `"+siteDatabase+"` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\n")
}

// siteEnv is the .env of the stack, for the domain backup.json records.
func siteEnv(t *testing.T) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), ".env")
	if err := os.WriteFile(path, []byte("DOMAIN="+siteDatabase+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

// rowsOf is the part of a dump that writes the rows of a table, from its
// LOCK TABLES to its UNLOCK TABLES. Recent dumps write one row per line.
func rowsOf(t *testing.T, sql, table string) string {
	t.Helper()
	start := strings.Index(sql, "LOCK TABLES `"+table+"` WRITE;")
	if start < 0 {
		t.Fatalf("the dump writes no rows of %s", table)
	}
	end := strings.Index(sql[start:], "UNLOCK TABLES;")
	if end < 0 {
		t.Fatalf("the rows of %s do not end", table)
	}
	return sql[start : start+end]
}

// pausedWriter holds the output of a dump once, after the first after
// bytes went through, for as long as while runs: the dump stops when its
// pipe is full, at a point of its tables the test chose.
type pausedWriter struct {
	w      io.Writer
	after  int64
	n      int64
	paused bool
	while  func()
}

func (p *pausedWriter) Write(b []byte) (int, error) {
	if !p.paused && p.n >= p.after {
		p.paused = true
		p.while()
	}
	n, err := p.w.Write(b)
	p.n += int64(n)
	return n, err
}

// pauseFirstDump pauses the first dump of the test after its first after
// bytes, and runs while meanwhile.
func pauseFirstDump(t *testing.T, after int64, while func()) {
	t.Helper()
	previous := execFn
	var once sync.Once
	execFn = func(ctx context.Context, name string, stdin io.Reader, stdout io.Writer, args ...string) error {
		if len(args) == 3 && strings.Contains(args[2], "mariadb-dump") {
			once.Do(func() { stdout = &pausedWriter{w: stdout, after: after, while: while} })
		}
		return previous(ctx, name, stdin, stdout, args...)
	}
	t.Cleanup(func() { execFn = previous })
}

// probeAnswers records, for the rest of the test, what the server answers
// when a replay asks it about its connection: lines of probeScript.
func probeAnswers(t *testing.T) func() []string {
	t.Helper()
	previous := execFn
	var mu sync.Mutex
	var answers []string
	execFn = func(ctx context.Context, name string, stdin io.Reader, stdout io.Writer, args ...string) error {
		if len(args) < 3 || args[2] != probeScript {
			return previous(ctx, name, stdin, stdout, args...)
		}
		var out bytes.Buffer
		err := previous(ctx, name, stdin, &out, args...)
		mu.Lock()
		answers = append(answers, strings.TrimRight(out.String(), "\n"))
		mu.Unlock()
		if _, werr := stdout.Write(out.Bytes()); err == nil {
			err = werr
		}
		return err
	}
	t.Cleanup(func() { execFn = previous })
	return func() []string {
		mu.Lock()
		defer mu.Unlock()
		return slices.Clone(answers)
	}
}

// inState tells the answers that show the connection of the replay
// running a statement in that state.
func inState(state string) func(string) bool {
	return func(answer string) bool {
		f := strings.Split(answer, "\t")
		return len(f) == 3 && f[0] == "Query" && f[2] == state
	}
}

// siteSnapshot is what the database of the site holds, the way a replay
// must give it back: its collation, its tables, views, sequences, routines,
// events and triggers, the rows of the tables of the test and the grants
// on it.
func siteSnapshot(t *testing.T) string {
	t.Helper()
	return inSite(t, `SELECT 'schema', default_character_set_name, default_collation_name FROM information_schema.schemata WHERE schema_name = DATABASE();
SELECT 'table', table_name, table_type, COALESCE(engine, '') FROM information_schema.tables WHERE table_schema = DATABASE() ORDER BY table_name;
SELECT 'view', table_name, view_definition FROM information_schema.views WHERE table_schema = DATABASE() ORDER BY table_name;
SELECT 'routine', routine_type, routine_name, routine_definition FROM information_schema.routines WHERE routine_schema = DATABASE() ORDER BY routine_type, routine_name;
SELECT 'event', event_name, event_definition FROM information_schema.events WHERE event_schema = DATABASE() ORDER BY event_name;
SELECT 'trigger', trigger_name, event_object_table, action_statement FROM information_schema.triggers WHERE trigger_schema = DATABASE() ORDER BY trigger_name;
SELECT 'video', video_id, title FROM ktvs_videos ORDER BY video_id;
SELECT 'comment', comment_id, video_id, body FROM ktvs_comments ORDER BY comment_id;
SELECT 'next id', NEXTVAL(ktvs_ids);
SHOW GRANTS FOR 'site'@'%';
`)
}

// A backup and a replay against a real MariaDB: the dump holds the database
// of the site, and only it, with its routines, triggers, events and text in
// utf8mb4, and the replay gives the database back as the archive has it:
// what was created since goes, whatever its name, and what was dropped
// comes back. A replay cut short runs again, and the other databases of
// the server are left alone.
func TestRealBackupAndReplay(t *testing.T) {
	mariadbServer(t)
	emptySite(t)
	inSite(t, `CREATE TABLE ktvs_videos (video_id INT PRIMARY KEY, title VARCHAR(100)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE ktvs_comments (comment_id INT PRIMARY KEY, video_id INT, body TEXT, FOREIGN KEY (video_id) REFERENCES ktvs_videos (video_id)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE SEQUENCE ktvs_ids;
CREATE VIEW ktvs_titles AS SELECT video_id, title FROM ktvs_videos;
CREATE TRIGGER ktvs_videos_title BEFORE INSERT ON ktvs_videos FOR EACH ROW SET NEW.title = TRIM(NEW.title);
CREATE PROCEDURE ktvs_count() SELECT COUNT(*) FROM ktvs_videos;
CREATE FUNCTION ktvs_double(n INT) RETURNS INT DETERMINISTIC RETURN n * 2;
CREATE EVENT ktvs_cleanup ON SCHEDULE EVERY 1 DAY DO DELETE FROM ktvs_comments WHERE comment_id < 0;
INSERT INTO ktvs_videos VALUES (1, ' first 😀 '), (2, 'second ✓');
INSERT INTO ktvs_comments VALUES (1, 1, 'nice'), (2, 2, 'great');
`)
	asRoot(t, "CREATE DATABASE IF NOT EXISTS other_site;\nCREATE TABLE IF NOT EXISTS other_site.kept (id INT);\nCREATE USER IF NOT EXISTS 'site'@'%' IDENTIFIED BY 'site';\nGRANT SELECT, INSERT, UPDATE ON `"+siteDatabase+"`.* TO 'site'@'%';\n")
	// NEXTVAL in the snapshot moves the sequence on: the snapshot runs once
	// against the archive's state, so it is taken after the backup, and once
	// after each replay.
	var reports []string
	result, err := Create(context.Background(), t.TempDir(), "26.10.0", mariadb.name, siteEnv(t), "", func(msg string) { reports = append(reports, msg) })
	if err != nil {
		t.Fatal(err)
	}
	if len(reports) != 2 || reports[0] != "dumping the database" {
		t.Errorf("a database of InnoDB tables said %q", reports)
	}
	sql := dumpText(t, result.Path)
	for _, want := range []string{"CREATE TABLE `ktvs_videos`", "CREATE TABLE `ktvs_comments`", "CREATE SEQUENCE `ktvs_ids`", "VIEW `ktvs_titles`", "TRIGGER ktvs_videos_title", "PROCEDURE `ktvs_count`", "FUNCTION `ktvs_double`", "EVENT `ktvs_cleanup`", "first 😀", "second ✓"} {
		if !strings.Contains(sql, want) {
			t.Errorf("the dump holds no %s", want)
		}
	}
	for _, unwanted := range []string{"CREATE DATABASE", "\nUSE ", "other_site"} {
		if strings.Contains(sql, unwanted) {
			t.Errorf("the dump holds %q: it is not the dump of the site alone", strings.TrimSpace(unwanted))
		}
	}
	before := siteSnapshot(t)
	if !strings.Contains(before, "first 😀") {
		t.Fatalf("the trigger did not run or the text was mangled:\n%s", before)
	}

	// What the site does after the backup: tables, rows and objects come
	// and go, some with names that need quoting.
	inSite(t, "CREATE TABLE ktvs_added_since (id INT) ENGINE=InnoDB;\n"+
		"INSERT INTO ktvs_added_since VALUES (1);\n"+
		"CREATE TABLE `ktvs_vidéos ``since` (id INT) ENGINE=MyISAM;\n"+
		"CREATE SEQUENCE ktvs_ids_since;\n"+
		"CREATE VIEW ktvs_view_since AS SELECT 1 AS one;\n"+
		"UPDATE ktvs_videos SET title = 'changed' WHERE video_id = 1;\n"+
		"DELETE FROM ktvs_comments WHERE comment_id = 2;\n"+
		"DROP VIEW ktvs_titles;\n"+
		"DROP PROCEDURE ktvs_count;\n"+
		"CREATE PROCEDURE ktvs_since() SELECT 1;\n"+
		"CREATE EVENT ktvs_event_since ON SCHEDULE EVERY 1 HOUR DO DELETE FROM ktvs_added_since;\n")
	if err := RestoreDatabase(context.Background(), result.Path, mariadb.name, nil); err != nil {
		t.Fatal(err)
	}
	if after := siteSnapshot(t); after != before {
		t.Fatalf("after the replay the database holds\n%s\nthe archive holds\n%s", after, before)
	}

	// A replay cut short, here half way through the tables, leaves a
	// database between the two; the next replay starts it over.
	cut := strings.Index(sql, "CREATE TABLE `ktvs_videos`")
	if cut < 0 {
		t.Fatal("no table to cut the dump at")
	}
	inSite(t, "CREATE TABLE ktvs_added_since (id INT);\n"+sql[:cut])
	if err := RestoreDatabase(context.Background(), result.Path, mariadb.name, nil); err != nil {
		t.Fatal(err)
	}
	if after := siteSnapshot(t); after != before {
		t.Fatalf("after a replay over one cut short the database holds\n%s\nthe archive holds\n%s", after, before)
	}
	if got := asRoot(t, "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'other_site';\n"); strings.TrimSpace(got) != "1" {
		t.Errorf("another database of the server holds %s tables after the replays, want its 1", strings.TrimSpace(got))
	}
}

// MyISAM tables take part in no transaction. A row written in two of them
// while the dump reads a third, a comment and the event that names it, is
// in the archive in both tables or in neither: the dump reads every table
// at one point, under a lock, and says that the writes wait.
func TestRealDumpOfTablesWithoutTransactions(t *testing.T) {
	mariadbServer(t)
	emptySite(t)
	inSite(t, `CREATE TABLE ktvs_a_comments (comment_id INT PRIMARY KEY, body VARCHAR(64)) ENGINE=MyISAM;
CREATE TABLE ktvs_m_rating_history (id INT PRIMARY KEY, a CHAR(100)) ENGINE=MyISAM;
CREATE TABLE ktvs_z_events (event_id INT PRIMARY KEY, comment_id INT) ENGINE=MyISAM;
INSERT INTO ktvs_a_comments SELECT seq, 'old' FROM seq_1_to_100;
INSERT INTO ktvs_z_events SELECT seq, seq FROM seq_1_to_100;
INSERT INTO ktvs_m_rating_history SELECT seq, REPEAT('r', 100) FROM seq_1_to_160000;
`)
	written := make(chan error, 1)
	pauseFirstDump(t, 2<<20, func() {
		// The middle table is being read. MyISAM takes these inserts
		// beside a read lock; a lock that held them would end the pause on
		// its timeout rather than hang the test.
		done := make(chan struct{})
		go func() {
			defer close(done)
			_, err := trySQL("INSERT INTO ktvs_a_comments VALUES (999999, 'late');\nINSERT INTO ktvs_z_events VALUES (999999, 999999);\n", `"$MARIADB_DATABASE"`)
			written <- err
		}()
		select {
		case <-done:
		case <-time.After(30 * time.Second):
		}
	})
	var reports []string
	result, err := Create(context.Background(), t.TempDir(), "26.10.0", mariadb.name, siteEnv(t), "", func(msg string) { reports = append(reports, msg) })
	if err != nil {
		t.Fatal(err)
	}
	if err := <-written; err != nil {
		t.Fatal(err)
	}
	sql := dumpText(t, result.Path)
	comment := strings.Contains(rowsOf(t, sql, "ktvs_a_comments"), "(999999,")
	event := strings.Contains(rowsOf(t, sql, "ktvs_z_events"), "(999999,999999)")
	t.Logf("the archive holds the comment written during the dump: %v, its event: %v", comment, event)
	if comment != event {
		t.Errorf("the archive holds the comment written during the dump: %v, the event that names it: %v; it reads the tables at different moments", comment, event)
	}
	want := "the database holds 3 tables without transactions (MyISAM): the dump locks every table to read them all at one point, so the writes of the site wait until it ends"
	if !slices.Contains(reports, want) {
		t.Errorf("the backup said %q, want %q", reports, want)
	}
}

// The server itself tells the tables a dump has to lock: those of an engine
// without transactions, a system-versioned one included, and never a MEMORY
// table, a sequence or a view.
func TestRealEnginesOfTheSite(t *testing.T) {
	mariadbServer(t)
	emptySite(t)
	engines := func() string {
		t.Helper()
		var out bytes.Buffer
		if err := execFn(context.Background(), mariadb.name, nil, &out, "sh", "-c", enginesScript); err != nil {
			t.Fatal(err)
		}
		return out.String()
	}
	inSite(t, `CREATE TABLE ktvs_videos (id INT PRIMARY KEY) ENGINE=InnoDB;
CREATE TABLE ktvs_history (id INT) ENGINE=InnoDB WITH SYSTEM VERSIONING;
CREATE TABLE ktvs_online (id INT) ENGINE=MEMORY;
CREATE SEQUENCE ktvs_ids ENGINE=Aria;
CREATE VIEW ktvs_titles AS SELECT id FROM ktvs_videos;
`)
	if got := engines(); got != "0\t\n" {
		t.Errorf("tables with transactions, MEMORY, a sequence and a view: the server answered %q, want none to lock", got)
	}
	inSite(t, `CREATE TABLE ktvs_stats (id INT) ENGINE=Aria;
CREATE TABLE ktvs_rating_history (id INT) ENGINE=MyISAM WITH SYSTEM VERSIONING;
`)
	if got := engines(); got != "2\tAria, MyISAM\n" {
		t.Errorf("with an Aria table and a system-versioned MyISAM one, the server answered %q", got)
	}
}

// A table emptied after the snapshot of the dump and before the dump reads
// it ends that dump with error 1412. The backup starts the dump again,
// which takes a new snapshot, and the archive holds the table as it is.
func TestRealDumpOfATableThatChanged(t *testing.T) {
	mariadbServer(t)
	emptySite(t)
	inSite(t, `CREATE TABLE ktvs_a_big (id INT PRIMARY KEY, a CHAR(100)) ENGINE=InnoDB;
CREATE TABLE ktvs_zz_work (id INT PRIMARY KEY) ENGINE=InnoDB;
INSERT INTO ktvs_a_big SELECT seq, REPEAT('b', 100) FROM seq_1_to_160000;
INSERT INTO ktvs_zz_work SELECT seq FROM seq_1_to_1000;
`)
	var truncated error
	pauseFirstDump(t, 2<<20, func() { _, truncated = trySQL("TRUNCATE TABLE ktvs_zz_work;\n", `"$MARIADB_DATABASE"`) })
	var reports []string
	result, err := Create(context.Background(), t.TempDir(), "26.10.0", mariadb.name, siteEnv(t), "", func(msg string) { reports = append(reports, msg) })
	if truncated != nil {
		t.Fatal(truncated)
	}
	if err != nil {
		t.Fatal(err)
	}
	if !slices.ContainsFunc(reports, func(msg string) bool {
		return strings.HasPrefix(msg, "table `ktvs_zz_work` changed its definition while the dump read the database")
	}) {
		t.Errorf("the backup said %q, want the dump started again for ktvs_zz_work", reports)
	}
	sql := dumpText(t, result.Path)
	if !strings.Contains(sql, "CREATE TABLE `ktvs_zz_work`") || strings.Contains(sql, "INSERT INTO `ktvs_zz_work`") {
		t.Error("the archive does not hold ktvs_zz_work as it is, empty")
	}
}

// replayTestArchive writes an archive whose dump is sql, as Create would.
func replayTestArchive(t *testing.T, sql string) string {
	t.Helper()
	var dump bytes.Buffer
	zw, err := zstd.NewWriter(&dump)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := zw.Write([]byte(sql)); err != nil {
		t.Fatal(err)
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	meta, _ := json.Marshal(Meta{Format: Format, Version: "26.10.0", DumpBytes: int64(len(sql)), CompressedBytes: int64(dump.Len())})
	return writeTar(t, t.TempDir(), "backup-26.10.0-20261007-120000.tar", [][2]string{{dumpName, dump.String()}, {metaName, string(meta)}})
}

// insertRows writes statements INSERT statements of 1000 rows of about a
// hundred bytes each into table: megabytes of dump, more than the pipes
// between kvsctl and mariadb hold, so a replay stops reading while the
// statement before them runs.
func insertRows(sql *strings.Builder, table string, statements int) {
	for s := 0; s < statements; s++ {
		fmt.Fprintf(sql, "INSERT INTO %s VALUES ", table)
		for r := 0; r < 1000; r++ {
			if r > 0 {
				sql.WriteByte(',')
			}
			fmt.Fprintf(sql, "(%d,'%s')", s*1000+r, strings.Repeat("a", 90))
		}
		sql.WriteString(";\n")
	}
}

// One statement of a replay that the server runs for longer than the stall
// timeout, while the rest of the dump waits in the pipe, is no stall: the
// server shows the connection of the replay running it, and the replay
// waits. The statement comes after the LOCK TABLES and UNLOCK TABLES that
// surround the rows of a table in a dump: neither releases the lock by
// which the server finds the connection, so a statement between them, the
// ENABLE KEYS of a large MyISAM table, is found the same way.
func TestRealReplayWaitsForALongStatement(t *testing.T) {
	mariadbServer(t)
	emptySite(t)
	setVar(t, &stallTimeout, time.Second)
	var sql strings.Builder
	sql.WriteString("CREATE TABLE ktvs_rating_history (id INT PRIMARY KEY, video_id INT, KEY (video_id)) ENGINE=MyISAM;\n" +
		"LOCK TABLES ktvs_rating_history WRITE;\n" +
		"/*!40000 ALTER TABLE ktvs_rating_history DISABLE KEYS */;\n" +
		"INSERT INTO ktvs_rating_history VALUES (1,1),(2,2);\n" +
		"/*!40000 ALTER TABLE ktvs_rating_history ENABLE KEYS */;\n" +
		"UNLOCK TABLES;\n" +
		"CREATE TABLE ktvs_after (id INT PRIMARY KEY, a CHAR(100));\n" +
		"DO SLEEP(4);\n")
	insertRows(&sql, "ktvs_after", 80)
	path := replayTestArchive(t, sql.String())
	answers := probeAnswers(t)
	start := time.Now()
	if err := RestoreDatabase(context.Background(), path, mariadb.name, nil); err != nil {
		t.Fatal(err)
	}
	if took := time.Since(start); took < 4*time.Second {
		t.Errorf("the replay took %s, less than its statement", took)
	}
	if !slices.ContainsFunc(answers(), inState("User sleep")) {
		t.Errorf("the server was never asked about the replay while it ran its long statement, so the test proves nothing: answers %q", answers())
	}
	if got := strings.TrimSpace(inSite(t, "SELECT COUNT(*) FROM ktvs_after;\nSELECT COUNT(*) FROM ktvs_rating_history;\n")); got != "80000\n2" {
		t.Errorf("the replay wrote %q rows, want 80000 and 2", got)
	}
}

// A replay whose statement waits for a lock that a connection of the site
// keeps, in a transaction left open, takes no input while it waits, and the
// server shows it waiting, not at work: once it has waited the stall
// timeout the replay is stopped, where the server would let it wait a day,
// and its connection is ended on the server, so nothing of the replay runs
// once the lock goes.
func TestRealReplayStopsBehindALockNobodyReleases(t *testing.T) {
	mariadbServer(t)
	emptySite(t)
	setVar(t, &stallTimeout, time.Second)
	var sql strings.Builder
	sql.WriteString("CREATE TABLE ktvs_videos (id INT PRIMARY KEY, a CHAR(100));\nINSERT INTO ktvs_videos VALUES (1, 'first');\n")
	sql.WriteString("CREATE TABLE ktvs_after (id INT PRIMARY KEY, a CHAR(100));\n")
	insertRows(&sql, "ktvs_after", 80)
	path := replayTestArchive(t, sql.String())
	inSite(t, "CREATE TABLE ktvs_videos (id INT PRIMARY KEY, a CHAR(100));\nINSERT INTO ktvs_videos VALUES (1, 'live');\n")
	commit := openTransaction(t, "SELECT COUNT(*) FROM ktvs_videos;\n")
	answers := probeAnswers(t)
	// Should the replay wait on, the test ends it rather than hang.
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	start := time.Now()
	err := RestoreDatabase(ctx, path, mariadb.name, nil)
	t.Logf("the replay ended after %s: %v", time.Since(start).Round(time.Millisecond), err)
	var stalled *stallError
	if !errors.As(err, &stalled) || !strings.Contains(err.Error(), "waiting (Waiting for table metadata lock)") {
		t.Fatalf("err = %v, want the replay stopped while its statement waits for the lock", err)
	}
	if !slices.ContainsFunc(answers(), inState("Waiting for table metadata lock")) {
		t.Errorf("the server was never asked about the replay while it waited for the lock, so the test proves nothing: answers %q", answers())
	}
	// The statement of the replay waits no more on the server.
	for deadline := time.Now().Add(10 * time.Second); ; {
		left := strings.TrimSpace(asRoot(t, "SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE STATE = 'Waiting for table metadata lock';\n"))
		if left == "0" {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("%s statements still wait for the lock after the replay was stopped", left)
		}
		time.Sleep(20 * time.Millisecond)
	}
	commit()
	time.Sleep(time.Second)
	if got := strings.TrimSpace(inSite(t, "SELECT a FROM ktvs_videos;\nSELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = 'ktvs_after';\n")); got != "live\n0" {
		t.Errorf("once the lock went the database holds %q, want its live row alone: the stopped replay ran on", got)
	}
}

// openTransaction runs sql in a transaction that stays open, its
// connection idle, as a request of the site that died half way leaves
// one: the tables it read stay locked against a DROP until commit, which
// the end of the test also calls.
func openTransaction(t *testing.T, sql string) (commit func()) {
	t.Helper()
	cmd := exec.Command("docker", "exec", "-i", mariadb.name, "sh", "-c", `MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb --batch --skip-column-names "$MARIADB_DATABASE"`)
	stdin, err := cmd.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	var once sync.Once
	commit = func() {
		once.Do(func() {
			_, _ = io.WriteString(stdin, "COMMIT;\n")
			_ = stdin.Close()
			ended := make(chan error, 1)
			go func() { ended <- cmd.Wait() }()
			select {
			case err := <-ended:
				if err != nil {
					t.Errorf("the open transaction ended with %v", err)
				}
			case <-time.After(30 * time.Second):
				_ = cmd.Process.Kill()
				t.Error("the open transaction did not end")
			}
		})
	}
	t.Cleanup(commit)
	// The user lock taken after sql says that sql ran.
	if _, err := io.WriteString(stdin, "BEGIN;\n"+sql+"DO GET_LOCK('kvsctltest-open-transaction', 0);\n"); err != nil {
		t.Fatal(err)
	}
	for deadline := time.Now().Add(30 * time.Second); strings.TrimSpace(asRoot(t, "SELECT IS_USED_LOCK('kvsctltest-open-transaction') IS NOT NULL;\n")) != "1"; {
		if time.Now().After(deadline) {
			t.Fatal("the transaction did not start")
		}
		time.Sleep(20 * time.Millisecond)
	}
	return commit
}

// A container that a run of these tests left behind, its test process
// gone, goes before the next run starts its own. The container of a run
// still going, this one here, stays, and so does one of another host,
// whose processes this one cannot see. Another run of these tests on this
// host may be sweeping too, and still be removing the container of the
// process that is gone when this one looks: that removal is waited for.
func TestSweepRemovesWhatADeadRunLeft(t *testing.T) {
	mariadbServer(t)
	host, err := os.Hostname()
	if err != nil {
		t.Fatal(err)
	}
	// No process has a number above the largest pid_max Linux allows.
	gone := 1 << 30
	containers := []struct {
		suffix, host string
		pid          int
		kept         bool
	}{
		{"sweep-gone", host, gone, false},
		{"sweep-alive", host, os.Getpid(), true},
		{"sweep-elsewhere", "elsewhere.invalid", gone, true},
	}
	for _, c := range containers {
		name := fmt.Sprintf("kvsctltest-backup-%d-%s", os.Getpid(), c.suffix)
		create := exec.Command("docker", "create", "--name", name, "--label", labelTests, "--label", fmt.Sprintf("%s=%d", labelPID, c.pid), "--label", labelHost+"="+c.host, mariadb.image)
		if out, err := create.CombinedOutput(); err != nil {
			t.Fatalf("docker create %s: %v: %s", name, err, out)
		}
		t.Cleanup(func() { _ = exec.Command("docker", "rm", "--force", "--volumes", name).Run() })
	}
	sweepLeftovers()
	for _, c := range containers {
		name := fmt.Sprintf("kvsctltest-backup-%d-%s", os.Getpid(), c.suffix)
		kept := exec.Command("docker", "container", "inspect", name).Run() == nil
		for deadline := time.Now().Add(30 * time.Second); kept && !c.kept && time.Now().Before(deadline); {
			time.Sleep(100 * time.Millisecond)
			kept = exec.Command("docker", "container", "inspect", name).Run() == nil
		}
		if kept != c.kept {
			t.Errorf("%s, of process %d on %s: kept %v, want %v", name, c.pid, c.host, kept, c.kept)
		}
	}
	if err := exec.Command("docker", "container", "inspect", mariadb.name).Run(); err != nil {
		t.Errorf("the container of this run went: %v", err)
	}
}

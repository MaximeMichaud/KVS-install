package upgrade

import (
	"fmt"
	"os"
	"slices"
	"strings"
	"testing"
	"time"
)

// rootCrontab is docker/cron/crontab before e3a1dd3: the cron image loaded
// it into root's own table, so its lines have no user field and the KVS
// task ran as root.
const rootCrontab = `# Set PATH for cron
PATH=/usr/local/bin:/usr/bin:/bin

# KVS Cron Job - runs every minute
* * * * * cd /var/www/kvs/admin/include && /usr/local/bin/php cron.php >> /var/log/cron.log 2>&1

# yt-dlp automatic update - weekly on Sunday at 4am
0 4 * * 0 { curl -fsSL https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -o /usr/local/bin/yt-dlp && chmod a+rx /usr/local/bin/yt-dlp; } >> /var/log/cron.log 2>&1

# Empty line required
`

// siteCrontab is docker/cron/crontab since e3a1dd3: an /etc/cron.d file
// whose user field runs the KVS task as www-data, uid 1000.
const siteCrontab = `# /etc/cron.d system crontab for the unprivileged KVS task.
SHELL=/bin/sh
PATH=/usr/local/bin:/usr/bin:/bin

# Run KVS as the same UID/GID that owns the shared application files.
* * * * * www-data cd /var/www/kvs/admin/include && /usr/local/bin/php cron.php >> /var/log/cron.log 2>&1
`

// handOverCall is the docker command that hands the site to uid 1000, as
// kvs-init's 60-permissions.sh does: a one-off PHP-FPM container, as root,
// changes the entries owned by anyone else, links themselves and never
// what they point to.
const handOverCall = "compose run --rm -T --no-deps --user 0:0 --entrypoint find php-fpm /var/www/kvs -ignore_readdir_race ( ! -uid 1000 -o ! -gid 1000 ) -exec chown -h 1000:1000 {} +"

// cronStack is a stack whose installed version ships the first crontab
// and whose next releases, 1.1.0 and on, ship the others.
func cronStack(t *testing.T, crontabs ...string) *stack {
	t.Helper()
	var rels []rel
	for i, crontab := range crontabs {
		rels = append(rels, rel{version: fmt.Sprintf("1.%d.0", i), files: map[string]string{"docker/cron/crontab": crontab}})
	}
	return newStack(t, "", rels[0], rels[1:]...)
}

// markHandedOver records in the state that an upgrade handed the site over.
func markHandedOver(s *stack) {
	s.t.Helper()
	r := s.runner()
	state, err := r.Inst.LoadState()
	if err != nil {
		s.t.Fatal(err)
	}
	state.SiteHandedOver = time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC)
	if err := r.Inst.SaveState(state); err != nil {
		s.t.Fatal(err)
	}
}

// handOvers counts the hand-overs the fake ran.
func handOvers(s *stack) int {
	return strings.Count(strings.Join(s.f.commands(), "\n")+"\n", handOverCall+"\n")
}

// upgradeTo upgrades the stack to version.
func upgradeTo(s *stack, version string) error {
	s.t.Helper()
	r := s.runner()
	r.Opts.Version = version
	return s.upgrade(r)
}

// answerHandOver has the fake answer the hand-over with code and stderr.
func answerHandOver(s *stack, code int, stderr string) {
	answerHandOvers(s, cliResponse{Stderr: stderr, Code: code})
}

// answerHandOvers has the fake answer the walks of the site, the hand-over
// and the check of what is left, with these responses in turn, the last one
// for every walk after them.
func answerHandOvers(s *stack, answers ...cliResponse) {
	s.f.with(func(f *fakeDocker) {
		f.hook = func(_ *fakeDocker, req cliRequest) (cliResponse, bool) {
			if !slices.Contains(req.Args, "find") {
				return cliResponse{}, false
			}
			answer := answers[0]
			if len(answers) > 1 {
				answers = answers[1:]
			}
			return answer, true
		}
	})
}

// An adopted stack whose cron ran the KVS task as root moves to one that
// runs it as www-data: once the old cron container is gone, the run hands
// the entries the old task created to uid 1000, the user the task runs as
// now, so cron.php can rewrite and remove them, and records it.
func TestUpgradeHandsRootCronFilesToTheSite(t *testing.T) {
	s := cronStack(t, rootCrontab, siteCrontab)
	answerHandOver(s, 0, "")
	if err := s.upgrade(s.runner()); err != nil {
		t.Fatalf("upgrade: %v", err)
	}
	calls := s.f.commands()
	handed := slices.Index(calls, handOverCall)
	if handed < 0 {
		t.Fatalf("the run never handed the site to uid 1000; it ran:\n%s", strings.Join(calls, "\n"))
	}
	if n := handOvers(s); n != 1 {
		t.Errorf("the hand-over ran %d times, want once", n)
	}
	// After the old root cron stopped: before it, the task could still
	// create a file root owns.
	up := -1
	for i, c := range calls {
		if c == "compose up -d" {
			up = i
		}
	}
	if up < 0 || handed < up {
		t.Errorf("the hand-over (call %d) ran before the stack was brought up on the new files (call %d):\n%s", handed, up, strings.Join(calls, "\n"))
	}
	state := s.state()
	if state.Current != "1.1.0" {
		t.Errorf("the state records %s, want 1.1.0", state.Current)
	}
	if state.SiteHandedOver.IsZero() {
		t.Error("the state does not record the hand-over")
	}
}

// A stack an earlier kvsctl already upgraded from a checkout whose cron ran
// the task as root runs a www-data crontab now, and the files the old task
// left are still root's: the first upgrade that records no hand-over walks
// the site, whatever the crontab of the running version says, and the next
// one does not.
func TestUpgradeHandsTheSiteOverOncePerStack(t *testing.T) {
	for _, c := range []struct{ name, before string }{
		{"www-data before and after", siteCrontab},
		{"no crontab before", ""},
	} {
		t.Run(c.name, func(t *testing.T) {
			s := cronStack(t, c.before, siteCrontab, siteCrontab)
			answerHandOver(s, 0, "")
			if err := upgradeTo(s, "1.1.0"); err != nil {
				t.Fatalf("upgrade: %v", err)
			}
			if n := handOvers(s); n != 1 {
				t.Fatalf("the first upgrade handed the site over %d times, want once", n)
			}
			if s.state().SiteHandedOver.IsZero() {
				t.Fatal("the state does not record the hand-over")
			}
			if err := upgradeTo(s, "1.2.0"); err != nil {
				t.Fatalf("second upgrade: %v", err)
			}
			if n := handOvers(s); n != 1 {
				t.Errorf("the hand-over ran %d times over two upgrades, want once", n)
			}
		})
	}
}

// The site was handed over, and the running version's cron runs the task
// as www-data, or the target does not: the run does not walk the site.
func TestUpgradeLeavesOwnersWhenTheSiteWasHandedOver(t *testing.T) {
	for _, c := range []struct {
		name, before, after string
		marked              bool
	}{
		{"handed over, www-data before and after", siteCrontab, siteCrontab, true},
		{"a target that does not run the task as www-data", rootCrontab, rootCrontab, false},
		{"a target without a KVS task", siteCrontab, "", false},
	} {
		t.Run(c.name, func(t *testing.T) {
			s := cronStack(t, c.before, c.after)
			if c.marked {
				markHandedOver(s)
			}
			answerHandOver(s, 0, "")
			if err := s.upgrade(s.runner()); err != nil {
				t.Fatalf("upgrade: %v", err)
			}
			for _, call := range s.f.commands() {
				if strings.Contains(call, "chown") {
					t.Errorf("the run changed owners: %s", call)
				}
			}
		})
	}
}

// A rollback can lay a version whose cron runs the task as root back, after
// a hand-over: the next upgrade to a www-data crontab walks the site again.
func TestUpgradeHandsOverAgainAfterARootCron(t *testing.T) {
	s := cronStack(t, rootCrontab, siteCrontab)
	markHandedOver(s)
	answerHandOver(s, 0, "")
	if err := s.upgrade(s.runner()); err != nil {
		t.Fatalf("upgrade: %v", err)
	}
	if n := handOvers(s); n != 1 {
		t.Errorf("the hand-over ran %d times, want once", n)
	}
}

// A hand-over the mount refuses in part (NFS with root_squash) does not
// undo the upgrade: the files it could not change keep their owner, as they
// had under the old cron, the run says so where the operator reads it, and
// the next upgrade tries again.
func TestUpgradeGoesOnWhenTheHandOverFails(t *testing.T) {
	s := cronStack(t, rootCrontab, siteCrontab, siteCrontab)
	answerHandOver(s, 1, "chown: changing ownership of '/var/www/kvs/admin/data/x': Operation not permitted\n")
	if err := upgradeTo(s, "1.1.0"); err != nil {
		t.Fatalf("upgrade: %v", err)
	}
	state := s.state()
	if state.Current != "1.1.0" {
		t.Errorf("the state records %s, want 1.1.0", state.Current)
	}
	if !state.SiteHandedOver.IsZero() {
		t.Error("the state records a hand-over that failed")
	}
	var notice string
	for _, line := range s.rep.notices() {
		if strings.Contains(line, "uid 1000") {
			notice = line
		}
	}
	if notice == "" {
		t.Fatal("no notice says the site keeps files of another owner")
	}
	if !strings.Contains(notice, "Operation not permitted") || !strings.Contains(notice, "chown -h 1000:1000") {
		t.Errorf("the notice names neither the cause nor the command to finish by hand: %q", notice)
	}
	answerHandOver(s, 0, "")
	if err := upgradeTo(s, "1.2.0"); err != nil {
		t.Fatalf("second upgrade: %v", err)
	}
	if n := handOvers(s); n != 2 {
		t.Errorf("the hand-over ran %d times over two upgrades, want twice", n)
	}
	if s.state().SiteHandedOver.IsZero() {
		t.Error("the state does not record the hand-over that succeeded")
	}
}

// handOverLeftCall is the walk that prints the first entry of the site
// another user still owns. Its comparisons hold no negation: an entry
// removed before find read its owner fails every one of them, where
// "! -uid 1000" would print it as left.
const handOverLeftCall = "compose run --rm -T --no-deps --user 0:0 --entrypoint find php-fpm /var/www/kvs -ignore_readdir_race ( -uid -1000 -o -uid +1000 -o -gid -1000 -o -gid +1000 ) -print -quit"

// An entry the site removes after find matched it makes the batched chown
// fail, which -ignore_readdir_race does not cover: after a failed walk, the
// run looks for an entry of another owner, and none left is a hand-over.
// One left, as a mount that refuses the change leaves it, is not.
func TestUpgradeHandOverCountsWhatIsLeft(t *testing.T) {
	vanished := cliResponse{Code: 1, Stderr: "chown: cannot access '/var/www/kvs/admin/data/engine/x.lock': No such file or directory\n"}
	for _, c := range []struct {
		name    string
		answers []cliResponse
		handed  bool
	}{
		{"none left", []cliResponse{vanished, {}}, true},
		{"one left", []cliResponse{vanished, {Stdout: "/var/www/kvs/admin/data/engine/y.dat\n"}}, false},
		{"the check failed", []cliResponse{vanished, {Code: 1}}, false},
	} {
		t.Run(c.name, func(t *testing.T) {
			s := cronStack(t, rootCrontab, siteCrontab)
			answerHandOvers(s, c.answers...)
			if err := s.upgrade(s.runner()); err != nil {
				t.Fatalf("upgrade: %v", err)
			}
			calls := s.f.commands()
			walk, check := slices.Index(calls, handOverCall), slices.Index(calls, handOverLeftCall)
			if walk < 0 || check < walk {
				t.Fatalf("want the hand-over, then the check of what is left:\n%s", strings.Join(calls, "\n"))
			}
			var notice string
			for _, line := range s.rep.notices() {
				if strings.Contains(line, "uid 1000") {
					notice = line
				}
			}
			if handed := !s.state().SiteHandedOver.IsZero(); handed != c.handed || (notice == "") != c.handed {
				t.Errorf("recorded=%t notice=%q, want a hand-over %t", handed, notice, c.handed)
			}
		})
	}
	// A walk that changed every entry needs no check.
	s := cronStack(t, rootCrontab, siteCrontab)
	answerHandOver(s, 0, "")
	if err := s.upgrade(s.runner()); err != nil {
		t.Fatalf("upgrade: %v", err)
	}
	if slices.Contains(s.f.commands(), handOverLeftCall) {
		t.Error("the run checked what is left after a walk that succeeded")
	}
}

func TestKVSTaskUser(t *testing.T) {
	cases := []struct {
		name, crontab string
		task, site    bool
	}{
		{"the crontab root loaded before e3a1dd3", rootCrontab, true, false},
		{"the cron.d file since e3a1dd3", siteCrontab, true, true},
		{"a cron.d line that names root", "* * * * * root cd /var/www/kvs/admin/include && php cron.php\n", true, false},
		{"a commented task", "# * * * * * www-data php cron.php\n", false, false},
		{"no KVS task", "0 4 * * 0 root true\n", false, false},
		{"empty", "", false, false},
		{"CRLF line endings", strings.ReplaceAll(siteCrontab, "\n", "\r\n"), true, true},
		{"an indented line", "  * * * * *  www-data  cd /var/www/kvs/admin/include && php cron.php\n", true, true},
		{"a setting that names cron.php", "MAILTO=cron.php\n", false, false},
		{"root's table, a command that names www-data", "* * * * * cd /var/www/kvs/admin/include && php cron.php >> /var/log/www-data.log\n", true, false},
		{"the kvs-cron-run wrapper", "* * * * * www-data /usr/local/bin/kvs-cron-run\n", true, true},
		{"the wrapper through PATH", "* * * * * www-data kvs-cron-run\n", true, true},
		{"the wrapper in root's table", "* * * * * /usr/local/bin/kvs-cron-run\n", true, false},
		{"the health check, not the task", "* * * * * www-data /usr/local/bin/kvs-cron-health\n", false, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			task, site := kvsTaskUser([]byte(c.crontab))
			if task != c.task || site != c.site {
				t.Errorf("kvsTaskUser = (%t, %t), want (%t, %t)", task, site, c.task, c.site)
			}
		})
	}
}

// The crontab this tree ships must read as a KVS task run by www-data,
// whatever command it uses: otherwise an upgrade into it would never hand
// the files of an old root cron to the site.
func TestKVSTaskUserOfTheShippedCrontab(t *testing.T) {
	data, err := os.ReadFile("../../../" + kvsCrontab)
	if err != nil {
		t.Fatal(err)
	}
	if task, site := kvsTaskUser(data); !task || !site {
		t.Errorf("kvsTaskUser(%s) = (%t, %t), want (true, true):\n%s", kvsCrontab, task, site, data)
	}
}

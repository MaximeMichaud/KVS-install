package doctor

import (
	"archive/tar"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"golang.org/x/sys/unix"

	"github.com/MaximeMichaud/KVS-install/cli/internal/diskspace"
	"github.com/MaximeMichaud/KVS-install/cli/internal/instance"
)

func TestStorageThresholds(t *testing.T) {
	for _, tc := range []struct {
		name  string
		space diskspace.Space
		err   error
		want  string
	}{
		{"healthy", diskspace.Space{Size: 100 << 30, Avail: 42 << 30}, nil, OK},
		{"low-space", diskspace.Space{Size: 100 << 30, Avail: 5 << 30}, nil, Warn},
		{"reserve", diskspace.Space{Size: 100 << 30, Avail: 1 << 30}, nil, Fail},
		{"read-only", diskspace.Space{Size: 100 << 30, Avail: 42 << 30, ReadOnly: true}, nil, Fail},
		{"low-inodes", diskspace.Space{Size: 100 << 30, Avail: 42 << 30, Files: 1000, FreeFiles: 40}, nil, Warn},
		{"no-inodes", diskspace.Space{Size: 100 << 30, Avail: 42 << 30, Files: 1000}, nil, Fail},
		{"dynamic-inodes", diskspace.Space{Size: 100 << 30, Avail: 42 << 30, Files: 0, FreeFiles: 0}, nil, OK},
		{"unreadable", diskspace.Space{}, errors.New("permission denied"), Fail},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r, _ := fixture(t)
			r.opts.Only = []string{"storage.installation"}
			r.probe.space = func(string) (diskspace.Space, error) { return tc.space, tc.err }
			if got := resultByID(t, r.run(context.Background()), "storage.installation"); got.Status != tc.want {
				t.Fatalf("%+v", got)
			}
		})
	}
	t.Run("missing-mount", func(t *testing.T) {
		r, f := fixture(t)
		r.opts.Only = []string{"storage.data"}
		f.mountErr = errors.New("missing")
		report := r.run(context.Background())
		if report.ExitCode != 1 || report.Complete {
			t.Fatalf("%+v", report)
		}
	})
	t.Run("unwritable-directory", func(t *testing.T) {
		if os.Geteuid() == 0 {
			t.Skip("root can write through Unix permission bits")
		}
		r, _ := fixture(t)
		r.opts.Only = []string{"storage.installation"}
		if err := os.Chmod(r.inst.Root, 0o500); err != nil {
			t.Fatal(err)
		}
		defer os.Chmod(r.inst.Root, 0o700)
		if resultByID(t, r.run(context.Background()), "storage.installation").Status != Fail {
			t.Fatal("unwritable directory passed")
		}
	})
}

func testArchive(t *testing.T, path string, withDump bool) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	tw := tar.NewWriter(f)
	files := map[string]string{"backup.json": `{"format":2,"version":"1.0.0","domain":"example.test","sequence":1}`}
	if withDump {
		files["database.sql.zst"] = "fixture-only-not-a-tested-restore"
	}
	for name, data := range files {
		if err := tw.WriteHeader(&tar.Header{Name: name, Mode: 0o600, Size: int64(len(data))}); err != nil {
			t.Fatal(err)
		}
		if _, err := tw.Write([]byte(data)); err != nil {
			t.Fatal(err)
		}
	}
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestBackupsDescribeWithoutClaimingRestorability(t *testing.T) {
	for _, tc := range []struct {
		name     string
		withDump bool
		want     string
	}{{"metadata", true, OK}, {"missing-dump", false, Fail}} {
		t.Run(tc.name, func(t *testing.T) {
			r, _ := fixture(t)
			r.opts.Only = []string{"backups"}
			testArchive(t, filepath.Join(r.inst.BackupDir(), "backup-1.0.0-"+time.Now().UTC().Format("20060102-150405")+".tar"), tc.withDump)
			result := resultByID(t, r.run(context.Background()), "backups")
			if result.Status != tc.want {
				t.Fatalf("%+v", result)
			}
			if result.Status == OK && !strings.Contains(result.Message, "restore was not tested") {
				t.Fatalf("overstated validation: %+v", result)
			}
		})
	}
	t.Run("corrupt", func(t *testing.T) {
		r, _ := fixture(t)
		r.opts.Only = []string{"backups"}
		writeFile(t, filepath.Join(r.inst.BackupDir(), "backup-1.0.0-20261001-120000.tar"), "not-a-tar")
		if resultByID(t, r.run(context.Background()), "backups").Status != Fail {
			t.Fatal("corrupt archive passed")
		}
	})
	t.Run("fifo-does-not-hang", func(t *testing.T) {
		r, _ := fixture(t)
		r.opts.Only = []string{"backups"}
		if err := os.MkdirAll(r.inst.BackupDir(), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := unix.Mkfifo(filepath.Join(r.inst.BackupDir(), "backup-1.0.0-20261001-120000.tar"), 0o600); err != nil {
			t.Fatal(err)
		}
		if resultByID(t, r.run(context.Background()), "backups").Status != Fail {
			t.Fatal("FIFO accepted")
		}
	})
}

func TestFilesAndRecordedImages(t *testing.T) {
	for _, changed := range []bool{false, true} {
		t.Run(map[bool]string{false: "unchanged", true: "edited"}[changed], func(t *testing.T) {
			r, _ := fixture(t)
			r.opts.Only = []string{"files"}
			writeFile(t, filepath.Join(r.inst.Root, "tracked.txt"), "original\n")
			sum := sha256.Sum256([]byte("original\n"))
			data, _ := json.Marshal(instance.State{Current: "1.0.0", Checksums: map[string]string{"tracked.txt": hex.EncodeToString(sum[:])}})
			writeFile(t, filepath.Join(r.inst.StateDir(), "state.json"), string(data))
			if changed {
				writeFile(t, filepath.Join(r.inst.Root, "tracked.txt"), "customized\n")
			}
			want := OK
			if changed {
				want = Warn
			}
			if got := resultByID(t, r.run(context.Background()), "files"); got.Status != want {
				t.Fatalf("%+v", got)
			}
		})
	}
	t.Run("running-image-mismatch", func(t *testing.T) {
		r, f := fixture(t)
		r.opts.Only = []string{"images"}
		p, _ := r.probe.compose(context.Background(), "")
		pin := "example/image@sha256:" + strings.Repeat("a", 64)
		for name, cfg := range p.Services {
			cfg.Image = pin
			p.Services[name] = cfg
		}
		f.wrong = []string{"nginx: image ID differs"}
		data, _ := json.Marshal(instance.State{Current: "1.0.0", ReleaseImages: map[string][]string{"1.0.0": {pin}}})
		writeFile(t, filepath.Join(r.inst.StateDir(), "state.json"), string(data))
		if resultByID(t, r.run(context.Background()), "images").Status != Fail || f.pins["nginx"] != pin {
			t.Fatalf("pins=%v", f.pins)
		}
	})
}

func TestImageConfigurationDriftIsVisibleBeforeRecreation(t *testing.T) {
	r, _ := fixture(t)
	r.opts.Only = []string{"images"}
	p, _ := r.probe.compose(context.Background(), "")
	pin := "example/image@sha256:" + strings.Repeat("a", 64)
	for service, cfg := range p.Services {
		cfg.Image = "example/image:newer"
		p.Services[service] = cfg
	}
	data, _ := json.Marshal(instance.State{Current: "1.0.0", ReleaseImages: map[string][]string{"1.0.0": {pin}}})
	writeFile(t, filepath.Join(r.inst.StateDir(), "state.json"), string(data))
	if got := resultByID(t, r.run(context.Background()), "images"); got.Status != Warn {
		t.Fatalf("%+v", got)
	}
}

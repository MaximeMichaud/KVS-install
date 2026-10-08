package instance

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// The runs a journal records, named the way the history of the state
// names them. A restore replays an archive over the database and adds no
// entry to the history.
const (
	ActionUpgrade  = "upgrade"
	ActionRollback = "rollback"
	ActionRestore  = "restore"
)

// The phases of a run, in the order an upgrade goes through them. A run
// that undoes what it did, after a failure or on recover, is in
// PhaseRollback. A manual rollback that replays a dump, and a restore,
// begin in PhaseBackup: the services that write are stopped and the live
// database is backed up. A restore then replays its archive in
// PhaseReplay, and starts the services again in PhaseRestart.
const (
	PhaseBackup   = "backup"
	PhaseApply    = "apply"
	PhaseRestart  = "restart"
	PhaseVerify   = "verify"
	PhaseRecord   = "record"
	PhaseRollback = "rollback"
	PhaseReplay   = "replay"
)

// JournalFormat is the format of the journal of a run this kvsctl begins: 2
// since the entry a run adds to the history carries the start of the run
// as its date. An older kvsctl wrote no format, and dated that entry when
// it wrote it.
const JournalFormat = 2

// Journal is kvsctl/journal.json: what a run that changes the stack has done
// so far. It is written before the first change of an upgrade, a manual
// rollback or a restore and again at each phase, and removed once the run
// is recorded in the state, rolled back or, for a restore, over. A journal
// that is still there names a run that died part way, power cut and
// SIGKILL included, which kvsctl recover finishes or undoes from what it
// says.
type Journal struct {
	// Format is JournalFormat for a run this kvsctl began, 0 for the
	// journal of an older one. SaveJournal sets it on the first save of a
	// run.
	Format int `json:"format,omitempty"`
	// Action is the run: ActionUpgrade, ActionRollback or ActionRestore.
	Action string `json:"action"`
	// From is the version the stack ran when the run started, and To the
	// one the run installs. They are equal when an upgrade applies the
	// installed release again with other variants.
	From string `json:"from"`
	To   string `json:"to"`
	// Started is when the run started, and Updated when the journal was
	// last written. SaveJournal sets both. Started also names the run: the
	// entry it adds to the history of the state carries it as its date,
	// which is how recover tells that the state already records the end
	// of this run, whatever the clock did since. The entry of a run whose
	// journal has no Format is dated when it was written.
	Started time.Time `json:"started"`
	Updated time.Time `json:"updated"`
	// Phase is the phase the run had reached.
	Phase string `json:"phase"`
	// Log is the path of the log the run writes.
	Log string `json:"log,omitempty"`
	// Backup is the archive the run took before its first change, by its
	// absolute path, empty when it took none.
	Backup string `json:"backup,omitempty"`
	// Replay is the archive a manual rollback or a restore replays into
	// the database.
	Replay string `json:"replay,omitempty"`
	// Env is set on a restore that also puts back the .env the archive
	// carries.
	Env bool `json:"env,omitempty"`
	// Applied is set once release files were laid over the installation.
	Applied bool `json:"applied,omitempty"`
	// ComposeStarted is set once a docker compose up process started.
	ComposeStarted bool `json:"compose_started,omitempty"`
	// MariaDB is the mariadb container as it was right before compose up:
	// the one found after a failure or on recover tells whether up
	// recreated it.
	MariaDB ContainerMark `json:"mariadb,omitzero"`
	// MariaDBRecreated is set once the run found the mariadb container
	// replaced or restarted.
	MariaDBRecreated bool `json:"mariadb_recreated,omitempty"`
	// OneWay and Database are what the run installs declares, as in
	// State, and RestoreDB is set when the operator asked for the dump to
	// be replayed on a rollback whatever the release declares.
	OneWay    bool   `json:"one_way,omitempty"`
	Database  string `json:"database,omitempty"`
	RestoreDB bool   `json:"restore_db,omitempty"`
	// Files lists the release files of To, relative to the root.
	Files []string `json:"files,omitempty"`
	// ImagesAfter are the variant settings the run writes to .env,
	// KVS_<SERVICE>_IMAGE to ref@digest and MARIADB_VERSION on a series
	// change, and ImagesBefore what .env held for those keys and for the
	// ones the run drops, before it: a key missing from ImagesBefore was
	// not in .env, and a rollback removes it.
	ImagesBefore map[string]string `json:"images_before,omitempty"`
	ImagesAfter  map[string]string `json:"images_after,omitempty"`
	// ComposeFileBefore is COMPOSE_FILE in .env before the run, empty when
	// .env set none.
	ComposeFileBefore string `json:"compose_file_before,omitempty"`
	// Pins are the images To pins, as ref@digest, which the state keeps in
	// ReleaseImages once the run is recorded.
	Pins []string `json:"pins,omitempty"`
	// Ignored are the services the verification of the run leaves out:
	// the ones already unhealthy before it, accepted with
	// --allow-unhealthy. A rollback run later from the journal judges the
	// stack the same way.
	Ignored []string `json:"ignored,omitempty"`
	// Services are the services compose ran when the run began, and
	// Containers the container of each of them then, by service. Recover
	// compares them with the containers it finds, which tells a run whose
	// compose never started from one whose files someone brought up by
	// hand since, and a rollback removes the containers of the services
	// the version it leaves added.
	Services   []string          `json:"services,omitempty"`
	Containers map[string]string `json:"containers,omitempty"`
	// Stopped are the services the run stopped before its backup and its
	// replay, so that nothing writes to the database meanwhile: a run
	// undone before compose started brings them back.
	Stopped []string `json:"stopped,omitempty"`
	// DataFolder is the folder of the MariaDB data volume the run moves
	// the data files to, named before the move begins. DataMoved is set
	// once every file moved, before any server starts on the fresh
	// directory, and DataBack once recover put the files of a one-way
	// rollback back in place.
	DataFolder string `json:"data_folder,omitempty"`
	DataMoved  bool   `json:"data_moved,omitempty"`
	DataBack   bool   `json:"data_back,omitempty"`
	// Cause is why the run itself failed or was cancelled, before anything
	// undid it, and Outcome which of the two it was, OutcomeFailed or
	// OutcomeCancelled: the entry recover adds to the history once the run
	// is undone says it. A run cut short records neither.
	Cause   string `json:"cause,omitempty"`
	Outcome string `json:"outcome,omitempty"`
	// Failed is when the run, or the last attempt to undo or finish it,
	// stopped on an error and left the journal, and Failure that error: a
	// journal that records one names a run that failed, not one cut short.
	Failed  time.Time `json:"failed,omitzero"`
	Failure string    `json:"failure,omitempty"`
}

// ContainerMark tells one life of a container from the next: a container
// that was recreated has another ID, and one that was restarted another
// start time.
type ContainerMark struct {
	ID      string    `json:"id,omitempty"`
	Started time.Time `json:"started,omitzero"`
}

func (i *Instance) journalPath() string { return filepath.Join(i.StateDir(), "journal.json") }

// LoadJournal reads the journal; nil and no error when there is none, which
// is the case whenever no run was interrupted.
func (i *Instance) LoadJournal() (*Journal, error) {
	data, err := os.ReadFile(i.journalPath())
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var j Journal
	if err := json.Unmarshal(data, &j); err != nil {
		return nil, fmt.Errorf("%s: %w", i.journalPath(), err)
	}
	return &j, nil
}

// SaveJournal writes the journal atomically, flushed to the disk before it
// returns, so the phase it records survives a power cut. It sets Updated to
// now, and Started and Format too on the first save of a run: the journal
// of a run an older kvsctl began keeps its own.
func (i *Instance) SaveJournal(j *Journal) error {
	if err := os.MkdirAll(i.StateDir(), 0o750); err != nil {
		return err
	}
	j.Updated = time.Now().UTC()
	if j.Started.IsZero() {
		j.Started, j.Format = j.Updated, JournalFormat
	}
	data, err := json.MarshalIndent(j, "", "  ")
	if err != nil {
		return err
	}
	return writeAtomic(i.journalPath(), append(data, '\n'), 0o600)
}

// RemoveJournal removes the journal once its run is recorded or rolled
// back, and flushes the directory: a journal that came back after a power
// cut would have recover finish a run twice. No journal is not an error.
func (i *Instance) RemoveJournal() error {
	err := os.Remove(i.journalPath())
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	return syncDir(i.StateDir())
}

// Describe says which run the journal records and where it stopped, the
// way status shows it. The state names the versions the way the operator
// reads them, an unreleased checkout by its commit; without a state they
// read as the journal records them. A run that failed is told as one,
// dated when it failed and with why: an operator who reads it hours later
// must not take it for a run that was cut short.
func (j *Journal) Describe(state *State) string {
	started := j.Started.UTC().Format("2006-01-02 15:04")
	run := "a run"
	switch j.Action {
	case ActionUpgrade:
		run = "an upgrade"
	case ActionRollback:
		run = "a rollback"
	}
	versions := fmt.Sprintf("from %s to %s", state.Label(j.From), state.Label(j.To))
	if j.Action == ActionRestore {
		run, versions = "a restore", "of "+filepath.Base(j.Replay)
	}
	if j.Failed.IsZero() {
		return fmt.Sprintf("%s %s was interrupted during %s on %s UTC", run, versions, j.Phase, started)
	}
	failed := j.Failed.UTC().Format("2006-01-02 15:04")
	switch {
	case j.Phase != PhaseRollback || j.Action == ActionRestore:
		return fmt.Sprintf("%s %s failed during %s on %s UTC: %s", run, versions, j.Phase, failed, j.Failure)
	case j.Action == ActionRollback:
		return fmt.Sprintf("undoing a rollback %s failed on %s UTC: %s", versions, failed, j.Failure)
	}
	return fmt.Sprintf("the rollback of %s %s failed on %s UTC: %s", run, versions, failed, j.Failure)
}

// Interrupted is the refusal of every command that must not run while the
// journal is there, with the versions named as Describe names them.
func (j *Journal) Interrupted(state *State) error {
	if !j.Failed.IsZero() {
		return fmt.Errorf("%s; once the cause is fixed, run 'kvsctl recover'", j.Describe(state))
	}
	return fmt.Errorf("%s: run 'kvsctl recover'", j.Describe(state))
}

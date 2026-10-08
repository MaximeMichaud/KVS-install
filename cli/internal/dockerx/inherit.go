package dockerx

import (
	"os"
	"slices"
	"sync"
)

// inherited are the open files every docker child of kvsctl inherits past
// its standard streams, from the fourth descriptor on.
var (
	inheritMu sync.Mutex
	inherited []*os.File
)

// Inherit has every docker child started from now on inherit f, until the
// returned function is called. f must stay open until then, and the caller
// calls it once no docker command can start any more: a child that starts
// reads the descriptor of f. The lock of an instance goes this way: a flock
// is held while any descriptor of it is open, so a docker command that
// outlives kvsctl, killed in the middle of a run, keeps the instance locked
// until it ends too, and no second run starts compose on the same project
// beside it.
func Inherit(f *os.File) (forget func()) {
	inheritMu.Lock()
	inherited = append(inherited, f)
	inheritMu.Unlock()
	var once sync.Once
	return func() {
		once.Do(func() {
			inheritMu.Lock()
			defer inheritMu.Unlock()
			if n := slices.Index(inherited, f); n >= 0 {
				inherited = slices.Delete(inherited, n, n+1)
			}
		})
	}
}

// inheritedFiles is what a docker child starting now inherits.
func inheritedFiles() []*os.File {
	inheritMu.Lock()
	defer inheritMu.Unlock()
	return slices.Clone(inherited)
}

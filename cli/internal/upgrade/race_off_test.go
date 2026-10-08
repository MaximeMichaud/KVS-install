//go:build !race

package upgrade

// raceBuild is set when the tests run with the race detector: the kvsctl
// they build and run as a process gets it too.
const raceBuild = false

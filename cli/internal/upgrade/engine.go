package upgrade

import (
	"context"
	"fmt"
	"regexp"
	"strconv"
	"strings"

	"github.com/MaximeMichaud/KVS-install/cli/internal/dockerx"
)

// MinEngineAPI is the oldest Docker Engine API kvsctl talks to, the one
// Docker Engine 19.03 speaks. The client library kvsctl is built with
// refuses an older engine without saying so: it sends its own version, and
// the engine answers every request with a refusal that names neither kvsctl
// nor what to install.
const MinEngineAPI = "1.40"

// refusalRe reads the API version an engine names when it refuses a client
// newer than itself: "client version 1.52 is too new. Maximum supported API
// version is 1.39", or before Docker 17.06 "client is newer than server
// (client API version: 1.52, server API version: 1.24)".
var refusalRe = regexp.MustCompile(`(?:Maximum supported API version is|server API version:)\s*([0-9]+\.[0-9]+)`)

// tooOldEngine is the error of an engine older than MinEngineAPI, read from
// the refusal err carries; nil for any other error, an engine that refused
// for another reason included.
func tooOldEngine(err error) error {
	if err == nil {
		return nil
	}
	m := refusalRe.FindStringSubmatch(err.Error())
	if m == nil || !lessAPI(m[1], MinEngineAPI) {
		return nil
	}
	return fmt.Errorf("the Docker Engine of this machine speaks API %s, and kvsctl needs API %s or newer, which Docker Engine 19.03 and later speak: upgrade Docker, then run the command again", m[1], MinEngineAPI)
}

// lessAPI compares two API versions, major.minor, number by number: 1.9
// comes before 1.40.
func lessAPI(a, b string) bool {
	amajor, aminor := apiNumbers(a)
	bmajor, bminor := apiNumbers(b)
	if amajor != bmajor {
		return amajor < bmajor
	}
	return aminor < bminor
}

func apiNumbers(v string) (major, minor int) {
	m, n, _ := strings.Cut(v, ".")
	major, _ = strconv.Atoi(m)
	minor, _ = strconv.Atoi(n)
	return major, minor
}

// CheckEngine asks the engine what it is before a command relies on it,
// and refuses to go on when it does not answer, or answers a client it is
// too old for: a command that changes the stack would otherwise fail half
// way, at the first container it reads, after it changed the files.
func CheckEngine(ctx context.Context, docker *dockerx.Client) error {
	_, err := docker.Info(ctx)
	if err == nil {
		return nil
	}
	if tooOld := tooOldEngine(err); tooOld != nil {
		return tooOld
	}
	return fmt.Errorf("kvsctl cannot talk to the Docker engine (%s): start Docker if it is stopped, then run the command again", firstLine(err.Error()))
}

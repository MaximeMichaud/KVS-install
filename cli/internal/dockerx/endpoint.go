package dockerx

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// endpoint is the engine kvsctl talks to: the one the docker CLI of the
// machine talks to, which is where the compose and exec children of kvsctl
// go too. The CLI takes DOCKER_HOST, else the context DOCKER_CONTEXT names,
// else the currentContext of its config.json, else its default socket.
type endpoint struct {
	// host is the address of the engine a context gives; empty, the
	// client reads DOCKER_HOST and the TLS settings of the environment, or
	// takes the default socket.
	host string
	// context is the docker context host comes from, and source where its
	// name was read.
	context, source string
}

// contextMeta is the part of the meta.json of a docker context that says
// where its engine is.
type contextMeta struct {
	Endpoints map[string]struct {
		Host          string `json:"Host"`
		SkipTLSVerify bool   `json:"SkipTLSVerify"`
	} `json:"Endpoints"`
}

// resolveEndpoint finds the engine the way the docker CLI does. A context
// kvsctl cannot follow is refused rather than replaced by the default
// socket: kvsctl would then judge the containers of one engine while its
// compose children recreate those of another.
func resolveEndpoint() (endpoint, error) {
	if os.Getenv("DOCKER_HOST") != "" {
		return endpoint{}, nil
	}
	dir := cliConfigDir()
	name, source := os.Getenv("DOCKER_CONTEXT"), "DOCKER_CONTEXT"
	if name == "" && dir != "" {
		// A config.json the CLI cannot read leaves it on its default
		// context, with a warning: kvsctl does the same.
		config := filepath.Join(dir, "config.json")
		var cfg struct {
			CurrentContext string `json:"currentContext"`
		}
		if data, err := os.ReadFile(config); err == nil && json.Unmarshal(data, &cfg) == nil {
			name, source = cfg.CurrentContext, "the currentContext of "+config
		}
	}
	if name == "" || name == "default" {
		return endpoint{}, nil
	}
	ep := endpoint{context: name, source: source}
	refuse := func(why string) error {
		return fmt.Errorf("the docker context %q (%s) %s; set DOCKER_HOST to the engine of the stack to run kvsctl", name, source, why)
	}
	if dir == "" {
		return ep, refuse("cannot be read: kvsctl finds no Docker CLI configuration directory (set DOCKER_CONFIG or HOME)")
	}
	sum := sha256.Sum256([]byte(name))
	id := hex.EncodeToString(sum[:])
	path := filepath.Join(dir, "contexts", "meta", id, "meta.json")
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return ep, refuse("does not exist (" + path + " is missing), so the docker CLI cannot reach an engine either")
	}
	if err != nil {
		return ep, refuse("cannot be read: " + err.Error())
	}
	var meta contextMeta
	if err := json.Unmarshal(data, &meta); err != nil {
		return ep, refuse(path + " is not valid JSON: " + err.Error())
	}
	docker := meta.Endpoints["docker"]
	scheme, _, _ := strings.Cut(docker.Host, "://")
	switch {
	case docker.Host == "":
		return ep, refuse("names no engine")
	case docker.SkipTLSVerify || exists(filepath.Join(dir, "contexts", "tls", id, "docker")):
		return ep, refuse("reaches its engine over TLS, which kvsctl does not read from a context")
	case scheme != "unix" && scheme != "tcp":
		return ep, refuse("reaches its engine through " + scheme + ", which kvsctl does not do: run kvsctl on the machine of the engine")
	}
	ep.host = docker.Host
	return ep, nil
}

func exists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

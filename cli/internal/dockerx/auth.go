package dockerx

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/moby/moby/api/pkg/authconfig"
	"github.com/moby/moby/api/types/registry"
)

// helperTimeout bounds one call of a credential helper. A helper that asks
// for a passphrase nobody can type would otherwise hold the pull for ever;
// past it the pull goes on anonymously.
var helperTimeout = 20 * time.Second

// cliConfig is the part of the Docker CLI configuration (config.json) that
// says where the registry credentials are. An auths entry is the CLI's
// AuthConfig: "docker login" writes auth, base64 of user:password, and
// other tools write username and password as they are; the CLI reads both.
type cliConfig struct {
	Auths map[string]struct {
		Auth          string `json:"auth"`
		Username      string `json:"username"`
		Password      string `json:"password"`
		IdentityToken string `json:"identitytoken"`
		RegistryToken string `json:"registrytoken"`
	} `json:"auths"`
	CredsStore  string            `json:"credsStore"`
	CredHelpers map[string]string `json:"credHelpers"`
}

// credentials are what a pull sends the engine for one registry, and where
// they come from, for the message of a pull that fails.
type credentials struct {
	// header is the X-Registry-Auth value, empty for an anonymous pull.
	header string
	// note says where the credentials came from, or why there are none
	// although the configuration names some.
	note string
}

// cliConfigDir is where the Docker CLI keeps config.json: $DOCKER_CONFIG,
// or ~/.docker.
func cliConfigDir() string {
	if dir := os.Getenv("DOCKER_CONFIG"); dir != "" {
		return dir
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".docker")
}

// registryCredentials reads the credentials of the registry of ref the way
// the Docker CLI does, so a "docker login" on the machine counts for kvsctl:
// the credential helper of that registry (credHelpers), else the default
// store (credsStore), else the auth entry of config.json. A pull is
// anonymous when there are none, and also when they cannot be read: the
// images of a release are public, and an unreadable store must not stop an
// upgrade that does not need it.
func registryCredentials(ctx context.Context, ref string) credentials {
	key := registryKey(ref)
	dir := cliConfigDir()
	if dir == "" {
		return credentials{}
	}
	path := filepath.Join(dir, "config.json")
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return credentials{}
	}
	if err != nil {
		return credentials{note: fmt.Sprintf("pulled anonymously, %s could not be read: %v", path, err)}
	}
	var cfg cliConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		return credentials{note: fmt.Sprintf("pulled anonymously, %s is not valid JSON: %v", path, err)}
	}
	helper := cfg.CredHelpers[key]
	if helper == "" {
		helper = cfg.CredsStore
	}
	if helper != "" {
		return helperCredentials(ctx, helper, key)
	}
	return fileCredentials(cfg, key, path)
}

// fileCredentials reads the auth entry config.json keeps for the registry,
// the way the Docker CLI does: auth, when it is there, gives the user and
// the password, else the username and password fields do. A registry other
// than Docker Hub may be saved under a URL of its host ("https://ghcr.io"),
// which the Docker CLI accepts too. An entry that holds nothing to log in
// with leaves the pull anonymous, and says so.
func fileCredentials(cfg cliConfig, key, path string) credentials {
	entry, ok := cfg.Auths[key]
	if !ok && key != dockerHub {
		for saved, candidate := range cfg.Auths {
			if hostOf(saved) == key {
				entry, ok = candidate, true
				break
			}
		}
	}
	if !ok {
		return credentials{}
	}
	if entry.Auth == "" && entry.Username == "" && entry.Password == "" && entry.IdentityToken == "" && entry.RegistryToken == "" {
		return credentials{note: fmt.Sprintf("pulled anonymously, the %s entry of %s holds no credentials", key, path)}
	}
	auth := registry.AuthConfig{
		ServerAddress: key, IdentityToken: entry.IdentityToken, RegistryToken: entry.RegistryToken,
		Username: entry.Username, Password: entry.Password, // pragma: allowlist secret
	}
	if entry.Auth != "" {
		decoded, err := base64.StdEncoding.DecodeString(entry.Auth)
		if err != nil {
			return credentials{note: fmt.Sprintf("pulled anonymously, the %s entry of %s is not base64: %v", key, path, err)}
		}
		user, password, found := strings.Cut(string(decoded), ":")
		if !found {
			return credentials{note: fmt.Sprintf("pulled anonymously, the %s entry of %s holds no user:password", key, path)}
		}
		auth.Username, auth.Password = user, password // pragma: allowlist secret
	}
	return encode(auth, fmt.Sprintf("with the credentials %s keeps for %s", path, key))
}

// helperOutput is what "docker-credential-<name> get" prints.
type helperOutput struct {
	Username string `json:"Username"`
	Secret   string `json:"Secret"`
}

// helperCredentials asks a credential helper for the registry, the way the
// Docker CLI does: the server on stdin, the credentials as JSON on stdout.
// A helper that has none for that server, or that fails, leaves the pull
// anonymous.
func helperCredentials(ctx context.Context, helper, key string) credentials {
	name := "docker-credential-" + helper
	if strings.ContainsRune(helper, '/') {
		return credentials{note: fmt.Sprintf("pulled anonymously, %q is not a credential helper name", helper)}
	}
	ctx, cancel := context.WithTimeout(ctx, helperTimeout)
	defer cancel()
	cmd := command(ctx, name, "get")
	// A credential helper never acts on the project, and one may leave a
	// process behind, an agent it starts: it does not take the lock of the
	// installation along (Inherit).
	cmd.ExtraFiles = nil
	cmd.Stdin = strings.NewReader(key)
	stderr := &tailBuffer{max: 4 << 10}
	cmd.Stderr = stderr
	out, err := cmd.Output()
	if err != nil {
		// The helper prints why on stdout, or on stderr. Having nothing
		// for that registry is no failure: the pull is simply anonymous.
		why := strings.TrimSpace(string(out))
		if why == "" {
			why = stderr.String()
		}
		if strings.Contains(why, "credentials not found") {
			return credentials{}
		}
		return credentials{note: strings.TrimSpace(fmt.Sprintf("pulled anonymously, %s get %s failed: %v %s", name, key, err, firstLine(why)))}
	}
	var got helperOutput
	if err := json.Unmarshal(out, &got); err != nil {
		return credentials{note: fmt.Sprintf("pulled anonymously, %s get %s answered no JSON: %v", name, key, err)}
	}
	if got.Secret == "" {
		return credentials{}
	}
	auth := registry.AuthConfig{ServerAddress: key}
	// A helper keeps an identity token under this user name.
	if got.Username == "<token>" {
		auth.IdentityToken = got.Secret
	} else {
		auth.Username, auth.Password = got.Username, got.Secret // pragma: allowlist secret
	}
	return encode(auth, fmt.Sprintf("with the credentials of %s for %s", name, key))
}

func encode(auth registry.AuthConfig, note string) credentials {
	header, err := authconfig.Encode(auth)
	if err != nil {
		return credentials{note: "pulled anonymously, the credentials could not be encoded: " + err.Error()}
	}
	return credentials{header: header, note: note}
}

// hostOf is the host of a registry saved as a URL: the scheme and the path
// are dropped, which is how the Docker CLI matches such an entry.
func hostOf(saved string) string {
	saved = strings.TrimPrefix(strings.TrimPrefix(saved, "http://"), "https://")
	host, _, _ := strings.Cut(saved, "/")
	return host
}

func firstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return s[:i]
	}
	return s
}

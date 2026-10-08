package dotenv

import "strings"

// owned reports whether kvsctl owns a key of the project .env: the compose
// settings that say which project to read, and the settings an upgrade
// writes (the stack version, the pinned images, the PHP and MariaDB
// series). A value the shell running kvsctl exported must never decide
// them: compose prefers its environment to the file, and kvsctl reads the
// file.
func owned(key string) bool {
	switch key {
	case "COMPOSE_FILE", "COMPOSE_PROFILES", "COMPOSE_PROJECT_NAME", "COMPOSE_PATH_SEPARATOR",
		"COMPOSE_ENV_FILES", "COMPOSE_DISABLE_ENV_FILE",
		"KVS_STACK_VERSION", "MARIADB_VERSION", "PHP_VERSION", "PHP_FPM_BASE", "PHP_CLI_BASE":
		return true
	}
	return strings.HasPrefix(key, "KVS_") && strings.HasSuffix(key, "_IMAGE")
}

// process reports whether a key belongs to the process rather than to the
// stack: how the docker CLI reaches its engine and its configuration, and
// where programs are found. A .env that names one does not take it over.
func process(key string) bool {
	switch key {
	case "PATH", "HOME", "DOCKER_HOST", "DOCKER_CONTEXT", "DOCKER_CONFIG", "DOCKER_CERT_PATH",
		"DOCKER_TLS", "DOCKER_TLS_VERIFY", "DOCKER_API_VERSION":
		return true
	}
	return false
}

// Isolate is the environment of a docker compose command run on a project:
// environ without the keys kvsctl owns, and without every key env (the
// project .env) or example (the .env.example of the release) assigns a
// value, so compose takes each setting from the file, or from its default,
// exactly as kvsctl reads it. A shell that sourced an older .env, which is
// what the scripts do, exports all of them. A key env leaves to the
// environment, alone on its line, still reaches compose, unless kvsctl owns
// it.
func Isolate(environ []string, env, example []byte) []string {
	drop := dropped(env, example)
	out := make([]string, 0, len(environ))
	for _, entry := range environ {
		key, _, _ := strings.Cut(entry, "=")
		if drop(key) {
			continue
		}
		out = append(out, entry)
	}
	return out
}

// Lookup is the environment Isolate leaves, as the lookup Parse expands a
// .env with: what compose itself sees when it reads the file.
func Lookup(environ []string, env, example []byte) func(string) (string, bool) {
	values := map[string]string{}
	for _, entry := range Isolate(environ, env, example) {
		key, value, _ := strings.Cut(entry, "=")
		if _, seen := values[key]; !seen {
			values[key] = value
		}
	}
	return func(key string) (string, bool) {
		v, ok := values[key]
		return v, ok
	}
}

// dropped tells the keys Isolate removes.
func dropped(env, example []byte) func(string) bool {
	assigned := Assigned(env)
	for key := range Assigned(example) {
		assigned[key] = true
	}
	delegated := inherited(env)
	return func(key string) bool {
		switch {
		case process(key):
			return false
		case owned(key):
			return true
		case delegated[key]:
			return false
		}
		return assigned[key]
	}
}

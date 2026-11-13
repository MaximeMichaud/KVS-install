package upgrade

import "testing"

// directTLSProfiles adds the direct-tls profile only for a single-site
// Let's Encrypt or ZeroSSL stack that does not already turn it on, so the
// acme container survives the upgrade and the certificate keeps renewing.
func TestDirectTLSProfiles(t *testing.T) {
	cases := []struct {
		name string
		env  map[string]string
		want string
	}{
		{"single letsencrypt keeps the other profiles", map[string]string{"SSL_PROVIDER": "letsencrypt", "COMPOSE_PROFILES": "dragonfly"}, "dragonfly,direct-tls"},
		{"single zerossl with no profiles", map[string]string{"SSL_PROVIDER": "zerossl", "COMPOSE_PROFILES": ""}, "direct-tls"},
		{"an empty MODE is single", map[string]string{"MODE": "", "SSL_PROVIDER": "letsencrypt", "COMPOSE_PROFILES": "dragonfly,memcached"}, "dragonfly,memcached,direct-tls"},
		{"MODE single spelled out", map[string]string{"MODE": "single", "SSL_PROVIDER": "letsencrypt"}, "direct-tls"},
		{"already on", map[string]string{"SSL_PROVIDER": "letsencrypt", "COMPOSE_PROFILES": "dragonfly,direct-tls"}, ""},
		{"multi site never runs acme", map[string]string{"MODE": "multi", "SSL_PROVIDER": "letsencrypt", "COMPOSE_PROFILES": "dragonfly"}, ""},
		{"self-signed does not need acme", map[string]string{"SSL_PROVIDER": "selfsigned", "COMPOSE_PROFILES": "dragonfly"}, ""},
		{"no SSL provider", map[string]string{"COMPOSE_PROFILES": "dragonfly"}, ""},
		{"case is ignored", map[string]string{"MODE": "Single", "SSL_PROVIDER": "LetsEncrypt", "COMPOSE_PROFILES": "dragonfly"}, "dragonfly,direct-tls"},
		{"blank entries are dropped", map[string]string{"SSL_PROVIDER": "letsencrypt", "COMPOSE_PROFILES": "dragonfly, memcached ,"}, "dragonfly,memcached,direct-tls"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := directTLSProfiles(c.env); got != c.want {
				t.Errorf("directTLSProfiles(%v) = %q, want %q", c.env, got, c.want)
			}
		})
	}
}

// An upgrade of a single-site Let's Encrypt stack adopted from before acme
// moved behind the direct-tls profile adds the profile, so acme is not
// dropped, and a rollback puts COMPOSE_PROFILES back.
func TestUpgradeAddsDirectTLSProfile(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	s.setEnv("SSL_PROVIDER", "letsencrypt")
	s.setEnv("COMPOSE_PROFILES", "dragonfly")

	if err := s.upgrade(s.runner()); err != nil {
		t.Fatalf("upgrade: %v", err)
	}
	if got := s.env()["COMPOSE_PROFILES"]; got != "dragonfly,direct-tls" {
		t.Fatalf("COMPOSE_PROFILES after the upgrade = %q, want %q", got, "dragonfly,direct-tls")
	}

	s.fresh()
	if err := s.rollback(s.runner()); err != nil {
		t.Fatalf("rollback: %v", err)
	}
	if got := s.env()["COMPOSE_PROFILES"]; got != "dragonfly" {
		t.Errorf("COMPOSE_PROFILES after the rollback = %q, want %q", got, "dragonfly")
	}
}

// A self-signed stack does not run acme, so its COMPOSE_PROFILES is left as
// it is.
func TestUpgradeLeavesProfilesForSelfSigned(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	s.setEnv("SSL_PROVIDER", "selfsigned")
	s.setEnv("COMPOSE_PROFILES", "dragonfly")

	if err := s.upgrade(s.runner()); err != nil {
		t.Fatalf("upgrade: %v", err)
	}
	if got := s.env()["COMPOSE_PROFILES"]; got != "dragonfly" {
		t.Errorf("COMPOSE_PROFILES after the upgrade = %q, want %q", got, "dragonfly")
	}
}

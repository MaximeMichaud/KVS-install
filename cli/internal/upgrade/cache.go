package upgrade

import (
	"context"
	_ "embed"
	"encoding/json"
	"fmt"
	"slices"
	"strings"
	"time"

	"github.com/MaximeMichaud/KVS-install/cli/internal/dockerx"
	"github.com/MaximeMichaud/KVS-install/cli/internal/instance"
)

// The helper is part of kvsctl, so recovery does not depend on a script
// supplied by the release being undone. It never includes setup.php.
//
//go:embed cache_config.php
var cacheConfigPHP string

type cacheConfig struct {
	Host      string `json:"host"`
	Port      int    `json:"port"`
	Supported bool   `json:"supported"`
}

func (r *Runner) cacheCommand(ctx context.Context, mode, before, after string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, 45*time.Second)
	defer cancel()
	return dockerx.ComposeOutput(ctx, r.Inst.DockerDir, "run", "--rm", "-T", "--no-deps", "--entrypoint", "php", "php-fpm", "-r", strings.TrimPrefix(cacheConfigPHP, "<?php\n"), "--", mode, before, after)
}

func (r *Runner) cacheChange(ctx context.Context, policy string, services []string) (*instance.CacheChange, error) {
	if policy == "" {
		return nil, nil
	}
	if policy != "direct" {
		return nil, fmt.Errorf("unsupported cache routing %q: update kvsctl first", policy)
	}
	out, err := r.cacheCommand(ctx, "inspect", "", "")
	if err != nil {
		return nil, fmt.Errorf("inspect the application's cache setting: %w", err)
	}
	var config cacheConfig
	if err := json.Unmarshal([]byte(out), &config); err != nil {
		return nil, fmt.Errorf("read the application's cache setting: %w", err)
	}
	if !config.Supported || config.Port != 11211 || (config.Host != "127.0.0.1" && config.Host != "localhost") {
		r.log("the application cache setting is disabled, custom or already direct; it is unchanged")
		return nil, nil
	}
	if slices.Contains(services, "memcached") == slices.Contains(services, "dragonfly") {
		return nil, fmt.Errorf("direct cache routing needs exactly one active installer cache service")
	}
	return &instance.CacheChange{Before: config.Host, After: "cache"}, nil
}

func reverseCache(change *instance.CacheChange) *instance.CacheChange {
	if change == nil {
		return nil
	}
	return &instance.CacheChange{Before: change.After, After: change.Before}
}

func (r *Runner) applyCache(ctx context.Context, change *instance.CacheChange, undo bool) error {
	if change == nil {
		return nil
	}
	mode := "apply"
	if undo {
		mode, change = "undo", reverseCache(change)
	}
	if _, err := r.cacheCommand(ctx, mode, change.Before, change.After); err != nil {
		return fmt.Errorf("change the application's cache route: %w", err)
	}
	r.log("the application's cache route is set; the compatibility relay remains available")
	return nil
}

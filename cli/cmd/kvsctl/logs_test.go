package main

import (
	"strings"
	"testing"
)

func TestLogsArgs(t *testing.T) {
	cases := []struct {
		tail     int
		follow   bool
		services []string
		want     string
	}{
		{200, false, nil, "logs --no-color --tail 200"},
		{50, true, []string{"php-fpm"}, "logs --no-color --tail 50 -f php-fpm"},
		{-1, false, nil, "logs --no-color --tail 0"},
	}
	for _, c := range cases {
		if got := strings.Join(logsArgs(c.tail, c.follow, c.services), " "); got != c.want {
			t.Fatalf("logsArgs(%d, %v, %v) = %q, wanted %q", c.tail, c.follow, c.services, got, c.want)
		}
	}
}

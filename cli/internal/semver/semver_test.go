package semver

import (
	"strings"
	"testing"
)

func TestCompare(t *testing.T) {
	cases := []struct {
		a, b string
		want int
	}{
		{"0.1.0", "0.2.0", -1},
		{"1.0.0", "0.9.9", 1},
		{"v1.2.3", "1.2.3", 0},
		{"1.2.10", "1.2.9", 1},
		{"26.9.0", "26.10.0", -1},
		{"26.11.0-rc1", "26.11.0", -1},
		{"26.11.0", "26.11.0-rc1", 1},
		{"26.11.0-rc1", "26.11.0-rc2", -1},
		{"26.11.0-beta2", "26.11.0-rc1", -1},
		{"26.11.0-rc1", "26.11.0-rc1", 0},
		{"26.11.0-rc9", "26.11.0-rc10", -1},
		{"26.10.1-rc1", "26.11.0-rc1", -1},
	}
	for _, c := range cases {
		va, err := Parse(c.a)
		if err != nil {
			t.Fatal(err)
		}
		vb, err := Parse(c.b)
		if err != nil {
			t.Fatal(err)
		}
		if got := Compare(va, vb); got != c.want {
			t.Errorf("Compare(%s, %s) = %d, want %d", c.a, c.b, got, c.want)
		}
	}
	if _, err := Parse("1.2"); err == nil {
		t.Error("two components must be refused")
	}
	if _, err := Parse("1.b.3"); err == nil {
		t.Error("letters must be refused")
	}
	if !Less("0.9.0", "0.10.0") {
		t.Error("Less must compare numerically")
	}
	if !Less("26.11.0-rc1", "26.11.0") {
		t.Error("a candidate must sort before its release")
	}
}

func TestLeadingZeroIsRefused(t *testing.T) {
	for _, s := range []string{"26.01.0", "026.1.0", "26.1.00", "v26.01.0"} {
		v, err := Parse(s)
		if err == nil {
			t.Errorf("Parse(%q) = %s, a leading zero must be refused", s, v)
			continue
		}
		if got := err.Error(); !strings.Contains(got, "leading zero") {
			t.Errorf("Parse(%q) error = %q, it must name the rule", s, got)
		}
	}
	for _, s := range []string{"26.1.0", "0.1.0", "0.0.0", "26.10.11"} {
		if _, err := Parse(s); err != nil {
			t.Errorf("Parse(%q): %v", s, err)
		}
	}
}

func TestPrerelease(t *testing.T) {
	v, err := Parse("26.11.0-rc1")
	if err != nil {
		t.Fatal(err)
	}
	if v.Pre != "rc1" || v.Major != 26 || v.Minor != 11 || v.Patch != 0 {
		t.Fatalf("Parse = %+v", v)
	}
	if v.String() != "26.11.0-rc1" {
		t.Errorf("String = %q", v.String())
	}
	if release, err := Parse("26.11.0"); err != nil || release.String() != "26.11.0" {
		t.Errorf("a release must print without a suffix: %v %v", release, err)
	}
	if _, err := Parse("26.11.0-"); err == nil {
		t.Error("an empty pre-release must be refused")
	}
	if _, err := Parse("26.11.0-1rc"); err == nil {
		t.Error("digits before letters must be refused")
	}
	if _, err := Parse("26.11.0-rc.1"); err == nil {
		t.Error("a dotted pre-release must be refused")
	}
	if _, err := Parse("26.11.0-beta"); err != nil {
		t.Errorf("a pre-release without a number must be accepted: %v", err)
	}
}

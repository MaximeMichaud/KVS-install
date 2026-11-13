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

func TestIsPrerelease(t *testing.T) {
	for s, want := range map[string]bool{
		"26.11.0-rc1":  true,
		"26.11.0-beta": true,
		"v1.2.0-rc2":   true,
		"26.11.0":      false,
		"0.0.0":        false,
		"dev":          false,
		"26.11-rc1":    false,
		"":             false,
	} {
		if got := IsPrerelease(s); got != want {
			t.Errorf("IsPrerelease(%q) = %v, want %v", s, got, want)
		}
	}
}

// Compare reads a pre-release as its label and its number, which another
// spelling of either would leave alike: Parse refuses an upper case label
// and a number with a leading zero, as the release workflow refuses them in
// a tag, and a label without a number sorts before the same label with one.
// Two versions Parse accepts then compare equal only when they print alike.
func TestPrereleaseHasOneSpelling(t *testing.T) {
	for _, s := range []string{"26.11.0-RC1", "26.11.0-Rc1", "26.11.0-rC1", "26.11.0-BETA", "26.11.0-rc01", "26.11.0-rc00"} {
		if v, err := Parse(s); err == nil {
			t.Errorf("Parse(%q) = %s, which Compare reads as another spelling of a version", s, v)
		}
	}
	if _, err := Parse("26.11.0-rc01"); err == nil || !strings.Contains(err.Error(), "leading zero") {
		t.Errorf("Parse(26.11.0-rc01) error = %v, it must name the rule", err)
	}
	versions := []string{"26.10.0", "26.11.0", "v26.11.0", "26.11.0-rc", "26.11.0-rc0", "26.11.0-rc1", "26.11.0-rc10",
		"26.11.0-beta", "26.11.0-beta0", "26.11.0-beta2", "v26.11.0-rc1"}
	for _, a := range versions {
		va, err := Parse(a)
		if err != nil {
			t.Fatal(err)
		}
		for _, b := range versions {
			vb, err := Parse(b)
			if err != nil {
				t.Fatal(err)
			}
			if equal := Compare(va, vb) == 0; equal != (va.String() == vb.String()) {
				t.Errorf("Compare(%s, %s) = %d, and they print as %q and %q", a, b, Compare(va, vb), va, vb)
			}
		}
	}
	if !Less("26.11.0-rc", "26.11.0-rc0") || !Less("26.11.0-rc0", "26.11.0-rc1") || !Less("26.11.0-beta", "26.11.0-rc") {
		t.Error("a label without a number sorts before the same label with one, and after a label before it")
	}
	const largest = "26.11.0-rc9223372036854775807"
	if !Less("26.11.0-rc", largest) || Less(largest, "26.11.0-rc") {
		t.Errorf("%s must sort after 26.11.0-rc", largest)
	}
}

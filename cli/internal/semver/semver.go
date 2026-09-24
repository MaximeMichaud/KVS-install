// Package semver orders the versions of the stack: three numbers and an
// optional pre-release suffix.
//
// The stack numbers its releases by calendar, YY.M.PATCH: 26.10.0 is the
// first release of October 2026, 26.10.1 the next patch of that month,
// 26.1.0 a release of January. Nothing below depends on that reading, so an
// ordinary MAJOR.MINOR.PATCH version compares exactly the same way.
//
// Two rules matter because the version is also the git tag and the image
// tag. A component never carries a leading zero: Version.String prints the
// numbers back, so 26.01.0 would come back as 26.1.0 and stop naming its
// tag. A pre-release suffix (26.11.0-rc1) sorts before the release carrying
// the same numbers, so a candidate never looks newer than the release it
// leads to.
package semver

import (
	"fmt"
	"strconv"
	"strings"
)

// Version is a parsed MAJOR.MINOR.PATCH with an optional pre-release.
type Version struct {
	Major, Minor, Patch int
	// Pre is the pre-release suffix without its dash ("rc1", "beta2"),
	// empty for a release. Parse fills it and checks its form: letters
	// followed by digits.
	Pre string
}

// Parse reads "26.10.0", or "26.11.0-rc1" for a candidate (a leading "v" is
// tolerated).
func Parse(s string) (Version, error) {
	s = strings.TrimPrefix(strings.TrimSpace(s), "v")
	core, pre, hasPre := strings.Cut(s, "-")
	parts := strings.Split(core, ".")
	if len(parts) != 3 {
		return Version{}, fmt.Errorf("version %q is not MAJOR.MINOR.PATCH", s)
	}
	var v Version
	for i, p := range parts {
		n, err := number(p)
		if err != nil {
			return Version{}, fmt.Errorf("version %q is not MAJOR.MINOR.PATCH", s)
		}
		if len(p) > 1 && p[0] == '0' {
			return Version{}, fmt.Errorf("version %q: %q has a leading zero, a component is written as a plain number (26.1.0, not 26.01.0)", s, p)
		}
		switch i {
		case 0:
			v.Major = n
		case 1:
			v.Minor = n
		default:
			v.Patch = n
		}
	}
	if hasPre {
		if _, _, err := splitPre(pre); err != nil {
			return Version{}, fmt.Errorf("version %q: %w", s, err)
		}
		v.Pre = pre
	}
	return v, nil
}

// Compare returns -1, 0 or 1. A pre-release sorts before the release of the
// same numbers; two pre-releases compare by label and then by number, so
// 26.11.0-beta2 comes before 26.11.0-rc1, itself before 26.11.0-rc2.
func Compare(a, b Version) int {
	switch {
	case a.Major != b.Major:
		return sign(a.Major - b.Major)
	case a.Minor != b.Minor:
		return sign(a.Minor - b.Minor)
	case a.Patch != b.Patch:
		return sign(a.Patch - b.Patch)
	case a.Pre == b.Pre:
		return 0
	case a.Pre == "":
		return 1
	case b.Pre == "":
		return -1
	}
	labelA, numberA, _ := splitPre(a.Pre)
	labelB, numberB, _ := splitPre(b.Pre)
	if labelA != labelB {
		return strings.Compare(labelA, labelB)
	}
	return sign(numberA - numberB)
}

// Less reports whether a sorts before b; unparsable strings sort first.
func Less(a, b string) bool {
	va, ea := Parse(a)
	vb, eb := Parse(b)
	if ea != nil || eb != nil {
		return ea != nil && eb == nil
	}
	return Compare(va, vb) < 0
}

func (v Version) String() string {
	if v.Pre != "" {
		return fmt.Sprintf("%d.%d.%d-%s", v.Major, v.Minor, v.Patch, v.Pre)
	}
	return fmt.Sprintf("%d.%d.%d", v.Major, v.Minor, v.Patch)
}

// splitPre reads a pre-release suffix as a lower case label and a number,
// "rc1" as ("rc", 1) and "beta" as ("beta", 0).
func splitPre(pre string) (string, int, error) {
	end := 0
	for end < len(pre) && isLetter(pre[end]) {
		end++
	}
	label, digits := strings.ToLower(pre[:end]), pre[end:]
	if label == "" {
		return "", 0, fmt.Errorf("pre-release %q is not letters followed by digits (rc1, beta2)", pre)
	}
	if digits == "" {
		return label, 0, nil
	}
	n, err := number(digits)
	if err != nil {
		return "", 0, fmt.Errorf("pre-release %q is not letters followed by digits (rc1, beta2)", pre)
	}
	return label, n, nil
}

// number reads a run of digits, refusing the sign and the empty string
// strconv would otherwise accept or report confusingly.
func number(s string) (int, error) {
	if s == "" {
		return 0, fmt.Errorf("%q is not a number", s)
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return 0, fmt.Errorf("%q is not a number", s)
		}
	}
	return strconv.Atoi(s)
}

func isLetter(b byte) bool {
	return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z')
}

func sign(n int) int {
	switch {
	case n < 0:
		return -1
	case n > 0:
		return 1
	}
	return 0
}

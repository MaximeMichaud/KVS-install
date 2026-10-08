// Package dotenv reads the .env of a compose project the way docker compose
// reads it, so kvsctl decides from the values the containers get, and
// writes one setting at a time in a form compose and the shell of the
// scripts (set -a; . .env) both read back as written.
package dotenv

import (
	"errors"
	"fmt"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"
)

// Entry is one setting of a .env file and where it stands in the data.
type Entry struct {
	Key string
	// Export is set when the setting starts with the export keyword, which
	// compose ignores and the shell of the scripts needs to pass it on.
	Export bool
	// Inherited is set for a key alone on its line: compose takes its value
	// from its own environment, and leaves it unset when that has none.
	Inherited bool
	// Start is the offset of the setting (its export keyword, or its key),
	// and End the offset just past its value: an inline comment and the
	// spaces before it stay out, so a new value can take its place.
	Start, End int
	// LineEnd is the offset just past the line break that ends the setting,
	// or the length of the data on its last line.
	LineEnd int
	// Line is the number of the line the setting starts on, from 1.
	Line int

	quote byte
	raw   string
	// keyAt and valueAt are the offsets of the key and of the value, its
	// opening quote included.
	keyAt, valueAt int
}

// Scan lists the settings of a .env file in their order, without expanding
// their values. The grammar is the one compose reads the project .env with:
// comment lines and blank lines; an optional export keyword; a key of
// letters, digits, _ . - [ ] ended by =, : or the end of its line; a value
// in single quotes (literal, \' for a quote), in double quotes (the escapes
// of the shell, $ expanded), or bare up to the end of the line, cut at the
// first " #" and trimmed. A UTF-8 byte order mark is skipped.
func Scan(data []byte) ([]Entry, error) {
	src := string(data)
	pos := 0
	if strings.HasPrefix(src, "\uFEFF") {
		pos = len("\uFEFF")
	}
	var entries []Entry
	for {
		start := statementStart(src, pos)
		if start < 0 {
			return entries, nil
		}
		e, next, err := scanEntry(src, start)
		if err != nil {
			return entries, fmt.Errorf("line %d: %w", lineOf(src, start), err)
		}
		entries = append(entries, e)
		pos = next
	}
}

// statementStart is the offset of the next setting at or after pos, past
// blank space and comment lines; -1 at the end of the data.
func statementStart(src string, pos int) int {
	for {
		i := strings.IndexFunc(src[pos:], func(r rune) bool { return !unicode.IsSpace(r) })
		if i < 0 {
			return -1
		}
		pos += i
		if src[pos] != '#' {
			return pos
		}
		nl := strings.IndexByte(src[pos:], '\n')
		if nl < 0 {
			return -1
		}
		pos += nl
	}
}

// scanEntry reads the setting at start and returns it with the offset where
// the next one may begin.
func scanEntry(src string, start int) (Entry, int, error) {
	e := Entry{Start: start, Line: lineOf(src, start)}
	pos := start
	if rest := src[pos:]; strings.HasPrefix(rest, "export") && len(rest) > len("export") && isRegexpSpace(rest[len("export")]) {
		e.Export = true
		pos += len("export")
		for pos < len(src) {
			r, size := utf8.DecodeRuneInString(src[pos:])
			if !isSpace(r) {
				break
			}
			pos += size
		}
	}
	keyStart := pos
	e.keyAt = keyStart
	if keyStart == len(src) {
		return e, 0, errors.New("zero length string")
	}
	sep := -1
	for i := pos; i < len(src); {
		r, size := utf8.DecodeRuneInString(src[i:])
		switch {
		case isSpace(r):
		case r == '=' || r == ':' || r == '\n':
			sep = i
		case r == '_' || r == '.' || r == '-' || r == '[' || r == ']', unicode.IsLetter(r), unicode.IsNumber(r):
		default:
			line, _, _ := strings.Cut(src[keyStart:], "\n")
			return e, 0, fmt.Errorf("unexpected character %q in variable name %q", string(r), line)
		}
		if sep >= 0 {
			break
		}
		i += size
	}
	valueStart := keyStart
	if sep >= 0 {
		e.Key = strings.TrimRightFunc(src[keyStart:sep], unicode.IsSpace)
		e.Inherited = src[sep] == '\n'
		valueStart = sep + 1
	}
	// A key that runs to the end of the data has no separator: compose then
	// reads the whole of it as the value of an empty key, which no setting
	// of the stack is. Compose refuses a space inside a key, and only that
	// blank.
	if strings.Contains(e.Key, " ") {
		return e, 0, errors.New("key cannot contain a space")
	}
	if e.Inherited {
		e.End = keyStart + len(e.Key)
		e.LineEnd = valueStart
		e.valueAt = e.End
		return e, valueStart, nil
	}
	for valueStart < len(src) {
		r, size := utf8.DecodeRuneInString(src[valueStart:])
		if !isSpace(r) {
			break
		}
		valueStart += size
	}
	e.valueAt = valueStart
	if valueStart < len(src) && (src[valueStart] == '"' || src[valueStart] == '\'') {
		return scanQuoted(src, e, valueStart)
	}
	lineEnd := len(src)
	next := len(src)
	value := src[valueStart:]
	if nl := strings.IndexByte(value, '\n'); nl >= 0 {
		value = value[:nl]
		lineEnd = valueStart + nl + 1
		next = lineEnd
	}
	if cut := strings.Index(value, " #"); cut >= 0 {
		value = value[:cut]
	}
	value = strings.TrimRightFunc(value, unicode.IsSpace)
	e.raw = value
	e.End = valueStart + len(value)
	e.LineEnd = lineEnd
	return e, next, nil
}

// scanQuoted reads a value in quotes that opens at pos. A backslash before
// the quote keeps the quote in the value; before any other character both
// stay, for the escapes of a double-quoted value to be read afterwards.
func scanQuoted(src string, e Entry, pos int) (Entry, int, error) {
	quote := src[pos]
	var chars []byte
	escaped := false
	for i := pos + 1; i < len(src); i++ {
		c := src[i]
		if c != quote {
			if !escaped && c == '\\' {
				escaped = true
				continue
			}
			if escaped {
				escaped = false
				chars = append(chars, '\\')
			}
			chars = append(chars, c)
			continue
		}
		if escaped {
			escaped = false
			chars = append(chars, c)
			continue
		}
		e.quote, e.raw = quote, string(chars)
		e.End = i + 1
		e.LineEnd = len(src)
		if nl := strings.IndexByte(src[e.End:], '\n'); nl >= 0 {
			e.LineEnd = e.End + nl + 1
		}
		return e, e.End, nil
	}
	line, _, _ := strings.Cut(src[pos:], "\n")
	return e, 0, fmt.Errorf("unterminated quoted value %s", line)
}

// Parse reads the settings of a .env file into a map, the way compose reads
// the project .env: a later setting of a key wins, and $ in a bare or
// double-quoted value is expanded from environ first, then from the
// settings above it. environ is the environment compose runs with, which
// also gives a key alone on its line its value; nil stands for an empty one.
func Parse(data []byte, environ func(string) (string, bool)) (map[string]string, error) {
	entries, err := Scan(data)
	if err != nil {
		return nil, err
	}
	if environ == nil {
		environ = func(string) (string, bool) { return "", false }
	}
	out := make(map[string]string, len(entries))
	lookup := func(key string) (string, bool) {
		if v, ok := environ(key); ok {
			return v, true
		}
		v, ok := out[key]
		return v, ok
	}
	for _, e := range entries {
		if e.Inherited {
			if v, ok := lookup(e.Key); ok {
				out[e.Key] = v
			}
			continue
		}
		value := e.raw
		switch e.quote {
		case '\'':
		case '"':
			value, err = substitute(unescape(value), lookup)
		default:
			value, err = substitute(value, lookup)
		}
		if err != nil {
			return nil, fmt.Errorf("line %d: %w", e.Line, err)
		}
		out[e.Key] = value
	}
	return out, nil
}

// Assigned lists the keys data gives a value, a key alone on its line left
// out. A file compose cannot read gives the keys before the line it stops at.
func Assigned(data []byte) map[string]bool {
	entries, _ := Scan(data)
	keys := make(map[string]bool, len(entries))
	for _, e := range entries {
		if !e.Inherited {
			keys[e.Key] = true
		}
	}
	return keys
}

// inherited lists the keys data leaves to the environment of compose.
func inherited(data []byte) map[string]bool {
	entries, _ := Scan(data)
	keys := map[string]bool{}
	for _, e := range entries {
		if e.Inherited {
			keys[e.Key] = true
		}
	}
	return keys
}

// unescape reads the escapes of a double-quoted value the way compose does:
// \a \b \f \n \r \t \v \" \\ as in Go, \$ as a literal dollar (kept as $$
// for the expansion that follows), and \0 with up to three octal digits;
// any other backslash stays as it is.
func unescape(s string) string {
	if !strings.Contains(s, `\`) {
		return s
	}
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] != '\\' || i+1 == len(s) {
			b.WriteByte(s[i])
			continue
		}
		switch c := s[i+1]; c {
		case 'a', 'b', 'f', 'n', 'r', 't', 'v', '"', '\\':
			r, _, _, _ := strconv.UnquoteChar(s[i:i+2], '"')
			b.WriteRune(r)
			i++
		case '$':
			b.WriteString("$$")
			i++
		case '0':
			j := i + 2
			for j < len(s) && j < i+5 && s[j] >= '0' && s[j] <= '9' {
				j++
			}
			// Compose drops the 0 and reads what is left as an octal
			// escape of Go, which takes exactly three digits; anything
			// else is left as it was, the 0 gone.
			match := `\` + s[i+2:j]
			if r, _, tail, err := strconv.UnquoteChar(match, '"'); err == nil && tail == "" {
				b.WriteRune(r)
			} else {
				b.WriteString(match)
			}
			i = j - 1
		default:
			b.WriteByte('\\')
		}
	}
	return b.String()
}

// errInvalid is a ${...} compose refuses to read.
var errInvalid = errors.New("invalid template")

// substitute expands the variables of a value the way compose does: $$ is a
// dollar, $NAME and ${NAME} the value of NAME (empty when unset), and
// ${NAME:-default}, ${NAME-default}, ${NAME:+alternative},
// ${NAME+alternative}, ${NAME:?message} and ${NAME?message} as in the
// shell, the inner text expanded in turn when it is used. A $ before
// anything else stays. Where a ${ ends follows the template reader of
// Compose 2.24.7 and later (compose-go v2): see templateEnd and
// closingBrace.
func substitute(s string, lookup func(string) (string, bool)) (string, error) {
	if !strings.Contains(s, "$") {
		return s, nil
	}
	var b strings.Builder
	for i := 0; i < len(s); {
		if s[i] != '$' || i+1 == len(s) {
			b.WriteByte(s[i])
			i++
			continue
		}
		next := s[i+1]
		switch {
		case next == '$':
			b.WriteByte('$')
			i += 2
		case isNameStart(next):
			j := i + 2
			for j < len(s) && isNameChar(s[j]) {
				j++
			}
			v, _ := lookup(s[i+1 : j])
			b.WriteString(v)
			i = j
		case next == '{':
			end := templateEnd(s, i)
			if end < 0 {
				return "", fmt.Errorf("%w %q", errInvalid, s)
			}
			// The template ends at the brace that closes its first one,
			// and what follows that brace in the match is text of its
			// own; a match where no brace closes it is a template whole.
			match := s[i : end+1]
			expr, rest := match[2:len(match)-1], ""
			if cut := closingBrace(match); cut >= 0 {
				expr, rest = match[2:cut], match[cut+1:]
			}
			v, err := braced(expr, lookup)
			if err != nil {
				if errors.Is(err, errInvalid) {
					return "", fmt.Errorf("%w %q", errInvalid, s)
				}
				return "", err
			}
			after, err := substitute(rest, lookup)
			if err != nil {
				return "", err
			}
			b.WriteString(v)
			b.WriteString(after)
			i = end + 1
		default:
			b.WriteByte('$')
			i++
		}
	}
	return b.String(), nil
}

// templateEnd is the offset of the brace that ends the ${ at start as the
// expression compose finds templates with matches it, -1 when it matches
// none: a name and its closing brace, or a name, an operator (- + ? with an
// optional colon before it) and anything up to the last brace of the line.
func templateEnd(s string, start int) int {
	i := start + 2
	if i >= len(s) || !isNameStart(s[i]) {
		return -1
	}
	for i < len(s) && isNameChar(s[i]) {
		i++
	}
	if i < len(s) && s[i] == '}' {
		return i
	}
	if i < len(s) && s[i] == ':' {
		i++
	}
	if i >= len(s) || strings.IndexByte("-+?", s[i]) < 0 {
		return -1
	}
	line := s[i+1:]
	if nl := strings.IndexByte(line, '\n'); nl >= 0 {
		line = line[:nl]
	}
	last := strings.LastIndexByte(line, '}')
	if last < 0 {
		return -1
	}
	return i + 1 + last
}

// closingBrace is the offset of the brace that closes the first one of a
// template match, -1 when none does. It counts the braces as compose does
// from 2.24.7 on: every { opens one, and the character after it is not
// looked at, so a } right after a { closes nothing. That is how
// ${A:-{}}x} reads as the default {}}x, where a count of that } would end
// the template at ${A:-{}} and leave x} after it. Compose 2.19.0 to 2.24.6
// opened one at a ${ only, and read a few defaults that hold a {
// otherwise ("${A:-[{}]}" as "[{]}"); kvsctl reads them as the Compose of
// today does.
func closingBrace(match string) int {
	open := 0
	for i := 0; i < len(match); i++ {
		switch match[i] {
		case '}':
			open--
			if open == 0 {
				return i
			}
		case '{':
			open++
			i++
		}
	}
	return -1
}

// braced expands the text between ${ and its closing brace.
func braced(expr string, lookup func(string) (string, bool)) (string, error) {
	if expr == "" || !isNameStart(expr[0]) {
		return "", errInvalid
	}
	n := 1
	for n < len(expr) && isNameChar(expr[n]) {
		n++
	}
	name, rest := expr[:n], expr[n:]
	if rest == "" {
		v, _ := lookup(name)
		return v, nil
	}
	colon := strings.HasPrefix(rest, ":")
	if colon {
		rest = rest[1:]
	}
	if rest == "" {
		return "", errInvalid
	}
	op, arg := rest[0], rest[1:]
	value, set := lookup(name)
	usable := set && (!colon || value != "")
	switch op {
	case '-':
		if usable {
			return value, nil
		}
		return substitute(arg, lookup)
	case '+':
		if usable {
			return substitute(arg, lookup)
		}
		return value, nil
	case '?':
		if usable {
			return value, nil
		}
		reason, err := substitute(arg, lookup)
		if err != nil {
			return "", err
		}
		if reason != "" {
			return "", fmt.Errorf("required variable %s is missing a value: %s", name, reason)
		}
		return "", fmt.Errorf("required variable %s is missing a value", name)
	}
	return "", errInvalid
}

func isNameStart(c byte) bool {
	return c == '_' || ('a' <= c && c <= 'z') || ('A' <= c && c <= 'Z')
}

func isNameChar(c byte) bool { return isNameStart(c) || ('0' <= c && c <= '9') }

// isSpace is a blank that does not end a line, as compose counts them.
func isSpace(r rune) bool {
	switch r {
	case '\t', '\v', '\f', '\r', ' ', 0x85, 0xA0:
		return true
	}
	return false
}

// isRegexpSpace is \s of the expression compose finds the export keyword
// with: a line break counts there.
func isRegexpSpace(c byte) bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\f' || c == '\r'
}

// lineOf is the number of the line offset pos is on, from 1.
func lineOf(src string, pos int) int {
	return strings.Count(src[:pos], "\n") + 1
}

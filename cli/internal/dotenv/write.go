package dotenv

import (
	"bytes"
	"fmt"
	"maps"
	"slices"
	"strings"
	"unicode"
)

// Set returns data with key set to value. Every setting of key is written
// again where it stands, its export keyword kept, in a form compose and the
// shell of the scripts both read as value, and an inline comment after it
// stays a comment; a line that holds other settings too is written again
// with each of them on a line of its own (rewrite). A key data does not set
// yet is added at the end. Refused are a key or a value no form gives both
// readers alike, a file compose cannot read, and an edit that a line of the
// operator's would have the shell read otherwise than compose, or the
// opposite edit a rollback makes, in the cases shellHazard finds: a word
// key= the shell may take for a setting inside another setting, a word
// NAME= inside a setting of a line the edit writes again, and a value out
// of quotes that ends with a backslash on such a line, on the line before
// it, or as the last byte of a file a setting is added to (endJoin). A line
// the shell misreads before the edit, such as a quote left open in a bare
// value (Bob's videos) or a here-document (NOTE=p<<EOF), is the operator's
// and not looked for. The lines the edit writes are in a form both read
// alike, but a shell such a line throws off may not read them at all, a
// quote left open taking in the lines after it: the edit does not make the
// file readable by the shell.
func Set(data []byte, key, value string) ([]byte, error) {
	if !shellName(key) {
		return nil, fmt.Errorf("%s: the shell of the scripts cannot set a variable of that name, so no setting reads alike in docker compose and in the scripts", key)
	}
	written, err := quote(value)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", key, err)
	}
	entries, err := Scan(data)
	if err != nil {
		return nil, err
	}
	if err := shellHazard(data, entries, key); err != nil {
		return nil, err
	}
	found := false
	out := rewrite(data, entries, func(e Entry, at place) (string, action) {
		if e.Key != key {
			return "", keep
		}
		found = true
		text := key + "=" + written
		if at.comment != "" {
			// Compose cuts a bare value at " #", and reads an empty one
			// up to the end of its line.
			if value == "" {
				text = key + `=""`
			}
			text += " " + at.comment
		}
		if at.exported {
			text = "export " + text
		}
		return text, replace
	})
	if found {
		return out, nil
	}
	if out, err = endJoin(data, entries, key); err != nil {
		return nil, err
	}
	newline := "\n"
	if bytes.Contains(data, []byte("\r\n")) {
		newline = "\r\n"
	}
	if len(out) > 0 && out[len(out)-1] != '\n' {
		out = append(out, newline...)
	}
	return append(out, key+"="+written+newline...), nil
}

// Unset returns data without the settings of key, each with its whole line,
// and whether there was one. The other settings of a line it shares stay,
// each on a line of its own (rewrite). A file compose cannot read is not
// edited, and neither is one where a line of the operator's would have the
// shell of the scripts read the result, or the opposite edit, otherwise
// than compose, in the cases shellHazard finds (Set). A line the shell
// misreads before the edit is the operator's, and stays as it is.
func Unset(data []byte, key string) ([]byte, bool, error) {
	entries, err := Scan(data)
	if err != nil {
		return nil, false, err
	}
	if err := shellHazard(data, entries, key); err != nil {
		return nil, false, err
	}
	found := false
	out := rewrite(data, entries, func(e Entry, _ place) (string, action) {
		if e.Key != key {
			return "", keep
		}
		found = true
		return "", drop
	})
	if !found {
		return data, false, nil
	}
	return out, true, nil
}

// Graft returns data with the settings of the keys pick accepts taken from
// donor, both read the way compose reads them. The first setting of such a
// key in data becomes the last one of donor, as donor writes it (export
// keyword, quotes, comment and all) on a line of its own, or goes when
// donor has none, and its later settings go; the ones only donor has are
// added at the end, in the order donor first sets them, where the shell
// reads them on their own (endJoin). Everything else of data stays as it
// is, comments, blank lines and values on several lines included, but for
// the other settings of a line it changes (rewrite). It also returns the
// keys pick accepted in either file, sorted. A file compose cannot read is
// refused, and so are keys to add after a backslash that ends data.
func Graft(data, donor []byte, pick func(key string) bool) ([]byte, []string, error) {
	theirs, err := Scan(donor)
	if err != nil {
		return nil, nil, err
	}
	ours, err := Scan(data)
	if err != nil {
		return nil, nil, err
	}
	taken := map[string]string{}
	var order []string
	for _, l := range linesOf(donor, theirs) {
		for i, at := range l.places(donor, theirs) {
			key := theirs[l.first+i].Key
			if !pick(key) {
				continue
			}
			if _, seen := taken[key]; !seen {
				order = append(order, key)
			}
			taken[key] = at.alone
		}
	}
	keys := map[string]bool{}
	written := map[string]bool{}
	out := rewrite(data, ours, func(e Entry, _ place) (string, action) {
		if !pick(e.Key) {
			return "", keep
		}
		keys[e.Key] = true
		text, ok := taken[e.Key]
		first := !written[e.Key]
		written[e.Key] = true
		if ok && first {
			return text, replace
		}
		return "", drop
	})
	var added []string
	for _, key := range order {
		keys[key] = true
		if !written[key] {
			added = append(added, key)
		}
	}
	if len(added) > 0 {
		grafted, err := Scan(out)
		if err != nil {
			return nil, nil, err
		}
		if out, err = endJoin(out, grafted, added[0]); err != nil {
			return nil, nil, err
		}
	}
	for _, key := range added {
		if len(out) > 0 && out[len(out)-1] != '\n' {
			out = append(out, '\n')
		}
		out = append(out, taken[key]+"\n"...)
	}
	return out, slices.Sorted(maps.Keys(keys)), nil
}

// What an edit does with a setting (rewrite).
type action int

const (
	keep action = iota
	replace
	drop
)

// place is where a setting stands on its line, as an edit sees it.
type place struct {
	// exported is set when the setting, or one before it on its line,
	// has the export keyword: the shell read it as an argument of export.
	exported bool
	// comment is the inline comment that ends the line, from its #, when
	// the setting is the last one there, and "" otherwise.
	comment string
	// alone is the setting as a line of its own, which compose reads as it
	// reads it where it stands: from its export keyword or its key to the
	// end of its value, the comment that ends the line when it is the last
	// setting there, and export in front when exported comes from a
	// setting before it, so that the shell still hands it to export.
	alone string
}

// line is a line of a .env file: the offset where it starts, the one of its
// line break (lineBreak), and its settings, entries[first:end]. A value in
// quotes leaves room for another setting after it on its line.
type line struct {
	start, brk int
	first, end int
}

// linesOf lists the lines that hold the settings of data, in their order.
func linesOf(data []byte, entries []Entry) []line {
	var lines []line
	for first := 0; first < len(entries); {
		end, brk := first+1, lineBreak(data, entries[first].End)
		for end < len(entries) && entries[end].Start < brk {
			brk = lineBreak(data, entries[end].End)
			end++
		}
		start := bytes.LastIndexByte(data[:entries[first].Start], '\n') + 1
		lines = append(lines, line{start: start, brk: brk, first: first, end: end})
		first = end
	}
	return lines
}

// places tells where each setting of l stands, entries[l.first] first.
func (l line) places(data []byte, entries []Entry) []place {
	places := make([]place, 0, l.end-l.first)
	exported := false
	for n := l.first; n < l.end; n++ {
		e := entries[n]
		at := place{exported: exported || e.Export}
		exported = at.exported
		to := e.End
		if n == l.end-1 {
			to = l.brk
			at.comment = strings.TrimLeftFunc(string(data[e.End:l.brk]), unicode.IsSpace)
		}
		at.alone = string(data[e.Start:to])
		if at.exported && !e.Export {
			at.alone = "export " + at.alone
		}
		places = append(places, at)
	}
	return places
}

// rewrite returns data with what edit does to each setting, called in their
// order: keep it, replace it with a text that stands for the whole of its
// line but the line break, or drop it. A line where nothing changes stays
// as it is. Any other is written again with each setting it keeps or gets
// on a line of its own, its leading blanks kept when they are spaces and
// tabs, and its line break; a line left without a setting goes with its
// line break. The shell of the scripts reads a line as one command, where
// a setting may stick to the value before it, run as a command or be handed
// to one; alone on its line, with the export keyword of the line in front
// (place.alone), it is read as compose reads it.
func rewrite(data []byte, entries []Entry, edit func(Entry, place) (string, action)) []byte {
	var out []byte
	last := 0
	for _, l := range linesOf(data, entries) {
		var texts []string
		changed := false
		for i, at := range l.places(data, entries) {
			text, act := edit(entries[l.first+i], at)
			switch act {
			case keep:
				texts = append(texts, at.alone)
			case replace:
				texts, changed = append(texts, text), true
			case drop:
				changed = true
			}
		}
		if !changed {
			continue
		}
		out = append(out, data[last:l.start]...)
		if len(texts) == 0 {
			last = entries[l.end-1].LineEnd
			continue
		}
		// A blank the shell does not split words at, a no-break space or
		// a byte order mark, would make the first setting a command.
		if lead := data[l.start:entries[l.first].Start]; len(bytes.Trim(lead, " \t")) == 0 {
			out = append(out, lead...)
		}
		newline := "\n"
		if l.brk < len(data) && data[l.brk] == '\r' {
			newline = "\r\n"
		}
		out = append(out, strings.Join(texts, newline)...)
		last = l.brk
	}
	return append(out, data[last:]...)
}

// shellHazard refuses an edit of key that a line of the operator's would
// keep the shell of the scripts from reading as compose reads it, after the
// edit or after the opposite one, which a rollback makes to take it back:
//   - anywhere but in a setting of key, a setting of key only the shell
//     may read (stray): after the last setting of key it wins over the one
//     written, and wherever it is it stays once the settings are removed;
//   - on a line the edit writes again, a setting of another key only the
//     shell may read, which the edit would take away, or have the shell run
//     once the line is cut into settings of their own;
//   - a value out of quotes that ends with a backslash, on the line before
//     one the edit writes again or on that line itself, which has the shell
//     read the two lines as one (continues): the edit would change how it
//     reads the line after.
func shellHazard(data []byte, entries []Entry, key string) error {
	for _, l := range linesOf(data, entries) {
		edited := slices.ContainsFunc(entries[l.first:l.end], func(e Entry) bool { return e.Key == key })
		if edited && l.first > 0 && entries[l.first-1].Key != key && continues(data, entries[l.first-1], entries[l.first].Start) {
			return joined(key, entries[l.first-1])
		}
		if edited && l.end < len(entries) && entries[l.end].Key != key && continues(data, entries[l.end-1], entries[l.end].Start) {
			return joined(key, entries[l.end-1])
		}
		for _, e := range entries[l.first:l.end] {
			for _, name := range stray(data, e) {
				if (name == key && e.Key != key) || (name != key && edited) {
					return fmt.Errorf("%s: line %d: the shell of the scripts may take %s= there for a setting, which docker compose reads as part of %q: write each setting as KEY=\"value\" on a line of its own", key, e.Line, name, e.Key)
				}
			}
		}
	}
	return nil
}

// stray lists the names the shell of the scripts may read a setting of in
// e that compose does not: a word NAME= after a blank or one of
// ; & | ( ) < > in a value out of quotes, which compose reads whole to the
// end of its line, or in a key, where compose keeps a tab.
func stray(data []byte, e Entry) []string {
	to := e.End
	if e.quote != 0 {
		to = e.valueAt
	}
	var names []string
	for i := e.Start + 1; i < to; i++ {
		if i == e.keyAt || strings.IndexByte(" \t;&|()<>", data[i-1]) < 0 || !isNameStart(data[i]) {
			continue
		}
		n := i + 1
		for n < to && isNameChar(data[n]) {
			n++
		}
		if n < to && data[n] == '=' {
			names = append(names, string(data[i:n]))
		}
	}
	return names
}

// continues reports whether the shell reads the line that starts at offset
// at, blanks before a setting or the end of data for one added there, as
// part of the line before it, which ends with prev: a value out of quotes
// whose last character, right before the line feed, is a backslash that no
// other escapes.
func continues(data []byte, prev Entry, at int) bool {
	if prev.quote != 0 || prev.Inherited {
		return false
	}
	if gap := data[prev.End:at]; len(gap) > 0 && (gap[0] != '\n' || strings.TrimFunc(string(gap[1:]), isSpace) != "") {
		return false
	}
	value := data[prev.Start:prev.End]
	return (len(value)-len(bytes.TrimRight(value, `\`)))%2 == 1
}

// endJoin is a copy of data, whose settings are entries, ready for a line
// that an edit of key adds at its end. After a last value that ends with a
// backslash, the shell joins the next line to it: a line feed ends that
// line first, so the line added is read on its own. Right at the end of
// the file the shell reads that backslash as itself, which a line feed
// would change, and the edit is refused.
func endJoin(data []byte, entries []Entry, key string) ([]byte, error) {
	out := append([]byte(nil), data...)
	if n := len(entries); n > 0 && continues(data, entries[n-1], len(data)) {
		if entries[n-1].End == len(data) {
			return nil, joined(key, entries[n-1])
		}
		out = append(out, '\n')
	}
	return out, nil
}

// joined is the refusal of an edit of key next to prev, whose line the
// shell reads as one with the line after it.
func joined(key string, prev Entry) error {
	return fmt.Errorf("%s: line %d: the value of %s ends with a backslash out of quotes, and the shell of the scripts joins the next line to it, which docker compose does not: put that value in quotes", key, prev.Line, prev.Key)
}

// lineBreak is the offset of the line break that ends the line holding
// offset at, its carriage return included, or the length of data on the
// last line.
func lineBreak(data []byte, at int) int {
	nl := bytes.IndexByte(data[at:], '\n')
	if nl < 0 {
		return len(data)
	}
	brk := at + nl
	if brk > at && data[brk-1] == '\r' {
		brk--
	}
	return brk
}

// shellName reports whether the shell of the scripts can set a variable
// named key: compose also takes dots, dashes and brackets in a name, which
// the shell reads as a command to run.
func shellName(key string) bool {
	for i := 0; i < len(key); i++ {
		c := key[i]
		if c != '_' && !('a' <= c && c <= 'z') && !('A' <= c && c <= 'Z') && (i == 0 || c < '0' || c > '9') {
			return false
		}
	}
	return key != ""
}

// quote is value as a setting writes it, so that compose and the shell of
// the scripts, which source the file, read the same value: bare when it
// only holds characters neither reads as syntax; in double quotes when it
// holds blanks or punctuation both read alike there; in single quotes,
// where both read every character as itself, when it holds a $, a
// backquote, a backslash or a double quote. A control character, a value
// that needs both kinds of quotes, and one that ends with a backslash
// (compose reads it as escaping the closing quote) are refused.
func quote(value string) (string, error) {
	bare, double, single := true, true, true
	for i := 0; i < len(value); i++ {
		c := value[i]
		switch {
		case 'a' <= c && c <= 'z', 'A' <= c && c <= 'Z', '0' <= c && c <= '9', strings.IndexByte("_-.:/@+=,%", c) >= 0:
		case c < 0x20 || c == 0x7f:
			bare, double, single = false, false, false
		case c == '$' || c == '`' || c == '"':
			bare, double = false, false
		case c == '\\':
			bare, double = false, false
			if i == len(value)-1 {
				single = false
			}
		case c == '\'':
			bare, single = false, false
		default:
			bare = false
		}
	}
	switch {
	case bare:
		return value, nil
	case double:
		return `"` + value + `"`, nil
	case single:
		return "'" + value + "'", nil
	}
	return "", fmt.Errorf("%q cannot be written to .env so that docker compose and the scripts read the same value", value)
}

package backup

import (
	"bufio"
	"bytes"
	"fmt"
	"io"
	"os"
	"regexp"
	"strings"
)

const compactMode = "SET SESSION sql_mode = CONCAT_WS(',', NULLIF(@@SESSION.sql_mode, ''), 'ALLOW_INVALID_DATES');\n"
const unknownModeWarning = "WARNING: Unrecognized header SQL_MODE assignment. Invalid dates may be stored as zero."

// replayPrologue inspects comments and SET statements up to the first body
// statement, then streams the remaining archive bytes directly to the client.
type replayPrologue struct {
	body          *bufio.Reader
	counted       *replayReader
	pending       string
	done, sawMode bool
	sqlQuoteMode
	saved map[string]sqlQuoteMode
}

type sqlQuoteMode struct {
	noBackslash, ansi bool
}

func quoteMode(modes string) sqlQuoteMode {
	return sqlQuoteMode{noBackslash: hasMode(modes, "NO_BACKSLASH_ESCAPES"), ansi: ansiQuotes(modes)}
}

// Lookahead decides token boundaries only. Neither a token nor a statement
// has to fit in the reader's buffer.
func sqlSpace(c byte) bool { return c == ' ' || c >= '\t' && c <= '\r' }
func sqlWord(c byte) bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_' || c == '$' || c >= 128
}

type headerToken struct {
	raw    string
	trivia bool
}

func headerTokenAt(r *bufio.Reader, noBackslash, ansi bool) (headerToken, error) {
	b, err := r.Peek(3)
	if len(b) == 0 {
		return headerToken{}, err
	}
	c := b[0]
	var s strings.Builder
	switch {
	case sqlSpace(c), sqlWord(c):
		space := sqlSpace(c)
		for {
			v, err := r.Peek(1)
			if len(v) == 0 || !(space && sqlSpace(v[0]) || !space && sqlWord(v[0])) {
				if err != nil && err != io.EOF {
					return headerToken{}, err
				}
				break
			}
			s.WriteByte(v[0])
			_, _ = r.Discard(1)
		}
		return headerToken{s.String(), space}, nil
	case c == '#' || len(b) >= 3 && string(b[:2]) == "--" && sqlSpace(b[2]):
		line, err := r.ReadString('\n')
		if err == io.EOF {
			err = nil
		}
		return headerToken{line, true}, err
	case bytes.HasPrefix(b, []byte("/*")):
		_, _ = r.Discard(2)
		s.WriteString("/*")
		for {
			part, err := r.ReadString('*')
			s.WriteString(part)
			if err == io.EOF {
				break
			}
			if err != nil {
				return headerToken{}, err
			}
			if next, _ := r.Peek(1); len(next) != 0 && next[0] == '/' {
				_, _ = r.Discard(1)
				s.WriteByte('/')
				break
			}
		}
		return headerToken{s.String(), true}, nil
	case c == '\'' || c == '"' || c == '`':
		_, _ = r.Discard(1)
		s.WriteByte(c)
		escapes := !noBackslash && c != '`' && !(ansi && c == '"')
		for {
			ch, err := r.ReadByte()
			if err == io.EOF {
				break
			}
			if err != nil {
				return headerToken{}, err
			}
			s.WriteByte(ch)
			if escapes && ch == '\\' {
				ch, err = r.ReadByte()
				if err == io.EOF {
					break
				}
				if err != nil {
					return headerToken{}, err
				}
				s.WriteByte(ch)
			} else if ch == c {
				if next, _ := r.Peek(1); len(next) == 0 || next[0] != c {
					break
				}
				_, _ = r.Discard(1)
				s.WriteByte(c)
			}
		}
	default:
		_, _ = r.Discard(1)
		s.WriteByte(c)
	}
	return headerToken{raw: s.String()}, nil
}

var versionComment = regexp.MustCompile(`(?is)^/\*(?:M)?!([0-9]*)[[:space:]]*([\s\S]*?)\*/$`)
var headerSet = regexp.MustCompile(`(?i)^SET(?:[^a-z0-9_$\x80-\xff]|$)`)
var routineMode = regexp.MustCompile(`(?i)^SET[[:space:]]+(?:SQL_MODE|@saved_sql_mode)\b`)
var literalModes = regexp.MustCompile(`^['"][a-zA-Z0-9_, \t]*['"]$`)

func hasMode(list, mode string) bool {
	for _, m := range strings.Split(list, ",") {
		if strings.EqualFold(strings.TrimSpace(m), mode) {
			return true
		}
	}
	return false
}

// Split a SET list at its top-level commas. Preserve spelling and trivia,
// including SQL_MODE lookalikes inside strings, expressions and user variables.
func (h *replayPrologue) setting(r *bufio.Reader, end string) (string, int, error) {
	var out, lhs, raw strings.Builder
	var rhs []string
	valueEnd, depth := 0, 0
	assigned := false
	noBackslash, ansi := h.noBackslash, h.ansi
	flush := func() {
		part := raw.String()
		target := strings.ToUpper(lhs.String())
		switch target {
		case "GLOBAL SQL_MODE", "@@GLOBAL.SQL_MODE", "PERSIST SQL_MODE", "PERSIST_ONLY SQL_MODE":
			fmt.Fprintln(os.Stderr, unknownModeWarning)
			h.sawMode = true
		case "SQL_MODE", "SESSION SQL_MODE", "LOCAL SQL_MODE", "@@SQL_MODE", "@@SESSION.SQL_MODE", "@@LOCAL.SQL_MODE":
			h.sawMode = true
			if len(rhs) == 1 && literalModes.MatchString(rhs[0]) && !(ansi && rhs[0][0] == '"') {
				modes := rhs[0][1 : len(rhs[0])-1]
				h.sqlQuoteMode = quoteMode(modes)
				if !hasMode(modes, "ALLOW_INVALID_DATES") {
					add := "ALLOW_INVALID_DATES"
					if modes != "" {
						add = "," + add
					}
					part = part[:valueEnd-1] + add + part[valueEnd-1:]
				}
			} else if strings.TrimSpace("SET"+part)+";\n" != compactMode {
				fmt.Fprintln(os.Stderr, unknownModeWarning)
				h.sqlQuoteMode = h.saved[strings.ToUpper(strings.Join(rhs, ""))]
			}
		default:
			if strings.HasPrefix(target, "@") && !strings.HasPrefix(target, "@@") {
				if h.saved == nil {
					h.saved = make(map[string]sqlQuoteMode)
				}
				value := strings.ToUpper(strings.Join(rhs, ""))
				switch {
				case value == "@@SQL_MODE" || value == "@@SESSION.SQL_MODE":
					h.saved[target] = h.sqlQuoteMode
				case len(rhs) == 1 && literalModes.MatchString(rhs[0]) && rhs[0][0] == '\'':
					h.saved[target] = quoteMode(value[1 : len(value)-1])
				default:
					delete(h.saved, target)
				}
			}
		}
		out.WriteString(part)
		raw.Reset()
		lhs.Reset()
		rhs = nil
		assigned = false
	}
	consumed := 0
	for {
		t, err := headerTokenAt(r, noBackslash, ansi)
		if err == io.EOF {
			flush()
			break
		}
		if err != nil {
			return "", 0, err
		}
		consumed += len(t.raw)
		if t.raw == end || t.raw == "," && depth == 0 {
			flush()
			out.WriteString(t.raw)
			if t.raw == end {
				break
			}
			continue
		}
		raw.WriteString(t.raw)
		if t.trivia {
			continue
		}
		if !assigned {
			switch t.raw {
			case "=":
				assigned = true
			case ":": // Optional colon in :=.
			default:
				word := t.raw
				if len(word) >= 2 && (word[0] == '`' || ansi && word[0] == '"') && word[len(word)-1] == word[0] {
					word = word[1 : len(word)-1]
				}
				if lhs.Len() > 0 && sqlWord(lhs.String()[lhs.Len()-1]) && word != "" && sqlWord(word[0]) {
					lhs.WriteByte(' ')
				}
				lhs.WriteString(word)
			}
		} else {
			rhs = append(rhs, t.raw)
			valueEnd = raw.Len()
		}
		switch t.raw {
		case "(":
			depth++
		case ")":
			depth--
		}
	}
	return out.String(), consumed, nil
}

func ansiQuotes(modes string) bool {
	for _, m := range []string{"ANSI_QUOTES", "ANSI", "DB2", "MAXDB", "MSSQL", "ORACLE", "POSTGRESQL"} {
		if hasMode(modes, m) {
			return true
		}
	}
	return false
}

func (h *replayPrologue) next() (string, int, error) {
	b, err := h.body.Peek(4)
	if len(b) == 0 {
		h.done = true
		return "", 0, err
	}
	isSet := headerSet.Match(b)
	comment := bytes.HasPrefix(b, []byte("/*")) || b[0] == '#' || len(b) >= 3 && string(b[:2]) == "--" && sqlSpace(b[2])
	if isSet || comment || sqlSpace(b[0]) || b[0] == ';' {
		t, err := headerTokenAt(h.body, h.noBackslash, h.ansi)
		if err != nil {
			return "", 0, err
		}
		if isSet {
			tail, n, err := h.setting(h.body, ";")
			return t.raw + tail, len(t.raw) + n, err
		}
		if loc := versionComment.FindStringSubmatchIndex(t.raw); loc != nil {
			body := t.raw[loc[4]:loc[5]]
			switch {
			case strings.HasPrefix(body, `\-`):
			case headerSet.MatchString(body) && !(t.raw[loc[2]:loc[3]] == "50003" && routineMode.MatchString(body)):
				rewritten, _, err := h.setting(bufio.NewReader(strings.NewReader(body[3:])), "")
				return t.raw[:loc[4]+3] + rewritten + t.raw[loc[5]:], len(t.raw), err
			default:
				// An executable body statement or a routine's stored creation mode.
				h.done = true
				if !h.sawMode {
					return compactMode + t.raw, len(t.raw), nil
				}
			}
		}
		return t.raw, len(t.raw), nil
	}
	h.done = true
	if !h.sawMode {
		return compactMode, 0, nil
	}
	return "", 0, nil
}

func (h *replayPrologue) Read(p []byte) (int, error) {
	for h.pending == "" && !h.done {
		s, n, err := h.next()
		h.counted.record(n)
		if err != nil && err != io.EOF {
			return 0, err
		}
		h.pending = s
	}
	if h.pending != "" {
		n := copy(p, h.pending)
		h.pending = h.pending[n:]
		return n, nil
	}
	return h.counted.Read(p)
}

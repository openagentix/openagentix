package rules

import (
	"errors"
	"fmt"
	"regexp"
	"regexp/syntax"
)

// Limits of an event block (ADR 0027).
const (
	MaxEventTextPattern = 256  // characters of the pattern
	MaxEventTextBytes   = 1024 // bytes of a message text, whatever the pattern
	MaxEventRepeat      = 64
	MaxEventCallers     = 16
	MaxEventSpaces      = 3 // spaces in a pattern: more would let fixed words make a sentence
	MaxEventLetterSlots = 2 // character classes that hold a letter
)

// allowedEventRune is the alphabet of an event text: letters, digits, '_', '.', ':', '-' and the space.
func allowedEventRune(r rune) bool {
	switch {
	case r >= 'A' && r <= 'Z', r >= 'a' && r <= 'z', r >= '0' && r <= '9':
		return true
	}
	return r == '_' || r == '.' || r == ':' || r == '-' || r == ' '
}

// allowedClassRune is the alphabet a character class may hold: the same, without the space.
func allowedClassRune(r rune) bool { return r != ' ' && allowedEventRune(r) }

// CompileEventText checks an operator's pattern against the narrow grammar of ADR 0027 and returns it anchored
// (^(?:pattern)$). It fails closed: anything the grammar does not name is refused. The error names the reason, not the
// pattern.
//
// The grammar: literals from the alphabet; non-negated classes inside it; bounded repeats {n} and {n,m} (m at most 64)
// and ?; concatenation; groups. Refused: alternation, * + {n,}, '.', every escape class, negated classes, flags,
// '^' and '$', escapes other than of ASCII punctuation, and a pattern that matches the empty text.
func CompileEventText(pattern string) (*regexp.Regexp, error) {
	if pattern == "" {
		return nil, errors.New("event text pattern is empty")
	}
	if len(pattern) > MaxEventTextPattern {
		return nil, fmt.Errorf("event text pattern is longer than %d characters", MaxEventTextPattern)
	}
	if err := scanEventPattern(pattern); err != nil {
		return nil, err
	}
	// parsed on its own, so a ')' or '|' in it cannot close the wrapper below
	tree, err := syntax.Parse(pattern, syntax.Perl)
	if err != nil {
		return nil, errors.New("event text pattern does not parse")
	}
	var st treeStats
	if err := checkEventTree(tree, false, &st); err != nil {
		return nil, err
	}
	if st.spaces > MaxEventSpaces {
		return nil, fmt.Errorf("event text pattern has more than %d spaces", MaxEventSpaces)
	}
	if st.slots > MaxEventLetterSlots {
		return nil, fmt.Errorf("event text pattern has more than %d character classes with letters", MaxEventLetterSlots)
	}
	re, err := regexp.Compile(`^(?:` + pattern + `)$`)
	if err != nil {
		return nil, errors.New("event text pattern does not compile")
	}
	if re.MatchString("") {
		return nil, errors.New("event text pattern matches the empty text")
	}
	return re, nil
}

// scanEventPattern looks at the raw text: only printable ASCII; no '|'; a backslash only before ASCII punctuation (so no
// \d \s \w \p \x \Q or octal); '(?' only as '(?:'.
func scanEventPattern(p string) error {
	inClass := false
	for i := 0; i < len(p); i++ {
		c := p[i]
		if c < 0x20 || c > 0x7e {
			return errors.New("event text pattern may hold printable ASCII only")
		}
		switch {
		case c == '|':
			return errors.New("event text pattern may not use alternation")
		case c == '\\':
			if i+1 >= len(p) {
				return errors.New("event text pattern ends with a backslash")
			}
			n := p[i+1]
			if isAlnum(n) || n == ' ' {
				return errors.New("event text pattern may not use escape classes or escaped letters")
			}
			i++
		case c == '[':
			inClass = true
		case c == ']':
			inClass = false
		case c == '(' && !inClass && i+1 < len(p) && p[i+1] == '?':
			if i+2 >= len(p) || p[i+2] != ':' {
				return errors.New("event text pattern may not use flags or special groups")
			}
		}
	}
	return nil
}

func isAlnum(c byte) bool {
	return c >= '0' && c <= '9' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z'
}

// treeStats counts what the caps of the grammar limit.
type treeStats struct {
	spaces int // literal spaces
	slots  int // character classes that hold a letter, repeated or not (the chart counts every one)
}

// repeated is true under a repeat or an optional: a space there would let words repeat, which is prose, not an identifier.
func checkEventTree(re *syntax.Regexp, repeated bool, st *treeStats) error {
	// Case folding can only come from a class of exactly the two cases of one letter ([Ww]): Go turns it into a folded literal. (?i) is refused in
	// the raw text. So the flag is accepted on a literal of letters, and refused on every other node.
	if re.Flags&syntax.FoldCase != 0 && (re.Op != syntax.OpLiteral || !onlyLetters(re.Rune)) {
		return errors.New("event text pattern may not fold case")
	}
	switch re.Op {
	case syntax.OpLiteral:
		for _, r := range re.Rune {
			if !allowedEventRune(r) {
				return errors.New("event text pattern has a literal outside letters, digits and _ . : - space")
			}
			if r == ' ' {
				if repeated {
					return errors.New("event text pattern may not repeat or make optional a space: that lets words repeat")
				}
				st.spaces++
			}
		}
	case syntax.OpCharClass:
		if len(re.Rune) == 0 || len(re.Rune)%2 != 0 {
			return errors.New("event text pattern has an empty character class")
		}
		letters := false
		for i := 0; i < len(re.Rune); i += 2 {
			lo, hi := re.Rune[i], re.Rune[i+1]
			if (lo <= 'Z' && hi >= 'A') || (lo <= 'z' && hi >= 'a') { // the range holds a letter
				letters = true
			}
			if lo < 0 || hi < lo || hi > 'z' {
				return errors.New("event text pattern has a character class outside letters, digits and _ . : -")
			}
			for r := lo; r <= hi; r++ {
				if !allowedClassRune(r) {
					return errors.New("event text pattern has a character class outside letters, digits and _ . : -")
				}
			}
		}
		if letters {
			st.slots++
		}
	case syntax.OpQuest:
		if re.Flags&syntax.NonGreedy != 0 {
			return errors.New("event text pattern may not use lazy repeats")
		}
	case syntax.OpRepeat:
		if re.Flags&syntax.NonGreedy != 0 {
			return errors.New("event text pattern may not use lazy repeats")
		}
		if re.Min < 0 || re.Max < re.Min || re.Max > MaxEventRepeat {
			return fmt.Errorf("event text pattern may repeat at most %d times, and only with {n} or {n,m}", MaxEventRepeat)
		}
	case syntax.OpConcat, syntax.OpCapture:
	case syntax.OpEmptyMatch:
		return errors.New("event text pattern has an empty group")
	default:
		// alternation, star, plus, any character, anchors, boundaries, no match
		return errors.New("event text pattern uses a construct outside the grammar")
	}
	sub := repeated || re.Op == syntax.OpRepeat || re.Op == syntax.OpQuest
	for _, s := range re.Sub {
		if err := checkEventTree(s, sub, st); err != nil {
			return err
		}
	}
	return nil
}

func onlyLetters(rs []rune) bool {
	for _, r := range rs {
		if !(r >= 'A' && r <= 'Z' || r >= 'a' && r <= 'z') {
			return false
		}
	}
	return len(rs) > 0
}

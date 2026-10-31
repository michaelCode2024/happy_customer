package ai

import (
	"strings"
	"unicode/utf8"
)

// SanitizeText removes code points that reach the UI only through corrupted
// knowledge-base text or a misbehaving model and that no shipping font can
// render as a meaningful glyph, so they surface in the console as empty tofu
// boxes. It is a conservative, pure transformation: it never changes valid
// text (CJK, Latin, digits, punctuation, emoji) and only deletes the three
// classes below.
//
// Dropped code points:
//   - U+FFFD, the replacement character, which appears when a UTF-8 string is
//     decoded across a broken byte boundary;
//   - the private-use areas (E000-F8FF and F0000-FFFFD), filled by icon fonts
//     and copied from rich sources such as web pages and Word documents;
//   - C0 and C1 control characters, keeping only tab, line feed and carriage
//     return.
//
// Emoji are deliberately kept: they are legal content an agent may want to
// send. A glyph missing for an emoji on a particular client is a font-fallback
// problem on that client, not a reason to delete the character here.
func SanitizeText(value string) string {
	if value == "" {
		return value
	}
	// Fast path: return the original string untouched when nothing would be
	// dropped, so the common clean case avoids an allocation.
	needsClean := false
	for i := 0; i < len(value); {
		r, size := utf8.DecodeRuneInString(value[i:])
		if !renderable(r) {
			needsClean = true
			break
		}
		i += size
	}
	if !needsClean {
		return value
	}
	var b strings.Builder
	b.Grow(len(value))
	for i := 0; i < len(value); {
		r, size := utf8.DecodeRuneInString(value[i:])
		if renderable(r) {
			b.WriteString(value[i : i+size])
		}
		i += size
	}
	return b.String()
}

// renderable reports whether a single code point survives SanitizeText.
func renderable(r rune) bool {
	switch {
	case r == 0xFFFD: // replacement character
		return false
	case r >= 0xE000 && r <= 0xF8FF: // private use area, BMP
		return false
	case r >= 0xF0000 && r <= 0xFFFFD: // private use area, supplementary
		return false
	case r < 0x20: // C0 controls: keep tab, line feed, carriage return
		return r == 0x09 || r == 0x0A || r == 0x0D
	case r >= 0x7F && r <= 0x9F: // C1 controls
		return false
	}
	return true
}

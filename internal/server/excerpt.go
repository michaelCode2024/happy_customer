package server

import (
	"strings"
)

// Search excerpts.
//
// ts_headline is not usable here: it segments with a built-in tokenizer, so
// under 'simple' it highlights nothing for a Chinese query and would render the
// whole message — which is how the search results ended up showing entire
// conversations instead of the sentence that matched. Building the excerpt in
// Go lets it highlight exactly the terms the database matched on, using the same
// window rules the retrieval side uses.

const (
	excerptLead    = 12
	excerptTrail   = 40
	excerptMaxTerm = 8
)

// excerptAround returns a short, highlighted window of content around the first
// occurrence of any query term. The window is measured in runes, not bytes, so a
// Chinese message is not cut mid-character, and it is placed on match
// boundaries so a highlighted term is never truncated into half a pair of
// markers.
//
// A query that matches nothing yields the head of the content without highlight
// markers, so the caller can always render something useful.
func excerptAround(content, query string) string {
	runes := []rune(content)
	marked := markRunes(runes, query)
	if len(runes) <= excerptLead+excerptTrail {
		return renderMarks(runes, marked)
	}
	start, end := matchWindow(marked)
	if start < 0 {
		return string(runes[:excerptLead+excerptTrail]) + "…"
	}
	start -= excerptLead
	if start < 0 {
		start = 0
	}
	end += excerptTrail
	if end > len(runes) {
		end = len(runes)
	}
	// Slide the edges out of the middle of a highlighted term. Without this a
	// window that starts inside "加急" would render "&lt;&lt;急&gt;&gt;", reading
	// as though the message said something it did not.
	for start > 1 && marked[start-1] && marked[start] {
		start--
	}
	for end < len(runes) && marked[end-1] && marked[end] {
		end++
	}
	window := renderMarks(runes[start:end], marked[start:end])
	if start > 0 {
		window = "…" + window
	}
	if end < len(runes) {
		window += "…"
	}
	return window
}

// matchWindow returns the offset and length of the first marked run, where a run
// is a maximal stretch of marked characters. Returning the span from the first
// mark to the last would be wrong for a common word: a message that says "客服"
// on every line would produce a window covering the whole message, which is the
// behaviour excerpts exist to avoid.
func matchWindow(marked []bool) (int, int) {
	for index, isMarked := range marked {
		if !isMarked {
			continue
		}
		end := index
		for end < len(marked) && marked[end] {
			end++
		}
		return index, end
	}
	return -1, -1
}

// renderMarks wraps runs of marked runes in << >>, the markup the console renders
// as <mark>.
func renderMarks(runes []rune, marked []bool) string {
	var builder strings.Builder
	builder.Grow(len(runes) + 16)
	open := false
	for index, r := range runes {
		isMarked := index < len(marked) && marked[index]
		if isMarked && !open {
			builder.WriteString("<<")
			open = true
		} else if !isMarked && open {
			builder.WriteString(">>")
			open = false
		}
		builder.WriteRune(r)
	}
	if open {
		builder.WriteString(">>")
	}
	return builder.String()
}

// markRunes flags every rune covered by any query term. Marking positions rather
// than substituting terms one at a time is what keeps overlapping terms correct:
// marking "急" inside an already-marked "加急" would otherwise emit nested
// delimiters that the console would show literally.
func markRunes(runes []rune, query string) []bool {
	marked := make([]bool, len(runes))
	for _, term := range excerptTerms(query) {
		needle := []rune(term)
		if len(needle) == 0 {
			continue
		}
		for index := 0; index+len(needle) <= len(runes); index++ {
			if !hasRunesAt(runes, needle, index) {
				continue
			}
			for offset := range needle {
				marked[index+offset] = true
			}
			index += len(needle) - 1
		}
	}
	return marked
}

func hasRunesAt(haystack, needle []rune, at int) bool {
	for offset, r := range needle {
		if haystack[at+offset] != r {
			return false
		}
	}
	return true
}

// excerptTerms picks the terms worth highlighting: the whole query first, then
// its individual words, then its windows from longest to shortest. A single
// character is deliberately excluded — highlighting every occurrence of "的"
// would turn the excerpt into a solid band of colour.
func excerptTerms(query string) []string {
	query = strings.TrimSpace(query)
	if query == "" {
		return nil
	}
	seen := make(map[string]struct{})
	result := make([]string, 0, excerptMaxTerm)
	add := func(value string) {
		if len([]rune(value)) < 2 || len(result) >= excerptMaxTerm {
			return
		}
		if _, ok := seen[value]; ok {
			return
		}
		seen[value] = struct{}{}
		result = append(result, value)
	}
	add(query)
	for _, word := range strings.FieldsFunc(query, func(r rune) bool {
		return !(r >= '0' && r <= '9') && !(r >= 'a' && r <= 'z') && !(r >= 'A' && r <= 'Z') &&
			!(r >= 0x4E00 && r <= 0x9FFF) && !(r >= 0x3400 && r <= 0x4DBF)
	}) {
		add(word)
	}
	runes := []rune(query)
	for size := 4; size >= 2; size-- {
		for index := 0; index+size <= len(runes); index++ {
			add(string(runes[index : index+size]))
		}
	}
	return result
}

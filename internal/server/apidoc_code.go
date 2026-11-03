package server

import (
	"html"
	"strconv"
	"strings"
	"unicode/utf8"
)

// renderCodeBlock wraps a fenced block in the reader-facing chrome: language
// label, copy button and — for sendable HTTP samples — a request runner.
// Highlighting is done in Go so the page needs no CDN and works on an offline
// instance.
//
// An HTTP sample that carries a request line is rendered as tabs: the raw
// request plus generated cURL, JavaScript, Python and Go equivalents. The other
// languages are derived from the same parsed request, so the docs never carry
// five hand-maintained copies that drift apart.
func renderCodeBlock(lang, src string) string {
	lang = strings.ToLower(strings.TrimSpace(lang))
	if lang == "http" {
		if sample, ok := parseHTTPSample(src); ok {
			return renderHTTPBlock(sample, src)
		}
	}

	var body string
	switch lang {
	case "json":
		body = highlightJSON(src)
	case "http":
		body = highlightHTTP(src)
	case "python", "py":
		body = highlightScript(src, pyKeywords, "#")
	case "js", "javascript", "ts":
		body = highlightScript(src, jsKeywords, "//")
	case "bash", "sh", "shell", "console":
		body = highlightScript(src, shKeywords, "#")
	default:
		body = html.EscapeString(src)
	}

	label, class := codeMeta(lang)
	var b strings.Builder
	b.WriteString(`<div class="code" data-lang="`)
	b.WriteString(html.EscapeString(lang))
	b.WriteString(`"><div class="code-bar"><span class="code-lang">`)
	b.WriteString(label)
	b.WriteString(`</span><span class="code-actions">`)
	b.WriteString(`<button class="code-btn code-copy" type="button">复制</button>`)
	b.WriteString(`</span></div><pre><code class="language-`)
	b.WriteString(class)
	b.WriteString(`">`)
	b.WriteString(body)
	b.WriteString(`</code></pre></div>`)
	return b.String()
}

// renderHTTPBlock emits one tab per language for a sendable request sample.
func renderHTTPBlock(sample httpSample, src string) string {
	tabs := []struct {
		key   string
		label string
		class string
		code  string
	}{
		{"http", "HTTP", "http", highlightHTTP(src)},
		{"curl", "cURL", "bash", highlightScript(sample.curl(), shKeywords, "#")},
		{"js", "JavaScript", "js", highlightScript(sample.javascript(), jsKeywords, "//")},
		{"python", "Python", "python", highlightScript(sample.python(), pyKeywords, "#")},
		{"go", "Go", "go", highlightScript(sample.goCode(), goKeywords, "//")},
	}

	var b strings.Builder
	b.WriteString(`<div class="code" data-lang="http" data-tabs="1"><div class="code-bar"><div class="code-tabs" role="tablist">`)
	for i, tab := range tabs {
		b.WriteString(`<button class="code-tab`)
		if i == 0 {
			b.WriteString(" is-on")
		}
		b.WriteString(`" type="button" role="tab" data-tab="`)
		b.WriteString(tab.key)
		b.WriteString(`" aria-selected="`)
		if i == 0 {
			b.WriteString("true")
		} else {
			b.WriteString("false")
		}
		b.WriteString(`">`)
		b.WriteString(tab.label)
		b.WriteString(`</button>`)
	}
	b.WriteString(`</div><span class="code-actions">`)
	b.WriteString(`<button class="code-btn code-try" type="button">调试</button>`)
	b.WriteString(`<button class="code-btn code-copy" type="button">复制</button>`)
	b.WriteString(`</span></div>`)

	for i, tab := range tabs {
		b.WriteString(`<pre data-panel="`)
		b.WriteString(tab.key)
		b.WriteString(`"`)
		if i > 0 {
			b.WriteString(" hidden")
		}
		b.WriteString(`><code class="language-`)
		b.WriteString(tab.class)
		b.WriteString(`">`)
		b.WriteString(tab.code)
		b.WriteString(`</code></pre>`)
	}
	b.WriteString(`</div>`)
	return b.String()
}

func codeMeta(lang string) (label, class string) {
	switch lang {
	case "json":
		return "JSON", "json"
	case "http":
		return "HTTP", "http"
	case "python", "py":
		return "Python", "python"
	case "js", "javascript", "ts":
		return "JavaScript", "js"
	case "bash", "sh", "shell", "console":
		return "Shell", "bash"
	case "":
		return "示例", "text"
	}
	return strings.ToUpper(lang), "text"
}

var pyKeywords = map[string]bool{
	"import": true, "from": true, "def": true, "return": true, "if": true, "elif": true,
	"else": true, "for": true, "while": true, "in": true, "not": true, "and": true,
	"or": true, "None": true, "True": true, "False": true, "class": true, "with": true,
	"as": true, "try": true, "except": true, "raise": true, "lambda": true, "yield": true,
	"pass": true, "break": true, "continue": true, "global": true, "is": true,
}

var jsKeywords = map[string]bool{
	"const": true, "let": true, "var": true, "function": true, "return": true, "if": true,
	"else": true, "for": true, "while": true, "new": true, "await": true, "async": true,
	"true": true, "false": true, "null": true, "undefined": true, "try": true, "catch": true,
	"throw": true, "class": true, "this": true, "typeof": true, "import": true, "export": true,
}

var shKeywords = map[string]bool{
	"curl": true, "echo": true, "export": true, "if": true, "then": true, "fi": true,
	"for": true, "do": true, "done": true, "sudo": true, "docker": true, "git": true,
}

// highlightJSON colours a JSON document: keys, strings, numbers, literals and
// punctuation each get their own class.
func highlightJSON(src string) string {
	var b strings.Builder
	b.Grow(len(src) * 2)
	i := 0
	for i < len(src) {
		c := src[i]
		switch {
		case c == '"':
			j := i + 1
			for j < len(src) {
				if src[j] == '\\' {
					j += 2
					continue
				}
				if src[j] == '"' {
					j++
					break
				}
				j++
			}
			if j > len(src) {
				j = len(src)
			}
			// A string followed by a colon is a key, not a value.
			k := j
			for k < len(src) && isSpaceByte(src[k]) {
				k++
			}
			cls := "j-str"
			if k < len(src) && src[k] == ':' {
				cls = "j-key"
			}
			b.WriteString(`<span class="` + cls + `">`)
			b.WriteString(html.EscapeString(src[i:j]))
			b.WriteString(`</span>`)
			i = j
		case c == '-' || (c >= '0' && c <= '9'):
			j := i + 1
			for j < len(src) && (src[j] >= '0' && src[j] <= '9' || src[j] == '.' || src[j] == '-' ||
				src[j] == '+' || src[j] == 'e' || src[j] == 'E') {
				j++
			}
			b.WriteString(`<span class="j-num">` + src[i:j] + `</span>`)
			i = j
		case hasWordAt(src, i, "true"):
			b.WriteString(`<span class="j-lit">true</span>`)
			i += 4
		case hasWordAt(src, i, "false"):
			b.WriteString(`<span class="j-lit">false</span>`)
			i += 5
		case hasWordAt(src, i, "null"):
			b.WriteString(`<span class="j-lit">null</span>`)
			i += 4
		case c == '{' || c == '}' || c == '[' || c == ']' || c == ':' || c == ',':
			b.WriteString(`<span class="j-pun">`)
			b.WriteByte(c)
			b.WriteString(`</span>`)
			i++
		default:
			r, size := utf8.DecodeRuneInString(src[i:])
			b.WriteString(html.EscapeString(string(r)))
			i += size
		}
	}
	return b.String()
}

// highlightHTTP colours a raw request sample: the request line, header names,
// and a JSON body when the block carries one.
func highlightHTTP(src string) string {
	lines := strings.Split(src, "\n")
	bodyAt := -1
	for i, line := range lines {
		t := strings.TrimSpace(line)
		if t == "" {
			continue
		}
		if strings.HasPrefix(t, "{") || strings.HasPrefix(t, "[") {
			bodyAt = i
			break
		}
	}
	head := lines
	var body []string
	if bodyAt >= 0 {
		head, body = lines[:bodyAt], lines[bodyAt:]
	}

	var b strings.Builder
	started := false
	for _, line := range head {
		t := strings.TrimSpace(line)
		if !started && t != "" {
			verb, rest := splitRequestLine(t)
			if verb != "" {
				path, version := rest, ""
				if idx := strings.LastIndex(rest, " HTTP/"); idx > 0 {
					path, version = rest[:idx], rest[idx+1:]
				}
				b.WriteString(`<span class="m m-` + strings.ToLower(verb) + `">` + verb + `</span> `)
				b.WriteString(`<span class="h-path">` + html.EscapeString(path) + `</span>`)
				if version != "" {
					b.WriteString(` <span class="h-ver">` + html.EscapeString(version) + `</span>`)
				}
			} else {
				b.WriteString(html.EscapeString(line))
			}
			b.WriteString("\n")
			started = true
			continue
		}
		switch {
		case strings.HasPrefix(t, "#"):
			b.WriteString(`<span class="c-cmt">` + html.EscapeString(line) + `</span>`)
		default:
			if name, value, ok := splitHeader(t); ok {
				b.WriteString(`<span class="h-key">` + html.EscapeString(name) + `</span>`)
				b.WriteString(`<span class="j-pun">:</span> `)
				b.WriteString(`<span class="h-val">` + html.EscapeString(value) + `</span>`)
			} else {
				b.WriteString(html.EscapeString(line))
			}
		}
		b.WriteString("\n")
	}
	if len(body) > 0 {
		b.WriteString(highlightJSON(strings.Join(body, "\n")))
	}
	return strings.TrimSuffix(b.String(), "\n")
}

func splitRequestLine(line string) (verb, rest string) {
	sp := strings.IndexByte(line, ' ')
	if sp <= 0 {
		return "", ""
	}
	candidate := line[:sp]
	if !docMethods[candidate] {
		return "", ""
	}
	return candidate, strings.TrimSpace(line[sp+1:])
}

func splitHeader(line string) (name, value string, ok bool) {
	colon := strings.IndexByte(line, ':')
	if colon <= 0 {
		return "", "", false
	}
	name = line[:colon]
	for i := 0; i < len(name); i++ {
		c := name[i]
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_') {
			return "", "", false
		}
	}
	return name, strings.TrimSpace(line[colon+1:]), true
}

// highlightScript covers the string/comment/keyword shapes shared by Python,
// JavaScript and shell samples.
func highlightScript(src string, keywords map[string]bool, comment string) string {
	var b strings.Builder
	i := 0
	for i < len(src) {
		c := src[i]
		switch {
		case comment != "" && strings.HasPrefix(src[i:], comment):
			j := strings.IndexByte(src[i:], '\n')
			if j < 0 {
				j = len(src)
			} else {
				j += i
			}
			b.WriteString(`<span class="c-cmt">` + html.EscapeString(src[i:j]) + `</span>`)
			i = j
		case c == '"' || c == '\'':
			quote := c
			j := i + 1
			for j < len(src) {
				if src[j] == '\\' {
					j += 2
					continue
				}
				if src[j] == quote {
					j++
					break
				}
				j++
			}
			if j > len(src) {
				j = len(src)
			}
			b.WriteString(`<span class="j-str">` + html.EscapeString(src[i:j]) + `</span>`)
			i = j
		case isIdentStart(c):
			j := i + 1
			for j < len(src) && isIdentPart(src[j]) {
				j++
			}
			word := src[i:j]
			if keywords[word] {
				b.WriteString(`<span class="j-kw">` + word + `</span>`)
			} else {
				b.WriteString(html.EscapeString(word))
			}
			i = j
		case c >= '0' && c <= '9':
			j := i + 1
			for j < len(src) && (src[j] >= '0' && src[j] <= '9' || src[j] == '.') {
				j++
			}
			b.WriteString(`<span class="j-num">` + src[i:j] + `</span>`)
			i = j
		default:
			r, size := utf8.DecodeRuneInString(src[i:])
			b.WriteString(html.EscapeString(string(r)))
			i += size
		}
	}
	return b.String()
}

func hasWordAt(src string, i int, word string) bool {
	if !strings.HasPrefix(src[i:], word) {
		return false
	}
	end := i + len(word)
	return end >= len(src) || !isIdentPart(src[end])
}

func isSpaceByte(c byte) bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r'
}

func isIdentStart(c byte) bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c == '_'
}

func isIdentPart(c byte) bool {
	return isIdentStart(c) || c >= '0' && c <= '9'
}

// sampleBase is the placeholder host used by every generated snippet. Readers
// replace it with their own instance, which is exactly what the raw samples say.
const sampleBase = "https://chat.example.com"

// httpSample is a parsed request sample: enough to replay it in another
// language, and nothing more.
type httpSample struct {
	Method  string
	Path    string
	Headers [][2]string
	Body    string
}

func parseHTTPSample(src string) (httpSample, bool) {
	lines := strings.Split(src, "\n")
	var s httpSample
	first := -1
	for i, line := range lines {
		if strings.TrimSpace(line) == "" {
			continue
		}
		first = i
		break
	}
	if first < 0 {
		return httpSample{}, false
	}
	verb, rest := splitRequestLine(strings.TrimSpace(lines[first]))
	if verb == "" {
		return httpSample{}, false
	}
	s.Method = verb
	if idx := strings.LastIndex(rest, " HTTP/"); idx > 0 {
		rest = rest[:idx]
	}
	s.Path = rest

	var bodyLines []string
	for i := first + 1; i < len(lines); i++ {
		t := strings.TrimSpace(lines[i])
		if t == "" {
			if rest := strings.TrimSpace(strings.Join(lines[i+1:], "\n")); rest != "" {
				bodyLines = lines[i+1:]
			}
			break
		}
		if strings.HasPrefix(t, "{") || strings.HasPrefix(t, "[") {
			bodyLines = lines[i:]
			break
		}
		if name, value, ok := splitHeader(t); ok {
			s.Headers = append(s.Headers, [2]string{name, value})
		}
	}
	if len(bodyLines) > 0 {
		s.Body = strings.TrimSpace(strings.Join(bodyLines, "\n"))
	}
	return s, true
}

func (s httpSample) url() string { return sampleBase + s.Path }

// sendableHeaders drops headers the HTTP client owns; fetch() even refuses to
// set Host, so leaving it in would produce a snippet that throws.
func (s httpSample) sendableHeaders() [][2]string {
	out := make([][2]string, 0, len(s.Headers))
	for _, h := range s.Headers {
		switch strings.ToLower(h[0]) {
		case "host", "content-length", "connection":
			continue
		}
		out = append(out, h)
	}
	return out
}

func escapeSingle(v string) string { return strings.ReplaceAll(v, "'", `'\''`) }

func escapeDouble(v string) string {
	v = strings.ReplaceAll(v, `\`, `\\`)
	return strings.ReplaceAll(v, `"`, `\"`)
}

func (s httpSample) curl() string {
	var b strings.Builder
	b.WriteString("curl -X " + s.Method + " '" + s.url() + "'")
	for _, h := range s.sendableHeaders() {
		b.WriteString(" \\\n  -H '" + h[0] + ": " + escapeSingle(h[1]) + "'")
	}
	if s.Body != "" {
		b.WriteString(" \\\n  -d '" + escapeSingle(s.Body) + "'")
	}
	return b.String()
}

func (s httpSample) javascript() string {
	var b strings.Builder
	b.WriteString("const res = await fetch(\"" + s.url() + "\", {\n")
	b.WriteString("  method: \"" + s.Method + "\"")
	if headers := s.sendableHeaders(); len(headers) > 0 {
		b.WriteString(",\n  headers: {\n")
		for i, h := range headers {
			b.WriteString("    \"" + h[0] + "\": \"" + escapeDouble(h[1]) + "\"")
			if i < len(headers)-1 {
				b.WriteString(",")
			}
			b.WriteString("\n")
		}
		b.WriteString("  }")
	}
	if s.Body != "" {
		// A JSON object literal is also a valid JavaScript expression.
		b.WriteString(",\n  body: JSON.stringify(" + s.Body + ")")
	}
	b.WriteString("\n});\n\n")
	b.WriteString("if (!res.ok) throw new Error(res.status + \" \" + (await res.text()));\n")
	b.WriteString("console.log(await res.json());")
	return b.String()
}

func (s httpSample) python() string {
	var b strings.Builder
	b.WriteString("import requests\n\n")
	if s.Body != "" {
		b.WriteString("payload = " + jsonToPython(s.Body) + "\n\n")
	}
	b.WriteString("resp = requests.request(\n")
	b.WriteString("    \"" + s.Method + "\",\n")
	b.WriteString("    \"" + s.url() + "\",\n")
	if headers := s.sendableHeaders(); len(headers) > 0 {
		b.WriteString("    headers={\n")
		for _, h := range headers {
			b.WriteString("        \"" + h[0] + "\": \"" + escapeDouble(h[1]) + "\",\n")
		}
		b.WriteString("    },\n")
	}
	if s.Body != "" {
		b.WriteString("    json=payload,\n")
	}
	b.WriteString("    timeout=10,\n)\n")
	b.WriteString("resp.raise_for_status()\nprint(resp.json())")
	return b.String()
}

func (s httpSample) goCode() string {
	var b strings.Builder
	b.WriteString("package main\n\nimport (\n\t\"fmt\"\n\t\"io\"\n\t\"log\"\n\t\"net/http\"\n")
	if s.Body != "" {
		b.WriteString("\t\"strings\"\n")
	}
	b.WriteString(")\n\nfunc main() {\n")

	arg := "nil"
	if s.Body != "" {
		if strings.Contains(s.Body, "`") {
			b.WriteString("\tbody := strings.NewReader(" + strconv.Quote(s.Body) + ")\n")
		} else {
			b.WriteString("\tbody := strings.NewReader(`" + s.Body + "`)\n")
		}
		arg = "body"
	}
	b.WriteString("\treq, err := http.NewRequest(\"" + s.Method + "\", \"" + s.url() + "\", " + arg + ")\n")
	b.WriteString("\tif err != nil {\n\t\tlog.Fatal(err)\n\t}\n")
	for _, h := range s.sendableHeaders() {
		b.WriteString("\treq.Header.Set(\"" + h[0] + "\", \"" + escapeDouble(h[1]) + "\")\n")
	}
	b.WriteString("\n\tresp, err := http.DefaultClient.Do(req)\n")
	b.WriteString("\tif err != nil {\n\t\tlog.Fatal(err)\n\t}\n")
	b.WriteString("\tdefer resp.Body.Close()\n\n")
	b.WriteString("\tdata, _ := io.ReadAll(resp.Body)\n")
	b.WriteString("\tfmt.Println(resp.Status, string(data))\n}\n")
	return b.String()
}

// jsonToPython rewrites the JSON literals that Python spells differently. It
// tracks string state so a "true" inside a value is left alone.
func jsonToPython(src string) string {
	var b strings.Builder
	inString := false
	for i := 0; i < len(src); i++ {
		c := src[i]
		if inString {
			b.WriteByte(c)
			if c == '\\' && i+1 < len(src) {
				b.WriteByte(src[i+1])
				i++
				continue
			}
			if c == '"' {
				inString = false
			}
			continue
		}
		if c == '"' {
			inString = true
			b.WriteByte(c)
			continue
		}
		if isIdentStart(c) {
			j := i
			for j < len(src) && isIdentPart(src[j]) {
				j++
			}
			switch word := src[i:j]; word {
			case "true":
				b.WriteString("True")
			case "false":
				b.WriteString("False")
			case "null":
				b.WriteString("None")
			default:
				b.WriteString(word)
			}
			i = j - 1
			continue
		}
		b.WriteByte(c)
	}
	return b.String()
}

var goKeywords = map[string]bool{
	"package": true, "import": true, "func": true, "return": true, "if": true, "else": true,
	"for": true, "range": true, "var": true, "const": true, "defer": true, "go": true,
	"nil": true, "true": true, "false": true, "type": true, "struct": true, "map": true,
}

package server

import (
	"crypto/hmac"
	"crypto/sha256"
	"embed"
	"encoding/base64"
	"encoding/json"
	"html"
	"html/template"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"

	"github.com/tongyu/tongyu/internal/auth"
)

//go:embed apidoc
var apidocFS embed.FS

// docEntry is one page of the reference site. Slug is the URL segment, File is
// the embedded Markdown, Label is what the document switcher shows.
type docEntry struct {
	Slug  string
	Label string
	File  string
}

// docSet is the served site. Order is the order of the switcher: the reference
// first, then the onboarding path, then the channel-specific references, and
// the changelog last so it reads as the tail of the set.
var docSet = []docEntry{
	{Slug: "open-api", Label: "开放接口", File: "open-api.md"},
	{Slug: "quickstart", Label: "快速开始", File: "quickstart.md"},
	{Slug: "sdk", Label: "SDK 与代码生成", File: "sdk.md"},
	{Slug: "webhook", Label: "Webhook 回调", File: "webhook.md"},
	{Slug: "integrations", Label: "前端嵌入", File: "integrations.md"},
	{Slug: "groups-api", Label: "群聊 API", File: "groups-api.md"},
	{Slug: "api", Label: "访客端 API", File: "api.md"},
	{Slug: "saas-onboarding", Label: "开通与接入", File: "saas-onboarding.md"},
	{Slug: "platform-api", Label: "运营 API", File: "platform-api.md"},
	{Slug: "changelog", Label: "更新日志", File: "changelog.md"},
}

// docText holds every served document, keyed by slug. The copies under
// apidoc/ are kept in sync with docs/ by scripts/sync-apidoc.sh.
var docText = mustLoadDocs()

// openAPIMarkdown is the default document, served at /docs.
var openAPIMarkdown = docText["open-api"]

// openAPISpec is the machine-readable OpenAPI 3.1 document. It lives beside the
// Markdown so /docs/openapi.json is served from the same binary as the page that
// links to it — an importer never needs a second host.
var openAPISpec = mustLoadSpec()

func mustLoadSpec() []byte {
	raw, err := apidocFS.ReadFile("apidoc/openapi.json")
	if err != nil {
		panic("apidoc: embedded openapi.json missing")
	}
	return raw
}

func mustLoadDocs() map[string]string {
	out := make(map[string]string, len(docSet))
	for _, d := range docSet {
		raw, err := apidocFS.ReadFile("apidoc/" + d.File)
		if err != nil {
			panic("apidoc: embedded copy missing for " + d.File)
		}
		out[d.Slug] = string(raw)
	}
	return out
}

func findDoc(slug string) (docEntry, bool) {
	for _, d := range docSet {
		if d.Slug == slug {
			return d, true
		}
	}
	return docEntry{}, false
}

// registerDocs publishes the integrator reference on the same host as the API.
// The page is part of the server binary, so a deployment serves it without a
// separate static site.
func (a *API) registerDocs(mux *http.ServeMux) {
	if a.cfg.DocsEnabled {
		registerDocsRoutes(mux, nil)
		return
	}
	// 不公开的实例：文档仍要能被客服主管读到，否则「应用接入」里的密钥和回调
	// 就没法配置。控制台登录后点「接口文档」，服务端签发一个 /docs 作用域的
	// Cookie，浏览器带着它才能进；匿名访问一律回首页。
	registerDocsRoutes(mux, a.docsGate)
}

// registerDocsRoutes mounts the reference. A nil gate serves it publicly; a
// non-nil gate decides per request who may read it.
func registerDocsRoutes(mux *http.ServeMux, gate func(http.HandlerFunc) http.HandlerFunc) {
	registerOpenAPIDocs(mux, gate)
}

const (
	// docsCookieName is scoped to /docs so the browser never sends it to the API.
	docsCookieName = "ty_docs"
	// docsCookieTTL is deliberately shorter than the 30-day agent session: the
	// console re-issues it on every click, so a leaked cookie ages out fast.
	docsCookieTTL = 12 * time.Hour
)

// docsGate lets a request through only when it carries a cookie this server
// signed. Anything else is sent to the home page rather than 404: /docs is
// already linked from the marketing site, and a redirect keeps that link from
// dead-ending without confirming what lives here.
func (a *API) docsGate(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if cookie, err := r.Cookie(docsCookieName); err == nil &&
			verifyDocsCookie(a.cfg.WidgetTokenKey, cookie.Value, time.Now()) {
			next(w, r)
			return
		}
		w.Header().Set("Cache-Control", "no-store")
		http.Redirect(w, r, "/", http.StatusFound)
	}
}

// docsCookiePayload binds the cookie to one agent in one tenant, so a cookie
// lifted from another instance or another tenant is useless here.
func docsCookiePayload(tenantID, agentID uuid.UUID, expires int64) string {
	return tenantID.String() + "|" + agentID.String() + "|" + strconv.FormatInt(expires, 10)
}

func signDocsCookie(key string, tenantID, agentID uuid.UUID, expires int64) string {
	payload := docsCookiePayload(tenantID, agentID, expires)
	mac := hmac.New(sha256.New, []byte(key))
	mac.Write([]byte(payload))
	return base64.RawURLEncoding.EncodeToString([]byte(payload)) + "." +
		base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

func verifyDocsCookie(key, value string, now time.Time) bool {
	encoded, sig, ok := strings.Cut(value, ".")
	if !ok {
		return false
	}
	rawPayload, err := base64.RawURLEncoding.DecodeString(encoded)
	if err != nil {
		return false
	}
	rawSig, err := base64.RawURLEncoding.DecodeString(sig)
	if err != nil {
		return false
	}
	mac := hmac.New(sha256.New, []byte(key))
	mac.Write(rawPayload)
	if !hmac.Equal(mac.Sum(nil), rawSig) {
		return false
	}
	parts := strings.Split(string(rawPayload), "|")
	if len(parts) != 3 {
		return false
	}
	expires, err := strconv.ParseInt(parts[2], 10, 64)
	if err != nil {
		return false
	}
	return now.Unix() < expires
}

// consoleDocsAccess mints the docs cookie for a logged-in staff member and hands
// back the URL to open. The console calls it right before opening a tab, so the
// cookie is always fresh and never needs to survive a logout.
func (a *API) consoleDocsAccess(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	expires := time.Now().Add(docsCookieTTL)
	http.SetCookie(w, &http.Cookie{
		Name:     docsCookieName,
		Value:    signDocsCookie(a.cfg.WidgetTokenKey, p.TenantID, p.AgentID, expires.Unix()),
		Path:     "/docs",
		Expires:  expires,
		MaxAge:   int(docsCookieTTL.Seconds()),
		HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
		Secure:   requestIsHTTPS(r, a.cfg.PublicBaseURL),
	})
	respond(w, 200, map[string]any{"url": "/docs", "expiresIn": int(docsCookieTTL.Seconds())})
}

// requestIsHTTPS decides the Secure flag. Behind a TLS-terminating proxy the
// request itself is plain HTTP, so the configured public URL is the tiebreaker.
func requestIsHTTPS(r *http.Request, publicBaseURL string) bool {
	if r.TLS != nil {
		return true
	}
	if proto := r.Header.Get("X-Forwarded-Proto"); proto != "" {
		return strings.EqualFold(strings.TrimSpace(proto), "https")
	}
	return strings.HasPrefix(strings.ToLower(publicBaseURL), "https://")
}

// OpenAPIDocsHandler serves the public API reference without the rest of the
// product. Local preview uses it when Postgres is not running. It ignores
// DOCS_ENABLED on purpose: the flag exists to shape a deployment, not to stop
// an operator from previewing the documents they are about to ship.
func OpenAPIDocsHandler() http.Handler {
	mux := http.NewServeMux()
	registerOpenAPIDocs(mux, nil)
	mux.HandleFunc("GET /{$}", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "/docs", http.StatusTemporaryRedirect)
	})
	return mux
}

func registerOpenAPIDocs(mux *http.ServeMux, gate func(http.HandlerFunc) http.HandlerFunc) {
	if gate == nil {
		gate = func(h http.HandlerFunc) http.HandlerFunc { return h }
	}
	mux.HandleFunc("GET /docs", gate(serveDocPage("open-api")))
	mux.HandleFunc("GET /docs/{$}", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "/docs", http.StatusPermanentRedirect)
	})
	mux.HandleFunc("GET /docs/md/{slug}", gate(serveDocMarkdown))
	// Machine-readable contract: importable by Postman, Insomnia, Apifox and
	// any OpenAPI code generator.
	mux.HandleFunc("GET /docs/openapi.json", gate(serveOpenAPISpec))
	// Kept so older links to the raw Markdown keep working.
	mux.HandleFunc("GET /docs/open-api.md", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "/docs/md/open-api", http.StatusMovedPermanently)
	})
	mux.HandleFunc("GET /docs/{slug}", gate(serveDocBySlug))
}

func serveDocPage(slug string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		entry, ok := findDoc(slug)
		if !ok {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("Cache-Control", "no-cache")
		_ = openAPIPage.Execute(w, renderDocPage(docText[entry.Slug], entry))
	}
}

func serveDocBySlug(w http.ResponseWriter, r *http.Request) {
	serveDocPage(r.PathValue("slug"))(w, r)
}

func serveDocMarkdown(w http.ResponseWriter, r *http.Request) {
	entry, ok := findDoc(r.PathValue("slug"))
	if !ok {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", "text/markdown; charset=utf-8")
	w.Header().Set("Content-Disposition", `inline; filename="`+entry.File+`"`)
	w.Header().Set("Cache-Control", "no-cache")
	_, _ = w.Write([]byte(docText[entry.Slug]))
}

// serveOpenAPISpec hands out the OpenAPI document verbatim. It is served inline
// rather than as an attachment so a browser tab renders it and a tool that
// fetches the URL gets the same bytes.
func serveOpenAPISpec(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Content-Disposition", `inline; filename="openapi.json"`)
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Access-Control-Allow-Origin", "*")
	_, _ = w.Write(openAPISpec)
}

type openAPIView struct {
	Title    string
	Subtitle string
	Version  string
	Updated  string
	Nav      template.HTML
	Body     template.HTML
	Markdown string
	Spec     string
	Index    template.JS
	Docs     []docOption
	HasIndex bool
	HasCodes bool
}

// docOption is one row of the document switcher.
type docOption struct {
	Slug   string
	Label  string
	Active bool
}

type docHeading struct {
	Level int
	ID    string
	Text  string
}

// docSnippet is one searchable block: a heading, a paragraph, a table row or a
// callout. The reader's search box runs over these instead of the raw Markdown,
// so every hit points at something actually rendered on the page.
type docSnippet struct {
	ID   string `json:"id"`
	Sec  string `json:"s"`
	Kind string `json:"k"`
	Text string `json:"t"`
}

// docContext carries the state the block renderers need to build the search
// index and the responsive table labels.
type docContext struct {
	section string
	current string
	index   []docSnippet
}

func (c *docContext) add(kind, text string) {
	text = strings.TrimSpace(stripDocMarkup(text))
	if text == "" {
		return
	}
	c.index = append(c.index, docSnippet{
		ID:   c.current,
		Sec:  c.section,
		Kind: kind,
		Text: truncateRunes(text, 220),
	})
}

func renderOpenAPI(src string) openAPIView {
	return renderDocPage(src, docSet[0])
}

func renderDocPage(src string, cur docEntry) openAPIView {
	body, headings, snippets := renderDocFull(src)
	title := "通语开放接口文档"
	subtitle := "业务系统服务端对接参考"
	if len(headings) > 0 {
		title = headings[0].Text
	}
	if len(headings) > 1 && headings[1].Level == 2 {
		subtitle = headings[1].Text
	}
	version, updated := docStamp(src)

	hasIndex, hasCodes := false, false
	for _, h := range headings {
		if h.Level != 2 {
			continue
		}
		if strings.Contains(h.Text, "接口目录") {
			hasIndex = true
		}
		if strings.Contains(h.Text, "错误码") {
			hasCodes = true
		}
	}

	var nav strings.Builder
	for i, h := range headings {
		if h.Level != 2 {
			continue
		}
		nav.WriteString(`<div class="nav-group"><div class="nav-row"><a class="lv2" href="#`)
		nav.WriteString(h.ID)
		nav.WriteString(`">`)
		nav.WriteString(html.EscapeString(h.Text))
		nav.WriteString(`</a><button class="nav-fold" type="button" aria-expanded="true" aria-label="折叠该组">`)
		nav.WriteString(`<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M4 6l4 4 4-4"/></svg>`)
		nav.WriteString(`</button></div><div class="nav-sub">`)
		for j := i + 1; j < len(headings); j++ {
			if headings[j].Level == 2 {
				break
			}
			if headings[j].Level != 3 {
				continue
			}
			nav.WriteString(`<a class="lv3" href="#`)
			nav.WriteString(headings[j].ID)
			nav.WriteString(`">`)
			nav.WriteString(html.EscapeString(headings[j].Text))
			nav.WriteString(`</a>`)
		}
		nav.WriteString(`</div></div>`)
	}

	idx, _ := json.Marshal(snippets)
	opts := make([]docOption, 0, len(docSet))
	for _, d := range docSet {
		opts = append(opts, docOption{Slug: d.Slug, Label: d.Label, Active: d.Slug == cur.Slug})
	}
	return openAPIView{
		Title:    title,
		Subtitle: subtitle,
		Version:  version,
		Updated:  updated,
		Nav:      template.HTML(nav.String()),
		Body:     body,
		Markdown: "/docs/md/" + cur.Slug,
		Spec:     "/docs/openapi.json",
		Index:    template.JS(idx),
		Docs:     opts,
		HasIndex: hasIndex,
		HasCodes: hasCodes,
	}
}

// docStamp pulls the version and date out of the metadata line under the
// document title, e.g. "版本 **v1** · 更新日期 **2026-11-02** · 适用服务端 **TongYu 主线**".
func docStamp(src string) (version, updated string) {
	lines := strings.Split(strings.ReplaceAll(src, "\r\n", "\n"), "\n")
	if len(lines) > 8 {
		lines = lines[:8]
	}
	for _, line := range lines {
		if !strings.Contains(line, "版本") || !strings.Contains(line, "更新日期") {
			continue
		}
		for _, part := range strings.Split(line, "·") {
			part = strings.TrimSpace(part)
			switch {
			case strings.Contains(part, "版本"):
				version = strings.TrimSpace(strings.TrimPrefix(part, "版本"))
			case strings.Contains(part, "更新日期"):
				updated = strings.TrimSpace(strings.TrimPrefix(part, "更新日期"))
			}
		}
		break
	}
	return strings.Trim(version, "* "), strings.Trim(updated, "* ")
}

// renderDoc is the block renderer without the search index, kept for callers
// that only need HTML and the heading outline.
func renderDoc(src string) (template.HTML, []docHeading) {
	body, headings, _ := renderDocFull(src)
	return body, headings
}

func renderDocFull(src string) (template.HTML, []docHeading, []docSnippet) {
	lines := strings.Split(strings.ReplaceAll(src, "\r\n", "\n"), "\n")
	var b strings.Builder
	var headings []docHeading
	used := map[string]int{}
	ctx := &docContext{}
	seenSection := false
	i := 0
	for i < len(lines) {
		trim := strings.TrimSpace(lines[i])
		switch {
		case trim == "":
			i++
		case strings.HasPrefix(trim, "```"):
			lang := strings.TrimSpace(strings.TrimPrefix(trim, "```"))
			var code []string
			i++
			for i < len(lines) && !strings.HasPrefix(strings.TrimSpace(lines[i]), "```") {
				code = append(code, lines[i])
				i++
			}
			if i < len(lines) {
				i++
			}
			b.WriteString(renderCodeBlock(lang, strings.Join(code, "\n")))
		case strings.HasPrefix(trim, "|"):
			var rows []string
			for i < len(lines) && strings.HasPrefix(strings.TrimSpace(lines[i]), "|") {
				rows = append(rows, strings.TrimSpace(lines[i]))
				i++
			}
			b.WriteString(renderDocTable(rows, ctx))
		case headingLevel(trim) > 0:
			level := headingLevel(trim)
			text := strings.TrimSpace(trim[level+1:])
			id := uniqueHeadingID(text, used)
			headings = append(headings, docHeading{Level: level, ID: id, Text: text})
			ctx.current = id
			if level == 2 {
				ctx.section = text
				seenSection = true
			}
			ctx.add("标题", text)
			b.WriteString("<h")
			b.WriteString(strconv.Itoa(level))
			b.WriteString(` id="`)
			b.WriteString(id)
			b.WriteString(`">`)
			b.WriteString(inlineDoc(text))
			b.WriteString(`<a class="hlink" href="#`)
			b.WriteString(id)
			b.WriteString(`" aria-label="本节链接">#</a>`)
			b.WriteString("</h")
			b.WriteString(strconv.Itoa(level))
			b.WriteString(">\n")
			i++
		case isDocBullet(trim):
			b.WriteString("<ul>\n")
			for i < len(lines) && isDocBullet(strings.TrimSpace(lines[i])) {
				item := strings.TrimSpace(lines[i])[2:]
				ctx.add("列表", item)
				b.WriteString("<li>")
				b.WriteString(inlineDoc(item))
				b.WriteString("</li>\n")
				i++
			}
			b.WriteString("</ul>\n")
		case orderedItem(trim):
			b.WriteString("<ol>\n")
			for i < len(lines) && orderedItem(strings.TrimSpace(lines[i])) {
				item := strings.TrimSpace(lines[i])
				dot := strings.IndexByte(item, '.')
				ctx.add("列表", strings.TrimSpace(item[dot+1:]))
				b.WriteString("<li>")
				b.WriteString(inlineDoc(strings.TrimSpace(item[dot+1:])))
				b.WriteString("</li>\n")
				i++
			}
			b.WriteString("</ol>\n")
		case strings.HasPrefix(trim, ">"):
			var parts []string
			for i < len(lines) {
				line := strings.TrimSpace(lines[i])
				if !strings.HasPrefix(line, ">") {
					break
				}
				parts = append(parts, strings.TrimSpace(strings.TrimPrefix(strings.TrimPrefix(line, ">"), " ")))
				i++
			}
			ctx.add("提示", strings.Join(parts, " "))
			b.WriteString(`<div class="note">`)
			b.WriteString(inlineDoc(strings.Join(parts, " ")))
			b.WriteString("</div>\n")
		default:
			var parts []string
			for i < len(lines) && !docBlockStart(lines[i]) {
				parts = append(parts, strings.TrimSpace(lines[i]))
				i++
			}
			text := strings.Join(parts, " ")
			// The line under the title carries version, date and target server;
			// render it as page metadata rather than a lead paragraph.
			if !seenSection && strings.Contains(text, "更新日期") {
				b.WriteString(`<p class="doc-meta">`)
				b.WriteString(inlineDoc(text))
				b.WriteString("</p>\n")
				continue
			}
			// A paragraph that is nothing but one bold run reads as a sub-label
			// above the table it introduces.
			if label, ok := docLabel(text); ok {
				b.WriteString(`<p class="label">`)
				b.WriteString(label)
				b.WriteString("</p>\n")
				continue
			}
			ctx.add("正文", text)
			b.WriteString("<p>")
			b.WriteString(inlineDoc(text))
			b.WriteString("</p>\n")
		}
	}
	return template.HTML(b.String()), headings, ctx.index
}

func docLabel(text string) (string, bool) {
	if !strings.HasPrefix(text, "**") || !strings.HasSuffix(text, "**") || len(text) < 5 {
		return "", false
	}
	inner := text[2 : len(text)-2]
	if strings.Contains(inner, "**") {
		return "", false
	}
	return "<strong>" + html.EscapeString(inner) + "</strong>", true
}

func isDocBullet(trim string) bool {
	return strings.HasPrefix(trim, "- ") || strings.HasPrefix(trim, "* ")
}

func headingLevel(trim string) int {
	level := 0
	for level < len(trim) && trim[level] == '#' {
		level++
	}
	if level >= 1 && level <= 4 && level < len(trim) && trim[level] == ' ' {
		return level
	}
	return 0
}

func orderedItem(trim string) bool {
	dot := strings.IndexByte(trim, '.')
	if dot <= 0 || dot > 2 || dot+1 >= len(trim) || trim[dot+1] != ' ' {
		return false
	}
	for _, r := range trim[:dot] {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

func docBlockStart(line string) bool {
	trim := strings.TrimSpace(line)
	return trim == "" || strings.HasPrefix(trim, "```") || strings.HasPrefix(trim, "|") || isDocBullet(trim) ||
		strings.HasPrefix(trim, ">") || orderedItem(trim) || headingLevel(trim) > 0
}

var docMethods = map[string]bool{"GET": true, "POST": true, "PUT": true, "PATCH": true, "DELETE": true}

// methodBadge turns a bare HTTP verb into a coloured pill, which is how the
// classic API reference tables read. A cell must contain only the verb so a
// sentence that merely mentions "GET" is untouched.
func methodBadge(cell string) (string, bool) {
	if !docMethods[strings.ToUpper(strings.TrimSpace(cell))] {
		return "", false
	}
	verb := strings.ToUpper(strings.TrimSpace(cell))
	return `<span class="m m-` + strings.ToLower(verb) + `">` + verb + `</span>`, true
}

func renderDocTable(rows []string, ctx *docContext) string {
	parsed := make([][]string, 0, len(rows))
	for _, row := range rows {
		cells := splitDocRow(row)
		if isDocRule(cells) {
			continue
		}
		parsed = append(parsed, cells)
	}
	if len(parsed) == 0 {
		return ""
	}
	// Header labels become data-label on every cell so the narrow-screen layout
	// can stack rows into cards without losing the column names.
	labels := make([]string, len(parsed[0]))
	for i, cell := range parsed[0] {
		labels[i] = stripDocMarkup(cell)
	}
	var b strings.Builder
	b.WriteString("<div class=\"table-wrap\"><table>\n<thead><tr>")
	for _, cell := range parsed[0] {
		b.WriteString("<th>")
		b.WriteString(docCell(cell))
		b.WriteString("</th>")
	}
	b.WriteString("</tr></thead>\n")
	if len(parsed) > 1 {
		b.WriteString("<tbody>\n")
		for _, row := range parsed[1:] {
			b.WriteString("<tr>")
			for i, cell := range row {
				b.WriteString("<td")
				if i < len(labels) && labels[i] != "" {
					b.WriteString(` data-label="`)
					b.WriteString(html.EscapeString(labels[i]))
					b.WriteString(`"`)
				}
				b.WriteString(">")
				b.WriteString(docCell(cell))
				b.WriteString("</td>")
			}
			b.WriteString("</tr>\n")
			ctx.add("表格", strings.Join(row, " "))
		}
		b.WriteString("</tbody>")
	}
	b.WriteString("</table></div>\n")
	return b.String()
}

// docCell renders one table cell: an HTTP verb becomes a pill, a served
// document name becomes a link, everything else goes through inline markup.
func docCell(cell string) string {
	if badge, ok := methodBadge(cell); ok {
		return badge
	}
	if link, ok := docNameLink(cell); ok {
		return link
	}
	if isDocDate(cell) {
		return `<span class="nb">` + html.EscapeString(strings.TrimSpace(cell)) + `</span>`
	}
	return inlineDoc(cell)
}

// isDocDate matches YYYY-MM-DD. A date column is narrow, and the browser will
// happily break "2026-11-02" into "2026-11-" + "02", which reads as two values.
func isDocDate(s string) bool {
	s = strings.TrimSpace(s)
	if len(s) != 10 || s[4] != '-' || s[7] != '-' {
		return false
	}
	for i := 0; i < len(s); i++ {
		if i == 4 || i == 7 {
			continue
		}
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

// docNameLink turns a bare `webhook.md` cell into a link to that document. The
// companion-document table names its targets in backticks, so this is what makes
// that table navigable without editing the Markdown.
func docNameLink(cell string) (string, bool) {
	cell = strings.TrimSpace(cell)
	if !strings.HasPrefix(cell, "`") || !strings.HasSuffix(cell, "`") || len(cell) < 4 {
		return "", false
	}
	name := cell[1 : len(cell)-1]
	if !strings.HasSuffix(name, ".md") || strings.ContainsAny(name, " /") {
		return "", false
	}
	slug := strings.TrimSuffix(name, ".md")
	if _, ok := findDoc(slug); !ok {
		return "", false
	}
	return `<a href="/docs/` + slug + `"><code>` + html.EscapeString(name) + `</code></a>`, true
}

func splitDocRow(row string) []string {
	row = strings.TrimSpace(row)
	row = strings.Trim(row, "|")
	parts := strings.Split(row, "|")
	out := make([]string, 0, len(parts))
	for _, part := range parts {
		out = append(out, strings.TrimSpace(part))
	}
	return out
}

func isDocRule(cells []string) bool {
	if len(cells) == 0 {
		return false
	}
	for _, cell := range cells {
		cell = strings.Trim(cell, " :-")
		if cell != "" {
			return false
		}
	}
	return true
}

func uniqueHeadingID(text string, used map[string]int) string {
	var b strings.Builder
	b.WriteString("s-")
	for _, r := range text {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9':
			b.WriteRune(r)
		case r > 127:
			b.WriteRune(r)
		}
	}
	base := b.String()
	if base == "s-" {
		base = "s-section"
	}
	n := used[base]
	used[base] = n + 1
	if n == 0 {
		return base
	}
	return base + "-" + strconv.Itoa(n+1)
}

func inlineDoc(s string) string {
	var b strings.Builder
	for len(s) > 0 {
		if s[0] == '`' {
			if end := strings.IndexByte(s[1:], '`'); end >= 0 {
				b.WriteString("<code>")
				b.WriteString(html.EscapeString(s[1 : 1+end]))
				b.WriteString("</code>")
				s = s[2+end:]
				continue
			}
		}
		if s[0] == '[' {
			if text, url, rest, ok := parseDocLink(s); ok {
				b.WriteString(`<a href="`)
				b.WriteString(html.EscapeString(url))
				b.WriteString(`">`)
				b.WriteString(inlineDoc(text))
				b.WriteString("</a>")
				s = rest
				continue
			}
		}
		if strings.HasPrefix(s, "**") {
			if end := strings.Index(s[2:], "**"); end >= 0 {
				b.WriteString("<strong>")
				b.WriteString(html.EscapeString(s[2 : 2+end]))
				b.WriteString("</strong>")
				s = s[4+end:]
				continue
			}
		}
		n := 1
		for n < len(s) && s[n] != '`' && s[n] != '[' && !strings.HasPrefix(s[n:], "**") {
			n++
		}
		b.WriteString(html.EscapeString(s[:n]))
		s = s[n:]
	}
	return b.String()
}

// docLinkSchemes are the only absolute targets a documentation link may point
// at, so a pasted javascript: or data: URL can never reach a reader's browser.
var docLinkSchemes = []string{"#", "/docs/", "http://", "https://", "mailto:"}

// resolveDocLink decides whether a Markdown target may become a live anchor.
// A relative "*.md" naming another served document is rewritten to its page
// route; anything unrecognised stays plain text instead of a dead link.
func resolveDocLink(url string) (string, bool) {
	for _, scheme := range docLinkSchemes {
		if strings.HasPrefix(url, scheme) {
			return url, true
		}
	}
	name, anchor, _ := strings.Cut(url, "#")
	if !strings.HasSuffix(name, ".md") || strings.Contains(name, "/") {
		return "", false
	}
	slug := strings.TrimSuffix(name, ".md")
	if _, ok := findDoc(slug); !ok {
		return "", false
	}
	if anchor != "" {
		return "/docs/" + slug + "#" + anchor, true
	}
	return "/docs/" + slug, true
}

func parseDocLink(s string) (text, url, rest string, ok bool) {
	closing := strings.Index(s, "](")
	if closing < 0 {
		return "", "", "", false
	}
	end := strings.Index(s[closing+2:], ")")
	if end < 0 {
		return "", "", "", false
	}
	text, url = s[1:closing], s[closing+2:closing+2+end]
	if resolved, ok := resolveDocLink(url); ok {
		return text, resolved, s[closing+2+end+1:], true
	}
	return "", "", "", false
}

// stripDocMarkup flattens inline Markdown to the words a reader sees, which is
// what the search index and the table labels need.
func stripDocMarkup(s string) string {
	var b strings.Builder
	for len(s) > 0 {
		switch {
		case s[0] == '`':
			if end := strings.IndexByte(s[1:], '`'); end >= 0 {
				b.WriteString(s[1 : 1+end])
				s = s[2+end:]
				continue
			}
		case s[0] == '[':
			if text, _, rest, ok := parseDocLink(s); ok {
				b.WriteString(text)
				s = rest
				continue
			}
		case strings.HasPrefix(s, "**"):
			if end := strings.Index(s[2:], "**"); end >= 0 {
				b.WriteString(s[2 : 2+end])
				s = s[4+end:]
				continue
			}
		}
		b.WriteByte(s[0])
		s = s[1:]
	}
	return strings.Join(strings.Fields(b.String()), " ")
}

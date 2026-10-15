package server

import (
	"encoding/json"
	"html/template"
	"io/fs"
	"net/http"
	"os"
	"path/filepath"
	"strings"
)

var h5Page = template.Must(template.New("h5").Parse(`<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
	<title>通语客服</title>
  <style>html,body{margin:0;height:100%;background:#f5f6f8}</style>
</head>
<body>
  <script>window.RelayDeskSettings={{.SettingsJSON}};</script>
  <script src="/widget.js" defer></script>
</body>
</html>`))

// registerStatic serves the same binaries whose URLs are returned by the
// install-snippet and tenant-provisioning APIs. StaticDir is optional for API-
// only deployments, but a configured directory must contain both build outputs.
func (a *API) registerStatic(mux *http.ServeMux) {
	if a.cfg.StaticDir == "" {
		return
	}
	// 官网与控制台各有入口；精确匹配根路径，避免吞掉未知 API 和资源的 404。
	website := filepath.Join(a.cfg.StaticDir, "website")
	mux.HandleFunc("GET /downloads/{$}", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-cache")
		http.ServeFile(w, r, filepath.Join(website, "downloads.html"))
	})
	// 安装包独立存放，更新客户端无需覆盖网站和业务数据。
	downloadDir := os.Getenv("DOWNLOAD_DIR")
	if downloadDir == "" {
		downloadDir = filepath.Join(a.cfg.StaticDir, "downloads")
	}
	// 描述文件保留苹果识别类型，同时让桌面浏览器明确按文件下载。
	mux.HandleFunc("GET /downloads/tongyu-ios.mobileconfig", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/x-apple-aspen-config")
		w.Header().Set("Content-Disposition", `attachment; filename="tongyu-ios.mobileconfig"`)
		w.Header().Set("Cache-Control", "no-cache")
		http.ServeFile(w, r, filepath.Join(downloadDir, "tongyu-ios.mobileconfig"))
	})
	mux.Handle("GET /downloads/", http.StripPrefix("/downloads/", http.FileServer(http.Dir(downloadDir))))
	mux.HandleFunc("GET /{$}", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-cache")
		http.ServeFile(w, r, filepath.Join(website, "index.html"))
	})
	mux.Handle("GET /website/", http.StripPrefix("/website/", http.FileServer(http.Dir(website))))
	mux.HandleFunc("GET /groups.html", func(w http.ResponseWriter, r *http.Request) {
		a.setFrameAncestors(w)
		w.Header().Set("Cache-Control", "no-store")
		http.ServeFile(w, r, filepath.Join(a.cfg.StaticDir, "groups.html"))
	})
	mux.HandleFunc("GET /group-interactions.js", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		http.ServeFile(w, r, filepath.Join(a.cfg.StaticDir, "group-interactions.js"))
	})
	mux.HandleFunc("GET /group-conference.js", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		http.ServeFile(w, r, filepath.Join(a.cfg.StaticDir, "group-conference.js"))
	})
	widget := filepath.Join(a.cfg.StaticDir, "widget.js")
	console := filepath.Join(a.cfg.StaticDir, "console")
	mux.HandleFunc("GET /widget.js", func(w http.ResponseWriter, r *http.Request) {
		// 安装脚本使用固定地址，更新时必须重新验证，避免客户继续加载旧界面。
		w.Header().Set("Cache-Control", "no-cache")
		w.Header().Set("Content-Type", "text/javascript; charset=utf-8")
		http.ServeFile(w, r, widget)
	})
	mux.HandleFunc("GET /h5/{inboxKey}", func(w http.ResponseWriter, r *http.Request) {
		key := r.PathValue("inboxKey")
		if key == "" || strings.ContainsAny(key, "/\\") {
			http.NotFound(w, r)
			return
		}
		settings := map[string]any{
			"endpoint":     a.cfg.PublicBaseURL,
			"inboxKey":     key,
			"embedded":     true,
			"source":       "H5",
			"launcher":     "none",
			"autoOpen":     true,
			"parentOrigin": firstNonEmpty(r.URL.Query().Get("parentOrigin"), "*"),
		}
		if r.URL.Query().Get("source") == "APP" {
			settings["source"] = "APP"
		}
		if theme := r.URL.Query().Get("theme"); theme == "light" || theme == "dark" {
			settings["theme"] = theme
		}
		if color := r.URL.Query().Get("primaryColor"); color != "" {
			settings["primaryColor"] = color
		}
		if title := r.URL.Query().Get("title"); title != "" {
			settings["title"] = title
		}
		if externalID := r.URL.Query().Get("externalId"); externalID != "" {
			settings["externalId"] = externalID
		}
		if name := r.URL.Query().Get("displayName"); name != "" {
			settings["displayName"] = name
		}
		encoded, err := json.Marshal(settings)
		if err != nil {
			fail(w, 500, "渲染嵌入页失败")
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("Cache-Control", "no-store")
		a.setFrameAncestors(w)
		if err := h5Page.Execute(w, map[string]any{
			"SettingsJSON": template.JS(encoded),
		}); err != nil {
			a.logger.Error("render H5 page failed", "error", err)
		}
	})
	mux.HandleFunc("GET /console/", func(w http.ResponseWriter, r *http.Request) {
		// Flutter's asset URLs use /console/ as their base. Unknown paths are
		// routed to the index only for browser navigation, not missing assets.
		path := strings.TrimPrefix(r.URL.Path, "/console/")
		if path == "" {
			path = "index.html"
		}
		if !fs.ValidPath(path) || strings.Contains(path, "\\") {
			http.NotFound(w, r)
			return
		}
		file := filepath.Join(console, filepath.FromSlash(path))
		if info, err := os.Stat(file); err != nil || info.IsDir() {
			if strings.Contains(filepath.Base(path), ".") {
				http.NotFound(w, r)
				return
			}
			file = filepath.Join(console, "index.html")
		}
		// 后台资源使用固定文件名，更新后必须重新验证脚本与图标版本。
		w.Header().Set("Cache-Control", "no-cache")
		http.ServeFile(w, r, file)
	})
	mux.HandleFunc("GET /console", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "/console/", http.StatusPermanentRedirect)
	})
	// 本机联调：模拟第三方业务 H5 嵌入客服，不进入 /console 体系。
	mux.HandleFunc("GET /demo/{name}", func(w http.ResponseWriter, r *http.Request) {
		name := r.PathValue("name")
		if name == "" || strings.ContainsAny(name, `/\:`) || !strings.HasSuffix(name, ".html") {
			http.NotFound(w, r)
			return
		}
		file := filepath.Join(a.cfg.StaticDir, name)
		if info, err := os.Stat(file); err != nil || info.IsDir() {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		http.ServeFile(w, r, file)
	})
}

// setFrameAncestors lets the host product iframe /h5 while still allowing an
// allowlist via FRAME_ANCESTORS (space-separated CSP sources).
func (a *API) setFrameAncestors(w http.ResponseWriter) {
	ancestors := a.cfg.FrameAncestors
	if len(ancestors) == 0 {
		ancestors = []string{"*"}
	}
	w.Header().Set("Content-Security-Policy", "frame-ancestors "+strings.Join(ancestors, " "))
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}

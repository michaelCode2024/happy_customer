package server

import (
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/tongyu/tongyu/internal/config"
)

func TestStaticRoutes(t *testing.T) {
	dir := t.TempDir()
	if err := os.Mkdir(filepath.Join(dir, "console"), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(dir, "website"), 0755); err != nil {
		t.Fatal(err)
	}
	for path, content := range map[string]string{
		"widget.js":            "window.TongYu = {};",
		"console/index.html":   `<base href="/console/">`,
		"console/main.dart.js": "console.log('console');",
		"website/index.html":   `<title>通语 TongYu</title><a href="/console/?surface=agent">登录</a>`,
		"website/site.css":     "body{margin:0}",
	} {
		if err := os.WriteFile(filepath.Join(dir, filepath.FromSlash(path)), []byte(content), 0644); err != nil {
			t.Fatal(err)
		}
	}
	a := &API{cfg: config.Config{StaticDir: dir, PublicBaseURL: "https://chat.example.com"}, logger: slog.Default()}
	mux := http.NewServeMux()
	a.registerStatic(mux)

	for _, tc := range []struct {
		path, content string
		status        int
	}{
		{path: "/widget.js", content: "window.TongYu", status: 200},
		{path: "/", content: "通语 TongYu", status: 200},
		{path: "/website/site.css", content: "margin:0", status: 200},
		{path: "/website/missing.js", status: 404},
		{path: "/unknown", status: 404},
		{path: "/api/unknown", status: 404},
		{path: "/console/", content: `/console/`, status: 200},
		{path: "/console/main.dart.js", content: "console.log", status: 200},
		{path: "/console/unavailable.js", status: 404},
		{path: "/console/unknown/route", content: `/console/`, status: 200},
		{path: "/h5/demo-web", content: `"demo-web"`, status: 200},
		{path: "/h5/key%3Fwith%23symbols", content: `"key?with#symbols"`, status: 200},
		{path: "/h5/%22%3Cscript%3E", content: `\u003cscript`, status: 200},
	} {
		t.Run(tc.path, func(t *testing.T) {
			r := httptest.NewRecorder()
			mux.ServeHTTP(r, httptest.NewRequest(http.MethodGet, tc.path, nil))
			if r.Code != tc.status || (tc.content != "" && !strings.Contains(r.Body.String(), tc.content)) {
				t.Fatalf("status=%d body=%q", r.Code, r.Body.String())
			}
		})
	}
	redirect := httptest.NewRecorder()
	mux.ServeHTTP(redirect, httptest.NewRequest(http.MethodGet, "/console", nil))
	if redirect.Code != http.StatusPermanentRedirect || redirect.Header().Get("Location") != "/console/" {
		t.Fatalf("console redirect: %d %q", redirect.Code, redirect.Header().Get("Location"))
	}
	for _, path := range []string{"/console/desktop.html?surface=agent", "/console/mobile.html?surface=platform"} {
		legacy := httptest.NewRecorder()
		mux.ServeHTTP(legacy, httptest.NewRequest(http.MethodGet, path, nil))
		if legacy.Code != http.StatusPermanentRedirect || !strings.HasPrefix(legacy.Header().Get("Location"), "/console/?") {
			t.Fatalf("legacy shell %s: %d %q", path, legacy.Code, legacy.Header().Get("Location"))
		}
	}
}

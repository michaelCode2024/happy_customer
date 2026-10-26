package server

import (
	"bytes"
	"compress/gzip"
	"io"
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
	if err := os.MkdirAll(filepath.Join(dir, "console", "canvaskit", "chromium"), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(dir, "console", "assets", "fonts"), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(dir, "website"), 0755); err != nil {
		t.Fatal(err)
	}
	for path, content := range map[string]string{
		"widget.js":            "window.TongYu = {};",
		"console/index.html":   `<base href="/console/">`,
		"console/main.dart.js":                    "console.log('console');",
		"console/canvaskit/chromium/canvaskit.wasm": "wasm-bytes",
		"console/assets/fonts/NotoSansSC-Regular.otf": "font-bytes",
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
	plain := httptest.NewRecorder()
	mux.ServeHTTP(plain, httptest.NewRequest(http.MethodGet, "/console/canvaskit/chromium/canvaskit.wasm", nil))
	if plain.Code != 200 || plain.Body.String() != "wasm-bytes" || !strings.Contains(plain.Header().Get("Cache-Control"), "max-age=86400") {
		t.Fatalf("wasm plain: %d %q %q", plain.Code, plain.Header().Get("Cache-Control"), plain.Body.String())
	}
	zippedReq := httptest.NewRequest(http.MethodGet, "/console/canvaskit/chromium/canvaskit.wasm", nil)
	zippedReq.Header.Set("Accept-Encoding", "gzip")
	zipped := httptest.NewRecorder()
	mux.ServeHTTP(zipped, zippedReq)
	if zipped.Code != 200 || zipped.Header().Get("Content-Encoding") != "gzip" {
		t.Fatalf("wasm gzip: %d %q", zipped.Code, zipped.Header().Get("Content-Encoding"))
	}
	reader, err := gzip.NewReader(bytes.NewReader(zipped.Body.Bytes()))
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := io.ReadAll(reader)
	if err != nil {
		t.Fatal(err)
	}
	if string(decoded) != "wasm-bytes" {
		t.Fatalf("wasm gzip body: %q", decoded)
	}
	font := httptest.NewRecorder()
	mux.ServeHTTP(font, httptest.NewRequest(http.MethodGet, "/console/assets/fonts/NotoSansSC-Regular.otf", nil))
	if font.Code != 200 || !strings.Contains(font.Header().Get("Cache-Control"), "max-age=86400") {
		t.Fatalf("font cache: %d %q", font.Code, font.Header().Get("Cache-Control"))
	}
	script := httptest.NewRecorder()
	mux.ServeHTTP(script, httptest.NewRequest(http.MethodGet, "/console/main.dart.js", nil))
	if script.Header().Get("Cache-Control") != "no-cache" {
		t.Fatalf("script cache: %q", script.Header().Get("Cache-Control"))
	}
	for _, path := range []string{"/console/desktop.html?surface=agent", "/console/mobile.html?surface=platform"} {
		legacy := httptest.NewRecorder()
		mux.ServeHTTP(legacy, httptest.NewRequest(http.MethodGet, path, nil))
		if legacy.Code != http.StatusPermanentRedirect || !strings.HasPrefix(legacy.Header().Get("Location"), "/console/?") {
			t.Fatalf("legacy shell %s: %d %q", path, legacy.Code, legacy.Header().Get("Location"))
		}
	}
}

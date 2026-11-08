package server

import (
	"github.com/tongyu/tongyu/internal/config"
	"testing"
)

func TestFontUploadMimeFallbackAndWhitelist(t *testing.T) {
	a := &API{cfg: config.Config{Upload: config.Upload{AllowedTypes: []string{"font/woff2", "audio/webm"}}}}
	for _, mime := range []string{"font/woff2", "application/octet-stream"} {
		if !a.allowedUploadType(mime, "Poppins-Bold.woff2") {
			t.Fatalf("font rejected: %s", mime)
		}
	}
	if !a.allowedUploadType("audio/webm;codecs=opus", "语音.webm") {
		t.Fatal("recording MIME rejected")
	}
	if !a.allowedUploadType("application/x-msdownload", "tool.exe") {
		t.Fatal("executable rejected")
	}
	if !a.allowedUploadType("application/octet-stream", "payload.exe") {
		t.Fatal("unnamed binary rejected")
	}
	if a.allowedUploadType("  ", "payload.exe") {
		t.Fatal("empty type accepted")
	}
	if a.allowedUploadType("application/pdf", "  ") {
		t.Fatal("empty name accepted")
	}
}

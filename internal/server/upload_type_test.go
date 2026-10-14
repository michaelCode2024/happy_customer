package server

import (
	"github.com/relaydesk/relaydesk/internal/config"
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
	if a.allowedUploadType("application/octet-stream", "payload.exe") {
		t.Fatal("arbitrary executable accepted")
	}
	a.cfg.Upload.AllowedTypes = []string{"image/png"}
	if a.allowedUploadType("application/octet-stream", "Poppins-Bold.woff2") {
		t.Fatal("explicit whitelist ignored")
	}
}

package config

import (
	"strings"
	"testing"
)

func TestDefaultUploadsSupportBrowserRecording(t *testing.T) {
	t.Setenv("WIDGET_TOKEN_SECRET", strings.Repeat("x", 32))
	t.Setenv("UPLOAD_ALLOWED_TYPES", "")
	cfg, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	for _, required := range []string{"audio/webm", "audio/mp4", "audio/ogg", "video/mp4", "video/webm"} {
		found := false
		for _, allowed := range cfg.Upload.AllowedTypes {
			if allowed == required {
				found = true
			}
		}
		if !found {
			t.Errorf("browser media format missing: %s", required)
		}
	}
	// 部署者仍可显式限制类型，默认能力不能覆盖企业的白名单。
	t.Setenv("UPLOAD_ALLOWED_TYPES", "image/png")
	cfg, err = Load()
	if err != nil {
		t.Fatal(err)
	}
	if len(cfg.Upload.AllowedTypes) != 1 || cfg.Upload.AllowedTypes[0] != "image/png" {
		t.Fatal("explicit whitelist was overwritten")
	}
}

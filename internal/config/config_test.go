package config

import "testing"

func TestEmbeddingProviderExplicitEmpty(t *testing.T) {
	t.Setenv("AI_PROVIDER", "compatible")
	t.Setenv("AI_EMBEDDING_PROVIDER", "")
	cfg, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.AI.EmbeddingProvider != "" {
		t.Fatal("显式空值必须禁用向量服务")
	}
	if cfg.AI.Provider != "compatible" {
		t.Fatal("禁用向量服务不能影响聊天提供方")
	}
}

// TestDocsEnabledDefaultsOn pins the default: the documents ship inside the
// binary, so an instance that never sets the variable keeps serving them.
func TestDocsEnabledDefaultsOn(t *testing.T) {
	cfg, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if !cfg.DocsEnabled {
		t.Fatal("DOCS_ENABLED 未设置时必须默认开启")
	}
}

func TestDocsEnabledCanBeTurnedOff(t *testing.T) {
	t.Setenv("DOCS_ENABLED", "false")
	cfg, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.DocsEnabled {
		t.Fatal("DOCS_ENABLED=false 必须关闭文档站")
	}
}

func TestDocsEnabledRejectsGarbage(t *testing.T) {
	t.Setenv("DOCS_ENABLED", "yes-please")
	if _, err := Load(); err == nil {
		t.Fatal("非布尔值必须报错，而不是静默当成 true")
	}
}

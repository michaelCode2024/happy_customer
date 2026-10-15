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

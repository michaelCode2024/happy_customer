package ai

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
)

const embeddingDimension = 1536

// EmbeddingProvider speaks the OpenAI text-embedding protocol so we can
// turn a knowledge entry into a 1536-dimensional dense vector.
type EmbeddingProvider struct {
	baseURL string
	apiKey  string
	model   string
	client  *http.Client
}

// NewEmbeddingProvider creates an embedding provider. baseURL defaults to
// OpenAI when empty; apiKey and model must be non-empty for Available() to
// report true.
func NewEmbeddingProvider(baseURL, apiKey, model string) *EmbeddingProvider {
	if strings.TrimSpace(baseURL) == "" {
		baseURL = "https://api.openai.com/v1"
	}
	return &EmbeddingProvider{
		baseURL: strings.TrimSuffix(baseURL, "/"),
		apiKey:  apiKey,
		model:   model,
		client:  &http.Client{},
	}
}

// Available reports whether the provider has credentials configured.
func (p *EmbeddingProvider) Available() bool {
	return p.apiKey != "" && p.model != ""
}

// EmbedOne returns a 1536-dim vector as a JSON string for storage in PostgreSQL.
// Returns nil if the model is unavailable or the request fails.
func (p *EmbeddingProvider) EmbedOne(ctx context.Context, text string) ([]float64, error) {
	payload := map[string]any{
		"model": p.model,
		"input": text,
	}
	body, err := json.Marshal(payload)
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		p.baseURL+"/embeddings", bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+p.apiKey)
	resp, err := p.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, err
	}
	if resp.StatusCode >= 300 {
		return nil, fmt.Errorf("embedding gateway returned %d: %s", resp.StatusCode, truncate(string(raw), 300))
	}
	var out struct {
		Data []struct {
			Embedding []float64 `json:"embedding"`
		} `json:"data"`
		Error *struct {
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal(raw, &out); err != nil {
		return nil, err
	}
	if out.Error != nil {
		return nil, errors.New(out.Error.Message)
	}
	if len(out.Data) == 0 {
		return nil, errors.New("embedding model returned no data")
	}
	dims := len(out.Data[0].Embedding)
	if dims != embeddingDimension {
		return nil, fmt.Errorf("embedding dimension mismatch: expected %d, got %d", embeddingDimension, dims)
	}
	return out.Data[0].Embedding, nil
}

// VectorToJSON converts a float64 slice to JSON string for DB storage.
func VectorToJSON(v []float64) (string, error) {
	b, err := json.Marshal(v)
	if err != nil {
		return "", err
	}
	return string(b), nil
}

// JSONToVector parses a JSON string back to float64 slice.
func JSONToVector(s string) ([]float64, error) {
	var v []float64
	if err := json.Unmarshal([]byte(s), &v); err != nil {
		return nil, err
	}
	return v, nil
}

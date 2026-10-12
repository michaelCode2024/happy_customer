-- 014 Vector Search
--
-- Adds semantic search support to the knowledge base using JSONB for embedding
-- storage. Since pgvector extension is not available in the deployment environment,
-- we store embeddings as JSON float arrays and compute similarity in application code.
-- When the embedding model is unavailable the lexical path continues to work —
-- the column is nullable and the application checks for a zero-length vector before using it.

-- Note: We do NOT use 'create extension vector' because pgvector is not installed.
-- Embeddings are stored as JSONB arrays and computed in Go application code.

alter table knowledge_entry
  add column if not exists embedding jsonb,
  add column if not exists embed_updated_at timestamptz;

comment on column knowledge_entry.embedding is
  'dense embedding produced by the AI embedding model stored as JSON float array; used for semantic retrieval';

-- No index needed: embeddings are queried in application code with Go-level filtering

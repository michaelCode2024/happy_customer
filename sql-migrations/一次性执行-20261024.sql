-- TongYuDesk local leftover: rename demo tenant display 语聊 → 通语
-- Date: 2026-10-24 (Asia/Shanghai)
-- Scope: local deploy-postgres-1 only; no remote.
-- Uses PostgreSQL U& escapes to avoid client encoding issues.

BEGIN;

UPDATE tenant
SET name = replace(name, U&'\8BED\804A', U&'\901A\8BED'),
    updated_at = now()
WHERE name LIKE U&'%\8BED\804A%'
RETURNING id, name, slug;

UPDATE tenant
SET settings = replace(settings::text, U&'\8BED\804A', U&'\901A\8BED')::jsonb,
    updated_at = now()
WHERE settings::text LIKE U&'%\8BED\804A%'
RETURNING id, name, slug;

COMMIT;
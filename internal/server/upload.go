package server

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/google/uuid"

	"github.com/relaydesk/relaydesk/internal/auth"
	"github.com/relaydesk/relaydesk/internal/storage"
)

func (a *API) registerUploads(mux *http.ServeMux) {
	mux.HandleFunc("POST /api/v1/uploads", a.limit(a.uploadRate, a.upload))
	mux.HandleFunc("GET /api/v1/files/{id}", a.downloadFile)
	mux.HandleFunc("DELETE /api/v1/uploads/{id}", a.requireAgent(a.deleteUpload))
}

type uploadResponse struct {
	ID          uuid.UUID `json:"id"`
	FileName    string    `json:"fileName"`
	ContentType string    `json:"contentType"`
	SizeBytes   int64     `json:"sizeBytes"`
	URL         string    `json:"url"`
}

// upload accepts a multipart file from either a visitor (widget token) or an
// agent (agent token) and stores it privately. The file is only reachable
// through downloadFile, which re-checks tenant ownership.
func (a *API) upload(w http.ResponseWriter, r *http.Request) {
	principal, err := a.tokens.Verify(bearer(r))
	if err != nil || (principal.Kind != auth.KindWidget && principal.Kind != auth.KindAgent) {
		failCode(w, 401, "TOKEN_INVALID", "上传需要有效的访客或坐席令牌")
		return
	}
	conversationID := strings.TrimSpace(r.URL.Query().Get("conversationId"))
	if conversationID == "" {
		fail(w, 400, "缺少 conversationId")
		return
	}
	parsedConversation, err := uuid.Parse(conversationID)
	if err != nil {
		fail(w, 400, "conversationId 不合法")
		return
	}
	if !a.canUploadTo(r, principal, parsedConversation) {
		failCode(w, 404, "CONVERSATION_NOT_FOUND", "会话不存在或无权上传")
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, a.cfg.Upload.MaxBytes+1<<20)
	if err := r.ParseMultipartForm(4 << 20); err != nil {
		fail(w, 400, "上传内容过大或格式不正确")
		return
	}
	file, header, err := r.FormFile("file")
	if err != nil {
		fail(w, 400, "缺少 file 字段")
		return
	}
	defer file.Close()
	if header.Size > a.cfg.Upload.MaxBytes {
		fail(w, 413, "文件超过大小限制")
		return
	}
	contentType := header.Header.Get("Content-Type")
	if contentType == "" {
		contentType = "application/octet-stream"
	}
	if !a.allowedUploadType(contentType, header.Filename) {
		fail(w, 415, "不支持的文件类型："+contentType)
		return
	}

	attachmentID := uuid.New()
	key := storage.BuildKey(principal.TenantID.String(), parsedConversation.String(), attachmentID.String(), header.Filename)
	if err := a.store.Save(r.Context(), key, io.LimitReader(file, a.cfg.Upload.MaxBytes), contentType); err != nil {
		a.logger.Error("store upload failed", "error", err)
		fail(w, 500, "保存文件失败")
		return
	}
	_, err = a.db.Exec(r.Context(), `
		insert into attachment(id, tenant_id, conversation_id, uploader_type, uploader_id, file_name, content_type, size_bytes, storage_key)
		values($1,$2,$3,$4,$5,$6,$7,$8,$9)`,
		attachmentID, principal.TenantID, parsedConversation, principalKindToUploader(principal.Kind),
		principalActorID(principal), header.Filename, contentType, header.Size, key)
	if err != nil {
		_ = a.store.Delete(r.Context(), key)
		a.logger.Error("record attachment failed", "error", err)
		fail(w, 500, "保存附件记录失败")
		return
	}
	respond(w, 201, uploadResponse{
		ID: attachmentID, FileName: header.Filename, ContentType: contentType, SizeBytes: header.Size,
		URL: a.cfg.PublicBaseURL + a.cfg.Upload.PublicBasePath + "/" + attachmentID.String(),
	})
}

func (a *API) canUploadTo(r *http.Request, principal auth.Principal, conversationID uuid.UUID) bool {
	switch principal.Kind {
	case auth.KindWidget:
		var exists bool
		err := a.db.QueryRow(r.Context(), `select exists(select 1 from conversation
			where id=$1 and tenant_id=$2 and visitor_id=$3 and status <> 'RESOLVED')`,
			conversationID, principal.TenantID, principal.VisitorID).Scan(&exists)
		return err == nil && exists
	case auth.KindAgent:
		var allowed bool
		err := a.db.QueryRow(r.Context(), `
			select exists(select 1 from conversation c
			 where c.id=$1 and c.tenant_id=$2
			   and (exists (select 1 from agent_inbox ai where ai.inbox_id = c.inbox_id and ai.agent_id = $3)
			        or c.assignee_id = $3))`, conversationID, principal.TenantID, principal.AgentID).Scan(&allowed)
		return err == nil && allowed
	}
	return false
}

func (a *API) allowedUploadType(contentType, fileName string) bool {
	contentType = strings.ToLower(strings.TrimSpace(strings.Split(contentType, ";")[0]))
	if strings.HasPrefix(contentType, "image/") {
		switch contentType {
		case "image/png", "image/jpeg", "image/gif", "image/webp", "image/bmp":
			return true
		default:
			return false
		}
	}
	for _, allowed := range a.cfg.Upload.AllowedTypes {
		if strings.EqualFold(allowed, contentType) {
			return true
		}
	}
	return false
}

// downloadFile streams an attachment to a visitor or agent who can prove access.
// A short-lived grant is not needed because every client already holds a token.
func (a *API) downloadFile(w http.ResponseWriter, r *http.Request) {
	id, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		fail(w, 400, "附件 ID 不合法")
		return
	}
	var tenantID, conversationID uuid.UUID
	var fileName, contentType, storageKey string
	var sizeBytes int64
	err = a.db.QueryRow(r.Context(), `select tenant_id, conversation_id, file_name, content_type, size_bytes, storage_key
		from attachment where id=$1`, id).Scan(&tenantID, &conversationID, &fileName, &contentType, &sizeBytes, &storageKey)
	if err != nil {
		fail(w, 404, "附件不存在")
		return
	}
	if !a.authorizeAttachment(r, tenantID, conversationID) {
		// Same response as a missing file: do not leak that the attachment exists.
		fail(w, 404, "附件不存在")
		return
	}
	reader, storedType, err := a.store.Open(r.Context(), storageKey)
	if err != nil {
		if errors.Is(err, storage.ErrNotFound) {
			fail(w, 404, "附件不存在")
			return
		}
		a.logger.Error("open attachment failed", "error", err)
		fail(w, 500, "读取附件失败")
		return
	}
	defer reader.Close()
	if storedType != "" {
		contentType = storedType
	}
	w.Header().Set("Content-Type", contentType)
	w.Header().Set("Content-Length", itoa64(sizeBytes))
	w.Header().Set("Content-Disposition", contentDisposition(fileName))
	w.Header().Set("Cache-Control", "private, max-age=3600")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.WriteHeader(200)
	_, _ = io.Copy(w, reader)
}

func (a *API) authorizeAttachment(r *http.Request, tenantID, conversationID uuid.UUID) bool {
	// A widget token in the query string keeps plain <img src> embeds working.
	token := bearer(r)
	if token == "" {
		token = r.URL.Query().Get("token")
	}
	principal, err := a.tokens.Verify(token)
	if err != nil || principal.TenantID != tenantID {
		return false
	}
	switch principal.Kind {
	case auth.KindWidget:
		var exists bool
		err := a.db.QueryRow(r.Context(), `select exists(select 1 from conversation
			where id=$1 and visitor_id=$2)`, conversationID, principal.VisitorID).Scan(&exists)
		return err == nil && exists
	case auth.KindAgent:
		var allowed bool
		err := a.db.QueryRow(r.Context(), `
			select exists(select 1 from conversation c
			 where c.id=$1 and c.tenant_id=$2
			   and (exists (select 1 from agent_inbox ai where ai.inbox_id = c.inbox_id and ai.agent_id = $3)
			        or c.assignee_id = $3))`, conversationID, principal.TenantID, principal.AgentID).Scan(&allowed)
		return err == nil && allowed
	}
	return false
}

func (a *API) deleteUpload(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		fail(w, 400, "附件 ID 不合法")
		return
	}
	var storageKey string
	err = a.db.QueryRow(r.Context(), `delete from attachment where id=$1 and tenant_id=$2 returning storage_key`,
		id, p.TenantID).Scan(&storageKey)
	if err != nil {
		fail(w, 404, "附件不存在")
		return
	}
	_ = a.store.Delete(r.Context(), storageKey)
	respond(w, 200, map[string]any{"status": "OK"})
}

func principalKindToUploader(kind string) string {
	if kind == auth.KindAgent {
		return "AGENT"
	}
	return "VISITOR"
}

func principalActorID(p auth.Principal) any {
	if p.Kind == auth.KindAgent {
		return nullableUUID(p.AgentID)
	}
	return nullableUUID(p.VisitorID)
}

func contentDisposition(fileName string) string {
	safe := strings.Map(func(r rune) rune {
		if r == '"' || r == '\\' || r == '\n' || r == '\r' {
			return '_'
		}
		return r
	}, fileName)
	return `inline; filename="` + safe + `"`
}

func itoa64(value int64) string {
	if value == 0 {
		return "0"
	}
	digits := make([]byte, 0, 20)
	for value > 0 {
		digits = append([]byte{byte('0' + value%10)}, digits...)
		value /= 10
	}
	return string(digits)
}

// fileFingerprint is used by the admin API when de-duplicating uploads.
func fileFingerprint(contentType string, size int64) string {
	sum := sha256.Sum256([]byte(contentType + ":" + itoa64(size) + ":" + time.Now().UTC().Format("2006-01-02")))
	return hex.EncodeToString(sum[:8])
}

var (
	_ = os.Getenv
	_ = fileFingerprint
)

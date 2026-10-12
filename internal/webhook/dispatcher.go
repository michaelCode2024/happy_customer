package webhook

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Dispatcher delivers tenant webhook events with signature, retry and backoff.
// Deliveries are queued in PostgreSQL so an instance restart never loses a
// customer notification.
type Dispatcher struct {
	pool        *pgxpool.Pool
	client      *http.Client
	maxAttempts int
	logger      *slog.Logger
}

func NewDispatcher(pool *pgxpool.Pool, maxAttempts int, logger *slog.Logger) *Dispatcher {
	if maxAttempts < 1 {
		maxAttempts = 6
	}
	return &Dispatcher{
		pool:        pool,
		client:      &http.Client{Timeout: 10 * time.Second},
		maxAttempts: maxAttempts,
		logger:      logger,
	}
}

// Enqueue records one delivery per matching endpoint. It must be called inside
// (or after) the transaction that produced the event.
func (d *Dispatcher) Enqueue(ctx context.Context, tenantID uuid.UUID, eventType string, payload any) error {
	body, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	// The event name is sent as two separate parameters on purpose. Reusing one
	// placeholder both for the varchar(60) event_type column and for the
	// `= any(e.events)` membership test makes PostgreSQL try to deduce two
	// different types for it and reject the statement with SQLSTATE 42P08.
	// The id is generated per row by the database: the select matches one row per
	// subscribed endpoint, so a single parameterised id would collide with itself
	// as soon as a tenant has two endpoints on the same event. The event name is
	// also bound twice on purpose; reusing one placeholder for both the varchar
	// event_type column and the `= any(...)` test leaves PostgreSQL with two
	// candidate types for it and it rejects the statement (SQLSTATE 42P08).
	_, err = d.pool.Exec(ctx, `
		insert into webhook_delivery(id, endpoint_id, tenant_id, event_type, payload, status, next_attempt_at)
		select gen_random_uuid(), e.id, $1, $2::varchar(60), $3, 'PENDING', now()
		  from webhook_endpoint e
		 where e.tenant_id = $1 and e.status = 'ACTIVE' and $4::text = any(e.events) and exists(select 1 from tenant t join tenant_subscription s on s.tenant_id=t.id where t.id=$1 and t.status='ACTIVE' and s.status='ACTIVE' and (s.service_starts_at is null or s.service_starts_at<=now()) and (s.service_ends_at is null or s.service_ends_at>now()) and s.plan in ('STARTER','GROWTH','ENTERPRISE'))`,
		tenantID, eventType, body, eventType)
	return err
}

// Run polls due deliveries. Multiple instances are safe: each row is claimed
// with SELECT ... FOR UPDATE SKIP LOCKED.
func (d *Dispatcher) Run(ctx context.Context) {
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if err := d.drain(ctx); err != nil && ctx.Err() == nil {
				d.logger.Warn("webhook drain failed", "error", err)
			}
		}
	}
}

type delivery struct {
	id         uuid.UUID
	endpointID uuid.UUID
	tenantID   uuid.UUID
	eventType  string
	payload    []byte
	attempts   int
	url        string
	secret     string
}

func (d *Dispatcher) drain(ctx context.Context) error {
	tx, err := d.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	rows, err := tx.Query(ctx, `
		select d.id, d.endpoint_id, d.tenant_id, d.event_type, d.payload, d.attempts, e.url, e.secret
		  from webhook_delivery d
		  join webhook_endpoint e on e.id = d.endpoint_id
		 where d.status = 'PENDING' and d.next_attempt_at <= now() and e.status='ACTIVE' and exists(select 1 from tenant t join tenant_subscription s on s.tenant_id=t.id where t.id=d.tenant_id and t.status='ACTIVE' and s.status='ACTIVE' and (s.service_starts_at is null or s.service_starts_at<=now()) and (s.service_ends_at is null or s.service_ends_at>now()) and s.plan in ('STARTER','GROWTH','ENTERPRISE'))
		 order by d.next_attempt_at
		 limit 20
		   for update of d skip locked`)
	if err != nil {
		return err
	}
	pending := make([]delivery, 0, 20)
	for rows.Next() {
		var item delivery
		if err := rows.Scan(&item.id, &item.endpointID, &item.tenantID, &item.eventType, &item.payload,
			&item.attempts, &item.url, &item.secret); err != nil {
			rows.Close()
			return err
		}
		pending = append(pending, item)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}
	if len(pending) == 0 {
		return tx.Commit(ctx)
	}
	ids := make([]uuid.UUID, 0, len(pending))
	for _, item := range pending {
		ids = append(ids, item.id)
	}
	// Push the next attempt far enough out that another instance cannot pick the
	// same row while this one is on the network.
	if _, err := tx.Exec(ctx, `update webhook_delivery set attempts = attempts + 1, next_attempt_at = now() + interval '60 seconds' where id = any($1)`, ids); err != nil {
		return err
	}
	if err := tx.Commit(ctx); err != nil {
		return err
	}
	for _, item := range pending {
		d.attempt(ctx, item)
	}
	return nil
}

func (d *Dispatcher) attempt(ctx context.Context, item delivery) {
	status, err := d.post(ctx, item)
	nextDelay := backoff(item.attempts)
	if err == nil && status >= 200 && status < 300 {
		_, _ = d.pool.Exec(ctx, `update webhook_delivery set status='SUCCEEDED', response_status=$2, delivered_at=now(), last_error=null where id=$1`, item.id, status)
		return
	}
	message := ""
	if err != nil {
		message = err.Error()
	} else {
		message = fmt.Sprintf("endpoint returned %d", status)
	}
	exhausted := item.attempts+1 >= d.maxAttempts
	if exhausted {
		_, _ = d.pool.Exec(ctx, `update webhook_delivery set status='FAILED', response_status=$2, last_error=$3 where id=$1`, item.id, status, message)
		d.logger.Warn("webhook delivery failed permanently", "endpoint", item.endpointID, "error", message)
		return
	}
	_, _ = d.pool.Exec(ctx, `update webhook_delivery set response_status=$2, last_error=$3, next_attempt_at=now() + $4::interval where id=$1`,
		item.id, status, message, fmt.Sprintf("%d seconds", int(nextDelay.Seconds())))
}

func (d *Dispatcher) post(ctx context.Context, item delivery) (int, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, item.url, bytes.NewReader(item.payload))
	if err != nil {
		return 0, err
	}
	timestamp := fmt.Sprintf("%d", time.Now().Unix())
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("X-RelayDesk-Event", item.eventType)
	request.Header.Set("X-RelayDesk-Delivery", item.id.String())
	request.Header.Set("X-RelayDesk-Timestamp", timestamp)
	request.Header.Set("X-RelayDesk-Signature", Sign(item.secret, timestamp, item.payload))
	response, err := d.client.Do(request)
	if err != nil {
		return 0, err
	}
	defer response.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 4096))
	return response.StatusCode, nil
}

// Sign is the documented signature scheme: HMAC-SHA256 over "<timestamp>.<body>".
func Sign(secret, timestamp string, body []byte) string {
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write([]byte(timestamp))
	mac.Write([]byte("."))
	mac.Write(body)
	return "sha256=" + hex.EncodeToString(mac.Sum(nil))
}

func backoff(attempt int) time.Duration {
	delays := []time.Duration{10 * time.Second, 30 * time.Second, 2 * time.Minute, 10 * time.Minute, 30 * time.Minute, time.Hour}
	if attempt < 0 {
		attempt = 0
	}
	if attempt >= len(delays) {
		return delays[len(delays)-1]
	}
	return delays[attempt]
}

// Event names are shared by the webhook docs and the Open API.
const (
	EventConversationCreated = "conversation.created"
	EventConversationUpdated = "conversation.updated"
	EventConversationClosed  = "conversation.closed"
	EventMessageCreated      = "message.created"
	EventMessageFromAgent    = "message.agent"
	// Editing and recall are separate events rather than a second
	// message.created, because a customer's integration needs to know that the
	// record it stored earlier is no longer accurate.
	EventMessageUpdated = "message.updated"
	EventMessageDeleted = "message.deleted"
	EventVisitorCreated = "visitor.created"
	EventRatingCreated  = "conversation.rated"
)

// KnownEvents is the vocabulary a tenant may subscribe to. It is exported so the
// console's endpoint editor and the documentation can offer exactly what the
// platform emits instead of a hand-maintained list that drifts.
var KnownEvents = []string{
	EventConversationCreated,
	EventConversationUpdated,
	EventConversationClosed,
	EventMessageCreated,
	EventMessageFromAgent,
	EventMessageUpdated,
	EventMessageDeleted,
	EventVisitorCreated,
	EventRatingCreated,
}

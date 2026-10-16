package realtime

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
)

// notifyChannel is the PostgreSQL LISTEN/NOTIFY channel used as the event bus.
// PostgreSQL already sits in the critical path of every message, so using it
// avoids adding Redis to the deployment while still letting several TongYu
// instances deliver to each other's connected clients.
const notifyChannel = "tongyu_events"

// maxNotifyPayload stays below PostgreSQL's 8000 byte NOTIFY limit. Larger
// events degrade to a "refetch" hint: clients then pull the real payload from
// the REST API, which is also how they recover after a reconnect.
const maxNotifyPayload = 7000

type envelope struct {
	Source   string          `json:"source"`
	Channels []string        `json:"channels"`
	Event    json.RawMessage `json:"event"`
}

type Bus struct {
	pool       *pgxpool.Pool
	hub        *Hub
	instanceID string
	logger     *slog.Logger
}

func NewBus(pool *pgxpool.Pool, hub *Hub, logger *slog.Logger) *Bus {
	return &Bus{pool: pool, hub: hub, instanceID: uuid.NewString(), logger: logger}
}

// Start listens for events published by any instance (including this one) and
// fans them out to local sockets. It blocks until ctx is cancelled.
func (b *Bus) Start(ctx context.Context) {
	for {
		if err := b.listen(ctx); err != nil && !errors.Is(err, context.Canceled) {
			b.logger.Error("event bus listener stopped, retrying", "error", err)
			select {
			case <-ctx.Done():
				return
			case <-time.After(2 * time.Second):
			}
			continue
		}
		return
	}
}

func (b *Bus) listen(ctx context.Context) error {
	conn, err := b.pool.Acquire(ctx)
	if err != nil {
		return fmt.Errorf("acquire listen connection: %w", err)
	}
	defer conn.Release()
	if _, err := conn.Exec(ctx, "listen "+notifyChannel); err != nil {
		return fmt.Errorf("listen: %w", err)
	}
	b.logger.Info("event bus listening", "channel", notifyChannel, "instance", b.instanceID)
	for {
		notification, err := conn.Conn().WaitForNotification(ctx)
		if err != nil {
			return err
		}
		var message envelope
		if json.Unmarshal([]byte(notification.Payload), &message) != nil {
			continue
		}
		if message.Source == b.instanceID {
			// Already delivered locally by Publish.
			continue
		}
		b.hub.Deliver(message.Channels, message.Event)
	}
}

// Publish delivers an event to local subscribers immediately and to every other
// instance through PostgreSQL. Call it only after the database transaction that
// produced the event has committed.
func (b *Bus) Publish(ctx context.Context, channels []string, event Event) {
	if len(channels) == 0 {
		return
	}
	payload := Encode(event)
	if len(payload) > maxNotifyPayload {
		compact := Event{Type: event.Type, TenantID: event.TenantID, ConversationID: event.ConversationID,
			Truncated: true, Meta: event.Meta}
		if compact.Meta == nil {
			compact.Meta = map[string]any{}
		}
		compact.Meta["refetch"] = true
		payload = Encode(compact)
	}
	b.hub.Deliver(channels, payload)

	// 大群的收件人列表也会超过NOTIFY限制；按完整信封大小切分，保留groupId等事件数据。
	for _, encoded := range notifyEnvelopes(b.instanceID, channels, payload) {
		if _, err := b.pool.Exec(ctx, "select pg_notify($1, $2)", notifyChannel, string(encoded)); err != nil {
			b.logger.Warn("event bus publish failed", "error", err, "type", event.Type)
		}
	}
}

func notifyEnvelopes(source string, channels []string, event json.RawMessage) [][]byte {
	var result [][]byte
	base, _ := json.Marshal(envelope{Source: source, Channels: []string{}, Event: event})
	batch := []string{}
	size := len(base)
	flush := func() {
		if len(batch) > 0 {
			raw, _ := json.Marshal(envelope{Source: source, Channels: batch, Event: event})
			result = append(result, raw)
			batch = nil
			size = len(base)
		}
	}
	for _, channel := range channels {
		encoded, _ := json.Marshal(channel)
		extra := len(encoded)
		if len(batch) > 0 {
			extra++
		}
		if size+extra > 7900 {
			flush()
			extra = len(encoded)
		}
		// Channel IDs are server generated and short; reject a malformed oversized ID.
		if size+extra > 7900 {
			continue
		}
		batch = append(batch, channel)
		size += extra
	}
	flush()
	return result
}

func (b *Bus) InstanceID() string { return b.instanceID }

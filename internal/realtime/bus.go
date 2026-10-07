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
// avoids adding Redis to the deployment while still letting several RelayDesk
// instances deliver to each other's connected clients.
const notifyChannel = "relaydesk_events"

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

	message := envelope{Source: b.instanceID, Channels: channels, Event: payload}
	encoded, err := json.Marshal(message)
	if err != nil || len(encoded) > maxNotifyPayload+2000 {
		return
	}
	// The publish must not fail the request: local clients already received it.
	if _, err := b.pool.Exec(ctx, "select pg_notify($1, $2)", notifyChannel, string(encoded)); err != nil {
		b.logger.Warn("event bus publish failed", "error", err, "type", event.Type)
	}
}

func (b *Bus) InstanceID() string { return b.instanceID }

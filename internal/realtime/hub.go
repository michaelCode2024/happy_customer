package realtime

import (
	"context"
	"encoding/json"
	"log/slog"
	"sync"
	"time"

	"github.com/coder/websocket"
)

// Hub keeps every locally connected socket and fans events out to the channels
// each socket subscribed to. Channels are opaque strings so the same hub serves
// visitor sockets ("visitor:<uuid>"), agent sockets ("agent:<uuid>") and shared
// tenant streams ("tenant:<uuid>").
type Hub struct {
	mu       sync.RWMutex
	channels map[string]map[*Subscriber]struct{}
	logger   *slog.Logger
}

func NewHub(logger *slog.Logger) *Hub {
	return &Hub{channels: make(map[string]map[*Subscriber]struct{}), logger: logger}
}

// Subscriber wraps one websocket with a bounded send queue so a slow consumer
// can never block the publisher or another connection.
type Subscriber struct {
	conn      *websocket.Conn
	send      chan []byte
	done      chan struct{}
	closeOnce sync.Once
	logger    *slog.Logger
	filter    func([]byte) []byte
}

const subscriberQueue = 64

func (h *Hub) Subscribe(conn *websocket.Conn, channels []string) *Subscriber {
	return h.SubscribeFiltered(conn, channels, nil)
}

// Filter runs at write time so queued frames cannot bypass a changed scope.
func (h *Hub) SubscribeFiltered(conn *websocket.Conn, channels []string, filter func([]byte) []byte) *Subscriber {
	s := &Subscriber{
		filter: filter,
		conn:   conn,
		send:   make(chan []byte, subscriberQueue),
		done:   make(chan struct{}),
		logger: h.logger,
	}
	h.mu.Lock()
	for _, channel := range channels {
		if h.channels[channel] == nil {
			h.channels[channel] = make(map[*Subscriber]struct{})
		}
		h.channels[channel][s] = struct{}{}
	}
	h.mu.Unlock()
	go s.writeLoop()
	return s
}

// AddChannels lets an already connected socket widen its subscription, used when
// an agent claims a conversation mid-session.
func (h *Hub) AddChannels(s *Subscriber, channels ...string) {
	if s == nil {
		return
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	for _, channel := range channels {
		if h.channels[channel] == nil {
			h.channels[channel] = make(map[*Subscriber]struct{})
		}
		h.channels[channel][s] = struct{}{}
	}
}

func (h *Hub) RemoveChannels(s *Subscriber, channels ...string) {
	if s == nil {
		return
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	for _, channel := range channels {
		delete(h.channels[channel], s)
		if len(h.channels[channel]) == 0 {
			delete(h.channels, channel)
		}
	}
}

func (h *Hub) Unsubscribe(s *Subscriber) {
	if s == nil {
		return
	}
	h.mu.Lock()
	for channel, subscribers := range h.channels {
		if _, ok := subscribers[s]; ok {
			delete(subscribers, s)
			if len(subscribers) == 0 {
				delete(h.channels, channel)
			}
		}
	}
	h.mu.Unlock()
	s.Close()
}

func (h *Hub) Deliver(channels []string, payload []byte) {
	h.mu.RLock()
	targets := make(map[*Subscriber]struct{})
	for _, channel := range channels {
		for subscriber := range h.channels[channel] {
			targets[subscriber] = struct{}{}
		}
	}
	h.mu.RUnlock()
	for subscriber := range targets {
		subscriber.Enqueue(payload)
	}
}

func (h *Hub) Count() int {
	h.mu.RLock()
	defer h.mu.RUnlock()
	seen := make(map[*Subscriber]struct{})
	for _, subscribers := range h.channels {
		for subscriber := range subscribers {
			seen[subscriber] = struct{}{}
		}
	}
	return len(seen)
}

func (s *Subscriber) Enqueue(payload []byte) {
	select {
	case <-s.done:
		return
	default:
	}
	select {
	case s.send <- payload:
	default:
		// Consumer is too slow: drop this client instead of stalling the hub.
		s.logger.Warn("realtime client too slow, closing")
		s.Close()
	}
}

func (s *Subscriber) Close() {
	s.closeOnce.Do(func() { close(s.done) })
}

func (s *Subscriber) Done() <-chan struct{} { return s.done }

func (s *Subscriber) writeLoop() {
	ping := time.NewTicker(30 * time.Second)
	defer ping.Stop()
	defer s.conn.CloseNow() //nolint:errcheck
	for {
		select {
		case <-s.done:
			_ = s.conn.Close(websocket.StatusNormalClosure, "closed")
			return
		case payload := <-s.send:
			if s.filter != nil {
				payload = s.filter(payload)
				if len(payload) == 0 {
					continue
				}
			}
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			err := s.conn.Write(ctx, websocket.MessageText, payload)
			cancel()
			if err != nil {
				s.Close()
				return
			}
		case <-ping.C:
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			err := s.conn.Ping(ctx)
			cancel()
			if err != nil {
				s.Close()
				return
			}
		}
	}
}

// Event is the wire format shared with every client (Flutter console, H5 page
// and third-party embeds).
type Event struct {
	Type           string         `json:"type"`
	TenantID       string         `json:"tenantId,omitempty"`
	ConversationID string         `json:"conversationId,omitempty"`
	Data           any            `json:"data,omitempty"`
	Truncated      bool           `json:"truncated,omitempty"`
	Meta           map[string]any `json:"meta,omitempty"`
}

func Encode(event Event) []byte {
	payload, err := json.Marshal(event)
	if err != nil {
		return []byte(`{"type":"error","data":{"message":"event encoding failed"}}`)
	}
	return payload
}

// Channel helpers keep the naming scheme in one place.
func VisitorChannel(id string) string      { return "visitor:" + id }
func AgentChannel(id string) string        { return "agent:" + id }
func TenantChannel(id string) string       { return "tenant:" + id }
func ConversationChannel(id string) string { return "conversation:" + id }

// PlatformChannel carries RelayDesk operations events (tenant created,
// suspended, plan changed). It is not tenant-scoped, so only sockets holding a
// platform principal ever subscribe to it.
const PlatformChannel = "platform:ops"

// InboxChannel is the queue-level stream an agent watches for new conversations
// in the inboxes they serve.
func InboxChannel(id string) string { return "inbox:" + id }

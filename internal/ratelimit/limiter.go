package ratelimit

import (
	"sync"
	"time"
)

// Limiter is a per-key token bucket. It protects the public widget and upload
// endpoints from abuse. Multi-instance deployments should replace it with a
// shared Redis counter; the interface stays the same.
type Limiter struct {
	mu      sync.Mutex
	buckets map[string]*bucket
	rate    float64
	burst   float64
}

type bucket struct {
	tokens   float64
	lastSeen time.Time
}

func New(requestsPerMinute, burst int) *Limiter {
	return &Limiter{
		buckets: make(map[string]*bucket),
		rate:    float64(requestsPerMinute) / 60,
		burst:   float64(burst),
	}
}

func (l *Limiter) Allow(key string) bool {
	if l == nil || l.rate <= 0 {
		return true
	}
	now := time.Now()
	l.mu.Lock()
	defer l.mu.Unlock()
	entry, ok := l.buckets[key]
	if !ok {
		l.buckets[key] = &bucket{tokens: l.burst - 1, lastSeen: now}
		l.evict(now)
		return true
	}
	entry.tokens = min(l.burst, entry.tokens+now.Sub(entry.lastSeen).Seconds()*l.rate)
	entry.lastSeen = now
	if entry.tokens < 1 {
		return false
	}
	entry.tokens--
	return true
}

func (l *Limiter) evict(now time.Time) {
	if len(l.buckets) < 10000 {
		return
	}
	for key, entry := range l.buckets {
		if now.Sub(entry.lastSeen) > 10*time.Minute {
			delete(l.buckets, key)
		}
	}
}

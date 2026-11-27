// Package ratelimit is a small token bucket. It is in-process.
package ratelimit

import (
	"sync"
	"time"
)

// Limiter is a token bucket of perMinute calls with a burst of the same size.
type Limiter struct {
	mu       sync.Mutex
	now      func() time.Time
	capacity float64
	tokens   float64
	last     time.Time
}

// New returns a limiter; now may be nil.
func New(perMinute int, now func() time.Time) *Limiter {
	if now == nil {
		now = time.Now
	}
	return &Limiter{now: now, capacity: float64(perMinute), tokens: float64(perMinute), last: now()}
}

func (l *Limiter) refill() {
	t := l.now()
	if el := t.Sub(l.last); el > 0 {
		l.tokens = min(l.capacity, l.tokens+l.capacity*float64(el)/float64(time.Minute))
	}
	l.last = t
}

// Allow takes one token if there is one.
func (l *Limiter) Allow() bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.refill()
	if l.tokens < 1 {
		return false
	}
	l.tokens--
	return true
}

// Available says whether Allow would succeed, without taking a token.
func (l *Limiter) Available() bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.refill()
	return l.tokens >= 1
}

// Refund gives one token back, for a call that took one and was then refused elsewhere.
func (l *Limiter) Refund() {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.tokens = min(l.capacity, l.tokens+1)
}

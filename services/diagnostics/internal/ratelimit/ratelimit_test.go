package ratelimit

import (
	"testing"
	"time"
)

func TestAllowAndRefill(t *testing.T) {
	now := time.Unix(1000, 0)
	l := New(3, func() time.Time { return now })
	for i := 0; i < 3; i++ {
		if !l.Allow() {
			t.Fatalf("call %d refused", i)
		}
	}
	if l.Allow() {
		t.Fatal("fourth call allowed")
	}
	now = now.Add(20 * time.Second) // one token back at 3 per minute
	if !l.Allow() {
		t.Fatal("not refilled")
	}
	if l.Allow() {
		t.Fatal("refilled too much")
	}
	now = now.Add(time.Hour)
	for i := 0; i < 3; i++ {
		if !l.Allow() {
			t.Fatalf("after a long wait call %d refused", i)
		}
	}
	if l.Allow() {
		t.Fatal("capacity exceeded")
	}
}

func TestRefund(t *testing.T) {
	l := New(1, nil)
	if !l.Allow() || l.Allow() {
		t.Fatal("setup")
	}
	l.Refund()
	if !l.Allow() {
		t.Fatal("refund did not give the token back")
	}
}

func TestAvailableDoesNotConsume(t *testing.T) {
	l := New(1, nil)
	if !l.Available() || !l.Available() {
		t.Fatal("Available consumed a token")
	}
	if !l.Allow() || l.Available() {
		t.Fatal("after Allow the bucket is empty")
	}
}

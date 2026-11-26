package bridge

import (
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"testing"
	"time"

	"github.com/openagentix/openagentix/bridges/telegram/internal/a2a"
)

var errWaking = fmt.Errorf("a2a: agent error -32004: %w", &a2a.RPCError{Code: a2a.CodeInputNotAccepted, Message: "input was not accepted"})

func TestWakeup_RetriesOnceThenReplies(t *testing.T) {
	f := newFakeTelegram(t, "["+upd(1, 42, "hello")+"]")
	agent := &stubAgent{fn: func(n int, _, text string) (string, string, error) {
		if n == 1 {
			return "", "", errWaking
		}
		return "answer", "ctx-A", nil
	}}
	b := newBridge(f, agent, NewMemoryStore())
	b.RetryOnWakeup, b.WakeupDelay = true, 5*time.Millisecond
	runUntil(t, b, func() bool { return len(f.sentMsgs()) >= 1 })
	if got := f.sentMsgs()[0].Text; got != "answer" {
		t.Fatalf("reply = %q", got)
	}
	calls := agent.snapshot()
	if len(calls) != 2 || calls[0] != calls[1] {
		t.Fatalf("calls = %+v", calls)
	}
}

func TestWakeup_StillWakingGivesWakingMessage(t *testing.T) {
	f := newFakeTelegram(t, "["+upd(1, 424242, "secret-text")+"]")
	agent := &stubAgent{fn: func(int, string, string) (string, string, error) { return "", "", errWaking }}
	b := newBridge(f, agent, NewMemoryStore())
	b.RetryOnWakeup, b.WakeupDelay = true, 5*time.Millisecond
	var buf syncBuf
	b.Log = jsonLogger(&buf, slog.LevelDebug)
	runUntil(t, b, func() bool { return len(f.sentMsgs()) >= 1 && len(turnRecords(t, &buf)) >= 1 })
	if got := f.sentMsgs()[0].Text; got != wakingMessage || !strings.Contains(got, "waking up") {
		t.Fatalf("reply = %q", got)
	}
	if n := len(agent.snapshot()); n != 2 {
		t.Fatalf("calls = %d, want 2 (one retry only)", n)
	}
	if r := turnRecords(t, &buf)[0]; r["outcome"] != "agent_waking" {
		t.Fatalf("outcome = %v", r["outcome"])
	}
	if strings.Contains(buf.String(), "424242") || strings.Contains(buf.String(), "secret-text") {
		t.Fatalf("log leaks:\n%s", buf.String())
	}
}

func TestWakeup_RetryOff(t *testing.T) {
	f := newFakeTelegram(t, "["+upd(1, 42, "hello")+"]")
	agent := &stubAgent{fn: func(int, string, string) (string, string, error) { return "", "", errWaking }}
	b := newBridge(f, agent, NewMemoryStore())
	runUntil(t, b, func() bool { return len(f.sentMsgs()) >= 1 })
	if f.sentMsgs()[0].Text != wakingMessage || len(agent.snapshot()) != 1 {
		t.Fatalf("sent=%+v calls=%d", f.sentMsgs(), len(agent.snapshot()))
	}
}

func TestWakeup_OtherErrorsAreNeverRetried(t *testing.T) {
	f := newFakeTelegram(t, "["+upd(1, 42, "hello")+"]")
	agent := &stubAgent{fn: func(int, string, string) (string, string, error) {
		return "", "", errors.New("a2a: agent returned HTTP 500")
	}}
	b := newBridge(f, agent, NewMemoryStore())
	b.RetryOnWakeup, b.WakeupDelay = true, time.Millisecond
	var buf syncBuf
	b.Log = jsonLogger(&buf, slog.LevelDebug)
	runUntil(t, b, func() bool { return len(f.sentMsgs()) >= 1 && len(turnRecords(t, &buf)) >= 1 })
	if f.sentMsgs()[0].Text != genericFailure || len(agent.snapshot()) != 1 {
		t.Fatalf("sent=%+v calls=%d", f.sentMsgs(), len(agent.snapshot()))
	}
	if turnRecords(t, &buf)[0]["outcome"] != "agent_error" {
		t.Fatal("outcome must stay agent_error")
	}
}

func TestWakeup_DelayRespectsTurnTimeout(t *testing.T) {
	f := newFakeTelegram(t, "["+upd(1, 42, "hello")+"]")
	agent := &stubAgent{fn: func(int, string, string) (string, string, error) { return "", "", errWaking }}
	b := newBridge(f, agent, NewMemoryStore())
	b.AgentTimeout = 50 * time.Millisecond
	b.RetryOnWakeup, b.WakeupDelay = true, time.Hour
	start := time.Now()
	runUntil(t, b, func() bool { return len(f.sentMsgs()) >= 1 })
	if time.Since(start) > 2*time.Second || f.sentMsgs()[0].Text != wakingMessage || len(agent.snapshot()) != 1 {
		t.Fatalf("took %v sent=%+v calls=%d", time.Since(start), f.sentMsgs(), len(agent.snapshot()))
	}
}

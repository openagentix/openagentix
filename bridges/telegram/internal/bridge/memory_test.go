package bridge

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"sync"
	"testing"
	"time"
	"unicode/utf16"
	"unicode/utf8"

	"github.com/openagentix/openagentix/bridges/telegram/internal/memory"
)

const memCanary = "CANARY-MEMORY-ROW-9042"

type fakeMemory struct {
	mu       sync.Mutex
	items    []memory.Item
	listErr  error
	delErr   error
	listed   []string // user ids
	deleted  []string
	snapshot func()
}

func (f *fakeMemory) List(_ context.Context, userID string) ([]memory.Item, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.listed = append(f.listed, userID)
	return f.items, f.listErr
}

func (f *fakeMemory) Delete(_ context.Context, userID string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.deleted = append(f.deleted, userID)
	return f.delErr
}

func (f *fakeMemory) counts() (int, int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.listed), len(f.deleted)
}

func memBridge(f *fakeTelegram, agent Agent, mem Memories, log *slog.Logger) *Bridge {
	b := newBridge(f, agent, NewMemoryStore())
	b.Memory = mem
	b.UserIDPrefix = "telegram:"
	if log != nil {
		b.Log = log
	}
	return b
}

func TestMemoriesListsThisChatsMemories(t *testing.T) {
	f := newFakeTelegram(t, "["+upd(1, 42, "/memories")+"]")
	mem := &fakeMemory{items: []memory.Item{{Content: "likes green tea"}, {Content: memCanary, ExpiresAt: time.Unix(1900000000, 0)}}}
	agent := okAgent()
	runUntil(t, memBridge(f, agent, mem, nil), func() bool { return len(f.sentMsgs()) >= 1 })
	if l, d := mem.counts(); l != 1 || d != 0 || mem.listed[0] != "telegram:42" {
		t.Fatalf("listed %v deleted %d", mem.listed, d)
	}
	if n := len(agent.snapshot()); n != 0 {
		t.Fatalf("the command reached the agent %d times", n)
	}
	got := f.sentMsgs()[0]
	if got.ChatID != 42 || !strings.Contains(got.Text, "likes green tea") || !strings.Contains(got.Text, memCanary) || !strings.Contains(got.Text, "/forget") {
		t.Fatalf("reply = %q", got.Text)
	}
}

func TestMemoriesWithNothingStored(t *testing.T) {
	f := newFakeTelegram(t, "["+upd(1, 42, "/memories")+"]")
	runUntil(t, memBridge(f, okAgent(), &fakeMemory{}, nil), func() bool { return len(f.sentMsgs()) >= 1 })
	if txt := f.sentMsgs()[0].Text; !strings.Contains(strings.ToLower(txt), "nothing") {
		t.Fatalf("reply = %q", txt)
	}
}

// The reply is bounded in count and in length, whatever is stored, and stays under what one Telegram message holds.
func TestMemoriesOutputIsBounded(t *testing.T) {
	var items []memory.Item
	for i := 0; i < 80; i++ {
		items = append(items, memory.Item{Content: fmt.Sprintf("item %d ", i) + strings.Repeat("é", 5000)})
	}
	f := newFakeTelegram(t, "["+upd(1, 42, "/memories")+"]")
	runUntil(t, memBridge(f, okAgent(), &fakeMemory{items: items}, nil), func() bool { return len(f.sentMsgs()) >= 1 })
	sent := f.sentMsgs()
	if len(sent) != 1 {
		t.Fatalf("%d messages sent, want 1", len(sent))
	}
	txt := sent[0].Text
	if n := utf8.RuneCountInString(txt); n > 3500 {
		t.Fatalf("reply has %d characters", n)
	}
	if strings.Contains(txt, "item 10 ") || !strings.Contains(txt, "item 9 ") || !strings.Contains(txt, "70 more") {
		t.Fatalf("reply does not show exactly the first 10 and the rest as a count: %.300q", txt)
	}
	if !utf8.ValidString(txt) {
		t.Fatal("reply is not valid UTF-8 (cut inside a character)")
	}
}

func TestForgetAsksForConfirmationFirst(t *testing.T) {
	f := newFakeTelegram(t, "["+upd(1, 42, "/forget")+"]", "["+upd(2, 42, "/forget now")+"]", "["+upd(3, 42, "/forget confirm please")+"]", "["+upd(4, 42, "/forget confirm telegram:999")+"]")
	mem := &fakeMemory{}
	agent := okAgent()
	runUntil(t, memBridge(f, agent, mem, nil), func() bool { return len(f.sentMsgs()) >= 4 })
	if _, d := mem.counts(); d != 0 {
		t.Fatalf("Delete was called %d times without a confirmation", d)
	}
	for _, m := range f.sentMsgs() {
		if !strings.Contains(m.Text, "/forget confirm") {
			t.Errorf("reply %q does not say how to confirm", m.Text)
		}
	}
	if n := len(agent.snapshot()); n != 0 {
		t.Fatalf("the command reached the agent %d times", n)
	}
}

func TestForgetConfirmDeletesThisChatsMemories(t *testing.T) {
	f := newFakeTelegram(t, "["+upd(1, 42, "/forget confirm")+"]")
	mem := &fakeMemory{}
	runUntil(t, memBridge(f, okAgent(), mem, nil), func() bool { return len(f.sentMsgs()) >= 1 })
	if _, d := mem.counts(); d != 1 || mem.deleted[0] != "telegram:42" {
		t.Fatalf("deleted = %v", mem.deleted)
	}
	if txt := f.sentMsgs()[0].Text; !strings.Contains(strings.ToLower(txt), "deleted") {
		t.Fatalf("reply = %q", txt)
	}
}

// The user id is the chat's, never something typed after the command.
func TestMemoryCommandsNeverTakeAUserIDFromTheText(t *testing.T) {
	f := newFakeTelegram(t, "["+upd(1, 42, "/memories telegram:999 user_id=999")+"]", "["+upd(2, 42, "/forget confirm")+"]")
	mem := &fakeMemory{}
	runUntil(t, memBridge(f, okAgent(), mem, nil), func() bool { return len(f.sentMsgs()) >= 2 })
	for _, id := range append(append([]string{}, mem.listed...), mem.deleted...) {
		if id != "telegram:42" {
			t.Fatalf("user id %q", id)
		}
	}
}

func TestMemoryCommandsFollowTheBotNameRule(t *testing.T) {
	f := newFakeTelegram(t, "["+upd(1, 42, "/memories@My_Bot")+"]", "["+upd(2, 42, "/memories@other_bot")+"]", "["+upd(3, 42, "/forget@MY_BOT confirm")+"]")
	mem := &fakeMemory{}
	agent := okAgent()
	runUntil(t, memBridge(f, agent, mem, nil), func() bool { return len(f.sentMsgs()) >= 3 })
	if l, d := mem.counts(); l != 1 || d != 1 {
		t.Fatalf("list %d delete %d, want 1 and 1 (the command for another bot is not ours)", l, d)
	}
	if c := agent.snapshot(); len(c) != 1 || c[0].Text != "/memories@other_bot" {
		t.Fatalf("agent calls %+v", c)
	}
}

// With no memory client the commands are ordinary text for the agent, as before this feature.
func TestMemoryCommandsAreOffWithoutAClient(t *testing.T) {
	f := newFakeTelegram(t, "["+upd(1, 42, "/memories")+"]", "["+upd(2, 42, "/forget confirm")+"]")
	agent := okAgent()
	b := newBridge(f, agent, NewMemoryStore())
	runUntil(t, b, func() bool { return len(f.sentMsgs()) >= 2 })
	if c := agent.snapshot(); len(c) != 2 {
		t.Fatalf("agent calls %+v", c)
	}
}

func TestMemoryCommandsRespectTheAllowlist(t *testing.T) {
	f := newFakeTelegram(t, "["+upd(1, 7, "/forget confirm")+"]", "["+upd(2, 42, "/memories")+"]")
	mem := &fakeMemory{}
	b := memBridge(f, okAgent(), mem, nil)
	b.AllowAll = false
	b.Allowed = map[int64]bool{42: true}
	runUntil(t, b, func() bool { return len(f.sentMsgs()) >= 1 })
	if _, d := mem.counts(); d != 0 {
		t.Fatalf("a chat outside the allowlist deleted memories")
	}
}

func TestMemoryCommandsNeedAUserIDPrefix(t *testing.T) {
	f := newFakeTelegram(t, "["+upd(1, 42, "/forget confirm")+"]")
	mem := &fakeMemory{}
	b := memBridge(f, okAgent(), mem, nil)
	b.UserIDPrefix = ""
	runUntil(t, b, func() bool { return len(f.sentMsgs()) >= 1 })
	if l, d := mem.counts(); l != 0 || d != 0 {
		t.Fatalf("a call was made without a user id (list %d, delete %d)", l, d)
	}
}

// A failing call gives the user a generic answer; neither the error text nor memory content nor the chat id reach the log.
func TestMemoryErrorsDoNotLeak(t *testing.T) {
	for name, tc := range map[string]struct {
		text string
		mem  *fakeMemory
	}{
		"list":   {"/memories", &fakeMemory{listErr: errors.New("boom " + memCanary), items: []memory.Item{{Content: memCanary}}}},
		"delete": {"/forget confirm", &fakeMemory{delErr: fmt.Errorf("wrapped: %w", errors.New(memCanary))}},
		"typed":  {"/memories", &fakeMemory{listErr: &memory.Error{Op: "list", HTTP: 403}, items: []memory.Item{{Content: memCanary}}}},
	} {
		buf := &syncBuf{}
		f := newFakeTelegram(t, "["+upd(1, 424242, tc.text)+"]")
		runUntil(t, memBridge(f, okAgent(), tc.mem, jsonLogger(buf, slog.LevelDebug)), func() bool { return len(f.sentMsgs()) >= 1 && len(turnRecords(t, buf)) >= 1 })
		reply := f.sentMsgs()[0].Text
		if strings.Contains(reply, memCanary) || strings.Contains(reply, "boom") || !strings.Contains(strings.ToLower(reply), "sorry") {
			t.Errorf("%s: reply %q", name, reply)
		}
		logs := buf.String()
		if strings.Contains(logs, memCanary) || strings.Contains(logs, "424242") || strings.Contains(logs, "boom") {
			t.Errorf("%s: the log carries content, an error text or the chat id:\n%s", name, logs)
		}
		var outcome any
		for _, r := range turnRecords(t, buf) {
			outcome = r["outcome"]
		}
		if outcome != "memory_error" {
			t.Errorf("%s: outcome %v", name, outcome)
		}
	}
}

// The reply is recorded by the fake before the turn line is logged and before the send returns, so the run is only
// stopped once both turn lines exist: stopping earlier cancels the second send and logs send_error instead.
// One "turn" line per command with an outcome and a count, never the memories or the chat id.
func TestMemoryCommandLogLines(t *testing.T) {
	buf := &syncBuf{}
	f := newFakeTelegram(t, "["+upd(1, 424242, "/memories")+"]", "["+upd(2, 424242, "/forget confirm")+"]")
	mem := &fakeMemory{items: []memory.Item{{Content: memCanary}, {Content: "b"}}}
	runUntil(t, memBridge(f, okAgent(), mem, jsonLogger(buf, slog.LevelDebug)), func() bool { return len(f.sentMsgs()) >= 2 && len(turnRecords(t, buf)) >= 2 })
	recs := turnRecords(t, buf)
	if len(recs) != 2 || recs[0]["outcome"] != "memories" || recs[0]["memories"] != float64(2) || recs[1]["outcome"] != "forget" {
		t.Fatalf("turn records: %v", recs)
	}
	if strings.Contains(buf.String(), memCanary) || strings.Contains(buf.String(), "424242") {
		t.Fatalf("log carries content or the chat id:\n%s", buf.String())
	}
}

// updRaw builds an update with extra message fields (chat type, forward markers).
func updRaw(id, chat int64, chatType, extra, text string) string {
	return fmt.Sprintf(`{"update_id":%d,"message":{"message_id":%d,"chat":{"id":%d,"type":%q}%s,"text":%q}}`, id, id, chat, chatType, extra, text)
}

// In a group every member shares the chat's memory scope: one member must not be able to wipe it.
func TestForgetIsRefusedOutsidePrivateChats(t *testing.T) {
	f := newFakeTelegram(t, "["+updRaw(1, -100, "group", "", "/forget confirm")+"]", "["+updRaw(2, -200, "supergroup", "", "/forget confirm")+"]")
	mem := &fakeMemory{}
	runUntil(t, memBridge(f, okAgent(), mem, nil), func() bool { return len(f.sentMsgs()) >= 2 })
	if _, d := mem.counts(); d != 0 {
		t.Fatalf("Delete was called %d times in a group chat", d)
	}
	for _, m := range f.sentMsgs() {
		if !strings.Contains(m.Text, "private chat") {
			t.Errorf("reply %q does not explain the private-chat rule", m.Text)
		}
	}
}

// A forwarded message whose text is a command is not the user's own command.
func TestForwardedMemoryCommandsAreIgnored(t *testing.T) {
	f := newFakeTelegram(t,
		"["+updRaw(1, 42, "private", `,"forward_origin":{"type":"user"}`, "/forget confirm")+"]",
		"["+updRaw(2, 42, "private", `,"forward_date":1700000000`, "/memories")+"]",
		"["+updRaw(3, 42, "private", "", "/memories")+"]")
	mem := &fakeMemory{}
	runUntil(t, memBridge(f, okAgent(), mem, nil), func() bool { l, _ := mem.counts(); return l >= 1 && len(f.sentMsgs()) >= 3 })
	if l, d := mem.counts(); l != 1 || d != 0 {
		t.Fatalf("list=%d delete=%d, want only the one direct /memories", l, d)
	}
}

func TestMemoriesWordingInGroups(t *testing.T) {
	f := newFakeTelegram(t, "["+updRaw(1, -100, "group", "", "/memories")+"]")
	mem := &fakeMemory{items: []memory.Item{{Content: "x"}}}
	runUntil(t, memBridge(f, okAgent(), mem, nil), func() bool { return len(f.sentMsgs()) >= 1 })
	if txt := f.sentMsgs()[0].Text; strings.Contains(txt, "about you") || !strings.Contains(txt, "in this chat") {
		t.Fatalf("group reply = %q", txt)
	}
}

// Telegram counts the 4096 limit in UTF-16 code units; an emoji is two.
func TestMemoriesReplyFitsTelegramInUTF16(t *testing.T) {
	var items []memory.Item
	for i := 0; i < 30; i++ {
		items = append(items, memory.Item{Content: strings.Repeat("\U0001F600", 400)})
	}
	got := formatMemories(items, false)
	if n := len(utf16.Encode([]rune(got))); n > 4000 {
		t.Fatalf("reply is %d UTF-16 units", n)
	}
	if !strings.Contains(got, "/forget") {
		t.Fatalf("the closing line is missing")
	}
}

package telegram

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
	"unicode/utf16"
	"unicode/utf8"
)

type call struct {
	path string
	body map[string]any
}

type fakeTG struct {
	mu    sync.Mutex
	calls []call
	reply func(path string) (int, string)
	srv   *httptest.Server
}

func newFakeTG(t *testing.T, reply func(path string) (int, string)) *fakeTG {
	t.Helper()
	f := &fakeTG{reply: reply}
	f.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)
		f.mu.Lock()
		f.calls = append(f.calls, call{r.URL.Path, body})
		f.mu.Unlock()
		code, resp := f.reply(r.URL.Path)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(code)
		_, _ = w.Write([]byte(resp))
	}))
	t.Cleanup(f.srv.Close)
	return f
}

func (f *fakeTG) snapshot() []call {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]call(nil), f.calls...)
}

func TestGetUpdates_ParsesAndSendsOffset(t *testing.T) {
	f := newFakeTG(t, func(string) (int, string) {
		return 200, `{"ok":true,"result":[
			{"update_id":10,"message":{"message_id":1,"chat":{"id":42},"text":"hello"}},
			{"update_id":11,"message":{"message_id":2,"chat":{"id":42},"photo":[{}]}}]}`
	})
	c := NewClient(f.srv.URL, "TOKEN123", f.srv.Client())

	ups, err := c.GetUpdates(context.Background(), 10, 30)
	if err != nil {
		t.Fatal(err)
	}
	if len(ups) != 2 || ups[0].UpdateID != 10 || ups[0].Message.Chat.ID != 42 || ups[0].Message.Text != "hello" {
		t.Fatalf("ups = %+v", ups)
	}
	if ups[1].Message.Text != "" {
		t.Fatalf("non-text update should have empty text")
	}
	calls := f.snapshot()
	if calls[0].path != "/botTOKEN123/getUpdates" {
		t.Fatalf("path = %q", calls[0].path)
	}
	if calls[0].body["offset"] != float64(10) || calls[0].body["timeout"] != float64(30) {
		t.Fatalf("body = %v", calls[0].body)
	}
}

var _ = strings.Contains

func TestGetUpdates_APIErrorNotOK(t *testing.T) {
	f := newFakeTG(t, func(string) (int, string) {
		return 409, `{"ok":false,"error_code":409,"description":"Conflict: terminated by other getUpdates request"}`
	})
	_, err := NewClient(f.srv.URL, "TOKEN123", f.srv.Client()).GetUpdates(context.Background(), 0, 1)
	if err == nil || !strings.Contains(err.Error(), "Conflict") {
		t.Fatalf("err = %v", err)
	}
}

func TestErrors_NeverContainToken_Transport(t *testing.T) {
	f := newFakeTG(t, func(string) (int, string) { return 200, `{"ok":true,"result":[]}` })
	url := f.srv.URL
	hc := f.srv.Client()
	f.srv.Close() // connection refused; net/http error embeds the full URL with the token
	c := NewClient(url, "TOKEN123", hc)

	_, err := c.GetUpdates(context.Background(), 0, 1)
	if err == nil {
		t.Fatal("expected error")
	}
	if strings.Contains(err.Error(), "TOKEN123") {
		t.Fatalf("token leaked: %v", err)
	}
}

func TestErrors_NeverContainToken_BadBody(t *testing.T) {
	f := newFakeTG(t, func(string) (int, string) { return 502, `<html>bad gateway</html>` })
	_, err := NewClient(f.srv.URL, "TOKEN123", f.srv.Client()).GetUpdates(context.Background(), 0, 1)
	if err == nil || strings.Contains(err.Error(), "TOKEN123") {
		t.Fatalf("err = %v", err)
	}
}

func TestGetUpdates_CancelledContextIsDetectable(t *testing.T) {
	f := newFakeTG(t, func(string) (int, string) { return 200, `{"ok":true,"result":[]}` })
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err := NewClient(f.srv.URL, "TOKEN123", f.srv.Client()).GetUpdates(ctx, 0, 1)
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("err = %v, want context.Canceled", err)
	}
	if strings.Contains(err.Error(), "TOKEN123") {
		t.Fatal("token leaked")
	}
}

func TestSendMessage_Short(t *testing.T) {
	f := newFakeTG(t, func(string) (int, string) { return 200, `{"ok":true,"result":{"message_id":5}}` })
	if err := NewClient(f.srv.URL, "T", f.srv.Client()).SendMessage(context.Background(), 42, "hi"); err != nil {
		t.Fatal(err)
	}
	calls := f.snapshot()
	if len(calls) != 1 || calls[0].path != "/botT/sendMessage" || calls[0].body["chat_id"] != float64(42) || calls[0].body["text"] != "hi" {
		t.Fatalf("calls = %+v", calls)
	}
}

func TestSendMessage_LinkPreviewsOff(t *testing.T) {
	f := newFakeTG(t, func(string) (int, string) { return 200, `{"ok":true,"result":{"message_id":5}}` })
	long := strings.Repeat("a", 4096) + "b"
	if err := NewClient(f.srv.URL, "T", f.srv.Client()).SendMessage(context.Background(), 1, long); err != nil {
		t.Fatal(err)
	}
	calls := f.snapshot()
	if len(calls) != 2 {
		t.Fatalf("got %d calls, want 2", len(calls))
	}
	for i, c := range calls {
		opts, _ := c.body["link_preview_options"].(map[string]any)
		if opts["is_disabled"] != true {
			t.Fatalf("call %d: link_preview_options = %v, want is_disabled true", i, c.body["link_preview_options"])
		}
	}
}

func TestSendMessage_SplitsLongText(t *testing.T) {
	f := newFakeTG(t, func(string) (int, string) { return 200, `{"ok":true,"result":{"message_id":5}}` })
	long := strings.Repeat("a", 4096) + strings.Repeat("b", 4096) + "c"
	if err := NewClient(f.srv.URL, "T", f.srv.Client()).SendMessage(context.Background(), 1, long); err != nil {
		t.Fatal(err)
	}
	calls := f.snapshot()
	if len(calls) != 3 {
		t.Fatalf("got %d calls, want 3", len(calls))
	}
	var joined string
	for _, c := range calls {
		txt := c.body["text"].(string)
		if n := len([]rune(txt)); n > 4096 {
			t.Fatalf("chunk of %d runes", n)
		}
		joined += txt
	}
	if joined != long {
		t.Fatal("chunks do not reassemble to original")
	}
}

func TestSendMessage_ErrorDoesNotLeakToken(t *testing.T) {
	f := newFakeTG(t, func(string) (int, string) { return 200, `{"ok":true,"result":{}}` })
	url, hc := f.srv.URL, f.srv.Client()
	f.srv.Close()
	err := NewClient(url, "TOKEN123", hc).SendMessage(context.Background(), 1, "x")
	if err == nil || strings.Contains(err.Error(), "TOKEN123") {
		t.Fatalf("err = %v", err)
	}
}

func TestSendTyping(t *testing.T) {
	f := newFakeTG(t, func(string) (int, string) { return 200, `{"ok":true,"result":true}` })
	if err := NewClient(f.srv.URL, "T", f.srv.Client()).SendTyping(context.Background(), 7); err != nil {
		t.Fatal(err)
	}
	c := f.snapshot()[0]
	if c.path != "/botT/sendChatAction" || c.body["chat_id"] != float64(7) || c.body["action"] != "typing" {
		t.Fatalf("call = %+v", c)
	}
}

func hangingTG(t *testing.T) *fakeTG {
	t.Helper()
	release := make(chan struct{})
	f := newFakeTG(t, func(string) (int, string) { <-release; return 200, `{"ok":true,"result":[]}` })
	t.Cleanup(func() { close(release) })
	return f
}

func TestSendMessage_HasPerCallTimeout(t *testing.T) {
	f := hangingTG(t)
	c := NewClient(f.srv.URL, "T", f.srv.Client())
	c.SendTimeout = 50 * time.Millisecond
	ctx, cancel := context.WithTimeout(context.Background(), time.Second) // test safety net
	defer cancel()
	start := time.Now()
	err := c.SendMessage(ctx, 1, "hi")
	if err == nil || time.Since(start) > 500*time.Millisecond {
		t.Fatalf("stalled send must time out: err=%v after %v", err, time.Since(start))
	}
}

func TestGetUpdates_HasPerCallTimeoutOfPollPlusGrace(t *testing.T) {
	f := hangingTG(t)
	c := NewClient(f.srv.URL, "T", f.srv.Client())
	c.PollGrace = 50 * time.Millisecond
	ctx, cancel := context.WithTimeout(context.Background(), time.Second) // test safety net
	defer cancel()
	start := time.Now()
	_, err := c.GetUpdates(ctx, 0, 0)
	if err == nil || time.Since(start) > 500*time.Millisecond {
		t.Fatalf("stalled poll must time out: err=%v after %v", err, time.Since(start))
	}
}

func TestCall_OversizedBodyIsError(t *testing.T) {
	big := `{"ok":true,"result":[{"update_id":1,"message":{"message_id":1,"chat":{"id":1},"text":"` + strings.Repeat("a", 5<<20) + `"}}]}`
	f := newFakeTG(t, func(string) (int, string) { return 200, big })
	ups, err := NewClient(f.srv.URL, "T", f.srv.Client()).GetUpdates(context.Background(), 0, 0)
	if err == nil || len(ups) != 0 || !strings.Contains(err.Error(), "too large") {
		t.Fatalf("ups=%d err=%v", len(ups), err)
	}
}

func sentTexts(f *fakeTG) []string {
	var out []string
	for _, c := range f.snapshot() {
		out = append(out, c.body["text"].(string))
	}
	return out
}

func utf16Len(s string) int { return len(utf16.Encode([]rune(s))) }

func TestSendMessage_CountsUTF16UnitsAndNeverSplitsEmoji(t *testing.T) {
	f := newFakeTG(t, func(string) (int, string) { return 200, `{"ok":true,"result":{}}` })
	text := strings.Repeat("😀", 3000) // 6000 UTF-16 units, 3000 runes
	if err := NewClient(f.srv.URL, "T", f.srv.Client()).SendMessage(context.Background(), 1, text); err != nil {
		t.Fatal(err)
	}
	got := sentTexts(f)
	if len(got) != 2 {
		t.Fatalf("chunks = %d, want 2", len(got))
	}
	for _, g := range got {
		if utf16Len(g) > 4096 || !utf8.ValidString(g) || strings.ContainsRune(g, utf8.RuneError) {
			t.Fatalf("bad chunk: %d units, valid=%v", utf16Len(g), utf8.ValidString(g))
		}
	}
	if strings.Join(got, "") != text {
		t.Fatal("chunks do not reassemble")
	}
}

func TestSendMessage_LongMultiByteText(t *testing.T) {
	f := newFakeTG(t, func(string) (int, string) { return 200, `{"ok":true,"result":{}}` })
	text := strings.Repeat("日本語é", 2500) // 10000 BMP runes
	if err := NewClient(f.srv.URL, "T", f.srv.Client()).SendMessage(context.Background(), 1, text); err != nil {
		t.Fatal(err)
	}
	got := sentTexts(f)
	for _, g := range got {
		if utf16Len(g) > 4096 {
			t.Fatalf("chunk of %d units", utf16Len(g))
		}
	}
	if strings.Join(got, "") != text || len(got) != 3 {
		t.Fatalf("chunks=%d reassemble=%v", len(got), strings.Join(got, "") == text)
	}
}

func TestSendMessage_PrefersNewlineThenSpace(t *testing.T) {
	f := newFakeTG(t, func(string) (int, string) { return 200, `{"ok":true,"result":{}}` })
	line := strings.Repeat("x", 99) + "\n"
	text := strings.Repeat(line, 50) // 5000 units
	if err := NewClient(f.srv.URL, "T", f.srv.Client()).SendMessage(context.Background(), 1, text); err != nil {
		t.Fatal(err)
	}
	got := sentTexts(f)
	if len(got) != 2 || !strings.HasSuffix(got[0], strings.Repeat("x", 99)) {
		t.Fatalf("first chunk must end at a line boundary: %d chunks, tail %q", len(got), got[0][len(got[0])-5:])
	}
	if strings.Join(got, "\n") != text {
		t.Fatalf("content lost")
	}

	f2 := newFakeTG(t, func(string) (int, string) { return 200, `{"ok":true,"result":{}}` })
	words := strings.Repeat("word ", 1000) // 5000 units, no newline
	if err := NewClient(f2.srv.URL, "T", f2.srv.Client()).SendMessage(context.Background(), 1, words); err != nil {
		t.Fatal(err)
	}
	for _, g := range sentTexts(f2) {
		if strings.HasPrefix(g, "ord") || strings.HasSuffix(g, "wor") || strings.HasSuffix(g, "wo") {
			t.Fatalf("split inside a word: %q", g[len(g)-6:])
		}
	}
}

func TestSendMessage_SkipsWhitespaceOnlyChunks(t *testing.T) {
	f := newFakeTG(t, func(string) (int, string) { return 200, `{"ok":true,"result":{}}` })
	text := strings.Repeat("a", 4096) + "  \n \n "
	if err := NewClient(f.srv.URL, "T", f.srv.Client()).SendMessage(context.Background(), 1, text); err != nil {
		t.Fatal(err)
	}
	if got := sentTexts(f); len(got) != 1 {
		t.Fatalf("chunks = %q", got)
	}
}

const tooMany = `{"ok":false,"error_code":429,"description":"Too Many Requests: retry after 2","parameters":{"retry_after":2}}`

func retryClient(f *fakeTG) (*Client, *[]time.Duration) {
	var slept []time.Duration
	c := NewClient(f.srv.URL, "TOKEN123", f.srv.Client())
	c.RetrySleep = func(_ context.Context, d time.Duration) error { slept = append(slept, d); return nil }
	return c, &slept
}

func TestSendMessage_HonoursRetryAfterOn429(t *testing.T) {
	n := 0
	f := newFakeTG(t, func(string) (int, string) {
		n++
		if n <= 2 {
			return 429, tooMany
		}
		return 200, `{"ok":true,"result":{}}`
	})
	c, slept := retryClient(f)
	if err := c.SendMessage(context.Background(), 1, "hi"); err != nil {
		t.Fatal(err)
	}
	if len(f.snapshot()) != 3 || len(*slept) != 2 || (*slept)[0] != 2*time.Second {
		t.Fatalf("calls=%d slept=%v", len(f.snapshot()), *slept)
	}
}

func TestSendMessage_GivesUpAfterTwoRetries(t *testing.T) {
	f := newFakeTG(t, func(string) (int, string) { return 429, tooMany })
	c, _ := retryClient(f)
	err := c.SendMessage(context.Background(), 1, "hi")
	var apiErr *APIError
	if !errors.As(err, &apiErr) || apiErr.Status != 429 || len(f.snapshot()) != 3 {
		t.Fatalf("err=%v calls=%d", err, len(f.snapshot()))
	}
}

func TestSendMessage_DoesNotWaitLongerThanCap(t *testing.T) {
	f := newFakeTG(t, func(string) (int, string) {
		return 429, `{"ok":false,"error_code":429,"description":"flood","parameters":{"retry_after":3600}}`
	})
	c, slept := retryClient(f)
	if err := c.SendMessage(context.Background(), 1, "hi"); err == nil || len(f.snapshot()) != 1 || len(*slept) != 0 {
		t.Fatalf("err=%v calls=%d slept=%v", err, len(f.snapshot()), *slept)
	}
}

func TestAPIError_ExposesUnauthorized(t *testing.T) {
	f := newFakeTG(t, func(string) (int, string) {
		return 401, `{"ok":false,"error_code":401,"description":"Unauthorized"}`
	})
	_, err := NewClient(f.srv.URL, "T", f.srv.Client()).GetUpdates(context.Background(), 0, 0)
	var apiErr *APIError
	if !errors.As(err, &apiErr) || apiErr.Status != 401 {
		t.Fatalf("err = %v", err)
	}
}

func TestGetMe_ReturnsUsername(t *testing.T) {
	f := newFakeTG(t, func(string) (int, string) {
		return 200, `{"ok":true,"result":{"id":1,"is_bot":true,"username":"My_Bot"}}`
	})
	got, err := NewClient(f.srv.URL, "T", f.srv.Client()).GetMe(context.Background())
	if err != nil || got != "My_Bot" || f.snapshot()[0].path != "/botT/getMe" {
		t.Fatalf("got=%q err=%v calls=%+v", got, err, f.snapshot())
	}
}

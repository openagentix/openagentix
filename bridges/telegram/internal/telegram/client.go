// Package telegram is a minimal Telegram Bot API client (long polling).
package telegram

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/openagentix/openagentix/bridges/telegram/internal/httpx"
)

type Client struct {
	base, token string
	http        *http.Client

	RetrySleep  func(ctx context.Context, d time.Duration) error // test hook; nil sleeps for real
	SendTimeout time.Duration                                    // per sendMessage/sendChatAction call; default 15s
	PollGrace   time.Duration                                    // added to the long-poll timeout for getUpdates; default 10s
}

func NewClient(base, token string, hc *http.Client) *Client {
	return &Client{base: strings.TrimRight(base, "/"), token: token, http: hc}
}

type Chat struct {
	ID   int64  `json:"id"`
	Type string `json:"type"` // private, group, supergroup, channel
}

type Message struct {
	MessageID int64  `json:"message_id"`
	Chat      Chat   `json:"chat"`
	Text      string `json:"text"`
	// Forward markers: forward_origin (Bot API 7.0 and later) or forward_date (older). Only their presence is used.
	ForwardOrigin json.RawMessage `json:"forward_origin,omitempty"`
	ForwardDate   int64           `json:"forward_date,omitempty"`
}

// Forwarded reports whether the message was forwarded from somewhere else.
func (m *Message) Forwarded() bool { return len(m.ForwardOrigin) > 0 || m.ForwardDate != 0 }

// Shared reports whether the chat has more than one human member by kind (anything but a private chat).
func (c Chat) Shared() bool { return c.Type != "" && c.Type != "private" }

type Update struct {
	UpdateID int64    `json:"update_id"`
	Message  *Message `json:"message"`
}

func (c *Client) GetUpdates(ctx context.Context, offset int64, timeoutSec int) ([]Update, error) {
	var ups []Update
	err := c.call(ctx, "getUpdates", map[string]any{"offset": offset, "timeout": timeoutSec}, &ups,
		time.Duration(timeoutSec)*time.Second+orDefault(c.PollGrace, 10*time.Second))
	return ups, err
}

// GetMe returns the bot's own username (without the @).
func (c *Client) GetMe(ctx context.Context) (string, error) {
	var me struct {
		Username string `json:"username"`
	}
	err := c.call(ctx, "getMe", map[string]any{}, &me, orDefault(c.SendTimeout, 15*time.Second))
	return me.Username, err
}

// SendTyping shows the "typing..." indicator in a chat.
func (c *Client) SendTyping(ctx context.Context, chatID int64) error {
	var out json.RawMessage
	return c.call(ctx, "sendChatAction", map[string]any{"chat_id": chatID, "action": "typing"}, &out, orDefault(c.SendTimeout, 15*time.Second))
}

// MaxMessageUnits is Telegram's sendMessage text limit, counted in UTF-16 code units.
const MaxMessageUnits = 4096

// SendMessage sends text to a chat, splitting it to respect Telegram's limit.
func (c *Client) SendMessage(ctx context.Context, chatID int64, text string) error {
	for _, chunk := range splitMessage(text, MaxMessageUnits) {
		if err := c.sendChunk(ctx, chatID, chunk); err != nil {
			return err
		}
	}
	return nil
}

const (
	maxRetries    = 2                // retries after a 429, per chunk
	maxRetryAfter = 30 * time.Second // longer waits are not worth blocking a chat for
)

// sendChunk sends one message, waiting out Telegram's flood control (429 with
// parameters.retry_after) up to maxRetries times.
func (c *Client) sendChunk(ctx context.Context, chatID int64, chunk string) error {
	for attempt := 0; ; attempt++ {
		var out json.RawMessage
		err := c.call(ctx, "sendMessage", map[string]any{"chat_id": chatID, "text": chunk, "link_preview_options": map[string]any{"is_disabled": true}}, &out, orDefault(c.SendTimeout, 15*time.Second))
		var apiErr *APIError
		if err == nil || attempt >= maxRetries || !errors.As(err, &apiErr) || apiErr.Status != 429 {
			return err
		}
		wait := time.Duration(apiErr.RetryAfter) * time.Second
		if wait <= 0 || wait > maxRetryAfter {
			return err
		}
		sleep := c.RetrySleep
		if sleep == nil {
			sleep = sleepCtx
		}
		if serr := sleep(ctx, wait); serr != nil {
			return serr
		}
	}
}

func sleepCtx(ctx context.Context, d time.Duration) error {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-t.C:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

// splitMessage cuts text into chunks of at most limit UTF-16 code units. It
// never splits a rune (so never a surrogate pair), prefers to cut at the last
// newline, then the last space, and drops whitespace-only chunks. The
// whitespace character a chunk was cut at is consumed.
func splitMessage(text string, limit int) []string {
	var chunks []string
	add := func(s string) {
		if strings.TrimSpace(s) != "" {
			chunks = append(chunks, s)
		}
	}
	for text != "" {
		units, end := 0, 0 // end: byte offset of the longest prefix within limit
		for i, r := range text {
			w := 1
			if r >= 0x10000 {
				w = 2
			}
			if units+w > limit {
				break
			}
			units += w
			end = i + utf8.RuneLen(r)
		}
		if end == len(text) {
			add(text)
			break
		}
		cut, skip := end, 0
		if i := strings.LastIndexByte(text[:end], '\n'); i > 0 {
			cut, skip = i, 1
		} else if i := strings.LastIndexByte(text[:end], ' '); i > 0 {
			cut, skip = i, 1
		}
		add(text[:cut])
		text = text[cut+skip:]
	}
	return chunks
}

func (c *Client) call(ctx context.Context, method string, params map[string]any, result any, timeout time.Duration) error {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	body, _ := json.Marshal(params)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.base+"/bot"+c.token+"/"+method, bytes.NewReader(body))
	if err != nil {
		return c.redact(method, err)
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.http.Do(req)
	if err != nil {
		return c.redact(method, err)
	}
	defer resp.Body.Close()
	var env struct {
		OK          bool   `json:"ok"`
		Description string `json:"description"`
		Parameters  struct {
			RetryAfter int `json:"retry_after"`
		} `json:"parameters"`
		Result json.RawMessage `json:"result"`
	}
	raw, err := httpx.ReadBody(resp.Body)
	if err != nil {
		return fmt.Errorf("telegram %s: HTTP %d: %w", method, resp.StatusCode, err)
	}
	if err := json.Unmarshal(raw, &env); err != nil {
		return fmt.Errorf("telegram %s: HTTP %d: undecodable response", method, resp.StatusCode)
	}
	if !env.OK {
		return &APIError{Method: method, Status: resp.StatusCode, Description: c.scrub(env.Description), RetryAfter: env.Parameters.RetryAfter}
	}
	return json.Unmarshal(env.Result, result)
}

// redact drops the request URL (which embeds the bot token) from transport
// errors and scrubs any remaining occurrence of the token.
func (c *Client) redact(method string, err error) error {
	var ue *url.Error
	if errors.As(err, &ue) {
		err = ue.Err
	}
	if c.token != "" && strings.Contains(err.Error(), c.token) {
		return fmt.Errorf("telegram %s: %s", method, c.scrub(err.Error()))
	}
	return fmt.Errorf("telegram %s: %w", method, err)
}

func (c *Client) scrub(s string) string {
	if c.token == "" {
		return s
	}
	return strings.ReplaceAll(s, c.token, "[REDACTED]")
}

func orDefault(d, def time.Duration) time.Duration {
	if d > 0 {
		return d
	}
	return def
}

// APIError is a Bot API error response.
type APIError struct {
	Method      string
	Status      int // HTTP status
	Description string
	RetryAfter  int // seconds, from parameters.retry_after on 429
}

func (e *APIError) Error() string {
	return fmt.Sprintf("telegram %s: HTTP %d: %s", e.Method, e.Status, e.Description)
}

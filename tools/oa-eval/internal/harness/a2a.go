package harness

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
)

const maxBody = 4 << 20

// answer is what one SendMessage returned.
type answer struct {
	State   string
	Text    string
	Failure string // the message of the task status when the task did not end COMPLETED, truncated; never the user's message or an answer
}

// maxFailure is the longest failure message a report keeps.
const maxFailure = 300

// sendMessage posts one A2A 1.0 SendMessage and returns the task state and the answer text. It follows the same
// wire format as tools/a2a-call (JSON-RPC, A2A-Version 1.0, X-User-Id, optional bearer token, no redirects). That
// module keeps its client in an internal package, so the small client is repeated here.
func sendMessage(ctx context.Context, hc *http.Client, url, userID, token, prompt string) (answer, error) {
	var out answer
	id := make([]byte, 16)
	_, _ = rand.Read(id)
	body, _ := json.Marshal(map[string]any{
		"jsonrpc": "2.0", "id": "1", "method": "SendMessage",
		"params": map[string]any{"message": map[string]any{
			"messageId": hex.EncodeToString(id), "role": "ROLE_USER", "parts": []map[string]string{{"text": prompt}},
		}},
	})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return out, fmt.Errorf("bad agent URL: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("A2A-Version", "1.0")
	req.Header.Set("X-User-Id", userID)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	c := *hc
	c.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	resp, err := c.Do(req)
	if err != nil {
		if errors.Is(ctx.Err(), context.DeadlineExceeded) {
			return out, errors.New("timed out waiting for the agent")
		}
		return out, errors.New("request failed")
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return out, fmt.Errorf("HTTP %d from the gate", resp.StatusCode)
	}
	raw, err := io.ReadAll(io.LimitReader(resp.Body, maxBody+1))
	if err != nil || len(raw) > maxBody {
		return out, errors.New("response unreadable or too large")
	}
	var rpc struct {
		Error *struct {
			Code int `json:"code"`
		} `json:"error"`
		Result struct {
			Message *struct {
				Parts []struct{ Text string } `json:"parts"`
			} `json:"message"`
			Task *struct {
				Status struct {
					State   string `json:"state"`
					Message *struct {
						Parts []struct{ Text string } `json:"parts"`
					} `json:"message"`
				} `json:"status"`
				Artifacts []struct {
					Parts []struct{ Text string } `json:"parts"`
				} `json:"artifacts"`
			} `json:"task"`
		} `json:"result"`
	}
	if err := json.Unmarshal(raw, &rpc); err != nil {
		return out, errors.New("malformed response")
	}
	if rpc.Error != nil {
		return out, fmt.Errorf("JSON-RPC error %d", rpc.Error.Code)
	}
	var texts []string
	switch {
	case rpc.Result.Message != nil: // a direct answer, as a container agent may give
		out.State = "TASK_STATE_COMPLETED"
		for _, p := range rpc.Result.Message.Parts {
			texts = append(texts, p.Text)
		}
	case rpc.Result.Task != nil:
		t := rpc.Result.Task
		out.State = t.Status.State
		for _, a := range t.Artifacts {
			for _, p := range a.Parts {
				if p.Text != "" {
					texts = append(texts, p.Text)
				}
			}
		}
		if t.Status.State != "TASK_STATE_COMPLETED" && t.Status.Message != nil {
			var f []string
			for _, p := range t.Status.Message.Parts {
				f = append(f, p.Text)
			}
			out.Failure = truncate(strings.TrimSpace(strings.Join(f, " ")), maxFailure)
		}
		if len(texts) == 0 && t.Status.Message != nil {
			for _, p := range t.Status.Message.Parts {
				texts = append(texts, p.Text)
			}
		}
	default:
		return out, errors.New("response has neither a message nor a task")
	}
	out.Text = strings.Join(texts, "\n")
	return out, nil
}

// readToken returns the trimmed content of a token file, or "" when none is configured. A configured file that is
// unreadable or empty is an error, so a call is never sent without the token it was set up to carry.
func readToken(path string) (string, error) {
	if path == "" {
		return "", nil
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return "", errors.New("cannot read the token file")
	}
	t := strings.TrimSpace(string(b))
	if t == "" {
		return "", errors.New("the token file is empty")
	}
	return t, nil
}

func truncate(s string, n int) string {
	if r := []rune(s); len(r) > n {
		return string(r[:n])
	}
	return s
}

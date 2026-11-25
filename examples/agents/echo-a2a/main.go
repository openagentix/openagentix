// echo-a2a is a tiny sample "bring your own" A2A 1.0 agent: it sends the user's text to an
// OpenAI-compatible model and answers with the model's reply. A sample, not production code.
package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"time"
)

const (
	maxBody      = 1 << 20
	maxModelBody = 4 << 20
	modelTimeout = 30 * time.Second
)

type server struct {
	env    func(string) string
	client *http.Client
	log    *log.Logger
}

// newServer builds the agent. env reads configuration, client may be nil, logs receive short status lines only.
func newServer(env func(string) string, client *http.Client, logs io.Writer) *server {
	if client == nil {
		client = &http.Client{Timeout: modelTimeout}
	}
	return &server{env: env, client: client, log: log.New(logs, "echo-a2a ", log.LstdFlags)}
}

func (s *server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /.well-known/agent-card.json", s.card)
	mux.HandleFunc("POST /{$}", s.rpc)
	return mux
}

func (s *server) card(w http.ResponseWriter, r *http.Request) {
	host := r.Host
	if host == "" {
		host = "localhost:8080"
	}
	card := map[string]any{
		"name":        "echo-a2a",
		"description": "Sample agent: sends your text to the configured model and returns its answer.",
		"version":     "0.1.0",
		"supportedInterfaces": []map[string]string{
			{"url": "http://" + host + "/", "protocolBinding": "JSONRPC", "protocolVersion": "1.0"},
		},
		"capabilities":       map[string]any{"streaming": false},
		"defaultInputModes":  []string{"text/plain"},
		"defaultOutputModes": []string{"text/plain"},
		"skills": []map[string]any{{
			"id": "echo", "name": "Ask the model",
			"description": "Forwards a text message to the model and reports which model answered.",
			"tags":        []string{"sample", "echo"},
		}},
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(card)
}

type rpcRequest struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params"`
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

func writeRPC(w http.ResponseWriter, status int, id json.RawMessage, result any, e *rpcError) {
	if len(id) == 0 {
		id = json.RawMessage("null")
	}
	out := map[string]any{"jsonrpc": "2.0", "id": id}
	if e != nil {
		out["error"] = e
	} else {
		out["result"] = result
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(out)
}

func (s *server) rpc(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxBody))
	if err != nil {
		var mbe *http.MaxBytesError
		if errors.As(err, &mbe) {
			writeRPC(w, http.StatusRequestEntityTooLarge, nil, nil, &rpcError{-32600, "request body too large"})
			return
		}
		writeRPC(w, http.StatusOK, nil, nil, &rpcError{-32700, "could not read request"})
		return
	}
	var req rpcRequest
	if err := json.Unmarshal(body, &req); err != nil {
		writeRPC(w, http.StatusOK, nil, nil, &rpcError{-32700, "parse error"})
		return
	}
	switch req.Method {
	case "SendMessage":
		s.sendMessage(w, r.Context(), req)
	case "SendStreamingMessage":
		writeRPC(w, http.StatusOK, req.ID, nil, &rpcError{-32004, "streaming is not supported"})
	default:
		writeRPC(w, http.StatusOK, req.ID, nil, &rpcError{-32601, "method not found"})
	}
}

type part struct {
	Text string `json:"text"`
}

func (s *server) sendMessage(w http.ResponseWriter, ctx context.Context, req rpcRequest) {
	var p struct {
		Message struct {
			Parts []part `json:"parts"`
		} `json:"message"`
	}
	if err := json.Unmarshal(req.Params, &p); err != nil {
		writeRPC(w, http.StatusOK, req.ID, nil, &rpcError{-32602, "invalid params"})
		return
	}
	var texts []string
	for _, pt := range p.Message.Parts {
		if pt.Text != "" {
			texts = append(texts, pt.Text)
		}
	}
	if len(texts) == 0 {
		writeRPC(w, http.StatusOK, req.ID, nil, &rpcError{-32602, "message needs a text part"})
		return
	}
	for _, name := range []string{"OPENAI_BASE_URL", "OPENAI_API_KEY", "OPENAGENTIX_MODEL"} {
		if s.env(name) == "" {
			writeRPC(w, http.StatusOK, req.ID, nil, &rpcError{-32000, "missing environment variable " + name})
			return
		}
	}
	answer, model, err := s.askModel(ctx, strings.Join(texts, "\n"))
	if err != nil {
		s.log.Printf("model call failed: %v", err)
		writeRPC(w, http.StatusOK, req.ID, nil, &rpcError{-32000, "model call failed"})
		return
	}
	writeRPC(w, http.StatusOK, req.ID, map[string]any{
		"messageId": newID(),
		"role":      "ROLE_AGENT",
		"parts":     []part{{Text: fmt.Sprintf("model %s answered: %s", model, answer)}},
	}, nil)
}

// askModel returns the assistant content and the model name. Errors never carry the key or the upstream body.
func (s *server) askModel(ctx context.Context, text string) (string, string, error) {
	want := s.env("OPENAGENTIX_MODEL")
	payload, _ := json.Marshal(map[string]any{
		"model":    want,
		"messages": []map[string]string{{"role": "user", "content": text}},
	})
	url := strings.TrimRight(s.env("OPENAI_BASE_URL"), "/") + "/chat/completions"
	ctx, cancel := context.WithTimeout(ctx, modelTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(payload))
	if err != nil {
		return "", "", errors.New("bad OPENAI_BASE_URL")
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+s.env("OPENAI_API_KEY"))
	resp, err := s.client.Do(req)
	if err != nil {
		return "", "", errors.New("model request failed")
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", "", fmt.Errorf("model returned status %d", resp.StatusCode)
	}
	var out struct {
		Model   string `json:"model"`
		Choices []struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
		} `json:"choices"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, maxModelBody)).Decode(&out); err != nil || len(out.Choices) == 0 {
		return "", "", errors.New("unreadable model response")
	}
	model := out.Model
	if model == "" {
		model = want
	}
	return out.Choices[0].Message.Content, model, nil
}

func newID() string {
	b := make([]byte, 8)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

func main() {
	addr := os.Getenv("LISTEN_ADDR")
	if addr == "" {
		addr = ":8080"
	}
	s := newServer(os.Getenv, nil, os.Stderr)
	srv := &http.Server{Addr: addr, Handler: s.Handler(), ReadHeaderTimeout: 5 * time.Second}
	s.log.Printf("listening on %s", addr)
	log.Fatal(srv.ListenAndServe())
}

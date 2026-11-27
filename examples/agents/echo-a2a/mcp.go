package main

// The message "/tools" lists the tools of the agent's tool profile (ADR 0019): the platform sets OPENAGENTIX_MCP_URL and
// OPENAGENTIX_MCP_TOKEN_FILE when the AgentDefinition names a toolProfile. The token file is written and replaced by the
// kubelet, so it is read again for every call. A minimal MCP client over streamable HTTP: initialize, the initialized
// notification, tools/list. A sample, not a full client.

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"sort"
	"strings"
)

const maxMCPBody = 1 << 20

type mcpClient struct {
	url, tokenFile string
	http           *http.Client
	session        string
	nextID         int
}

func (c *mcpClient) call(ctx context.Context, method string, params any, notify bool) (json.RawMessage, error) {
	tok, err := os.ReadFile(c.tokenFile)
	if err != nil {
		return nil, errors.New("cannot read the tool token file")
	}
	msg := map[string]any{"jsonrpc": "2.0", "method": method}
	if params != nil {
		msg["params"] = params
	}
	if !notify {
		c.nextID++
		msg["id"] = c.nextID
	}
	body, _ := json.Marshal(msg)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.url, bytes.NewReader(body))
	if err != nil {
		return nil, errors.New("bad OPENAGENTIX_MCP_URL")
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json, text/event-stream")
	req.Header.Set("Authorization", "Bearer "+strings.TrimSpace(string(tok)))
	if c.session != "" {
		req.Header.Set("Mcp-Session-Id", c.session)
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return nil, errors.New("tool server request failed")
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		return nil, fmt.Errorf("tool server returned status %d", resp.StatusCode)
	}
	if s := resp.Header.Get("Mcp-Session-Id"); s != "" {
		c.session = s
	}
	if notify {
		return nil, nil
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, maxMCPBody))
	if err != nil {
		return nil, errors.New("unreadable tool server response")
	}
	if strings.HasPrefix(resp.Header.Get("Content-Type"), "text/event-stream") {
		data = lastSSEData(data)
	}
	var out struct {
		Result json.RawMessage `json:"result"`
		Error  *struct {
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal(data, &out); err != nil {
		return nil, errors.New("unreadable tool server response")
	}
	if out.Error != nil {
		return nil, fmt.Errorf("tool server error: %s", out.Error.Message)
	}
	return out.Result, nil
}

// lastSSEData returns the data of the last event of a server-sent event stream.
func lastSSEData(b []byte) []byte {
	var last, cur []byte
	sc := bufio.NewScanner(bytes.NewReader(b))
	sc.Buffer(make([]byte, 64<<10), maxMCPBody)
	for sc.Scan() {
		line := sc.Text()
		switch {
		case strings.HasPrefix(line, "data:"):
			cur = append(cur, strings.TrimSpace(strings.TrimPrefix(line, "data:"))...)
		case line == "" && len(cur) > 0:
			last, cur = cur, nil
		}
	}
	if len(cur) > 0 {
		last = cur
	}
	return last
}

// callTool answers "/call <tool>": one tools/call with empty arguments through the agent's tool profile, with its own pod-bound token. It says whether the
// call reached the tool or was refused, and never echoes the content of a result. A sample for the live checks: with empty arguments a real tool answers with its own
// argument error, which still proves that the policy of the tool server let the call through.
func (s *server) callTool(w http.ResponseWriter, ctx context.Context, req rpcRequest, name string) {
	reply := func(text string) {
		writeRPC(w, http.StatusOK, req.ID, map[string]any{"message": map[string]any{
			"messageId": newID(), "role": "ROLE_AGENT", "parts": []part{{Text: text}},
		}}, nil)
	}
	if name == "" || strings.ContainsAny(name, " \t\n") {
		reply("usage: /call <tool name>")
		return
	}
	if s.env("OPENAGENTIX_MCP_URL") == "" {
		reply("no tool profile: OPENAGENTIX_MCP_URL is not set")
		return
	}
	ctx, cancel := context.WithTimeout(ctx, modelTimeout)
	defer cancel()
	c := &mcpClient{url: s.env("OPENAGENTIX_MCP_URL"), tokenFile: s.env("OPENAGENTIX_MCP_TOKEN_FILE"), http: s.client}
	if _, err := c.call(ctx, "initialize", map[string]any{
		"protocolVersion": "2025-06-18", "capabilities": map[string]any{},
		"clientInfo": map[string]string{"name": "echo-a2a", "version": "0.1.0"},
	}, false); err != nil {
		s.log.Printf("tool call failed: %v", err)
		writeRPC(w, http.StatusOK, req.ID, nil, &rpcError{-32000, "tool call failed"})
		return
	}
	if _, err := c.call(ctx, "notifications/initialized", nil, true); err != nil {
		s.log.Printf("tool call failed: %v", err)
		writeRPC(w, http.StatusOK, req.ID, nil, &rpcError{-32000, "tool call failed"})
		return
	}
	res, err := c.call(ctx, "tools/call", map[string]any{"name": name, "arguments": map[string]any{}}, false)
	if err != nil {
		reply(fmt.Sprintf("call %s: refused: %v", name, err))
		return
	}
	var tr struct {
		IsError bool `json:"isError"`
	}
	_ = json.Unmarshal(res, &tr)
	reply(fmt.Sprintf("call %s: reached the tool (isError=%t)", name, tr.IsError))
}

// listTools returns the sorted tool names of the profile.
func (s *server) listTools(ctx context.Context) ([]string, error) {
	c := &mcpClient{url: s.env("OPENAGENTIX_MCP_URL"), tokenFile: s.env("OPENAGENTIX_MCP_TOKEN_FILE"), http: s.client}
	if _, err := c.call(ctx, "initialize", map[string]any{
		"protocolVersion": "2025-06-18", "capabilities": map[string]any{},
		"clientInfo": map[string]string{"name": "echo-a2a", "version": "0.1.0"},
	}, false); err != nil {
		return nil, err
	}
	if _, err := c.call(ctx, "notifications/initialized", nil, true); err != nil {
		return nil, err
	}
	res, err := c.call(ctx, "tools/list", map[string]any{}, false)
	if err != nil {
		return nil, err
	}
	var tl struct {
		Tools []struct {
			Name string `json:"name"`
		} `json:"tools"`
	}
	if err := json.Unmarshal(res, &tl); err != nil {
		return nil, errors.New("unreadable tool list")
	}
	var names []string
	for _, t := range tl.Tools {
		names = append(names, t.Name)
	}
	sort.Strings(names)
	return names, nil
}

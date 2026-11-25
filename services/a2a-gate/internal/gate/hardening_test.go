package gate

import (
	"io"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"
)

// slowNet answers workload requests after a delay (or never, until the request is cancelled).
type slowNet struct {
	delay time.Duration
	hold  chan struct{} // when set, every workload request waits on it (or on cancellation)
	mu    sync.Mutex
	n     int
}

func (s *slowNet) RoundTrip(r *http.Request) (*http.Response, error) {
	if !strings.HasSuffix(r.URL.Host, ".svc.cluster.local:8080") {
		return http.DefaultTransport.RoundTrip(r)
	}
	if r.Body != nil {
		_, _ = io.ReadAll(r.Body)
	}
	s.mu.Lock()
	s.n++
	s.mu.Unlock()
	var wait <-chan time.Time
	if s.hold == nil {
		wait = time.After(s.delay)
	}
	select {
	case <-r.Context().Done():
		return nil, r.Context().Err()
	case <-s.hold:
	case <-wait:
	}
	return &http.Response{StatusCode: 200, Header: http.Header{"Content-Type": {"application/json"}}, Body: io.NopCloser(strings.NewReader(`{"ok":true}`)), Request: r}, nil
}

func TestWorkloadResponseHeaderTimeout(t *testing.T) {
	sn := &slowNet{delay: 3 * time.Second}
	r, _ := routedRig(t, `{"container":["kagent/echo-go"]}`, nil, func(o *Options) { o.Transport = sn; o.WorkloadHeaderTimeout = 100 * time.Millisecond })
	start := time.Now()
	resp, _ := r.do("POST", "/agents/kagent/echo-go", tokBridge, nil, msg("c1"))
	if resp.StatusCode != 502 || time.Since(start) > 2*time.Second {
		t.Fatalf("status %d after %s, want 502 within the timeout", resp.StatusCode, time.Since(start))
	}
}

func TestWorkloadHeaderTimeoutSparesStreams(t *testing.T) {
	sn := &slowNet{delay: 400 * time.Millisecond}
	r, _ := routedRig(t, `{"container":["kagent/echo-go"]}`, nil, func(o *Options) { o.Transport = sn; o.WorkloadHeaderTimeout = 100 * time.Millisecond })
	resp, _ := r.do("POST", "/agents/kagent/echo-go/message:stream", tokBridge, nil, `{"message":{"contextId":"c1"}}`)
	if resp.StatusCode != 200 {
		t.Fatalf("http stream route: status %d", resp.StatusCode)
	}
	body := `{"jsonrpc":"2.0","id":"1","method":"SendStreamingMessage","params":{"message":{"contextId":"c1"}}}`
	resp, _ = r.do("POST", "/agents/kagent/echo-go", tokBridge, nil, body)
	if resp.StatusCode != 200 {
		t.Fatalf("json-rpc stream: status %d", resp.StatusCode)
	}
}

func TestWorkloadResponseHeadersStripped(t *testing.T) {
	fn := &fakeNet{hdr: http.Header{
		"Set-Cookie":                       {"sid=1"},
		"Access-Control-Allow-Origin":      {"*"},
		"Access-Control-Allow-Credentials": {"true"},
		"Content-Type":                     {"text/html"},
	}}
	r, _ := routedRig(t, `{"container":["kagent/echo-go"]}`, fn, nil)
	resp, _ := r.do("POST", "/agents/kagent/echo-go", tokBridge, nil, msg("c1"))
	if resp.StatusCode != 200 {
		t.Fatalf("status %d", resp.StatusCode)
	}
	for _, k := range []string{"Set-Cookie", "Access-Control-Allow-Origin", "Access-Control-Allow-Credentials"} {
		if v := resp.Header.Get(k); v != "" {
			t.Errorf("%s reached the caller: %q", k, v)
		}
	}
	if resp.Header.Get("X-Content-Type-Options") != "nosniff" {
		t.Errorf("no nosniff: %v", resp.Header)
	}
}

func TestWorkloadRequestHeaderAllowlist(t *testing.T) {
	fn := &fakeNet{}
	r, _ := routedRig(t, `{"container":["kagent/echo-go"]}`, fn, nil)
	r.do("POST", "/agents/kagent/echo-go", tokBridge, map[string]string{
		"Content-Type": "application/json", "Accept": "application/json", "A2A-Version": "1.0", "A2A-Extensions": "x",
		"Traceparent": "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01",
		"Tracestate":  "a=b", "Origin": "https://evil", "Referer": "https://evil/x", "Accept-Language": "fr", "X-Custom": "1",
		"X-Request-Id": "r1", "Te": "trailers",
	}, msg("c1"))
	got := fn.requests()
	if len(got) != 1 {
		t.Fatalf("%d requests", len(got))
	}
	allowed := map[string]bool{"Content-Type": true, "Accept": true, "A2a-Version": true, "A2a-Extensions": true, "Traceparent": true, "X-User-Id": true, "User-Agent": true, "Content-Length": true}
	for k := range got[0].Header {
		if !allowed[k] {
			t.Errorf("header %s was forwarded to the workload", k)
		}
	}
	for _, k := range []string{"Content-Type", "Accept", "A2a-Version", "A2a-Extensions", "Traceparent", "X-User-Id"} {
		if got[0].Header.Get(k) == "" {
			t.Errorf("header %s was not forwarded", k)
		}
	}
}

func TestWorkloadPerAgentInFlightCap(t *testing.T) {
	sn := &slowNet{hold: make(chan struct{})}
	r, _ := routedRig(t, `{"container":["kagent/echo-go"]}`, nil, func(o *Options) { o.Transport = sn; o.WorkloadMaxInFlight = 2; o.MaxInFlight = 10 })
	var wg sync.WaitGroup
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); r.do("POST", "/agents/kagent/echo-go", tokBridge, nil, msg("c1")) }()
	}
	waitFor(t, "two requests in the workload", func() bool { sn.mu.Lock(); defer sn.mu.Unlock(); return sn.n == 2 })
	resp, _ := r.do("POST", "/agents/kagent/echo-go", tokBridge, nil, msg("c1"))
	if resp.StatusCode != 503 || resp.Header.Get("Retry-After") == "" {
		t.Errorf("third call: status %d, want 503", resp.StatusCode)
	}
	// another agent is not affected by the full one
	resp, _ = r.do("POST", "/agents/kagent/assistant", tokBridge, nil, msg("c1"))
	if resp.StatusCode != 200 {
		t.Errorf("built-in agent while the container agent is full: %d", resp.StatusCode)
	}
	close(sn.hold)
	wg.Wait()
	resp, _ = r.do("POST", "/agents/kagent/echo-go", tokBridge, nil, msg("c1"))
	if resp.StatusCode != 200 {
		t.Errorf("after the slots are free: %d", resp.StatusCode)
	}
}

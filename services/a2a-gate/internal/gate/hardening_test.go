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
	// bodyDelay: the headers come at once and the body takes this long to arrive (a slow answer after the first byte)
	bodyDelay time.Duration
	mu        sync.Mutex
	n         int
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
	var body io.ReadCloser = io.NopCloser(strings.NewReader(`{"ok":true}`))
	if s.bodyDelay > 0 {
		body = io.NopCloser(&slowReader{d: s.bodyDelay, r: strings.NewReader(`{"ok":true}`)})
	}
	return &http.Response{StatusCode: 200, Header: http.Header{"Content-Type": {"application/json"}}, Body: body, Request: r}, nil
}

type slowReader struct {
	d    time.Duration
	r    io.Reader
	done bool
}

func (s *slowReader) Read(p []byte) (int, error) {
	if !s.done {
		time.Sleep(s.d)
		s.done = true
	}
	return s.r.Read(p)
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

func TestWorkloadHeaderTimeoutAppliesToStreamsToo(t *testing.T) {
	sn := &slowNet{delay: 3 * time.Second}
	r, _ := routedRig(t, `{"container":["kagent/echo-go"]}`, nil, func(o *Options) { o.Transport = sn; o.WorkloadHeaderTimeout = 100 * time.Millisecond })
	start := time.Now()
	resp, _ := r.do("POST", "/agents/kagent/echo-go/message:stream", tokBridge, nil, `{"message":{"contextId":"c1"}}`)
	if resp.StatusCode != 502 || time.Since(start) > 2*time.Second {
		t.Fatalf("http stream route: status %d after %s, want 502 within the timeout", resp.StatusCode, time.Since(start))
	}
	body := `{"jsonrpc":"2.0","id":"1","method":"SendStreamingMessage","params":{"message":{"contextId":"c1"}}}`
	resp, _ = r.do("POST", "/agents/kagent/echo-go", tokBridge, nil, body)
	if resp.StatusCode != 502 {
		t.Fatalf("json-rpc stream: status %d, want 502", resp.StatusCode)
	}
}

func TestWorkloadSlowBodyAfterHeadersIsNotCut(t *testing.T) {
	sn := &slowNet{bodyDelay: 400 * time.Millisecond}
	r, _ := routedRig(t, `{"container":["kagent/echo-go"]}`, nil, func(o *Options) { o.Transport = sn; o.WorkloadHeaderTimeout = 100 * time.Millisecond })
	resp, body := r.do("POST", "/agents/kagent/echo-go", tokBridge, nil, msg("c1"))
	if resp.StatusCode != 200 || body != `{"ok":true}` {
		t.Fatalf("status %d body %q", resp.StatusCode, body)
	}
}

func TestWorkloadLimitDefaults(t *testing.T) {
	h, err := New(Options{UpstreamURL: "http://x:1", Auth: nil, MaxInFlight: 128})
	if err != nil {
		t.Fatal(err)
	}
	g := h.(*handler)
	if g.o.WorkloadHeaderTimeout != 300*time.Second || g.o.WorkloadMaxInFlight != 32 || cap(g.workPool) != 64 {
		t.Fatalf("defaults: %s, %d per agent, pool %d", g.o.WorkloadHeaderTimeout, g.o.WorkloadMaxInFlight, cap(g.workPool))
	}
}

func TestWorkloadResponseHeadersAllowlist(t *testing.T) {
	fn := &fakeNet{hdr: http.Header{
		"Set-Cookie":                       {"sid=1"},
		"Access-Control-Allow-Origin":      {"*"},
		"Access-Control-Allow-Credentials": {"true"},
		"Content-Security-Policy":          {"default-src *"},
		"Link":                             {"<https://evil.example>; rel=preload"},
		"Refresh":                          {"0; url=https://evil.example"},
		"Clear-Site-Data":                  {"\"cookies\""},
		"X-Anything":                       {"1"},
		"Cache-Control":                    {"no-store"},
		"X-Accel-Buffering":                {"no"},
		"Content-Type":                     {"text/event-stream"},
	}}
	r, _ := routedRig(t, `{"container":["kagent/echo-go"]}`, fn, nil)
	resp, _ := r.do("POST", "/agents/kagent/echo-go", tokBridge, nil, msg("c1"))
	if resp.StatusCode != 200 {
		t.Fatalf("status %d", resp.StatusCode)
	}
	for _, k := range []string{"Set-Cookie", "Access-Control-Allow-Origin", "Access-Control-Allow-Credentials", "Content-Security-Policy", "Link", "Refresh", "Clear-Site-Data", "X-Anything"} {
		if v := resp.Header.Get(k); v != "" {
			t.Errorf("%s reached the caller: %q", k, v)
		}
	}
	if resp.Header.Get("X-Content-Type-Options") != "nosniff" || resp.Header.Get("Cache-Control") != "no-store" ||
		resp.Header.Get("X-Accel-Buffering") != "no" || resp.Header.Get("Content-Type") != "text/event-stream" {
		t.Errorf("allowed headers missing: %v", resp.Header)
	}
}

func TestWorkloadRedirectIsBadGateway(t *testing.T) {
	fn := &fakeNet{hdr: http.Header{"Location": {"https://evil.example/x"}}, reply: func(*http.Request) (int, string) { return 302, "" }}
	r, _ := routedRig(t, `{"container":["kagent/echo-go"]}`, fn, nil)
	resp, _ := r.do("POST", "/agents/kagent/echo-go", tokBridge, nil, msg("c1"))
	if resp.StatusCode != 502 || resp.Header.Get("Location") != "" {
		t.Fatalf("status %d, Location %q", resp.StatusCode, resp.Header.Get("Location"))
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
	allowed := map[string]bool{"Content-Type": true, "Accept": true, "A2a-Version": true, "A2a-Extensions": true, "Traceparent": true, "Tracestate": true, "X-User-Id": true, "User-Agent": true, "Content-Length": true}
	for k := range got[0].Header {
		if !allowed[k] {
			t.Errorf("header %s was forwarded to the workload", k)
		}
	}
	for _, k := range []string{"Content-Type", "Accept", "A2a-Version", "A2a-Extensions", "Traceparent", "Tracestate", "X-User-Id"} {
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

// Several container agents together cannot take more than the workload pool (half of MaxInFlight), so built-in
// agents keep their share even when every container agent is at its own cap.
func TestWorkloadPoolIsSharedByAllContainerAgents(t *testing.T) {
	sn := &slowNet{hold: make(chan struct{})}
	r, _ := routedRig(t, `{"container":["kagent/echo-go","kagent/echo-2","kagent/echo-3"]}`, nil, func(o *Options) {
		o.Transport = sn
		o.MaxInFlight = 8         // workload pool: 4
		o.WorkloadMaxInFlight = 3 // per agent
	})
	var wg sync.WaitGroup
	for _, a := range []string{"echo-go", "echo-go", "echo-2", "echo-2"} {
		wg.Add(1)
		go func() { defer wg.Done(); r.do("POST", "/agents/kagent/"+a, tokBridge, nil, msg("c1")) }()
	}
	waitFor(t, "four requests in the workload", func() bool { sn.mu.Lock(); defer sn.mu.Unlock(); return sn.n == 4 })
	resp, _ := r.do("POST", "/agents/kagent/echo-3", tokBridge, nil, msg("c1"))
	if resp.StatusCode != 503 {
		t.Errorf("third agent while the pool is full: %d, want 503", resp.StatusCode)
	}
	resp, _ = r.do("POST", "/agents/kagent/assistant", tokBridge, nil, msg("c1"))
	if resp.StatusCode != 200 {
		t.Errorf("built-in agent while the container pool is full: %d", resp.StatusCode)
	}
	close(sn.hold)
	wg.Wait()
}

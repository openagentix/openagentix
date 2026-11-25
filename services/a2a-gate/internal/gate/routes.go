package gate

// Bring your own A2A agent: the routes file, the fixed upstream template and the agent card rewrite.
//
// The controller writes {"container":["<namespace>/<name>", ...]} and nothing else. The list only chooses WHICH of the
// agents goes to the workload namespace. The host is never read from it: the gate builds
// http://<name>.<workloadNamespace>.svc.cluster.local:<port> itself, from a namespace and port fixed at start and a
// name that is an exact entry of the list (a DNS label, checked when the list is loaded).

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const (
	maxRoutesBytes   = 256 << 10
	maxRoutesEntries = 1000
	maxCardBytes     = 64 << 10
	defaultRoutePoll = 10 * time.Second
	defaultWorkPort  = 8080
)

var dnsLabel = regexp.MustCompile(`^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$`)

// RouteSet is the set of "<namespace>/<name>" agents that run as containers in the workload namespace.
type RouteSet map[string]struct{}

// Has reports whether the agent is listed.
func (s RouteSet) Has(ns, name string) bool {
	_, ok := s[ns+"/"+name]
	return ok
}

// ParseRoutes reads the routes file strictly: one object with exactly the member "container", an array of at most
// 1000 distinct "<namespace>/<name>" strings (both DNS labels), at most 256 KiB, nothing after the object. Errors never
// quote the content.
func ParseRoutes(b []byte) (RouteSet, error) {
	if len(b) > maxRoutesBytes {
		return nil, errors.New("routes file is larger than 256 KiB")
	}
	dec := json.NewDecoder(bytes.NewReader(b))
	if t, err := dec.Token(); err != nil || t != json.Delim('{') {
		return nil, errors.New("routes file is not a JSON object")
	}
	var raw json.RawMessage
	for dec.More() {
		kt, err := dec.Token()
		key, isStr := kt.(string)
		if err != nil || !isStr {
			return nil, errors.New("routes file is not valid JSON")
		}
		if key != "container" || raw != nil {
			return nil, errors.New(`routes file must have exactly one member, "container"`)
		}
		if err := dec.Decode(&raw); err != nil {
			return nil, errors.New("routes file is not valid JSON")
		}
	}
	if t, err := dec.Token(); err != nil || t != json.Delim('}') {
		return nil, errors.New("routes file is not valid JSON")
	}
	if _, err := dec.Token(); !errors.Is(err, io.EOF) {
		return nil, errors.New("routes file has data after the object")
	}
	if len(raw) == 0 || raw[0] != '[' {
		return nil, errors.New(`"container" must be an array`)
	}
	var entries []any
	if err := json.Unmarshal(raw, &entries); err != nil {
		return nil, errors.New(`"container" must be an array`)
	}
	if len(entries) > maxRoutesEntries {
		return nil, fmt.Errorf("more than %d entries", maxRoutesEntries)
	}
	set := make(RouteSet, len(entries))
	for i, e := range entries {
		s, ok := e.(string)
		ns, name, found := strings.Cut(s, "/")
		if !ok || !found || !dnsLabel.MatchString(ns) || !dnsLabel.MatchString(name) {
			return nil, fmt.Errorf("entry %d is not <namespace>/<name> of two lowercase DNS labels", i)
		}
		if _, dup := set[s]; dup {
			return nil, fmt.Errorf("entry %d is a duplicate", i)
		}
		set[s] = struct{}{}
	}
	return set, nil
}

func readRoutesFile(path string) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, errors.New("routes file cannot be read")
	}
	defer f.Close()
	b, err := io.ReadAll(io.LimitReader(f, maxRoutesBytes+1))
	if err != nil {
		return nil, errors.New("routes file cannot be read")
	}
	return b, nil
}

// reloadRoutes reads the file once. A good file replaces the set; a bad or missing one keeps the set that is there
// (empty at start) and is logged once per change.
func (h *handler) reloadRoutes(last *string) {
	b, err := readRoutesFile(h.o.RoutesFile)
	if err == nil && string(b) == *last {
		return // unchanged: nothing to do, nothing to log again
	}
	var set RouteSet
	if err == nil {
		*last = string(b)
		set, err = ParseRoutes(b)
	} else {
		*last = "\x00unreadable"
	}
	if err != nil {
		h.o.Log.Warn("routes: file unusable, keeping the last good list (a bad list never adds a route)", "err", err.Error())
		return
	}
	h.routes.Store(&set)
	h.o.Log.Info("routes: loaded", "container_agents", len(set))
}

func (h *handler) watchRoutes(ctx context.Context, last string) {
	t := time.NewTicker(h.o.RoutesPoll)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			h.reloadRoutes(&last)
		}
	}
}

// initRoutes validates the options of the feature and does the first, synchronous load.
func (h *handler) initRoutes() error {
	o := &h.o
	if o.RoutesFile == "" {
		return nil
	}
	if !dnsLabel.MatchString(o.WorkloadNamespace) {
		return errors.New("workload namespace must be a DNS label")
	}
	if o.WorkloadPort == 0 {
		o.WorkloadPort = defaultWorkPort
	}
	if o.WorkloadPort < 1 || o.WorkloadPort > 65535 {
		return errors.New("workload port must be 1..65535")
	}
	pu, err := url.Parse(o.PublicURL)
	if err != nil || (pu.Scheme != "http" && pu.Scheme != "https") || pu.Host == "" {
		return errors.New("public URL must be an http or https URL when routes are on")
	}
	o.PublicURL = strings.TrimRight(o.PublicURL, "/")
	if o.RoutesPoll <= 0 {
		o.RoutesPoll = defaultRoutePoll
	}
	empty := RouteSet{}
	h.routes.Store(&empty) // fail closed: until a good list is read, nothing is routed
	last := "\x00never"
	h.reloadRoutes(&last)
	ctx := o.Ctx
	if ctx == nil {
		ctx = context.Background()
	}
	go h.watchRoutes(ctx, last)
	return nil
}

// target is where a listed agent's request goes. It is built per request from fixed parts only.
type target struct {
	host string // <name>.<workloadNamespace>.svc.cluster.local:<port>
	path string
	card bool
	ns   string
	name string
}

const keyTarget ctxKey = 2

// workloadTarget returns the target for a listed agent, or nil when the agent is not listed (or the feature is off).
func (h *handler) workloadTarget(ns, name, route string) *target {
	rs := h.routes.Load()
	if rs == nil || !rs.Has(ns, name) {
		return nil
	}
	t := &target{ns: ns, name: name,
		host: net.JoinHostPort(name+"."+h.o.WorkloadNamespace+".svc.cluster.local", strconv.Itoa(h.o.WorkloadPort))}
	switch route {
	case routeRPC:
		t.path = "/"
	case routeCard:
		t.path, t.card = "/.well-known/agent-card.json", true
	case "SendMessage":
		t.path = "/message:send"
	case "SendStreamingMessage":
		t.path = "/message:stream"
	default:
		return nil
	}
	return t
}

var workloadResponseHeaders = map[string]bool{
	"Content-Type": true, "Content-Length": true, "Cache-Control": true, "Date": true, "X-Accel-Buffering": true,
}

// modifyResponse rewrites the agent card of a listed agent; every other response passes through untouched.
func (h *handler) modifyResponse(resp *http.Response) error {
	t, _ := resp.Request.Context().Value(keyTarget).(*target)
	if t == nil {
		return nil
	}
	// a redirect would send the caller to an address the agent chose
	if resp.StatusCode >= 300 && resp.StatusCode < 400 {
		return errors.New("container agent answered with a redirect")
	}
	// the answer of foreign code keeps only the headers a client needs; everything else (cookies, cross-origin
	// grants, policies, links) is dropped, and the type may not be sniffed
	for k := range resp.Header {
		if !workloadResponseHeaders[http.CanonicalHeaderKey(k)] {
			delete(resp.Header, k)
		}
	}
	resp.Header.Set("X-Content-Type-Options", "nosniff")
	if !t.card || resp.StatusCode != http.StatusOK {
		return nil
	}
	b, err := io.ReadAll(io.LimitReader(resp.Body, maxCardBytes+1))
	_ = resp.Body.Close()
	var out []byte
	switch {
	case err != nil:
		err = errors.New("agent card could not be read")
	case len(b) > maxCardBytes:
		err = errors.New("agent card is larger than 64 KiB")
	default:
		out, err = h.rewriteCard(b, t)
	}
	hdr := resp.Header
	hdr.Del("Content-Encoding")
	hdr.Set("Content-Type", "application/json")
	hdr.Set("X-Content-Type-Options", "nosniff")
	if err != nil {
		resp.StatusCode, resp.Status = http.StatusBadGateway, "502 Bad Gateway"
		out = []byte(`{"error":"` + err.Error() + `"}` + "\n")
	}
	resp.Body = io.NopCloser(bytes.NewReader(out))
	resp.ContentLength = int64(len(out))
	hdr.Set("Content-Length", strconv.Itoa(len(out)))
	return nil
}

// legacy and security members that name the pod's own address or an authentication the gate does not implement
var cardDrop = []string{"securitySchemes", "security", "securityRequirements", "url", "preferredTransport", "additionalInterfaces"}

func (h *handler) rewriteCard(b []byte, t *target) ([]byte, error) {
	if tb := bytes.TrimSpace(b); len(tb) == 0 || tb[0] != '{' {
		return nil, errors.New("agent card is not a JSON object")
	}
	dec := json.NewDecoder(bytes.NewReader(b))
	var card map[string]json.RawMessage
	if err := dec.Decode(&card); err != nil || card == nil {
		return nil, errors.New("agent card is not valid JSON")
	}
	if _, err := dec.Token(); !errors.Is(err, io.EOF) {
		return nil, errors.New("agent card is not valid JSON")
	}
	for _, k := range cardDrop {
		delete(card, k)
	}
	// the gate's own address for this agent; the upstream's protocolVersion is copied only when it is "1.0", which is
	// the only version the gate serves, so the value is always "1.0"
	base := h.o.PublicURL + "/agents/" + t.ns + "/" + t.name
	mk := func(binding string) map[string]string {
		return map[string]string{"url": base, "protocolBinding": binding, "protocolVersion": "1.0"}
	}
	ifs, _ := json.Marshal([]map[string]string{mk("JSONRPC"), mk("HTTP+JSON")})
	card["supportedInterfaces"] = ifs
	return json.Marshal(card)
}

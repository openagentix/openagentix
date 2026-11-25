// Package kube is a minimal Kubernetes REST client: get, list, watch, server-side apply, merge patch (also on status),
// create, update and delete, with the in-cluster ServiceAccount token and CA. Errors carry the HTTP status and the API's
// reason word only, never its message or body.
package kube

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"
)

// FieldManager is the server-side apply field manager of every write the controller applies.
const FieldManager = "openagentix-control-plane"

const requestTimeout = 30 * time.Second

// ListPageSize is the limit of every list request; a list follows the continue token until the server has no more.
var ListPageSize = 100

// MaxListItems bounds one List call: more items than this is an error, never an unbounded read.
const MaxListItems = 10000

// Object is an unstructured Kubernetes object.
type Object = map[string]any

// Resource names a kind's REST endpoint.
type Resource struct {
	Group, Version, Plural, Kind string
	Namespaced                   bool
}

func (r Resource) APIVersion() string {
	if r.Group == "" {
		return r.Version
	}
	return r.Group + "/" + r.Version
}

func (r Resource) path(ns, name, sub string) string {
	var b strings.Builder
	if r.Group == "" {
		b.WriteString("/api/" + r.Version)
	} else {
		b.WriteString("/apis/" + r.Group + "/" + r.Version)
	}
	if r.Namespaced {
		b.WriteString("/namespaces/" + url.PathEscape(ns))
	}
	b.WriteString("/" + r.Plural)
	if name != "" {
		b.WriteString("/" + url.PathEscape(name))
	}
	if sub != "" {
		b.WriteString("/" + sub)
	}
	return b.String()
}

// Error is an API failure: the status code and the reason word.
type Error struct {
	Op     string
	Code   int
	Reason string
}

func (e *Error) Error() string {
	return fmt.Sprintf("kubernetes API: %s: %d %s", e.Op, e.Code, e.Reason)
}

// ErrGone means the resourceVersion is too old: list again.
var ErrGone = errors.New("kubernetes API: resourceVersion too old (410 Gone)")

func code(err error) int {
	var e *Error
	if errors.As(err, &e) {
		return e.Code
	}
	return 0
}

func IsNotFound(err error) bool { return code(err) == http.StatusNotFound }
func IsConflict(err error) bool { return code(err) == http.StatusConflict }

// IsInvalid is a 422: the object or patch is not valid, and sending it again will not change that.
func IsInvalid(err error) bool { return code(err) == http.StatusUnprocessableEntity }

// Client talks to one API server.
type Client struct {
	base  string
	http  *http.Client
	token func() (string, error)
}

// New builds a client. token is called on every request, so a rotated token is picked up.
func New(base string, h *http.Client, token func() (string, error)) *Client {
	return &Client{base: strings.TrimRight(base, "/"), http: h, token: token}
}

// FileToken reads the token from a file on every call.
func FileToken(path string) func() (string, error) {
	return func() (string, error) {
		b, err := os.ReadFile(path)
		return strings.TrimSpace(string(b)), err
	}
}

const saDir = "/var/run/secrets/kubernetes.io/serviceaccount/"

// InCluster builds a client from the pod's ServiceAccount files and environment.
func InCluster() (*Client, error) {
	host, port := os.Getenv("KUBERNETES_SERVICE_HOST"), os.Getenv("KUBERNETES_SERVICE_PORT")
	if host == "" || port == "" {
		return nil, errors.New("not running in a cluster: KUBERNETES_SERVICE_HOST is not set")
	}
	ca, err := os.ReadFile(saDir + "ca.crt")
	if err != nil {
		return nil, fmt.Errorf("read cluster CA: %w", err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(ca) {
		return nil, errors.New("cluster CA has no certificate")
	}
	if strings.Contains(host, ":") {
		host = "[" + host + "]"
	}
	// No client timeout: a watch lives for minutes. Every other call gets a context deadline.
	h := &http.Client{Transport: &http.Transport{TLSClientConfig: &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS12}}}
	return New("https://"+host+":"+port, h, FileToken(saDir+"token")), nil
}

func (c *Client) newRequest(ctx context.Context, method, path string, q url.Values, ct string, body []byte) (*http.Request, error) {
	tok, err := c.token()
	if err != nil {
		return nil, fmt.Errorf("read service account token: %w", err)
	}
	u := c.base + path
	if len(q) > 0 {
		u += "?" + q.Encode()
	}
	req, err := http.NewRequestWithContext(ctx, method, u, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+tok)
	req.Header.Set("Accept", "application/json")
	if ct != "" {
		req.Header.Set("Content-Type", ct)
	}
	return req, nil
}

// reason reads the "reason" word of a Status body and nothing else.
func reason(b []byte) string {
	var s struct {
		Reason string `json:"reason"`
	}
	_ = json.Unmarshal(b, &s)
	if len(s.Reason) > 64 || strings.ContainsFunc(s.Reason, func(r rune) bool { return r < 'A' || (r > 'Z' && r < 'a') || r > 'z' }) {
		return ""
	}
	return s.Reason
}

func (c *Client) do(ctx context.Context, op, method, path string, q url.Values, ct string, body []byte) (Object, error) {
	ctx, cancel := context.WithTimeout(ctx, requestTimeout)
	defer cancel()
	req, err := c.newRequest(ctx, method, path, q, ct, body)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", op, err)
	}
	resp, err := c.http.Do(req)
	if err != nil {
		var ue *url.Error
		if errors.As(err, &ue) {
			err = ue.Err // drops the URL
		}
		return nil, fmt.Errorf("kubernetes API: %s: request failed: %w", op, err)
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 32<<20))
	if err != nil {
		return nil, fmt.Errorf("kubernetes API: %s: read response: %w", op, err)
	}
	if resp.StatusCode >= 300 {
		return nil, &Error{Op: op, Code: resp.StatusCode, Reason: reason(raw)}
	}
	var out Object
	if len(bytes.TrimSpace(raw)) > 0 {
		if err := json.Unmarshal(raw, &out); err != nil {
			return nil, fmt.Errorf("kubernetes API: %s: response is not JSON", op)
		}
	}
	return out, nil
}

func opName(verb string, r Resource, name string) string {
	if name == "" {
		return verb + " " + r.Plural
	}
	return verb + " " + r.Plural + "/" + name
}

// Get reads one object.
func (c *Client) Get(ctx context.Context, r Resource, ns, name string) (Object, error) {
	return c.do(ctx, opName("get", r, name), http.MethodGet, r.path(ns, name, ""), nil, "", nil)
}

// List reads a collection page by page (limit ListPageSize, following the continue token, at most MaxListItems items)
// and returns the list's resourceVersion for a watch to resume from. Each page is read with a bounded body.
func (c *Client) List(ctx context.Context, r Resource, ns, selector string) ([]Object, string, error) {
	var items []Object
	cont, rv := "", ""
	for {
		q := url.Values{}
		if selector != "" {
			q.Set("labelSelector", selector)
		}
		if ListPageSize > 0 {
			q.Set("limit", strconv.Itoa(ListPageSize))
		}
		if cont != "" {
			q.Set("continue", cont)
		}
		out, err := c.do(ctx, opName("list", r, ""), http.MethodGet, r.path(ns, "", ""), q, "", nil)
		if err != nil {
			return nil, "", err
		}
		if l, ok := out["items"].([]any); ok {
			for _, it := range l {
				if m, ok := it.(map[string]any); ok {
					items = append(items, m)
				}
			}
		}
		if len(items) > MaxListItems {
			return nil, "", fmt.Errorf("kubernetes API: list %s: more than %d items", r.Plural, MaxListItems)
		}
		md := Meta(out)
		rv = md.String("resourceVersion")
		if cont = md.String("continue"); cont == "" {
			return items, rv, nil
		}
	}
}

// Apply writes obj with server-side apply, forcing conflicts: the controller owns the fields it sends.
func (c *Client) Apply(ctx context.Context, r Resource, ns, name string, obj Object) error {
	b, err := json.Marshal(obj)
	if err != nil {
		return err
	}
	q := url.Values{"fieldManager": {FieldManager}, "force": {"true"}}
	_, err = c.do(ctx, opName("apply", r, name), http.MethodPatch, r.path(ns, name, ""), q, "application/apply-patch+yaml", b)
	return err
}

// PatchMerge sends a JSON merge patch, to the subresource when sub is not empty.
func (c *Client) PatchMerge(ctx context.Context, r Resource, ns, name, sub string, patch Object) error {
	b, err := json.Marshal(patch)
	if err != nil {
		return err
	}
	_, err = c.do(ctx, opName("patch", r, name), http.MethodPatch, r.path(ns, name, sub), nil, "application/merge-patch+json", b)
	return err
}

// Create posts an object. A 409 is reported as an error for which IsConflict is true.
func (c *Client) Create(ctx context.Context, r Resource, ns string, obj Object) (Object, error) {
	b, err := json.Marshal(obj)
	if err != nil {
		return nil, err
	}
	return c.do(ctx, opName("create", r, Meta(obj).String("name")), http.MethodPost, r.path(ns, "", ""), nil, "application/json", b)
}

// Update replaces an object (the resourceVersion in obj is the precondition).
func (c *Client) Update(ctx context.Context, r Resource, ns, name string, obj Object) (Object, error) {
	b, err := json.Marshal(obj)
	if err != nil {
		return nil, err
	}
	return c.do(ctx, opName("update", r, name), http.MethodPut, r.path(ns, name, ""), nil, "application/json", b)
}

// Delete removes an object.
func (c *Client) Delete(ctx context.Context, r Resource, ns, name string) error {
	_, err := c.do(ctx, opName("delete", r, name), http.MethodDelete, r.path(ns, name, ""), nil, "", nil)
	return err
}

// Event is one watch event.
type Event struct {
	Type   string
	Object Object
}

// ResourceVersion of the event's object.
func (e Event) ResourceVersion() string {
	return Meta(e.Object).String("resourceVersion")
}

// Stream is an open watch.
type Stream struct {
	dec  *json.Decoder
	body io.Closer
}

// Close ends the watch.
func (s *Stream) Close() { _ = s.body.Close() }

// Next blocks for the next event. ErrGone means the resourceVersion expired.
func (s *Stream) Next() (Event, error) {
	for {
		var raw struct {
			Type   string          `json:"type"`
			Object json.RawMessage `json:"object"`
		}
		if err := s.dec.Decode(&raw); err != nil {
			return Event{}, err
		}
		var obj Object
		_ = json.Unmarshal(raw.Object, &obj)
		switch raw.Type {
		case "ERROR":
			if c, _ := obj["code"].(float64); c == http.StatusGone {
				return Event{}, ErrGone
			}
			return Event{}, &Error{Op: "watch", Code: int(func() float64 { c, _ := obj["code"].(float64); return c }()), Reason: reason(raw.Object)}
		case "BOOKMARK":
			return Event{Type: "BOOKMARK", Object: obj}, nil
		}
		return Event{Type: raw.Type, Object: obj}, nil
	}
}

// Watch opens a watch from resourceVersion rv. The stream ends when ctx is done or the server closes it.
func (c *Client) Watch(ctx context.Context, r Resource, ns, rv string) (*Stream, error) {
	q := url.Values{"watch": {"true"}, "allowWatchBookmarks": {"true"}}
	if rv != "" {
		q.Set("resourceVersion", rv)
	}
	req, err := c.newRequest(ctx, http.MethodGet, r.path(ns, "", ""), q, "", nil)
	if err != nil {
		return nil, err
	}
	resp, err := c.http.Do(req)
	if err != nil {
		var ue *url.Error
		if errors.As(err, &ue) {
			err = ue.Err
		}
		return nil, fmt.Errorf("kubernetes API: watch %s: request failed: %w", r.Plural, err)
	}
	if resp.StatusCode == http.StatusGone {
		resp.Body.Close()
		return nil, ErrGone
	}
	if resp.StatusCode >= 300 {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<16))
		resp.Body.Close()
		return nil, &Error{Op: "watch " + r.Plural, Code: resp.StatusCode, Reason: reason(b)}
	}
	return &Stream{dec: json.NewDecoder(resp.Body), body: resp.Body}, nil
}

// Manifest is one object a runtime wants written, with the endpoint it belongs to.
type Manifest struct {
	Resource Resource
	Object   Object
	// Namespace is where the object goes. "" means the definition's own namespace (the default, and what every builtin
	// runtime uses); a container runtime sets its workload namespace here.
	Namespace string
}

// MetaMap gives safe access to the metadata of an unstructured object.
type MetaMap map[string]any

// Meta returns the metadata map of o (empty, never nil, when absent).
func Meta(o Object) MetaMap {
	m, _ := o["metadata"].(map[string]any)
	return MetaMap(m)
}

// String returns a string field of the metadata, or "".
func (m MetaMap) String(k string) string {
	s, _ := m[k].(string)
	return s
}

// Package routes keeps the A2A gate's route list: a ConfigMap whose one key, routes.json, is exactly {"container":[ns/name,...]},
// sorted and compact. The gate sends those agents to the container runtime's Service; the list cannot carry a URL. The control
// plane is the only writer and writes nothing but this shape.
package routes

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"regexp"
	"slices"
	"sync"

	"github.com/openagentix/openagentix/services/control-plane/internal/kube"
)

const (
	// DefaultName is the ConfigMap's name.
	DefaultName = "a2a-gate-routes"
	// Key is its one data key.
	Key = "routes.json"
)

var configMaps = kube.Resource{Version: "v1", Plural: "configmaps", Kind: "ConfigMap", Namespaced: true}

// refRE is "namespace/name", both DNS labels, as the gate checks them.
var refRE = regexp.MustCompile(`^[a-z]([-a-z0-9]*[a-z0-9])?/[a-z]([-a-z0-9]*[a-z0-9])?$`)

// Kube is the part of the REST client the store uses.
type Kube interface {
	Get(ctx context.Context, r kube.Resource, ns, name string) (kube.Object, error)
	PatchMerge(ctx context.Context, r kube.Resource, ns, name, sub string, patch kube.Object) error
}

// Store reads and writes the route list ConfigMap.
type Store struct {
	Kube      Kube
	Namespace string
	Name      string // DefaultName when empty
	mu        sync.Mutex
}

func (s *Store) name() string {
	if s.Name == "" {
		return DefaultName
	}
	return s.Name
}

func check(ref string) error {
	if !refRE.MatchString(ref) {
		return fmt.Errorf("route %q is not namespace/name", ref)
	}
	return nil
}

// encode is the one shape: sorted, no duplicates, compact.
func encode(list []string) string {
	l := slices.Clone(list)
	slices.Sort(l)
	l = slices.Compact(l)
	if l == nil {
		l = []string{}
	}
	var b bytes.Buffer
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	_ = enc.Encode(struct {
		Container []string `json:"container"`
	}{l})
	return string(bytes.TrimSpace(b.Bytes()))
}

// parse reads the current list; anything but the exact shape reads as empty (and so is rewritten on the next change).
func parse(raw string) []string {
	var v struct {
		Container []string `json:"container"`
	}
	dec := json.NewDecoder(bytes.NewReader([]byte(raw)))
	dec.DisallowUnknownFields()
	if dec.Decode(&v) != nil || dec.More() {
		return nil
	}
	var out []string
	for _, r := range v.Container {
		if check(r) == nil {
			out = append(out, r)
		}
	}
	return out
}

func (s *Store) current(ctx context.Context) (string, error) {
	o, err := s.Kube.Get(ctx, configMaps, s.Namespace, s.name())
	if err != nil {
		return "", fmt.Errorf("read ConfigMap %s/%s: %w", s.Namespace, s.name(), err)
	}
	d, _ := o["data"].(map[string]any)
	raw, _ := d[Key].(string)
	return raw, nil
}

// update applies f to the list and writes it with a merge patch, only when the text differs.
func (s *Store) update(ctx context.Context, f func([]string) []string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	raw, err := s.current(ctx)
	if err != nil {
		return err
	}
	want := encode(f(parse(raw)))
	if want == raw {
		return nil
	}
	if err := s.Kube.PatchMerge(ctx, configMaps, s.Namespace, s.name(), "", kube.Object{"data": kube.Object{Key: want}}); err != nil {
		return fmt.Errorf("write ConfigMap %s/%s: %w", s.Namespace, s.name(), err)
	}
	return nil
}

// Ensure lists ref ("namespace/name").
func (s *Store) Ensure(ctx context.Context, ref string) error {
	if err := check(ref); err != nil {
		return err
	}
	return s.update(ctx, func(l []string) []string { return append(l, ref) })
}

// Remove drops ref.
func (s *Store) Remove(ctx context.Context, ref string) error {
	if err := check(ref); err != nil {
		return err
	}
	return s.update(ctx, func(l []string) []string {
		return slices.DeleteFunc(l, func(x string) bool { return x == ref })
	})
}

// Sync makes the list exactly keep.
func (s *Store) Sync(ctx context.Context, keep []string) error {
	for _, r := range keep {
		if err := check(r); err != nil {
			return err
		}
	}
	return s.update(ctx, func([]string) []string { return keep })
}

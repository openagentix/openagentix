// Package agentgateway is the ModelGateway adapter. It keeps one ConfigMap, llm-api-keys-control-plane, in the gateway
// namespace: one entry per gateway user, in the format install.sh writes into llm-api-keys. The entry's name is the user id,
// "<namespace>.<name>" of the definition: a ConfigMap key may hold '.', the gateway never reads the key's text (only the JSON
// value: agentgateway controller/pkg/agentgateway/plugins/traffic_plugin.go, processAPIKeyAuthenticationPolicy), and its
// metadata is a free map (crates/agentgateway/src/http/apikey.rs, UserMetadata), so user_id may hold '.' too. The ConfigMap is created by
// the chart (labelled agentgateway.dev/apikey=true, which the gateway policy selects on); the controller only patches
// single entries, so it never touches the installer's ConfigMap and the installer never touches this one.
package agentgateway

import (
	"context"
	"encoding/json"
	"fmt"
	"regexp"

	"github.com/openagentix/openagentix/services/control-plane/internal/api"
	"github.com/openagentix/openagentix/services/control-plane/internal/keys"
	"github.com/openagentix/openagentix/services/control-plane/internal/kube"
)

// ConfigMapName is the controller's own key ConfigMap.
const ConfigMapName = "llm-api-keys-control-plane"

var cm = kube.Resource{Version: "v1", Plural: "configmaps", Kind: "ConfigMap", Namespaced: true}

// userRE is "<namespace>.<name>": a namespace is a DNS label (at most 63 characters), a name a DNS label of at most 40
// starting with a letter; neither can hold a dot, so the id is unique per namespace and name, and a chart agent's plain name
// (which has no dot) can never be equal to it.
var userRE = regexp.MustCompile(`^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?\.[a-z]([-a-z0-9]{0,38}[a-z0-9])?$`)

// classRE is a DNS label of at most 40 characters: no quote, backslash or control character can reach the entry.
var classRE = regexp.MustCompile(`^[a-z0-9]([-a-z0-9]{0,38}[a-z0-9])?$`)

// metadataKeys maps the reserved label keys the gateway carries as metadata to the metadata names, in the order written.
var metadataKeys = []struct{ label, meta string }{{api.LabelTeam, "team"}, {api.LabelProject, "project"}}

// API is the part of the REST client this adapter uses.
type API interface {
	Get(ctx context.Context, r kube.Resource, ns, name string) (kube.Object, error)
	PatchMerge(ctx context.Context, r kube.Resource, ns, name, sub string, patch kube.Object) error
}

type Adapter struct {
	api API
	ns  string
}

func New(api API, namespace string) *Adapter { return &Adapter{api: api, ns: namespace} }

func (a *Adapter) Name() string { return "agentgateway" }

// entry is the exact text install.sh writes: {"keyHash":"<hash>","metadata":{"user_id":"<user>"}}.
// A budget class is the last member (ADR 0029), the one place the admission guard accepts it.
func entry(user, hash string, labels map[string]string, class string) string {
	h, _ := json.Marshal(hash)
	u, _ := json.Marshal(user)
	meta := `"user_id":` + string(u)
	for _, k := range metadataKeys {
		if v := labels[k.label]; v != "" {
			j, _ := json.Marshal(v)
			meta += `,"` + k.meta + `":` + string(j)
		}
	}
	if class != "" {
		j, _ := json.Marshal(class)
		meta += `,"budget_class":` + string(j)
	}
	return `{"keyHash":` + string(h) + `,"metadata":{` + meta + `}}`
}

// Register sets the entry of user. A missing ConfigMap is an error: the chart creates it.
func (a *Adapter) Register(ctx context.Context, user, hash string, labels map[string]string, class string) error {
	if !userRE.MatchString(user) {
		return fmt.Errorf("gateway user id %q is not a valid <namespace>.<name>", user)
	}
	if class != "" && (class == "default" || !classRE.MatchString(class)) {
		return fmt.Errorf("budget class %q is not a DNS label of at most 40 characters (or is the reserved name default)", class)
	}
	err := a.api.PatchMerge(ctx, cm, a.ns, ConfigMapName, "", kube.Object{"data": kube.Object{user: entry(user, hash, labels, class)}})
	if err != nil {
		return fmt.Errorf("write key entry for %s: %w", user, err)
	}
	return nil
}

// Unregister removes the entry of user; nothing to do when the ConfigMap or the entry is missing.
func (a *Adapter) Unregister(ctx context.Context, user string) error {
	err := a.api.PatchMerge(ctx, cm, a.ns, ConfigMapName, "", kube.Object{"data": kube.Object{user: nil}})
	if err != nil && !kube.IsNotFound(err) {
		return fmt.Errorf("remove key entry for %s: %w", user, err)
	}
	return nil
}

// Entries returns the hash of every user that has an entry ("" for an entry that is not in the installer's format).
func (a *Adapter) Entries(ctx context.Context) (map[string]keys.Entry, error) {
	o, err := a.api.Get(ctx, cm, a.ns, ConfigMapName)
	if err != nil {
		return nil, fmt.Errorf("read key ConfigMap: %w", err)
	}
	data, _ := o["data"].(map[string]any)
	out := make(map[string]keys.Entry, len(data))
	for user, v := range data {
		s, _ := v.(string)
		var e struct {
			KeyHash  string         `json:"keyHash"`
			Metadata map[string]any `json:"metadata"`
		}
		_ = json.Unmarshal([]byte(s), &e)
		ent := keys.Entry{Hash: e.KeyHash}
		ent.Class, _ = e.Metadata["budget_class"].(string)
		for _, k := range metadataKeys {
			if v, _ := e.Metadata[k.meta].(string); v != "" {
				if ent.Labels == nil {
					ent.Labels = map[string]string{}
				}
				ent.Labels[k.label] = v
			}
		}
		out[user] = ent
	}
	return out, nil
}

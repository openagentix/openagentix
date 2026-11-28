// Package keys makes and registers the per-agent gateway virtual key. The key exists only in process memory and in the
// body of one create request; the controller never reads or lists Secrets, and no log line, status or error repeats it.
package keys

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"maps"
	"strings"

	"github.com/openagentix/openagentix/services/control-plane/internal/kube"
)

// Outcome says what Ensure did.
type Outcome string

const (
	Created   Outcome = "created"   // Secret created (201), hash written
	Exists    Outcome = "exists"    // Secret exists (409) and the gateway has a hash for the user: adopted, nothing written
	Replaced  Outcome = "replaced"  // Secret existed but its key is not the registered one: deleted, created again, hash written
	Unchanged Outcome = "unchanged" // the registered hash is the known key's: no mint, no request
	Relabeled Outcome = "relabeled" // as Unchanged, but the entry's labels were out of date and were rewritten
)

// AnnotationFingerprint carries the key fingerprint on the Secret and on the runtime objects that must roll when the key
// changes. It is not a secret: it is the head of the hash that is public in the gateway's ConfigMap.
const AnnotationFingerprint = "openagentix.io/key-fingerprint"

// Result is what Ensure did and the fingerprint of the key that is now registered.
type Result struct {
	Outcome     Outcome
	Fingerprint string
	Hash        string // the hash the gateway holds for the user after Ensure
}

// Fingerprint is the first 16 hex characters of a hash as Hash returns it ("" for an empty hash).
func Fingerprint(hash string) string {
	h := strings.TrimPrefix(hash, "sha256:")
	if h == "" {
		return ""
	}
	if len(h) > 16 {
		h = h[:16]
	}
	return h
}

// Mint returns "vk-" plus 16 random bytes in hex, like install.sh.
func Mint() (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", errors.New("random source failed")
	}
	return "vk-" + hex.EncodeToString(b), nil
}

// Hash is what the gateway stores: "sha256:" and the hex SHA-256 of the key.
func Hash(key string) string {
	sum := sha256.Sum256([]byte(key))
	return "sha256:" + hex.EncodeToString(sum[:])
}

// Registry is the model gateway's key store (writing side; the core reads the entries once per pass and hands the
// current hash of the user to Ensure).
type Registry interface {
	// Register sets the entry of user: the hash and the informational labels (the reserved label keys) that the gateway
	// carries as metadata next to the user id. labels may be nil.
	// class is the budget class of the entry ("" for none, ADR 0029).
	Register(ctx context.Context, user, hash string, labels map[string]string, class string) error
}

// Entry is what the gateway holds for one user.
type Entry struct {
	Hash   string
	Labels map[string]string
	Class  string // the budget class of the entry, "" when it has none
}

// Secrets is the write-only view of Secrets the controller has: create and delete, never get or list.
type Secrets interface {
	Create(ctx context.Context, ns string, obj kube.Object) error
	Delete(ctx context.Context, ns, name string) error
}

// KubeSecrets implements Secrets over the REST client.
type KubeSecrets struct{ C *kube.Client }

var secretRes = kube.Resource{Version: "v1", Plural: "secrets", Kind: "Secret", Namespaced: true}

func (k *KubeSecrets) Create(ctx context.Context, ns string, obj kube.Object) error {
	_, err := k.C.Create(ctx, secretRes, ns, obj)
	return err
}

func (k *KubeSecrets) Delete(ctx context.Context, ns, name string) error {
	return k.C.Delete(ctx, secretRes, ns, name)
}

type OwnerRef struct{ APIVersion, Kind, Name, UID string }

// Params describe the Secret and the gateway user.
type Params struct {
	Namespace, SecretName, DataKey, User string
	Labels                               map[string]string
	Owner                                OwnerRef
	// Registered is the hash the gateway holds for User now ("" when none). Known is the fingerprint of the key the
	// controller minted last, as it recorded it in the definition's status ("" when unknown).
	Registered, Known string
	// EntryLabels are the labels the entry should carry; RegisteredLabels the ones it carries now. When they differ and the
	// key is in order, the entry is rewritten with the same hash.
	EntryLabels, RegisteredLabels map[string]string
	// EntryClass is the budget class the entry should carry, RegisteredClass the one it carries now (ADR 0029); a difference rewrites the entry like a label does.
	EntryClass, RegisteredClass string
	// Adopted: Registered is an entry the previous controller made under another user id (the plain name). When the Secret
	// exists it holds that entry's key, so the hash is written under User and nothing is replaced; when it does not, the hash
	// belongs to nothing and a new key is made as usual.
	Adopted bool
	// Hold: the definition is suspended. Ensure makes or finds the key but registers nothing (and rewrites no entry), and the
	// Result carries the hash to hold. The caller removes an entry that exists.
	Hold bool
}

func (p Params) secret(key string) kube.Object {
	labels := map[string]any{}
	for k, v := range p.Labels {
		labels[k] = v
	}
	meta := kube.Object{
		"name": p.SecretName, "namespace": p.Namespace, "labels": labels,
		"annotations": map[string]any{AnnotationFingerprint: Fingerprint(Hash(key))},
	}
	// An owner reference cannot cross namespaces: a Secret in a workload namespace has no owner UID and so no reference; the
	// controller deletes it by name (and by label) instead.
	if p.Owner.UID != "" {
		meta["ownerReferences"] = []any{kube.Object{"apiVersion": p.Owner.APIVersion, "kind": p.Owner.Kind, "name": p.Owner.Name, "uid": p.Owner.UID, "controller": true}}
	}
	return kube.Object{
		"apiVersion": "v1", "kind": "Secret", "type": "Opaque", "immutable": true,
		"metadata": meta,
		"data":     kube.Object{p.DataKey: base64.StdEncoding.EncodeToString([]byte(key))},
	}
}

// Ensure makes sure the agent has a Secret and a registered hash, following ADR 0007 "Virtual keys". The Secret's name
// carries the definition's UID (plan.KeySecretName), so a Secret of that name was made for this definition: it may be
// replaced, never adopted blindly. Ensure never reads a Secret; what it knows comes from the gateway's hash and from the
// fingerprint the controller recorded.
//
//   - Registered hash present and equal to the known fingerprint: nothing to do, no mint, no request.
//   - Registered hash present and a different one known: someone restored an older entry. The key is replaced.
//   - No registered hash, or nothing known: create the Secret. 201: register. 409 and a hash is registered: adopt it. 409 and
//     none: the Secret holds a key nobody can use, so it is deleted, created again and the new hash registered.
func Ensure(ctx context.Context, p Params, sec Secrets, reg Registry, mint func() (string, error)) (Result, error) {
	regFP := Fingerprint(p.Registered)
	if regFP != "" && p.Known == regFP {
		labelsDiffer := !maps.Equal(p.EntryLabels, p.RegisteredLabels) && (len(p.EntryLabels) > 0 || len(p.RegisteredLabels) > 0)
		if !p.Hold && (labelsDiffer || p.EntryClass != p.RegisteredClass) {
			if err := reg.Register(ctx, p.User, p.Registered, p.EntryLabels, p.EntryClass); err != nil {
				return Result{}, fmt.Errorf("update key entry for %s: %w", p.User, err)
			}
			return Result{Outcome: Relabeled, Fingerprint: regFP, Hash: p.Registered}, nil
		}
		return Result{Outcome: Unchanged, Fingerprint: regFP, Hash: p.Registered}, nil
	}
	replace := regFP != "" && p.Known != ""
	if replace {
		if err := sec.Delete(ctx, p.Namespace, p.SecretName); err != nil && !kube.IsNotFound(err) {
			return Result{}, fmt.Errorf("delete key secret %s: %w", p.SecretName, err)
		}
	}
	create := func() (string, error) {
		key, err := mint()
		if err != nil {
			return "", err
		}
		return key, sec.Create(ctx, p.Namespace, p.secret(key))
	}
	register := func(key string, out Outcome) (Result, error) {
		h := Hash(key)
		if !p.Hold {
			if err := reg.Register(ctx, p.User, h, p.EntryLabels, p.EntryClass); err != nil {
				return Result{}, fmt.Errorf("register key hash for %s: %w", p.User, err)
			}
		}
		return Result{Outcome: out, Fingerprint: Fingerprint(h), Hash: h}, nil
	}
	key, err := create()
	switch {
	case err == nil && replace:
		return register(key, Replaced)
	case err == nil:
		return register(key, Created)
	case !kube.IsConflict(err):
		return Result{}, fmt.Errorf("create key secret %s: %w", p.SecretName, err)
	}
	// 409: the Secret exists. Whether it is usable is known only from the gateway side.
	if regFP != "" && !replace {
		if p.Adopted {
			if err := reg.Register(ctx, p.User, p.Registered, p.EntryLabels, p.EntryClass); err != nil {
				return Result{}, fmt.Errorf("register key hash for %s: %w", p.User, err)
			}
		}
		return Result{Outcome: Exists, Fingerprint: regFP, Hash: p.Registered}, nil
	}
	if err := sec.Delete(ctx, p.Namespace, p.SecretName); err != nil && !kube.IsNotFound(err) {
		return Result{}, fmt.Errorf("delete key secret %s: %w", p.SecretName, err)
	}
	if key, err = create(); err != nil {
		return Result{}, fmt.Errorf("create key secret %s again: %w", p.SecretName, err)
	}
	return register(key, Replaced)
}

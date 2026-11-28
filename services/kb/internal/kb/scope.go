package kb

import (
	"context"

	"github.com/openagentix/openagentix/services/kb/internal/store"
)

type scopeKey struct{}

// WithScope returns a context whose reads are limited to the scope's
// collections (ADR 0030). The admin API never sets one.
func WithScope(ctx context.Context, sc store.Scope) context.Context {
	return context.WithValue(ctx, scopeKey{}, sc)
}

// ScopeFrom returns the scope of a context; the zero scope limits nothing.
func ScopeFrom(ctx context.Context) store.Scope {
	sc, _ := ctx.Value(scopeKey{}).(store.Scope)
	return sc
}

package fake

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/openagentix/openagentix/services/console/internal/backend"
	"github.com/openagentix/openagentix/services/console/internal/model"
)

func TestSeedMatchesTheMockup(t *testing.T) {
	b := New(nil, 0)
	l, _ := b.List(context.Background())
	got := map[string]model.State{}
	for _, a := range l.Items {
		got[a.Name] = a.State
	}
	want := map[string]model.State{"assistant": "ready", "profile-demo": "ready", "researcher": "ready", "cve-triage": "refused", "release-notes": "pending"}
	if len(got) != 5 || l.Used != 3 {
		t.Fatal(got, l.Used)
	}
	for k, v := range want {
		if got[k] != v {
			t.Errorf("%s: %s", k, got[k])
		}
	}
	d, _ := b.Get(context.Background(), "cve-triage")
	if len(d.Status.Violations) != 2 || !strings.HasPrefix(d.Status.Violations[0], `the definition lists tool "knowledge_kb_get_document"`) {
		t.Fatalf("%v", d.Status.Violations)
	}
}

func TestConflictAndSettling(t *testing.T) {
	now := time.Now()
	b := New(func() time.Time { return now }, 5*time.Second)
	ctx := context.Background()
	d, err := b.Create(ctx, "fresh", model.Spec{Model: "claude-haiku", Instructions: "x", ToolProfile: "lookup"})
	if err != nil || d.State != model.StatePending {
		t.Fatal(err, d.State)
	}
	b.Touch("fresh")
	if _, err := b.Update(ctx, "fresh", d.ResourceVersion, model.Spec{Model: "claude-haiku", Instructions: "y", ToolProfile: "lookup"}); err == nil || err.(*backend.Error).Code != "conflict" {
		t.Fatal("expected a conflict", err)
	}
	now = now.Add(6 * time.Second)
	d, _ = b.Get(ctx, "fresh")
	if d.State != model.StateReady {
		t.Fatal(d.State)
	}
	d2, err := b.Create(ctx, "bad", model.Spec{Model: "gpt-x", Instructions: "x", ToolProfile: "lookup"})
	if err != nil {
		t.Fatal(err)
	}
	now = now.Add(6 * time.Second)
	if d2, _ = b.Get(ctx, "bad"); d2.State != model.StateRefused || len(d2.Status.Violations) == 0 {
		t.Fatal(d2.State)
	}
}

func TestContainerAgentNeedsNoInstructionsAndIsAcceptedByTheDemoPolicy(t *testing.T) {
	now := time.Now()
	b := New(func() time.Time { return now }, 5*time.Second)
	ctx := context.Background()
	img := "registry.example.com/agents/echo@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	sp := model.Spec{Model: "claude-haiku", Runtime: map[string]any{"type": "container", "container": map[string]any{"image": img, "port": float64(8080)}}}
	d, err := b.Create(ctx, "echo", sp)
	if err != nil || d.RuntimeType != "container" {
		t.Fatal(err, d.RuntimeType)
	}
	now = now.Add(6 * time.Second)
	if d, _ = b.Get(ctx, "echo"); d.State != model.StateReady {
		t.Fatal(d.State, d.Status.Violations)
	}
	sp.Runtime["container"].(map[string]any)["image"] = "registry.example.com/agents/echo:1"
	if _, err := b.Create(ctx, "bad", sp); err != nil {
		t.Fatal(err)
	}
	now = now.Add(6 * time.Second)
	if d, _ = b.Get(ctx, "bad"); d.State != model.StateRefused {
		t.Fatal(d.State)
	}
}

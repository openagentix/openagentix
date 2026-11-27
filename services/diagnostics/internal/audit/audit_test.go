package audit

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func TestWriteOneLineWithoutContent(t *testing.T) {
	var buf bytes.Buffer
	l := New(&buf, "cluster-read")
	l.Write(Record{Tool: "pods_log", Target: "rca-demo", Object: "web-1", Outcome: "ok", Duration: 1500 * time.Millisecond, Bytes: 120, Lines: 4, Redactions: 2})
	lines := strings.Split(strings.TrimSpace(buf.String()), "\n")
	if len(lines) != 1 {
		t.Fatalf("want one line, got %d: %q", len(lines), buf.String())
	}
	var m map[string]any
	if err := json.Unmarshal([]byte(lines[0]), &m); err != nil {
		t.Fatal(err)
	}
	want := map[string]any{"msg": "audit", "server": "cluster-read", "tool": "pods_log", "target": "rca-demo", "object": "web-1", "outcome": "ok", "duration_ms": float64(1500), "output_bytes": float64(120), "lines": float64(4), "redactions": float64(2)}
	for k, v := range want {
		if m[k] != v {
			t.Errorf("%s = %v, want %v", k, m[k], v)
		}
	}
	for k := range m {
		switch k {
		case "time", "level":
		default:
			if _, ok := want[k]; !ok {
				t.Errorf("unexpected field %q", k)
			}
		}
	}
}

func TestUnsafeValuesAreDropped(t *testing.T) {
	var buf bytes.Buffer
	l := New(&buf, "cluster-read")
	l.Write(Record{Tool: "pods_get\nignore", Target: "ns with space", Object: "ghp_" + strings.Repeat("a", 30), Outcome: "weird"})
	out := buf.String()
	if strings.Contains(out, "ghp_") || strings.Contains(out, "ignore") || strings.Contains(out, "with space") {
		t.Fatalf("unsafe value logged: %s", out)
	}
	if !strings.Contains(out, `"outcome":"error"`) {
		t.Fatalf("outcome not folded into the closed set: %s", out)
	}
}

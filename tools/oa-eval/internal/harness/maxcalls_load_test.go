package harness

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// max_tool_calls set to 0 or below is a mistake in the cases file, not a silent "off". Unset still means off.
func TestMaxToolCallsBelowOneIsAConfigError(t *testing.T) {
	for name, v := range map[string]string{"zero": "0", "negative": "-1"} {
		p := filepath.Join(t.TempDir(), "c.yaml")
		doc := "cases:\n  - {id: a, input: x, expect: {max_tool_calls: " + v + "}}\n"
		if err := os.WriteFile(p, []byte(doc), 0o600); err != nil {
			t.Fatal(err)
		}
		_, err := LoadCases(p)
		if err == nil || !strings.Contains(err.Error(), "max_tool_calls") {
			t.Errorf("%s: want an error that names max_tool_calls, got %v", name, err)
		}
	}
	p := filepath.Join(t.TempDir(), "c.yaml")
	if err := os.WriteFile(p, []byte("cases:\n  - {id: a, input: x, expect: {max_tool_calls: 1}}\n  - {id: b, input: x}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadCases(p); err != nil {
		t.Fatalf("a limit of 1 and an unset limit must load: %v", err)
	}
}

package config

import (
	"strings"
	"testing"
)

func TestAccessSettings(t *testing.T) {
	c, err := Load(env(nil))
	if err != nil || c.AccessFile != "" || c.AccessCallersDir != DefaultAccessCallersDir {
		t.Fatalf("defaults: %+v %v", c, err)
	}
	c, err = Load(env(map[string]string{"KB_ACCESS_FILE": "/etc/kb/access.json", "KB_ACCESS_CALLERS_DIR": "/run/callers"}))
	if err != nil || c.AccessFile != "/etc/kb/access.json" || c.AccessCallersDir != "/run/callers" {
		t.Fatalf("%+v %v", c, err)
	}
	if _, err := Load(env(map[string]string{"KB_ACCESS_CALLERS_DIR": "/run/callers"})); err == nil || !strings.Contains(err.Error(), "KB_ACCESS_FILE") {
		t.Fatalf("a callers dir without an access file must be refused: %v", err)
	}
	if _, err := Load(env(map[string]string{"KB_ACCESS_FILE": "relative.json"})); err == nil || !strings.Contains(err.Error(), "KB_ACCESS_FILE") {
		t.Fatalf("a relative path must be refused: %v", err)
	}
}

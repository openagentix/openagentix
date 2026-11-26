package config

import (
	"testing"
	"time"
)

func TestLoad_WakeupDefaultsAndOverrides(t *testing.T) {
	base := map[string]string{"TELEGRAM_BOT_TOKEN": "tok", "A2A_URL": "http://agent", "TELEGRAM_ALLOW_ALL": "true"}
	c, err := Load(env(base))
	if err != nil || !c.RetryOnWakeup || c.WakeupDelay != 20*time.Second {
		t.Fatalf("defaults: %+v %v", c, err)
	}
	base["RETRY_ON_WAKEUP"], base["WAKEUP_RETRY_DELAY"] = "false", "5s"
	c, err = Load(env(base))
	if err != nil || c.RetryOnWakeup || c.WakeupDelay != 5*time.Second {
		t.Fatalf("overrides: %+v %v", c, err)
	}
	for k, v := range map[string]string{"RETRY_ON_WAKEUP": "maybe", "WAKEUP_RETRY_DELAY": "-1s"} {
		bad := map[string]string{"TELEGRAM_BOT_TOKEN": "tok", "A2A_URL": "http://agent", "TELEGRAM_ALLOW_ALL": "true", k: v}
		if _, err := Load(env(bad)); err == nil {
			t.Fatalf("%s=%s accepted", k, v)
		}
	}
}

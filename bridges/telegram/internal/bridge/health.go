package bridge

import (
	"net/http"
	"time"
)

func (b *Bridge) now() time.Time {
	if b.Now != nil {
		return b.Now()
	}
	return time.Now()
}

func (b *Bridge) markPoll() { b.lastPoll.Store(b.now().UnixNano()) }

// markPolled records the first successful getUpdates. It never goes back to false.
func (b *Bridge) markPolled() { b.polled.Store(true) }

// Ready reports whether the bridge has completed one successful getUpdates and
// is still polling. Unlike Healthy, the start-up moment does not count.
func (b *Bridge) Ready() bool { return b.polled.Load() && b.Healthy() }

// Healthy reports whether Run is polling: it started, and the last successful
// getUpdates is no older than 3x the poll timeout (at least 3s).
func (b *Bridge) Healthy() bool {
	last := b.lastPoll.Load()
	if last == 0 {
		return false
	}
	window := 3 * time.Duration(max(b.PollTimeout, 1)) * time.Second
	return b.now().Sub(time.Unix(0, last)) <= window
}

// HealthHandler serves GET /healthz (liveness: 200 while polling is healthy,
// else 503) and GET /readyz (readiness: 200 only after the first successful
// poll, and while polling stays healthy). It exposes no other information.
func (b *Bridge) HealthHandler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		if b.Healthy() {
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte("ok\n"))
			return
		}
		http.Error(w, "polling stalled", http.StatusServiceUnavailable)
	})
	mux.HandleFunc("/readyz", func(w http.ResponseWriter, _ *http.Request) {
		if b.Ready() {
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte("ok\n"))
			return
		}
		http.Error(w, "no successful poll yet", http.StatusServiceUnavailable)
	})
	return mux
}

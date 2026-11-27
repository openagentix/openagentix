// Command stub-model serves the scripted OpenAI-compatible stub used by the OpenAgentix quick start.
package main

import (
	"log"
	"net/http"
	"os"
	"time"

	"github.com/openagentix/openagentix/services/stub-model/internal/stub"
)

func main() {
	addr := os.Getenv("STUB_MODEL_ADDR")
	if addr == "" {
		addr = ":8080"
	}
	handler := stub.New()
	if p := os.Getenv("STUB_MODEL_SCENARIOS"); p != "" {
		set, err := stub.LoadScenarios(p)
		if err != nil {
			log.Fatalf("stub-model: STUB_MODEL_SCENARIOS=%s: %v", p, err)
		}
		handler = stub.NewWithScenarios(set)
		log.Printf("stub-model: scenarios loaded from %s", p)
	}
	srv := &http.Server{Addr: addr, Handler: handler, ReadHeaderTimeout: 10 * time.Second, ReadTimeout: 30 * time.Second, WriteTimeout: 60 * time.Second}
	log.Printf("stub-model listening on %s (a scripted stand-in, not a language model)", addr)
	log.Fatal(srv.ListenAndServe())
}

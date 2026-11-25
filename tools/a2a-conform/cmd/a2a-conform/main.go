// a2a-conform checks that an agent speaks the A2A 1.0 slice OpenAgentix needs from a container agent.
//
//	a2a-conform http://localhost:8080
//	a2a-conform --fake-model :9099        # also serve a fake OpenAI endpoint for the agent to call
//
// Exit code 0: no failed check. 1: at least one failed check. 2: bad usage.
package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"time"

	"github.com/openagentix/openagentix/tools/a2a-conform/internal/conform"
)

func main() { os.Exit(run(os.Args[1:], os.Stdout, os.Stderr)) }

func run(args []string, out, errw io.Writer) int {
	fs := flag.NewFlagSet("a2a-conform", flag.ContinueOnError)
	fs.SetOutput(errw)
	fake := fs.String("fake-model", "", "serve a fake OpenAI chat endpoint on this address (for example :9099) while checking; point the agent's OPENAI_BASE_URL at it")
	timeout := fs.Duration("call-timeout", 30*time.Second, "time allowed for each JSON-RPC call")
	fs.Usage = func() {
		fmt.Fprintln(errw, "usage: a2a-conform [flags] AGENT_URL   (for example http://localhost:8080)")
		fs.PrintDefaults()
	}
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if fs.NArg() != 1 {
		fs.Usage()
		return 2
	}
	if *fake != "" {
		srv := &http.Server{Addr: *fake, Handler: conform.FakeModel(), ReadHeaderTimeout: 5 * time.Second}
		go func() { _ = srv.ListenAndServe() }()
		defer srv.Close()
		fmt.Fprintf(errw, "fake model listening on %s (chat completions only)\n", *fake)
		time.Sleep(200 * time.Millisecond)
	}
	res := conform.Run(context.Background(), fs.Arg(0), conform.Options{CallTimeout: *timeout})
	conform.Render(out, res)
	if conform.Failed(res) {
		return 1
	}
	return 0
}

// Command oa-eval runs a use case's evaluation set against an agent through the A2A gate and checks the results
// with plain code, outside the model.
//
//	oa-eval run    --cases cases.yaml --gate-url URL [flags]
//	oa-eval replay --cases cases.yaml --gate-url URL --baseline report.json [flags]
//
// Exit codes: 0 all good, 1 a case failed (run) or a regression or agreement drop was found (replay), 2 bad usage or
// setup, 3 the model refused a call (a spent budget or a provider error): those cases are "not run". A token is read from a file, never from a flag, and is never printed.
package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	"github.com/openagentix/openagentix/tools/oa-eval/internal/harness"
)

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

const usage = `usage:
  oa-eval run    --cases FILE (--gate-url URL | --agent-url URL) [flags]
  oa-eval replay --cases FILE (--gate-url URL | --agent-url URL) --baseline REPORT.json [flags]
flags: --namespace NS (default kagent) --user-id ID --token-file FILE --audit FILE|URL --audit-token-file FILE
       --audit-settle DURATION (default 1s) --state-base URL --state-token-file FILE --timeout DURATION (default 120s)
       --only ID,ID --out REPORT.json --include-answers`

func run(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 || (args[0] != "run" && args[0] != "replay") {
		fmt.Fprintln(stderr, usage)
		return 2
	}
	mode := args[0]
	fs := flag.NewFlagSet(mode, flag.ContinueOnError)
	fs.SetOutput(stderr)
	var (
		casesPath = fs.String("cases", "", "evaluation set file")
		gate      = fs.String("gate-url", "", "base URL of the A2A gate")
		agentURL  = fs.String("agent-url", "", "one full agent URL, instead of a gate URL")
		ns        = fs.String("namespace", "kagent", "namespace of agents given by bare name")
		user      = fs.String("user-id", "", "caller id (X-User-Id); default eval:harness")
		tokenFile = fs.String("token-file", "", "file with the bearer token for the gate")
		audit     = fs.String("audit", "", "audit source: a file of JSON lines or an http(s) URL")
		auditTok  = fs.String("audit-token-file", "", "bearer token file for an audit URL")
		settle    = fs.Duration("audit-settle", time.Second, "wait after a call before reading the audit")
		stateBase = fs.String("state-base", "", "base URL of the system of record for state checks")
		stateTok  = fs.String("state-token-file", "", "bearer token file for the system of record")
		timeout   = fs.Duration("timeout", 120*time.Second, "time limit for one case")
		only      = fs.String("only", "", "comma separated case ids to run")
		out       = fs.String("out", "", "write the JSON report here")
		incl      = fs.Bool("include-answers", false, "put the answer text in the report (it may hold private data)")
		baseline  = fs.String("baseline", "", "replay: a report written by an earlier run")
	)
	if err := fs.Parse(args[1:]); err != nil {
		return 2
	}
	fail := func(format string, a ...any) int {
		fmt.Fprintf(stderr, "oa-eval: "+format+"\n", a...)
		return 2
	}
	if *casesPath == "" {
		return fail("--cases is required")
	}
	if *gate == "" && *agentURL == "" {
		return fail("give --gate-url or --agent-url")
	}
	if mode == "replay" && *baseline == "" {
		return fail("replay needs --baseline")
	}
	cs, err := harness.LoadCases(*casesPath)
	if err != nil {
		return fail("%v", err)
	}
	var old *harness.Report
	if mode == "replay" {
		if old, err = harness.LoadReport(*baseline); err != nil {
			return fail("%v", err)
		}
	}
	cfg := harness.Config{
		GateURL: *gate, AgentURL: *agentURL, DefaultNS: *ns, UserID: *user, TokenFile: *tokenFile,
		AuditSrc: *audit, AuditTokenFile: *auditTok, AuditSettle: *settle,
		StateBase: *stateBase, StateTokenFile: *stateTok, Timeout: *timeout, IncludeAnswers: *incl,
	}
	if *only != "" {
		cfg.Only = strings.Split(*only, ",")
	}
	rep, err := harness.Run(context.Background(), cs, cfg)
	if err != nil {
		return fail("%v", err)
	}
	rep.Mode = mode
	rep.WriteTable(stdout)
	rep.Failures(stdout)
	if *out != "" {
		if err := rep.WriteFile(*out); err != nil {
			return fail("cannot write the report: %v", err)
		}
	}
	if mode == "run" {
		if rep.Failed > 0 {
			return 1
		}
		if rep.NotRun > 0 {
			return 3 // the model refused a call: nothing failed, and nothing can be called a pass
		}
		return 0
	}
	d := harness.Compare(old, rep)
	fmt.Fprintln(stdout)
	d.Write(stdout)
	if d.Regressions > 0 || d.AgreementDrop {
		return 1
	}
	return 0
}

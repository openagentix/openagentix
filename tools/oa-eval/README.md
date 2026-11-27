# oa-eval

Runs an evaluation set against an agent through the A2A gate and checks the results with plain code, outside the model. It prints a pass/fail table and writes a JSON report. Its `replay` mode runs the set again and diffs the outcomes against a recorded report.

How to write a set, the checks, and the exit codes: `docs/diary/guide/write-an-evaluation-set.md`. An example set: `examples/cases.yaml`.

```sh
make test                                   # go test ./... -race -count=1
make build                                  # bin/oa-eval
bin/oa-eval run --cases examples/cases.yaml --gate-url http://127.0.0.1:8080 --token-file TOKEN --audit audit.jsonl --state-base http://127.0.0.1:9000 --out report.json
bin/oa-eval replay --cases examples/cases.yaml --gate-url ... --baseline report.json
```

Notes:

- The A2A call follows `tools/a2a-call` (JSON-RPC `SendMessage`, `A2A-Version: 1.0`, `X-User-Id`, bearer token). That module keeps its client in an internal package, so the small client is repeated here.
- Tests use a fake agent, a fake audit file and a fake record server. No cluster, no model, no network beyond localhost.
- It depends on `gopkg.in/yaml.v3` only.

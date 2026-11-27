# Stub model

A tiny OpenAI-compatible chat server with scripted answers. It is not a language model. The quick start uses it so that OpenAgentix can be tried with no model key, and CI uses it so that tests make no paid calls.

With no settings it knows two prompts:

- a vulnerability look-up (the word "vulnerab" or "cve"): one call to a tool whose name ends in `query_vulnerability`;
- a fetch request (the word "fetch", or a URL): one call to `fetch_fetch`, even when the agent is not offered it, so that the platform decides what is allowed.

After any tool result it quotes the result and says it is the stub. Everything else gets a plain "I am a scripted stand-in" answer.

## Scenarios

A scenario replays a whole agent run: several tool calls over several turns, then a final answer. It is the same every time, so a CI job can check the agent, the tool profile, the gate and the audit trail without a model.

Set `STUB_MODEL_SCENARIOS` to a JSON file, or to a directory of `*.json` files. Without it the stub behaves as before. A bad file stops the start with the reason, so a typo is found at once. In a cluster the chart ships the files (ADR 0026): `gateway.stubModel.scenarios.files` maps a file name to the JSON text, and the chart renders a ConfigMap `stub-model-scenarios`, mounts it read-only at `/etc/stub-model/scenarios`, sets `STUB_MODEL_SCENARIOS` and restarts the pod when a file changes. `install.sh` fills it from `STUB_SCENARIOS=<file or directory>` (pass it on every run, because Helm replaces release values). A name must be lowercase letters, digits and dashes ending in `.json`, and all files together may hold 256 KiB. The loader reads a ConfigMap mount the same as plain files (a test covers the `..data` links).

**This is a test component.** A scenario decides which tools an agent calls and with which arguments, and its placeholders copy text from the user's message into tool arguments. A run that uses scenarios is a scripted run, not the behaviour of a model. A demo, a diary entry or a `what-works.md` row that used one must say it was scripted by the stub model and name the scenario file.

```json
{
  "scenarios": [
    {
      "name": "dispute-triage",
      "match": {"system": "(?i)dispute", "user": "(?i)review dispute (?P<id>D-\\d+)"},
      "steps": [
        {"tool": "get_case", "args": {"case_id": "{{user.id}}"}},
        {"tool": "get_rule", "args": {"reason_code": "{{result.0.reason_code}}"}}
      ],
      "answers": [
        {"when": {"result.1.title": "^$"}, "text": "Inconclusive: no rule found for {{user.id}}."},
        {"text": "Case {{user.id}} falls under: {{result.1.title}}."}
      ]
    }
  ]
}
```

A full example is in [`examples/dispute.json`](examples/dispute.json).

How it works:

- **Match.** `match.system` is a regular expression on the system prompt (use it as an agent marker). `match.user` is a regular expression on the last user message. Give one or both; all that are given must match. The first scenario in file order that matches is used. If none matches, the built-in rules answer.
- **Step.** The step is the number of tool results after the last user message. Step N makes one tool call. When all steps are done, the answer is given.
- **Tool.** `tool` is matched by suffix among the tools the request offers, as the built-in rules do. If the tool is not offered, the chain ends with an answer that names the missing tool. This is how "the agent has no such tool" is tested.
- **Placeholders.** `{{user.N}}` and `{{user.name}}` are groups of the user pattern. `{{result.N}}` is the Nth tool result since the last user message, and `{{result.N.a.b.0.c}}` reads a field of it when it is JSON. When a path goes on below a string that holds a JSON object or array, the stub reads into it. This matters because an agent runtime may hand a tool result to the model as a string inside a wrapper: the kagent runtime gives `{"output":{"text":"<the tool's JSON>"}}`, so the field `pods.0.name` of such a result is `{{result.0.output.text.pods.0.name}}` (first seen in the live run of `examples/use-cases/software-org`). A placeholder with no value shows as `<missing NAME>`, never as an empty string, so a wrong path is easy to see. In `args`, a value that is exactly one placeholder keeps its JSON type (a number stays a number). A placeholder may not read a result that cannot exist yet; the loader refuses it.
- **Answers.** A list, tried in order. `when` maps a result path to a regular expression; all must match. An entry with no `when` is the default. Every answer starts with `[stub model]` and ends with the stub notice, so the smoke checks that look for "stub model" keep working.
- **Order of rules.** A loaded scenario is tried before the two built-in rules. A scenario can therefore also replace a built-in prompt. Without a scenario file the built-in rules are the only ones.
- **Call ids.** Step N uses the id `call_stub_N`. The built-in call keeps `call_stub_1`.

Run it:

```sh
STUB_MODEL_SCENARIOS=examples/dispute.json STUB_MODEL_ADDR=127.0.0.1:8080 go run ./cmd/stub-model
```

## Tests

```sh
make test      # go test ./... -race -count=1, standard library only
```

`TestExampleScenarioReplaysDeterministically` plays an agent loop against fake tools, twice, and checks that both runs are the same, including the case where the evidence is missing.

## Not done yet

- Scenarios are JSON, not YAML, because this module uses only the standard library.
- One tool call per turn. Parallel calls in one turn are not scripted.

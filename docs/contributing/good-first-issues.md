# Good first issue candidates

This page is a list of small, well-scoped tasks for a first contribution. Each one comes from a gap that was checked in the code or the docs on 2026-11-26. They are candidates: a maintainer turns one into a GitHub issue (labels `good first issue`, `help wanted`, one `kind/...`, one `area/...`, `priority/p2`) before anyone is asked to work on it. Nothing here is an issue yet.

New contributors: start with [Your first contribution in an hour](../diary/guide/first-contribution.md). Every task below needs only Go, Node or a text editor, and the offline checks. None needs Docker, a cluster, a model key or a chat token.

Sizes: **XS** is under 30 minutes, **S** is about an hour, **M** is two to four hours.

Some starter issues are already open and labelled `good first issue`: the shellcheck findings (#57), SPDX headers (#58), a glossary (#62), a troubleshooting page (#61), digest pins for Go base images (#63), unverified THIRD-PARTY entries (#64), example agents (#53), chart render-failure tests (#60), and three adapters (#54, #55, #56). The candidates below do not repeat them.

## Candidates

### 1. Remove a stray backup file from the knowledge base store

- **Area:** `kind/chore`, `area/knowledge`. **Size:** XS.
- **Gap:** `services/kb/internal/store/postgres/postgres.go.bak` is tracked in git. It differs from `postgres.go` and nothing uses it.
- **Files:** `services/kb/internal/store/postgres/postgres.go.bak`, `.gitignore`.
- **Do:** delete the file with `git rm`, and add `*.bak` and `*.orig` to `.gitignore`.
- **Acceptance:**
  - `git ls-files | rg '\.(bak|orig)$'` prints nothing.
  - `.gitignore` lists both patterns.
  - `(cd services/kb && go test ./...)` still passes.
- **Test:** `(cd services/kb && go build ./... && go test ./internal/store/...)`. The Postgres tests need Docker and are skipped without it; that is fine here.

### 2. Fix or remove a copied page with a broken link

- **Area:** `kind/docs`, `area/docs`. **Size:** XS.
- **Gap:** `components/runtime/dl/postgres.md` starts with Hugo front matter (`linkTitle`, `weight`) from an upstream site, and links to `../../pkg/postgressetup/setup.sql`, which does not exist in this repository. No other file links to the page. The SQL it describes lives in `components/runtime/dl/kagent-setup.sql` and `substrate-setup.sql`.
- **Files:** `components/runtime/dl/postgres.md`.
- **Do:** either rewrite the page for this repository (remove the front matter, link to the two real SQL files, say which install step uses them) or delete it and say why in the pull request.
- **Acceptance:**
  - No front matter that this repository does not use.
  - Every relative link in the page points to a file that exists.
  - The page says only what `install.sh` and the two SQL files do. Check each claim.
- **Test:** open every link in the page; `fd -t f . components/runtime/dl` shows the files that exist.

### 3. A relative link checker for the Markdown files

- **Area:** `kind/chore`, `area/ci`, `area/docs`. **Size:** M.
- **Gap:** the docs site fails the build on a broken link, but the Markdown outside `website/` (README, CONTRIBUTING, ADRs, component pages) has no link check. A scan on 2026-11-26 found one real broken link (candidate 2). The other hits were site routes that start with `/`, which the script must skip.
- **Files:** a new `hack/docs/check-links.sh` and a test next to the others in `hack/docs/tests/`; one line in the `test-shell` target of `Makefile`.
- **Do:** for each tracked `*.md` outside `website/` and `node_modules/`, check that each relative link target (without the `#anchor`) exists. Skip `http(s):`, `mailto:`, `#...` and links that start with `/`.
- **Acceptance:**
  - The script exits 1 and names the file and link when one is broken, and exits 0 on a clean tree.
  - A test in `hack/docs/tests/run.sh` shows both cases with a throwaway directory.
  - `make test-shell` runs it. Fix candidate 2 first, so the tree is clean.
- **Test:** `hack/docs/tests/run.sh`, then `make lint-shell` to check the new script.

### 4. Unit tests for the console's Kubernetes REST client

- **Area:** `kind/test`, `area/console`. **Size:** S.
- **Gap:** `services/console/internal/kube` has no test file (0.0% coverage). It is the one place the console sends a request to the API server, and its header comment makes three promises: it reads the token file again for every request, it never takes a header from the browser's request, and it has a response size limit.
- **Files:** `services/console/internal/kube/kube.go`, a new `kube_test.go`.
- **Do:** use `net/http/httptest` and a temporary token file. Write one test per promise, plus: a missing CA file returns an error, and a CA file with no certificate returns an error.
- **Acceptance:**
  - A test changes the token file between two requests and sees the new token on the second.
  - A test checks that only the headers the client sets are sent.
  - A test checks that a response over `maxResponse` is cut off or refused, as the code does.
  - Coverage of the package is above 80%.
- **Test:** `(cd services/console && go test -race -cover ./internal/kube/)`.

### 5. Unit tests for the console backend's status and spec helpers

- **Area:** `kind/test`, `area/console`. **Size:** M.
- **Gap:** `services/console/internal/backend` has 5.2% coverage. `kube.go` (653 lines) has no test file. It has small pure functions that are easy to test: `parseStatus`, `statusObj.mentions`, `statusObj.fieldProblems`, `shorten`, `unmanagedKeys` and `mergeSpec`.
- **Files:** `services/console/internal/backend/kube.go`, a new `kube_test.go`.
- **Do:** table-driven tests for those six functions. For `mergeSpec`, include a stored spec with a key the console does not manage, which must be kept.
- **Acceptance:**
  - Each function has at least one normal case and one edge case (empty input, a very long string, an unknown key).
  - No change to `kube.go`, except to export nothing new. If a function cannot be tested without a change, say so in the pull request.
  - Coverage of the package goes above 20%.
- **Test:** `(cd services/console && go test -race -cover ./internal/backend/)`.

### 6. Tests for the Telegram bridge's start-up code

- **Area:** `kind/test`, `area/channels`. **Size:** M.
- **Gap:** `bridges/telegram/cmd/bridge` has 48.5% coverage, while the packages under `internal/` are above 80%. The command's setup code (reading configuration, wiring the parts, shutting down) is the part least covered.
- **Files:** `bridges/telegram/cmd/bridge/main.go` and its test file.
- **Do:** run `go test -coverprofile=c.out ./cmd/bridge/ && go tool cover -func=c.out` to see which functions are not covered. Add tests for the missing configuration and bad-value paths first. Use fakes. Do not call Telegram.
- **Acceptance:**
  - Coverage of `cmd/bridge` is above 70%.
  - No real token or chat id appears in the tests. Use made-up values.
  - The tests do not open the network.
- **Test:** `(cd bridges/telegram && go test -race -cover ./cmd/bridge/)`.

### 7. Render tests for the knowledge base tuning values

- **Area:** `kind/test`, `area/knowledge`, `area/install`. **Size:** S.
- **Gap:** the chart values `knowledge.kb.requestTimeout`, `ingestTimeout`, `queryEmbedTimeout`, `chunkMaxChars` and `chunkOverlap` are rendered into the kb Deployment as environment variables (see `charts/openagentix/templates/knowledge.yaml`, for example `KB_CHUNK_MAX_CHARS`). `charts/openagentix/tests/run.sh` never mentions them.
- **Files:** `charts/openagentix/tests/run.sh`.
- **Do:** with the knowledge base enabled (copy the way the existing `knowledge.kb` tests turn it on), render once with the defaults and once with `--set` for each value. Assert the environment variable in the kb container.
- **Acceptance:**
  - One assertion for the default value and one for an override, for each of the five values.
  - The new assertions fail if the template line is removed (delete the line, run the test, see it fail, restore it).
  - The default render is unchanged.
- **Test:** `make test-chart`.

### 8. Render tests for the Telegram bridge values

- **Area:** `kind/test`, `area/channels`, `area/install`. **Size:** S.
- **Gap:** `bridge.agentTimeout`, `bridge.agentNamespace`, `bridge.allowlist.secretKey`, `bridge.image.repository` and `bridge.image.pullPolicy` have no assertion in `charts/openagentix/tests/run.sh`. `bridge.agentTimeout` is rendered in `charts/openagentix/templates/bridge.yaml` only when it is set.
- **Files:** `charts/openagentix/tests/run.sh`.
- **Do:** follow the existing "bridge" assertions at the top of the file. Add a default and an override case for each value. For `agentTimeout`, test both "unset" (no env var) and "set".
- **Acceptance:**
  - Each of the five values has an assertion that fails if the template ignores the value.
  - The default render is byte-identical to before (the existing default tests still pass).
- **Test:** `make test-chart`.

### 9. Vitest tests for the console's planned-page text and toast store

- **Area:** `kind/test`, `area/console`. **Size:** S.
- **Gap:** in `console/src/lib/`, `planned.ts` (the "not available yet" page text and the splitter that turns backticks into code segments) and `toast.svelte.ts` (at most three toasts, errors stay until dismissed) have no test file, unlike most of their neighbours.
- **Files:** `console/src/lib/planned.ts`, `console/src/lib/toast.svelte.ts`, new `planned.test.ts` and `toast.test.ts`.
- **Do:** for `planned.ts`, test the segment splitter (no backticks, one pair, two pairs, an unmatched backtick) and check that every page has a non-empty title, notice, why and today. For the toast store, test the limit of three and that an error is not removed by its timer (use fake timers).
- **Acceptance:**
  - Both new test files pass and fail meaningfully if the code is changed (try one change).
  - `pnpm lint` and `pnpm check` stay clean.
- **Test:** `cd console && pnpm install --frozen-lockfile && pnpm test` (needs Node 22 and pnpm; `make test-console` runs lint and check too).

### 10. A README for the stub model service

- **Area:** `kind/docs`, `area/docs`. **Size:** S.
- **Gap:** every other service under `services/` has a `README.md`; `services/stub-model` does not. It is what makes the keyless quick start work, so a newcomer who finds it in the install output has nothing to read.
- **Files:** a new `services/stub-model/README.md`; a link from the repository map in `README.md` if the service is listed there.
- **Do:** read `services/stub-model/cmd/stub-model` and `internal/stub`. Say what it is, how its scripted answers are chosen, what it can and cannot do (it is not a model), how to run it locally (`go run ./cmd/stub-model`) and how to test it (`make test`). Copy the shape of `services/notify/README.md` in plain English.
- **Acceptance:**
  - Each command in the page was run, and the output shown is real.
  - The page says plainly that it makes no paid calls and is for tests and the quick start.
  - No em dashes, no marketing words.
- **Test:** run every command in the page. `(cd services/stub-model && make test)`.

### 11. One consistent wording for console empty states

- **Area:** `kind/chore`, `area/console`. **Size:** XS.
- **Gap:** empty-state titles in the console do not follow one pattern. `AgentRegistry.svelte` uses "No agents yet." (with a full stop) and "No agent matches" (singular, no full stop), `SchedulesPage.svelte` uses "No schedules are defined", `AccessPage.svelte` uses "The gate has no caller rule", and `GoTo.svelte` uses "Nothing matches.".
- **Files:** `console/src/lib/components/AgentRegistry.svelte`, `SchedulesPage.svelte`, `AccessPage.svelte`, `GoTo.svelte`, `OverviewPage.svelte`, and the tests that check the text (`govern-pages.test.ts` and any that `rg` finds).
- **Do:** pick one rule (for example: no full stop in a title, a sentence with a full stop in the body, plural nouns), write it as a comment above `EmptyState.svelte`, and change the strings and the tests that check them.
- **Acceptance:**
  - All titles follow the rule, and the rule is written next to the component.
  - Tests that check the old text are updated in the same pull request.
  - No screenshot or layout change.
- **Test:** `make test-console`. For the Playwright suite, see `make test-console-e2e`; it installs Chromium, so you may leave it to CI.

### 12. Fix the shellcheck warnings in the chart test script

- **Area:** `kind/chore`, `area/ci`. **Size:** S.
- **Gap:** this is a first slice of #57. `shellcheck -S warning` reports 23 findings across the tracked scripts, and 17 of them are in `charts/openagentix/tests/run.sh`. One file is a good size for one pull request.
- **Files:** `charts/openagentix/tests/run.sh`.
- **Do:** run `shellcheck -S warning charts/openagentix/tests/run.sh`. Fix each finding with a real change (quote a variable, check an exit code). Do not add `# shellcheck disable` lines unless you explain each one in a comment. Do not change what a test asserts.
- **Acceptance:**
  - `shellcheck -S warning charts/openagentix/tests/run.sh` prints nothing.
  - `make test-chart` prints the same `passed=` count as before and `failed=0`.
  - The pull request says `Refs #57`.
- **Test:** `shellcheck -S warning charts/openagentix/tests/run.sh && make test-chart`.

## Before you create the issues

- Check each candidate again against `main`. Some may have been done since 2026-11-26.
- Each issue should include the **Gap**, **Files**, **Acceptance** and **Test** parts above, and a link to the first contribution guide.
- Candidate 3 should wait for candidate 2. Candidate 12 is part of #57.
- Candidates 4 and 5 touch code that talks to the Kubernetes API. They only add tests, but a maintainer should still read the pull request with the security rules in mind.

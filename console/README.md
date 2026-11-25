# console (web app)

The Svelte single-page app of the OpenAgentix console (ADR 0007). It is built to static files and embedded in the Go service
`services/console`, which also serves its JSON API. Design contract: `docs/console/UI-SPEC.md`; visual reference:
`docs/console/mockup.html`. Third-party software and licences: `THIRD-PARTY.md`.

Stack: Svelte 5 (runes only), SvelteKit 3 with `@sveltejs/adapter-static` (SPA, `fallback: index.html`, `ssr = false`; SvelteKit 3 reads its
configuration from the `sveltekit({...})` call in `vite.config.ts`, there is no `svelte.config.js`), Vite 8,
TypeScript strict (no `any`), Tailwind 4 (`@theme` tokens of UI-SPEC section 3 and a `.dark` class), pnpm. No component kit.

## Dev loop

```sh
# terminal 1: the API with fake demo data (no cluster)
cd services/console && CONSOLE_DEV_FAKE=1 go run ./cmd/console      # http://127.0.0.1:8080, token demo-token
# terminal 2: the app with hot reload; Vite proxies /api to the Go service
cd console && pnpm install && pnpm dev                              # http://localhost:5173
```

The token is kept in memory: a reload asks for it again (on purpose).

## Scripts

| Command         | Does                                                                                                                       |
| --------------- | -------------------------------------------------------------------------------------------------------------------------- |
| `pnpm dev`      | Vite dev server                                                                                                            |
| `pnpm build`    | production build to `build/`, then `scripts/externalize-boot.mjs` (see "CSP")                                              |
| `pnpm check`    | `svelte-kit sync` and `svelte-check` (strict, warnings fail)                                                               |
| `pnpm test`     | Vitest, jsdom, Testing Library, axe-core (the YAML tests parse the output back with the `yaml` package)                    |
| `pnpm test:e2e` | Playwright (Chromium, one worker) against `go run ./cmd/console` in demo mode; needs `services/console/build-web.sh` first |
| `pnpm lint`     | `prettier --check` and `eslint` (flat config)                                                                              |
| `pnpm format`   | `prettier --write`                                                                                                         |

One-time for Playwright: `pnpm exec playwright install chromium`.

To embed the build in the Go binary: `services/console/build-web.sh`.

From the repository root: `make test-console` (install with the frozen lockfile, lint, check, vitest) and `make test-console-e2e`
(build the web app, install Chromium, run Playwright). CI runs the same as the jobs `console`, `console-audit` (`pnpm audit --prod`
blocks, the full `pnpm audit` is a report) and `console-e2e` (the Playwright report is uploaded when it fails). pnpm is pinned by
`packageManager` in `package.json`, with the hash of its tarball, so corepack and CI use exactly that version.

The `$lib` alias is set in `vite.config.ts` (`alias`). SvelteKit 3 calls it deprecated in favour of `#lib` subpath imports, which
cannot name the `.svelte.ts` modules without their extension; move when that is possible.

## Design rules (short)

- **Nothing invented.** Overview, Models, Tools, Skills, Memory and Governance show what `GET /api/v1/platform` and `GET /api/v1/agents`
  already return, read-only (`src/lib/views.ts` derives everything; no spend, counts from a job, or call numbers). Pages with no data
  source (Knowledge, Channels and triggers, Schedules, Traces, Costs, Playground) are honest "not available yet" pages
  (`src/lib/planned.ts`): what the page will show, why it is not available, where the thing is configured today. No sample data.
- **Two sidebar markers.** A lock: real data, read-only in this release. A dotted circle: no data source yet (`MARKS` in `src/lib/nav.ts`).
- **Refusals are predicted, not discovered.** The builder asks `POST /api/v1/agents/validate` while you type and shows a _prediction_;
  the controller's `status.violations` are shown word for word after save and are the authority.
- **The status contract** (ADR 0012): the UI reads `conditions` (Accepted and Ready are the contract), `observedGeneration`,
  `endpoint`, `revision`, `effectiveTools`, `effectiveEgress`, `violations`, `capabilities`, `agentRef`. `status.controller` is
  shown only in a collapsed "Controller details (internal)" section, as opaque key and value pairs; no code reads a named field of it.
- **Tokens.** Colours, type and spacing come from `src/app.css` (`@theme static` + `.dark`). Component classes (`.btn`, `.badge`,
  `.panel`, ...) are the mockup's. Status colours are used only for state, and never alone: every status has an icon and a word.
- **Accessibility.** Native controls where possible, visible focus, skip link, `g`+letter shortcuts (off in text fields and in Settings),
  focus trap and Escape in dialogs, sheet and drawer (the page behind an open one is `inert`, focus that a mouse click or a script moves
  out is pulled back, focus returns to the opener on close; `src/lib/actions.ts`), axe-core in the component tests.
- **Bounded.** The registry says "Showing the first N agents of each kind" when the API cut the list. The live check is debounced
  (600 ms) and the API limits it per minute. The token field is a password field with a show and hide button.
- **What it does not edit, it keeps.** A definition with fields the form does not know (`instructionsFrom`, a field of a later release)
  opens with a notice; the instructions of an `instructionsFrom` definition are read-only; a save leaves the other fields as they are.
- **Style.** 4-space indent, single quotes, semicolons (Prettier). Svelte runes only. No inline `style=`.

## CSP

The Go service sends `Content-Security-Policy: default-src 'self'; ...; style-src 'self'` with no `unsafe-inline`. So:

- no inline styles: no `style="..."`, no `style:` directive (Svelte sets those through `cssText`, which the policy blocks); widths and
  similar are classes. Tailwind writes one external stylesheet (`inlineStyleThreshold: 0`).
- no inline scripts: `scripts/externalize-boot.mjs` moves SvelteKit's start-up script out of `index.html` into a file and fails the
  build if anything inline is left. The theme script is the static file `static/theme-init.js`.
- SvelteKit's route announcer carries an inline style; `vite.config.ts` swaps it for a class (and fails loudly if SvelteKit changes it).
- the e2e tests listen for `securitypolicyviolation` events and console errors on every flow.

## Layout

```
src/app.css                 tokens, component classes
src/lib/types.ts            the API's JSON, by hand
src/lib/api.ts              the one API client (bearer token, 401, error sentences)
src/lib/draft.ts            builder logic with no DOM (limits, policy options, secret scan, sentence-to-field mapping)
src/lib/components/         own small component set; AgentRegistry, AgentBuilder, AppShell
src/routes/                 one route per navigation entry
e2e/                        Playwright
```

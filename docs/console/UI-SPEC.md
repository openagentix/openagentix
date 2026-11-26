# OpenAgentix console: UI design contract

Status: draft for review (2026-11-25). Owner of the decisions behind it: [ADR 0007](../decisions/0007-control-plane-and-agent-builder.md) ("Scope", "AgentDefinition", "Console"), [ADR 0008](../decisions/0008-model-routing-and-gateways.md), [ADR 0009](../decisions/0009-finops-and-agent-tracing.md), [ADR 0010](../decisions/0010-community-and-enterprise-editions.md).

This page is the contract between design and the Svelte build. The static mockup (`console-mockups/index.html`, published as a web page for review) is the visual reference. When the two disagree, this page wins and the mockup is fixed.

Words used here:

- **Built agent**: an `AgentDefinition` written through the console, `kubectl` or Git.
- **Chart agent**: an entry of `agents[]` in chart values. Read-only in the console.
- **Read-only page**: a page whose resource kind does not exist yet (ADR 0007 table). It shows real data, and says why it cannot be edited.

---

## 1. Product principles

1. **Nothing invented.** Every number, name and state on screen comes from the cluster: a resource, the catalog, the policy or a metric. If the source is missing, the page says which source is missing. We never show sample numbers, placeholder charts or "coming soon" mock content inside the product.
2. **Status is always explained.** A badge never stands alone. Next to every non-ready state there is the condition reason and its message in one plain sentence, and the next step when there is one.
3. **Refusals are predicted, not discovered.** The builder checks a draft against the catalog and the policy while you type, with the same rules as the controller. A choice the policy forbids is shown disabled, with the reason. The controller stays the authority: its `violations` are shown word for word after save.
4. **YAML is one click away.** Every resource page has "View YAML". What you see in a form is exactly what is in the resource. The console writes the same resource that `kubectl` and Git write, nothing else.
5. **Read-only is a finished state, not a broken one.** Pages for kinds that do not exist yet look complete, show real data, and say in one sentence where that configuration lives today (for example "`gateway.models` in chart values").
6. **Secrets are write-only.** A credential is entered once and never shown again. The console shows only that it exists and when it was set.
7. **Dense, calm, keyboard-first.** Platform engineers scan tables. Default row height is compact, one accent colour, no decoration that carries no data, and every action reachable from the keyboard.

---

## 2. Identity

### Name treatment

- Product name: **OpenAgentix**, one word, capital O and A. Never "Open Agentix", never "OAX".
- In the sidebar header: a small square mark followed by the wordmark. The mark is a 20 px square, radius 5 px, filled with the accent, holding a white glyph of two nodes joined by a short link (a gate between two points). No gradient, no glow.
- Wordmark: "Open" in text-2 weight 500, "Agentix" in text-1 weight 650, no space. Set in the sans face, 15 px.
- Under the wordmark, in mono 11 px text-3: the cluster context (for example `kind-openagentix · kagent`).
- Edition label in Settings and the About dialog only: "Community edition". Never in the main navigation (ADR 0010: the community edition is complete, not a trial).

### Tone

Plain, exact, a little dry. The console talks like a careful colleague in a runbook: it says what happened, what it means and what to do. No exclamation marks, no "Oops", no praise, no emoji. Use the platform's own words (tool profile, gate caller, fact set) and explain each once in a hint.

### Visual direction: "instrument panel"

A calm control surface for infrastructure people. Cool mineral greys with a faint blue-green bias, one petrol-blue accent used only for interaction and focus, and status colours that are reserved for state. Every resource identifier (names, kinds, origins, tool names, digests, trace ids) is set in the mono face, so the eye can tell "words about a thing" from "the thing itself".

Two signature elements carry the identity, and nothing else needs to:

- **The condition rail.** Four small cells in a row, one per condition of an `AgentDefinition` (`Accepted`, `KeyReady`, `Applied`, `Ready`). Each cell takes its status colour and has its own icon and label. In tables it shrinks to four 8 px pips with a tooltip. It shows at a glance where a definition stopped.
- **The resource strip.** Every page header carries, in mono 12 px text-3, the resource kind and API group it reads or writes (`AgentDefinition · openagentix.io/v1alpha1`), or the upstream source for read-only pages (`chart values · gateway.models`). It tells an engineer exactly what the page is backed by.

Rules that keep it restrained: no purple, no gradients, no glassmorphism, no illustrations of robots or sparkles, no large hero areas. Radius is small (4 to 10 px). Shadows only on things that float (menus, side panels on narrow screens, dialogs, toasts).

---

## 3. Design tokens

### 3.1 Colour roles

Contrast ratios are WCAG 2 relative-luminance ratios, measured for the pair named. Text pairs are all at least 4.5:1. Non-text boundaries of controls are at least 3:1.

| Token | Role | Light | Dark | Contrast (pair) |
|---|---|---|---|---|
| `canvas` | page background behind panels | `#F1F3F5` | `#0D1115` | |
| `surface` | panels, tables, cards | `#FFFFFF` | `#151B21` | |
| `surface-sunken` | inputs, code blocks, table header | `#F6F7F9` | `#11161B` | |
| `surface-raised` | menus, popovers, dialogs | `#FFFFFF` | `#1B232B` | |
| `sidebar` | navigation column | `#E9EDF0` | `#10151A` | |
| `hover` | row and item hover | `#EEF1F4` | `#1C242C` | |
| `selected` | selected row, active nav item | `#E4F0F5` | `#10242D` | |
| `text-1` | primary text | `#121A22` | `#E5EAEF` | 17.6 / 14.3 on surface |
| `text-2` | secondary text, labels | `#3C4854` | `#B3BECA` | 9.4 / 9.2 on surface |
| `text-3` | hints, metadata, axis labels | `#5B6774` | `#8C99A6` | 5.8 / 6.0 on surface; 4.9 / 6.5 on sidebar and canvas |
| `border` | dividers, card edges | `#DDE2E7` | `#252E37` | decorative |
| `border-control` | input, select, checkbox edges | `#7D8A97` | `#64727F` | 3.5 / 3.5 on surface |
| `accent` | links, primary button, focus, selected tab | `#0A6283` | `#5DB8DB` | 6.8 / 7.7 on surface |
| `on-accent` | text on accent fill | `#FFFFFF` | `#071319` | 6.8 / 8.4 |
| `accent-soft` | accent tint behind text | `#E4F0F5` | `#10242D` | accent text 5.9 / 7.1 on it |
| `focus-ring` | 2 px outline, 2 px offset | `#0A6283` | `#5DB8DB` | |

Status colours. Each status has a text colour (`fg`) and a tint (`bg`). Badges use `fg` on `bg`; dots and rail cells use `fg` as a fill. Status colour is never used for anything else, and never alone: every status has an icon and a word.

| Status | Meaning | Light fg / bg | Dark fg / bg | Contrast light / dark | Icon |
|---|---|---|---|---|---|
| `ready` | condition True, agent answers | `#13653A` / `#E3F3E9` | `#71D59D` / `#11271B` | 6.2 / 8.8 | filled circle with check |
| `pending` | working, waiting, unknown | `#855000` / `#FCF0D6` | `#F0B65A` / `#2B2110` | 5.9 / 8.7 | half-filled circle |
| `refused` | refused by policy (`Accepted=False`) | `#9A1B57` / `#FAE6EF` | `#F28DBE` / `#2D1522` | 6.6 / 7.5 | circle with a bar (no entry) |
| `error` | failed apply, key, runtime error | `#B0261C` / `#FCE9E6` | `#FF8F84` / `#301614` | 5.7 / 7.6 | triangle with exclamation |
| `paused` | suspended schedule, disabled, read-only | `#46525F` / `#ECEFF2` | `#A9B4C0` / `#1F272F` | 6.9 / 7.2 | two vertical bars |

"Refused" and "error" are different on purpose. Refused means the platform said no to what you asked, and you can fix the definition. Error means something broke while doing what was allowed.

Chart colours (categorical, fixed order, never cycled). From the reference palette of the dataviz method, validated with its script for all pairs in both themes: light worst CVD ΔE 9.2, normal-vision ΔE 24.0; dark worst CVD ΔE 9.4, normal-vision ΔE 20.9. Light `chart-3` is below 3:1 on the surface, so every chart that uses it ships direct labels or a table view.

| Token | Light | Dark |
|---|---|---|
| `chart-1` | `#2A78D6` | `#3987E5` |
| `chart-2` | `#EB6834` | `#D95926` |
| `chart-3` | `#1BAF7A` | `#199E70` |
| `chart-grid` | `#E6EAEE` | `#222B33` |

More than three series fold into "Other" or become small multiples.

### 3.2 Typography

- **Sans: Public Sans** (SIL Open Font License), weights 400, 500, 600, 650 (variable). Fallback: `system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif`.
- **Mono: JetBrains Mono** (SIL Open Font License), weights 400 and 500. Fallback: `ui-monospace, "SF Mono", Menlo, Consolas, "Liberation Mono", monospace`.
- Both fonts are bundled as `woff2` files in the static build and served by `services/console`. The console makes no request to a font host (CSP is same-origin only). If the files are missing, the fallback stacks render without layout breakage.
- Numbers in tables, tiles and waterfalls use `font-variant-numeric: tabular-nums`.

| Token | Size / line height | Weight | Use |
|---|---|---|---|
| `text-xs` | 11 / 16 | 500 | rail labels, uppercase group labels (letter-spacing 0.06em) |
| `text-sm` | 12 / 18 | 400 | metadata, hints, table secondary text, mono identifiers in tables |
| `text-base` | 13.5 / 20 | 400 | body, table cells, form values (the console default) |
| `text-md` | 15 / 22 | 600 | panel titles, card titles |
| `text-lg` | 18 / 26 | 650 | page titles |
| `text-xl` | 24 / 30 | 600 | stat tile values |
| `text-2xl` | 30 / 36 | 600 | one hero number per page, at most |
| `mono-sm` | 12 / 18 | 400 | identifiers, YAML, code |

### 3.3 Spacing, radius, shadow, motion

Spacing is a 4 px scale: `1`=4, `2`=8, `3`=12, `4`=16, `5`=20, `6`=24, `8`=32, `10`=40, `12`=48. Panel padding is 16; page gutter 24 (16 below 640 px); gap between cards 12; table cell padding 8 by 12; control height 32 (28 in dense table toolbars).

| Token | Value | Use |
|---|---|---|
| `radius-sm` | 4 px | badges, tags, checkboxes, rail cells |
| `radius-md` | 6 px | buttons, inputs, selects |
| `radius-lg` | 10 px | cards, panels, dialogs |
| `radius-full` | 999 px | switch track, avatar |
| `shadow-sm` | `0 1px 2px rgb(16 24 32 / 0.06)` | cards on hover only |
| `shadow-md` | `0 6px 20px rgb(16 24 32 / 0.10), 0 1px 3px rgb(16 24 32 / 0.08)` | menus, popovers, overlay side panel |
| `shadow-lg` | `0 18px 48px rgb(16 24 32 / 0.18)` | dialogs |

In dark mode shadows use `rgb(0 0 0 / 0.5)` and raised surfaces get a 1 px `border` edge, because shadows read poorly on dark.

| Token | Value | Use |
|---|---|---|
| `duration-fast` | 120 ms | hover, press, switch thumb |
| `duration-base` | 180 ms | tabs, menus, toasts |
| `duration-slow` | 260 ms | side panel and drawer slide |
| `ease-standard` | `cubic-bezier(0.2, 0, 0, 1)` | everything |

Reduced motion: under `prefers-reduced-motion: reduce` every transition and animation is 0.01 ms, slides become fades, skeleton shimmer stops (static tint), and no element moves on its own. Nothing in the console animates in a loop except a pending spinner, which becomes a static half-filled circle.

### 3.4 Tailwind 4 `@theme` block

Put this in `src/app.css`. Light values are the defaults; the `.dark` class on `<html>` swaps them. The theme follows the system setting until the user picks one (stored in `localStorage` as `oa-theme`; the only thing the console stores in the browser besides the in-memory token).

```css
@import "tailwindcss";

@custom-variant dark (&:where(.dark, .dark *));

@font-face { font-family: "Public Sans"; src: url("/fonts/PublicSans-Variable.woff2") format("woff2"); font-weight: 100 900; font-display: swap; }
@font-face { font-family: "JetBrains Mono"; src: url("/fonts/JetBrainsMono-Variable.woff2") format("woff2"); font-weight: 100 800; font-display: swap; }

@theme {
  /* type */
  --font-sans: "Public Sans", system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
  --font-mono: "JetBrains Mono", ui-monospace, "SF Mono", Menlo, Consolas, "Liberation Mono", monospace;
  --text-xs: 11px;   --text-xs--line-height: 16px;
  --text-sm: 12px;   --text-sm--line-height: 18px;
  --text-base: 13.5px; --text-base--line-height: 20px;
  --text-md: 15px;   --text-md--line-height: 22px;
  --text-lg: 18px;   --text-lg--line-height: 26px;
  --text-xl: 24px;   --text-xl--line-height: 30px;
  --text-2xl: 30px;  --text-2xl--line-height: 36px;

  /* spacing base: Tailwind multiplies this (p-4 = 16px) */
  --spacing: 4px;

  /* radius */
  --radius-sm: 4px; --radius-md: 6px; --radius-lg: 10px;

  /* shadow */
  --shadow-sm: 0 1px 2px rgb(16 24 32 / 0.06);
  --shadow-md: 0 6px 20px rgb(16 24 32 / 0.10), 0 1px 3px rgb(16 24 32 / 0.08);
  --shadow-lg: 0 18px 48px rgb(16 24 32 / 0.18);

  /* motion */
  --ease-standard: cubic-bezier(0.2, 0, 0, 1);
  --duration-fast: 120ms; --duration-base: 180ms; --duration-slow: 260ms;

  /* breakpoints */
  --breakpoint-sm: 640px; --breakpoint-md: 900px; --breakpoint-lg: 1200px; --breakpoint-xl: 1500px;

  /* colour roles, light */
  --color-canvas: #F1F3F5;
  --color-surface: #FFFFFF;
  --color-surface-sunken: #F6F7F9;
  --color-surface-raised: #FFFFFF;
  --color-sidebar: #E9EDF0;
  --color-hover: #EEF1F4;
  --color-selected: #E4F0F5;
  --color-text-1: #121A22;
  --color-text-2: #3C4854;
  --color-text-3: #5B6774;
  --color-border: #DDE2E7;
  --color-border-control: #7D8A97;
  --color-accent: #0A6283;
  --color-on-accent: #FFFFFF;
  --color-accent-soft: #E4F0F5;

  --color-ready: #13653A;    --color-ready-bg: #E3F3E9;
  --color-pending: #855000;  --color-pending-bg: #FCF0D6;
  --color-refused: #9A1B57;  --color-refused-bg: #FAE6EF;
  --color-error: #B0261C;    --color-error-bg: #FCE9E6;
  --color-paused: #46525F;   --color-paused-bg: #ECEFF2;

  --color-chart-1: #2A78D6; --color-chart-2: #EB6834; --color-chart-3: #1BAF7A; --color-chart-grid: #E6EAEE;
}

/* colour roles, dark: same names, so utilities like bg-surface switch with the class */
.dark {
  color-scheme: dark;
  --color-canvas: #0D1115;
  --color-surface: #151B21;
  --color-surface-sunken: #11161B;
  --color-surface-raised: #1B232B;
  --color-sidebar: #10151A;
  --color-hover: #1C242C;
  --color-selected: #10242D;
  --color-text-1: #E5EAEF;
  --color-text-2: #B3BECA;
  --color-text-3: #8C99A6;
  --color-border: #252E37;
  --color-border-control: #64727F;
  --color-accent: #5DB8DB;
  --color-on-accent: #071319;
  --color-accent-soft: #10242D;

  --color-ready: #71D59D;    --color-ready-bg: #11271B;
  --color-pending: #F0B65A;  --color-pending-bg: #2B2110;
  --color-refused: #F28DBE;  --color-refused-bg: #2D1522;
  --color-error: #FF8F84;    --color-error-bg: #301614;
  --color-paused: #A9B4C0;   --color-paused-bg: #1F272F;

  --color-chart-1: #3987E5; --color-chart-2: #D95926; --color-chart-3: #199E70; --color-chart-grid: #222B33;
  --shadow-md: 0 6px 20px rgb(0 0 0 / 0.5);
  --shadow-lg: 0 18px 48px rgb(0 0 0 / 0.6);
}

@media (prefers-reduced-motion: reduce) {
  *, *::before, *::after { transition-duration: 0.01ms !important; animation-duration: 0.01ms !important; animation-iteration-count: 1 !important; }
}

html { background: var(--color-canvas); color: var(--color-text-1); font-family: var(--font-sans); font-size: var(--text-base); }
```

---

## 4. Layout

### 4.1 App shell

```
+-----------+-----------------------------------------------------------+
| sidebar   | top bar: breadcrumb · search (/) · context · theme · menu |
| 240 px    +-----------------------------------------------------------+
| (56 px    | page header: title · resource strip · status · actions    |
| collapsed)|                tabs (when the page has them)              |
|           +-------------------------------------------+---------------+
|           | main content (min 0, scrolls)             | detail panel  |
|           |                                           | 380 px        |
+-----------+-------------------------------------------+---------------+
| footer line inside main: edition · version · marker legend            |
```

- CSS grid: `grid-template-columns: var(--sidebar-w) minmax(0, 1fr)`. The top bar is sticky inside the main column. Only the main column scrolls.
- Content max width: none for tables and graph; 1180 px for forms and reading pages, left-aligned (not centred).

### 4.2 Sidebar

Groups, in this order. Group labels are uppercase `text-xs`. Items have a 16 px icon and a label. A page can carry one of two markers after its label, and they mean different things. The **lock** marks a page that shows real data and cannot edit it in this release (Skills, Models, Tools, Memory, Governance); its tooltip is "Read-only in this release". A **dotted circle** marks a page that has no data source yet (Knowledge, Channels and triggers, Schedules, Traces, Costs); its tooltip is "No data source yet". Overview and Agents carry no marker. The footer line spells out both: "read-only in this release" and "no data source yet".

| Group | Item | Sub-items (shown when the item is active) |
|---|---|---|
| (none) | Overview | |
| Build | Agents | Registry, Playground |
| Build | Skills | |
| Connect | Models | Providers and routes, Keys and budgets |
| Connect | Tools | MCP servers, Tool profiles |
| Connect | Knowledge | Collections, Sources, Graph |
| Connect | Channels and triggers | |
| Connect | Schedules | |
| Operate | Traces | |
| Operate | Costs | |
| Operate | Memory | |
| Govern | Governance | Policy, Gate callers, Egress |
| (bottom) | Settings | |

The builder is not a navigation item: it opens from the registry (row click or "New agent") and keeps "Agents" active.

Behaviour:

- **Expanded** (default at 1200 px and wider): 240 px.
- **Collapsed** (user choice, or 900 to 1199 px by default): 56 px icon rail. Group labels become 1 px dividers. Each icon has a tooltip with the label, shown on hover and on keyboard focus. Toggle with the button at the bottom of the sidebar or `[`. The choice is remembered in `localStorage` (`oa-sidebar`).
- **Mobile** (below 900 px): the sidebar is an off-canvas drawer, opened from a menu button in the top bar. It traps focus, closes on Escape, on selection and on a click on the scrim.

### 4.3 Page header pattern

One block, same everywhere:

1. Breadcrumb in the top bar (`Agents / researcher`).
2. Title (`text-lg`), then on the same line the status badge when the page is one resource.
3. Resource strip (mono `text-sm` text-3): kind and group, or the upstream source.
4. Actions on the right: at most one primary button; others are secondary or in a "More" menu. "View YAML" is always a secondary button where a resource exists.
5. Tabs under it, when the page has tabs (segmented tabs, section 5).
6. For read-only pages, a **read-only notice** directly under the header (section 5, "Notice").

### 4.4 List plus detail panel

Used by Tools, Knowledge, Skills, Models, Channels, Schedules.

- At 1200 px and wider the detail panel is a third column, 380 px, with its own scroll. Selecting a card or row fills it; the selection stays visible (selected tint and a 2 px accent edge on the left of the card).
- From 900 to 1199 px the panel overlays the content from the right with `shadow-md`, and has a close button.
- Below 900 px the panel is a full-height sheet.
- The panel URL is part of the route (`/tools/servers/osv`), so a selected item can be linked and the Back button closes it.
- Nothing selected: the panel shows a short hint ("Select a server to see its tools and who uses them"), not an empty box.

### 4.5 Breakpoints

| Name | Width | What changes |
|---|---|---|
| base | < 640 | one column; cards one per row; tables scroll inside their own container; page gutter 16 |
| `sm` | ≥ 640 | cards two per row |
| `md` | ≥ 900 | sidebar becomes visible (collapsed by default); builder switches to two columns |
| `lg` | ≥ 1200 | sidebar expanded; detail panel docks as a column |
| `xl` | ≥ 1500 | cards up to four per row; traces list and waterfall side by side |

---

## 5. Component inventory

Every interactive component has a visible focus state: a 2 px `focus-ring` outline with 2 px offset, never removed. Disabled controls keep 3:1 on their boundary and carry the reason in a tooltip or hint, never just a grey look.

| Component | Variants and states | Accessibility |
|---|---|---|
| **Button** | primary (accent fill), secondary (surface, `border-control` edge), ghost (text only), danger (error colour, used only inside the delete dialog). States: default, hover, active, focus, disabled, busy (spinner replaces icon, label stays, width fixed). Sizes 32 and 28 px. | Native `<button>`. Busy sets `aria-busy="true"` and `aria-disabled`, keeps focus. A disabled button that has a reason uses `aria-disabled="true"` (stays focusable) plus `aria-describedby` to the reason. |
| **Icon button** | same as ghost button, 32 by 32, 16 px icon | `aria-label` is required. Tooltip shows the same text on hover and focus. |
| **Field** | label above, control, hint or counter below, error message below. States: default, focus, invalid, disabled, read-only (looks like text on `surface-sunken`, no edge). | `<label for>`. Hint and error linked with `aria-describedby`. Invalid sets `aria-invalid="true"`. The error is text, with an icon, not colour alone. |
| **Textarea** | auto-grows to 24 rows, then scrolls; counter shows bytes or characters against the limit (`1,284 / 16,384 bytes`) | Counter is `aria-live="polite"` only when within 10% of the limit. |
| **Select** | native `<select>` styled, or a listbox when options need a second line (reason). Disabled options show the reason in the second line. | Native select where possible. Custom listbox follows the WAI-ARIA listbox pattern: arrow keys, Home, End, type-ahead, `aria-disabled` options stay readable. |
| **Switch** | on, off, disabled with reason, busy | `<button role="switch" aria-checked>`. The label is the setting ("Knowledge"), never "On/Off". Space toggles. |
| **Checkbox** | checked, unchecked, indeterminate, disabled with reason | Native `<input type="checkbox">`. Groups in a `<fieldset>` with `<legend>`. |
| **Segmented tabs** | page tabs (underline style, accent 2 px underline on the active tab) and segmented control (pill group for filters) | Tabs: `role="tablist"`, `tab`, `tabpanel`, arrow keys move, automatic activation. Segmented filter: a radio group. |
| **Table** | sortable header (arrow shows direction), row hover, selected row, sticky header, compact density. States: loading (5 skeleton rows), empty (empty state inside the table frame), error (error notice inside the frame with Retry). | Real `<table>`. Sortable headers are buttons inside `<th>` with `aria-sort`. A clickable row has one real link in its first cell; the row click is a convenience. |
| **Card** | default, hover (`shadow-sm`), selected (selected tint, 2 px left accent edge), disabled | A card that opens something is one `<a>` or `<button>` wrapping the title; nested controls are not allowed. |
| **Status badge** | ready, pending, refused, error, paused; sizes regular and small (dot plus word) | Icon plus word, always. `title` gives reason. Not a live region; changes are announced by the page's status region. |
| **Condition rail** | four cells: `Accepted`, `KeyReady`, `Applied`, `Ready`. Each cell: True (ready), False (refused for `Accepted`, error or pending for others by reason), Unknown (pending), not reached yet (empty outline). Compact form: four pips. | `role="list"`; each cell `role="listitem"` with text "Applied: False, ApplyFailed". Pips have a tooltip and an `aria-label` on the group. |
| **Tag** | neutral (mono, for identifiers), accent (selected filter), removable (with a close button) | Removable tag: the close button has `aria-label="Remove https://api.osv.dev"`. |
| **Side panel** | docked, overlay, sheet (section 4.4) | Docked: a `<aside>` landmark with a heading. Overlay and sheet: `role="dialog"`, `aria-modal="true"` when it traps focus, Escape closes, focus returns to the opener. |
| **Dialog** | confirm, destructive confirm (type the name), form | `role="dialog"` (or `alertdialog` for destructive), labelled by its title, focus starts on the first field or the safe action, Escape cancels. |
| **Toast** | success, info, error; at most 3; bottom right; auto-dismiss after 6 s except error | Region `role="status"` (`role="alert"` for errors). Never the only place an error is shown: the page shows it too. Pauses on hover and focus. |
| **Code / YAML viewer** | read-only, line numbers, mono, copy button, wrap toggle, "changed" gutter marks when comparing draft with live | `<pre><code>` with `tabindex="0"` so it can scroll by keyboard. Copy button announces "Copied" via the toast region. Syntax colours use text tokens plus accent only. |
| **Key-value list** | two columns (label text-3, value text-1), mono values for identifiers, empty value shown as "None" in text-3 | `<dl>`, `<dt>`, `<dd>`. |
| **Notice** | info (accent-soft), read-only (paused tint, lock icon), refused (refused tint), error (error tint). Title line, one or two sentences, optional action. | `role="status"` for info and read-only, `role="alert"` for errors that appear after an action. |
| **Empty state** | icon 24 px, one-line title, one sentence of why, one action or one command | Heading level fits the page. The command is in a code viewer with copy. |
| **Skeleton** | text line, table row, card, tile | `aria-hidden="true"`; the container has `aria-busy="true"` and a visually hidden "Loading". Shimmer off under reduced motion. |
| **Stat tile** | label, value (`text-xl`), unit, comparison line, optional sparkline | The value and its unit read as one string ("1.28 US dollars, last 7 days"). |
| **Bar chart / sparkline** | stacked columns up to 3 series, 2 px surface gap between segments, ≤ 24 px bars, rounded data end; sparkline 2 px line with an end dot | Every chart has a "Show table" toggle and a text summary (`aria-describedby`). Hover tooltip and keyboard focus per column. Legend always for two or more series. |
| **Trace waterfall** | rows of spans: name, kind icon (gate, agent, model, tool, memory, knowledge), bar on a shared time axis, duration, tokens and cost on model spans. Collapsible children. Selected span shows attributes in the detail panel. | A `treegrid`: arrow keys move, Right and Left expand and collapse, Enter selects. Each row reads "generate_content, claude-haiku-5-5, starts 1.60 s, lasts 1.60 s, 0.00170 US dollars". |
| **Graph canvas** | SVG, entities as rounded labels with a type glyph, relations as lines with a predicate label; the path in focus drawn in accent with numbered hops; zoom and pan; curated facts drawn with a dashed edge and a "curated" tag | The canvas has `role="img"` with a summary, and the path panel next to it is the accessible version: an ordered list of hops, each with its source document. Tab moves through entities in path order. Plus and minus keys zoom. |

---

## 6. Pages

Editable means the console writes the resource. The column follows the ADR 0007 table.

| Page | Route | Editable in first release | Source |
|---|---|---|---|
| Overview | `/` | no (summary page) | all of the below |
| Agents, registry | `/agents` | yes (create, delete built agents) | `AgentDefinition`, chart `agents[]` |
| Agents, builder | `/agents/<name>` | yes | `AgentDefinition`, catalog, policy |
| Playground | `/agents/playground` | yes (sends messages) | A2A gate, caller `console` |
| Skills | `/skills` | read-only until `Skill` | catalog `skills` map |
| Models | `/models` | read-only until `ModelProvider`, `ModelRoute` | gateway resources, metrics |
| Tools | `/tools` | read-only until `ToolServer`, `ToolProfile` | ToolHive resources, catalog profiles |
| Knowledge | `/knowledge` | read-only until `KnowledgeCollection`, `KnowledgeSource` | kb service |
| Channels and triggers | `/channels` | read-only until `Channel`, `Trigger` | Kourier resources, bridge settings |
| Schedules | `/schedules` | read-only until `Schedule` | CronJobs in `openagentix-schedules` |
| Memory | `/memory` | settings are edited in the builder; page is read-only | catalog, `memory-expiry` CronJob |
| Governance | `/governance` | never in community 0.3 (operator-owned) | policy ConfigMap, gate caller rules |
| Traces | `/traces` | not applicable | Observability adapter (Jaeger) |
| Costs | `/costs` | not applicable until `Budget` | gateway metrics (VictoriaMetrics) |
| Settings | `/settings` | partly (theme, sidebar; console token is rotated by the installer) | console, catalog adapters |

### Shared states

Every page defines these. Wording is fixed here so pages stay consistent.

- **Loading:** skeletons in the shape of the content. No spinner on a whole page. After 8 s a line appears: "Still waiting for the console API."
- **Empty:** says what would be here and how it gets here. Example: "No built agents yet. Create one here, or apply an `AgentDefinition` with kubectl."
- **Error (source unreachable):** notice with what failed and the next step. Example: "Could not read traces: the observability adapter returned 503 from Jaeger. Check that `observability.enabled` is true and the Jaeger pod is running." Plus Retry.
- **Source not installed:** for an optional component that is off. Example: "Knowledge is not installed on this platform (`knowledge.enabled` is false in chart values)." No Retry, no fake content.
- **Read-only:** the notice "Read-only until the `ModelProvider` and `ModelRoute` kinds exist. Today models are set in chart values under `gateway.models`; change them there and run `install.sh`." Edit controls are not shown at all on read-only pages (no greyed-out Save).
- **Refused by policy:** only on pages that write. Shown as a refused notice with the controller's sentences, word for word, as a list.

### 6.1 Overview

Purpose: one look at whether the platform is healthy. In this release the page shows only what the console API reads (the agents list, the platform catalog and the policy). Spend, turns and recent changes come with the observability adapter and are not shown, not even as zeros; one calm line says so.

- Tiles: Agents (count, split ready / pending / refused / paused, and how many are chart-managed), Definitions used against `maxAgents` ("3 of 5"), Needs attention (a count), Chart-managed. Spend today and Turns in the last 24 hours come back with the observability adapter.
- "Needs attention": definitions not Ready, with reason; schedules whose last run failed; components that are off but referenced.
- Platform: active adapters from the catalog (`runtime: kagent`, `modelGateway: agentgateway`, `tools: toolhive`), optional components and whether each is on (knowledge, graph, memory with expiry, notify, channels, schedules, observability, A2A gate).
- Recent changes: last definition events (created, accepted, refused, ready) with time.
- Empty state for spend when observability is off: "Spend is not available: observability is off (`observability.enabled: false`)."

### 6.2 Agents, registry

Purpose: every agent in one table, built or chart-managed.

- Columns: Name (mono, link), Status badge, Conditions (compact rail), Model, Tool profile, Capabilities (icons for knowledge, notify, memory, skills count, egress count), Source (`console` / `kubectl` show as "Built", chart agents as "Chart"), Updated.
- Toolbar: search by name, segmented filter All / Built / Chart, status filter, "New agent" (primary). A quiet line on the right: "3 of 5 definitions used (policy `maxAgents: 5`)". When the limit is reached, "New agent" is disabled with the reason "The platform policy allows at most 5 agents and 5 already exist."
- Row of a chart agent: a "Chart" tag and, on open, a read-only builder with the notice "This agent comes from chart values (`agents[]`). Change it in your values file and run `install.sh`."
- Refused row: the badge plus the first violation sentence in text-3 under the name.
- Delete: from the row menu or the builder, built agents only (section 6.3).
- Empty: "No agents yet." with "New agent" and the kubectl line.

### 6.3 Agents, builder

Tabs: **Build**, **Playground**, **Deploy**. Header: name, status badge, condition rail (full form), resource strip `AgentDefinition · openagentix.io/v1alpha1 · kagent`, actions "View YAML", "Delete", primary "Save" ("Create agent" for a new one).

Layout at `md` and wider: two columns. Left (form, 3/5): identity and instructions. Right (capabilities, 2/5): model and everything the agent may use, then the policy summary. Below both: Status.

Field by field:

| UI | Field | Control | Rules and messages |
|---|---|---|---|
| Name | `metadata.name` | text, mono; locked after create (shown read-only with "Names cannot change; create a new agent instead") | DNS label, at most 40 characters. Live check against reserved names from catalog and policy: "assistant is reserved (chart agents and platform services own it)". |
| Namespace | `metadata.namespace` | read-only value `kagent` with hint "Only the kagent namespace is reconciled in v1alpha1" | |
| Description | `spec.description` | single-line text, counter `0 / 256` | at most 256 characters |
| Instructions | `spec.instructions` | textarea, sans, counter in bytes `0 / 16,384 bytes` | required. Live secret-shape scan with the same ten patterns as the controller: "Instructions contain something shaped like a secret (bearer token); remove it." The matched span is underlined in error colour. |
| Added instructions preview | (computed) | collapsed disclosure "Prompts the platform adds" listing the knowledge, notify and memory prompt paragraphs from the catalog that this draft would add | read-only, so the author sees the whole system prompt |
| Model | `spec.model` | select of catalog models; models the policy does not allow are disabled with "Not allowed by the platform policy" | required |
| Tool profile | `spec.toolProfile` | select of catalog profiles plus "None". "None" is disabled when `requireToolProfile` is true: "The platform policy requires a toolProfile." Profiles not in `allowedProfiles` disabled with the reason. | |
| Tools | `spec.tools` | checklist of the tools the selected profile offers (from the catalog), with server prefix shown dimmed (`osv_` `query_vulnerability`). `execute_tool_script` labelled "Code mode" with a hint. | each must be offered by the profile; the list cannot contain other names in the UI. A definition applied with kubectl that lists other names shows them as checked, refused rows with the violation. |
| Knowledge | `spec.knowledge` | switch | Disabled with reason when `allowKnowledge` is false ("Not allowed by the platform policy") or `knowledge.available` is false ("Knowledge is not installed on this platform"). When on, the hint lists the tools it adds. If the profile does not offer them all, the predicted violation shows under the switch before save. |
| Notify | `spec.notify` | switch | Same pattern with `allowNotify` and `notify.available`. Hint: "The agent can send a message to a named destination when a task asks it to." |
| Memory | `spec.memory.enabled`, `spec.memory.ttlDays` | switch, then number field "Keep memories for N days" with the policy maximum as the field max and in the hint ("1 to 30 days, platform maximum"); empty means the catalog default (15) | Disabled with reason when memory is not allowed, not installed, or the expiry job is off while the policy requires it: "The memory expiry job is off, so the time limit would not be enforced; memory is refused until an operator turns it on." |
| Skills | `spec.skills` | checklist of catalog skills; skills not in `allowedSkills` disabled with reason | at most 16 |
| Egress | `spec.egress.allow` | tag input for origins, with the allowed patterns of the policy listed under it as hints (`https://api.osv.dev`, `https://*.example.org`); default "No outbound access" | Live check per origin: shape, inside the tools namespace, matched by the policy. A failing origin stays as a refused tag with the sentence under the input. |
| Policy summary | (policy) | key-value list: models, profiles, knowledge, notify, memory max days, skills, egress patterns, agents used | read-only, links to Governance |

What is not in the form, by design: model config, image, harness, tool server, egress policy, gateway user, budget, callers. A one-line note at the bottom of the capabilities column says so: "Model access, image, tool server and budget come from the platform. Callers are set by an operator in the gate rules."

**Status block** (below the form, and the Deploy tab):

- Condition rail, then a table of the four conditions: type, status, reason, message, last change ("Ready · False · AgentPending · the runtime reports no Ready condition yet · 40 s ago").
- Key-value list: Endpoint (`status.a2aUrl`, with copy; "None, the A2A gate is off" when empty), Gateway user (`status.gatewayUserId`), Tool server (`status.toolServer`), Effective tools (`status.effectiveTools` as mono tags), Effective egress (`status.effectiveEgress`), Runtime object (`status.agentRef`, for debugging), Observed generation against current generation ("Status is for generation 3; you are looking at generation 4. Waiting for the controller." while they differ).

**Refused (`Accepted=False`):**

- A refused notice at the top of the form, title "Refused by the platform policy", body "2 rules refused this definition. Nothing was changed in the cluster; objects of an earlier version, if any, are left as they were." (the second sentence is the `Applied` message), then the violation sentences word for word as a list.
- Each violation that maps to a field also shows under that field, and the field gets the refused edge. Mapping is by the field named in the sentence (`tool`, `egress.allow`, `memory.ttlDays`, `model`, `toolProfile`, `skill`, `instructions`, `name`). A sentence that maps to no field stays only in the notice.
- Save stays enabled: the author fixes the draft and saves again.

**Predicted violations before save** use the same look but the title "This draft would be refused" and they disappear as the author fixes them. Save is still allowed (the controller is the authority), with the button label "Save anyway" when predicted violations exist.

**YAML view:** a side panel (overlay at every width) with the full `AgentDefinition` as the cluster has it (spec and status), and a "Draft" toggle that shows the unsaved draft with changed lines marked. Copy button. Read-only in the first release; editing YAML in the browser is not offered (use kubectl).

**Delete:** destructive dialog. Title "Delete agent researcher?" Body: "This deletes the definition and everything the controller made for it: the runtime agent and its template, model config, harness and egress policy, and the gateway key. Running conversations stop. Memories saved by this agent stay in the memory database until they expire." Field "Type researcher to confirm". Buttons "Cancel" (focused) and "Delete agent" (danger, enabled when the name matches). After delete: toast "Deleting researcher", and the registry row shows pending until the finalizer is done.

**Deploy tab:** what the definition becomes, as a list of the objects the runtime adapter will own (names, kinds, labels), the endpoint once Ready, and the callers note: "Nobody can call this agent yet. An operator adds a gate caller rule with `agents: [kagent/researcher]`." with the YAML snippet to hand to the operator.

**Bring your own agent** (`/agents/new/container`, issue #107). A second path for a new agent, linked under the header of the new agent page ("Already have an agent in a container image? Bring your own agent") only when the platform summary says `container.available` and `container.allowed`. Same header and two-column layout; no instructions field. Fields: Name, Namespace (read-only), Description, **Image** (mono; hint "Must be pinned by digest, not by a tag. Example: <first allowed registry>my-agent@sha256:<64 hex digits>"), **Port** (1024 to 65535, default 8080), **Environment variables** (name and value rows, at most 32, "Add variable" and "Remove variable N"), **Model** (allowed models; others disabled with the reason) and **Tool profile** (None, or an allowed profile that is open to container agents; others disabled with the reason). A warning notice "Less isolated than a built-in agent" comes before the form. Errors are plain sentences that mirror the guard and appear once the field was touched: a tag, a tag next to a digest, a short digest, a registry that is not allowed (the allowed prefixes are named), a port out of range, a reserved or repeated variable name, a value shaped like a secret (the kind is named, the value is never repeated). "Create agent" is `aria-disabled` with the first reason until the form has no problem and the validate route has answered with no prediction and no schema error for exactly this draft ("Checking with the platform..." while it waits). A viewer sees the form read-only without the button. A container agent opened later shows a notice with its image, port and variable names, and no form.

### 6.4 Playground

Purpose: talk to one agent through the gate, as caller `console` with user id `console:<session>`.

- Header: agent select (Ready agents only; others disabled with their reason), caller and user id shown in mono, "New conversation".
- Conversation: user and agent messages, tool calls as collapsed rows inside the agent's message (`osv_query_vulnerability · 2.9 s`), and a turn footer: model calls, input and output tokens, cache read share, cost, duration, link "Open trace".
- Composer: textarea, Enter sends, Shift+Enter new line. While a turn runs: "Stop" and the state text "Waiting for the agent".
- States: agent not Ready ("researcher is not Ready (AgentPending). Messages are sent once it is."), gate off ("The A2A gate is off, so the console cannot call agents. Turn on `governance.a2a.enabled`."), caller missing ("The gate has no rule for caller console."), failed turn (error message from the task, plus trace link).
- Memory warning when the agent has memory on: "This agent remembers. Facts saved here are stored for user console:<session> for up to 30 days."

### 6.5 Skills (read-only until `Skill`)

Cards: name, state (`approved` until the registry exists, from the catalog), digest (mono, shortened with copy of the full value), agents that use it. Detail panel: full reference, versions (one, until the registry), users, `SKILL.md` when it can be read. Notice names `skills` in chart values.

### 6.6 Models (read-only until `ModelProvider`, `ModelRoute`)

Tabs: Providers and routes, Keys and budgets.

- Providers: cards per concrete gateway model (provider type, endpoint, credential "set" with date, health rules, price from the catalog). Detail panel with the agents that use it.
- Routes: table of aliases agents name, strategy (`failover` today), targets with priority, health rules (402, 429, 5xx).
- Keys and budgets: one row per gateway user (agents, `kb`, `kb-extract`, `memory`), who made the key (installer or control plane), token limit and window from the gateway policy, spend today. No USD limit column until it can be enforced (ADR 0008); a line says so.

### 6.7 Tools (read-only until `ToolServer`, `ToolProfile`)

- MCP servers: cards per backend of the vMCP (`fetch`, `osv`, `knowledge` entry, `delivery` entry), kind (MCPServer or MCPServerEntry), status, tool count, calls in 24 h (`toolhive_mcp_tool_calls_total`). Detail panel: tools with full agent-side names, which profiles offer each, which agents use each, image digest for MCPServers.
- Tool profiles: cards per profile (`lookup`), its tool server (`toolhive-vmcp-lookup`), code mode, offered tools, agents using it. Plus the shared vMCP (`toolhive-vmcp`) with the warning "Filters on the client side only. Built agents cannot use it."

### 6.8 Knowledge (read-only until `KnowledgeCollection`, `KnowledgeSource`)

- Collections: cards with documents, chunks, last ingest, graph on or off; for graph collections entities, relations, curated fact sets, job counts (pending, done, failed) and the last error code. Detail panel with documents (title and id, never content preview unless the operator opens it), fact sets.
- Sources: empty state until `KnowledgeSource`: "No sources yet. Documents are added with `hack/kb-ingest.sh <dir> <collection>`. Sources with a sync schedule (Git, web, object storage) come with the KnowledgeSource kind."
- Graph: search box (entity names), the canvas, and the **path panel** on the right: a question or two entity names, then the path as numbered hops ("Quill stores data in Teal"), each with its source (document id and quoted evidence, or "curated: fact set org-catalogue"). Notice on every graph page: "Facts were extracted by a model from documents. Check the cited document before you rely on one."

### 6.9 Channels and triggers (read-only until `Channel`, `Trigger`)

Connections (Kourier ChatConnection: platform, verify scheme, secret "set", Ready), bindings (connection, channel, agent, trigger type and match, limits, user id the agent sees, Ready with reason such as `AgentNotReady`), the Telegram bridge (allowlist size, user id prefix, memory commands on or off). Slack shows "Untested in this project" when present.

### 6.10 Schedules (read-only until `Schedule`)

Table: name, agent, cron with its plain-English reading ("At 08:00, Monday to Friday, UTC"), state (Active or Suspended as paused badge), last run (outcome, duration, time), next run, user id (memory scope). Detail: prompt (with the note "Prompts are configuration, not secrets: they are readable in a ConfigMap"), last three runs.

### 6.11 Memory

Agents with memory on and their days; the expiry job `memory-expiry` with schedule and last run counts (`total_before`, `expired`, `extended`, `deleted`, `total_after`); secret scan mode (report or delete) and the last counts per pattern. Fixed line: "A person's memories are never listed in the console."

### 6.12 Governance (read-only, operator-owned)

Tabs: Policy (the platform policy as a key-value list and YAML), Gate callers (caller, kind, agents, user ids it may assert, methods, memory RPCs), Egress (per agent: origins allowed by the definition, origins effective, policy patterns). Notice: "The platform policy is owned by operators. Change `controlPlane.policy` in chart values or Git."

### 6.13 Traces

- List: recent turns with time, agent, caller, user (salted hash), duration, model calls, cost, outcome. Filters: agent, caller, outcome, time range.
- One turn: header with trace id and context id (copy), the waterfall, and a detail panel for the selected span (attributes in platform names; tool arguments are not shown because content capture is off).
- Fixed notice when content capture is off: "Prompts and answers are not stored (content capture is off)."
- Limit notice for the bundled Jaeger: "The bundled trace store keeps the last 2,000 traces in memory."

### 6.14 Costs

- Tiles: spend for the window, tokens in and out, cache read share, most expensive agent.
- Chart: daily spend stacked by gateway user, three series at most plus "Other", with a table view.
- Table: per gateway user: model, calls, input tokens, output tokens, cache read share, cost, share of total. Link per row to its traces.
- Budgets: token budget per key against today's use, as a meter. USD budgets come with the `Budget` kind.
- Notes: the price source ("gateway price catalog: claude-haiku-5-5 at 0.10 USD per million input and 0.50 per million output tokens") and the first-hour caveat of the metrics store.

### 6.15 Settings

Theme (System, Light, Dark), sidebar default, console session (token held in memory, sign out), adapters and versions from the catalog, edition and licence, links to the decision records.

---

## 7. Content rules

**Labels.** Sentence case everywhere ("Tool profile", not "Tool Profile"). Buttons are verbs: "Create agent", "Save", "Delete agent", "View YAML", "Open trace". No "Submit", no "OK". Field names use the platform words, with the resource field in the hint when it differs (`spec.toolProfile`).

**Status words.** Exactly these, in badges and filters:

| State | Word | When |
|---|---|---|
| ready | Ready | `Ready=True` |
| pending | Pending | any condition Unknown, or `Ready=False` with a waiting reason (`AgentPending`, `AgentNotFound`, `NotApplied` while the key is made) |
| refused | Refused | `Accepted=False` |
| error | Failed | `KeyReady=False`, `Applied=False` with `ApplyFailed`, `RenderFailed`, `CheckFailed`, `PruneFailed`, `NameConflict` |
| paused | Suspended / Off / Read-only | schedule suspended, component off, read-only resource |
| (deleting) | Deleting | finalizer running, shown as pending |

**Error messages.** Pattern: what happened, then why, then what to do. One sentence each, no apology. "Could not save researcher: the console API returned 403. The console's ServiceAccount may not write agentdefinitions. Ask an operator to bind the openagentix-agent-builder Role." Controller sentences are shown exactly as written, in their own list, never rephrased.

**Numbers and units.**

- Tokens: thousands separator, unit word: `30,782 tokens`. Compact above 100,000 in tiles and axes only: `6.42M tokens`, `41.3K tokens`. Tables use full numbers.
- US dollars: `$` before the number. Per turn and per call: 5 decimals (`$0.00321`). Daily and per agent below $10: 3 decimals (`$0.124`). $10 and above: 2 decimals. Always say the source once per page (gateway price catalog).
- Durations: below 1 s in ms (`640 ms`), below 60 s in seconds with one decimal (`3.2 s`), above that `4 min 10 s`. Waterfall axis in seconds.
- Percentages: whole numbers unless below 10 (`7.4%`).
- Sizes: binary units as the platform writes them: `MiB`, `GiB`.

**Dates and times.** Relative for the last 24 hours ("40 s ago", "3 h ago"), with the absolute time in a tooltip. Older: `25 Nov 2026, 08:00`. Always the user's local time zone, with UTC in the tooltip. Cron times show the schedule's own time zone.

**Identifiers.** Always mono, never translated or capitalised: `profile-demo`, `osv_query_vulnerability`, `https://api.osv.dev`. Long ids (digests, trace ids) are shortened in the middle (`4bf92f35…0e4736`) with a copy of the full value.

**Demo data.** The demo install ships demo agents and data. The console shows a "Demo" tag in the top bar when the catalog marks the install as a demo. The console itself never generates demo content.

---

## 8. Accessibility

Target: WCAG 2.2 AA.

**Keyboard map.**

| Key | Action |
|---|---|
| `/` or `Ctrl+K` / `Cmd+K` | focus search (agents, resources, pages) |
| `g` then `o`, `a`, `p`, `t`, `k`, `m`, `c`, `r`, `v` | go to Overview, Agents, Playground, Tools, Knowledge, Models, Costs, tRaces, goVernance |
| `[` | collapse or expand the sidebar |
| `n` | new agent (on the registry) |
| `Ctrl+S` / `Cmd+S` | save in the builder |
| `y` | open YAML view on a resource page |
| `Escape` | close panel, dialog, menu or drawer; returns focus to its opener |
| `Enter` / `Shift+Enter` | in Playground: send / new line |
| Arrow keys | move in tabs, listboxes, the waterfall and the graph path |

Single-letter shortcuts are off while focus is in a text field, and can be turned off in Settings (WCAG 2.1.4).

**Focus order.** Skip link "Skip to content" first. Then sidebar, top bar, page header actions, tabs, main content, detail panel. Opening a panel moves focus to its heading; closing returns it. After save, focus stays on Save and the result is announced in the status region. After a refused save, focus moves to the refused notice heading.

**ARIA patterns.** As listed per component in section 5. Landmarks: `nav` (sidebar, labelled "Main"), `header` (top bar), `main`, `aside` (detail panel, labelled by its heading). One `h1` per page (the page title).

**Colour-independent status.** Every status has an icon shape and a word. The condition rail cells have text labels in the full form and accessible names in the compact form. Charts have legends, direct labels and a table view. Refused fields have an icon and a message, not only a coloured edge.

**Other.** Hit targets at least 24 by 24 px (WCAG 2.5.8), 32 px for primary controls. Text resizes to 200% without loss. Respect `prefers-reduced-motion` and `forced-colors` (status icons keep their shapes; borders use `CanvasText`).

---

## 9. Not in the first release

Deliberately left out. Each one either has no platform behind it yet, or belongs to the enterprise line (ADR 0010).

- Editing YAML in the browser. The YAML view is read-only; use kubectl.
- Editing models, tools, skills, knowledge, channels, schedules and policy. Read-only until each kind exists.
- Per-user identity, roles, approvals, audit history view, teams and showback (enterprise line, or 0.4 and 0.7).
- USD budgets and forecasts (until `Budget` and the gateway expose them).
- Version history and diff between versions of an agent (0.5 lifecycle).
- Evaluation, simulation, red-team runs, guardrails, PII redaction, voice, blueprints, a semantic data model (no platform behind them).
- Listing a person's memories, and reading conversation content in traces (privacy default; content capture is off).
- Uploading skills, adding connectors, adding provider keys (each comes with its kind and its own decision record).
- A command palette that runs actions; search only navigates in the first release.

---

## 10. Open design questions, with the chosen default

| Question | Default |
|---|---|
| Should the builder offer a YAML editor next to the form? | No. Read-only YAML with copy. Revisit after the first users. |
| How are kubectl-applied definitions shown, since there is no per-user identity? | Same as console-built ones ("Built"). The field manager is shown in the YAML panel only. |
| Predicted violations: block Save or allow it? | Allow, labelled "Save anyway". The controller is the authority and its answer is what counts. |
| Dark sidebar in light theme for a stronger frame? | No. Tinted light sidebar; a dark rail in light mode reads as a different product next to dense tables. |
| Font bundling cost (two variable fonts, about 250 KB) | Accept. Fallback stacks keep layout if removed. |
| Graph canvas library | Plain SVG with a small force layout of our own for up to 200 nodes; above that, show the path and its neighbours only. No graph library in the first release. |
| Chart library | None. Inline SVG components (bar, sparkline, meter, waterfall). |
| Where does the "Demo" tag come from? | A `demo: true` flag in the catalog rendered by the chart from the demo values files. Absent means no tag. |

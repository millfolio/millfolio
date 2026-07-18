# Millwright — a codegen-ed, user-owned UI

_Design note. Status: **v1 COMPLETE in code** (2026-07-11, `millwright` branches
in vault + app): storage seams, the versioned spec API, pin-from-Ask, the Board
tab + trusted chrome, and model-assisted spec edit (viewgen rides enclave's
transport — the single Anthropic egress — with its own system prompt; the reply
passes the same lint as a hand edit). Defaults chosen on the open questions
below: ONE dashboard spec, manual refresh + staleness stamp, simple column grid
(cols 1–6, per-widget span). NOT yet verified live: pin from a real chat answer,
widget ↻ through the WS run path, and one keyed viewgen round-trip. Audience:
the app author. Builds directly on [COMPUTE_VS_RENDER.md](COMPUTE_VS_RENDER.md)
(the result-spec IR) and the existing saved-program machinery._

Named for the craftsman who builds and rebuilds a mill's machinery: millfolio's
dashboard surface is **generated, inspectable, editable (by hand or by a model),
and versioned** — the UI fits the user, and the user can always see and change
what it's made of.

## The two-plane model

The design's load-bearing decision is that "the UI is codegen-ed" splits into two
planes with different trust, cost, and tooling — and only one of them is new:

| plane | artifact | machinery |
|---|---|---|
| **data** — *what to compute* | saved vault programs | EXISTING, unchanged: frontier codegen → user approval → Seatbelt sandbox → run-queue → deterministic re-run over the current vault ("Run again") → result-spec output |
| **view** — *how to show it* | a **declarative UI spec** | NEW: extends the result-spec `v:1` IR upward — a dashboard is named widgets + layout + per-widget presentation, each widget bound to one saved program's result |

The generated view artifact is **data, not code**. A hand-written, trusted
renderer (per client) interprets it. Real framework code (Svelte/JS) as the
generated artifact is rejected for v1: it would need eval-or-build at runtime, a
generated `fetch()` is an exfiltration path the Seatbelt sandbox can't reach
(browser CSP would be the only line of defense), and it renders on the web app
only. A "code widget" escape hatch remains a possible LATER extension, not a
founding constraint.

What the spec buys:

- **No exfil path** — a spec can't call the network; the privacy story is intact.
- **Cross-client** — web, iOS, and the menu bar can all render the same spec.
- **Diffable + hand-editable** — the "see the codegen / edit it manually" buttons
  operate on readable text.
- **Lintable** — a spec is shape-checked BEFORE it's accepted (the same guard
  class as the codegen eval lint).
- **Local-model-editable** — a spec is simple enough that VIEW edits are a
  realistic on-device-model task; the frontier model (API key) stays required
  only where it already is: writing programs.

## Invariants

1. **Trusted chrome is never generated.** The Ask panel, the spec-viewer buttons
   (bottom-left), the version list, and revert are hand-written and live outside
   the generated surface. A bad generation must never remove the user's ability
   to see, edit, or revert it.
2. **The view plane never touches data.** Widgets bind to the RESULTS of saved
   programs — never raw vault reads. UI codegen sees the widget catalog (names,
   result shapes, tag names), never values — the same alias boundary as today.
   Specs may not contain remote URLs (a generated image URL is an exfil
   channel), and spec strings render as text, never HTML.
3. **Approval follows the plane.** Creating or editing a PROGRAM goes through
   the existing approval gate (once — thereafter it re-runs unattended, like Run
   again). VIEW edits are frictionless and apply immediately. A model edit that
   implies both shows the view diff applying instantly and the program change as
   a separate approval card.
4. **A broken spec never bricks the app.** Validate before accepting a version;
   if the active spec fails validation or throws at render, boot into the
   last-known-good version automatically and surface "reverted" + the diff.

## Versioning: commit semantics, not a git dependency

Every accepted spec version is immutable, content-addressed, and carries a
parent pointer, a timestamp, and a message (model-authored when the model made
the edit — "added a monthly spend sparkline"). List, diff, and revert operate on
this chain. Implemented over `vault.storage` (log/doc shapes) — NOT by shelling
out to a `git` binary (which would drag in the Xcode CLT as a dependency).
"Export the history as a real git repo" is a later, portability-flavored
feature.

## Refresh: a scheduling problem the Scheduler already solves

A widget's program re-runs through the **Scheduler** as a low-priority
job, keyed on the vault's monotonic insertion generation (the same counter the
tag-backfill ledger uses) — so a widget refreshes only when data it could see
has changed, at background politeness, never at view time. The UI shows a
staleness stamp ("as of yesterday") and allows a manual refresh.

## The on-ramp: pin-from-Ask

In v1 the ONLY way a widget is created: ask a question in the (separate,
trusted) Ask panel → answer + result spec → **Pin**. Every widget is therefore
born from a program the user already saw and approved, with a result shape that
already renders. Cold-start generation ("make me a finance dashboard") is
deferred — weaker results, riskier surface.

## v1 scope

1. Pin-from-Ask → a widget dashboard (grid spec + saved programs + result-spec
   rendering).
2. Trusted chrome: spec viewer, manual edit with validate-before-save, version
   list with diff + revert, auto-revert on a broken spec.
3. Model-assisted spec edit (frontier first; the spec's simplicity keeps the
   local-model door open).

**Not in v1:** whole-app-layout generation, code widgets, cold-start dashboard
generation.

## v2: the curated starter, pages as nav, editable programs

Three extensions (proposed 2026-07-11, direction agreed), in build order:

### 1. The curated starter board (cold-start, answered)

v1 deferred cold-start ("make me a dashboard") because model-generated
dashboards from nothing are weak. Instead: a **curated starter board ships with
the app** — a seed spec version + widget snapshots (program + canned example
result) authored by the app author. On FIRST run (no version chain yet) the
seed is materialized as version 1 (author "millfolio", message "starter board")
— from then on it's ordinary history: editable, revertable, deletable.

- Curated programs are hand-written and deterministic, so unlike model output
  they are **CI-testable**: compile (and eventually run against a fixture
  vault) in `:check`, the same discipline as the eval golden set. The showcase
  cannot rot silently. (Compile-in-CI is a follow-up; the seed spec + result
  JSON are unit-validated from day one.)
- A new user's vault is EMPTY, so seed snapshots are marked `"preview": true`
  and render with an "example — index your data, then ↻ to make it live"
  state. The canned-result pattern is already proven by the public demo.
- Seeding is LAZY (first GET of /api/millwright) and idempotent — it respects
  MILLFOLIO_DATA_DIR and survives reinstalls; it never runs if any version
  exists (an emptied board stays empty — deliberate deletions are respected).

### 2. Pages as top-level nav entries

The v1 "granularity" open question, answered: the spec grows a `pages[]` level
— each page a named board, rendered as a top-level nav button after the
built-ins. "Save a program as a button" = a page with one full-bleed widget; no
new concept.

- **Additive-only chrome invariant:** a spec may ADD nav entries, never move,
  rename, or remove Ask/Vault/Board/Operations — those stay hand-written
  routes no spec can touch. Spec-driven entries render after them, capped
  (5), and the boot-to-last-known-good reflex protects the nav too.
- ONE spec, ONE version chain, with `pages[]` inside — a single history for
  "the UI" (revert reverts everything; no parallel-chain reasoning).

### 3. Editable saved programs

Trust: unchanged — the Seatbelt sandbox exists because programs are untrusted,
so a hand-edited program is no scarier than a generated one; a user editing
their own program is self-approving. The approval card remains exactly where v1
put it: on MODEL-authored program changes.

- **Prerequisite:** program snapshots become CONTENT-ADDRESSED with the same
  version-log pattern as specs (widgets reference a program hash; edits
  append; revert is coherent across both planes). Do this before any editor.
- The editor reuses the existing `vault_build` compile path for inline error
  feedback; "fix it with the model" is the codegen fix-loop behind the usual
  approval card.
- An edited program STALES its cached result: stamp the tile, prompt a re-run.

## Open questions

- **Cross-client rendering:** goal or nice-to-have? (It is the strongest single
  argument for the spec-over-code choice.)
- **Granularity:** one spec per dashboard, or multiple named dashboards/tabs
  each with their own spec + history?
- **Refresh policy:** per-widget ("live / daily / manual") or one global
  setting?
- **Spec format details:** exactly how the result-spec `v:1` IR extends to
  layout (grid? stack? breakpoints?) — to be settled against real pinned
  examples.

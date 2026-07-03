# Compute vs. Present — a declarative result spec for rich output

_Design note. Status: recommendation (decided). Audience: the app author._

## Context & the two directions

The app's core flow today: a user asks a question → the frontier **codegen**
model writes one small Mojo program (`from vault import *`) that calls the vault
tools (`transactions()`, `money()`, `.tags`, `search()`, `ask_local()`) →
`privacy_box` compiles it and runs it in a **macOS Seatbelt sandbox** over the
real vault → the program's `print_answer(...)` output is captured, the internal
sentinel lines are stripped, and the remaining text is shipped to the SvelteKit
UI as one WebSocket `message` event and rendered as a chat bubble
(`app/web/src/lib/components/ChatPanel.svelte:414`).

Two directions of development motivate this note:

1. **Richer output** — tables and graphs, not just a paragraph of text. A
   "spending by month" answer wants a line chart; "top merchants" wants a bar
   chart; "total spent" wants a KPI tile.
2. **Packaging as a macOS desktop app** — one downloadable `.app`, not brew +
   terminal.

Both pull on the same seam: _how a computed answer becomes something a client
draws_. This note fixes that seam before either direction is built, so they
don't fork it.

## The decision

**Separate COMPUTE from PRESENT across a declarative, typed seam.** The
generated program stays platform-agnostic: it computes and emits a single
**serializable result spec** (a typed IR) — never platform render calls, never
HTML/SVG. The render _implementations_ live in the CLIENTS (web, desktop, iOS,
CLI). The program emits typed result _data_ (scalars, labeled tables,
time/category series); a **deterministic presenter in the client** picks the
visualization from the data's shape. The model's job stays exactly as narrow as
it is today — compute correct data — and presentation becomes trusted,
deterministic, and client-side.

## Why a declarative spec, not platform render calls

The tempting shortcut is to give the generated program `chart(...)`/`table(...)`
tools that emit HTML or call a real renderer. Reject it, for three reasons
specific to _this_ app:

- **The generated program is UNTRUSTED.** It runs in Seatbelt precisely because
  a prompt-injected vault document could steer the model into hostile code —
  that's the whole reason for the sandbox
  (`vault/privacy-box/src/orchestrator.mojo`, the `run_vault_task`
  confidentiality argument). If the program could emit HTML/SVG or drive a real
  renderer, we'd hand untrusted code a **markup/injection channel right where we
  built the security boundary**. A closed, typed spec means every string that
  crosses the seam is _data_ the client escapes — there is no markup path out of
  the sandbox. `print_answer` is already treated as plain text; the spec keeps
  that property for structured output.
- **N clients from ONE generation.** Emit the same spec always; let clients
  differ. The "html vs. desktop vs. iOS vs. CLI" question then costs _one
  schema_, not one fork per render primitive. A native SwiftUI renderer and the
  web renderer consume the identical JSON.
- **It reuses existing discipline.** The `vault:eval` shape-lint already guards
  the program's _shape_ — it must use `transactions()`/`money()`/`.tags`, never
  `.alias`, never `search()`-for-totals, never raw-float `$` (the "$224,303
  phone bill" class of bug; see `vault/privacy-box/eval/README.md`). The result
  spec becomes **another validated contract** the same harness can lint: "if the
  answer is a spending total, it emits a typed money scalar, not a bare float."
  Critically, `money()` values must cross the seam as **typed money** (a raw
  `Float64` _plus_ the `money()`-formatted string — see
  `vault/core/src/vault/tools/tools.mojo:620`), not a pre-rendered string, so
  the client can format axes and re-aggregate correctly without ever seeing
  `$31241.0599999998`.

## Why the client picks the view, not the model

Push **view selection** into a deterministic client-side presenter. The program
emits typed DATA; the presenter picks the mark from the data's SHAPE — the
standard dataviz "form heuristic," which is highly inferable:

| data shape               | view              |
| ------------------------ | ----------------- |
| single number            | KPI / scalar tile |
| labeled category → value | bar               |
| time-ordered → value     | line              |
| two grouped categories   | grouped bar       |
| anything else            | table             |

This beats asking the model to call chart APIs:

- **Keeps codegen narrow.** The correctness risk lives in _computing the right
  number_ — that's what the eval protects. Every render primitive the model must
  choose among widens the eval surface and injects nondeterminism into a
  behavior that _can't_ be unit-tested (it's an LLM). Chart selection is a
  deterministic function of the data; don't make an LLM re-derive it per query.
- **Clean trust split.** Untrusted compute (sandbox) produces data; trusted,
  deterministic presentation (client) picks the mark. The security boundary and
  the compute/present boundary land in the same place.
- **Escape hatch without load-bearing model choices.** Keep an _optional_ model
  hint (`hint: "line"`) the presenter honors when present and ignores when
  absent. The model can nudge; it can't break rendering by getting the chart
  type wrong.

**Net contract:** the program emits `{ text, data?, hint? }`. `text` is the
streamed narrative (unchanged from today). `data`, when attached, is typed and
auto-visualized. Keep the vocabulary small — **KPI/scalar, table, line, bar,
grouped-bar** — which covers essentially every personal-finance answer.

## Concrete schema sketch

_All Mojo below is **proposed**, not existing._ The builders are thin appenders
to a per-run result buffer; `main()` computes as it does today and calls them
instead of (or alongside) `print_answer`.

### Proposed Mojo builder API (`from vault import *`)

```mojo
# result buffer — one spec per run; builders append, the runtime serializes once.
result_text("You spent $4,210.55 across 128 transactions.")  # the narrative (== today's print_answer)

kpi("Total spent", money_val(4210.55))          # typed money scalar → KPI tile
kpi("Transactions", count(128))

# a labeled table; money cells carry raw + formatted (never a bare float)
var t = table(["Merchant", "Spent"])
t.row(["Whole Foods", money_val(812.40)])
t.row(["Shell",       money_val(214.02)])

# a time series → the presenter draws a line; a category series → a bar
series("Spending by month", kind="time")        # x = ISO date, y = money
  .point("2026-01-01", money_val(1203.10))
  .point("2026-02-01", money_val(980.44))

hint("line")                                     # OPTIONAL — presenter honors if set
```

- `money_val(x: Float64)` carries **both** the raw `Float64` and `money(x)`
  (`tools.mojo:620`) so the client formats/aggregates from the number and
  displays the exact string. This is the typed-money invariant made concrete.
- `count(n)`, `date(iso)` similarly tag their type so the presenter never
  guesses from a formatted string.
- The narrative still goes through `result_text` (a rename of `print_answer`'s
  role); text-only answers attach no `data` and render exactly as today.

### JSON wire shape (versioned from day one)

```json
{
  "v": 1,
  "text": "You spent $4,210.55 across 128 transactions.",
  "data": {
    "kind": "series",
    "hint": "line",
    "title": "Spending by month",
    "x": { "type": "date", "values": ["2026-01-01", "2026-02-01"] },
    "y": {
      "type": "money",
      "raw": [1203.1, 980.44],
      "text": ["$1,203.10", "$980.44"]
    }
  }
}
```

The `"type": "money"` tag is what lets a client render `$1,203.10` on a tick
label while scaling the axis by `1203.10`. `v` is the contract version (see
Tradeoffs).

### Threading it through the WS `ServerEvent` protocol

The transport already has the right seams. Two grounded options:

1. **A field on the final message event (smallest change).** The message builder
   is `app/server/src/events.mojo:117` and the mirrored TS type is
   `MessageEvent` in `app/web/src/lib/protocol.ts:40`. Add an optional
   `result?: ResultSpec` field there (kept in lockstep, as the file header
   requires). ChatPanel's assistant branch (`ChatPanel.svelte:411-421`) renders
   `it.text`, then, if `it.result` is present, mounts the presenter component
   below the bubble.
2. **A dedicated `result` event** (cleaner union). Add a `ResultEvent` to the
   `ServerEvent` union (`protocol.ts:70`) + a `result_event(...)` builder in
   `events.mojo` beside `tags_event`/`debug_event`. This mirrors how `tags` and
   `tag-proposal` were added as first-class events, and keeps `message`
   unchanged.

**How the spec leaves the sandbox** — reuse the existing sentinel channel. The
program already emits out-of-band lines with dedicated sentinels
(`PROGRESS_SENTINEL`, `STAT_SENTINEL`, `LOCAL_SENTINEL` —
`orchestrator.mojo:43-48`), and `_strip_progress` (`orchestrator.mojo:51`)
filters them out of the captured answer text. Add a `RESULT_SENTINEL`: the
builders emit the serialized spec on a `RESULT_SENTINEL`-prefixed line;
`_strip_progress` already drops it from `text`; `vault_run_finish`
(`orchestrator.mojo:404`) captures it separately and the WS server attaches it
to the message/result event. No new channel out of Seatbelt — it rides the one
that already exists, and stays plain-text-escaped data the whole way.

## The desktop direction

The project is **already ~80% a desktop app**:

- The menu-bar Swift app (`menu-bar/menu/Sources/Millfolio/MillfolioApp.swift`)
  is a `MenuBarExtra` that manages the servers and today opens the web UI in the
  default browser (`NSWorkspace.shared.open(url)`, line 47).
- The `mill` CLI runs the app-server under launchd and serves the full web UI
  locally at **http://localhost:10000**
  (`vault/cli/.../MillfolioCLI.swift:86-96`, `Bootstrapper.swift:1510+`), with
  the streaming WS on :10001.

So "make it a macOS app" is not a rewrite. **The cheapest path is a native shell
that hosts the existing web UI in a `WKWebView`** — one `.app`, no
brew/terminal, native menu + notifications — reusing the ONE web renderer.
Concretely: replace the menu-bar app's `NSWorkspace.open(:10000)` with a
`WKWebView` window pointed at the same local server. The "html vs. desktop"
split disappears because both render the same page.

Only build a **second** native renderer (SwiftUI + Swift Charts consuming the
same JSON spec) if the webview feel isn't good enough. The value of doing the
spec IR _now_ is that it lets you **defer that decision**: web-first today,
native renderer later, with **zero change to the generation side** — the sandbox
emits the same `v:1` spec either way.

## Tradeoffs to design around

- **Streaming UX.** Today the narrative answer arrives as a _single_ final
  `message` event (progress lines stream live during the run via the sentinel
  channel; `ChatPanel` shows a working indicator and per-step elapsed time,
  `ChatPanel.svelte:295-310`). A chart is inherently "compute then emit." Keep
  the narrative behavior as-is and **attach the visualization at the end** — the
  chart pops in below the words once `data` arrives. Do not regress into a
  blocking spinner that withholds the text until the chart is ready. (If
  narrative token streaming is added later, the same rule holds: stream text,
  attach data last.)
- **Contract versioning.** The result spec is a contract spanning Mojo (sandbox)
  → JSON/WS → Svelte/SwiftUI. **Version it from day one** with the `v` field so
  a later shape change is a migration, not a break. Clients ignore-with-fallback
  on an unknown `v` (render `text` only).
- **Typed money end to end.** The single most important payload rule: money
  crosses the seam as `{raw, text}`, never a bare float and never only a
  formatted string. Raw drives axes/aggregation; text is the exact `money()`
  display. This is the spec-level continuation of the eval's existing "never
  raw-float `$`" guard.

## Phased plan

- **Phase 1 — result spec + web presenter (text-parity first).** Define
  `ResultSpec` (`v:1`) with `kpi` / `table` / `series`; add the Mojo builders
  - `RESULT_SENTINEL`; thread it onto the message/result event (`events.mojo` +
    `protocol.ts`); render `text` exactly as today and a table/KPI when `data`
    is present. Add a `vault:eval` shape-lint rule for the spec (typed money, no
    bare floats). Ship with **no chart** yet — proves the seam.
- **Phase 2 — chart presenter (form heuristic).** Add the deterministic
  shape→mark presenter (line/bar/grouped-bar) + the optional `hint`. Teach the
  codegen prompt (`privacy_box-system.md`) the builder API and _when_ to emit a
  series vs. a scalar — narrowly, since the presenter, not the model, chooses
  the mark. Attach-at-end streaming.
- **Phase 3 — desktop shell.** Wrap the web UI in a `WKWebView` window in the
  menu-bar app (reuse the local server). Single `.app`, native
  menu/notifications. The renderer is unchanged.
- **Phase 4 (optional, deferred) — native renderer.** Only if the webview feel
  falls short: a SwiftUI + Swift Charts presenter over the _same_ `v:1` JSON.
  The generation side does not change.

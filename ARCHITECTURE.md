# millfolio architecture

millfolio answers questions about your **private documents without the data leaving
your device**. An *untrusted* frontier model writes a small program over an
**aliased** manifest (it never sees your data); that program runs in a
**network-denied sandbox** on your machine, calling a *trusted* on-device model +
local tools to read the real content; the answer is printed locally.

This repo is the **moon workspace / git superproject** tying the pieces together as
submodules. They stack in four layers; **dependencies point strictly downward.**

```
┌─ apps / clients ──────────────────────────────────────────────────────────┐
│  app/web (SvelteKit)   app/ios   menu-bar   website                        │
└───────────────▲───────────────────────────────────────────────────────────┘
                │  HTTP / WebSocket (loopback or tailnet)
┌─ infra / runtime ─────────────────────────────────────────────────────────┐
│  engine (:8000 inference, Metal)   app/server (:10000 UI+REST+chat)        │
│  vault/privacy-box (codegen broker + EgressGuard + sandbox)   vault/cli    │
└───────────────▲───────────────────────────────────────────────────────────┘
                │  `from vault import *`  /  build_index
┌─ domain / tools  (the `vault` package) ───────────────────────────────────┐
│  tool surface (manifest, search, transactions, file_chunks, ask_local,    │
│  csv_rows, pdf_text, money, parse_amount, iso_date, print_answer, …)       │
│  indexer (chunk+embed, LanceDB side-tables)   reconcile-validated extractor│
└───────────────▲───────────────────────────────────────────────────────────┘
                │  uses
┌─ low-level libraries  (domain-agnostic, pure Mojo, shipped as .mojopkg) ───┐
│  flare(http/tls)  json  zlib  pdftotext  docx  csv  lancedb  jinja2        │
└───────────────────────────────────────────────────────────────────────────┘
```

## 1. Low-level libraries

General-purpose Mojo libraries with **no millfolio knowledge** — reusable in any
project. Each ships as a precompiled `.mojopkg`.

| repo | role | depends on |
|---|---|---|
| `flare` | HTTP/TLS client (+ a server reactor) | `json` |
| `json` | JSON parse/serialize | — |
| `zlib` | DEFLATE/inflate (FFI shim) | — |
| `pdftotext` | PDF → text; born-digital, **layout-preserving** | `zlib` |
| `docx` | .docx → text (ZIP + OOXML) | `zlib` |
| `csv` | RFC-4180 CSV | — |
| `lancedb` | on-device vector store (Rust cdylib via FFI) | — |
| `jinja2` | templating (privacy-box prompts) | — |

## 2. Domain / tools — the `vault` package

`vault/core/src/vault` is **what millfolio knows about personal documents**. This is
the "tools" layer; `money` is one of many. It is the confidentiality boundary on the
tool side: every tool takes an **alias** (`file_0`, `col_2`), resolves it internally,
and never returns a real path or name. Three concerns live here today:

- **Tool surface** — what a generated program imports via `from vault import *`:
  `manifest`, `search`, `file_chunks`, `csv_rows`, `pdf_text`/`md_text`/`docx_text`,
  `ask_local`/`ask_local_batch`, `transactions`, `print_answer`, `progress`,
  `iso_date`, `parse_amount`, `money`.
- **Indexer** — `build_index` (incremental chunk + embed), the LanceDB store, the
  side-tables (`chunks.tsv`, `manifest.tsv`, `transactions.tsv`).
- **Domain extraction** — the **reconcile-validated** transaction extractor
  (statements → `Txn`s trusted only when they close against the statement's own
  arithmetic), plus amounts/dates parsing/formatting.

It uses the low-level libs (flare → the engine over HTTP, lancedb → the index,
pdf/docx/csv → extraction).

## 3. Infra / runtime

The long-running processes + orchestration that turn the tools into a service.

| repo | process | role |
|---|---|---|
| `engine` | inference server `:8000` | ONE process serving a chat model **and** an embedding model; Mojo + Metal GPU |
| `vault/privacy-box` | orchestrator (in-process / CLI) | brokers codegen (frontier vs local), enforces the **EgressGuard** (fails closed), compiles + runs the generated program under a **Seatbelt** sandbox (network-denied except loopback) |
| `app/server` | web backend `:10000` | serves UI + REST + chat WS; embeds the orchestrator per-connection; streams progress |
| `vault/cli` | the `mill` Swift CLI + bootstrapper | provisions bundle + toolchain + weights, manages the launchd agents, runs `index`/`ask`/`start`/`stop` |

**Runtime shape:** two processes (inference `:8000` GPU, app `:10000`), both under
launchd. The HTTP API is load-bearing **because the sandboxed generated program is a
separate process** that reaches inference only over loopback.

**The codegen seam** is a *configurable* remote endpoint (`ANTHROPIC_BASE_URL` →
`{base}/messages`). That single seam is why the demo can replay cached programs with
zero changes to the real code.

## 4. Apps / clients

`app/web` (SvelteKit Chat + Vault views), `app/ios`, `menu-bar` (macOS), `website`
(millfolio.app). Clients talk to infra over HTTP/WS and hold **no** domain logic.

### Supporting
- `scripts` — release orchestration (`publish`/`verify`: tag vault → CI builds the
  bundle → bumps the Homebrew tap).
- `demo` + `demo-vault` (separate repos) — the public demo: replay codegen / real
  execution over a synthetic vault, reusing the real infra **unmodified** via config.

## The dependency rule

**Down only:** apps → infra → vault(tools/domain) → low-level libs. A lower layer
never imports a higher one. The libs don't know about millfolio; the vault domain
uses them; infra orchestrates the domain; apps consume infra over the wire.

## The privacy architecture (cross-cutting — the whole point)

- **Frontier model = untrusted planner.** Sees only the aliased manifest + the
  question; writes a program over aliases. Never sees data or real names.
- **Local model = trusted reader.** Runs on-device, sees real content, returns the
  minimal answer the program asked for.
- **The generated program runs in a Seatbelt sandbox:** network **denied** except
  loopback (so it can reach the local inference server and nothing else). The
  EgressGuard gates the outbound codegen path and fails closed.
- Data never leaves the device; the answer is printed locally.

Enforced by **infra** (privacy-box) + the **tool boundary** (vault aliases), not left
to callers.

## Packaging / build / test

- **Build:** moon orchestrates per-project `pixi` (Mojo) / `swift` tasks; a single
  pinned Mojo nightly across all repos.
- **Ship:** the install bundle carries **precompiled `.mojopkg`** (vault + libs) +
  prebuilt binaries + FFI shims — **no `.mojo` source** (commercial IP protection).
  Generated programs compile against the `.mojopkg`s.
- **Release:** `moon run release:publish -- vX.Y.Z` tags vault → CI builds
  `millfolio.zip` + the `mill` CLI → bumps the Homebrew tap.
- **Test:** each repo has a pure-Mojo hermetic suite (`pixi run test`) run in CI,
  with test files under `test/`.

## What I think of this layering

The four-layer model is the right shape, and the codebase largely follows it. The
parts I'd call out:

- **The `vault` package is doing three jobs** (tool surface, indexer, domain
  extractor) under one roof. They're cohesive today, but as the domain grows,
  splitting them into sub-packages — `vault.tools` (the `from vault import *` API),
  `vault.index` (build/storage), `vault.extract` (statement reconciliation) — would
  keep the public tool contract small and stable while the heavier logic evolves
  behind it. `money`/`parse_amount`/`iso_date` are the seed of a reusable
  formatting/parsing group.
- **"Tools" is the right name for what the generated program sees**, and it's worth
  treating the `from vault import *` surface as a *versioned contract* (it already
  must match `privacy_box-system.md` exactly). Adding a tool = a deliberate API
  change, not an incidental export.
- **The codegen seam is a genuine architectural asset.** Keeping codegen behind a
  configurable endpoint (rather than hard-wired to one provider) is what makes the
  demo, offline/mock mode, and provider swaps cheap. Preserve that.
- **One thing that blurs the layers:** `app/server` embeds the privacy-box
  orchestrator in-process rather than calling it as a service. That's fine for a
  single-box product, but it means "infra" has an internal call graph, not just a
  wire protocol. If you ever scale out, that's the seam to formalize.
- **Cross-cutting concerns** (the alias contract, the sandbox profile, the FFI
  shims, the pinned nightly) live in a few specific places and are easy to get
  wrong from the outside — they belong to infra/domain and should never be a
  knob an app or a tool reaches for.

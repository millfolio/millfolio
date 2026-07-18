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
│  vault/enclave = Enclave (Harness + EgressGuard + sandbox)   vault/cli     │
└───────────────▲───────────────────────────────────────────────────────────┘
                │  `from vault import *`  /  build_index
┌─ domain / tools  (the `vault` package) ───────────────────────────────────┐
│  tool surface (manifest, search, transactions, spending, file_chunks,     │
│  ask_local, csv_rows, pdf_text, money, parse_amount, iso_date, …)          │
│  indexer (chunk+embed, LanceDB side-tables)   reconcile-validated extractor│
│  tag derivation (keyword + AI rules)   storage seam (queue/log/kv/doc)     │
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
| `jinja2` | templating (enclave prompts) | — |

## 2. Domain / tools — the `vault` package

`vault/core/src/vault` is **what millfolio knows about personal documents**. This is
the "tools" layer; `money` is one of many. It is the confidentiality boundary on the
tool side: every tool takes an **alias** (`file_0`, `col_2`), resolves it internally,
and never returns a real path or name. It is split into **five sub-packages**: the
generated-program chain `tools → index → extract`, plus `derive` (category tags,
built over extract/index/storage) and `storage` (the persistence seam, a leaf). The
top `vault/__init__.mojo` re-exports the **tool surface** so the
`from vault import *` contract is identical whether consumed as source or as a
precompiled `vault.mojopkg` (`derive`/`storage` are internal — deliberately not in
that contract):

- **`vault/tools/`** — the tool surface a generated program imports via
  `from vault import *`: `manifest`, `search`, `file_chunks`, `csv_rows`,
  `pdf_text`/`md_text`/`docx_text`, `ask_local`/`ask_local_batch`, `transactions`,
  `print_answer`, `progress`, `iso_date`, `parse_amount`, `money`. Small + stable —
  treat it as a versioned contract (it must match `enclave-system.md` exactly).
- **`vault/index/`** — `build_index` (incremental chunk + embed), the LanceDB store,
  the readers/embed/sha256, the side-tables (`chunks.tsv`, `manifest.tsv`,
  `transactions.tsv`).
- **`vault/extract/`** — the **reconcile-validated** transaction extractor
  (statements → `Txn`s trusted only when they close against the statement's own
  arithmetic), plus amounts/dates parsing/formatting.
- **`vault/derive/`** — deterministic **category tags** over the extracted
  transactions: the editable rule registry (`categories.txt` — keyword rules +
  AI yes/no rules), index-time tagging, and the ML-backfill ledger. Privacy split:
  tag NAMES + scope notes go to codegen; the keyword RULES (real merchant strings)
  stay on-device.
- **`vault/storage/`** — the **persistence seam**: four store shapes as traits
  (`QueueStore`/`LogStore`/`KvStore`/`DocStore`) with file-backed impls behind
  `default_*_store()` factories. All queue/log/marker/registry I/O (app server +
  vault) routes through it, so a real backend (LanceDB is the candidate) can be
  swapped in per shape without touching call sites.

It uses the low-level libs (flare → the engine over HTTP, lancedb → the index,
pdf/docx/csv → extraction). Tests mirror the structure under `core/test/{index,extract}/`.

## 3. Infra / runtime

The long-running processes + orchestration that turn the tools into a service.

| repo | process | role |
|---|---|---|
| `engine` | inference server `:8000` | ONE process serving a chat model **and** an embedding model; Mojo + Metal GPU |
| `vault/enclave` | the **Enclave** — its **Harness** codegen loop (in-process / CLI) | brokers codegen (frontier vs local), enforces the **EgressGuard** (fails closed), compiles + runs the generated program under a **Seatbelt** sandbox (network-denied except loopback). The security boundary is sealed in its `security/` sub-package (`sandbox`/`egress`/`broker`/`budget`) |
| `app/server` | web backend `:10000` | serves UI + REST + chat WS; embeds the **Harness** per-connection; streams progress. Internally: `server.mojo` is a thin composition root (route dispatcher + `main()`) over per-domain `handlers_*` modules (chat/vault/tags/models/…) and `scheduler_loop.mojo` (the **Scheduler**), which runs ALL background engine work (indexing + AI-tag backfill) serially |
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
- `scripts` — release orchestration (`publish`/`promote`/`verify`: dev rc → test →
  promote the same artifacts to prod; see Packaging below).
- `demo` + `demo-vault` (separate repos) — the public demo: replay codegen / real
  execution over a synthetic vault, reusing the real infra **unmodified** via config.
- `browser-native.mojo` — a standalone Mojo lib: an agent-friendly wrapper around
  the upstream `agent-browser` CDP engine, plus a **recorder** seam (a Rust
  chromiumoxide cdylib) that observes a human's click/type/navigate in a live
  session and emits a replayable `job`. **Auxiliary / exploratory** — it is *not*
  imported by the vault stack and *not* in the install bundle; it's the seed of
  privacy-preserving, on-device ingestion (e.g. log in and download a statement
  locally, then hand the file to the vault readers). Off the dependency rule below.

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

Enforced by **infra** (enclave) + the **tool boundary** (vault aliases), not left
to callers.

## Packaging / build / test

- **Build:** moon orchestrates per-project `pixi` (Mojo) / `swift` tasks; a single
  pinned Mojo nightly across all repos.
- **Ship:** the install bundle carries **precompiled `.mojopkg`** (vault + libs) +
  prebuilt binaries + FFI shims — **no `.mojo` source** (commercial IP protection).
  Generated programs compile against the `.mojopkg`s.
- **Release:** two channels, dev → prod. `moon run release:publish -- vX.Y.Z-rc.N`
  tags vault as a **pre-release** → CI builds `millfolio.zip` + the `mill` CLI →
  bumps the `mill-dev` tap formula. After testing,
  `moon run release:promote -- vX.Y.Z` copies the **same tested artifacts** to a
  clean prod release (no rebuild — prod is byte-identical to what was tested) and
  bumps `mill`; `release:verify` confirms assets + tap match.
- **Test:** each repo has a pure-Mojo hermetic suite (`pixi run test`) run in CI,
  with test files under `test/`. `vault:check` also runs `vault:precompile` (the
  same `.mojopkg` build the release performs) so a precompile-only break — a
  nightly API rename, a `len(String)` only the tool surface reaches — is caught
  by `moon run :check`, not at tag time.

## What I think of this layering

The four-layer model is the right shape, and the codebase largely follows it. The
parts I'd call out:

- **The `vault` package is split into `vault.tools` / `vault.index` / `vault.extract`**
  (done — the three jobs that used to share one roof now have a clean
  `tools → index → extract` dependency chain), **since joined by `vault.derive`
  (tags) and `vault.storage` (the persistence seam)** without disturbing that
  chain. The public tool contract stays small and stable in `tools/` while the
  heavier indexer and extractor logic evolve behind it. `money`/`parse_amount`/
  `iso_date` (in `extract/`) are the seed of a reusable formatting/parsing group.
- **"Tools" is the right name for what the generated program sees**, and it's worth
  treating the `from vault import *` surface as a *versioned contract* (it already
  must match `enclave-system.md` exactly). Adding a tool = a deliberate API
  change, not an incidental export.
- **The codegen seam is a genuine architectural asset.** Keeping codegen behind a
  configurable endpoint (rather than hard-wired to one provider) is what makes the
  demo, offline/mock mode, and provider swaps cheap. Preserve that.
- **One thing that blurs the layers:** `app/server` embeds the Enclave's
  **Harness** in-process rather than calling it as a service. That's fine for a
  single-box product, but it means "infra" has an internal call graph, not just a
  wire protocol. If you ever scale out, that's the seam to formalize. (The 2026-07
  carve-up makes it findable: the **Harness** is reached from `handlers_chat`, the
  **Scheduler** from `scheduler_loop`, not from a god-file.)
- **Cross-cutting concerns** (the alias contract, the sandbox profile, the FFI
  shims, the pinned nightly) live in a few specific places and are easy to get
  wrong from the outside — they belong to infra/domain and should never be a
  knob an app or a tool reaches for.

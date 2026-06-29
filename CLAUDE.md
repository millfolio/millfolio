# millfolio — superproject

This is the **moon workspace / git superproject** that ties together millfolio's
repos (each a submodule). The personal-data-vault product is: a combined
inference server (`engine`) + a privacy/sandbox orchestrator (`vault/privacy-box`)
+ vault tools/indexer (`vault/core`) + the `mill` CLI (`vault/cli`) + the web app
(`app/`), shipped to users as one downloadable bundle and a Homebrew formula.

Commands below are run from the superproject root (`/Users/mseritan/dev/millfolio`)
unless noted. `moon` is at `~/.moon/bin/moon` and on PATH.

## Releases (two channels: dev → test → prod)

The release pipeline lives in `scripts/` (moon project name: `release`). We ship to
a **dev** channel, test it, then **promote the same artifacts** to prod — promote
never rebuilds, so prod is byte-identical to what was tested.

```bash
moon run release:publish -- vX.Y.Z-rc.N   # DEV: tag a PRE-RELEASE → CI builds both
                                          #      assets → bump the mill-dev formula
# …test it… (FIRST install of mill-dev → `brew install`; a later rc.N → `brew upgrade`)
brew install millfolio/tap/mill-dev && mill-dev install
moon run release:promote -- vX.Y.Z        # PROD: copy the tested rc's assets to a
                                          #       clean vX.Y.Z release + bump mill
moon run release:verify -- vX.Y.Z         # confirm assets + tap formula match
```

- **Two Homebrew formulae in `millfolio/homebrew-tap`:** `mill` (prod, binary `mill`)
  and `mill-dev` (dev, binary `mill-dev`) — so they coexist. The CLI reads its own
  channel back via `brew list --versions` and fetches the **version-pinned** bundle
  (`releases/download/v<version>/millfolio.zip`, NOT `/latest/`), so a dev CLI gets
  the dev bundle. Testers run `mill-dev`; the public runs `mill`. They share the
  install footprint, so run **one at a time** (stop/uninstall the other first).
- **publish** (`scripts/release.sh`): DEV only — requires a `-rc.N`/`-beta.N`/`-dev.N`
  suffix, tags `vault`, CI attaches both assets to a **pre-release** (kept off
  `/releases/latest`, invisible to prod), bumps `mill-dev`.
- **promote** (`scripts/promote.sh`): copies the tested rc's `millfolio.zip` +
  `mill-macos.tar.gz` to a clean `vX.Y.Z` full release (marked latest) at the same
  commit, then bumps `mill`. **No rebuild.** Plain `vX.Y.Z` tags don't trigger CI
  (the build workflows fire only on `v*-*`), so the copied assets are never clobbered.
- **verify** (`scripts/verify_release.sh`): confirms both assets are attached AND
  the tap formula version matches. No arg → checks whatever the tap currently
  pins. Prints `✅ vX.Y.Z is live` or exits non-zero listing what's missing.

**Gotcha — the tag push uses SSH.** `release.sh` pushes the tag to
`git@github.com:millfolio/vault`, so an SSH key must be loaded (`ssh-add -l`);
otherwise it fails `Permission denied (publickey)` and no tag is created (a
re-run after `ssh-add` is clean). For one-off HTTPS pushes when SSH is
unavailable: `git push "https://x-access-token:$(gh auth token)@github.com/<org>/<repo>.git" HEAD:main`.

## Build / check (any project)

`moon run <project>:<task>`. Projects: `vault`, `app-server`, `app-web`,
`engine`, `menu-bar`, `website`, plus the Mojo libs (`flare`, `json`, `lancedb`,
`pdftotext`, `csv`, `jinja2`, `zlib`, `browser-native`).

```bash
moon run vault:build         # Mojo binaries: build/vault (core) + build/privacy_box
moon run vault:build-cli     # the Swift `mill` umbrella CLI
moon run vault:bundle        # assemble millfolio.zip (the install bundle)
moon run app-server:build    # the web app's Mojo server (millfolio-server + -ws)
moon run app-web:build       # the SvelteKit web UI → app/web/build
moon run menu-bar:build      # the macOS menu-bar app
moon run website:build       # the marketing site
```

Each Mojo project also builds directly via `pixi run build` in its own dir (the
unified toolchain — see the `mojo-toolchain-via-pixi` note). Prefer `pixi run …`
to verify Mojo changes locally before relying on CI.

## Toolchain & testing

- **Shared Mojo nightly.** Every Mojo repo pins the *same* nightly in its
  `pixi.toml` (currently **`1.0.0b3.dev2026062706`**) — the `-I ../sibling` layout
  requires one shared version. To bump: edit the pin in each `pixi.toml` (and the
  `recipe.yaml` run-reqs for json + flare — a second, easy-to-miss pin),
  `pixi update mojo`, then rebuild/test in dep order (libs → engine → vault →
  app-server). Bump gotchas seen on dev2026062706: recursive structs (e.g. a
  `List[Self]` field) now hard-error `field has non-implicitly deletable type` →
  add a trivial `def __del__(deinit self): pass`; destructors must be `def` not
  `fn`; `reflect[T]()` → `reflect[T]`; `len(String/StringSlice)` → `.byte_length()`.

- **GPU/Metal (engine).** Metal builds need the Xcode **Metal Toolchain**
  component. If `xcrun metal --version` says `missing Metal Toolchain`, install it
  once per machine: `xcodebuild -downloadComponent MetalToolchain` (otherwise GPU
  gates fail `Metal Compiler failed to compile metallib`). `moon run :check` keeps
  engine on weight-free **CPU** gates (portable); the **GPU** gates run only in
  `moon run release:preflight`.

- **Each project's `check` = build + full unit tests.** `moon run :check` runs
  them all, cached + affected-aware — the single source of truth locally and in CI.

- **Prompt eval is a PRE-RELEASE gate, not in `:check`.** The codegen system prompt
  (`vault/privacy-box/resources/privacy_box-system.md`) is an LLM behaviour — it
  can't be unit-tested. `moon run vault:eval` drives `privacy_box codegen` on a
  synthetic manifest and lints the generated program's SHAPE (must use
  `transactions()`/`money()`, never `.alias`/`search()`-for-totals/raw-float `$`) —
  guarding the "$224,303 phone bill" class. It needs `ANTHROPIC_API_KEY` and is
  model-nondeterministic, so it's a manual pre-release step, kept OUT of pre-push.
  See `vault/privacy-box/eval/README.md`.

- **Two-tier git hooks** (install with `bash scripts/install-hooks.sh`; fans out to
  the superproject + every submodule):
  - **pre-commit** (`scripts/precommit.sh`) — FAST, staged files only: `mojo format`
    check on staged `.mojo` + `svelte-check` on staged web.
  - **pre-push** (`scripts/preflight.sh`) — FULL `moon run :check` (build + tests).
  - Bypass once with `git commit --no-verify` / `git push --no-verify`.

- **Formatter is `mojo format` (= mblack,** a fork of Python `black`). No
  `--check`/`--diff` flag — it only writes in place, so the pre-commit hook formats
  a *copy* and diffs. mblack can't parse some valid Mojo (aliased imports,
  `from x import y as z`) — those files are left untouched and the hook skips them.

## The `mill` CLI (what users run)

Built from `vault/cli`; installed via `brew install millfolio/tap/mill`.

```bash
mill install        # provision: inference server + weights + privacy_box + vault tools + web app
mill update         # brew-upgrade the CLI, then refresh the downloadable components
mill start          # bring everything up; serves the millfolio web app at http://localhost:10000
mill stop           # tear it down
mill status         # what's installed
mill version        # component versions
mill index <dir>    # build the on-device LanceDB vault index over a folder
mill ask "<q>"      # one-shot vault answer
```

## Conventions for agents

- **At session start, check GitHub SSH reachability** and tell the user if it's
  down — pushes and releases here go over SSH, so catching it early avoids a
  half-finished release. Run `ssh -o BatchMode=yes -o ConnectTimeout=5 -T
  git@github.com` (a successful auth exits 1 with `Hi <user>!`; a failure is a
  timeout or `Permission denied (publickey)`). If it fails, notify the user (e.g.
  "GitHub SSH isn't available — run `ssh-add` / check your key before releasing").
- **Don't use `cd`** in Bash commands — it can trigger a permission prompt. `gh`
  takes `-R <owner>/<repo>`; `git` takes `-C <repo>`; `pixi`/`swift` take
  `--package-path` / run from the project dir via moon.
- **Pushes are SSH** (`git@github.com:millfolio/*`). Confirm `ssh-add -l` before a
  release.
- After a release, confirm with `moon run release:verify` rather than ad-hoc
  `gh` queries.

## Repo map

| dir | what |
|-----|------|
| `engine` | combined inference server (chat + embeddings), Mojo + Metal |
| `vault/core` | vault tools + LanceDB indexer (`mill index`/`ask`) |
| `vault/privacy-box` | the sandbox/orchestrator generated vault programs run under |
| `vault/cli` | the Swift `mill` CLI + the installer (`Bootstrapper.swift`) |
| `app/server` | the web app's Mojo HTTP/WS backend (`GET /api/vault`, `POST /chat`) |
| `app/web` | the SvelteKit web UI (Chat + Vault views) |
| `app/ios`, `menu-bar` | native clients |
| `flare json lancedb pdftotext csv jinja2 zlib` | vendored Mojo libs |
| `browser-native.mojo` | Mojo wrapper around the `agent-browser` CLI (agent-friendly browser automation) |
| `scripts` | release orchestration (`release`/`verify`) |
| `website` | millfolio.app marketing site |

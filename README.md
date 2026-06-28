# millfolio

> 💬 **Community:** questions, ideas, and show-and-tell live in [GitHub Discussions](https://github.com/millfolio/millfolio/discussions).

> The product: **[millfolio.app](https://millfolio.app)** — a private, on-device document vault.

Superproject aggregating the millfolio repos as git submodules, orchestrated with
[moon](https://moonrepo.dev). Each submodule stays an independent repo under
github.com/millfolio; this repo pins them together and provides cross-project
build/check/release tasks. Mojo builds run through `pixi` (moon wraps them as
`system` tasks).

## Layout
- `app/`, `engine/`, `vault/`, `website/`, `menu-bar/` — apps/clients
- `flare/`, `json/`, `jinja2.mojo/`, `lancedb.mojo/`, `pdftotext.mojo/`, `zlib.mojo/`, `csv.mojo/` — Mojo libraries (pixi-managed)
- `.moon/` — moon workspace config; per-project tasks live in each submodule's `moon.yml`
- `scripts/` — helper scripts (most superseded by moon tasks; `ios.sh` is wrapped by `app-ios:run`)

## Setup
```sh
git clone --recurse-submodules git@github.com:millfolio/millfolio.git
# or, after a plain clone:
git submodule update --init --recursive
curl -fsSL https://moonrepo.dev/install/moon.sh | bash   # then: export PATH="$HOME/.moon/bin:$PATH"
```
`pixi` must be on PATH (the Mojo repos carry their own `pixi.toml`/`pixi.lock`).
Each Mojo repo pins one shared Mojo nightly (currently **`1.0.0b3.dev2026062706`**,
in every `pixi.toml`); `pixi run <task>` inside a repo resolves/downloads that
toolchain into its `.pixi/`. The first run in a repo is slow (it fetches the
compiler).

**Mac GPU prerequisite (engine only).** `engine`'s Metal/GPU builds need the Xcode
**Metal Toolchain** component. If `xcrun metal --version` reports
`missing Metal Toolchain`, install it once per machine:

```sh
xcodebuild -downloadComponent MetalToolchain
```

Without it, GPU gates fail with `Metal Compiler failed to compile metallib`. The
portable `moon run :check` keeps engine on weight-free CPU gates (so it runs on
machines without the toolchain); the GPU gates run in `moon run release:preflight`.

## Common tasks
```sh
moon run :check                          # build/check every project (replaces scripts/check.sh)
moon run vault:build-cli menu-bar:build  # Swift builds (replaces scripts/build.sh)
moon run app-ios:build                   # iOS simulator build (replaces scripts/ios.sh)
moon run app-ios:run                     # iOS build + launch on the simulator + screenshot
moon run vault:bundle                    # build millfolio.zip install bundle
moon run vault:formula -- v0.4.1         # bump the Homebrew formula to a published tag
```

## Tests & git hooks

Each project's `check` task = **build + full unit tests** (Mojo via `pixi run`,
caught by moon's per-project cache). `moon run :check` runs them all and re-runs
only what changed. A two-tier git-hook setup gates work before it leaves the
machine — install it once (fans out to the superproject **and** every submodule):

```sh
bash scripts/install-hooks.sh            # install   (--remove to uninstall)
```

- **pre-commit** → `scripts/precommit.sh` — FAST, staged files only: `mojo format`
  check on staged `.mojo` + `svelte-check` on staged web files.
- **pre-push** → `scripts/preflight.sh` → `moon run :check` — FULL build + tests;
  moon's cache makes unchanged projects instant.

Bypass either once with `git commit --no-verify` / `git push --no-verify`. Mojo's
formatter is `mojo format` (= mblack, a fork of Python `black`); it has no
`--check`/`--diff` flag, so the hook formats a copy and diffs.

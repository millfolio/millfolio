# Contributing to millfolio

Thanks for your interest! This repo is the **moon workspace / git superproject**
that ties the millfolio repos together. Each library and app is an **independent
git submodule** under [github.com/millfolio](https://github.com/millfolio) — you
make changes *in the submodule*, then bump the superproject's pointer to it.

> 💬 Questions and ideas are welcome in
> [GitHub Discussions](https://github.com/millfolio/millfolio/discussions).

The big picture lives in [ARCHITECTURE.md](ARCHITECTURE.md); the setup and task
basics are in the [README](README.md). This file is the *how to work in the
repo* guide.

## Prerequisites

Install these first. The versions below are what the project is currently built
and tested against — a newer release is generally fine; older than the stated
floor is not.

| tool | version | why | install |
|------|---------|-----|---------|
| **[pixi](https://pixi.sh)** | **≥ 0.69** (tested **0.71.1**) | per-repo env + Mojo toolchain manager. **The `pixi.lock` files use the v7 format, which pixi < 0.69 can't read.** | `curl -fsSL https://pixi.sh/install.sh \| bash` |
| **[moon](https://moonrepo.dev)** | **≥ 2.0** (tested **2.3.4**) | cross-project task runner (`moon run :check`) | `curl -fsSL https://moonrepo.dev/install/moon.sh \| bash` |
| **[Rust](https://rustup.rs)** stable (via rustup) | **recent stable** (tested **1.94**) | builds the `ffi/` Rust shims (lancedb, zlib, flare TLS/HTTP, browser-native recorder) | `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \| sh` |
| **git** | any recent | submodules | system / `xcode-select --install` |
| **Swift / Xcode** | Xcode 16+ | the `mill` CLI, iOS app, `menu-bar` | App Store |
| **Xcode Metal Toolchain** | — | GPU gates: `engine` Metal builds + `json`'s GPU suite | `xcodebuild -downloadComponent MetalToolchain` |

After installing, make sure `pixi` and `moon` are on `PATH` (add to your shell
profile):

```sh
export PATH="$HOME/.pixi/bin:$HOME/.moon/bin:$PATH"
```

You do **not** install Mojo separately — each repo pins one shared **Mojo
nightly** in its `pixi.toml`, and `pixi run <task>` downloads it into that repo's
`.pixi/` on first use (the first run is slow). Rust is only needed when you build
or touch a repo that has an `ffi/` directory; `rustup`'s `stable` channel (what
CI uses) is the right default.

**Version gotchas**
- **pixi ≥ 0.69 is a hard floor** — the locks are v7. If you see `the lock file …
  uses an older format (v6)`, your pixi is too old: `pixi self-update`.
- **moon** is the workspace task runner; install it before running any
  `moon run …` command.

```sh
git clone --recurse-submodules git@github.com:millfolio/millfolio.git
cd millfolio
bash scripts/install-hooks.sh        # two-tier git hooks (see below)
```

## The submodule workflow

A change almost always belongs to **one submodule** (a lib or an app). Work there
as you would in any repo, then record it upstream:

1. Branch/edit **inside the submodule** (e.g. `vault/`, `json/`, `flare/`). Each
   is on `main` and has its own history and remote.
2. Verify with moon (see *Checks* below).
3. **Commit in the submodule**, then **bump the superproject**:
   ```sh
   git -C <submodule> commit -am "…"          # commit the real change
   git add <submodule> && git commit -m "Bump <submodule>: …"   # record the new SHA
   ```
4. **Push leaf repos before the superproject**, so the superproject's gitlinks
   resolve for everyone:
   ```sh
   git -C <submodule> push        # leaf first
   git push                       # then the superproject pointer
   ```

Cross-cutting changes (e.g. a Mojo nightly bump) touch several submodules plus a
superproject pointer commit — same rule, just repeated per repo.

## Checks

Every project's `check` task is **build + full unit tests**, cached and
affected-aware. It is the single source of truth, locally and in CI.

```sh
moon run :check                 # everything that changed
moon run <project>:check        # one project, e.g. json:check, vault:check
moon run vault:precompile       # the release-critical .mojopkg set (part of vault:check)
```

> **Metal note.** `moon run :check` is *no longer fully Metal-free*: `json:check`
> runs the GPU suite (Apple Metal / CUDA), and `vault:check` runs the release
> `precompile`. On a machine without the Metal toolchain, run the CPU-only
> subsets directly (`pixi run tests-cpu` in `json/`) or skip those projects.

## Code style & hooks

- **Mojo** is formatted by `mojo format` (= **mblack**, a fork of Python `black`).
  No `--check`/`--diff` flag — it only writes in place. Run it before committing.
- **Web** (`app/web`) uses `svelte-check`.
- The **two-tier hooks** (installed by `scripts/install-hooks.sh`, fanning out to
  the superproject + every submodule) gate work before it leaves the machine:
  - **pre-commit** (`scripts/precommit.sh`) — fast, staged files only: `mojo
    format` check on staged `.mojo` + `svelte-check` on staged web.
  - **pre-push** (`scripts/preflight.sh`) — full `moon run :check`.
  - Bypass once with `git commit --no-verify` / `git push --no-verify`.

## Tests

Add tests next to the code you change — each Mojo repo keeps a pure, hermetic
suite under `test/` (or `tests/`), run by `pixi run test` and gated by the
project's `check`. New tool-surface behavior, parsers, and FFI seams should ship
with coverage; prefer pure functions that test without a network or a browser.

## Bumping the Mojo toolchain

All Mojo repos pin one nightly. To bump: edit the pin in **each** `pixi.toml`
(and the `recipe.yaml` run-reqs for `json` + `flare` — a second, easy-to-miss
pin), run `pixi update mojo`, then rebuild/test in dependency order
(libs → engine → vault → app-server). See the nightly-migration notes in
[CLAUDE.md](CLAUDE.md).

## Releases (two channels: dev → test → prod)

Releases are cut from `vault` and orchestrated by `scripts/` — see the **Releases**
section of [CLAUDE.md](CLAUDE.md) for the full details. We ship to a **dev** channel,
test it, then **promote the same artifacts** to prod — promote never rebuilds, so
prod is byte-identical to what was tested.

```bash
# 1. DEV — cut a pre-release (mill-dev). CI builds + attaches both assets to a
#    PRE-RELEASE (kept off /releases/latest, invisible to prod users).
moon run release:publish -- vX.Y.Z-rc.N

# 2. TEST it (the dev CLI installs the dev bundle; runs one at a time with prod).
#    First install of mill-dev → `brew install` (a later rc.N → `brew upgrade`).
brew install millfolio/tap/mill-dev && mill-dev install

# 3. PROD — promote the tested rc's assets to a clean vX.Y.Z release + bump `mill`.
#    No rebuild → prod ships exactly what you tested.
moon run release:promote -- vX.Y.Z
moon run release:verify -- vX.Y.Z
```

The public installs `brew install millfolio/tap/mill`; testers use
`millfolio/tap/mill-dev`. The two formulae install different binaries (`mill` vs
`mill-dev`) so they coexist, but share the install footprint — run one at a time.
Pushing the tag uses SSH, so load your key first (`ssh-add -l`).

## Reporting issues

Open an issue on the **specific submodule** when the problem is scoped to one
library/app; use this superproject's issues for cross-cutting or build/workspace
problems. For open-ended questions, prefer
[Discussions](https://github.com/millfolio/millfolio/discussions).

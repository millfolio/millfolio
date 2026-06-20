# Moonrepo Migration Plan — `millfolio/millfolio`

> **Status:** PLAN ONLY. Nothing here has been executed. This document is written
> so another agent (or a human) can implement the migration end-to-end. Read the
> whole thing — especially **§7 Caveats** — before running any command.

## 0. Goal

Turn the loose directory `~/dev/millfolio/` (which today holds ~12 *independent*
git repos side by side) into a single **git superproject** named `millfolio`
(remote `git@github.com:millfolio/millfolio.git`), with each existing repo wired
in as a **git submodule**, and a **moon** workspace on top that orchestrates
builds/checks across all of them. Mojo is driven through **`system` tasks** that
wrap the existing `pixi run …` commands (moon has no native Mojo toolchain).

The five decisions to implement:

1. `git init` a new repo at `~/dev/millfolio/`.
2. Convert each subfolder into a git submodule.
3. Set up moon, with Mojo builds/tests as `system` tasks wrapping pixi.
4. Commit + push as `millfolio/millfolio` with a brief `README.md`.
5. Reproduce everything `scripts/*.sh` does today as moon tasks.

---

## 1. Current state (verified 2026-06-20)

`~/dev/millfolio/` is **not** a git repo. It contains these independent repos
(all under the GitHub org `millfolio`, remote `git@github.com:millfolio/<name>.git`):

| Dir (= submodule path) | Branch | Kind | Remote name |
|---|---|---|---|
| `app` | `main` | Swift/iOS + npm/web + pixi server | `app` |
| `csv.mojo` | `main` | Mojo lib (pixi) | `csv.mojo` |
| `engine` | `main` | Mojo app (pixi) | `engine` |
| `flare` | `main` | Mojo lib (pixi, has C++ FFI) | `flare` |
| `jinja2.mojo` | `main` | Mojo lib (pixi) | `jinja2.mojo` |
| `json` | `main` | Mojo lib (pixi) | `json` |
| `lancedb.mojo` | `main` | Mojo lib (pixi, FFI) | `lancedb.mojo` |
| `menu-bar` | `main` | Swift app | `menu-bar` |
| `pdftotext.mojo` | `main` | Mojo lib (pixi) | `pdftotext.mojo` |
| `vault` | `main` | Mojo app (pixi) + Swift CLI (`cli/`) | `vault` |
| `website` | `main` | npm/Astro | `website` |
| `zlib.mojo` | `main` | Mojo lib (pixi, FFI) | `zlib.mojo` |

**Non-repo directories** (live only in the new superproject, NOT submodules):

- `scripts/` — the shell scripts to be reproduced as moon tasks (see §6).
- `logs/` — local scratch (`error.txt`). Should be **gitignored**.

> All repos are on **`main`** (the former `app` `ios-client` branch was merged
> into `main` and deleted). No non-default-branch special-casing is needed.

---

## 2. Inter-project dependency graph (the real constraint)

Mojo builds reference **sibling source directories** via the compiler's `-I`
flag (relative paths), discovered in `engine/pixi.toml` and `vault/pixi.toml`:

- **`engine`** → `jinja2.mojo`, `flare`
  - e.g. `mojo build src/server.mojo -I ../jinja2.mojo/src -I ../flare …`
- **`vault`** (build deps) → `flare`, `json`, `lancedb.mojo`, `pdftotext.mojo`,
  `zlib.mojo`, `csv.mojo`, `jinja2.mojo`
  - `mojo build core/src/millfolio.mojo -I ../flare -I ../json -I ../lancedb.mojo/src -I ../pdftotext.mojo/src -I ../zlib.mojo/src -I ../csv.mojo/src`
  - `engine` is a **runtime** dep of vault, **not** a build dep.
- **`app/server`** → its own pixi task (`build-ws`); no Mojo sibling `-I`.

> **Why submodules don't break this:** the `-I ../flare` paths are *filesystem*
> paths resolved by the `mojo` compiler at build time. Submodules do **not** move
> files — the on-disk layout (`~/dev/millfolio/flare`, etc.) is byte-for-byte
> identical; only git gains a superproject that pins each folder to a commit. As
> long as **each submodule's checkout path equals its current directory name**
> (`flare`→`flare`, `jinja2.mojo`→`jinja2.mojo`, …), every `-I ../x` resolves
> unchanged. **This invariant is mandatory.**
>
> Also note: because `-I` points at sibling **source**, a dependency only needs
> to be *present* (checked out), not pre-built. So moon `dependsOn` here is about
> correct **affected-detection / cache invalidation** (rebuild dependents when a
> dep's sources change), not strict build ordering.

This graph maps directly to moon `dependsOn` (§5).

---

## 3. Step 1+2 — superproject + submodules

### 3a. Preconditions (do first, do not skip)

Submodules pin to a commit that exists **on the remote**. So for every repo:

```sh
# For each repo, verify clean + pushed. STOP and surface anything dirty/unpushed.
for d in app csv.mojo engine flare jinja2.mojo json lancedb.mojo \
         menu-bar pdftotext.mojo vault website zlib.mojo; do
  echo "== $d =="
  git -C "$d" status --short                 # expect empty
  git -C "$d" log --oneline -1
  git -C "$d" rev-parse HEAD                  # record this SHA
  git -C "$d" status -sb | head -1            # check ahead/behind origin
done
```

- If any repo has **uncommitted** changes → commit or stash in that repo first.
- If any repo is **ahead of origin** → `git -C <d> push` first.
- Record each repo's HEAD SHA; the submodule will be re-pinned to it (§3c).
- All repos (incl. `app`) are on `main`; confirm `main` is pushed to `origin`.

### 3b. Initialize the superproject

```sh
cd ~/dev/millfolio
git init
git branch -M main
```

### 3c. Convert each directory to a submodule

`git submodule add` will not adopt an existing populated git repo in place, so
the reliable procedure per repo is: **record SHA → remove dir → re-add as
submodule → check out the recorded SHA**. (Safe *only* because §3a confirmed
everything is pushed.)

```sh
cd ~/dev/millfolio

add_submodule() {            # add_submodule <name> [branch]
  name="$1"; branch="${2:-main}"
  sha="$(git -C "$name" rev-parse HEAD)"
  url="git@github.com:millfolio/${name}.git"
  rm -rf "$name"
  git submodule add -b "$branch" "$url" "$name"
  git -C "$name" checkout "$sha"     # pin to the exact pre-migration commit
}

add_submodule app
add_submodule csv.mojo
add_submodule engine
add_submodule flare
add_submodule jinja2.mojo
add_submodule json
add_submodule lancedb.mojo
add_submodule menu-bar
add_submodule pdftotext.mojo
add_submodule vault
add_submodule website
add_submodule zlib.mojo
```

This creates `.gitmodules`. Verify paths exactly match the original names
(invariant from §2). All submodules track `main`.

> Alternative (no re-download): keep the dir, `git submodule add` against a
> temporary path then move — more fragile. The remove/re-add path above is the
> recommended one. If bandwidth is a concern, the implementer may instead use
> `git submodule add --name <name> <url> <existing-path>` workarounds, but must
> verify the working tree SHA is preserved.

### 3d. Superproject `.gitignore`

```gitignore
# transient
logs/
# moon caches / local artifacts
.moon/cache/
.moon/docker/
# tool caches that may appear at root
.DS_Store
```

> Do **not** gitignore the submodule directories — they are tracked via
> `.gitmodules` + gitlinks, not as normal files.

---

## 4. Step 3 — install moon + pixi prerequisites

moon and proto are **not currently installed**. Install via proto (moonrepo's
version manager) or the standalone script:

```sh
# Option A: proto (recommended by moonrepo)
curl -fsSL https://moonrepo.dev/install/proto.sh | bash
proto install moon

# Option B: standalone
curl -fsSL https://moonrepo.dev/install/moon.sh | bash

moon --version    # sanity check
```

Pin tool versions for reproducibility (optional but recommended) in
`~/dev/millfolio/.prototools`:

```toml
moon = "latest"   # replace with the resolved version after install
```

**pixi must be installed** (the Mojo repos already carry `pixi.toml` +
`pixi.lock`; moon only *calls* `pixi run …`). Verify `pixi --version`.

---

## 5. Step 3 (cont.) — moon workspace + project config

### Config placement decision

**Recommended:** put a small `moon.yml` **inside each submodule** (it co-locates
build knowledge with the project and supports per-project commands +
`dependsOn`). The trade-off: this adds one `moon.yml` commit to each of the 12
sub-repos.

**Alternative (keeps sub-repos pristine):** define everything centrally in the
superproject under `.moon/` using an explicit `projects` map + `.moon/tasks/*.yml`
inherited tasks. This is harder because each Mojo repo uses a *different*
representative command, so you'd lean on tags + per-tag task files. Choose this
only if touching the sub-repos is unacceptable.

The rest of this section documents the **recommended** per-project approach.

### 5a. `~/dev/millfolio/.moon/workspace.yml`

```yaml
# Explicit id → path map. IDs are clean (no dots); paths keep the on-disk names.
projects:
  app-ios: 'app/ios'
  app-server: 'app/server'
  app-web: 'app/web'
  csv: 'csv.mojo'
  engine: 'engine'
  flare: 'flare'
  jinja2: 'jinja2.mojo'
  json: 'json'
  lancedb: 'lancedb.mojo'
  menu-bar: 'menu-bar'
  pdftotext: 'pdftotext.mojo'
  vault: 'vault'
  website: 'website'
  zlib: 'zlib.mojo'

vcs:
  manager: 'git'
  defaultBranch: 'main'

# Mojo/Swift builds shell out; no language toolchain is auto-managed.
runner:
  cacheLifetime: '7 days'
```

### 5b. `~/dev/millfolio/.moon/toolchain.yml`

```yaml
# No managed language toolchains — all tasks run via the `system` toolchain.
# (Left intentionally minimal; pixi/swift/xcodebuild come from PATH.)
```

### 5c. Per-project `moon.yml` examples

All Mojo/Swift tasks set `toolchain: 'system'` so moon wraps the shell command
and doesn't try to manage a language runtime.

**`flare/moon.yml`** (representative Mojo lib; same shape for json/zlib/csv/
pdftotext/jinja2/lancedb — only the `command`/`args` differ, see §6 table):

```yaml
type: 'library'
language: 'unknown'
tags: ['mojo']
tasks:
  check:
    command: 'pixi'
    args: ['run', 'test-quic-varint']
    toolchain: 'system'
    inputs:
      - 'flare/**/*.mojo'
      - 'pixi.toml'
      - 'pixi.lock'
```

**`vault/moon.yml`** (Mojo app with build-dep graph + a Swift CLI in `cli/`):

```yaml
type: 'application'
language: 'unknown'
tags: ['mojo', 'swift']
dependsOn:
  - 'flare'
  - 'json'
  - 'lancedb'
  - 'pdftotext'
  - 'zlib'
  - 'csv'
  - 'jinja2'
tasks:
  build:                       # Mojo build (pixi resolves toolchain + FFI)
    command: 'pixi'
    args: ['run', 'build']
    toolchain: 'system'
    inputs: ['core/**/*.mojo', 'privacy-box/**/*.mojo', 'pixi.toml', 'pixi.lock']
    outputs: ['build/**/*']
  check:
    command: 'pixi'
    args: ['run', 'build']
    toolchain: 'system'
  build-cli:                   # Swift `mill` product in vault/cli
    command: 'swift'
    args: ['build', '--package-path', 'cli', '--product', 'mill']
    toolchain: 'system'
    inputs: ['cli/Sources/**/*.swift', 'cli/Package.swift']
```

**`engine/moon.yml`** (build deps: jinja2 + flare):

```yaml
type: 'application'
language: 'unknown'
tags: ['mojo']
dependsOn: ['jinja2', 'flare']
tasks:
  build:
    command: 'pixi'
    args: ['run', 'serve']      # adjust to the desired default build/serve task
    toolchain: 'system'
    inputs: ['src/**/*.mojo', 'pixi.toml', 'pixi.lock']
# NOTE: scripts/check.sh has NO engine check today (see §6). Add a real
# `check` task here (e.g. a pixi test) — flagged as an open item.
```

**`menu-bar/moon.yml`** (pure Swift):

```yaml
type: 'application'
language: 'swift'
tags: ['swift']
tasks:
  build:
    command: 'swift'
    args: ['build', '--package-path', 'menu']
    toolchain: 'system'
    inputs: ['menu/Sources/**/*.swift', 'menu/Package.swift']
  check:
    command: 'swift'
    args: ['build', '--package-path', 'menu']
    toolchain: 'system'
```

**`app/ios/moon.yml`** (the iOS app — reproduces `scripts/ios.sh`, see §6):

```yaml
type: 'application'
language: 'swift'
tags: ['swift', 'ios']
tasks:
  build:                        # xcodegen + simulator build (CODE_SIGNING_ALLOWED=NO)
    command: 'bash'
    args: ['-c', 'xcodegen generate && xcodebuild -project Millfolio.xcodeproj -scheme Millfolio -sdk iphonesimulator -destination "platform=iOS Simulator,name=iPhone 17,OS=26.5" -configuration Debug build CODE_SIGNING_ALLOWED=NO']
    toolchain: 'system'
    inputs: ['Millfolio/**/*', 'project.yml']
  run:                          # build + install + launch on sim + screenshot
    command: 'bash'
    args: ['../../scripts/ios.sh', 'run']   # OR inline the logic; see §6 note
    toolchain: 'system'
    deps: ['app-ios:build']
```

**`app/server/moon.yml`**:

```yaml
type: 'application'
language: 'unknown'
tags: ['mojo']
tasks:
  build:
    command: 'pixi'
    args: ['run', 'build-ws']
    toolchain: 'system'
  check:
    command: 'pixi'
    args: ['run', 'build-ws']
    toolchain: 'system'
```

**`website/moon.yml`** (npm/Astro):

```yaml
type: 'application'
language: 'javascript'
tags: ['web']
tasks:
  build:
    command: 'npm'
    args: ['run', 'build']
    toolchain: 'system'
    inputs: ['src/**/*', 'package.json', 'astro.config.mjs']
    outputs: ['dist/**/*']
```

> After config is in place, validate the graph:
> `moon project-graph` and `moon task-graph` (or `moon query projects`).

---

## 6. Step 5 — reproduce `scripts/*.sh` as moon tasks

The current `scripts/` directory (verified contents):

### `build.sh` — Swift sanity builds
Builds two Swift targets:
- `mill` ← `vault/cli`  (`swift build --product mill`)
- `menu-bar` ← `menu-bar/menu` (`swift build`)

**moon equivalent:** `moon run vault:build-cli menu-bar:build`

### `check.sh` — build/check every repo (continue-on-fail + summary)
One representative command per repo. Map each to a project `check` task:

| check.sh label | dir | command today | moon task |
|---|---|---|---|
| `mill` | `vault/cli` | `swift build --product mill` | `vault:build-cli` |
| `menu-bar` | `menu-bar/menu` | `swift build` | `menu-bar:check` |
| `flare` | `flare` | `pixi run test-quic-varint` | `flare:check` |
| `json` | `json` | `pixi run mojo -I . tests/test_value.mojo` | `json:check` |
| `jinja2` | `jinja2.mojo` | `pixi run build` | `jinja2:check` |
| `zlib` | `zlib.mojo` | `pixi run test` | `zlib:check` |
| `csv` | `csv.mojo` | `pixi run test` | `csv:check` |
| `pdftotext` | `pdftotext.mojo` | `pixi run build` | `pdftotext:check` |
| `lancedb` | `lancedb.mojo` | `pixi run test` | `lancedb:check` |
| `vault-mojo` | `vault` | `pixi run build` | `vault:check` |
| `app-server` | `app/server` | `pixi run build-ws` | `app-server:check` |

**moon equivalent of the whole script:** `moon run :check`
(`:check` runs the `check` task in every project that defines one. moon already
continues across failures and prints a summary, and it adds caching +
`--affected` that `check.sh` lacks.)

> ⚠️ `engine` is **absent** from `check.sh` today — there is no engine check.
> Define a real `engine:check` (e.g. a pixi test task) as part of this work, or
> consciously leave it out. Flagged as an open item in §8.

### `ios.sh` — iOS build (+ `run` = install/launch sim + screenshot)
- `scripts/ios.sh` → `app-ios:build`
- `scripts/ios.sh run` → `app-ios:run`

Two ways to implement (pick one):
1. **Wrap** the existing script from the moon task (shown in §5c `app/ios/moon.yml`
   `run` task). Simplest; keeps one source of truth. The script must stay in the
   superproject `scripts/`.
2. **Inline** the logic into the moon task `args` (no dependency on `scripts/`).
   More moon-native; duplicates the bash. Prefer (1) unless you intend to delete
   `scripts/`.

### `rename.sh` + `check-rename.sh` — ONE-OFF migration (millrace/veilens → millfolio)
These are **historical, single-purpose** scripts for the brand rename across
`engine vault app menu-bar`. They are **not** recurring build tasks.

Recommendation: do **not** model these as first-class moon `build`/`check`
tasks. Options:
- Keep them as-is in `scripts/` (committed to the superproject) for reference.
- Optionally expose under a clearly-namespaced, non-default task, e.g. a
  `migrate` project / `migrate:rename` + `migrate:check-rename`, with a comment
  that they are one-shot and already applied.
- Or delete them post-migration if the rename is considered complete.

Document the choice; don't silently drop them.

### Disposition of `scripts/`
After moon tasks exist, decide whether to (a) keep `scripts/` as thin wrappers /
historical record, or (b) delete the build/check/ios scripts now superseded by
moon and keep only the one-off rename scripts. Recommended: keep `ios.sh` (the
`run` task wraps it) + the rename scripts; the build/check scripts become
redundant with `moon run :check`.

---

## 7. Caveats — read before implementing

1. **Submodules + moon affected-detection is coarse-grained.** moon detects
   touched files via git in the **superproject** repo. Files *inside* a submodule
   belong to the submodule's own repo, so the superproject's `git diff` sees a
   changed submodule only as a **moved gitlink (pointer)**, not as individual
   files. Practical effect:
   - When a submodule's commit pointer is updated in the superproject, moon
     treats that whole project as affected (acceptable).
   - **Uncommitted / un-pinned** changes inside a submodule's working tree may
     **not** be seen by `moon --affected` at the superproject level. Devs editing
     inside a submodule should run that project's task directly, or commit +
     bump the pointer before relying on affected-detection.
   - This is the known cost of the polyrepo-via-submodules approach; it is the
     reason a true monorepo gives better affected granularity.
2. **Directory-name invariant (from §2):** submodule checkout paths MUST equal
   the current names, or the Mojo `-I ../sibling` includes break. Verify
   `.gitmodules` paths after §3c.
3. **All repos track `main`.** (The former `app` `ios-client` work branch has
   been merged into `main` and deleted, so there is no non-default-branch case.)
4. **FFI repos** (`flare`, `zlib.mojo`, `lancedb.mojo`) build C/C++ via pixi
   tasks (e.g. vault's `ffi` task sources `../flare/.../build.sh`,
   `../zlib.mojo/src/ffi/build.sh`, `../lancedb.mojo/ffi/build.sh`). These also
   rely on the sibling layout — same invariant. moon just calls the pixi tasks;
   don't try to model FFI separately.
5. **pixi owns the Mojo toolchain.** moon does not install Mojo. First `pixi run`
   in each repo resolves the pinned toolchain — may be slow once. Keep that in
   mind for the first `moon run :check`.
6. **`runFromWorkspaceRoot`:** moon tasks run from the **project** dir by default,
   which is what the pixi `-I ../sibling` paths expect. Do not set
   `runFromWorkspaceRoot: true` on these tasks.
7. **Don't commit secrets / signing.** The iOS device-signing settings
   (`DEVELOPMENT_TEAM`) live in `app/ios/project.yml` (that repo) — out of scope
   here. No certs/profiles belong in the superproject.
8. **Caching correctness:** the `inputs`/`outputs` in the examples are
   representative, not exhaustive. Tune them per repo so moon's cache doesn't
   serve stale results (especially include `pixi.lock` + any FFI sources).

---

## 8. Step 4 — README, commit, push as `millfolio/millfolio`

### 8a. Create `~/dev/millfolio/README.md` (brief)

```markdown
# millfolio

Superproject aggregating the millfolio repos as git submodules, orchestrated
with [moon](https://moonrepo.dev). Each submodule remains an independent repo
under github.com/millfolio; this repo pins them together and provides
cross-project build/check tasks.

## Layout
- `app/`, `engine/`, `vault/`, `website/`, `menu-bar/` — apps/clients
- `*.mojo/`, `flare/`, `json/` — Mojo libraries (pixi-managed)
- `.moon/` — moon workspace config
- `scripts/` — legacy/one-off scripts (most superseded by moon tasks)

## Setup
    git clone --recurse-submodules git@github.com:millfolio/millfolio.git
    # or, after a plain clone:
    git submodule update --init --recursive
    proto install moon         # or: curl -fsSL https://moonrepo.dev/install/moon.sh | bash

## Common tasks
    moon run :check            # build/check every project (replaces scripts/check.sh)
    moon run vault:build-cli menu-bar:build   # Swift builds (replaces scripts/build.sh)
    moon run app-ios:build     # iOS sim build (replaces scripts/ios.sh)
    moon run app-ios:run       # iOS build + launch on simulator + screenshot
```

### 8b. Commit + push

```sh
cd ~/dev/millfolio
git add .gitmodules .gitignore README.md Moonrepo.md .moon scripts .prototools
# (submodule gitlinks were staged by `git submodule add`)
git commit -m "millfolio superproject: submodules + moon workspace"

# Create the GitHub repo and push (requires gh auth + org write access):
gh repo create millfolio/millfolio --private --source=. --remote=origin --push
# If the remote already exists:
#   git remote add origin git@github.com:millfolio/millfolio.git
#   git push -u origin main
```

> Per-project `moon.yml` files (if using the recommended approach) are commits
> **inside each submodule** — commit + push those in their own repos, then bump
> the submodule pointers in the superproject (`git add <submodule>` + commit).

---

## 9. Verification checklist (run after implementing)

- [ ] `git -C ~/dev/millfolio submodule status` lists all 12, none with `+`/`-` prefixes after `update --init`.
- [ ] `.gitmodules` paths exactly match original dir names; all submodules track `main`.
- [ ] `cd vault && pixi run build` still succeeds (proves `-I ../sibling` intact post-submodule).
- [ ] `moon project-graph` shows all 14 project ids and the vault/engine `dependsOn` edges.
- [ ] `moon run :check` runs and prints per-project pass/fail (parity with `scripts/check.sh`, minus the known engine gap).
- [ ] `moon run vault:build-cli menu-bar:build` succeeds (parity with `scripts/build.sh`).
- [ ] `moon run app-ios:build` succeeds; `moon run app-ios:run` launches the sim + writes `/tmp/mf-ios.png` (parity with `scripts/ios.sh`).
- [ ] Fresh clone test: `git clone --recurse-submodules …` into a temp dir reproduces the full tree.

## 10. Open items / decisions for the implementer

- **`engine:check`** — no equivalent exists in `check.sh` today. Define one (a
  real pixi test/build) or consciously skip. (§6)
- **moon.yml placement** — recommended per-submodule vs. centralized in `.moon/`.
  (§5) Default to per-submodule unless touching sub-repos is disallowed.
- **`ios.sh` run task** — wrap the script vs. inline the bash. (§6) Default: wrap.
- **`scripts/` disposition** — keep as wrappers/history vs. delete superseded
  ones. (§6) Default: keep `ios.sh` + rename scripts; drop build/check scripts.
- **Rename scripts** — keep for reference, namespace as `migrate:*`, or delete.
- **`app` sub-projects** — modeled as `app-ios` / `app-server` / `app-web` under
  the single `app` submodule. Confirm `app/web` actually has a buildable target
  before wiring `app-web` (not verified here).
```

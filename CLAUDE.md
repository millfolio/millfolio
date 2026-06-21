# millfolio — superproject

This is the **moon workspace / git superproject** that ties together millfolio's
repos (each a submodule). The personal-data-vault product is: a combined
inference server (`engine`) + a privacy/sandbox orchestrator (`vault/privacy-box`)
+ vault tools/indexer (`vault/core`) + the `mill` CLI (`vault/cli`) + the web app
(`app/`), shipped to users as one downloadable bundle and a Homebrew formula.

Commands below are run from the superproject root (`/Users/mseritan/dev/millfolio`)
unless noted. `moon` is at `~/.moon/bin/moon` and on PATH.

## Releases

The release pipeline lives in `scripts/` (moon project name: `release`).

```bash
moon run release:publish -- vX.Y.Z   # tag vault → CI builds+attaches both assets → bump tap
moon run release:verify              # check the latest published release is consistent
moon run release:verify -- vX.Y.Z    # …or a specific tag
```

- **publish** (`scripts/release.sh`): tags `vault` (`vX.Y.Z`), waits for both
  release assets (`millfolio.zip` + `mill-macos.tar.gz`) to attach, bumps the
  Homebrew formula in `millfolio/homebrew-tap`, syncs the formula template back.
  Side-effecting (tags/pushes) — never cached.
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
`pdftotext`, `csv`, `jinja2`, `zlib`).

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
| `scripts` | release orchestration (`release`/`verify`) |
| `website` | millfolio.app marketing site |

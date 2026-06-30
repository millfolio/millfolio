#!/usr/bin/env bash
#
# release_preflight.sh — build the release bundle (millfolio.zip) LOCALLY and COMPILE its
# components, so a packaging gap fails HERE (before the tag) instead of at install time
# for users.
#
# Two layers, because they catch different bugs:
#   1. `package_bundle.sh` — runs every component packager; catches packaging-SCRIPT
#      failures (a `cp` of a missing path, a libs vendoring gap).
#   2. compile the bundle — `mill install` BUILDS privacy_box + the app server at install
#      time from the bundle's copied source, so a module that wasn't copied into the
#      bundle (e.g. runqueue.mojo) only fails THERE. So we extract the bundle and run the
#      SAME `mojo build` the installer runs. THIS is what catches the v0.4.30/runqueue
#      class of bug before a release ships.
#
# Slow (builds the engine + app web, then compiles) — that's the point; releases are rare
# and a broken one is expensive. Needs the dev pixi envs (run a normal build once first).
#
#   moon run release:preflight        (or: bash scripts/release_preflight.sh)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
OUT="$TMP/millfolio.zip"

# ── [0/3] engine GPU gates ──────────────────────────────────────────────────
# The engine ships as source and is compiled on the user's GPU at install time, so
# the bundle compile-check below never exercises the Metal path. Run the weight-free
# GPU gates here (on this Metal-capable machine) so a GPU/Metal regression blocks the
# release BEFORE the tag. Needs the Xcode Metal Toolchain (see the gpu-metal-toolchain
# note: `xcodebuild -downloadComponent MetalToolchain`).
echo "==> [0/3] engine GPU gates (Metal: gpu-hello + kernels + simd-gemm + attention)…"
if ! xcrun metal --version >/dev/null 2>&1; then
  echo "error: Metal Toolchain missing — run: xcodebuild -downloadComponent MetalToolchain" >&2
  exit 1
fi
( cd "$ROOT/engine" && pixi run test-gpu )
echo "    ✓ GPU gates pass"

# ── codegen prompt examples compile ─────────────────────────────────────────
# Every ```mojo example in privacy_box-system.md is a real program the frontier
# model imitates; compile each against the vault package so a broken example (a
# wrong tool/field like the `.id` vs `.alias` regression) can't ship. Cheap; runs
# before the slow bundle build. (Lives here, not in the hermetic vault `test`, so
# it has the sibling lib repos on the -I path.)
echo "==> codegen prompt examples compile against the vault package…"
( cd "$ROOT/vault" && pixi run bash scripts/check_prompt_examples.sh )
echo "    ✓ prompt examples compile"

echo "==> [1/3] building millfolio.zip locally…"
( cd "$ROOT/vault" && bash scripts/package_bundle.sh "$OUT" )
[[ -s "$OUT" ]] || { echo "error: package_bundle.sh produced no millfolio.zip" >&2; exit 1; }

echo "==> [2/3] compile-checking the bundle ($(du -h "$OUT" | cut -f1)) — the install-time builds…"
EX="$TMP/extract"; mkdir -p "$EX"; unzip -q "$OUT" -d "$EX"

# Run the SAME `mojo build` invocations the Bootstrapper runs at install time, against
# the EXTRACTED bundle (so a module missing from the bundle fails here). Keep the -I sets
# in sync with vault/cli/Sources/MillfolioCore/Bootstrapper.swift (installPrivacyBox /
# installAppServer). Compile only — the FFI shims are dlopen'd at runtime, not linked.
compile() {  # $1 = subdir under the extracted bundle ; $2 = mojo-build args (one string)
  echo "    mojo build  (in $1)"
  ( cd "$ROOT/vault" && pixi run bash -c "cd '$EX/$1' && mkdir -p build && mojo build $2" )
}
compile "privacy_box/privacy_box" \
  "src/privacy_box.mojo -I ../flare -I ../json -I ../jinja2.mojo/src -I ../logging.mojo/src -o build/privacy_box"
compile "app" \
  "src/server.mojo -I src -I ../privacy_box/privacy_box/src -I ../privacy_box/flare -I ../privacy_box/json -I ../privacy_box/jinja2.mojo/src -I ../privacy_box/logging.mojo/src -I ../millfolio/millfolio/pkgs -o build/millfolio-server"

echo "✅ GPU gates pass + bundle builds AND compiles (privacy_box + app server). Safe to release."

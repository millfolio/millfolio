#!/usr/bin/env bash
#
# release_preflight.sh — build the release bundle (millfolio.zip) LOCALLY and COMPILE its
# components, so a packaging gap fails HERE (before the tag) instead of at install time
# for users.
#
# The guard has two halves, because the binaries split into two build models:
#   • privacy_box + the app server + millfolio ship PREBUILT — their (CPU-only)
#     packagers `mojo build` them, so a vendoring gap (the v0.4.30/runqueue class
#     of bug) fails inside `package_bundle.sh` HERE, before the tag. We then assert
#     those three binaries are actually in the bundle.
#   • the engine ships SOURCE and is compiled ON-DEVICE — its AOT GPU/Metal kernels
#     can't build on the GPU-less GitHub CI runner ("Unknown GPU architecture
#     detected"). So THIS local, GPU-equipped preflight is the ONLY place its full
#     bundle compile is exercised: we run the installer's exact `mojo build` against
#     the extracted engine source (catches a missing jinja2/flare vendoring gap).
#
# Slow (builds the engine + app web, then compiles) — that's the point; releases
# are rare and a broken one is expensive. Needs the dev pixi envs.
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

echo "==> [1/3] building millfolio.zip locally (compiles the 3 prebuilt CPU binaries)…"
# package_bundle.sh runs every component packager. The privacy_box + app + millfolio
# packagers `mojo build` their binaries with the exact include set the installer
# used, so a vendoring gap or a broken example fails RIGHT HERE. The engine packager
# ships source (no build).
( cd "$ROOT/vault" && bash scripts/package_bundle.sh "$OUT" )
[[ -s "$OUT" ]] || { echo "error: package_bundle.sh produced no millfolio.zip" >&2; exit 1; }

EX="$TMP/extract"; mkdir -p "$EX"; unzip -q "$OUT" -d "$EX"

echo "==> [2/3] confirming the bundle carries the 3 PREBUILT CPU binaries…"
for b in privacy_box/privacy_box/build/privacy_box \
         app/build/millfolio-server \
         millfolio/millfolio/build/millfolio; do
  [[ -x "$EX/$b" ]] || { echo "error: bundle missing prebuilt binary: $b" >&2; exit 1; }
  echo "    ✓ $b"
done

echo "==> [3/3] compile-checking the ENGINE from the bundle SOURCE — the on-device build…"
# The engine ships source + compiles on-device; CI can't build it (no GPU). This
# GPU-equipped preflight is the only place its full bundle compile runs — the SAME
# `mojo build` the installer (Bootstrapper.installServer) runs, against the extracted
# engine source, so a missing jinja2/flare vendoring gap fails here before the tag.
[[ -f "$EX/runner/inference-server/src/server.mojo" ]] || { echo "error: engine bundle missing SOURCE src/server.mojo" >&2; exit 1; }
( cd "$ROOT/engine" && pixi run bash -c "cd '$EX/runner/inference-server' && mkdir -p build && mojo build src/server.mojo -I ../jinja2.mojo/src -I ../flare -o build/server" )
echo "    ✓ engine compiles from bundle source"

echo "✅ GPU gates pass + bundle builds (privacy_box + app + millfolio prebuilt) + engine compiles on-device. Safe to release."

#!/usr/bin/env bash
#
# release_preflight.sh — build the release bundle (millfolio.zip) LOCALLY and COMPILE its
# components, so a packaging gap fails HERE (before the tag) instead of at install time
# for users.
#
# The guard: `package_bundle.sh` now BUILDS all four of our Mojo binaries (engine
# server + download, privacy_box, app millfolio-server) inside the component
# packagers — they ship PREBUILT, no on-device `mojo build` at install time. So a
# module that wasn't vendored into a packager's include set (the v0.4.30/runqueue
# class of bug) fails the packager's `mojo build` HERE, before the tag — there is
# no separate install-time compile left to catch it. (Previously this script
# re-ran the installer's `mojo build` against the extracted bundle; that compile
# now lives in the packagers, so the extra step is gone.)
#
# Slow (builds the engine + app web, then compiles all four binaries) — that's the
# point; releases are rare and a broken one is expensive. Needs the dev pixi envs.
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

echo "==> [1/2] building millfolio.zip locally (compiles all four prebuilt binaries)…"
# package_bundle.sh runs every component packager, and each packager now `mojo
# build`s its binary (engine server+download, privacy_box, app millfolio-server)
# with the exact include set the installer used — so a vendoring gap or a broken
# example fails RIGHT HERE.
( cd "$ROOT/vault" && bash scripts/package_bundle.sh "$OUT" )
[[ -s "$OUT" ]] || { echo "error: package_bundle.sh produced no millfolio.zip" >&2; exit 1; }

echo "==> [2/2] confirming the bundle carries the four PREBUILT binaries…"
EX="$TMP/extract"; mkdir -p "$EX"; unzip -q "$OUT" -d "$EX"
for b in runner/inference-server/build/server \
         runner/inference-server/build/download \
         privacy_box/privacy_box/build/privacy_box \
         app/build/millfolio-server \
         millfolio/millfolio/build/millfolio; do
  [[ -x "$EX/$b" ]] || { echo "error: bundle missing prebuilt binary: $b" >&2; exit 1; }
  echo "    ✓ $b"
done

echo "✅ GPU gates pass + bundle builds with all prebuilt binaries (engine + privacy_box + app + millfolio). Safe to release."

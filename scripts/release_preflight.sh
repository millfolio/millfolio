#!/usr/bin/env bash
#
# release_preflight.sh — build the release bundle (millfolio.zip) LOCALLY, against your
# local sibling repos, so a packaging/checkout gap fails HERE instead of in CI after the
# tag is already live (which ships a broken release: the tag + the CLI asset attach, but
# millfolio.zip never builds, and `mill install` then 404s on the bundle — exactly what
# happened with v0.4.29 when logging.mojo wasn't vendored/checked out).
#
# This runs the real `vault/scripts/package_bundle.sh`, so it exercises every component
# packager (engine, privacy_box+vendored libs, vault core, app) the same way CI does.
# It is SLOW (builds the engine + the app web UI) — that's the point; releases are rare
# and a broken one is expensive. Needs the dev pixi envs (run a normal build once first).
#
#   moon run release:preflight        (or: bash scripts/release_preflight.sh)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
OUT="$TMP/millfolio.zip"

echo "==> release preflight: building millfolio.zip locally (catches packaging gaps unit tests can't)…"
( cd "$ROOT/vault" && bash scripts/package_bundle.sh "$OUT" )

[[ -s "$OUT" ]] || { echo "error: package_bundle.sh produced no millfolio.zip" >&2; exit 1; }
echo "✅ bundle builds — $(du -h "$OUT" | cut -f1). Safe to release."

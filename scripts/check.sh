#!/usr/bin/env bash
# Build/check every repo in one shot — Swift targets via `swift build`, Mojo repos
# via `pixi run <task>` (resolves the pinned toolchain on first run). Continues on
# failure and prints a pass/fail summary. Review once; run by absolute path:
#   /Users/mseritan/dev/millfolio/scripts/check.sh
set -uo pipefail
ROOT="/Users/mseritan/dev/millfolio"
RESULTS=()

run() {                       # run <label> <dir> <cmd...>
  local label="$1" dir="$2"; shift 2
  printf '\n──────── %s ────────\n' "$label"
  if ( cd "$ROOT/$dir" && "$@" ) >"/tmp/mf-check-$label.log" 2>&1; then
    echo "  ✅ $label"; RESULTS+=("✅ $label")
  else
    echo "  ❌ $label  → /tmp/mf-check-$label.log"
    tail -8 "/tmp/mf-check-$label.log" | sed 's/^/     /'
    RESULTS+=("❌ $label")
  fi
}

# ── Swift ────────────────────────────────────────────────────────────────────
run mill     vault/cli      swift build --product mill
run menu-bar menu-bar/menu  swift build

# ── Mojo (one representative build/test per repo; pixi resolves the b3 toolchain)
run flare       flare           pixi run test-quic-varint
run json        json            pixi run mojo -I . tests/test_value.mojo
run jinja2      jinja2.mojo     pixi run build
run zlib        zlib.mojo       pixi run test
run csv         csv.mojo        pixi run test
run pdftotext   pdftotext.mojo  pixi run build
run lancedb     lancedb.mojo    pixi run test
run vault-mojo  vault           pixi run build
run app-server  app/server      pixi run build-ws

# ── summary ──────────────────────────────────────────────────────────────────
echo; echo "════════ SUMMARY ════════"
printf '%s\n' "${RESULTS[@]}"
printf '%s\n' "${RESULTS[@]}" | grep -q '❌' && { echo; echo "some checks FAILED"; exit 1; } || echo "ALL OK"

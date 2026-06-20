#!/usr/bin/env bash
# Build + sanity-check the Swift targets touched by the millrace/veilens→millfolio
# rename. Read-only except for build artifacts under each package's .build/.
# Review once; safe to run repeatedly.
set -uo pipefail
ROOT="/Users/mseritan/dev/millfolio"
fail=0

build() {
  local name="$1" dir="$2"; shift 2
  printf '── %-10s ' "$name"
  if ( cd "$dir" && swift build "$@" ) >"/tmp/mf-build-$name.log" 2>&1; then
    echo "✅ OK"
  else
    echo "❌ FAILED ($(grep -c 'error:' "/tmp/mf-build-$name.log") errors)  → /tmp/mf-build-$name.log"
    grep 'error:' "/tmp/mf-build-$name.log" | head -10 | sed 's/^/     /'
    fail=1
  fi
}

build mill     "$ROOT/vault/cli"      --product mill
build menu-bar "$ROOT/menu-bar/menu"

echo
[ "$fail" -eq 0 ] && echo "ALL BUILDS OK" || echo "SOME BUILDS FAILED"
exit "$fail"

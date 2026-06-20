#!/usr/bin/env bash
# Report leftover millrace / veilens / millfolioapp references in the four repos
# touched by the rename (engine, vault, app, menu-bar). Source only — build
# artifacts, generated projects, and deps are excluded.
#
# Two intentional kinds of hit are filtered out:
#   - the migration code in Bootstrapper.swift (it references the legacy millrace paths)
#   - the `MillfolioApp` SwiftUI struct (case-insensitively contains "millfolioapp")
set -uo pipefail
ROOT="/Users/mseritan/dev/millfolio"
DIRS=(engine vault app menu-bar)
EXCL=(--exclude-dir=.git --exclude-dir=.build --exclude-dir=node_modules
      --exclude-dir=.pixi --exclude-dir=DerivedData --exclude-dir='*.xcodeproj'
      --exclude-dir=dist --exclude-dir=.scratch)

cd "$ROOT" || exit 1

# millrace / veilens: case-insensitive (catches Millrace/Veilens). millfolioapp:
# case-SENSITIVE so it doesn't match the MillfolioApp struct or millfolio-app names.
mv=$(grep -rnI -i -e millrace -e veilens "${EXCL[@]}" "${DIRS[@]}" 2>/dev/null \
       | grep -v 'Bootstrapper.swift.*[Mm]illrace')
app=$(grep -rnI millfolioapp "${EXCL[@]}" "${DIRS[@]}" 2>/dev/null)

hits=$(printf '%s\n%s\n' "$mv" "$app" | sed '/^$/d')
if [ -z "$hits" ]; then
  echo "✅ clean — no unexpected millrace/veilens/millfolioapp refs in: ${DIRS[*]}"
else
  echo "⚠ $(printf '%s\n' "$hits" | wc -l | tr -d ' ') hit(s):"
  printf '%s\n' "$hits" | sed 's/^/  /'
fi

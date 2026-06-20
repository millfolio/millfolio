#!/usr/bin/env bash
# Finish the millrace/veilens → millfolio rename across the four repos
# (engine, vault, app, menu-bar). Idempotent: safe to run repeatedly.
#
# Ordered rules (specific → general) so org slugs, the brew tap, config/cache
# paths, the launchd label, and the OpenAI-compat identity are mapped correctly
# before the catch-all brand replacement.
#
# DELIBERATELY EXCLUDED:
#   - Bootstrapper.swift  — its migration code references the legacy millrace paths on purpose
#   - .claude/settings.local.json — local, historical allow-list (absolute dev paths)
#   - bench/results/**    — recorded benchmark data (labels + filenames are historical)
#   - .git/.build/node_modules/.pixi/DerivedData/*.xcodeproj/dist/.scratch — generated/vendored
set -uo pipefail
ROOT="/Users/mseritan/dev/millfolio"
cd "$ROOT" || exit 1

# Files to edit: those containing a target token, minus the protected set. grep -I
# skips binaries, so icons/images are never touched. (while-read for bash 3.2 compat.)
n=0
grep -rlI -i -e millrace -e veilens -e millfolioapp engine vault app menu-bar \
    --exclude-dir=.git --exclude-dir=.build --exclude-dir=node_modules \
    --exclude-dir=.pixi --exclude-dir=DerivedData --exclude-dir='*.xcodeproj' \
    --exclude-dir=dist --exclude-dir=.scratch --exclude-dir=results 2>/dev/null \
  | grep -v 'Bootstrapper.swift$' \
  | grep -v 'settings.local.json$' \
  | while IFS= read -r f; do
  n=$((n+1))
  sed -i '' \
    -e 's#millrace/inference-server#millfolio/engine#g' \
    -e 's#github.com/millrace/millrace#github.com/millfolio/engine#g' \
    -e 's#millfolioapp/tap/millfolio#millfolio/tap/mill#g' \
    -e 's#millfolioapp/#millfolio/#g' \
    -e 's#millrace/#millfolio/#g' \
    -e 's#Application Support/Millrace#Application Support/Millfolio#g' \
    -e 's#config/millrace#config/millfolio#g' \
    -e 's#cache/millrace#cache/millfolio#g' \
    -e 's#me\.millrace\.server#me.millfolio.server#g' \
    -e 's#MILLRACE#MILLFOLIO#g' \
    -e 's#Millrace#Millfolio#g' \
    -e 's#millrace#millfolio#g' \
    -e 's#VEILENS#MILLFOLIO#g' \
    -e 's#Veilens#Millfolio#g' \
    -e 's#veilens#millfolio#g' \
    "$f"
done

echo "edited files containing the tokens."

# Rename the one mis-named workflow file (content already fixed above).
old="$ROOT/vault/core/.github/workflows/veilens-zip.yml"
new="$ROOT/vault/core/.github/workflows/millfolio-zip.yml"
[ -f "$old" ] && { mv "$old" "$new" && echo "renamed: veilens-zip.yml → millfolio-zip.yml"; }

echo "done."

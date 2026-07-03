#!/usr/bin/env bash
# Assemble demo-vault.zip from the generated files. Not committed as an asset —
# host the resulting zip as the onboarding "Download demo data" release asset.
#   ./build_zip.sh [out-dir] [zip-path]
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="${1:-$here/out}"
zip_path="${2:-$here/demo-vault.zip}"

tmp="$(mktemp -d)/demo-vault"
mkdir -p "$tmp"
cp "$out"/*.csv "$out"/*.pdf "$tmp/"
( cd "$(dirname "$tmp")" && zip -X -r "$zip_path" demo-vault >/dev/null )
echo "built $zip_path"
unzip -l "$zip_path"

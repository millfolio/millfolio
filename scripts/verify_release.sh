#!/usr/bin/env bash
# Verify a published millfolio release: both release assets are attached AND the
# Homebrew tap formula points at that version.
#
# Usage (via moon):  moon run release:verify -- vX.Y.Z
#        directly:   scripts/verify_release.sh vX.Y.Z
# With no version, checks whatever the tap currently pins (i.e. "is the latest
# published release fully consistent?").
set -euo pipefail

command -v gh >/dev/null || { echo "gh CLI not found" >&2; exit 1; }

TAP_VERSION="$(gh api repos/millfolio/homebrew-tap/contents/Formula/mill.rb \
  -q '.content' 2>/dev/null | base64 -d 2>/dev/null \
  | sed -nE 's/^[[:space:]]*version "([^"]+)".*/\1/p' | head -1)"

VERSION="${1:-v${TAP_VERSION}}"
[[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "version must be vX.Y.Z (got '$VERSION')" >&2; exit 2; }

echo "==> verifying $VERSION"
ok=1

# 1. release assets
assets="$(gh release view "$VERSION" -R millfolio/vault --json assets -q '.assets[].name' 2>/dev/null || true)"
for asset in millfolio.zip mill-macos.tar.gz; do
  if grep -qx "$asset" <<<"$assets"; then
    echo "   ✓ asset $asset"
  else
    echo "   ✗ asset $asset MISSING"; ok=0
  fi
done

# 2. tap formula version
if [ "$TAP_VERSION" = "${VERSION#v}" ]; then
  echo "   ✓ tap formula → $TAP_VERSION"
else
  echo "   ✗ tap formula is $TAP_VERSION, expected ${VERSION#v}"; ok=0
fi

if [ "$ok" = 1 ]; then
  echo "✅ $VERSION is live — both assets attached, tap → ${VERSION#v}"
else
  echo "❌ $VERSION is NOT fully published (see ✗ above)" >&2; exit 1
fi

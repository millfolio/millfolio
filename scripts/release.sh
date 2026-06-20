#!/usr/bin/env bash
# Cut a millfolio release end-to-end:
#   1. tag `vault` (vX.Y.Z) → CI builds + attaches millfolio.zip + mill-macos.tar.gz
#   2. wait for both release assets
#   3. bump the Homebrew formula in millfolio/homebrew-tap to the published tag
#   4. sync the formula template back into vault
#
# Usage (via moon):  moon run release:publish -- vX.Y.Z
#        directly:   scripts/release.sh vX.Y.Z
set -euo pipefail
VERSION="${1:?usage: release.sh vX.Y.Z}"
[[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "version must be vX.Y.Z (got '$VERSION')" >&2; exit 2; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VAULT="$ROOT/vault"
TIMEOUT_TRIES=120; SLEEP=20   # ~40 min max per asset

command -v gh >/dev/null || { echo "gh CLI not found" >&2; exit 1; }
[ -z "$(git -C "$VAULT" status --porcelain)" ] || { echo "vault working tree is dirty — commit/stash first" >&2; exit 1; }

# 1. tag + push vault
git -C "$VAULT" fetch -q origin
if git -C "$VAULT" ls-remote --tags --exit-code origin "refs/tags/$VERSION" >/dev/null 2>&1; then
  echo "==> tag $VERSION already on origin — skipping tag, will still wait for assets" >&2
else
  git -C "$VAULT" tag -a "$VERSION" -m "mill ${VERSION#v}"
  git -C "$VAULT" push origin "$VERSION"
  echo "==> tagged vault $VERSION → CI building bundle + cli"
fi

# 2. wait for both release assets to appear
for asset in millfolio.zip mill-macos.tar.gz; do
  echo "==> waiting for $asset (timeout ~$((TIMEOUT_TRIES*SLEEP/60)) min)…"
  for i in $(seq 1 "$TIMEOUT_TRIES"); do
    if gh release view "$VERSION" -R millfolio/vault --json assets -q '.assets[].name' 2>/dev/null | grep -qx "$asset"; then
      echo "   ✓ $asset"; break
    fi
    [ "$i" = "$TIMEOUT_TRIES" ] && { echo "timed out waiting for $asset (check the Actions tab)" >&2; exit 1; }
    sleep "$SLEEP"
  done
done

# 3. bump the Homebrew formula + publish to the tap
( cd "$VAULT/cli" && MILL_REPO=millfolio/vault dist/homebrew/update-formula.sh "$VERSION" )
TAP="$(mktemp -d)/homebrew-tap"
git clone -q git@github.com:millfolio/homebrew-tap.git "$TAP"
cp "$VAULT/cli/dist/homebrew/mill.rb" "$TAP/Formula/mill.rb"
if [ -n "$(git -C "$TAP" status --porcelain)" ]; then
  git -C "$TAP" commit -q -am "mill ${VERSION#v}" && git -C "$TAP" push -q origin HEAD
  echo "==> tap published mill ${VERSION#v}"
else
  echo "==> tap already at ${VERSION#v}"
fi

# 4. sync the source-of-truth formula template back into vault
if [ -n "$(git -C "$VAULT" status --porcelain cli/dist/homebrew/mill.rb)" ]; then
  git -C "$VAULT" commit -q -m "cli: bump mill.rb template to $VERSION" cli/dist/homebrew/mill.rb
  git -C "$VAULT" push -q origin main
fi
echo "==> done. Install:  brew install millfolio/tap/mill   ($VERSION)"

#!/usr/bin/env bash
# Promote a tested DEV (pre-release) build to PROD — with NO rebuild.
#
# Takes the millfolio.zip + mill-macos.tar.gz that CI already built for a tested
# vX.Y.Z-rc.N pre-release and COPIES them to a clean vX.Y.Z full release (marked
# latest), then bumps the prod `mill` formula to point at them. Because nothing is
# rebuilt, what ships to prod is byte-identical to what you tested.
#
#   moon run release:promote -- vX.Y.Z            # promote the latest vX.Y.Z-rc.N
#   moon run release:promote -- vX.Y.Z vX.Y.Z-rc.2  # …or an explicit source rc
#
# Plain vX.Y.Z tags do NOT trigger CI (the build workflows fire only on v*-* tags),
# so the copied assets are never clobbered by a rebuild.
set -euo pipefail

PROD="${1:?usage: promote.sh vX.Y.Z [vX.Y.Z-rc.N]}"
[[ "$PROD" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "prod version must be vX.Y.Z, no suffix (got '$PROD')" >&2; exit 2; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VAULT="$ROOT/vault"
REPO="millfolio/vault"

command -v gh >/dev/null || { echo "gh CLI not found" >&2; exit 1; }
[ -z "$(git -C "$VAULT" status --porcelain)" ] || { echo "vault working tree is dirty — commit/stash first" >&2; exit 1; }

# 1. resolve the source rc (explicit arg, else the highest vX.Y.Z-rc.N pre-release)
SRC="${2:-}"
if [ -z "$SRC" ]; then
  SRC="$(gh api "repos/$REPO/releases?per_page=100" -q '.[].tag_name' \
        | grep -E "^${PROD}-rc\.[0-9]+$" | sort -V | tail -1 || true)"
  [ -n "$SRC" ] || { echo "no ${PROD}-rc.N pre-release found to promote (publish one first)" >&2; exit 1; }
fi
echo "==> promoting $SRC → $PROD"

# 2. the source rc must carry BOTH assets
for asset in millfolio.zip mill-macos.tar.gz; do
  gh release view "$SRC" -R "$REPO" --json assets -q '.assets[].name' 2>/dev/null | grep -qx "$asset" \
    || { echo "source $SRC is missing $asset — is the dev build complete?" >&2; exit 1; }
done

# 3. the commit the rc tag points at (deref an annotated tag to its commit)
SHA="$(gh api "repos/$REPO/git/ref/tags/$SRC" -q '.object.sha')"
OTYPE="$(gh api "repos/$REPO/git/ref/tags/$SRC" -q '.object.type')"
[ "$OTYPE" = tag ] && SHA="$(gh api "repos/$REPO/git/tags/$SHA" -q '.object.sha')"
echo "==> source commit $SHA"

# 4. download the tested assets
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
gh release download "$SRC" -R "$REPO" -p millfolio.zip -p mill-macos.tar.gz -D "$TMPD" --clobber
[ -s "$TMPD/millfolio.zip" ] && [ -s "$TMPD/mill-macos.tar.gz" ] || { echo "asset download failed" >&2; exit 1; }

# 5. create the clean prod release at the SAME commit, marked latest, with the COPIES
if gh release view "$PROD" -R "$REPO" >/dev/null 2>&1; then
  echo "==> release $PROD already exists — re-uploading assets (clobber)"
  gh release upload "$PROD" -R "$REPO" "$TMPD/millfolio.zip" "$TMPD/mill-macos.tar.gz" --clobber
else
  gh release create "$PROD" -R "$REPO" --target "$SHA" --title "mill ${PROD#v}" --latest \
    --notes "Promoted from ${SRC} (same artifacts, no rebuild)." \
    "$TMPD/millfolio.zip" "$TMPD/mill-macos.tar.gz"
fi
echo "==> prod release $PROD published (latest)"

# 6. bump the prod `mill` formula to the promoted assets + publish to the tap
( cd "$VAULT/cli" && MILL_REPO="$REPO" dist/homebrew/update-formula.sh "$PROD" )
TAP="$(mktemp -d)/homebrew-tap"
git clone -q git@github.com:millfolio/homebrew-tap.git "$TAP"
cp "$VAULT/cli/dist/homebrew/mill.rb" "$TAP/Formula/mill.rb"
git -C "$TAP" add Formula/mill.rb   # robust whether mill.rb is tracked or brand-new
if ! git -C "$TAP" diff --cached --quiet; then
  git -C "$TAP" commit -q -m "mill ${PROD#v}"
  git -C "$TAP" push -q origin HEAD
  echo "==> tap published mill ${PROD#v}"
else
  echo "==> tap already at mill ${PROD#v}"
fi

# 7. sync the source-of-truth prod formula template back into vault. `git add` FIRST
# (robust whether mill.rb is already tracked or brand-new) — `git commit <pathspec>`
# matches only tracked files, so a never-before-committed formula would fail.
git -C "$VAULT" add cli/dist/homebrew/mill.rb
if ! git -C "$VAULT" diff --cached --quiet -- cli/dist/homebrew/mill.rb; then
  git -C "$VAULT" commit -q -m "cli: bump mill.rb template to $PROD" -- cli/dist/homebrew/mill.rb
  git -C "$VAULT" push -q origin main
fi

echo "==> done. Public install:  brew install millfolio/tap/mill   ($PROD)"
echo "==> verify:                moon run release:verify -- $PROD"

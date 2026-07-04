#!/usr/bin/env bash
# Cut a millfolio DEV (pre-release) build end-to-end:
#   1. tag `vault` (vX.Y.Z-rc.N) → CI builds + attaches millfolio.zip + mill-macos.tar.gz
#      to a PRE-RELEASE (kept off /releases/latest, so prod users never see it)
#   2. wait for both release assets
#   3. bump the dev Homebrew formula (mill-dev) in millfolio/homebrew-tap
#   4. sync the dev formula template back into vault
#
# This is the DEV channel. You test it (`brew upgrade millfolio/tap/mill-dev &&
# mill-dev install`), then ship the SAME artifacts to prod with NO rebuild:
#   moon run release:promote -- vX.Y.Z
#
# Usage (via moon):  moon run release:publish -- vX.Y.Z-rc.N
#        directly:   scripts/release.sh vX.Y.Z-rc.N
set -euo pipefail
VERSION="${1:?usage: release.sh vX.Y.Z-rc.N}"
if [[ ! "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-(rc|beta|dev)\.[0-9]+$ ]]; then
  echo "version must be a PRE-RELEASE vX.Y.Z-rc.N (got '$VERSION')." >&2
  echo "  Dev builds carry a -rc.N / -beta.N / -dev.N suffix. Prod is cut from a tested" >&2
  echo "  rc with:  moon run release:promote -- vX.Y.Z   (copies the assets, no rebuild)." >&2
  exit 2
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VAULT="$ROOT/vault"
TIMEOUT_TRIES=120; SLEEP=20   # ~40 min max per asset

command -v gh >/dev/null || { echo "gh CLI not found" >&2; exit 1; }
[ -z "$(git -C "$VAULT" status --porcelain)" ] || { echo "vault working tree is dirty — commit/stash first" >&2; exit 1; }

# 0. PREFLIGHT — build the bundle locally BEFORE tagging, so a packaging/checkout gap
# fails here (no tag, no harm) instead of in CI after the tag is live (a broken release
# with the tag + CLI attached but no millfolio.zip → mill install 404s). Override with
# RELEASE_SKIP_PREFLIGHT=1 only when you know the bundle already builds.
if [ "${RELEASE_SKIP_PREFLIGHT:-0}" != 1 ]; then
  bash "$ROOT/scripts/release_preflight.sh" || {
    echo "error: bundle preflight FAILED — NOT tagging $VERSION. Fix the packaging, then re-run." >&2
    echo "       (override with RELEASE_SKIP_PREFLIGHT=1 if you're certain the bundle builds.)" >&2
    exit 1
  }
fi

# 0.5 PIN SIBLINGS — freeze each sibling repo at its CURRENT main tip and commit the
# list into vault as .github/bundle-pins.env, so the tagged CI bundle build checks out
# these EXACT commits (reproducible + pinned to what this release was cut from) instead
# of whatever each sibling's main happens to be whenever CI runs. The pins are read
# LIVE from each remote here, so they auto-refresh every publish — "push a feature to a
# sibling's main → cut an rc" still gets the latest, it's just frozen into the tag.
# bundle.yml consumes this file only on tag builds; main/PR builds stay unpinned.
# NOTE: keep this list identical to the checkouts in vault/.github/workflows/bundle.yml.
PINS="$VAULT/.github/bundle-pins.env"
BUNDLE_SIBLINGS=(engine app flare json jinja2.mojo lancedb.mojo pdftotext.mojo zlib.mojo csv.mojo docx.mojo logging.mojo)
echo "==> pinning sibling repos to their current main tips"
{
  echo "# Sibling repo pins for a reproducible bundle build — WRITTEN BY scripts/release.sh."
  echo "# <repo path>=<commit sha>, consumed by .github/workflows/bundle.yml. Do NOT hand-edit."
  echo "# Cut for $VERSION at $(date -u +%Y-%m-%dT%H:%M:%SZ)."
} > "$PINS.tmp"
for repo in "${BUNDLE_SIBLINGS[@]}"; do
  sha="$(git ls-remote "git@github.com:millfolio/${repo}.git" refs/heads/main | awk 'NR==1{print $1}')"
  [ -n "$sha" ] || { echo "error: could not resolve main tip for millfolio/$repo (SSH loaded?)" >&2; rm -f "$PINS.tmp"; exit 1; }
  echo "${repo}=${sha}" >> "$PINS.tmp"
  printf '   %-18s %s\n' "$repo" "$sha"
done
mv "$PINS.tmp" "$PINS"
git -C "$VAULT" add .github/bundle-pins.env
if ! git -C "$VAULT" diff --cached --quiet -- .github/bundle-pins.env; then
  git -C "$VAULT" commit -q -m "ci: pin siblings for $VERSION bundle build" -- .github/bundle-pins.env
  git -C "$VAULT" push -q origin main
  echo "==> committed + pushed bundle-pins.env for $VERSION"
else
  echo "==> bundle-pins.env unchanged since last publish"
fi

# 1. tag + push vault  (tags the pins commit above, so the bundle build reads it)
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

# 3. bump the DEV Homebrew formula (mill-dev) + publish to the tap, and publish
#    millfolio.zip's sha256 into the tap so `mill install` can verify the bundle
#    before unpacking+compiling it. The tap is a DIFFERENT repo from the release
#    assets, so a swapped asset can't forge the hash. See
#    Bootstrapper.expectedBundleSHA256.
( cd "$VAULT/cli" && MILL_REPO=millfolio/vault dist/homebrew/update-formula.sh "$VERSION" --dev )
TAP="$(mktemp -d)/homebrew-tap"
git clone -q git@github.com:millfolio/homebrew-tap.git "$TAP"
cp "$VAULT/cli/dist/homebrew/mill-dev.rb" "$TAP/Formula/mill-dev.rb"
BUNDLE_DIR="$(mktemp -d)"
gh release download "$VERSION" -R millfolio/vault -p millfolio.zip -D "$BUNDLE_DIR" --clobber
BUNDLE_SHA="$(shasum -a 256 "$BUNDLE_DIR/millfolio.zip" | awk '{print $1}')"
mkdir -p "$TAP/checksums"
echo "$BUNDLE_SHA  millfolio.zip" > "$TAP/checksums/millfolio-$VERSION.sha256"
echo "==> bundle sha256 $BUNDLE_SHA → checksums/millfolio-$VERSION.sha256"
git -C "$TAP" add Formula/mill-dev.rb "checksums/millfolio-$VERSION.sha256"   # `-a`/`-am` skips an UNTRACKED new formula (first dev release)
if ! git -C "$TAP" diff --cached --quiet; then
  git -C "$TAP" commit -q -m "mill-dev ${VERSION#v}"
  git -C "$TAP" push -q origin HEAD
  echo "==> tap published mill-dev ${VERSION#v} (+ bundle checksum)"
else
  echo "==> tap already at mill-dev ${VERSION#v}"
fi

# 4. sync the source-of-truth dev formula template back into vault. `git add` FIRST
# so the FIRST dev release works: mill-dev.rb is then untracked, and `git commit
# <pathspec>` matches only tracked files ("pathspec did not match").
git -C "$VAULT" add cli/dist/homebrew/mill-dev.rb
if ! git -C "$VAULT" diff --cached --quiet -- cli/dist/homebrew/mill-dev.rb; then
  git -C "$VAULT" commit -q -m "cli: bump mill-dev.rb template to $VERSION" -- cli/dist/homebrew/mill-dev.rb
  git -C "$VAULT" push -q origin main
fi
echo "==> dev build live ($VERSION). Test it:"
echo "      brew install millfolio/tap/mill-dev && mill-dev install   (first time)"
echo "      brew upgrade millfolio/tap/mill-dev && mill-dev install   (a later rc.N)"
echo "==> ship to prod when ready:  moon run release:promote -- ${VERSION%-*}"

#!/usr/bin/env bash
#
# preflight.sh — build + test every project in the moon workspace before code leaves
# the machine. `moon run :check` runs each project's `check` task (the Mojo/Swift build
# + its unit tests); moon CACHES results, so unchanged projects are instant and only
# what you touched re-runs. The git pre-push hook (scripts/install-hooks.sh) runs this.
#
# NOTE: this catches CODE/compile regressions. It does NOT catch the cross-repo packaging
# gaps that only surface in the release bundle build (CI runs that on every push to main,
# and `moon run release:preflight` builds it locally) — see scripts/README / CLAUDE.md.
#
#   bash scripts/preflight.sh            # all projects (cached)
#   bash scripts/preflight.sh --force    # ignore the cache
set -euo pipefail
cd "$(dirname "$0")/.."
MOON="${MOON:-$HOME/.moon/bin/moon}"
echo "==> preflight: moon run :check (build + unit tests, cached)"
exec "$MOON" run :check "$@"

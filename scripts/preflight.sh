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

# Git exports GIT_DIR/GIT_WORK_TREE/etc. into hook processes. `moon run :check`
# shells out to git inside sibling submodules for affected-detection; the inherited
# vars point at the WRONG repo there, which makes those git calls fail or hang
# (e.g. `core.bare and core.worktree do not make sense`) and stalls the whole push.
# Clear the hook's git environment so moon (and its tasks) see each repo normally.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR \
      GIT_NAMESPACE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES \
      GIT_QUARANTINE_PATH 2>/dev/null || true

MOON="${MOON:-$HOME/.moon/bin/moon}"
echo "==> preflight: moon run :check (build + unit tests, cached)"
exec "$MOON" run :check "$@"

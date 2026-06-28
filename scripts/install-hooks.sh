#!/usr/bin/env bash
#
# install-hooks.sh — install the two-tier test-before-commit git hooks in the
# superproject AND every submodule:
#
#   pre-commit → scripts/precommit.sh  — FAST, staged-only: `mojo format --check` on
#                staged Mojo + `svelte-check` on staged web. Runs on every commit.
#   pre-push   → scripts/preflight.sh  — FULL: `moon run :check` (build + unit tests
#                across all projects). Runs once per push; moon's cache makes
#                unchanged projects instant. A failing build/test blocks the push.
#
# Two tiers because the Mojo/Swift builds are too slow for every commit: the cheap
# format/type checks gate commits, the full build+test suite gates pushes. Bypass
# either once with `git commit --no-verify` / `git push --no-verify`.
#
#   bash scripts/install-hooks.sh          # install into superproject + submodules
#   bash scripts/install-hooks.sh --remove # uninstall
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REMOVE=0; [[ "${1:-}" == "--remove" ]] && REMOVE=1

write_hook() {  # $1 = absolute git-dir
  local hooks="$1/hooks"
  if [[ "$REMOVE" == 1 ]]; then
    rm -f "$hooks/pre-push" "$hooks/pre-commit" && echo "  removed: $hooks/{pre-commit,pre-push}"
    return
  fi
  mkdir -p "$hooks"
  cat > "$hooks/pre-push" <<EOF
#!/usr/bin/env bash
# Auto-installed by scripts/install-hooks.sh — full build+test gate before push.
exec "$ROOT/scripts/preflight.sh"
EOF
  cat > "$hooks/pre-commit" <<EOF
#!/usr/bin/env bash
# Auto-installed by scripts/install-hooks.sh — fast staged-file lint before commit.
exec "$ROOT/scripts/precommit.sh"
EOF
  chmod +x "$hooks/pre-push" "$hooks/pre-commit"
  echo "  installed: $hooks/{pre-commit,pre-push}"
}

ACTION=installing; [[ "$REMOVE" == 1 ]] && ACTION=removing
echo "==> $ACTION hooks in the superproject"
write_hook "$(git -C "$ROOT" rev-parse --absolute-git-dir)"

echo "==> $ACTION hooks in each submodule"
# A submodule's git-dir is .git/modules/<name>; resolve it from inside each one.
git -C "$ROOT" submodule --quiet foreach 'true' >/dev/null 2>&1 || { echo "  (no submodules)"; exit 0; }
while IFS= read -r sm; do
  [[ -n "$sm" ]] || continue
  gd="$(git -C "$ROOT/$sm" rev-parse --absolute-git-dir 2>/dev/null)" || continue
  write_hook "$gd"
done < <(git -C "$ROOT" submodule --quiet foreach 'echo "$sm_path"' 2>/dev/null)

echo "done. (bypass once with: git commit --no-verify / git push --no-verify)"

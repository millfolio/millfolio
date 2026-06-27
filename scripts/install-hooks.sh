#!/usr/bin/env bash
#
# install-hooks.sh — install a `pre-push` git hook in the superproject AND every
# submodule, so `scripts/preflight.sh` (moon :check — build + unit tests across all
# projects) runs before any repo pushes to GitHub. A failing build/test blocks the push.
#
# Why pre-PUSH, not pre-commit: the Mojo/Swift builds are too slow to run on every
# commit. Pre-push runs once per push and moon's cache makes unchanged projects instant.
# Bypass a single push with `git push --no-verify` when you must.
#
#   bash scripts/install-hooks.sh          # install into superproject + submodules
#   bash scripts/install-hooks.sh --remove # uninstall
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REMOVE=0; [[ "${1:-}" == "--remove" ]] && REMOVE=1

write_hook() {  # $1 = absolute git-dir
  local hooks="$1/hooks"
  if [[ "$REMOVE" == 1 ]]; then
    rm -f "$hooks/pre-push" && echo "  removed: $hooks/pre-push"
    return
  fi
  mkdir -p "$hooks"
  cat > "$hooks/pre-push" <<EOF
#!/usr/bin/env bash
# Auto-installed by scripts/install-hooks.sh — runs the workspace preflight.
exec "$ROOT/scripts/preflight.sh"
EOF
  chmod +x "$hooks/pre-push"
  echo "  installed: $hooks/pre-push"
}

ACTION=installing; [[ "$REMOVE" == 1 ]] && ACTION=removing
echo "==> $ACTION pre-push hook in the superproject"
write_hook "$(git -C "$ROOT" rev-parse --absolute-git-dir)"

echo "==> $ACTION pre-push hook in each submodule"
# A submodule's git-dir is .git/modules/<name>; resolve it from inside each one.
git -C "$ROOT" submodule --quiet foreach 'true' >/dev/null 2>&1 || { echo "  (no submodules)"; exit 0; }
while IFS= read -r sm; do
  [[ -n "$sm" ]] || continue
  gd="$(git -C "$ROOT/$sm" rev-parse --absolute-git-dir 2>/dev/null)" || continue
  write_hook "$gd"
done < <(git -C "$ROOT" submodule --quiet foreach 'echo "$sm_path"' 2>/dev/null)

echo "done. (bypass once with: git push --no-verify)"

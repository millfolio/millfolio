#!/usr/bin/env bash
#
# precommit.sh — the FAST tier of the test-before-commit workflow (the pre-commit hook
# installed by install-hooks.sh). It runs only on STAGED files in the repo being
# committed, so it stays fast and never blocks on pre-existing/legacy formatting:
#
#   * staged *.mojo   → `mojo format --check` (mblack) in that file's pixi project
#   * staged web files → `npm run check` (svelte-check) in the nearest package.json
#                        project that defines a `check` script
#
# The SLOW tier — build + full unit tests — runs on pre-push via preflight.sh
# (`moon run :check`). Bypass this hook once with `git commit --no-verify`.
#
# Git runs the hook with CWD = the repo root being committed (works for the
# superproject AND each submodule). Written for macOS's stock bash 3.2 (no
# associative arrays / mapfile).
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
cd "$ROOT" || exit 0

FAILED=0
have_pixi=0; command -v pixi >/dev/null 2>&1 && have_pixi=1
have_npm=0;  command -v npm  >/dev/null 2>&1 && have_npm=1

# Walk up from a file to the nearest ancestor dir containing $2; print it (or nothing).
nearest_with() {  # $1 = file ; $2 = marker filename
  local d; d="$(dirname "$1")"
  while [ "$d" != "." ] && [ "$d" != "/" ]; do
    [ -f "$d/$2" ] && { printf '%s\n' "$d"; return 0; }
    d="$(dirname "$d")"
  done
  [ -f "./$2" ] && printf '.\n'
}

web_seen=" "  # space-delimited set of already-checked web project dirs

while IFS= read -r f; do
  [ -n "$f" ] && [ -e "$f" ] || continue
  case "$f" in
    *.mojo)
      # `mojo format` has no --check/--diff (only -q) and writes in place, so we
      # format a COPY and diff it against the working tree. A formatter parse error
      # (mblack can't handle some valid Mojo, e.g. `import … as …`) is treated as a
      # skip — never a block.
      [ "$have_pixi" = 1 ] || continue
      proj="$(nearest_with "$f" pixi.toml)"; [ -n "$proj" ] || continue
      td="$(mktemp -d)" || continue
      cp "$f" "$td/c.mojo" || { rm -rf "$td"; continue; }
      if ( cd "$proj" && pixi run -q mojo format "$td/c.mojo" ) >/dev/null 2>&1; then
        if ! cmp -s "$f" "$td/c.mojo"; then
          echo "pre-commit: ✗ unformatted Mojo: $f"
          echo "            fix: (cd $proj && pixi run mojo format ${f#"$proj"/})"
          FAILED=1
        fi
      fi
      rm -rf "$td"
      ;;
    *.svelte|*.ts|*.js|*.css|*.html|*.svx)
      [ "$have_npm" = 1 ] || continue
      proj="$(nearest_with "$f" package.json)"; [ -n "$proj" ] || continue
      case "$web_seen" in *" $proj "*) continue ;; esac        # already checked this project
      grep -q '"check"' "$proj/package.json" 2>/dev/null || continue
      web_seen="$web_seen$proj "
      echo "pre-commit: svelte-check ($proj)…"
      if ! ( cd "$proj" && npm run -s check >/dev/null 2>&1 ); then
        echo "pre-commit: ✗ typecheck failed: $proj  (fix: cd $proj && npm run check)"
        FAILED=1
      fi
      ;;
  esac
done < <(git diff --cached --name-only --diff-filter=ACM)

[ "$FAILED" = 0 ] && exit 0
echo "pre-commit failed — fix the above, or bypass once with: git commit --no-verify"
exit 1

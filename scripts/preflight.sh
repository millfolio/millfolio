#!/usr/bin/env bash
#
# preflight.sh — build + test only the projects AFFECTED by what you're pushing,
# before code leaves the machine. Scoped via moon's affected graph: the files in the
# commits being pushed select their project(s), and `--downstream deep` adds the
# DEPENDENTS — so a library change (flare/json) still sweeps engine/vault/app, but a
# website or app-only change runs just itself. Whole-workspace coverage still happens
# in CI on push to main and in `moon run release:preflight`.
#
# Installed as the git pre-push hook (scripts/install-hooks.sh) in the superproject and
# every submodule. The hook feeds the push range on stdin; we diff it to changed files.
#
#   bash scripts/preflight.sh           # affected projects (+ dependents)
#   PREFLIGHT_ALL=1 bash scripts/preflight.sh   # force the WHOLE workspace
#   bash scripts/preflight.sh --force   # ignore the moon cache (implies whole workspace)
#
# NOTE: catches CODE/compile regressions. It does NOT catch cross-repo packaging gaps
# that only surface in the release bundle build (CI on push to main + release:preflight).
set -euo pipefail

ZERO=0000000000000000000000000000000000000000

# The repo being pushed — captured BEFORE we cd away (git runs the hook with cwd =
# the pushed repo's top-level; for a submodule that's the submodule working tree).
PUSH_REPO="$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)"

# The push range(s): git pre-push feeds "<localref> <localsha> <remoteref> <remotesha>"
# on stdin. Read it BEFORE anything else consumes stdin. A tty (manual run) has none.
RANGES=""
if [ ! -t 0 ]; then
  while read -r _lref lsha _rref rsha; do
    [ -n "${lsha:-}" ] && RANGES="$RANGES$rsha $lsha
"
  done
fi

cd "$(dirname "$0")/.."
ROOT="$PWD"
MOON="${MOON:-$HOME/.moon/bin/moon}"

# Git exports GIT_DIR/etc into hook processes; cleared so moon (and our git calls)
# see each repo normally — the inherited vars point at the wrong repo otherwise.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR \
      GIT_NAMESPACE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES \
      GIT_QUARANTINE_PATH 2>/dev/null || true

run_full() {
  echo "==> preflight: moon run :check (FULL workspace, cached)"
  exec "$MOON" run :check "$@"
}

# Escape hatch + cache-bypass: always do the whole workspace.
[ "${PREFLIGHT_ALL:-0}" = 1 ] && run_full "$@"
case " $* " in *" --force "*) run_full "$@" ;; esac

# The pushed repo's path relative to the moon workspace root ("" = the superproject).
REL="${PUSH_REPO#"$ROOT"}"
REL="${REL#/}"

CHANGED=""  # newline-delimited, workspace-relative changed paths

# Append the files changed between base..head (workspace-relative). Returns 1 when the
# range can't be scoped reliably (new branch / deletion / missing tip) → caller fulls.
add_range() {
  base="$1"
  head="$2"
  if [ -z "$base" ] || [ -z "$head" ] || [ "$base" = "$ZERO" ] || [ "$head" = "$ZERO" ]; then
    return 1
  fi
  out="$(git -C "$PUSH_REPO" diff --name-only "$base..$head" 2>/dev/null || true)"
  [ -n "$out" ] || return 0
  [ -n "$REL" ] && out="$(printf '%s\n' "$out" | sed "s#^#$REL/#")"
  CHANGED="$CHANGED$out
"
}

if [ -n "$RANGES" ]; then
  while read -r base head; do
    [ -n "$base$head" ] || continue
    add_range "$base" "$head" || run_full "$@"
  done <<EOF
$RANGES
EOF
else
  # Manual run (no stdin): compare HEAD against its upstream, else full.
  up="$(git -C "$PUSH_REPO" rev-parse '@{upstream}' 2>/dev/null || true)"
  if [ -n "$up" ]; then
    add_range "$up" "$(git -C "$PUSH_REPO" rev-parse HEAD)" || run_full "$@"
  else
    run_full "$@"
  fi
fi

CHANGED="$(printf '%s' "$CHANGED" | awk 'NF' | sort -u)"
if [ -z "$CHANGED" ]; then
  echo "==> preflight: no changed files in the push — nothing to check"
  exit 0
fi

count="$(printf '%s\n' "$CHANGED" | wc -l | tr -d ' ')"
echo "==> preflight: moon run :check --affected ($count changed file(s) under '${REL:-<superproject>}', + dependents)"
printf '%s\n' "$CHANGED" | "$MOON" run :check --affected --stdin --downstream deep "$@"

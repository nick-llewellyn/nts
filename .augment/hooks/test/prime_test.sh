#!/usr/bin/env bash
# Session-start context injection in beads-prime.sh.
#
# SessionStart stdout is injected as agent context, so stdout is the whole
# contract: what lands there, and that the hook never exits nonzero. Drives
# the real hook against a scratch workspace with a stubbed `bd`, so nothing
# here touches the repository's own bead store.

set -uo pipefail

HOOK="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/beads-prime.sh}"
[ -r "$HOOK" ] || { echo "FATAL: cannot read hook at $HOOK" >&2; exit 2; }

# The hook runs under the interpreter running this suite, not whichever one
# PATH resolves. CI's macOS leg names /bin/bash to exercise bash 3.2, and a
# bare `bash` here would re-resolve and hand the hook a different version --
# leaving the leg testing only the harness's own syntax. `$BASH` is absolute,
# so it also survives the PATH rewriting these cases do.
BASH_UNDER_TEST="${BASH:-bash}"

PASS=0
FAIL=0
ORIG_PATH="$PATH"

report() {
  if [ "$1" = ok ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL %s\n' "$2"
  fi
}

# Scratch workspace with a stub `bd` that echoes a recognisable context
# block, records the directory it was aimed at, and can be made to fail.
setup() {
  WS=$(mktemp -d)
  mkdir -p "$WS/.beads" "$WS/bin"
  cat >"$WS/bin/bd" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = -C ] && printf '%s\n' "${2:-}" >"${BD_TARGET:?}"
if [ -n "${BD_PRIME_FAIL:-}" ]; then
  echo "prime refused: store locked"
  exit 1
fi
echo "PRIMED-CONTEXT"
exit 0
STUB
  chmod +x "$WS/bin/bd"
  export BD_TARGET="$WS/target"
  : >"$BD_TARGET"
  PATH="$WS/bin:$ORIG_PATH"
}

teardown() {
  rm -rf "$WS"
  PATH="$ORIG_PATH"
  unset BD_PRIME_FAIL BD_TARGET AUGMENT_PROJECT_DIR
}

# Runs the hook and captures stdout; RC is its exit status.
run_hook() {
  OUT=$("$BASH_UNDER_TEST" "$HOOK" 2>/dev/null)
  RC=$?
}

# --- prime output reaches stdout ---------------------------------------
setup
export AUGMENT_PROJECT_DIR="$WS"
run_hook
grep -q PRIMED-CONTEXT <<<"$OUT" && report ok ||
  report bad "bd prime output must be injected as context (got: $OUT)"
[ "$RC" -eq 0 ] && report ok || report bad "hook must exit 0 on success (rc=$RC)"
teardown

# --- the workspace is addressed explicitly -----------------------------
# `bd` inherits the agent's cwd, not the project's, so the hook must pass
# `-C`. Running from elsewhere would otherwise prime the wrong store.
setup
export AUGMENT_PROJECT_DIR="$WS"
(cd / && "$BASH_UNDER_TEST" "$HOOK" >/dev/null 2>&1)
[ "$(cat "$BD_TARGET")" = "$WS" ] && report ok ||
  report bad "bd must be aimed at the project dir (got: $(cat "$BD_TARGET"))"
teardown

# --- a failing prime is reported, not swallowed ------------------------
# Discarding it would start the session with no context and no hint that
# durable task tracking is unavailable.
setup
export AUGMENT_PROJECT_DIR="$WS" BD_PRIME_FAIL=1
run_hook
grep -q "'bd prime' failed" <<<"$OUT" && report ok ||
  report bad "a failed prime must be reported as context (got: $OUT)"
grep -q "store locked" <<<"$OUT" && report ok ||
  report bad "the failure must carry bd's own output (got: $OUT)"
[ "$RC" -eq 0 ] && report ok ||
  report bad "a failed prime must not fail startup (rc=$RC)"
teardown

# --- no bd on PATH -----------------------------------------------------
# PATH is narrowed rather than just deleting the stub: the real `bd` is on
# the inherited PATH, so removing the stub alone would run it for real.
setup
export AUGMENT_PROJECT_DIR="$WS"
rm -f "$WS/bin/bd"
PATH="$WS/bin:/usr/bin:/bin"
run_hook
[ -z "$OUT" ] && report ok ||
  report bad "a missing bd must inject nothing (got: $OUT)"
[ "$RC" -eq 0 ] && report ok ||
  report bad "a missing bd must not fail startup (rc=$RC)"
teardown

# --- no bead store in the workspace ------------------------------------
# A repository that does not use beads must not have context injected into
# every session, nor have its startup fail.
setup
export AUGMENT_PROJECT_DIR="$WS"
rm -rf "$WS/.beads"
run_hook
[ -z "$OUT" ] && report ok ||
  report bad "no .beads must inject nothing (got: $OUT)"
[ "$RC" -eq 0 ] && report ok ||
  report bad "no .beads must not fail startup (rc=$RC)"
teardown

# --- workspace falls back to the cwd -----------------------------------
setup
unset AUGMENT_PROJECT_DIR
OUT=$(cd "$WS" && "$BASH_UNDER_TEST" "$HOOK" 2>/dev/null)
grep -q PRIMED-CONTEXT <<<"$OUT" && report ok ||
  report bad "without AUGMENT_PROJECT_DIR the cwd is the workspace (got: $OUT)"
teardown

echo "prime: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]

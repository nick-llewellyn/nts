#!/usr/bin/env bash
# Inject bd workflow context at session start, mirroring the SessionStart hook
# `bd init` writes for Claude Code and Codex.
#
# SessionStart stdout is injected as agent context, so `bd prime` output goes
# straight to stdout. Always exits 0: a missing `bd` must not fail startup.

set -uo pipefail

BD=$(command -v bd 2>/dev/null) || exit 0

# A relative PATH entry gives a relative path (`bin/bd`, `./bd`), which the
# `cd` below would point elsewhere, so it is anchored here. A bare name, such
# as an exported function, is left to resolve as before.
case "$BD" in
  /*) ;;
  */*) BD="$PWD/$BD" ;;
esac

WORKSPACE="${AUGMENT_PROJECT_DIR:-$PWD}"
[ -d "$WORKSPACE/.beads" ] || exit 0

# `bd` runs from the workspace rather than being aimed at it with `-C`: `bd -C
# <dir> prime` reads `.beads/PRIME.md` from the current directory's store when
# that directory has one, and only the memories from <dir>'s (bd 1.3.2). CDPATH
# is cleared so `cd` neither goes elsewhere nor prints the directory into the
# output.
#
# Discarding the output would start the session with no Beads context and no
# hint that durable task tracking is unavailable. Report the failure as context
# instead, while still exiting 0 so startup is never blocked.
if PRIME_OUT=$(CDPATH='' cd -- "$WORKSPACE" 2>&1 && "$BD" prime 2>&1); then
  printf '%s\n' "$PRIME_OUT"
else
  printf '%s\n' \
    "beads: 'bd prime' failed, so this session has no Beads context and durable task tracking may be unavailable. Output: ${PRIME_OUT}"
fi

exit 0

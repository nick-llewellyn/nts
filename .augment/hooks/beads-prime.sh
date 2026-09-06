#!/usr/bin/env bash
# Inject bd workflow context at session start, mirroring the SessionStart hook
# `bd init` writes for Claude Code and Codex.
#
# SessionStart stdout is injected as agent context, so `bd prime` output goes
# straight to stdout. Always exits 0: a missing `bd` must not fail startup.

set -uo pipefail

command -v bd >/dev/null 2>&1 || exit 0

WORKSPACE="${AUGMENT_PROJECT_DIR:-$PWD}"
[ -d "$WORKSPACE/.beads" ] || exit 0

# Discarding the output would start the session with no Beads context and no
# hint that durable task tracking is unavailable. Report the failure as context
# instead, while still exiting 0 so startup is never blocked.
if PRIME_OUT=$(bd -C "$WORKSPACE" prime 2>&1); then
  printf '%s\n' "$PRIME_OUT"
else
  printf '%s\n' \
    "beads: 'bd prime' failed, so this session has no Beads context and durable task tracking may be unavailable. Output: ${PRIME_OUT}"
fi

exit 0

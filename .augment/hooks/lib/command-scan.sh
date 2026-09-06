#!/usr/bin/env bash
# Decide whether a shell command writes to a bead store, and which store.
#
# Sourced by beads-sync.sh and by test/classification_test.sh, so the suite
# exercises the scanner the hook actually runs. A suite carrying its own copy
# of the rules passes against logic the hook no longer has, which is the
# failure mode that let three rounds of defects through.
#
# The decision itself is in command_scan.py, over the syntax tree `shfmt
# --to-json` produces. This file is the bash contract around it: scan_command
# sets SCAN_MUTATES, SCAN_UNRESOLVED, SCAN_TARGETS and SCAN_FAILED, which is
# what the hook and the suite are written against. Both `shfmt` and `python3`
# are required; a missing one is a broken install rather than a case to degrade
# through, and standing down quietly would leave bead writes local with nothing
# to say so.

_SC_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_SC_PY="$_SC_LIB_DIR/command_scan.py"

# Results of scan_command.
SCAN_MUTATES=0
SCAN_UNRESOLVED=0
SCAN_TARGETS=()
SCAN_FAILED=0

# Fills SCAN_MUTATES, SCAN_UNRESOLVED, SCAN_TARGETS and SCAN_FAILED from
# command $1, which was launched from directory $2. An empty $2 says that
# directory is unknown, which leaves a relative `-C` target unresolved rather
# than resolving it against this process's own cwd -- a directory nothing
# requires to be the tool call's.
#
# Targets are read back NUL-separated rather than by line, because a store path
# may contain a newline and a target silently truncated at one names some other
# store.
#
# The scanner's output is captured to a file rather than read from a process
# substitution, because a substitution's exit status is not the pipeline's and
# so cannot be observed at all. A scanner that dies before emitting anything
# leaves SCAN_MUTATES at its initial 0, which reads exactly like "this command
# writes nothing": the write is then treated as read-only and no sync is even
# attempted, silently. SCAN_FAILED distinguishes the two, so the caller can say
# so instead of standing down.
scan_command() {
  local command="$1" launch_cwd="$2" field seen=0 out status
  SCAN_MUTATES=0
  SCAN_UNRESOLVED=0
  SCAN_TARGETS=()
  SCAN_FAILED=0
  out=$(mktemp "${TMPDIR:-/tmp}/cs-scan.XXXXXX") || {
    SCAN_FAILED=1
    return 0
  }
  printf '%s' "$command" | python3 "$_SC_PY" "$launch_cwd" >"$out" 2>/dev/null
  status=$?
  # The two counts come first and always; everything past them is a target.
  while IFS= read -r -d '' field; do
    seen=$((seen + 1))
    case "$seen" in
      1) SCAN_MUTATES=$field ;;
      2) SCAN_UNRESOLVED=$field ;;
      *) SCAN_TARGETS+=("$field") ;;
    esac
  done <"$out"
  rm -f "$out"
  # A nonzero status and a short answer are both failures, and neither implies
  # the other: the scanner can exit 0 having written nothing if its stdout was
  # lost, and can exit nonzero after a complete answer. Both counts are required,
  # since a truncated answer would otherwise leave the second reading 0 --
  # indistinguishable from "every target was resolved".
  if [ "$status" -ne 0 ] || [ "$seen" -lt 2 ]; then
    SCAN_FAILED=1
    SCAN_MUTATES=0
    SCAN_UNRESOLVED=0
    SCAN_TARGETS=()
  fi
  return 0
}

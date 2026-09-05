#!/usr/bin/env bash
# Commit and push the embedded Dolt bead store after a mutating `bd` command.
#
# `bd`'s own git-hook shims only fire on git operations, so standalone bead
# writes (create/close/config) never reach DoltHub. This runs on Auggie's
# PostToolUse and SessionEnd events instead, which do not depend on git.
#
# Reads the hook event as JSON on stdin. Always exits 0: a failed push must
# warn, never wedge the session.

set -uo pipefail

EVENT_JSON=$(cat)

# No `bd` means no bead store to sync, so exiting quietly is honest here.
command -v bd >/dev/null 2>&1 || exit 0

# `jq` reads the event, so without it there is no event to act on at all --
# not the name of it, and not the roots to sync. Reported rather than silent:
# `bd` may well have pending writes this hook can no longer detect, and exiting
# quietly would claim all was well.
#
# The scanner's own tools -- `shfmt` and `python3` -- are deliberately not
# required here, though they were. Only PostToolUse scans a command; SessionEnd
# syncs the roots unconditionally and asks the scanner nothing. Standing down on
# a missing `shfmt` therefore disabled the backstop precisely when it was the
# last thing that could flush a pending write, one this hook could no longer
# detect on the events that do scan. A scanner that cannot run is reported by
# `SCAN_FAILED` instead, which is the same warning and syncs the roots anyway.
if ! command -v jq >/dev/null 2>&1; then
  echo "beads: jq not found, so the Auggie sync hook is inactive and bead writes will not reach DoltHub. Install with 'brew install jq'." >&2
  exit 0
fi

# PostToolUse can inject additionalContext so the agent learns a push failed.
# SessionEnd stdout is debug-only, so warn on stderr instead.
warn() {
  local event="$1" message="$2"
  if [ "$event" = "PostToolUse" ]; then
    jq -n --arg m "$message" \
      '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $m}}'
  else
    echo "$message" >&2
  fi
}

EVENT_NAME=$(jq -r '.hook_event_name // ""' <<<"$EVENT_JSON")

# Every root with a bead store is synced, not just the first. The event
# supplies an array, and `bd -C <dir>` can address any of them, so picking
# `[0]` would detect a write in a second root and then commit the first --
# leaving the store that actually changed behind. Syncing every root costs
# a no-op commit in the ones that did not change.
ROOTS=()

# The event's own roots, kept apart from any external `-C` target so the
# registry below can tell which of the two a path is.
WS_ROOTS=()

# One warning per invocation. PostToolUse warnings are JSON on stdout, and
# several roots failing would otherwise emit several objects. Declared here
# rather than beside the sync loop because the registry below can warn too.
WARNINGS=()

# Emits whatever has been collected, once. Called on the way out of every
# terminating path, the normal end included.
#
# Everything worth saying is known before the work that can be killed, and
# almost none of it survives being killed. The hook is stopped at 60s; the lock
# wait alone is allowed 30 of those and each `bd` beyond it is unbounded, so an
# invocation can be reading the remote when the axe falls. Emitting only after
# the last root meant the axe took the scan warnings with it -- and for a store
# that could not be named, that warning is not a report of the failure but the
# entire recovery path: nothing else names the path, so a reader who never sees
# it has no way to learn a store needs pushing.
#
# Not emitted early instead, because a PostToolUse hook is read as one JSON
# object and a second would not be honoured: saying the scan warnings up front
# would silence every push failure found afterwards. So it is said once, as
# late as possible, on a path a kill cannot skip.
#
# Idempotent, since the trap fires after the normal call as well, and a second
# object on stdout is exactly what the single call exists to avoid.
WARNINGS_EMITTED=0
flush_warnings() {
  [ "$WARNINGS_EMITTED" -eq 1 ] && return 0
  WARNINGS_EMITTED=1
  [ "${#WARNINGS[@]}" -gt 0 ] || return 0
  warn "$EVENT_NAME" "$(printf '%s\n' "${WARNINGS[@]}")"
  return 0
}

# `SIGKILL` cannot be caught and is the one case nothing here covers. The
# others are trapped explicitly rather than left to their defaults: a signal
# with no handler ends the shell without running the EXIT trap, so the
# warnings would go the same way as before.
trap 'flush_warnings' EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP

# Adds $1 to the sync set if it holds a bead store and is not already in it.
add_root() {
  local candidate="$1" existing
  [ -n "$candidate" ] && [ -d "$candidate/.beads" ] || return 0
  for existing in ${ROOTS[@]:+"${ROOTS[@]}"}; do
    [ "$existing" = "$candidate" ] && return 0
  done
  ROOTS+=("$candidate")
  return 0
}

# Every lock here is a symlink whose target is the owning pid. `mkdir` plus
# a pid file cannot express ownership atomically: a holder paused between
# the two publishes a lock nobody owns, and a waiter that reads it has no
# way to tell "created a moment ago" from "creator died". Any delay chosen
# as proof of death is a guess, and guessing wrong hands the same lock to
# two processes. `symlink(2)` fails when the name exists and carries its
# payload in the same call, so a lock that exists always names its owner.
#
# The target is an owner, not a path, so the link is deliberately dangling.
# `readlink` reads it regardless; tests for its presence must use `-L`,
# since `-e` follows the link and reports a live lock as absent.
# `ln -s x d` where `d` is a directory does not fail -- it links to `x`
# *inside* `d`. A lock left by the older directory-based version would
# therefore be walked straight past, handing this invocation a lock another
# process still holds. Success is confirmed by the name being a symlink
# afterwards, and the stray link cleared when it is not.
take_lock() {
  ln -s "$SELF_ID" "$1" 2>/dev/null || return 1
  [ -L "$1" ] && return 0
  rm -f "$1/$SELF_ID"
  return 1
}
lock_owner() { readlink "$1" 2>/dev/null; }

# The owner of lock $1, whatever shape the lock has, or nothing when there is
# no lock or its owner cannot be named.
#
# `lock_owner` alone cannot tell those apart: it returns nothing for a lock
# that was just released, for one that never existed, and for a live lock in
# the directory format an older version of this hook wrote. Reclamation
# turns on that distinction -- an unnamed generation must never be deleted,
# because nothing read later can confirm it is still the same one.
#
# A legacy directory names its owner in a pid file, in the bare-pid form
# `owner_alive` still accepts. One with no readable pid file is left alone:
# it is the very state the symlink format exists to avoid, and no reading of
# it can distinguish a holder paused before writing its pid from a corpse.
lock_kind() {
  local lock="$1" owner
  owner=$(lock_owner "$lock")
  if [ -n "$owner" ]; then
    printf '%s' "$owner"
    return 0
  fi
  [ -d "$lock" ] || return 0
  owner=$(cat "$lock/pid" 2>/dev/null)
  case "$owner" in
    '' | *[!0-9]*) return 0 ;;
  esac
  printf '%s' "$owner"
  return 0
}

# A number that changes at every boot, or nothing where the system does not
# offer one. Read from the kernel's boot time, which both platforms expose
# and neither lets a process alter.
boot_token() {
  local raw=""
  if [ -r /proc/stat ]; then
    raw=$(awk '/^btime /{print $2; exit}' /proc/stat 2>/dev/null)
  else
    raw=$(sysctl -n kern.boottime 2>/dev/null)
    raw=${raw#*sec = }
    raw=${raw%%,*}
  fi
  case "$raw" in
    '' | *[!0-9]*) return 0 ;;
  esac
  printf '%s' "$raw"
}

# When the process $1 started, in whatever form the platform reports it, or
# nothing where it cannot be read. The value is only ever compared with
# another reading of the same field, so its units and format do not matter;
# what matters is that the kernel sets it once at exec and a process cannot
# change its own. Separators are stripped so the value survives the `:`
# delimited owner string.
proc_start() {
  local pid="$1" raw=""
  case "$pid" in '' | *[!0-9]*) return 0 ;; esac
  if [ -r "/proc/$pid/stat" ]; then
    # Start time is field 22, but fields 1 and 2 cannot be counted through:
    # the command name in field 2 is parenthesised and may itself contain
    # spaces and brackets. Everything up to the last `)` is dropped first, so
    # the count starts at field 3 and is unaffected by the name. Counting
    # back from the end instead would break as the kernel appends fields.
    raw=$(sed 's/.*) //' "/proc/$pid/stat" 2>/dev/null | awk '{print $20}')
  else
    raw=$(ps -p "$pid" -o lstart= 2>/dev/null)
  fi
  raw=${raw//[^0-9A-Za-z]/}
  printf '%s' "$raw"
}

# A pid alone is not an identity. Pids are reused, and across a reboot the
# number in a lock left behind can belong to something unrelated: `kill -0`
# then reports the owner live, the lock is never reclaimed, and every sync of
# that store spends its whole budget waiting on a process that is not it.
# Pairing the pid with the boot token makes an owner from an earlier boot
# recognisably dead however its number was reissued.
#
# The boot token settles reuse across boots but not within one: a hook killed
# mid-pass frees a pid the kernel may hand to something unrelated minutes
# later, and that process answers `kill -0` under this boot's token just as
# the real owner would. The start time closes it -- reuse gives the same
# number a different start -- so the owner carries all three.
# The three fields are positional, so an owner that carries a start time
# always carries a token field even where the platform offers no token: an
# empty one in the middle keeps the start time from being read as the token.
BOOT_TOKEN=$(boot_token)
SELF_START=$(proc_start "$$")
if [ -n "$SELF_START" ]; then
  SELF_ID="$$:$BOOT_TOKEN:$SELF_START"
else
  SELF_ID="$$${BOOT_TOKEN:+:$BOOT_TOKEN}"
fi

# Whether the owner string $1 names a process that is still running.
#
# An owner is judged on whatever it carries. One written by an older version
# of this hook has no token, or a token but no start time, and is judged on
# the fields it has -- which is what that version did and no weaker than it
# was. Reading a short owner as dead instead would let this version delete a
# live lock held by one still running alongside it.
owner_alive() {
  local owner="$1" pid=${1%%:*} rest="" token="" start=""
  case "$owner" in *:*) rest=${owner#*:} ;; esac
  token=${rest%%:*}
  case "$rest" in *:*) start=${rest#*:} ;; esac
  case "$pid" in '' | *[!0-9]*) return 1 ;; esac
  [ -n "$token" ] && [ -n "$BOOT_TOKEN" ] && [ "$token" != "$BOOT_TOKEN" ] &&
    return 1
  kill -0 "$pid" 2>/dev/null || return 1
  # A start time that cannot be read now proves nothing either way, so the
  # pid stands on its own rather than the owner being called dead.
  if [ -n "$start" ]; then
    local now
    now=$(proc_start "$pid")
    [ -n "$now" ] && [ "$now" != "$start" ] && return 1
  fi
  return 0
}
drop_lock() { rm -f "$1"; }

# The owner string for pid $1, in the same three fields `owner_alive` reads.
owner_id() {
  local pid="$1" start
  start=$(proc_start "$pid")
  if [ -n "$start" ]; then
    printf '%s' "$pid:$BOOT_TOKEN:$start"
  else
    printf '%s' "$pid${BOOT_TOKEN:+:$BOOT_TOKEN}"
  fi
}

# Runs `bd -C $1 ${@:3}` with its output collected in the file $2, recording the
# child that runs it beside the lock for as long as it does.
#
# The record exists because this hook is killed at 60s and a lock's owner being
# gone does not mean its work is: `bd dolt push` is a separate process, it is not
# in this shell, and nothing reparents or signals it when this shell dies. It
# keeps running, holding the store open and talking to the remote, while the lock
# it was covered by reads as reclaimable -- so the next invocation takes that
# lock and starts a second push against the same remote, which is the one thing
# the lock exists to prevent. The suite hid this by killing the child itself
# before retrying, which the hook's own timeout does not do.
#
# The child is gated rather than simply forked, because forking and recording are
# two steps and a kill between them leaves a push running that nothing names. So
# the child waits to be released, and is released only once its pid is recorded:
# a kill before that leaves a child which has not yet run `bd` and will not.
#
# `exec` matters -- the recorded pid must be `bd` itself and not a shell that
# will outlive it by a moment, or the record can name a process that has finished
# its push. The gate is polled rather than waited on because a FIFO would block
# this shell against a child that was killed before opening it, and it lives
# outside the store because a `kill -9` runs no trap: left in `.beads` it would
# accumulate one file per killed invocation, in the directory whose contents
# other parts of this hook read as markers.
run_tracked() {
  local root="$1" out="$2"
  shift 2
  local child_link="$root/.beads/.augment-sync.child"
  local gate
  gate=$(mktemp "${TMPDIR:-/tmp}/cs-gate.XXXXXX") || return 1
  rm -f "$gate"
  (
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
      [ -e "$gate" ] && break
      sleep 0.1
    done
    # Never released: this invocation died between the fork and the record, so
    # the push must not start -- it would be the very orphan the record exists
    # to make visible, and unrecorded.
    [ -e "$gate" ] || exit 70
    exec bd -C "$root" "$@"
  ) >"$out" 2>&1 &
  child=$!
  local recorded
  recorded=$(owner_id "$child")
  rm -f "$child_link"
  # The gate is opened only once the record is known to be the record, since a
  # push running with nothing naming it is the orphan the record exists to
  # prevent: killed then, its lock reads reclaimable while it still talks to
  # the remote. `ln -s` is not proof of that by itself -- where the path is a
  # directory, which `rm -f` will not clear, it answers success for a link it
  # made *inside* it. So the path is required to be clear first, which also
  # keeps a refusal from leaving one such link per attempt, and the result is
  # read back. A child not released stands itself down, which is the case it
  # already exits 70 for.
  [ -e "$child_link" ] || [ -L "$child_link" ] ||
    ln -s "$recorded" "$child_link" 2>/dev/null
  if [ "$(lock_owner "$child_link")" != "$recorded" ]; then
    wait "$child"
    rm -f "$gate"
    WARNINGS+=("beads: could not record the sync process in ${root}, so no push was started there; the markers stay and the next invocation retries.")
    return 1
  fi
  : >"$gate"
  wait "$child"
  rc=$?
  rm -f "$child_link" "$gate"
  # The gate having gone unseen is this invocation's own failure to release it,
  # not `bd` refusing the work, so it is reported as a failed run: the markers
  # stay and the next invocation retries.
  return "$rc"
}

# Whether a push started under the lock $1 is still running, whoever started it.
# A live one keeps the lock from being reclaimed even when its owner is gone,
# since taking it would put a second push against the same remote.
child_running() {
  local owner
  owner=$(lock_owner "$1")
  [ -n "$owner" ] || return 1
  owner_alive "$owner"
}

# Takes the guard $1, or returns non-zero while another live process holds
# it. Used for the short read-modify-write windows -- the lock reclamation
# below and the external registry -- where the protected work is a handful
# of filesystem calls and a loser can simply stand down.
#
# Clearing a guard whose holder is gone is itself a validate-then-delete, so
# it needs its own election -- one that neither recurses nor can be left
# behind as a permanent blocker. The election is a lock keyed on both the
# generation being replaced (the dead holder's pid) and an attempt number,
# so exactly one of the waiters that judged that holder dead wins a given
# attempt.
#
# The attempt number is what makes an orphan harmless. An election whose own
# holder died can never be *deleted* safely -- that is the same race again --
# so it is not deleted: the next waiter moves to the attempt above it. A
# leftover election therefore costs one `readlink`, not the store's ability
# to recover. The walk terminates because each step consumes one election
# that already existed, and attempts only ever move upward.
#
# `GUARD_RECLAIMED` says how the guard was taken: 0 free, 1 reclaimed from a
# holder that had died. The registry callers read it, since a holder that died
# under the registry guard may have died between the two writes it makes.
GUARD_RECLAIMED=0
take_guard() {
  local guard="$1" holder election elector attempt won=1
  GUARD_RECLAIMED=0
  take_lock "$guard" && return 0
  holder=$(lock_owner "$guard")
  # An empty owner no longer means "caught mid-creation" -- it means the
  # guard was released between the attempt and the read. Nothing to reclaim,
  # so stand down and let the caller come round again.
  [ -n "$holder" ] || return 1
  owner_alive "$holder" && return 1

  election=""
  for ((attempt = 0; ; attempt++)); do
    election="$guard.stale.$holder.$attempt"
    take_lock "$election" && break
    elector=$(lock_owner "$election")
    # A live elector is contending for this generation already, and a
    # vanished one means the field moved on; either way, stand down. Only a
    # dead elector is an orphan, which is stepped over rather than removed.
    [ -n "$elector" ] || return 1
    owner_alive "$elector" && return 1
  done

  # Re-read under the election: cheap, and the only cost of being wrong here
  # is deleting a guard that has just been taken.
  if [ "$(lock_owner "$guard")" = "$holder" ]; then
    drop_lock "$guard"
    take_lock "$guard" && won=0
  fi
  drop_lock "$election"
  [ "$won" -eq 0 ] && GUARD_RECLAIMED=1
  return "$won"
}

# As `take_guard`, but waits. Losing the registry guard outright would drop
# the record of an external store, which is the one thing that makes a failed
# sync there recoverable, so that caller is worth a short retry.
take_guard_waiting() {
  local guard="$1" attempts="${2:-5}" i
  for ((i = 1; i <= attempts; i++)); do
    take_guard "$guard" && return 0
    sleep 1
  done
  return 1
}

# Read NUL-delimited for the reason the scanner and the registry are: a root
# path may contain a newline, and by line such a root arrives as two paths that
# name nothing. Neither has a `.beads`, so `add_root` drops both and the real
# workspace store is left out of the push set entirely -- SessionEnd builds its
# list the same way, so nothing later recovers it.
#
# `jq` appends the delimiter itself rather than `--raw-output0`, which needs
# jq 1.7 and would fail on the 1.6 still shipped by several distributions.
while IFS= read -r -d '' ROOT; do
  add_root "$ROOT"
  [ -d "$ROOT/.beads" ] && WS_ROOTS+=("$ROOT")
done < <(jq -j '.workspace_roots[]? // empty | . + "\u0000"' <<<"$EVENT_JSON")

# An external `-C` target is named by one command and by nothing else: no
# later event mentions it, and the root list every invocation builds comes
# from `workspace_roots`. A marker left in such a store by a failed sync
# would therefore never be found again, so the retry and the SessionEnd
# backstop -- the two things that make a failed push recoverable -- would
# both miss it. Recording the path in a workspace-owned file is what lets a
# later invocation rediscover it.
#
# An entry means "this store is owed a sync". It is written once, when the
# target is first seen, and removed only by a push against that store that
# returned 0 -- or by the prune, when the store no longer has a `.beads` and so
# can never settle. Nothing else takes it out, which is what makes a sync that
# failed, timed out or was killed outright still recoverable.
#
# A new entry goes to the first root, but every root's registry is read and
# rewritten. Which root is first is a property of the event, not of the store:
# a session over root B alone records there, and a later session over A and B
# has a different `[0]`. Reading only that one left B's entry unseen -- the
# external store it names is named by nothing else, so the write sat local
# indefinitely with no invocation able to find it again.
REGISTRY=""
REGISTRY_GUARD=""
REGISTRIES=()
for ROOT in ${WS_ROOTS[@]:+"${WS_ROOTS[@]}"}; do
  REGISTRIES+=("$ROOT/.beads/.augment-sync.external")
done
if [ "${#REGISTRIES[@]}" -gt 0 ]; then
  REGISTRY="${REGISTRIES[0]}"
  REGISTRY_GUARD="$REGISTRY.guard"
fi

# Runs `$@` once per registry, with `REGISTRY` and `REGISTRY_GUARD` naming it.
# The readers and rewriters below take their file from those two, so this is
# what makes each of them cover every root rather than the first alone. The
# pair is restored after, the write path being the first root's.
for_each_registry() {
  local saved="$REGISTRY" saved_guard="$REGISTRY_GUARD" reg
  for reg in ${REGISTRIES[@]:+"${REGISTRIES[@]}"}; do
    REGISTRY="$reg"
    REGISTRY_GUARD="$reg.guard"
    "$@"
  done
  REGISTRY="$saved"
  REGISTRY_GUARD="$saved_guard"
  return 0
}

# NUL-delimited, matching the scanner's own output, because a path may contain
# a newline and a line-delimited record of one is two records: the store the
# write opened is then named by neither, so its failed sync can never be
# rediscovered. A NUL cannot appear in a path, so it is the one delimiter that
# needs no escaping.
read_registry() {
  local entry
  [ -n "$REGISTRY" ] && [ -r "$REGISTRY" ] || return 0
  while IFS= read -r -d '' entry; do
    add_root "$entry"
  done <"$REGISTRY"
  return 0
}
for_each_registry read_registry

# Records $1 for later invocations, and raises its marker. Roots the event
# supplies need no record; only a target outside them can be lost.
#
# The entry is the record that a sync is owed there, and the marker is what
# keeps the entry from being settled by a push that did not cover this request.
# Two files on two paths cannot be written atomically, so both are written under
# the one guard, entry first: a writer killed between them leaves the entry, and
# an entry alone is enough for every later invocation to sync the store. A
# `forget_external` racing this cannot see the entry without its marker, since it
# rewrites the registry under the same guard and re-reads the marker after.
#
# That holds while the writer lives. Killed between the two writes, it leaves the
# guard held by a dead owner, and the next taker reclaims it -- which for a
# `forget_external` settling a push that ran before this request means dropping
# the entry with no marker to stop it: the store is then named by nothing. So
# the guard it died holding is read as the record it could not finish. Whoever
# reclaims the registry guard raises the marker on every store the registry
# names before doing anything else (`mark_registry_owed`), and a settle that
# follows finds the marker. Every entry rather than the one, since the dead
# holder's candidate is not recoverable from the guard; the cost is a no-op
# commit per entry, once.
remember_external() {
  local candidate="$1" existing
  [ -n "$REGISTRY" ] && [ -d "$candidate/.beads" ] || return 0
  for existing in ${WS_ROOTS[@]:+"${WS_ROOTS[@]}"}; do
    [ "$existing" = "$candidate" ] && return 0
  done
  # Serialised against the rewrites below, both of which are read-modify-write:
  # an entry appended after one read the file would be dropped by its rewrite,
  # and that entry is by definition one whose sync has not been seen to finish.
  # Refusing to record is worth saying out loud, since the target is then only
  # reachable for as long as this invocation runs.
  if ! take_guard_waiting "$REGISTRY_GUARD" 5; then
    WARNINGS+=("beads: could not record the external bead store ${candidate}; a failed sync there will not be retried later in this session.")
    return 0
  fi
  [ "$GUARD_RECLAIMED" -eq 1 ] && mark_registry_owed
  # Deduplicated by path, which is sound only because an entry is no longer
  # settled by a push alone: what settles it is a push followed by no request
  # left outstanding, and the marker raised below is what says one is. So
  # collapsing two requests into one entry cannot let the first holder settle the
  # second's request -- the marker it would have to ignore is the same one it
  # checks. Without that gate the collapse was a silent loss, and per-entry
  # generations would have been the alternative.
  # Appended by replacement rather than in place, as `filter_registry` rewrites
  # by replacement, and for the same reason: a `printf` that stops part-way --
  # a full filesystem, a signal -- leaves a record with no NUL to end it, and
  # the next append then runs its path onto the end of that one. The reader
  # takes the two as a single entry naming neither store, so both are lost for
  # good, where a failed replacement leaves the list that was there.
  if ! registry_has "$candidate"; then
    if : >"$REGISTRY.$$" &&
      { [ ! -e "$REGISTRY" ] || cat "$REGISTRY" >>"$REGISTRY.$$"; } &&
      printf '%s\0' "$candidate" >>"$REGISTRY.$$"; then
      mv -f "$REGISTRY.$$" "$REGISTRY" ||
        WARNINGS+=("beads: could not record the external bead store ${candidate}; a failed sync there will not be retried later in this session.")
    else
      rm -f "$REGISTRY.$$"
      WARNINGS+=("beads: could not record the external bead store ${candidate}; a failed sync there will not be retried later in this session.")
    fi
  fi
  : >"$candidate/.beads/.augment-sync.pending"
  drop_lock "$REGISTRY_GUARD"
  return 0
}

# Whether the registry being written already names $1. Read as NUL-delimited
# records rather than matched as text: `grep -qxF` reads a path holding a
# newline as two lines and reports a match for either half on its own, so a
# store whose path merely shares a line with another would read as already
# recorded and never be added.
#
# `$REGISTRY` alone, not every root's. The caller holds that one's guard and no
# other, so a match found elsewhere is a read of a file another invocation may
# rewrite in the same instant: a concurrent sync settling that entry between
# this read and the marker below would leave the store named by no registry at
# all, and an external store is named by nothing else -- so a failure here
# would strand the write for good. A duplicate is the safe error of the two:
# `forget_external` and the prune both rewrite every registry, so a copy in
# another root is removed by the same pass that removes this one, and until
# then it costs a no-op commit.
registry_has() {
  local wanted="$1" entry
  [ -n "$REGISTRY" ] && [ -r "$REGISTRY" ] || return 1
  while IFS= read -r -d '' entry; do
    [ "$entry" = "$wanted" ] && return 0
  done <"$REGISTRY"
  return 1
}

# Raises the marker on every store the registry being written names. Called by
# whoever takes the registry guard from a holder that died, before anything
# else is done under it: the holder may have been `remember_external`, killed
# after writing the entry and before the marker, and a settle that ran on
# without the marker would drop the entry -- see the note there. A store
# without a `.beads` is left alone, as `bd` could not have written it and the
# prune is about to drop it.
#
# The marker is raised for a store that may already be pushed, which costs a
# no-op commit there once. Whether the dead holder got as far as the entry is
# not knowable from the guard, and this is done under it, so a caller that dies
# part-way leaves it stale for the next taker to do again.
mark_registry_owed() {
  local entry
  [ -n "$REGISTRY" ] && [ -r "$REGISTRY" ] || return 0
  while IFS= read -r -d '' entry; do
    [ -d "$entry/.beads" ] || continue
    : >"$entry/.beads/.augment-sync.pending"
  done <"$REGISTRY"
  return 0
}

# Rewrites the registry as every entry for which `$1 <entry>` succeeds.
#
# Replaced whole rather than edited in place, so a hook killed mid-write leaves
# the previous list rather than half of one. Keeping a settled entry costs a
# no-op commit; dropping a live one strands a write, so a guard this cannot
# take means stand down rather than rewrite from a snapshot someone else has
# moved on from.
#
# The keep function runs under the guard, after a reclaimed guard has raised its
# markers, so a decision that turns on a marker -- `forget_keep`'s does -- is
# made against the state the dead holder left rather than the one read before
# the guard was taken.
filter_registry() {
  local keep="$1" entry tmp any=0 failed=0
  [ -n "$REGISTRY" ] && [ -r "$REGISTRY" ] || return 0
  take_guard "$REGISTRY_GUARD" || return 0
  [ "$GUARD_RECLAIMED" -eq 1 ] && mark_registry_owed
  tmp="$REGISTRY.$$"
  : >"$tmp" || {
    drop_lock "$REGISTRY_GUARD"
    return 0
  }
  # Written straight through to the replacement rather than accumulated in a
  # variable, since a value cannot hold the NUL the records are delimited by.
  #
  # Every record must be written for the replacement to be the list. A `printf`
  # that fails part-way -- a full filesystem, a quota, an interrupted write --
  # leaves a shorter file that is still a well-formed registry, and moving that
  # over the real one drops the entries below the failure: each names an external
  # store whose sync has not been seen to finish and which nothing else names, so
  # the write there becomes unrecoverable. Abandoning the rewrite instead keeps
  # the list that was there, which costs a no-op commit against every entry it
  # should have dropped.
  while IFS= read -r -d '' entry; do
    [ -n "$entry" ] || continue
    if "$keep" "$entry"; then
      printf '%s\0' "$entry" >>"$tmp" || {
        failed=1
        break
      }
      any=1
    fi
  done <"$REGISTRY"
  # Not warned about, unlike a refusal to record: a rewrite that does not happen
  # leaves every store still named, so nothing is owed that a later invocation
  # cannot find. The same holds for a `mv` that fails -- the previous list stands.
  if [ "$failed" -eq 1 ]; then
    rm -f "$tmp"
    drop_lock "$REGISTRY_GUARD"
    return 0
  fi
  if [ "$any" -eq 1 ]; then
    mv -f "$tmp" "$REGISTRY"
  else
    rm -f "$tmp" "$REGISTRY"
  fi
  drop_lock "$REGISTRY_GUARD"
  return 0
}

# Drops $1 from the registry, its sync having been seen to finish. Called only
# after a push returns 0, which is the entry's one exit path: while it is
# there, the store it names has work owed and every later invocation syncs it.
#
# A push returning 0 is necessary but not sufficient. The sync loop is bounded,
# so it can return having pushed successfully and still leave a request
# outstanding -- either one it ran out of passes to serve, or one another
# invocation raised while this one was pushing. Removing the entry then settles
# a request no push has covered, and for a store outside the workspace roots the
# marker left behind is unreachable: nothing else names that path, so neither
# the retry nor the SessionEnd backstop can find it again. So the markers are
# re-read here, and an entry is kept whenever either of them says work is still
# owed.
#
# Every root's registry is rewritten, not just the one a new entry goes to: the
# entry being settled may have been recorded by a session whose first root was
# another of them, and one left behind means this store is committed by every
# later invocation with nothing able to settle it.
#
# The markers are read twice: once before the guard, which is what saves the
# rewrite in the common case, and once by `forget_keep` under it. The second
# read is the one that sees a marker raised by the guard's own reclaim -- a
# `remember_external` that died between its entry and its marker is only known
# by the guard it left held, and the marker stands in for the one it did not
# write. Without it the entry was dropped on the first read's word.
FORGET_TARGET=""
forget_keep() {
  [ "$1" != "$FORGET_TARGET" ] ||
    [ -e "$1/.beads/.augment-sync.pending" ] ||
    [ -e "$1/.beads/.augment-sync.inflight" ]
}
forget_external() {
  local root="$1"
  [ -e "$root/.beads/.augment-sync.pending" ] && return 0
  [ -e "$root/.beads/.augment-sync.inflight" ] && return 0
  FORGET_TARGET="$root"
  for_each_registry filter_registry forget_keep
  FORGET_TARGET=""
  # Re-checked after the removal, since a request can arrive between the test
  # above and the rewrite: the entry would then be gone while its marker stands,
  # which for an external store is the unrecoverable case. Re-recording is
  # idempotent and costs a no-op commit if the request settles meanwhile.
  if [ -e "$root/.beads/.augment-sync.pending" ]; then
    remember_external "$root"
  fi
  return 0
}

# The entry's only other exit. A successful push is what settles an entry, so a
# store that has been deleted -- or that has had its bead store removed -- has
# no way to settle and would otherwise be committed by every invocation from
# here on. Nothing is owed to a store that no longer exists.
prune_keep() { [ -d "$1/.beads" ]; }
prune_registry() {
  for_each_registry filter_registry prune_keep
  return 0
}

# A request is outstanding while either marker exists. `.pending` is raised
# by an invocation that has not yet been served; `.inflight` is a sync that
# started and has not been seen to finish.
#
# A registry entry counts too, and is the only record for an external store
# whose markers this invocation may not have reached: the entry is removed only
# by a push that returned 0, so while it is there the store it names is owed a
# sync whatever its own markers say.
any_outstanding() {
  local root reg
  for root in ${ROOTS[@]:+"${ROOTS[@]}"}; do
    [ -e "$root/.beads/.augment-sync.pending" ] && return 0
    [ -e "$root/.beads/.augment-sync.inflight" ] && return 0
  done
  for reg in ${REGISTRIES[@]:+"${REGISTRIES[@]}"}; do
    [ -s "$reg" ] && return 0
  done
  return 1
}

# Whether $1 carries no record that a sync is owed it: neither marker exists.
# The markers are written with their failure ignored, since what fails them --
# a full disk, a `.beads` made read-only -- is nothing a retry mends. What can
# be done is to notice, at each point where the record was the only thing
# standing behind the request, and say so.
unrecorded() {
  [ ! -e "$1/.beads/.augment-sync.pending" ] &&
    [ ! -e "$1/.beads/.augment-sync.inflight" ]
}

# Hands the request in $1 back for retry after a failed pass, by returning the
# claimed marker to `.pending`, and says so when neither marker can be made to
# stand. A failed sync is already warned about by the caller; what this adds is
# that the next invocation will not find it, which the failure warning on its
# own let the reader assume it would.
hand_back() {
  mv -f "$1/.beads/.augment-sync.inflight" "$1/.beads/.augment-sync.pending" 2>/dev/null ||
    : >"$1/.beads/.augment-sync.pending"
  unrecorded "$1" || return 0
  WARNINGS+=("beads: the failed sync in ${1} could not be recorded for retry either, so nothing marks that store as owed one; run 'bd dolt push --remote origin' there once the cause is fixed.")
  return 0
}

# PostToolUse fires on every tool call, so narrow to shell commands touching
# the bead store. Deciding which commands those are means reading shell
# syntax, which is what the scanner does; see its header for why that is a
# tokeniser and not a set of patterns.
HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/command-scan.sh
. "$HOOK_DIR/lib/command-scan.sh"

if [ "$EVENT_NAME" = "PostToolUse" ]; then
  TOOL_NAME=$(jq -r '.tool_name // ""' <<<"$EVENT_JSON")
  [ "$TOOL_NAME" = "launch-process" ] || exit 0

  COMMAND=$(jq -r '.tool_input.command // ""' <<<"$EVENT_JSON")
  # The directory the tool call was launched from, and empty when the event does
  # not say. The field is optional, and the hook's own cwd is not a substitute
  # for it: nothing requires this process to run where the tool call did, so
  # resolving `bd -C store` against it names a store under some unrelated
  # directory. That store is then recorded and pushed while the one the command
  # actually opened is in neither the push set nor the registry -- so even
  # SessionEnd cannot recover it, an external target being named by that command
  # and nothing else.
  #
  # Passed through empty instead, which the scanner reads as an unknown cwd: a
  # relative target stays unresolved and the write still counts, so the roots
  # sync and the warning says which store could not be named.
  LAUNCH_CWD=$(jq -r '.tool_input.cwd // ""' <<<"$EVENT_JSON")

  # Every `bd` in the command is examined rather than stopping at the first,
  # because each may name a different store via `-C`. A read-only one does
  # not speak for a write beside it: `bd config get x && bd update CHR-1
  # --claim` syncs.
  scan_command "$COMMAND" "$LAUNCH_CWD"
  MUTATES=$SCAN_MUTATES

  # A scanner that failed answered nothing, which is not the same as answering
  # "no write". Reading its silence as a read-only command would strand every
  # write the command made, so the workspace roots are synced instead and the
  # failure is reported: a no-op commit is the cost of being wrong here, against
  # bead writes that stay local with nothing to say so. A store outside the
  # roots cannot be recovered this way -- nothing else names that path -- so the
  # warning is the only thing that can stand in for it.
  #
  # Every route to such a store goes down with the scan, not `-C` alone: the
  # scanner also reads `BEADS_DIR`, and a `bd` with neither selects its store by
  # walking up from the directory the command ran in. Naming only `-C` sent the
  # reader looking for a flag their command need never have carried, which for
  # the one store this warning stands in place of is the wrong place to look.
  if [ "$SCAN_FAILED" -eq 1 ]; then
    MUTATES=1
    WARNINGS+=("beads: could not scan the command for bead writes; syncing the workspace roots as a precaution. A store outside them -- named by 'bd -C <dir>' or BEADS_DIR, or found by walking up from where the command ran -- may be left unsynced. Check that shfmt and python3 are installed.")
  fi

  # A store that was seen to be written and could not be named is the one write
  # with nothing standing behind it: the roots sync, but that store is not among
  # them and no other command names its path, so neither the marker retry nor
  # SessionEnd can rediscover it. The warning is all that is left in place of the
  # sync, which is why it is said even though the write itself was found.
  #
  # The counter covers every way the path can go unread, not a `-C` that failed:
  # a `BEADS_DIR` whose value this scan cannot work out, a `bd` carrying
  # neither when the event did not say which directory the tool call ran in --
  # the walk up has no place to start, so the store it would have found cannot
  # be named -- and script the scan could not read at all, as `eval "$X"` or
  # `bash -c "$(gen)"` runs, which may carry a `-C` nothing later can find.
  # Saying `-C` of all of these pointed recovery at a flag the command need not
  # have carried.
  if [ "$SCAN_UNRESOLVED" -gt 0 ]; then
    WARNINGS+=("beads: a bead store that was written could not be resolved to a path, so it was not synced or recorded; run 'bd dolt push' there if the write matters. This happens when a 'bd -C <dir>' or BEADS_DIR value depends on something only the running command knew, when a plain 'bd' ran in a directory the event did not report, or when the command ran script the hook could not read (eval \"\$X\", bash -c \"\$(...)\").")
  fi

  # `bd -C <dir>` can write a store outside every workspace root, which no
  # later event would ever revisit: SessionEnd builds its list the same way,
  # so that write would sit local indefinitely.
  #
  # Entry and marker are both written by `remember_external`, under the registry
  # guard, so no kill window leaves the store nameless. Writing the marker here
  # instead left one: killed between the two calls, the only record was a file
  # outside every root that no entry named, and no later invocation could find
  # it.
  for TARGET in ${SCAN_TARGETS[@]:+"${SCAN_TARGETS[@]}"}; do
    add_root "$TARGET"
    remember_external "$TARGET"
  done

  # A marker left by an earlier invocation that timed out is itself reason
  # to sync, so a stranded write is not held until the SessionEnd backstop.
  if [ "$MUTATES" -ne 1 ] && ! any_outstanding; then
    exit 0
  fi
fi

[ "${#ROOTS[@]}" -gt 0 ] || exit 0

# Every root is marked before any of them is synced. A root reached late --
# or not reached at all, the invocation having spent its budget waiting on an
# earlier one -- must still carry a record that a sync is owed, or the write
# there is invisible to `any_outstanding` and waits for the SessionEnd
# backstop. Marking costs one empty file and is idempotent.
for ROOT in "${ROOTS[@]}"; do
  : >"$ROOT/.beads/.augment-sync.pending"
done

# Hook invocations are killed at 60s. The per-root lock wait is bounded, but
# several blocked roots in series still add up past that, and a root the
# invocation never reaches gets no sync attempt at all. A shared deadline
# spends the budget across all of them instead of exhausting it on the first.
LOCK_DEADLINE=$((SECONDS + 30))

# The lock is per root, and an abnormal exit must not leave any of them held.
#
# The child record is deliberately not cleared here. A normal exit has already
# removed it, having waited for the child; an abnormal one is exactly the case
# where the record must survive, since the push it names is still running and the
# lock must stay unreclaimable until it stops. A stale record costs nothing --
# the pid it names answers dead, and `child_running` says so.
#
# Nor is the lock dropped over a push that is still running. This trap runs on
# every terminating path but `kill -9`, SIGTERM among them, and the child is in
# a process group of its own, so it does not take the signal and keeps talking
# to the remote. Freeing the lock there hands it to the next invocation at once,
# which is the second concurrent push the lock exists to prevent -- and that
# invocation never consults the child record, having taken the lock rather than
# reclaimed it. Left held, the lock is reclaimed instead, and reclamation does
# ask: once the child is gone the next invocation takes it, this shell being
# long dead by then.
release_locks() {
  local root lock
  for root in "${ROOTS[@]}"; do
    lock="$root/.beads/.augment-sync.lock"
    [ "$(lock_owner "$lock")" = "$SELF_ID" ] || continue
    child_running "$root/.beads/.augment-sync.child" && continue
    drop_lock "$lock"
  done
  return 0
}
# Both, and the warnings first: this is the path a kill arrives on, and what
# the reader most needs from it is the store that could not be named. Replaces
# the earlier EXIT trap rather than adding to it, a second `trap` on the same
# signal being a replacement.
trap 'flush_warnings; release_locks' EXIT

# Each tracked `bd` gets a process group of its own, so its pid is the pid of
# `bd` rather than of a group this shell shares. Enabled here rather than at the
# top of the file because it also silences the job-control notices bash would
# otherwise write to stderr for every backgrounded child.
set -m

sync_root() {
  local root="$1"
  local lock_dir="$root/.beads/.augment-sync.lock"
  local pending="$root/.beads/.augment-sync.pending"
  local inflight="$root/.beads/.augment-sync.inflight"
  local reclaim_dir="$root/.beads/.augment-sync.reclaim"
  local child_link="$root/.beads/.augment-sync.child"
  local locked=0 owner recheck pass commit_out commit_rc push_out push_rc
  local run_out

  # A write that arrives while another invocation holds the lock is not
  # covered by that invocation's push if its commit already ran. Record the
  # request so the holder makes a second pass. Already written for every root
  # before the loop began; repeated here because a pass below consumes it.
  : >"$pending"

  # Serialise concurrent hook invocations; a burst of writes must not race
  # two pushes against the same remote. Bail rather than steal a live lock.
  #
  # Bounded by a deadline shared with the other roots, so a blocked root
  # cannot spend the invocation's whole budget and leave a later one
  # unvisited. Waiting at all is a convenience: the marker written above
  # already guarantees the write is picked up, either by the current holder's
  # next pass or by a later invocation.
  while :; do
    if take_lock "$lock_dir"; then
      locked=1
      break
    fi

    [ "$SECONDS" -lt "$LOCK_DEADLINE" ] || break

    # Reclaim a lock whose owner is gone. Without this, one invocation killed
    # before its EXIT trap runs disables syncing for every later one.
    #
    # Reclamation is itself guarded, because reading the owner and deleting
    # the lock are two steps. Two waiters can both read the same dead pid;
    # the first deletes, a third invocation takes the freed lock, and the
    # second's delete then removes a live one -- leaving two invocations
    # pushing the same store at once, which is what the lock exists to stop.
    # The guard makes at most one waiter reach the delete, and re-reading the
    # owner inside it means a lock that changed hands in between is left
    # alone.
    #
    # There is no longer an ownerless lock to age out: a lock either names
    # its owner or does not exist, so the "no pid yet" wait that used to
    # stand in for proof of death is gone. The one exception is a lock left
    # by an older version of this hook, which is a directory rather than a
    # symlink; it is identified from the pid file inside it and cleared on
    # the same path as a dead owner.
    #
    # An empty read is not a generation. `readlink` returns nothing for a
    # lock released between the failed `ln` and the read, for a live legacy
    # directory, and for a lock that never existed alike. Treating that as an
    # owner to match against made the recheck vacuous: empty then empty
    # passed, and the delete removed whatever a third invocation had taken in
    # between -- two pushes at once, the failure the lock exists to prevent.
    # So the kind of the lock is established first, and only a generation
    # that can be named is a candidate for reclamation.
    #
    # A dead owner is not an idle store, either. `bd dolt push` runs in a
    # process of its own, and killing this hook -- which happens at 60s, with no
    # trap and no reparenting -- leaves that push running against the remote. Its
    # pid is recorded beside the lock precisely so this test can be made: while
    # it answers live, the lock stands however dead the shell that took it is,
    # because taking it would start a second push against the same remote. The
    # wait is bounded by the deadline like any other, so a push that outlives it
    # costs this invocation its turn and nothing more -- the markers stay, and the
    # next invocation finds them.
    owner=$(lock_kind "$lock_dir")
    if [ -n "$owner" ] && ! owner_alive "$owner" &&
      ! child_running "$child_link"; then
      if take_guard "$reclaim_dir"; then
        recheck=$(lock_kind "$lock_dir")
        # Re-read under the guard, for the same reason the owner is: a push
        # started between the test above and here is one this reclaim would put
        # a second alongside.
        [ -n "$recheck" ] && [ "$recheck" = "$owner" ] &&
          ! child_running "$child_link" && rm -rf "$lock_dir"
        drop_lock "$reclaim_dir"
      fi
    fi

    sleep 1
  done

  # Timing out is not a dropped request: the marker is still set, so the
  # holder picks the write up on its next pass, or the next invocation does.
  #
  # That holds only while the marker could be written. The write above ignores
  # its failure -- a full disk, a `.beads` made read-only -- because there is
  # nothing to retry it into, but a request with no marker has no record at
  # all: the holder's pass finds no `.pending` and stops, and for a store
  # outside the roots nothing later revisits the path. Returning in silence
  # then left the write with neither a push nor a record that one was owed. The
  # warning stands in for the record, as it does for a store that could not be
  # named.
  if [ "$locked" -ne 1 ]; then
    if unrecorded "$root"; then
      WARNINGS+=("beads: could not record that ${root} is owed a sync, and its lock was held past the deadline; the write there stands behind no record, so run 'bd dolt push --remote origin' there if it matters.")
    fi
    return 0
  fi

  # The request is claimed by moving the marker, not deleting it. Deleting it
  # up front means the 60s hook timeout landing inside a commit or push
  # destroys the only record that a sync was owed -- no failure branch runs
  # to put it back. `.inflight` survives that: it is only removed once the
  # push has returned, so a sync killed part-way still counts as outstanding.
  # It also leaves `.pending` free to record requests arriving mid-pass,
  # which is what earns the next pass. The bound stops a steady stream of
  # writes from holding the lock indefinitely; whatever is left over stays
  # marked for the next invocation.
  #
  # The output file is where `bd`'s own words are read from for the warnings
  # below, and a temporary directory that refuses one is a condition that
  # persists: returning in silence here disabled every sync for as long as it
  # lasted while the hook reported nothing, the marker keeping each request
  # only for a retry that met the same refusal. The marker is left standing
  # -- it is the record -- and the lock released, so a later invocation with
  # a working directory takes both up.
  if ! run_out=$(mktemp "${TMPDIR:-/tmp}/cs-bd.XXXXXX"); then
    WARNINGS+=("beads: could not create a temporary file under ${TMPDIR:-/tmp}, so ${root} was not synced; the request stays marked, but until the directory is writable no invocation can serve it -- run 'bd dolt push --remote origin' there if the write matters.")
    drop_lock "$lock_dir"
    return 0
  fi
  for ((pass = 1; pass <= 3; pass++)); do
    mv -f "$pending" "$inflight" 2>/dev/null || : >"$inflight"

    # Run through `run_tracked` rather than directly, so the pid of the `bd`
    # doing the work is recorded beside the lock while it runs. A kill of this
    # shell does not stop that process, and a later invocation must be able to
    # see it is still going before deciding the lock is free -- otherwise it
    # starts a second push against the same remote.
    run_tracked "$root" "$run_out" dolt commit -m "bd: sync via auggie ${EVENT_NAME}"
    commit_rc=$?
    commit_out=$(cat "$run_out" 2>/dev/null)

    # A no-op commit is the common case and is not an error.
    if [ "$commit_rc" -ne 0 ] && ! grep -qiE 'nothing to commit|no changes' <<<"$commit_out"; then
      # As with a failed push: hand the request back so it is retried.
      WARNINGS+=("beads: 'bd dolt commit' failed in ${root}, bead store not pushed to DoltHub. Output: ${commit_out}")
      hand_back "$root"
      rm -f "$run_out"
      return 0
    fi

    run_tracked "$root" "$run_out" dolt push --remote origin
    push_rc=$?
    push_out=$(cat "$run_out" 2>/dev/null)

    if [ "$push_rc" -ne 0 ]; then
      rm -f "$run_out"
      WARNINGS+=("beads: 'bd dolt push' failed in ${root}, local bead writes are NOT on DoltHub. Output: ${push_out}")
      hand_back "$root"
      return 0
    fi

    rm -f "$inflight"
    [ -e "$pending" ] || break
  done
  rm -f "$run_out"

  # A push has returned 0, which is a precondition for settling a registry
  # entry rather than proof of one. The loop above is bounded, so it can arrive
  # here with a request still outstanding; `forget_external` re-reads the
  # markers and keeps the entry when it is. Every earlier return from this
  # function leaves the entry in place too, so a sync that failed, timed out or
  # was killed is still owed and every later invocation still finds it.
  forget_external "$root"

  # Released here rather than only in the trap so a later root is not blocked
  # behind a lock this invocation no longer needs.
  drop_lock "$lock_dir"
  return 0
}

for ROOT in "${ROOTS[@]}"; do
  sync_root "$ROOT"
done

prune_registry

flush_warnings

exit 0

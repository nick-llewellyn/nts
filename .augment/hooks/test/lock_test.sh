#!/usr/bin/env bash
# Lock acquisition and pending-marker handoff in beads-sync.sh.
#
# Drives the real hook against a scratch workspace with a stubbed `bd`, so
# the behaviour under test is the shipped script rather than a description
# of it. Nothing here touches the repository's own bead store.

set -uo pipefail

HOOK="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/beads-sync.sh}"
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

# Every temporary file this run makes, the hook's included, lives under one
# directory of its own, removed on the way out however the run ends.
#
# `TMPDIR` is exported so the hook inherits it: the gate files it makes with
# `mktemp` land here too, which is what lets the case asserting no gate is left
# behind look at just this run's. Scanning the shared directory instead reads
# every concurrent run's gates as this one's -- a false failure -- and any it
# leaks are indistinguishable from another suite's litter.
SUITE_TMP=$(mktemp -d "${TMPDIR:-/tmp}/cs-lock-suite.XXXXXX") || exit 2
trap 'rm -rf "$SUITE_TMP"' EXIT
export TMPDIR="$SUITE_TMP"

report() {
  if [ "$1" = ok ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL %s\n' "$2"
  fi
}

# Scratch workspace with a stub `bd` that logs each call and can be made
# to fail or stall on demand.
setup() {
  WS=$(mktemp -d)
  mkdir -p "$WS/.beads" "$WS/bin"
  cat >"$WS/bin/bd" <<'STUB'
#!/usr/bin/env bash
LOG="${BD_LOG:?}"
# `bd -C <dir> dolt <op>`: record which root each op was aimed at, so the
# multi-root cases can tell the difference.
[ "${1:-}" = -C ] && TARGET="${2:-}" || TARGET=""
for a in "$@"; do
  case "$a" in
    commit) echo commit >>"$LOG"; echo "commit $TARGET" >>"$LOG.dirs" ;;
    push) echo push >>"$LOG"; echo "push $TARGET" >>"$LOG.dirs" ;;
  esac
done
if grep -q push <<<"$*"; then
  [ -n "${BD_PUSH_FAIL:-}" ] && { echo "push refused"; exit 1; }
  # Bracket every push, not just a slept one, so a concurrency case can see
  # whether two were ever in flight at once -- which counting alone cannot
  # show. Bracketing only the slow ones makes a fast push invisible, and an
  # overlap it takes part in unobservable.
  echo "push-begin $$" >>"$LOG.span"
  [ -n "${BD_PUSH_SLEEP:-}" ] && sleep "$BD_PUSH_SLEEP"
  echo "push-end $$" >>"$LOG.span"
fi
if grep -q commit <<<"$*"; then
  # BD_COMMIT_FAIL=1 fails with a generic message; any other value is printed
  # as the diagnostic, so a case can choose what a failing commit says.
  if [ -n "${BD_COMMIT_FAIL:-}" ]; then
    [ "$BD_COMMIT_FAIL" = 1 ] && echo "commit refused" || echo "$BD_COMMIT_FAIL"
    exit 1
  fi
  # A no-op said with a non-zero exit, as the hook reads it for a `bd` that
  # does so; 1.2 exits 0 for the same case.
  [ -n "${BD_COMMIT_NOOP:-}" ] && { echo "Nothing to commit."; exit 1; }
fi
exit 0
STUB
  chmod +x "$WS/bin/bd"
  export BD_LOG="$WS/log"
  : >"$BD_LOG"
  PATH="$WS/bin:$ORIG_PATH"
}

teardown() {
  rm -rf "$WS"
  PATH="$ORIG_PATH"
  unset BD_PUSH_FAIL BD_PUSH_SLEEP BD_COMMIT_FAIL BD_COMMIT_NOOP
}

# Feeds one event of type $1 carrying $2 as the command. Remaining
# arguments are extra workspace roots beyond the scratch one. SessionEnd
# carries no tool call, so the command fields are simply ignored there.
#
# `$FIRE_CWD` sets the directory the tool call was launched from, which is
# what a relative `-C` target resolves against. Empty by default, since the
# field is optional on the real event.
event_as() {
  local e="$1" c="$2"; shift 2
  jq -n --arg e "$e" --arg w "$WS" --arg c "$c" \
    --arg d "${FIRE_CWD:-}" --args \
    '{hook_event_name:$e, workspace_roots:([$w] + $ARGS.positional), tool_name:"launch-process", tool_input:({command:$c} + (if $d == "" then {} else {cwd:$d} end))}' \
    "$@"
}

event() { event_as PostToolUse "$@"; }

fire() { event "$@" | "$BASH_UNDER_TEST" "$HOOK" >/dev/null 2>&1; }

# Same, but with the tool call launched from $1.
fire_in() { local d="$1"; shift; FIRE_CWD="$d" fire "$@"; }

# SessionEnd is the backstop for anything PostToolUse missed, so it syncs
# unconditionally. Its warnings go to stderr, not stdout, hence the split.
fire_end() { event_as SessionEnd "" "$@" | "$BASH_UNDER_TEST" "$HOOK" >/dev/null 2>"$WS/err"; }

# Same, but returns the hook's pid so the caller can kill it mid-flight.
fire_bg() {
  event "$@" | "$BASH_UNDER_TEST" "$HOOK" >/dev/null 2>&1 &
  HOOK_PID=$!
}

pending() { [ -e "${1:-$WS}/.beads/.augment-sync.pending" ]; }
inflight() { [ -e "${1:-$WS}/.beads/.augment-sync.inflight" ]; }
count() { grep -c "^$1$" "$BD_LOG" 2>/dev/null | head -1; }

# The registry is NUL-delimited, since a store path may hold a newline, so it
# is read record by record rather than matched as text. `grep -qxF` would
# report a match for either half of such a path on its own.
registered() {
  local wanted="$1" file="${2:-$REG}" entry
  [ -r "$file" ] || return 1
  while IFS= read -r -d '' entry; do
    [ "$entry" = "$wanted" ] && return 0
  done <"$file"
  return 1
}

# The registry's contents, for a failure message.
reg_dump() { tr '\0' ',' <"${1:-$REG}" 2>/dev/null; }

# Writes $@ as the registry, in the delimiting the hook reads.
reg_write() {
  local file="$1" entry
  shift
  : >"$file"
  for entry in "$@"; do printf '%s\0' "$entry" >>"$file"; done
}

# Locks are symlinks naming their owner, so a test that plants one has to
# plant that shape rather than a directory with a pid file inside it. The
# owner is `pid:boot-token`, or a bare pid from before the token existed;
# a planted one is whichever of the two the case is about. `-L` throughout:
# the target is an owner, so the link dangles by design and `-e` would
# report a lock that exists as absent.
hold_lock() { ln -sf "$2" "$1"; }
held_by() { [ "$(readlink "$1" 2>/dev/null)" = "$2" ]; }
lock_exists() { [ -L "$1" ]; }

# The owner fields as the shipped hook computes them, lifted from it rather
# than reimplemented: a planted owner has to agree with what the hook reads
# back, and a second implementation here could drift from it silently.
#
# Written to a name `mktemp` chooses, not a fixed one. A fixed name in a
# world-writable directory is a file this suite writes and then *sources*: a
# second run of it truncates the copy the first is about to read, and a symlink
# planted at that name beforehand redirects the write onto whatever it points
# at -- `>` follows a symlink, so the extraction lands on the target while the
# link stays a link. An unpredictable name is what makes both unreachable.
OWNER_FIELDS=$(mktemp "$SUITE_TMP/cs-owner-fields.XXXXXX") || exit 2
sed -n '/^boot_token()/,/^}/p;/^proc_start()/,/^}/p' "$HOOK" >"$OWNER_FIELDS"
# Passed in as an argument rather than spliced into the script text, so the
# path is data to the shell that reads it and not more of the program.
self_token() { bash -c '. "$1"; boot_token' _ "$OWNER_FIELDS"; }
start_of() { bash -c '. "$1"; proc_start "$2"' _ "$OWNER_FIELDS" "$1"; }

# Two waiters are hard to interleave through the hook, so the guard cases
# below drive `take_guard` directly. It is lifted from the shipped script
# with the lock primitives it calls, so what runs is the real function
# rather than a copy that can drift from it.
extract_guard() {
  sed -n '/^take_lock()/,/^drop_lock()/p;/^take_guard()/,/^}/p' \
    "$HOOK" >"$WS/guard.sh"
}

# --- a write syncs and leaves no marker behind -------------------------
setup
fire 'bd close CHR-1'
[ "$(count commit)" -eq 1 ] && [ "$(count push)" -eq 1 ] && ! pending &&
  report ok || report bad "write: commit+push once, marker cleared (log: $(tr '\n' ',' <"$BD_LOG"))"
teardown

# --- a read-only command does not sync ---------------------------------
setup
fire 'bd list'
[ "$(count commit)" -eq 0 ] && [ "$(count push)" -eq 0 ] && ! pending &&
  report ok || report bad "read-only: no sync"
teardown

# --- a push failure leaves the marker set for a later retry ------------
setup
export BD_PUSH_FAIL=1
fire 'bd close CHR-1'
pending && report ok || report bad "push failure must leave marker set"
# ... and the next invocation syncs on the marker alone, despite a read-only
# command of its own.
unset BD_PUSH_FAIL
fire 'bd list'
[ "$(count commit)" -eq 2 ] && report ok ||
  report bad "leftover marker must force a sync (commits=$(count commit))"
! pending && report ok || report bad "successful retry must clear marker"
teardown

# --- a commit failure also leaves the marker set -----------------------
setup
export BD_COMMIT_FAIL=1
fire 'bd close CHR-1'
pending && report ok || report bad "commit failure must leave marker set"
[ "$(count push)" -eq 0 ] && report ok || report bad "commit failure must not push"
teardown

# --- a no-op commit said with a non-zero exit is not a failure ---------
setup
export BD_COMMIT_NOOP=1
fire 'bd close CHR-1'
[ "$(count push)" -eq 1 ] && report ok || report bad "no-op commit must still push (pushes=$(count push))"
! pending && report ok || report bad "no-op commit must clear marker"
teardown

# --- a failure that merely mentions the no-op phrase is still a failure --
# The old reading matched the phrase anywhere in the output, so a lock error
# that quoted it, or any diagnostic that mentioned it in passing, was taken
# for a no-op: the hook pushed, cleared the marker, and the only record that
# the store was owed a retry went with it.
for msg in \
  'error: database is locked; nothing to commit until the other writer exits' \
  'commit failed: no changes were staged because the working set is corrupt' \
  $'Nothing to commit.\nerror: could not update working set'; do
  setup
  export BD_COMMIT_FAIL="$msg"
  fire 'bd close CHR-1'
  pending && report ok || report bad "failure quoting the no-op phrase must leave marker set: $msg"
  [ "$(count push)" -eq 0 ] && report ok || report bad "failure quoting the no-op phrase must not push: $msg"
  teardown
done

# --- a temporary directory that refuses a file is said so ---------------
# The output of each `bd` is read back from a file under $TMPDIR, and a
# directory that refuses one refuses the next invocation's too: returning in
# silence disabled every sync for as long as the condition lasted, the marker
# holding each request only for a retry that met the same refusal. So it is
# warned about, the marker left standing, and the lock released.
setup
TMPDIR="$WS/nowhere" event 'bd close CHR-1' | TMPDIR="$WS/nowhere" "$BASH_UNDER_TEST" "$HOOK" >"$WS/out" 2>/dev/null
grep -q "could not create a temporary file" "$WS/out" && report ok ||
  report bad "a refused temporary file must be warned about (out: $(tr '\n' ',' <"$WS/out"))"
[ "$(count commit)" -eq 0 ] && report ok ||
  report bad "no sync can run without the output file (commits=$(count commit))"
pending && report ok || report bad "the request must stay marked"
! lock_exists "$WS/.beads/.augment-sync.lock" && report ok ||
  report bad "the lock must be released for the next invocation"
# ... and the next invocation, with a working directory, serves it on the
# marker alone.
fire 'bd list'
[ "$(count commit)" -eq 1 ] && report ok ||
  report bad "the marked request must be served once the directory works (commits=$(count commit))"
teardown

# --- lock held by a live process: the invocation defers, not drops -----
setup
sleep 300 &
HOLDER=$!
hold_lock "$WS/.beads/.augment-sync.lock" "$HOLDER"
# The lock loop bounds itself at ~30s, so no external timeout is needed
# (and macOS has no `timeout`). Run it in the background and reap it.
event 'bd close CHR-1' | "$BASH_UNDER_TEST" "$HOOK" >"$WS/out" 2>&1 &
wait $! 2>/dev/null
[ "$(count commit)" -eq 0 ] && report ok ||
  report bad "must not sync while a live holder has the lock"
pending && report ok || report bad "deferred request must leave marker set"
# A deferral the marker records is not a stranded write, so it is not warned
# about as one.
! grep -q "could not record" "$WS/out" && report ok ||
  report bad "a recorded deferral must not be reported as unrecorded (out: $(tr '\n' ',' <"$WS/out"))"
kill "$HOLDER" 2>/dev/null
wait "$HOLDER" 2>/dev/null
teardown

# --- a marker that cannot be written is said so, not returned over -------
# Timing out on the lock is safe only because the marker stands: the holder's
# next pass finds it, or the next invocation does. When the marker cannot be
# written -- a full disk; here, a `.beads` made read-only -- and the lock is
# then held past the deadline, the write has neither a push nor a record that
# one is owed, and returning in silence left the agent nothing to act on. The
# `.beads` is made read-only after the holder's lock is planted, since the lock
# lives in the same directory.
setup
sleep 300 &
HOLDER=$!
hold_lock "$WS/.beads/.augment-sync.lock" "$HOLDER"
chmod 0555 "$WS/.beads"
event 'bd close CHR-1' | "$BASH_UNDER_TEST" "$HOOK" >"$WS/out" 2>/dev/null &
wait $! 2>/dev/null
chmod 0755 "$WS/.beads"
! pending && report ok ||
  report bad "precondition: a read-only .beads must refuse the marker (running as root?)"
grep -qF "could not record that $WS is owed a sync" "$WS/out" && report ok ||
  report bad "an unrecorded deferral must be warned about (out: $(tr '\n' ',' <"$WS/out"))"
[ "$(count commit)" -eq 0 ] && report ok ||
  report bad "must not sync while a live holder has the lock"
kill "$HOLDER" 2>/dev/null
wait "$HOLDER" 2>/dev/null
teardown

# --- lock owned by a dead pid is reclaimed -----------------------------
setup
# A pid that has exited; reuse is vanishingly unlikely within this run.
(exit 0) &
DEAD=$!
wait "$DEAD" 2>/dev/null
hold_lock "$WS/.beads/.augment-sync.lock" "$DEAD"
fire 'bd close CHR-1'
[ "$(count commit)" -ge 1 ] && report ok ||
  report bad "must reclaim a lock whose owner is gone"
! lock_exists "$WS/.beads/.augment-sync.lock" && report ok ||
  report bad "lock must be released on exit"
teardown

# --- a lock from an earlier boot is reclaimed --------------------------
# A pid is only an identity within one boot. A lock that survived a restart
# names a number the kernel is free to have reissued, and the process now
# holding it answers `kill -0`: the lock is judged live for good, and every
# sync of that store waits out its budget and gives up. The boot token in
# the owner is what tells the two apart. Planted with a live pid, so only
# the token can distinguish it.
setup
sleep 300 &
LIVE=$!
hold_lock "$WS/.beads/.augment-sync.lock" "$LIVE:1"
fire 'bd close CHR-1'
[ "$(count commit)" -ge 1 ] && report ok ||
  report bad "a lock from an earlier boot must be reclaimed (commits=$(count commit))"
kill "$LIVE" 2>/dev/null
wait "$LIVE" 2>/dev/null
teardown

# --- a lock from this boot is still respected --------------------------
# The token must not read every owner as dead: a live holder from the
# current boot carries this boot's token, and stealing its lock is the
# double push the lock exists to stop.
setup
sleep 300 &
LIVE=$!
TOKEN=$(self_token)
hold_lock "$WS/.beads/.augment-sync.lock" "$LIVE${TOKEN:+:$TOKEN}"
fire 'bd close CHR-1' &
wait $! 2>/dev/null
[ "$(count commit)" -eq 0 ] && report ok ||
  report bad "a live holder from this boot must keep its lock (commits=$(count commit))"
kill "$LIVE" 2>/dev/null
wait "$LIVE" 2>/dev/null
teardown

# --- a live holder whose pid was reused is not mistaken for dead -------
# The converse of the case below: a lock whose owner is genuinely live must
# still be respected once the start time is part of the owner. Planted with
# this boot's token and the holder's real start time, which is the shape the
# hook writes.
setup
sleep 300 &
LIVE=$!
hold_lock "$WS/.beads/.augment-sync.lock" "$LIVE:$(self_token):$(start_of "$LIVE")"
fire 'bd close CHR-1' &
wait $! 2>/dev/null
[ "$(count commit)" -eq 0 ] && report ok ||
  report bad "a live holder with a full owner keeps its lock (commits=$(count commit))"
kill "$LIVE" 2>/dev/null
wait "$LIVE" 2>/dev/null
teardown

# --- a reused pid does not wedge the lock ------------------------------
# The boot token settles pid reuse across boots but not within one. A hook
# killed mid-pass frees its pid, and an unrelated process given that number
# later answers `kill -0` under this boot's token exactly as the real owner
# would -- so the lock is judged live for good and every sync of that store
# waits out its budget. The start time in the owner tells them apart:
# planted with a live pid and this boot's token, differing only in when the
# process it names started.
setup
sleep 300 &
LIVE=$!
hold_lock "$WS/.beads/.augment-sync.lock" "$LIVE:$(self_token):19700101000000"
fire 'bd close CHR-1'
[ "$(count commit)" -ge 1 ] && report ok ||
  report bad "a reused pid must not wedge the lock (commits=$(count commit))"
kill "$LIVE" 2>/dev/null
wait "$LIVE" 2>/dev/null
teardown

# --- a live legacy directory lock is not deleted -----------------------
# Before the symlink format, a lock was a directory with a pid file inside.
# `readlink` reads nothing from one, and reclaiming on an empty read deleted
# it without ever asking whose it was -- taking a live holder's lock and
# putting two pushes against the same remote. The pid file is what names it.
setup
mkdir -p "$WS/.beads/.augment-sync.lock"
sleep 300 &
LIVE=$!
echo "$LIVE" >"$WS/.beads/.augment-sync.lock/pid"
fire 'bd close CHR-1' &
wait $! 2>/dev/null
[ "$(count commit)" -eq 0 ] && report ok ||
  report bad "a live legacy lock must be respected (commits=$(count commit))"
[ -f "$WS/.beads/.augment-sync.lock/pid" ] && report ok ||
  report bad "a live legacy lock must not be deleted"
kill "$LIVE" 2>/dev/null
wait "$LIVE" 2>/dev/null
teardown

# --- a dead legacy directory lock is reclaimed -------------------------
setup
mkdir -p "$WS/.beads/.augment-sync.lock"
(exit 0) &
DEAD=$!
wait "$DEAD" 2>/dev/null
echo "$DEAD" >"$WS/.beads/.augment-sync.lock/pid"
fire 'bd close CHR-1'
[ "$(count commit)" -ge 1 ] && report ok ||
  report bad "a legacy lock with a dead owner must be reclaimed (commits=$(count commit))"
teardown

# --- an unidentifiable lock is left alone ------------------------------
# A directory with no readable pid file names no generation. Deleting it is
# the same unguarded delete as before -- nothing read later can confirm it
# is still the one that was judged -- so it is waited out instead.
setup
mkdir -p "$WS/.beads/.augment-sync.lock"
fire 'bd close CHR-1' &
wait $! 2>/dev/null
[ "$(count commit)" -eq 0 ] && report ok ||
  report bad "an unidentifiable lock must not be reclaimed (commits=$(count commit))"
[ -d "$WS/.beads/.augment-sync.lock" ] && report ok ||
  report bad "an unidentifiable lock must be left in place"
teardown

# --- a marker set mid-push earns a second pass -------------------------
setup
( sleep 1; : >"$WS/.beads/.augment-sync.pending" ) &
POKE=$!
export BD_PUSH_SLEEP=3
fire 'bd close CHR-1'
wait "$POKE" 2>/dev/null
[ "$(count push)" -ge 2 ] && report ok ||
  report bad "request arriving mid-push must earn another pass (pushes=$(count push))"
teardown

# --- a sync killed mid-push stays outstanding --------------------------
# The hook's own timeout lands here. No failure branch runs, so only the
# durable in-flight marker can record that a sync was owed.
setup
export BD_PUSH_SLEEP=30
fire_bg 'bd close CHR-1'
sleep 3
kill -9 "$HOOK_PID" 2>/dev/null
wait "$HOOK_PID" 2>/dev/null
pkill -f "$WS/bin/bd" 2>/dev/null
{ pending || inflight; } && report ok ||
  report bad "a sync killed mid-push must leave a marker behind"
# ... and the next invocation acts on it, even for a read-only command.
unset BD_PUSH_SLEEP
rm -f "$WS/.beads/.augment-sync.lock"
fire 'bd list'
[ "$(count push)" -ge 2 ] && report ok ||
  report bad "killed sync must be retried by the next invocation (pushes=$(count push))"
teardown

# --- a second root with a bead store is synced too ---------------------
setup
ALT=$(mktemp -d)
mkdir -p "$ALT/.beads"
fire 'bd close CHR-1' "$ALT"
grep -q "push $WS" "$BD_LOG.dirs" && report ok ||
  report bad "first root must be pushed (dirs: $(tr '\n' ',' <"$BD_LOG.dirs"))"
grep -q "push $ALT" "$BD_LOG.dirs" && report ok ||
  report bad "second root must be pushed (dirs: $(tr '\n' ',' <"$BD_LOG.dirs"))"
rm -rf "$ALT"
teardown

# --- a root without a bead store is skipped ----------------------------
setup
ALT=$(mktemp -d)
fire 'bd close CHR-1' "$ALT"
! grep -q "push $ALT" "$BD_LOG.dirs" && report ok ||
  report bad "a root with no .beads must not be synced"
rm -rf "$ALT"
teardown

# --- a marker in any root is reason enough to sync ---------------------
# The write landed in the second root; a later read-only command in the
# session must still clear it.
setup
ALT=$(mktemp -d)
mkdir -p "$ALT/.beads"
: >"$ALT/.beads/.augment-sync.pending"
fire 'bd list' "$ALT"
grep -q "push $ALT" "$BD_LOG.dirs" && report ok ||
  report bad "a marker in a non-first root must force a sync"
[ ! -e "$ALT/.beads/.augment-sync.pending" ] && report ok ||
  report bad "that sync must clear the marker"
rm -rf "$ALT"
teardown

# --- one root's held lock does not block the other ---------------------
setup
ALT=$(mktemp -d)
mkdir -p "$ALT/.beads"
sleep 300 &
HOLDER=$!
hold_lock "$WS/.beads/.augment-sync.lock" "$HOLDER"
fire 'bd close CHR-1' "$ALT" &
wait $! 2>/dev/null
grep -q "push $ALT" "$BD_LOG.dirs" && report ok ||
  report bad "a lock on one root must not strand another"
pending && report ok || report bad "the blocked root keeps its marker"
kill "$HOLDER" 2>/dev/null
wait "$HOLDER" 2>/dev/null
rm -rf "$ALT"
teardown

# --- a `-C` target outside every root is synced too --------------------
# `bd -C <dir>` can address a store no workspace root contains. Nothing
# would ever revisit it: SessionEnd builds its root list the same way, so
# the write would sit local indefinitely.
setup
OUT=$(mktemp -d)
mkdir -p "$OUT/.beads"
fire "bd -C $OUT close CHR-1"
grep -q "push $OUT" "$BD_LOG.dirs" && report ok ||
  report bad "a -C target outside the roots must be synced (dirs: $(tr '\n' ',' <"$BD_LOG.dirs"))"
grep -q "push $WS" "$BD_LOG.dirs" && report ok ||
  report bad "the workspace root must still be synced alongside it"
rm -rf "$OUT"
teardown

# --- a quoted `-C` target is recognised --------------------------------
setup
OUT=$(mktemp -d)
mkdir -p "$OUT/.beads"
fire "bd -C \"$OUT\" update CHR-1 --claim"
grep -q "push $OUT" "$BD_LOG.dirs" && report ok ||
  report bad "a quoted -C target must be synced (dirs: $(tr '\n' ',' <"$BD_LOG.dirs"))"
rm -rf "$OUT"
teardown

# --- a `-C` target with no bead store is not invented ------------------
setup
OUT=$(mktemp -d)
fire "bd -C $OUT close CHR-1"
! grep -q "push $OUT" "$BD_LOG.dirs" && report ok ||
  report bad "a -C target with no .beads must not be synced"
rm -rf "$OUT"
teardown

# --- a read-only `-C` command adds nothing -----------------------------
# Only mutating segments contribute a target; a query elsewhere must not
# drag another store into the sync set.
setup
OUT=$(mktemp -d)
mkdir -p "$OUT/.beads"
fire "bd -C $OUT list"
[ ! -s "$BD_LOG.dirs" ] && report ok ||
  report bad "a read-only -C command must not sync anything (dirs: $(tr '\n' ',' <"$BD_LOG.dirs"))"
rm -rf "$OUT"
teardown

# --- two `-C` targets in one command are both synced -------------------
# The segment loop no longer stops at the first mutating segment, since
# each may name a different store.
setup
ONE=$(mktemp -d); TWO=$(mktemp -d)
mkdir -p "$ONE/.beads" "$TWO/.beads"
fire "bd -C $ONE close CHR-1 && bd -C $TWO close CHR-2"
grep -q "push $ONE" "$BD_LOG.dirs" && grep -q "push $TWO" "$BD_LOG.dirs" &&
  report ok || report bad "both -C targets must sync (dirs: $(tr '\n' ',' <"$BD_LOG.dirs"))"
rm -rf "$ONE" "$TWO"
teardown

# --- a `-C` target that is already a root is not synced twice ----------
setup
fire "bd -C $WS close CHR-1"
[ "$(count push)" -eq 1 ] && report ok ||
  report bad "a -C target equal to a root must not double-sync (pushes=$(count push))"
teardown

# --- a single-quoted `-C` target is recognised -------------------------
setup
OUT=$(mktemp -d)
mkdir -p "$OUT/.beads"
fire "bd -C '$OUT' close CHR-1"
grep -q "push $OUT" "$BD_LOG.dirs" && report ok ||
  report bad "a single-quoted -C target must be synced (dirs: $(tr '\n' ',' <"$BD_LOG.dirs"))"
rm -rf "$OUT"
teardown

# --- a `-C` target containing a space is not truncated -----------------
# Capturing up to the first space names a directory that does not exist,
# so the store that changed is silently left out of the sync set. All
# three ways of writing the path must survive.
for QUOTE in dq sq esc; do
  setup
  BASE=$(mktemp -d)
  OUT="$BASE/a b"
  mkdir -p "$OUT/.beads"
  case "$QUOTE" in
    dq) fire "bd -C \"$OUT\" close CHR-1" ;;
    sq) fire "bd -C '$OUT' close CHR-1" ;;
    esc) fire "bd -C ${OUT// /\\ } close CHR-1" ;;
  esac
  grep -qF "push $OUT" "$BD_LOG.dirs" && report ok ||
    report bad "a -C path with a space ($QUOTE) must be synced (dirs: $(tr '\n' ',' <"$BD_LOG.dirs"))"
  rm -rf "$BASE"
  teardown
done

# --- a `-C` target written as a variable is resolved -------------------
# The hook sees the command as written, never as run, so `-C "$OUT"` arrives
# literally. Unresolved it names no store, is dropped, and the write is
# stranded outside every root -- exactly what the `-C` handling is for.
for FORM in dq bare braced env tilde; do
  setup
  BASE=$(mktemp -d)
  OUT="$BASE/store"
  mkdir -p "$OUT/.beads"
  case "$FORM" in
    dq) fire "OUT=$OUT; bd -C \"\$OUT\" close CHR-1" ;;
    bare) fire "OUT=$OUT && bd -C \$OUT close CHR-1" ;;
    braced) fire "D=$BASE; bd -C \"\${D}/store\" close CHR-1" ;;
    # Subshells, since assignments prefixed to a function call persist in
    # bash and would leak `HOME` into every later case.
    env) (export OUT_ENV="$OUT"; fire 'bd -C "$OUT_ENV" close CHR-1') ;;
    tilde) (export HOME="$BASE"; fire 'bd -C ~/store close CHR-1') ;;
  esac
  grep -qF "push $OUT" "$BD_LOG.dirs" && report ok ||
    report bad "a -C target via $FORM must be resolved (dirs: $(tr '\n' ',' <"$BD_LOG.dirs"))"
  rm -rf "$BASE"
  teardown
done

# --- a `-C` target after a shell keyword is found ----------------------
# The detector admits a `bd` after whitespace, so these all count as
# writes. A target the capture then misses is worse than an undetected
# write: the roots sync, nothing looks wrong, and the external store is
# never registered, so neither the marker retry nor SessionEnd can
# rediscover it.
for LEAD in 'if' 'while' 'until' '!' 'time' 'if !' 'then'; do
  setup
  OUT=$(mktemp -d)
  mkdir -p "$OUT/.beads"
  fire "$LEAD bd -C $OUT close CHR-1"
  grep -qF "push $OUT" "$BD_LOG.dirs" && report ok ||
    report bad "a -C target after '$LEAD' must be synced (dirs: $(tr '\n' ',' <"$BD_LOG.dirs"))"
  rm -rf "$OUT"
  teardown
done

# --- a quoted keyword-led target is found too --------------------------
# The widening must not be limited to the bare form, or a path with a
# space stays lost in exactly the arrangement the keyword case fixes.
setup
BASE=$(mktemp -d)
OUT="$BASE/a b"
mkdir -p "$OUT/.beads"
fire "if bd -C \"$OUT\" close CHR-1; then echo done; fi"
grep -qF "push $OUT" "$BD_LOG.dirs" && report ok ||
  report bad "a quoted -C target after a keyword must be synced (dirs: $(tr '\n' ',' <"$BD_LOG.dirs"))"
rm -rf "$BASE"
teardown

# --- a non-keyword word before `bd` still names no target --------------
# The anchor is what stops argument text reading as an invocation, so the
# widening is a fixed list of keywords rather than "any whitespace". A
# command that merely mentions the text must not contribute a store.
setup
OUT=$(mktemp -d)
mkdir -p "$OUT/.beads"
fire "echo bd -C $OUT close CHR-1"
! grep -qF "push $OUT" "$BD_LOG.dirs" && report ok ||
  report bad "a mentioned -C must not be synced (dirs: $(tr '\n' ',' <"$BD_LOG.dirs"))"
rm -rf "$OUT"
teardown

# --- a keyword-led read-only command is suppressed ---------------------
# Detection and suppression see the same command word, so a keyword in
# front of `bd` no longer changes which verb is judged. Under the previous
# text matching this synced: suppression was anchored at `^`, the keyword
# defeated the anchor, and the query was read as a write. That was accepted
# as erring in the safe direction rather than argued for on its merits, and
# the scanner removes the need for the concession entirely -- the keyword
# is a prefix word, `list` is still the verb.
setup
OUT=$(mktemp -d)
mkdir -p "$OUT/.beads"
fire "if bd -C $OUT list; then echo done; fi"
[ ! -s "$BD_LOG.dirs" ] && report ok ||
  report bad "a keyword-led read-only -C must be suppressed (dirs: $(tr '\n' ',' <"$BD_LOG.dirs"))"
rm -rf "$OUT"
teardown

# --- an unanchored read-only command is still suppressed ---------------
# The paired direction, so the case above is suppression working rather
# than the target having been lost before it was ever judged.
setup
OUT=$(mktemp -d)
mkdir -p "$OUT/.beads"
fire "bd -C $OUT list"
[ ! -s "$BD_LOG.dirs" ] && report ok ||
  report bad "an unanchored read-only -C must still be suppressed (dirs: $(tr '\n' ',' <"$BD_LOG.dirs"))"
rm -rf "$OUT"
teardown

# --- the last assignment of a reused name wins -------------------------
# The one in effect when the `bd` runs, not the first one written.
setup
BASE=$(mktemp -d)
mkdir -p "$BASE/one/.beads" "$BASE/two/.beads"
fire "OUT=$BASE/one; OUT=$BASE/two; bd -C \"\$OUT\" close CHR-1"
grep -qF "push $BASE/two" "$BD_LOG.dirs" && report ok ||
  report bad "the last assignment must win (dirs: $(tr '\n' ',' <"$BD_LOG.dirs"))"
! grep -qF "push $BASE/one" "$BD_LOG.dirs" && report ok ||
  report bad "an overwritten assignment must not be synced"
rm -rf "$BASE"
teardown

# --- an unresolvable target neither loops nor invents a store ----------
# Resolution is best-effort: the roots are synced regardless, so failing to
# resolve costs nothing, while hanging on a reference cycle costs the sync.
#
# Run in the background and timed out here, rather than timed in the
# foreground. A foreground call cannot express this: the hang being
# guarded against would park the suite inside `fire`, which never returns
# to reach the assertion, so the case could only ever report the passing
# case. The watchdog turns that freeze into a reported failure.
setup
fire_bg 'A=$B; B=$A; bd -C "$A" close CHR-1'
WEDGED=1
for _ in $(seq 20); do
  kill -0 "$HOOK_PID" 2>/dev/null || { WEDGED=0; break; }
  sleep 1
done
if [ "$WEDGED" -eq 1 ]; then
  kill -9 "$HOOK_PID" 2>/dev/null
  pkill -9 -P "$HOOK_PID" 2>/dev/null
fi
wait "$HOOK_PID" 2>/dev/null
[ "$WEDGED" -eq 0 ] && report ok ||
  report bad "a reference cycle must not hang"
[ "$(count push)" -eq 1 ] && report ok ||
  report bad "an unresolvable -C must still sync the roots (pushes=$(count push))"
teardown

# --- an external target survives a failed sync -------------------------
# The marker sits under a store no later event names, so without a record
# in the workspace neither the marker retry nor the SessionEnd backstop
# can find it, and the two recovery paths this design rests on both miss.
setup
OUT=$(mktemp -d)
mkdir -p "$OUT/.beads"
export BD_PUSH_FAIL=1
fire "bd -C $OUT close CHR-1"
[ -e "$OUT/.beads/.augment-sync.pending" ] && report ok ||
  report bad "precondition: a failed external push leaves its marker"
unset BD_PUSH_FAIL
# A later command naming nothing external at all must still retry it.
: >"$BD_LOG.dirs"
fire 'bd list'
grep -q "push $OUT" "$BD_LOG.dirs" && report ok ||
  report bad "an external target must be retried by a later invocation (dirs: $(tr '\n' ',' <"$BD_LOG.dirs"))"
[ ! -e "$OUT/.beads/.augment-sync.pending" ] && report ok ||
  report bad "the retry must clear the external marker"
rm -rf "$OUT"
teardown

# --- the SessionEnd backstop reaches an external target ----------------
setup
OUT=$(mktemp -d)
mkdir -p "$OUT/.beads"
export BD_PUSH_FAIL=1
fire "bd -C $OUT close CHR-1"
unset BD_PUSH_FAIL
: >"$BD_LOG.dirs"
fire_end
grep -q "push $OUT" "$BD_LOG.dirs" && report ok ||
  report bad "SessionEnd must reach an external target (dirs: $(tr '\n' ',' <"$BD_LOG.dirs"))"
rm -rf "$OUT"
teardown

# --- a settled external target is forgotten ----------------------------
# The record exists only to carry unfinished work forward. Kept past that,
# every later invocation would commit a store it has no reason to touch --
# and one that may since have been deleted.
setup
OUT=$(mktemp -d)
mkdir -p "$OUT/.beads"
fire "bd -C $OUT close CHR-1"
: >"$BD_LOG.dirs"
fire 'bd close CHR-1'
! grep -q "push $OUT" "$BD_LOG.dirs" && report ok ||
  report bad "a settled external target must not be synced again (dirs: $(tr '\n' ',' <"$BD_LOG.dirs"))"
rm -rf "$OUT"
teardown

# --- a stale-lock reclaim does not delete a live lock ------------------
# Reading the pid and removing the directory are two steps. A waiter that
# read a dead pid, then slept while the lock changed hands, must not
# delete the new owner's lock: two invocations would push at once.
setup
(exit 0) &
DEAD=$!
wait "$DEAD" 2>/dev/null
hold_lock "$WS/.beads/.augment-sync.lock" "$DEAD"
# Hold the reclaim guard with a live process, so the waiter's reclaim is
# refused rather than racing it.
sleep 300 &
GUARD=$!
hold_lock "$WS/.beads/.augment-sync.reclaim" "$GUARD"
fire 'bd close CHR-1' &
wait $! 2>/dev/null
[ "$(count commit)" -eq 0 ] && report ok ||
  report bad "a waiter must not reclaim while another holds the guard (commits=$(count commit))"
pending && report ok || report bad "the refused waiter keeps its marker"
kill "$GUARD" 2>/dev/null
wait "$GUARD" 2>/dev/null
teardown

# --- a guard whose holder died is itself reclaimed ---------------------
# Otherwise one kill inside a three-call window disables reclamation for
# the life of the store, reinstating the wedge reclaim exists to undo.
setup
(exit 0) &
DEAD=$!
wait "$DEAD" 2>/dev/null
hold_lock "$WS/.beads/.augment-sync.lock" "$DEAD"
hold_lock "$WS/.beads/.augment-sync.reclaim" "$DEAD"
fire 'bd close CHR-1' &
wait $! 2>/dev/null
[ "$(count commit)" -ge 1 ] && report ok ||
  report bad "a dead guard holder must not block reclamation (commits=$(count commit))"
! lock_exists "$WS/.beads/.augment-sync.reclaim" && report ok ||
  report bad "the guard must be released after reclaiming"
teardown

# --- two waiters cannot both hold the reclaim guard --------------------
# The guard closes a validate-then-delete race, so it must not contain one.
# Deleting a guard judged stale and then recreating it lets a second waiter
# delete the first's live guard and recreate its own, leaving both believing
# they may remove the lock -- the race, one level down. Exercised on the
# function directly, two waiters being hard to interleave through the hook.
setup
GUARD="$WS/.beads/g"
(exit 0) &
DEAD=$!
wait "$DEAD" 2>/dev/null
hold_lock "$GUARD" "$DEAD"
extract_guard
[ -s "$WS/guard.sh" ] && report ok || report bad "take_guard must be extractable"
# Winners hold briefly and bracket the interval. Claiming in turn is correct
# -- each release leaves the guard free -- so the invariant is that no two
# hold it at the same moment, which counting wins cannot express.
for _ in 1 2 3 4 5 6 7 8; do
  bash -c ". '$WS/guard.sh'
    take_guard '$GUARD' || exit 0
    echo \"in \$\$\" >>'$WS/held'
    sleep 2
    echo \"out \$\$\" >>'$WS/held'
    drop_lock '$GUARD'" &
done
wait
OVERLAP=0
DEPTH=0
while read -r KIND _; do
  case "$KIND" in
    in) DEPTH=$((DEPTH + 1)); [ "$DEPTH" -gt 1 ] && OVERLAP=1 ;;
    out) DEPTH=$((DEPTH - 1)) ;;
  esac
done <"$WS/held"
[ "$OVERLAP" -eq 0 ] && report ok ||
  report bad "two waiters must not hold the guard at once (held: $(tr '\n' ',' <"$WS/held"))"
[ -s "$WS/held" ] && report ok || report bad "at least one waiter must claim a stale guard"
teardown

# --- an orphaned election does not wedge the guard ---------------------
# A hook killed between creating its election and removing it leaves the
# directory behind. Treated as a live contender, that turns a one-off kill
# into a permanent refusal to reclaim: every later waiter for the same dead
# holder stands down, the stale lock is never cleared, and every sync of
# that store times out for good.
setup
GUARD="$WS/.beads/g"
(exit 0) &
DEAD=$!
wait "$DEAD" 2>/dev/null
hold_lock "$GUARD" "$DEAD"
extract_guard
# Two orphans, so a fix that only steps over one is not enough.
hold_lock "$GUARD.stale.$DEAD.0" "$DEAD"
hold_lock "$GUARD.stale.$DEAD.1" "$DEAD"
bash -c ". '$WS/guard.sh'; take_guard '$GUARD' && echo won >'$WS/won'"
[ -e "$WS/won" ] && report ok ||
  report bad "an orphaned election must not block reclamation"
! held_by "$GUARD" "$DEAD" && report ok ||
  report bad "the stale guard must have been replaced"
teardown

# --- a live election is still respected --------------------------------
# Stepping over orphans must not step over a contender that is running:
# both would then delete the same guard, which is the race being closed.
setup
GUARD="$WS/.beads/g"
(exit 0) &
DEAD=$!
wait "$DEAD" 2>/dev/null
hold_lock "$GUARD" "$DEAD"
extract_guard
sleep 300 &
LIVE=$!
hold_lock "$GUARD.stale.$DEAD.0" "$LIVE"
bash -c ". '$WS/guard.sh'; take_guard '$GUARD' && echo won >'$WS/won'"
[ ! -e "$WS/won" ] && report ok ||
  report bad "a live election must refuse a second waiter"
held_by "$GUARD" "$DEAD" && report ok ||
  report bad "the refused waiter must leave the guard alone"
kill "$LIVE" 2>/dev/null
wait "$LIVE" 2>/dev/null
teardown

# --- a lock never exists without naming its owner ----------------------
# Creating the lock and recording who holds it were two steps, so a holder
# interrupted between them published a lock nobody owned. A waiter cannot
# tell that from a lock whose creator died, so any delay treated as proof of
# death is a guess -- and guessing wrong hands one lock to two processes.
#
# Killing the creator the moment the lock appears is what makes the window
# observable: the interval is microseconds under contention, but a kill
# lands inside it every time. The invariant that makes the guess
# unnecessary is that no kill can leave the lock unowned.
setup
extract_guard
LOCK="$WS/.beads/k"
UNOWNED=0
for _ in $(seq 40); do
  rm -f "$LOCK"
  rm -rf "$LOCK"
  bash -c ". '$WS/guard.sh'
    while :; do take_lock '$LOCK' && break; done
    sleep 30" &
  CREATOR=$!
  # Spin rather than sleep: the window closes in microseconds, and any
  # delay here lands after it.
  while [ ! -L "$LOCK" ] && [ ! -d "$LOCK" ]; do
    kill -0 "$CREATOR" 2>/dev/null || break
  done
  kill -9 "$CREATOR" 2>/dev/null
  wait "$CREATOR" 2>/dev/null
  if { [ -L "$LOCK" ] || [ -d "$LOCK" ]; } &&
    [ -z "$(readlink "$LOCK" 2>/dev/null)$(cat "$LOCK/pid" 2>/dev/null)" ]; then
    UNOWNED=$((UNOWNED + 1))
  fi
done
[ "$UNOWNED" -eq 0 ] && report ok ||
  report bad "a killed creator must not leave an unowned lock ($UNOWNED of 40)"
rm -f "$LOCK"
teardown

# --- an unowned lock is never reissued on a timer -----------------------
# What the ambiguity forced. An unowned lock could not be told apart from a
# live one caught mid-creation, so the wait for an owner to appear stood in
# for proof of death -- and a holder slower than the wait had its lock
# reissued. Planting an unowned lock is the state that used to trigger it;
# the requirement is that it is either reclaimed at once, as a lock from an
# older version is, or refused, but never handed over on a delay.
setup
extract_guard
LOCK="$WS/.beads/unowned"
mkdir "$LOCK"
START=$SECONDS
bash -c ". '$WS/guard.sh'; take_guard '$LOCK' && echo won >'$WS/won'"
ELAPSED=$((SECONDS - START))
[ "$ELAPSED" -lt 3 ] && report ok ||
  report bad "an unowned lock must not be waited on (elapsed=${ELAPSED}s)"
teardown

# --- a lock left by an older version is still reclaimed ----------------
# The previous representation was a directory holding a pid file. One left
# behind by a hook from before this change reads as ownerless, and must be
# cleared rather than blocking the store for good.
setup
mkdir "$WS/.beads/.augment-sync.lock"
echo 1 >"$WS/.beads/.augment-sync.lock/pid"
fire 'bd close CHR-1' &
wait $! 2>/dev/null
[ "$(count commit)" -ge 1 ] && report ok ||
  report bad "a directory lock from an older version must be reclaimed (commits=$(count commit))"
teardown

# --- a reclaim leaves no overlapping pushes ----------------------------
# The whole point of the lock: whatever the reclamation path does, two
# invocations must never be pushing the same store at once.
setup
(exit 0) &
DEAD=$!
wait "$DEAD" 2>/dev/null
hold_lock "$WS/.beads/.augment-sync.lock" "$DEAD"
hold_lock "$WS/.beads/.augment-sync.reclaim" "$DEAD"
export BD_PUSH_SLEEP=3
fire 'bd close CHR-1' &
fire 'bd close CHR-2' &
wait
OVERLAP=0
DEPTH=0
while read -r KIND _; do
  case "$KIND" in
    push-begin) DEPTH=$((DEPTH + 1)); [ "$DEPTH" -gt 1 ] && OVERLAP=1 ;;
    push-end) DEPTH=$((DEPTH - 1)) ;;
  esac
done <"$BD_LOG.span"
[ "$OVERLAP" -eq 0 ] && report ok ||
  report bad "two invocations must not push at once (span: $(tr '\n' ',' <"$BD_LOG.span"))"
teardown

# --- every root is marked before any is synced -------------------------
# A root the invocation never reaches still has a write owed. Marking only
# on arrival means the 60s timeout landing while an earlier root is blocked
# leaves no record for it, so `any_outstanding` reports the work done and
# the write waits for the SessionEnd backstop. Killing mid-wait is the case:
# it is what the timeout does.
setup
ALT=$(mktemp -d)
mkdir -p "$ALT/.beads"
sleep 300 &
HOLDER=$!
for D in "$WS" "$ALT"; do
  hold_lock "$D/.beads/.augment-sync.lock" "$HOLDER"
done
fire_bg 'bd close CHR-1' "$ALT"
sleep 3
kill -9 "$HOOK_PID" 2>/dev/null
wait "$HOOK_PID" 2>/dev/null
pending && report ok || report bad "the first blocked root keeps its marker"
pending "$ALT" && report ok ||
  report bad "a root not yet reached must already be marked"
kill "$HOLDER" 2>/dev/null
wait "$HOLDER" 2>/dev/null
rm -rf "$ALT"
teardown

# --- blocked roots share one waiting budget ----------------------------
# Two roots each waiting the full per-root bound in series runs past the
# 60s hook timeout, so the second is killed rather than visited.
setup
ALT=$(mktemp -d)
mkdir -p "$ALT/.beads"
sleep 300 &
HOLDER=$!
for D in "$WS" "$ALT"; do
  hold_lock "$D/.beads/.augment-sync.lock" "$HOLDER"
done
START=$SECONDS
fire 'bd close CHR-1' "$ALT" &
wait $! 2>/dev/null
[ $((SECONDS - START)) -lt 55 ] && report ok ||
  report bad "blocked roots must share one budget (elapsed=$((SECONDS - START))s)"
kill "$HOLDER" 2>/dev/null
wait "$HOLDER" 2>/dev/null
rm -rf "$ALT"
teardown

# --- a prune cannot clobber a concurrent registry append ---------------
# Prune is a read-modify-write over the registry. Run against a stale
# snapshot it drops an entry appended in between -- and an entry is only
# appended when an external store has a sync owed, so that is exactly the
# record whose loss strands a write.
setup
OUT=$(mktemp -d)
mkdir -p "$OUT/.beads"
fire "bd -C $OUT close CHR-1"
REG="$WS/.beads/.augment-sync.external"
# Re-register by hand: the entry above settled and was pruned.
reg_write "$REG" "$OUT"
sleep 300 &
HOLDER=$!
hold_lock "$REG.guard" "$HOLDER"
fire 'bd close CHR-1'
registered "$OUT" && report ok ||
  report bad "prune must stand down rather than rewrite behind the guard"
kill "$HOLDER" 2>/dev/null
wait "$HOLDER" 2>/dev/null
rm -rf "$OUT"
teardown

# --- a stale registry guard does not disable the registry --------------
setup
OUT=$(mktemp -d)
mkdir -p "$OUT/.beads"
REG="$WS/.beads/.augment-sync.external"
(exit 0) &
DEAD=$!
wait "$DEAD" 2>/dev/null
hold_lock "$REG.guard" "$DEAD"
export BD_PUSH_FAIL=1
fire "bd -C $OUT close CHR-1"
unset BD_PUSH_FAIL
registered "$OUT" && report ok ||
  report bad "a guard whose holder is gone must not block recording"
rm -rf "$OUT"
teardown

# --- a recorder killed before its marker cannot be settled over --------
# `remember_external` writes the entry and then the marker, under the guard.
# Killed between them it leaves the entry with no marker and the guard held by
# a dead pid. If another invocation had already committed that store and is
# mid-push, its `forget_external` reclaims the guard, sees no marker, and drops
# the entry -- for a write that landed after its commit. The store is then
# named by nothing.
#
# Staged from the stub: when the push aimed at the external store begins --
# after its commit, before its settle -- the guard is planted with a dead
# owner, which is all the dead recorder left behind.
setup
OUT=$(mktemp -d)
mkdir -p "$OUT/.beads"
REG="$WS/.beads/.augment-sync.external"
reg_write "$REG" "$OUT"
(exit 0) &
DEAD=$!
wait "$DEAD" 2>/dev/null
mv -f "$WS/bin/bd" "$WS/bin/bd.real"
cat >"$WS/bin/bd" <<STUB
#!/usr/bin/env bash
if [ "\${1:-}" = -C ] && [ "\${2:-}" = "$OUT" ] && grep -q push <<<"\$*"; then
  ln -sf "$DEAD" "$REG.guard"
fi
exec "$WS/bin/bd.real" "\$@"
STUB
chmod +x "$WS/bin/bd"
fire 'bd list'
registered "$OUT" && report ok ||
  report bad "a settle that reclaimed the guard must not drop the entry (reg: $(reg_dump))"
pending "$OUT" && report ok ||
  report bad "the reclaim must leave the store marked as owed"
! lock_exists "$REG.guard" && report ok ||
  report bad "the reclaimed guard must be released"
# ... and the next invocation serves the marker and settles the entry.
mv -f "$WS/bin/bd.real" "$WS/bin/bd"
fire 'bd list'
[ "$(grep -c "push $OUT" "$BD_LOG.dirs")" -eq 2 ] && report ok ||
  report bad "the marked store must be pushed again (dirs: $(tr '\n' ',' <"$BD_LOG.dirs"))"
! registered "$OUT" && report ok ||
  report bad "a push covering the request must settle the entry (reg: $(reg_dump))"
rm -rf "$OUT"
teardown

# --- ... even when the reclaim cannot raise the marker ------------------
# The reclaim above stands in for the dead recorder by writing the marker it
# did not. When that write fails too -- a full disk -- the settle that follows
# it in the same invocation found no marker and dropped the entry, for a write
# that landed after its commit: the store was then named by nothing, and the
# only sign was a warning nothing had emitted. The reclaim must remember what
# it could not mark, the settle must keep that entry, and the hook must say so.
#
# The failure is staged as a dangling symlink where the marker goes: the write
# fails where the link points, and the marker tests as absent, which is what a
# full disk leaves. Planted from the stub at the same moment as the dead guard,
# after the pass has claimed the marker and before the settle.
setup
OUT=$(mktemp -d)
mkdir -p "$OUT/.beads"
REG="$WS/.beads/.augment-sync.external"
reg_write "$REG" "$OUT"
(exit 0) &
DEAD=$!
wait "$DEAD" 2>/dev/null
mv -f "$WS/bin/bd" "$WS/bin/bd.real"
cat >"$WS/bin/bd" <<STUB
#!/usr/bin/env bash
if [ "\${1:-}" = -C ] && [ "\${2:-}" = "$OUT" ] && grep -q push <<<"\$*"; then
  ln -sf "$DEAD" "$REG.guard"
  ln -sf "$OUT/.beads/no-such-dir/pending" "$OUT/.beads/.augment-sync.pending"
fi
exec "$WS/bin/bd.real" "\$@"
STUB
chmod +x "$WS/bin/bd"
event 'bd list' | "$BASH_UNDER_TEST" "$HOOK" >"$WS/out" 2>/dev/null
! pending "$OUT" && report ok ||
  report bad "precondition: the staged marker must test as absent"
registered "$OUT" && report ok ||
  report bad "a settle whose reclaim could not raise the marker must keep the entry (reg: $(reg_dump))"
grep -qF "could not mark the external bead store $OUT as owed a sync" "$WS/out" && report ok ||
  report bad "a marker the reclaim could not raise must be warned about (out: $(tr '\n' ',' <"$WS/out"))"
! lock_exists "$REG.guard" && report ok ||
  report bad "the reclaimed guard must be released"
# ... and once the marker can be written again, the next invocation pushes the
# entry and settles it.
rm -f "$OUT/.beads/.augment-sync.pending"
mv -f "$WS/bin/bd.real" "$WS/bin/bd"
fire 'bd list'
[ "$(grep -c "push $OUT" "$BD_LOG.dirs")" -eq 2 ] && report ok ||
  report bad "the kept entry must be pushed again (dirs: $(tr '\n' ',' <"$BD_LOG.dirs"))"
! registered "$OUT" && report ok ||
  report bad "a push covering the kept entry must settle it (reg: $(reg_dump))"
rm -rf "$OUT"
teardown

# --- a target is resolved as of the bd that names it -------------------
# Variables are read from the command text, and the text also holds
# assignments that run after the `bd`. Taking the last one in the whole
# command resolves the write to a store it never touched: the store that
# did change is neither synced nor recorded, so nothing can rediscover it.
setup
ONE=$(mktemp -d)
TWO=$(mktemp -d)
mkdir -p "$ONE/.beads" "$TWO/.beads"
fire "OUT=$ONE; bd -C \"\$OUT\" close CHR-1; OUT=$TWO"
grep -qF "push $ONE" "$BD_LOG.dirs" && report ok ||
  report bad "the store the write reached must be synced (dirs: $(tr '\n' ',' <"$BD_LOG.dirs"))"
! grep -qF "push $TWO" "$BD_LOG.dirs" && report ok ||
  report bad "a later assignment must not redirect the target (dirs: $(tr '\n' ',' <"$BD_LOG.dirs"))"
rm -rf "$ONE" "$TWO"
teardown

# --- the last assignment before the bd still wins ----------------------
# The paired direction: narrowing to the prefix must not narrow to the
# first assignment. Reassignment before the invocation is ordinary, and the
# value in effect there is the later one.
setup
ONE=$(mktemp -d)
TWO=$(mktemp -d)
mkdir -p "$ONE/.beads" "$TWO/.beads"
fire "OUT=$ONE; OUT=$TWO; bd -C \"\$OUT\" close CHR-1"
grep -qF "push $TWO" "$BD_LOG.dirs" && report ok ||
  report bad "the last assignment before the bd must win (dirs: $(tr '\n' ',' <"$BD_LOG.dirs"))"
rm -rf "$ONE" "$TWO"
teardown

# --- each bd segment resolves against its own state --------------------
# One command can write two stores through the same variable name. Both
# are real writes, so both must be synced.
setup
ONE=$(mktemp -d)
TWO=$(mktemp -d)
mkdir -p "$ONE/.beads" "$TWO/.beads"
fire "OUT=$ONE; bd -C \"\$OUT\" close CHR-1; OUT=$TWO; bd -C \"\$OUT\" close CHR-2"
grep -qF "push $ONE" "$BD_LOG.dirs" && grep -qF "push $TWO" "$BD_LOG.dirs" &&
  report ok ||
  report bad "each segment must resolve its own target (dirs: $(tr '\n' ',' <"$BD_LOG.dirs"))"
rm -rf "$ONE" "$TWO"
teardown

# --- a relative target resolves against the launch cwd -----------------
# The hook runs wherever the agent happens to be, which is not where the
# command ran. Resolved against the hook's own directory a relative target
# names a path that does not exist, `add_root` drops it, and the write is
# stranded outside every root.
setup
BASE=$(mktemp -d)
mkdir -p "$BASE/store/.beads"
fire_in "$BASE" 'bd -C store close CHR-1'
grep -qF "push $BASE/store" "$BD_LOG.dirs" && report ok ||
  report bad "a relative -C must resolve against the launch cwd (dirs: $(tr '\n' ',' <"$BD_LOG.dirs"))"
rm -rf "$BASE"
teardown

# --- a cd before the bd moves the base ---------------------------------
setup
BASE=$(mktemp -d)
mkdir -p "$BASE/sub/store/.beads"
fire_in "$BASE" 'cd sub && bd -C store close CHR-1'
grep -qF "push $BASE/sub/store" "$BD_LOG.dirs" && report ok ||
  report bad "a cd must move the base a relative -C resolves against (dirs: $(tr '\n' ',' <"$BD_LOG.dirs"))"
rm -rf "$BASE"
teardown

# --- an absolute cd replaces the base ----------------------------------
setup
BASE=$(mktemp -d)
ELSE=$(mktemp -d)
mkdir -p "$BASE/store/.beads" "$ELSE/store/.beads"
fire_in "$ELSE" "cd $BASE && bd -C store close CHR-1"
grep -qF "push $BASE/store" "$BD_LOG.dirs" && report ok ||
  report bad "an absolute cd must replace the base (dirs: $(tr '\n' ',' <"$BD_LOG.dirs"))"
! grep -qF "push $ELSE/store" "$BD_LOG.dirs" && report ok ||
  report bad "the launch cwd must not survive an absolute cd (dirs: $(tr '\n' ',' <"$BD_LOG.dirs"))"
rm -rf "$BASE" "$ELSE"
teardown

# --- a cd after the bd does not move the base --------------------------
# Same reasoning as the assignment case: only the prefix has run.
setup
BASE=$(mktemp -d)
mkdir -p "$BASE/store/.beads" "$BASE/sub/store/.beads"
fire_in "$BASE" 'bd -C store close CHR-1; cd sub'
grep -qF "push $BASE/store" "$BD_LOG.dirs" && report ok ||
  report bad "a later cd must not move the base (dirs: $(tr '\n' ',' <"$BD_LOG.dirs"))"
rm -rf "$BASE"
teardown

# --- an absolute target ignores the cwd entirely -----------------------
setup
BASE=$(mktemp -d)
OUT=$(mktemp -d)
mkdir -p "$OUT/.beads"
fire_in "$BASE" "cd /tmp && bd -C $OUT close CHR-1"
grep -qF "push $OUT" "$BD_LOG.dirs" && report ok ||
  report bad "an absolute -C must ignore the cwd (dirs: $(tr '\n' ',' <"$BD_LOG.dirs"))"
rm -rf "$BASE" "$OUT"
teardown

# --- a failed external sync leaves both records ------------------------
# The entry carries the retry across invocations, and the marker carries it
# across passes within one. Neither substitutes for the other: an entry
# alone would be re-synced but with no request to serve, and a marker alone
# sits under a store no later event names.
setup
OUT=$(mktemp -d)
mkdir -p "$OUT/.beads"
REG="$WS/.beads/.augment-sync.external"
export BD_PUSH_FAIL=1
fire "bd -C $OUT close CHR-1"
unset BD_PUSH_FAIL
registered "$OUT" && report ok ||
  report bad "a failed external sync must stay registered"
pending "$OUT" && report ok ||
  report bad "a failed external sync must leave its request marked"
rm -rf "$OUT"
teardown

# --- entry and marker are written by the one call -----------------------
# Two files on two paths cannot be written atomically, so whichever is
# written first there is a window where the other is missing. Writing the
# marker from the caller left the worse of the two windows open: killed
# between the calls, the only record was a file outside every root that no
# entry named, and no later invocation could find it.
#
# Both writes belong to `remember_external`, under the guard, so the window
# that remains leaves the entry -- which alone means work is owed. Asserted
# where it lives, the interleaving being microseconds wide and unreachable
# from outside the process. Driven directly, the guard machinery coming
# with it.
setup
OUT=$(mktemp -d)
mkdir -p "$OUT/.beads"
REG="$WS/.beads/.augment-sync.external"
{
  sed -n '/^take_lock()/,/^drop_lock()/p;/^take_guard()/,/^}/p' "$HOOK"
  sed -n '/^take_guard_waiting()/,/^}/p;/^remember_external()/,/^}/p' "$HOOK"
  sed -n '/^registry_has()/,/^}/p' "$HOOK"
} >"$WS/reg.sh"
[ -s "$WS/reg.sh" ] && report ok ||
  report bad "remember_external must be extractable"
bash -c "REGISTRY='$REG'; REGISTRY_GUARD='$REG.guard'; WS_ROOTS=('$WS'); WARNINGS=()
  . '$WS/reg.sh'
  remember_external '$OUT'"
registered "$OUT" && report ok ||
  report bad "the target must be registered"
# The marker comes with the entry, and neither is left to the caller.
pending "$OUT" && report ok ||
  report bad "recording must raise the marker beside the entry"
# The guard is not left held, or every later rewrite of the registry would
# refuse.
[ ! -L "$REG.guard" ] && report ok ||
  report bad "the registry guard must be released"
rm -rf "$OUT"
teardown

# --- the dedupe reads only the registry the guard covers -----------------
# `remember_external` holds one registry's guard, so a lookup that searched
# every root's read files no invocation had locked. A concurrent sync settling
# that entry between the read and the marker leaves this one recording nothing
# -- and an external store is named by nothing else, so a failure here strands
# the write with no invocation able to find it again. A duplicate is the safe
# error of the two: `forget_external` and the prune rewrite every registry, so
# a copy in another root goes out with the one that was written.
#
# The race itself is microseconds wide and not reachable from outside the
# process, so what is asserted is the property that removes it: an entry
# present only in a registry this call does not hold does not suppress the
# write into the one it does.
setup
OUT=$(mktemp -d)
OTHER=$(mktemp -d)
mkdir -p "$OUT/.beads" "$OTHER/.beads"
REG="$WS/.beads/.augment-sync.external"
{
  sed -n '/^take_lock()/,/^drop_lock()/p;/^take_guard()/,/^}/p' "$HOOK"
  sed -n '/^take_guard_waiting()/,/^}/p;/^remember_external()/,/^}/p' "$HOOK"
  sed -n '/^registry_has()/,/^}/p' "$HOOK"
} >"$WS/reg.sh"
reg_write "$OTHER/.beads/.augment-sync.external" "$OUT"
bash -c "REGISTRY='$REG'; REGISTRY_GUARD='$REG.guard'
  REGISTRIES=('$REG' '$OTHER/.beads/.augment-sync.external')
  WS_ROOTS=('$WS'); WARNINGS=()
  . '$WS/reg.sh'
  remember_external '$OUT'"
registered "$OUT" && report ok ||
  report bad "an entry held by another root must not suppress the guarded write ($(reg_dump))"
# And the one already there is untouched, this call holding no guard over it.
registered "$OUT" "$OTHER/.beads/.augment-sync.external" && report ok ||
  report bad "the other root's registry must be left alone"
# A repeat within the guarded registry still collapses: the dedupe narrowed to
# one file, it did not go away.
bash -c "REGISTRY='$REG'; REGISTRY_GUARD='$REG.guard'
  REGISTRIES=('$REG')
  WS_ROOTS=('$WS'); WARNINGS=()
  . '$WS/reg.sh'
  remember_external '$OUT'"
[ "$(tr -cd '\0' <"$REG" | wc -c | tr -d ' ')" = 1 ] && report ok ||
  report bad "the guarded registry must not gain a second copy ($(reg_dump))"
rm -rf "$OUT" "$OTHER"
teardown

# --- an entry is appended by replacement --------------------------------
# The readers want whole NUL-terminated records. A `printf` onto the end of
# the file that stops part-way -- a full filesystem, a signal -- leaves one
# with no terminator, and the next append runs its path onto the end of that
# one: the reader takes the two as a single entry naming neither store, so
# both are lost for good. Written whole and renamed over, as `filter_registry`
# already is, a failure leaves the list that was there.
#
# Replacement is observable as the file being a different one afterwards,
# which appending in place would not be. The partial write itself cannot be
# staged from outside the process.
setup
OUT=$(mktemp -d)
OTHER=$(mktemp -d)
mkdir -p "$OUT/.beads" "$OTHER/.beads"
REG="$WS/.beads/.augment-sync.external"
{
  sed -n '/^take_lock()/,/^drop_lock()/p;/^take_guard()/,/^}/p' "$HOOK"
  sed -n '/^take_guard_waiting()/,/^}/p;/^remember_external()/,/^}/p' "$HOOK"
  sed -n '/^registry_has()/,/^}/p' "$HOOK"
} >"$WS/reg.sh"
reg_write "$REG" "$OTHER"
BEFORE=$(ls -i "$REG" | awk '{print $1}')
bash -c "REGISTRY='$REG'; REGISTRY_GUARD='$REG.guard'; WS_ROOTS=('$WS'); WARNINGS=()
  . '$WS/reg.sh'
  remember_external '$OUT'"
[ "$(ls -i "$REG" | awk '{print $1}')" != "$BEFORE" ] && report ok ||
  report bad "an entry must be appended by replacement, not in place"
# The entry that was there is still there, replacement being of the whole
# list and not of one record.
registered "$OTHER" && report ok ||
  report bad "replacement must carry the entries already recorded ($(reg_dump))"
registered "$OUT" && report ok ||
  report bad "the new entry must be recorded ($(reg_dump))"
# The half-built list is not left beside the real one, where a later reader
# globbing the directory for markers would find it.
[ -z "$(find "$WS/.beads" -name '.augment-sync.external.[0-9]*' 2>/dev/null)" ] &&
  report ok || report bad "no partial registry may be left behind"
rm -rf "$OUT" "$OTHER"
teardown

# --- an entry survives until a push settles it -------------------------
# The entry's one exit path. A sync killed outright runs no failure branch,
# so anything that clears the entry before the push has returned can lose
# the only record that a store outside every root was owed a sync.
setup
OUT=$(mktemp -d)
mkdir -p "$OUT/.beads"
REG="$WS/.beads/.augment-sync.external"
export BD_PUSH_FAIL=1
fire "bd -C $OUT close CHR-1"
unset BD_PUSH_FAIL
registered "$OUT" && report ok ||
  report bad "a failed push must leave the entry in place"
# A later command naming nothing external is enough, the entry itself being
# the reason to sync.
: >"$BD_LOG.dirs"
fire 'bd list'
grep -q "push $OUT" "$BD_LOG.dirs" && report ok ||
  report bad "a registered store must be retried (dirs: $(tr '\n' ',' <"$BD_LOG.dirs"))"
[ ! -s "$REG" ] && report ok ||
  report bad "a push that returned 0 must settle the entry ($(reg_dump))"
rm -rf "$OUT"
teardown

# --- a store that can never settle is dropped --------------------------
# A successful push is what removes an entry, so a store that has been
# deleted has no way to settle and would be committed by every invocation
# from here on. Nothing is owed to a store that no longer exists.
setup
OUT=$(mktemp -d)
mkdir -p "$OUT/.beads"
REG="$WS/.beads/.augment-sync.external"
export BD_PUSH_FAIL=1
fire "bd -C $OUT close CHR-1"
unset BD_PUSH_FAIL
registered "$OUT" && report ok ||
  report bad "precondition: the failed sync stays registered"
rm -rf "$OUT"
: >"$BD_LOG.dirs"
fire 'bd list'
[ ! -s "$REG" ] && report ok ||
  report bad "a vanished store must be dropped ($(reg_dump))"
! grep -q "push $OUT" "$BD_LOG.dirs" && report ok ||
  report bad "a vanished store must not be synced (dirs: $(tr '\n' ',' <"$BD_LOG.dirs"))"
teardown

# --- a path holding a newline is one entry, not two --------------------
# The scanner delimits its output with NULs precisely because a path may
# hold a newline. A line-delimited registry undoes that: the store is
# recorded as two entries, neither of which names it, so the retry and the
# SessionEnd backstop both look for stores that do not exist while the one
# that was written is named by nothing.
setup
BASE=$(mktemp -d)
OUT="$BASE/a
b"
mkdir -p "$OUT/.beads"
REG="$WS/.beads/.augment-sync.external"
export BD_PUSH_FAIL=1
fire "bd -C '$OUT' close CHR-1"
unset BD_PUSH_FAIL
registered "$OUT" && report ok ||
  report bad "a newline in the path must be recorded whole ($(reg_dump))"
# One record, so the halves are not entries of their own.
! registered "$BASE/a" && report ok ||
  report bad "the first line of the path must not be an entry of its own"
! registered "b" && report ok ||
  report bad "the second line of the path must not be an entry of its own"
# And the entry it wrote is the one a later invocation retries.
: >"$BD_LOG.dirs"
fire 'bd list'
grep -qF "push $OUT" "$BD_LOG.dirs" && report ok ||
  report bad "a store whose path holds a newline must be retried (dirs: $(tr '\n' ',' <"$BD_LOG.dirs"))"
rm -rf "$BASE"
teardown

# --- a bounded loop must not settle a request it did not serve ---------
# A push returning 0 is necessary but not sufficient. The sync loop is
# capped at three passes, so it can return successfully with a request still
# outstanding -- and removing the entry then settles work no push covered.
# For a store outside every workspace root the marker left behind is
# unreachable: nothing else names that path, so neither the retry nor the
# backstop can find it again. Driven by planting the marker the loop cannot
# consume, which is what a concurrent invocation would have raised.
setup
OUT=$(mktemp -d)
mkdir -p "$OUT/.beads"
REG="$WS/.beads/.augment-sync.external"
export BD_PUSH_FAIL=1
fire "bd -C $OUT close CHR-1"
unset BD_PUSH_FAIL
registered "$OUT" && report ok ||
  report bad "precondition: the failed sync is registered"
# A request that outlives the loop: re-raised after each pass consumes it,
# so the third pass still leaves one outstanding.
cat >"$WS/bin/bd" <<'STUB'
#!/usr/bin/env bash
LOG="${BD_LOG:?}"
[ "${1:-}" = -C ] && TARGET="${2:-}" || TARGET=""
[ "${1:-}" = -C ] && shift 2
printf '%s\n' "$1" >>"$LOG"
if [ "${1:-}" = dolt ]; then
  printf '%s %s\n' "$2" "$TARGET" >>"$LOG.dirs"
  # Stand in for a write arriving while this push runs.
  [ -n "$TARGET" ] && : >"$TARGET/.beads/.augment-sync.pending"
fi
exit 0
STUB
chmod +x "$WS/bin/bd"
: >"$BD_LOG.dirs"
fire 'bd list'
registered "$OUT" && report ok ||
  report bad "an entry must survive a push that left a request outstanding ($(reg_dump))"
rm -rf "$OUT"
teardown

# --- SessionEnd syncs unconditionally ----------------------------------
# The backstop exists for writes PostToolUse never saw -- a `bd` call the
# classifier missed, or one made outside a tool call. It must not consult
# the command at all, so it syncs with no marker and no command.
setup
fire_end
[ "$(count commit)" -eq 1 ] && [ "$(count push)" -eq 1 ] && report ok ||
  report bad "SessionEnd must sync with no prior request (log: $(tr '\n' ',' <"$BD_LOG"))"
teardown

# --- SessionEnd clears an outstanding marker ---------------------------
# The case the backstop is named for: a push failed mid-session, and the
# session is ending with the write still only local.
setup
export BD_PUSH_FAIL=1
fire 'bd close CHR-1'
pending && report ok || report bad "precondition: failed push leaves marker"
unset BD_PUSH_FAIL
fire_end
! pending && ! inflight && report ok ||
  report bad "SessionEnd must clear the outstanding marker"
teardown

# --- SessionEnd covers every root --------------------------------------
setup
ALT=$(mktemp -d)
mkdir -p "$ALT/.beads"
fire_end "$ALT"
grep -q "push $WS" "$BD_LOG.dirs" && grep -q "push $ALT" "$BD_LOG.dirs" &&
  report ok || report bad "SessionEnd must sync every root (dirs: $(tr '\n' ',' <"$BD_LOG.dirs"))"
rm -rf "$ALT"
teardown

# --- a SessionEnd failure warns on stderr, not stdout ------------------
# SessionEnd stdout is debug-only, so a warning emitted there is lost. It
# must also not emit the PostToolUse JSON envelope, which has no meaning
# for this event.
setup
export BD_PUSH_FAIL=1
fire_end
grep -q "NOT on DoltHub" "$WS/err" && report ok ||
  report bad "SessionEnd push failure must warn on stderr (err: $(tr '\n' ',' <"$WS/err"))"
! grep -q hookSpecificOutput "$WS/err" && report ok ||
  report bad "SessionEnd must not emit the PostToolUse envelope"
teardown

# --- a workspace root holding a newline is one root, not two -----------
# The event's roots are decoded the same way the scanner and the registry are
# delimited, and for the same reason. By line such a root arrives as two paths
# that name nothing, neither has a `.beads`, and the real workspace store is
# left out of the push set entirely -- SessionEnd builds its list the same way,
# so nothing later recovers it.
setup
NLWS=$(mktemp -d)
NLROOT="$NLWS/a
b"
mkdir -p "$NLROOT/.beads"
# The event is built here rather than through `event`, since the root under
# test is the newline one rather than the scratch workspace.
jq -n --arg e PostToolUse --arg w "$NLROOT" --arg c 'bd close CHR-1' \
  '{hook_event_name:$e, workspace_roots:[$w], tool_name:"launch-process", tool_input:{command:$c}}' |
  "$BASH_UNDER_TEST" "$HOOK" >/dev/null 2>&1
grep -qF "push $NLROOT" "$BD_LOG.dirs" && report ok ||
  report bad "a workspace root holding a newline must be synced (dirs: $(tr '\n' ',' <"$BD_LOG.dirs"))"
# One root, so one push. Read as two, the halves name nothing and are dropped
# for having no `.beads`, which shows up as no push at all rather than as an
# extra one -- so the count is what distinguishes the two readings.
[ "$(count push)" -eq 1 ] && report ok ||
  report bad "a root holding a newline must be one root (pushes: $(count push))"
rm -rf "$NLWS"
teardown

# --- a scanner that fails is not a command that writes nothing ----------
# `scan_command` left SCAN_MUTATES at its initial 0 when the scanner died
# before emitting anything, which reads exactly like "no write here": the sync
# was skipped silently and every write the command made stayed local. A
# failure must sync the roots and say so instead. Driven by putting a `shfmt`
# on PATH that cannot run, which is the shape a broken install takes.
setup
cat >"$WS/bin/shfmt" <<'BROKEN'
#!/usr/bin/env bash
echo "shfmt: cannot run" >&2
exit 127
BROKEN
chmod +x "$WS/bin/shfmt"
# A command that writes nothing at all, so a sync can only come from the
# failure being noticed rather than from the command being read.
fire 'ls -la'
[ "$(count push)" -ge 1 ] && report ok ||
  report bad "a failed scan must sync the roots (pushes: $(count push))"
# And it must be reported, since a store outside the roots cannot be recovered
# this way -- nothing else names that path.
OUTPUT=$(event 'ls -la' | "$BASH_UNDER_TEST" "$HOOK" 2>/dev/null)
grep -q "could not scan" <<<"$OUTPUT" && report ok ||
  report bad "a failed scan must warn"
# Naming every route to such a store, not `-C` alone. The scan is what reads
# `BEADS_DIR` and what works out where the command ran, so all three go down
# together -- and this warning is the only guidance the reader gets.
grep -q "BEADS_DIR" <<<"$OUTPUT" && report ok ||
  report bad "a failed scan must name BEADS_DIR as a route to a missed store"
grep -q "walking up" <<<"$OUTPUT" && report ok ||
  report bad "a failed scan must name the walk up as a route to a missed store"
rm -f "$WS/bin/shfmt"
teardown

# A scanner that answers completely is not affected by any of that: the
# read-only command still skips, so the fail-safe is not a blanket sync.
setup
fire 'ls -la'
[ "$(count push)" -eq 0 ] && report ok ||
  report bad "a working scan must still skip a command that writes nothing"
teardown

# --- the backstop does not need the scanner -------------------------------
# A PATH carrying every tool the hook uses except those named in $@. Built by
# symlink from the real PATH rather than by pruning directories, since which
# directory holds which tool varies between this machine and CI -- and pruning
# the one holding `shfmt` takes `jq` with it where they share a prefix.
without_tools() {
  local omit=" $* " tool dir="$WS/onlybin"
  rm -rf "$dir"
  mkdir -p "$dir"
  for tool in jq shfmt python3 awk bash cat cp dirname env find grep head \
    kill ln mktemp mv ps readlink rm sed sleep tr; do
    case "$omit" in *" $tool "*) continue ;; esac
    ln -sf "$(command -v "$tool")" "$dir/$tool" 2>/dev/null
  done
  ln -sf "$WS/bin/bd" "$dir/bd"
  PATH="$dir"
}

# SessionEnd syncs the roots unconditionally and asks the scanner nothing, so a
# missing `shfmt` or `python3` is no reason for it to stand down. It was: the
# tool check ran before the event was read and covered all three, which
# disabled the flush precisely when it was the only thing that could still
# reach a write -- one this hook could no longer detect on the events that do
# scan. Distinct from the case above, where `shfmt` is present and broken.
setup
without_tools shfmt python3
command -v shfmt >/dev/null 2>&1 &&
  report bad "shfmt must be off PATH for this case" || report ok
fire_end
[ "$(count push)" -ge 1 ] && report ok ||
  report bad "SessionEnd must sync without the scanner (pushes: $(count push))"
[ "$(count commit)" -ge 1 ] && report ok ||
  report bad "SessionEnd must commit without the scanner"
PATH="$WS/bin:$ORIG_PATH"
teardown

# The same install still cannot scan, so PostToolUse says so and syncs the
# roots -- the `SCAN_FAILED` path, reached here by the tools being absent
# rather than broken.
setup
without_tools shfmt python3
fire 'ls -la'
[ "$(count push)" -ge 1 ] && report ok ||
  report bad "a scan that cannot run must sync the roots (pushes: $(count push))"
PATH="$WS/bin:$ORIG_PATH"
teardown

# `jq` is the one tool still required, since without it there is no event to
# act on: not its name, and not the roots to sync. It must say so rather than
# exit silently, a pending write being undetectable either way. The event is
# built before the PATH is narrowed, `event_as` needing the `jq` the hook is
# about to be denied.
setup
event_as SessionEnd "" >"$WS/ev"
without_tools jq
"$BASH_UNDER_TEST" "$HOOK" <"$WS/ev" >/dev/null 2>"$WS/err"
PATH="$WS/bin:$ORIG_PATH"
grep -q 'jq not found' "$WS/err" && report ok ||
  report bad "a missing jq must be reported ($(head -1 "$WS/err"))"
[ "$(count push)" -eq 0 ] && report ok ||
  report bad "a missing jq must stand down, having no event to read"
teardown

# --- a warning outlives the work that was still running -----------------
# Everything worth warning about is known before the syncing starts, and the
# syncing is what gets killed: the hook is stopped at 60s, the lock wait may
# spend 30 of them and each `bd` beyond that is unbounded. Emitted only after
# the last root, the scan warnings went down with the invocation -- and for a
# store that could not be named, that warning is not a report of the failure
# but the whole of the recovery path, nothing else naming the path.
#
# Staged as the two together: a command whose store cannot be resolved, so
# there is a warning that matters, and a push slow enough that the kill lands
# inside it.
setup
export BD_PUSH_SLEEP=20
event 'bd -C "$ONLY_THE_COMMAND_KNEW" close CHR-1' | "$BASH_UNDER_TEST" "$HOOK" >"$WS/out" 2>&1 &
HOOK_PID=$!
sleep 3
kill -TERM "$HOOK_PID" 2>/dev/null
wait "$HOOK_PID" 2>/dev/null
grep -q "could not be resolved" "$WS/out" && report ok ||
  report bad "a warning must reach the agent though the sync was killed (out: $(tr '\n' ',' <"$WS/out"))"
# One object still, not one per emit point: a PostToolUse hook is read as a
# single JSON object, so a second would not be honoured -- and the flush runs
# both from the normal end and from the trap.
[ "$(grep -c hookSpecificOutput "$WS/out")" -le 1 ] && report ok ||
  report bad "the warning must be emitted once (out: $(tr '\n' ',' <"$WS/out"))"
pkill -9 -f "$WS/bin/bd" 2>/dev/null
unset BD_PUSH_SLEEP
teardown

# The normal path still emits exactly once, the trap firing after the call
# rather than instead of it.
setup
event 'bd -C "$ONLY_THE_COMMAND_KNEW" close CHR-1' | "$BASH_UNDER_TEST" "$HOOK" >"$WS/out" 2>&1
[ "$(grep -c hookSpecificOutput "$WS/out")" = 1 ] && report ok ||
  report bad "an uninterrupted run must warn exactly once (out: $(tr '\n' ',' <"$WS/out"))"
teardown

# A run with nothing to say writes nothing, the flush being a no-op on an
# empty list however many times it runs.
setup
FIRE_CWD="$WS" event 'bd close CHR-1' | "$BASH_UNDER_TEST" "$HOOK" >"$WS/out" 2>&1
[ ! -s "$WS/out" ] && report ok ||
  report bad "a run with no warnings must write nothing (out: $(tr '\n' ',' <"$WS/out"))"
teardown

# --- an orphaned push keeps the lock unreclaimable ----------------------
# A dead hook pid does not mean its work stopped. `bd dolt push` is a separate
# process, and the 60s kill leaves it running against the remote with no trap to
# stop it. Reclaiming the lock on the strength of the owner alone then starts a
# second push against the same remote -- the one thing the lock exists to
# prevent. The earlier kill case hid this by killing the child itself first,
# which the real timeout does not do, so this one deliberately does not.
#
# The orphan is given a long sleep and killed early in it, so the second
# invocation meets a push that is certainly still running. Without that margin
# the orphan can finish on its own before the retry looks, and the case passes
# whatever the hook does -- which is the failure mode of a timing test, not a
# property of the fix.
setup
export BD_PUSH_SLEEP=20
fire_bg 'bd close CHR-1'
sleep 3
kill -9 "$HOOK_PID" 2>/dev/null
wait "$HOOK_PID" 2>/dev/null
pgrep -f "$WS/bin/bd" >/dev/null && report ok ||
  report bad "the push child must outlive the killed hook for this case to test anything"
# Nothing was seen to finish, so the request stands -- checked before the retry,
# which is entitled to clear it.
{ pending || inflight; } && report ok ||
  report bad "a sync behind an orphaned push must stay outstanding"
# The next invocation must not push alongside it. Its wait is bounded, so this
# returns either way; what matters is that no two pushes were ever in flight.
unset BD_PUSH_SLEEP
fire 'bd close CHR-1'
OVERLAP=$(awk '/push-begin/{n++; if(n>m) m=n} /push-end/{n--} END{print (m>1)?"yes":"no"}' \
  "$BD_LOG.span" 2>/dev/null)
[ "$OVERLAP" = no ] && report ok ||
  report bad "an orphaned push must not run alongside a second (span: $(tr '\n' ',' <"$BD_LOG.span"))"
pkill -f "$WS/bin/bd" 2>/dev/null
teardown

# ... and once that push is gone the lock is reclaimable again, so an orphan
# cannot wedge the store for the rest of the session.
setup
export BD_PUSH_SLEEP=6
fire_bg 'bd close CHR-1'
sleep 3
kill -9 "$HOOK_PID" 2>/dev/null
wait "$HOOK_PID" 2>/dev/null
pkill -f "$WS/bin/bd" 2>/dev/null
sleep 1
unset BD_PUSH_SLEEP
fire 'bd close CHR-1'
[ "$(count push)" -ge 2 ] && report ok ||
  report bad "a lock left by a finished orphan must be reclaimable (pushes: $(count push))"
teardown

# --- a terminated hook does not free the lock over its push --------------
# The `kill -9` above runs no trap. SIGTERM does, and the EXIT trap ran the
# same release on every root -- while the push child, being in a process group
# of its own, does not take the signal and keeps talking to the remote. The
# freed lock is then taken outright by the next invocation, which asks nothing
# about the child because it never reclaims anything, so two pushes run against
# the one remote. Held instead, the lock is reclaimed, and reclamation does ask.
setup
export BD_PUSH_SLEEP=20
fire_bg 'bd close CHR-1'
sleep 3
kill -TERM "$HOOK_PID" 2>/dev/null
wait "$HOOK_PID" 2>/dev/null
pgrep -f "$WS/bin/bd" >/dev/null && report ok ||
  report bad "the push child must survive the SIGTERM for this case to test anything"
lock_exists "$WS/.beads/.augment-sync.lock" && report ok ||
  report bad "a terminated hook must keep the lock while its push runs"
unset BD_PUSH_SLEEP
fire 'bd close CHR-1'
OVERLAP=$(awk '/push-begin/{n++; if(n>m) m=n} /push-end/{n--} END{print (m>1)?"yes":"no"}' \
  "$BD_LOG.span" 2>/dev/null)
[ "$OVERLAP" = no ] && report ok ||
  report bad "a push behind a terminated hook must not run alongside a second (span: $(tr '\n' ',' <"$BD_LOG.span"))"
pkill -f "$WS/bin/bd" 2>/dev/null
teardown

# ... and the trap still frees a lock with no push behind it, or the store
# would be wedged until the next invocation troubled to reclaim it.
setup
fire 'bd close CHR-1'
! lock_exists "$WS/.beads/.augment-sync.lock" && report ok ||
  report bad "a normal exit must still release the lock"
teardown

# --- an unpublished child record stops the push -------------------------
# The record is what makes the push visible to a later invocation, so a push
# that starts without one is the orphan the record exists to prevent: killed,
# its lock reads reclaimable while it still runs. `ln -s` answers success for
# a link it makes *inside* the record's path when that path is a directory --
# which `rm -f` will not clear -- so success is not proof the record is there.
# Read back instead, and the child is stood down by leaving its gate shut.
setup
mkdir -p "$WS/.beads/.augment-sync.child"
fire 'bd close CHR-1'
[ "$(count push)" -eq 0 ] && report ok ||
  report bad "no push may start without its record published (pushes=$(count push))"
[ "$(count commit)" -eq 0 ] && report ok ||
  report bad "no commit may start without its record published"
# Reported as a failed run, so the request stands and the next invocation
# retries -- rather than being settled by a sync that never happened.
{ pending || inflight; } && report ok ||
  report bad "a refused run must leave the request outstanding"
# The gate is not left in place for every refused run to accumulate one.
# Looked for in this run's own temp directory, which the hook inherits, so a
# concurrent run's gate is neither read as this one's nor able to hide a leak.
[ -z "$(find "$SUITE_TMP" -maxdepth 1 -name 'cs-gate.*' -newer "$BD_LOG" 2>/dev/null)" ] &&
  report ok || report bad "a refused run must not leave its gate behind"
rmdir "$WS/.beads/.augment-sync.child"
# Cleared, the same command syncs, so the refusal was the record and not the
# command.
: >"$BD_LOG"
fire 'bd close CHR-1'
[ "$(count push)" -ge 1 ] && report ok ||
  report bad "a published record must let the push run (pushes=$(count push))"
teardown

# --- a recorded external target always has a marker beside it -----------
# An entry is settled by a sync that finds neither marker standing, so an entry
# without one reads as work already done: another invocation removes it, and if
# this one is then killed the only record of an external store is gone, with
# nothing else naming its path. `remember_external` writes the entry first even
# so, as the case above describes, because the other window is worse -- a marker
# with no entry is a file outside every root that nothing names -- and it closes
# this one by writing both under the registry guard, which a `forget_external`
# racing it also takes. This asserts the state that discipline maintains: a
# store that is registered is a store that looks owed.
#
# The ordering itself is not what is asserted here, and it cannot be: the two
# writes are consecutive filesystem calls with no invocation of anything between
# them, so no stub can observe the window from outside. What is checked is the
# invariant the guard is meant to produce.
setup
REG="$WS/.beads/.augment-sync.external"
OUT=$(mktemp -d)
mkdir -p "$OUT/.beads"
export BD_PUSH_SLEEP=8
fire_bg "bd -C $OUT close CHR-1"
sleep 3
registered "$OUT" && report ok ||
  report bad "an external target must be recorded (registry: $(reg_dump))"
{ [ -e "$OUT/.beads/.augment-sync.pending" ] ||
  [ -e "$OUT/.beads/.augment-sync.inflight" ]; } && report ok ||
  report bad "a registered external target must have a marker beside it"
kill -9 "$HOOK_PID" 2>/dev/null
wait "$HOOK_PID" 2>/dev/null
pkill -f "$WS/bin/bd" 2>/dev/null
unset BD_PUSH_SLEEP
rm -rf "$OUT"
teardown

# --- an unknown launch directory does not become this process's own -----
# `tool_input.cwd` is optional, and nothing requires this hook to run where the
# tool call did. Resolving `bd -C store` against the hook's own cwd names a
# store under an unrelated directory: that one is pushed and recorded while the
# one the command opened is in neither, so even SessionEnd cannot recover it.
setup
REG="$WS/.beads/.augment-sync.external"
DECOY="$WS/decoy"
mkdir -p "$DECOY/store/.beads"
# No FIRE_CWD, so the event carries no cwd, and the hook runs in $DECOY.
(cd "$DECOY" && event 'bd -C store close CHR-1' | "$BASH_UNDER_TEST" "$HOOK" >/dev/null 2>&1)
! grep -qF "push $DECOY/store" "$BD_LOG.dirs" && report ok ||
  report bad "a relative target must not resolve against the hook's cwd (dirs: $(tr '\n' ',' <"$BD_LOG.dirs"))"
! registered "$DECOY/store" && report ok ||
  report bad "an unresolved target must not be recorded (registry: $(reg_dump))"
# The write is still found, so the roots sync ...
grep -qF "push $WS" "$BD_LOG.dirs" && report ok ||
  report bad "an unresolved target must still sync the roots (dirs: $(tr '\n' ',' <"$BD_LOG.dirs"))"
# ... and the store that could not be named is reported, that warning being all
# that stands in for the sync it cannot have.
(cd "$DECOY" && event 'bd -C store close CHR-1' | "$BASH_UNDER_TEST" "$HOOK" 2>/dev/null) |
  grep -q "could not be resolved" && report ok ||
  report bad "an unresolved target must warn"
teardown

# The same counter stands for two stores that carry no `-C` at all, so a
# warning naming that flag sends recovery to a place the command never went.
# A plain `bd` selects its store by walking up from where it ran, and where the
# event does not say where that was, the walk has no start: the store cannot be
# named, exactly as an unresolvable `-C` cannot.
setup
DECOY="$WS/decoy"
mkdir -p "$DECOY/.beads"
OUTPUT=$( (cd "$DECOY" && event 'bd close CHR-1' | "$BASH_UNDER_TEST" "$HOOK" 2>/dev/null) )
grep -q "could not be resolved" <<<"$OUTPUT" && report ok ||
  report bad "a plain bd with no reported cwd must warn (out: $OUTPUT)"
! grep -q "a 'bd -C <dir>' store" <<<"$OUTPUT" && report ok ||
  report bad "the warning must not name a flag the command did not carry"
teardown

# And a `BEADS_DIR` whose value this scan cannot work out, which is the third
# route to the same counter.
setup
OUTPUT=$(event 'BEADS_DIR="$SOMETHING_ONLY_THE_COMMAND_KNEW" bd close CHR-1' |
  "$BASH_UNDER_TEST" "$HOOK" 2>/dev/null)
grep -q "could not be resolved" <<<"$OUTPUT" && report ok ||
  report bad "an unreadable BEADS_DIR must warn (out: $OUTPUT)"
grep -q "BEADS_DIR" <<<"$OUTPUT" && report ok ||
  report bad "the warning must name BEADS_DIR as a route to the store"
teardown

# A cwd the event does supply is used, so the above has not simply stopped
# relative targets from resolving at all.
setup
OUT="$WS/from"
mkdir -p "$OUT/store/.beads"
fire_in "$OUT" 'bd -C store close CHR-1'
grep -qF "push $OUT/store" "$BD_LOG.dirs" && report ok ||
  report bad "a supplied cwd must still resolve a relative target (dirs: $(tr '\n' ',' <"$BD_LOG.dirs"))"
teardown

# --- a store selected by the walk up, named by no word of the command ----
# `bd` finds its store by walking up from where it runs, so a mutating command
# with no `-C` still writes one particular store. Where that is outside every
# workspace root the hook reported nothing about it: only the roots were pushed,
# and the write sat local indefinitely -- SessionEnd builds its list the same
# way, so nothing later could recover it.
setup
REG="$WS/.beads/.augment-sync.external"
ELSE=$(mktemp -d)
mkdir -p "$ELSE/.beads" "$ELSE/sub"
fire_in "$ELSE/sub" 'bd close CHR-1'
grep -qF "push $ELSE" "$BD_LOG.dirs" && report ok ||
  report bad "a store found by the walk up must be pushed (dirs: $(tr '\n' ',' <"$BD_LOG.dirs"))"
# And recorded, an external store's path being named by nothing else, so a
# failed sync there has no other route back to it. Read after a refused push,
# a successful one settling the entry it made.
export BD_PUSH_FAIL=1
fire_in "$ELSE/sub" 'bd close CHR-1'
unset BD_PUSH_FAIL
registered "$ELSE" && report ok ||
  report bad "a store found by the walk up must be recorded (registry: $(reg_dump))"
rm -rf "$ELSE"
teardown

# The same command inside a workspace root names that root, which is already in
# the push set -- so it is synced without being recorded as external.
setup
REG="$WS/.beads/.augment-sync.external"
mkdir -p "$WS/sub"
fire_in "$WS/sub" 'bd close CHR-1'
grep -qF "push $WS" "$BD_LOG.dirs" && report ok ||
  report bad "a root's own store must still sync (dirs: $(tr '\n' ',' <"$BD_LOG.dirs"))"
! registered "$WS" && report ok ||
  report bad "a workspace root must not be recorded as external (registry: $(reg_dump))"
teardown

# A `-C` may name a subdirectory of the root holding the store, `bd` walking up
# from it as from any cwd. Reported as given, that path holds no `.beads`, so
# `add_root` dropped it and the write went unsynced and unrecorded.
setup
REG="$WS/.beads/.augment-sync.external"
ELSE=$(mktemp -d)
mkdir -p "$ELSE/.beads" "$ELSE/sub/deeper"
fire "bd -C $ELSE/sub/deeper close CHR-1"
grep -qF "push $ELSE" "$BD_LOG.dirs" && report ok ||
  report bad "a -C below the store must push the store (dirs: $(tr '\n' ',' <"$BD_LOG.dirs"))"
export BD_PUSH_FAIL=1
fire "bd -C $ELSE/sub/deeper close CHR-1"
unset BD_PUSH_FAIL
registered "$ELSE" && report ok ||
  report bad "a -C below the store must record the store (registry: $(reg_dump))"
rm -rf "$ELSE"
teardown

# A command in a directory with no store above it writes nothing, so there is
# nothing to sync and no reason to treat it as a write with an unnamed store.
setup
ELSE=$(mktemp -d)
fire_in "$ELSE" 'bd close CHR-1'
! grep -qF "push $ELSE" "$BD_LOG.dirs" && report ok ||
  report bad "a directory with no store above it must not be pushed (dirs: $(tr '\n' ',' <"$BD_LOG.dirs"))"
rm -rf "$ELSE"
teardown

# --- a wrapper's own directory is where the command runs ------------------
# `env -C` and `sudo -D` change the directory before running the command, and
# which store `bd` selects turns on that directory. Read as an opaque option
# value, the store above the launch directory was pushed and recorded while the
# one the write opened was in neither -- and being outside every root, nothing
# later could rediscover it.
setup
REG="$WS/.beads/.augment-sync.external"
ELSE=$(mktemp -d)
mkdir -p "$ELSE/.beads" "$ELSE/sub"
fire_in "$WS" "env -C $ELSE bd close CHR-1"
grep -qF "push $ELSE" "$BD_LOG.dirs" && report ok ||
  report bad "a wrapper's directory must select the store (dirs: $(tr '\n' ',' <"$BD_LOG.dirs"))"
export BD_PUSH_FAIL=1
fire_in "$WS" "env -C $ELSE bd close CHR-1"
unset BD_PUSH_FAIL
registered "$ELSE" && report ok ||
  report bad "a store the wrapper's directory selects must be recorded (registry: $(reg_dump))"
# A relative `-C` of `bd`'s own resolves there too, the wrapper having moved
# before `bd` reads it.
: >"$BD_LOG.dirs"
fire_in "$WS" "env -C $ELSE bd -C sub close CHR-1"
grep -qF "push $ELSE" "$BD_LOG.dirs" && report ok ||
  report bad "a relative -C must resolve in the wrapper's directory (dirs: $(tr '\n' ',' <"$BD_LOG.dirs"))"
rm -rf "$ELSE"
teardown

# --- every root's registry is read, not just the first --------------------
# A new entry goes to the first root, but which root is first is a property of
# the event and not of the store: a session over root B alone records there, and
# a later session over A and B has a different `[0]`. Reading only that one left
# B's entry unseen, and an external store is named by nothing else -- so the
# write there sat local indefinitely, with no invocation able to find it again.
#
# Staged as the sequence that produces it: a single-root session over B records
# the external store, then a session over A and B must still rediscover it.
setup
OTHER=$(mktemp -d)
ELSE=$(mktemp -d)
mkdir -p "$OTHER/.beads" "$ELSE/.beads"
# B alone, and a push that refuses, so the entry survives to be found.
export BD_PUSH_FAIL=1
FIRE_CWD="" event_as PostToolUse "bd -C $ELSE close CHR-1" |
  jq --arg b "$OTHER" '.workspace_roots = [$b]' | "$BASH_UNDER_TEST" "$HOOK" >/dev/null 2>&1
unset BD_PUSH_FAIL
registered "$ELSE" "$OTHER/.beads/.augment-sync.external" && report ok ||
  report bad "the single-root session must record the external store"
# Now A first, B second. The entry is in B's registry, which is not `[0]`.
: >"$BD_LOG.dirs"
fire 'ls -la' "$OTHER"
grep -qF "push $ELSE" "$BD_LOG.dirs" && report ok ||
  report bad "an entry in a later root's registry must still be synced (dirs: $(tr '\n' ',' <"$BD_LOG.dirs"))"
# And once its push succeeds it is settled where it lives, rather than left to
# be committed by every invocation from here on.
! registered "$ELSE" "$OTHER/.beads/.augment-sync.external" && report ok ||
  report bad "a settled entry must be dropped from the registry that holds it"
rm -rf "$OTHER" "$ELSE"
teardown

# The prune reaches them all the same way: a store that no longer exists can
# never settle, so an entry left in a non-first root's registry would be
# committed by every later invocation with nothing able to remove it.
setup
OTHER=$(mktemp -d)
GONE=$(mktemp -d)
mkdir -p "$OTHER/.beads"
reg_write "$OTHER/.beads/.augment-sync.external" "$GONE"
rm -rf "$GONE"
fire 'ls -la' "$OTHER"
! registered "$GONE" "$OTHER/.beads/.augment-sync.external" && report ok ||
  report bad "the prune must reach every root's registry"
rm -rf "$OTHER"
teardown

# --- a registry rewrite that cannot be finished leaves the list alone -----
# The rewrite is a replacement, so it is the list only once every retained
# record is in it. A `printf` that fails part-way -- ENOSPC, a quota -- leaves a
# shorter file that is still a well-formed registry, and renaming that over the
# real one drops the entries below the failure: each names an external store
# whose sync has not been seen to finish and which nothing else names, so the
# write there stops being recoverable. Abandoning the rewrite keeps the list that
# was there, at the cost of a no-op commit for the entries it should have
# dropped.
#
# The failure is staged by making the replacement read-only once the first record
# is in it, which is the one way to reach this from outside the process: a real
# ENOSPC cannot be arranged here. Read-only rather than a directory, since `mv`
# refuses a directory over a file and so hides the very step under test -- the
# partial file has to be one a rename would accept.
setup
REG="$WS/.beads/.augment-sync.external"
ONE=$(mktemp -d)
TWO=$(mktemp -d)
mkdir -p "$ONE/.beads" "$TWO/.beads"
{
  sed -n '/^take_lock()/,/^drop_lock()/p;/^take_guard()/,/^}/p' "$HOOK"
  sed -n '/^filter_registry()/,/^}/p' "$HOOK"
} >"$WS/filter.sh"
reg_write "$REG" "$ONE" "$TWO"
bash -c "REGISTRY='$REG'; REGISTRY_GUARD='$REG.guard'
  . '$WS/filter.sh'
  # Keeps both, and breaks the write of the second: the first is already in the
  # replacement, so what a rename would publish is a list missing an entry.
  keep_all() { [ \"\$1\" = '$TWO' ] && chmod 0444 \"\$REGISTRY.\$\$\"; return 0; }
  filter_registry keep_all"
chmod -f 0644 "$REG".[0-9]* 2>/dev/null
registered "$ONE" && report ok ||
  report bad "a failed rewrite must leave the first entry (registry: $(reg_dump))"
registered "$TWO" && report ok ||
  report bad "a failed rewrite must leave the entries below the failure (registry: $(reg_dump))"
rm -rf "$REG".[0-9]* "$ONE" "$TWO"
teardown

# The same rewrite with the write succeeding does replace the list, so the
# above has not simply stopped the rewrite from happening at all.
setup
REG="$WS/.beads/.augment-sync.external"
ONE=$(mktemp -d)
TWO=$(mktemp -d)
mkdir -p "$ONE/.beads" "$TWO/.beads"
{
  sed -n '/^take_lock()/,/^drop_lock()/p;/^take_guard()/,/^}/p' "$HOOK"
  sed -n '/^filter_registry()/,/^}/p' "$HOOK"
} >"$WS/filter.sh"
reg_write "$REG" "$ONE" "$TWO"
bash -c "REGISTRY='$REG'; REGISTRY_GUARD='$REG.guard'
  . '$WS/filter.sh'
  keep_one() { [ \"\$1\" = '$ONE' ]; }
  filter_registry keep_one"
registered "$ONE" && ! registered "$TWO" && report ok ||
  report bad "a rewrite that completes must replace the list (registry: $(reg_dump))"
rm -rf "$ONE" "$TWO"
teardown

echo "lock: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]

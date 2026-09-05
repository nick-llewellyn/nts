#!/usr/bin/env bash
# Which commands beads-sync.sh treats as bead-store writes, and which store
# each one addresses.
#
# The scanner is sourced rather than restated here. A suite carrying its own
# copy of the rules passes against logic the hook no longer has, which is the
# failure mode that let three rounds of defects through.

set -uo pipefail

LIB="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/command-scan.sh}"
[ -r "$LIB" ] || { echo "FATAL: cannot read scanner at $LIB" >&2; exit 2; }
# shellcheck source=../lib/command-scan.sh
. "$LIB"

declare -F scan_command >/dev/null || {
  echo "FATAL: scan_command not defined by $LIB" >&2
  exit 2
}

PASS=0
FAIL=0

# The cwd every case is scanned under, so a relative `-C` has a fixed base.
BASE=/tmp/cs-classify-base

# Directories the `cd` cases enter. A `cd` to a path that is no directory
# fails and leaves the shell where it was, which the scanner reads from the
# filesystem, so a case asserting that a `cd` was taken needs its destination
# to exist. Made here rather than assumed of /tmp, where another suite or an
# earlier run could have left either answer.
# `TMPDIR` carries a trailing slash on macOS, and the doubled separator it leaves
# is not what a path naming this directory looks like. The store cases compare
# against the normalised form the scanner reports, so it is normalised here.
CD=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/cs-classify-cd.XXXXXX")" && pwd -P)
mkdir -p "$CD/base" "$CD/one/two" "$CD/other"
trap 'rm -rf "$CD"' EXIT

# A bead store, and directories below it holding none. `bd` selects its store by
# walking up from where it runs, so which store a command opens is a question
# about the filesystem and the cases asserting it need one to read.
STORE="$CD/repo"
mkdir -p "$STORE/.beads" "$STORE/sub/deeper"
# A second, to assert that the walk stops at the nearest rather than the first.
mkdir -p "$STORE/nested/inner/.beads"

classify() {
  scan_command "$1" "$BASE"
  [ "$SCAN_MUTATES" -eq 1 ] && echo sync || echo skip
}

check() {
  local want="$1" command="$2" got
  got=$(classify "$command")
  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL want=%-4s got=%-4s %s\n' "$want" "$got" "$command"
  fi
}

# Asserts the stores a command addresses, space-separated and in order.
check_target() {
  local want="$1" command="$2" got
  scan_command "$command" "$BASE"
  got="${SCAN_TARGETS[*]:+${SCAN_TARGETS[*]}}"
  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL want=[%s] got=[%s] %s\n' "$want" "$got" "$command"
  fi
}

# Asserts a write whose store the scan could not name: the command mutates,
# no target is reported, and the unresolved count says why. Asserting the
# empty target list alone let a scan that saw no write at all pass the same
# case -- and that regression is the one these cases exist to catch, since a
# write nothing reports is a store nothing syncs.
check_unresolved() {
  local command="$1" got
  scan_command "$command" "$BASE"
  got="${SCAN_TARGETS[*]:+${SCAN_TARGETS[*]}}"
  if [ -z "$got" ] && [ "$SCAN_MUTATES" -eq 1 ] && [ "$SCAN_UNRESOLVED" -ge 1 ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL want unresolved write got mutates=%s unresolved=%s targets=[%s] %s\n' \
      "$SCAN_MUTATES" "$SCAN_UNRESOLVED" "$got" "$command"
  fi
}

# --- not bd at all -----------------------------------------------------
check skip 'ls -la'
check skip 'git commit -m "bd update"'
check skip 'echo bd'
check skip 'abd list'
check skip 'bdx list'

# --- read-only verbs ---------------------------------------------------
check skip 'bd list'
check skip 'bd show CHR-1'
check skip 'bd ready'
check skip 'bd blocked'
check skip 'bd search foo'
check skip 'bd stale'
check skip 'bd status'
check skip 'bd graph'
check skip 'bd export'
check skip 'bd prime'
check skip 'bd version'
check skip 'bd -C /tmp/x list'
check skip 'bd list --json | jq .'

# --- read-only subcommands ---------------------------------------------
check skip 'bd dep list CHR-1'
check skip 'bd dep tree CHR-1'
check skip 'bd label list'
check skip 'bd kv get foo'
check skip 'bd config get x'
check skip 'bd dolt status'
check skip 'bd dolt log'
check skip 'bd swarm validate'
check skip 'bd todo list'
check skip 'bd human list'
check skip 'bd human stats'

# --- mutating verbs ----------------------------------------------------
# Includes verbs an allow-list would plausibly have missed, which is why
# the hook enumerates the read-only side instead.
check sync 'bd create "x"'
check sync 'bd close CHR-1'
check sync 'bd update CHR-1 --claim'
check sync 'bd defer CHR-1'
check sync 'bd undefer CHR-1'
check sync 'bd priority CHR-1 1'
check sync 'bd link CHR-1 CHR-2'
check sync 'bd tag CHR-1 foo'
check sync 'bd set-state CHR-1 open'
check sync 'bd promote CHR-1'
check sync 'bd duplicate CHR-1'
check sync 'bd supersede CHR-1 CHR-2'
check sync 'bd rename CHR-1 "y"'
check sync 'bd kv set foo bar'
check sync 'bd forget foo'
check sync 'bd todo add "x"'
check sync 'bd swarm create x'
check sync 'bd dep add CHR-1 CHR-2'
check sync 'bd label add CHR-1 foo'
check sync 'bd dolt commit -m x'
# `human` reads bare and writes under two of its subcommands, so the verb
# cannot speak for it: `respond` comments and closes, `dismiss` closes.
check sync 'bd human respond CHR-1 -r "answered"'
check sync 'bd human dismiss CHR-1'
# Bare `bd human` prints a help menu, but a verb whose subcommand is missing
# lands on the syncing side like any other unrecognised operand pair.
check sync 'bd human'
# A subcommand a later bd release adds must land there too.
check sync 'bd human archive CHR-1'
# A verb a later bd release adds must land on the syncing side.
check sync 'bd frobnicate CHR-1'

# --- grouped commands --------------------------------------------------
# A read-only segment must not speak for a write beside it.
check sync 'bd config get x && bd update CHR-1 --claim'
check sync 'bd update CHR-1 --claim && bd config get x'
check sync 'bd list; bd close CHR-1'
check sync 'bd close CHR-1; bd list'
check skip 'bd list && bd show CHR-1'

# --- a read-only verb is only that verb, not a prefix of one -----------
# The suppression list is the dangerous half: a verb it wrongly matches
# strands a write. A hyphen, underscore or dot must not end the token.
check sync 'bd list-add CHR-1 foo'
check sync 'bd show-and-close CHR-1'
check sync 'bd status-set CHR-1 open'
check sync 'bd export-import'
check sync 'bd dep list-add CHR-1 CHR-2'
check sync 'bd config get-and-set x y'
check sync 'bd dolt status-reset'
# Verbs that legitimately carry a hyphen still suppress.
check skip 'bd find-duplicates'
check skip 'bd statuses'
check skip 'bd label list-all'
check skip 'bd dep cycles'

# --- substitutions and subshells ---------------------------------------
# `bd` after `(` or a backtick is still `bd`; the delimiter must not hide it.
check sync 'id=$(bd create "x")'
check sync '(bd close CHR-1)'
check sync 'echo "$(bd update CHR-1 --claim)"'
check sync 'id=`bd create "x"`'
check sync 'for i in $(seq 2); do bd close CHR-$i; done'
check sync 'bd update CHR-1 --notes "$(bd show CHR-2)"'
# The read-only side survives the extra boundaries.
check skip 'echo "$(bd list)"'
check skip '(bd show CHR-1)'
check skip 'count=$(bd list --json | jq length)'
# A substitution runs wherever in the word it sits -- under an arithmetic
# expansion, a parameter expansion's operator word or replacement, a slice
# bound -- and the word is walked whole so none of those places is a blind
# spot. Listing the places to look left `$(( $(bd close X) + 1 ))` running
# the write and reporting nothing.
check sync 'echo $(( $(bd close CHR-1) + 1 ))'
check sync 'echo "$(( $(bd close CHR-1) + 1 ))"'
check sync 'echo ${X:-$(bd close CHR-1)}'
check sync 'echo ${X/a/$(bd close CHR-1)}'
check sync 'echo ${X:$(bd close CHR-1):1}'
check sync 'n=$(( $(bd create "x" | wc -c) ))'
check_target '/tmp/store' 'echo "$(( $(bd -C /tmp/store close CHR-1) + 1 ))"'
check skip 'echo $(( $(bd list | wc -l) + 1 ))'

# --- help flags --------------------------------------------------------
check skip 'bd --help'
check skip 'bd -h'
check skip 'bd defer --help'
check skip 'bd dep --help'
check skip 'bd -C /tmp/x defer --help'
check sync 'bd defer --help && bd close CHR-7'
# A help token as an argument value is not a help invocation.
check sync 'bd update CHR-1 --title "document --help output"'
check sync 'bd create "x" --notes "pass -h for usage"'
# Nor is one an option of `bd`'s own merely for standing alone: a per-verb
# option takes the word after it, so `--title --help` titles the issue
# `--help` and writes the store. Read as a help request it suppressed the sync.
check sync 'bd update CHR-1 --title --help'
check sync 'bd update CHR-1 --title -h'
check sync 'bd create --notes --help "x"'
# A help flag two words past such an option is a help request again: the
# option consumed one word, not every word after it.
check skip 'bd update --title x --help'
# The unknown short flag takes the same reading.
check sync 'bd update CHR-1 -m --help'
# A global option's arity is known, so a help flag past its value still reads
# as one.
check skip 'bd -C /tmp/x --actor me --help'

# --- read-only token as an argument value ------------------------------
check sync 'bd update CHR-1 --notes "run bd show CHR-2 next"'
check sync 'bd close CHR-1 -m "see bd list output"'
check sync 'bd create "add bd status to docs"'
check sync 'bd update CHR-1 --title "bd export is slow"'
check skip '  bd list'

# --- command prefixes --------------------------------------------------
# A wrapper does not change which command runs. Reading the wrapper as the
# command name detects the write and then loses its `-C`, which is worse
# than missing it outright: the roots sync, nothing looks wrong, and the
# external store is never revisited.
check sync 'command bd close CHR-1'
check sync 'env bd close CHR-1'
check sync 'sudo bd close CHR-1'
check sync 'exec bd close CHR-1'
check sync 'nohup bd close CHR-1'
check sync 'time bd close CHR-1'
check sync '/usr/local/bin/bd close CHR-1'
# The prefix is transparent in both directions, so a read-only behind one
# is still read-only. Under text matching the keyword defeated the `^` in
# the suppression pattern and the query was read as a write.
check skip 'if bd list; then echo done; fi'
check skip 'command bd list'
check skip 'sudo bd dep list CHR-1'
# A word that is not a prefix is the command, and `bd` after it is an
# argument.
check skip 'echo bd close CHR-1'
check skip 'grep bd close CHR-1'
# `exec` takes options of its own. Without them the walk stopped at `-a` and
# named it as the command word, so the `bd` behind it went unread: the write
# was missed outright, and with it the external store no other word names.
check_target '/tmp/store' 'exec -a worker bd -C /tmp/store close CHR-1'
check_target '/tmp/store' 'exec -l bd -C /tmp/store close CHR-1'
check_target '/tmp/store' 'exec -c bd -C /tmp/store close CHR-1'
check_target '/tmp/store' 'exec -lc bd -C /tmp/store close CHR-1'
check skip 'exec -a worker bd list'
# A letter neither table knows may take the word after it, so the command word
# cannot be placed -- but the `bd` after it may be it, so the invocation is a
# write whose store is unknown, as for any wrapper.
check_unresolved 'exec -Z bd -C /tmp/store close CHR-1'
# `xargs` runs the command it is given, once per batch of its input, so it
# stands in front of the real command as the wrappers above do. Read as the
# command itself, the `bd` behind it was an argument nothing looked at: the
# assignee audit AGENTS.md prescribes -- `bd list --json | ... | xargs -I{} bd
# assign {} user` -- wrote the store and the hook reported nothing, so the
# writes sat local until SessionEnd.
check sync 'bd list --json | grep -v x | xargs -I{} bd assign {} nllewelln@gmail.com'
check sync 'xargs bd close'
check sync 'xargs -n1 -P4 bd close'
check sync 'xargs -0rt bd close CHR-1'
check sync 'xargs -n 1 -- bd close CHR-1'
check sync 'xargs -d "\n" -a ids bd close'
check sync 'xargs --max-args=1 --no-run-if-empty bd close'
check_target '/tmp/store' 'xargs -I{} bd -C /tmp/store assign {} user'
check_target '/tmp/store' 'cat ids | xargs -I {} bd -C /tmp/store close {}'
# The prefix is transparent in both directions here too.
check skip 'xargs -n1 bd show'
check skip 'xargs -I{} bd show {}'
# The replacement string names an argument the input supplies, so what stands
# in its place here is not what the command receives: a `-C {}` names a store
# per input line that this scan cannot read, where the literal `{}` resolved to
# a directory of that name under the launch directory. Every spelling of the
# option -- `-I`, BSD `-J`, `-i[str]`, `--replace[=str]` -- sets it.
check_unresolved 'xargs -I{} bd -C {} close CHR-1'
check_unresolved 'xargs -I{} bd -C /tmp/store-{} close CHR-1'
check_unresolved 'xargs -J % bd -C % close CHR-1'
check_unresolved 'xargs -i bd -C {} close CHR-1'
check_unresolved 'xargs -i@@ bd -C @@ close CHR-1'
check_unresolved 'xargs --replace bd -C {} close CHR-1'
check_unresolved 'xargs --replace=@@ bd -C @@ close CHR-1'
for spelling in 'xargs -I{} bd -C {} close CHR-1' 'xargs -J % bd -C % close CHR-1' \
  'xargs -i bd -C {} close CHR-1' 'xargs --replace bd -C {} close CHR-1'; do
  scan_command "$spelling" "$BASE"
  [ "$SCAN_MUTATES" -eq 1 ] && [ "$SCAN_UNRESOLVED" -eq 1 ] && PASS=$((PASS + 1)) || {
    FAIL=$((FAIL + 1))
    printf 'FAIL want mutates=1 unresolved=1 got mutates=%s unresolved=%s %s\n' \
      "$SCAN_MUTATES" "$SCAN_UNRESOLVED" "$spelling"
  }
done
# A bare `-i` is `-I {}` and takes no word of its own, so the word after it is
# the command; reading it as the value named `bd` as the string and `assign`
# as the command.
check sync 'xargs -i bd assign {} user'
check skip 'xargs -i bd show {}'
# An argument that does not hold the string is what it says.
check_target '/tmp/store' 'xargs -I{} bd -C /tmp/store close {}'
# A replacement string this scan cannot read leaves the arguments as they are:
# the words it would match carry the same expansion and are unreadable already.
check_target '/tmp/store' 'xargs -I "$CS_SOMETHING_UNSET" bd -C /tmp/store close "$CS_SOMETHING_UNSET"'
# The command word itself may come from the input, in which case nothing here
# names it.
check skip 'xargs -I{} {} close CHR-1'
# With no command `xargs` runs `echo`, and a letter neither table knows leaves
# the command word unplaceable, as for any wrapper.
check skip 'xargs'
check_unresolved 'xargs -Z bd close CHR-1'
# The word `xargs` as an argument is a string, not a wrapper.
check skip 'echo xargs bd close CHR-1'

# --- quoting -----------------------------------------------------------
# An operator inside quotes is a character in a word, not a boundary.
check sync 'bd create "one; two"'
check sync 'bd create "a && b"'
check sync 'bd create "pipe | here"'
check skip 'echo "bd close CHR-1"'
check skip "echo 'bd close CHR-1'"
check sync 'bd close CHR-1 -m "it'"'"'s done"'

# --- targets -----------------------------------------------------------
check_target '/tmp/store' 'bd -C /tmp/store close CHR-1'
check_target '/tmp/store' 'command bd -C /tmp/store close CHR-1'
check_target '/tmp/store' 'sudo bd -C /tmp/store close CHR-1'
check_target '/tmp/store' 'bd --dir /tmp/store close CHR-1'
check_target '/tmp/store' 'bd -C=/tmp/store close CHR-1'
# `-C` carries its directory attached as readily as separated, and may sit at
# the end of a bundle of flags that take nothing. Matched as a whole word
# neither form named a `-C` at all, so the write was found and its target lost
# -- and an external store named by nothing else then goes unregistered, which
# no later event can recover.
check_target '/tmp/store' 'bd -C/tmp/store close CHR-1'
check_target '/tmp/store' 'bd -qC/tmp/store close CHR-1'
check_target '/tmp/store' 'bd -vqC/tmp/store close CHR-1'
check_target '/tmp/store' 'bd -qC=/tmp/store close CHR-1'
check_target '/tmp/store' 'bd -q -C /tmp/store close CHR-1'
# `-h` among the letters is still the help flag, which prints instead of
# writing.
check skip 'bd -qh close CHR-1'
check skip 'bd -hC/tmp/store close CHR-1'
# A letter this scan does not know is stepped over rather than abandoning the
# invocation: the write is still found, and only its target is in doubt. Giving
# up would be the worse trade, `bd` being the command that does the writing.
check sync 'bd -Z/tmp/x close CHR-1'
check_target '' 'bd -Z/tmp/x close CHR-1'
# A lone `-` is an operand, not an option, so it does not swallow what follows.
check_target '/tmp/store' 'bd -C /tmp/store close - CHR-1'

# --- the store a command opens without naming it -------------------------
# `bd` selects its store by walking up from the directory it runs in, so a
# mutating command with no `-C` still writes one particular store -- and where
# that is not a workspace root, reporting nothing left it in neither the push set
# nor the registry, which no later event can recover: SessionEnd builds its list
# the same way.
check_target "$STORE" "cd $STORE && bd close CHR-1"
check_target "$STORE" "cd $STORE/sub/deeper && bd close CHR-1"
# The nearest store wins, the walk stopping at the first it meets.
check_target "$STORE/nested/inner" "cd $STORE/nested/inner && bd close CHR-1"
# `-C` is where `bd` starts looking rather than where it finds, so it walks up
# from there too. Reported as given, a subdirectory holding no `.beads` was a
# root the hook then skipped -- and the store that was written went unsynced.
check_target "$STORE" "bd -C $STORE/sub/deeper close CHR-1"
check_target "$STORE" "bd -C $STORE close CHR-1"
check_target "$STORE/nested/inner" "bd -C $STORE/nested/inner close CHR-1"
# A relative `-C` is resolved before the walk, so a `cd` before it applies.
check_target "$STORE" "cd $STORE && bd -C sub/deeper close CHR-1"
# No ancestor holding a store is nothing to sync: `bd` fails there, so no write
# happened and there is nothing to report unresolvable either.
check_target '' "cd $CD/other && bd close CHR-1"
# A cwd this scan cannot know leaves the store unknowable, which is counted --
# the walk from a guessed directory would name one the command never opened.
check_unresolved 'cd $(pwd); bd close CHR-1'
# A read-only command opens a store too, but nothing there needs syncing.
check_target '' "cd $STORE && bd list"
# A `-C` naming no directory is reported as it stands rather than walked up
# from: `bd` refuses such a path outright, so walking would name an ancestor's
# store this command never opened.
check_target "$STORE/sub/nosuch" "bd -C $STORE/sub/nosuch close CHR-1"
# The directory flag is one scalar option however it is spelled, so a repeated
# one takes its last value: `bd -C /a -C /b close X` writes /b. Keeping the
# first pushed and registered /a while the store that was written went
# unrecorded -- and an external one named by nothing else stayed local for good.
check_target "$STORE" "bd -C $CD/other -C $STORE close CHR-1"
check_target "$CD/other" "bd -C $STORE -C $CD/other close CHR-1"
check_target "$STORE" "bd --dir=$CD/other -C $STORE close CHR-1"
check_target "$STORE" "bd -C $CD/other --directory $STORE close CHR-1"
check_target "$STORE" "bd -C$CD/other -qC$STORE close CHR-1"
check_target "$STORE" "bd -C $CD/other --dir $STORE close CHR-1"
# A later one this scan cannot read leaves the store in doubt rather than
# falling back to the earlier one, which the command did not use.
check_unresolved "bd -C $CD/other -C \$(pwd) close CHR-1"

# BEADS_DIR names the store outright when no `-C` overrides it, and points at
# the `.beads` directory itself where every other path names the root above it.
check_target "$STORE" "BEADS_DIR=$STORE/.beads bd close CHR-1"
check_target "$STORE" "env BEADS_DIR=$STORE/.beads bd close CHR-1"
# It reaches the command's environment though it speaks for none of its words,
# so a prefix assignment counts here where it does not for `-C "$BEADS_DIR"`.
check_target "$STORE/nested/inner" \
  "cd $STORE && BEADS_DIR=$STORE/nested/inner/.beads bd close CHR-1"
# `-C` wins over it, which is the precedence `bd` itself applies.
check_target "$STORE" "BEADS_DIR=$CD/other/.beads bd -C $STORE close CHR-1"
# A BEADS_DIR this scan cannot read leaves the store in doubt rather than
# falling back to the walk, which would name the store the walk finds while the
# write went where BEADS_DIR pointed.
check_unresolved "cd $STORE && BEADS_DIR=\$(pwd) bd close CHR-1"
# Set to nothing, it names no store and the walk applies as usual.
check_target "$STORE" "cd $STORE && BEADS_DIR= bd close CHR-1"
# The root is what holds the `.beads` the value names, so the separator after
# it is not a component of its own. Taking the empty one off named the `.beads`
# directory as the root, which holds no `.beads` itself: the hook dropped it and
# the write went to neither the push set nor the registry.
check_target "$STORE" "BEADS_DIR=$STORE/.beads/ bd close CHR-1"
check_target "$STORE" "BEADS_DIR=$STORE/.beads/// bd close CHR-1"
# The environment is built in the shell's order, innermost last. A name
# repeated in the prefix takes its last value; a wrapper's own assignment
# lands on top of the prefix, however many wrappers deep; and a wrapper that
# clears or unsets drops the prefix's value with the rest. Answering from the
# first prefix assignment named a store the command never opened in each
# case, pushing and registering it while the one written stayed local.
check_target "$STORE" "BEADS_DIR=$CD/other/.beads BEADS_DIR=$STORE/.beads bd close CHR-1"
check_target "$STORE" "BEADS_DIR=$CD/other/.beads env BEADS_DIR=$STORE/.beads bd close CHR-1"
check_target "$STORE" "BEADS_DIR=$CD/other/.beads env A=1 env BEADS_DIR=$STORE/.beads bd close CHR-1"
check_target "$STORE" "BEADS_DIR=$CD/other/.beads nohup env BEADS_DIR=$STORE/.beads bd close CHR-1"
check_unresolved "BEADS_DIR=$CD/other/.beads sudo bd close CHR-1"
# A wrapper assignment of another name leaves the prefix's in force.
check_target "$STORE" "BEADS_DIR=$STORE/.beads env A=1 bd close CHR-1"
# A cleared environment is a known one, not an unreadable one. Under `env -i`,
# `exec -c` or `env -u BEADS_DIR` the name is certainly unset, so `bd` walks up
# from its directory as it does when nothing ever set it -- and that walk can
# be followed. Reading the clear as opaque left `cd /external/repo && env -i
# bd close X` unresolved: the write was found, but the store the walk names
# was neither synced nor registered, and the warning pointed at a value the
# command never depended on.
check_target "$STORE" "cd $STORE && BEADS_DIR=$CD/other/.beads env -i bd close CHR-1"
check_target "$STORE" "cd $STORE && BEADS_DIR=$CD/other/.beads env -u BEADS_DIR bd close CHR-1"
check_target "$STORE" "cd $STORE && BEADS_DIR=$CD/other/.beads env --unset=BEADS_DIR bd close CHR-1"
check_target "$STORE" "cd $STORE && BEADS_DIR=$CD/other/.beads env -uBEADS_DIR bd close CHR-1"
check_target "$STORE" "cd $STORE && BEADS_DIR=$CD/other/.beads exec -c bd close CHR-1"
check_target "$STORE" "cd $STORE && env BEADS_DIR=$CD/other/.beads env -i bd close CHR-1"
check_target "$STORE" "cd $STORE && env -i bash -c 'bd close CHR-1'"
check_target "$STORE" "cd $STORE && BEADS_DIR=$CD/other/.beads env -u BEADS_DIR bash -c 'bd close CHR-1'"
scan_command "cd $STORE && BEADS_DIR=$CD/other/.beads env -i bd close CHR-1" "$BASE"
[ "$SCAN_UNRESOLVED" -eq 0 ] && PASS=$((PASS + 1)) || {
  FAIL=$((FAIL + 1))
  printf 'FAIL unresolved want=0 got=%s cleared BEADS_DIR\n' "$SCAN_UNRESOLVED"
}
# ... while an unreadable one still leaves the store in doubt: what `sudo`
# passes is decided by a policy this scan cannot read, and a prefix word it
# cannot resolve may be an assignment of the name. An assignment read before
# such a word is in doubt with the rest.
check_unresolved "cd $STORE && BEADS_DIR=$CD/other/.beads sudo bd close CHR-1"
check_unresolved "cd $STORE && env -i sudo bd close CHR-1"
check_target '' "cd $STORE && env -i \$(w) bd close CHR-1"
check_target '' "cd $STORE && env -i BEADS_DIR=$STORE/.beads \$(w) bd close CHR-1"
check_unresolved "cd $STORE && env -i -u \$(w) bd close CHR-1"
check_unresolved "cd $STORE && sudo bash -c 'bd close CHR-1'"
scan_command "cd $STORE && env -i sudo bd close CHR-1" "$BASE"
[ "$SCAN_UNRESOLVED" -eq 1 ] && PASS=$((PASS + 1)) || {
  FAIL=$((FAIL + 1))
  printf 'FAIL unresolved want=1 got=%s opaque after cleared\n' "$SCAN_UNRESOLVED"
}
# The innermost wrapper decides: a clear under `sudo` is a clear, and a
# `sudo` under a clear is opaque. An assignment `env -i` carries itself, or
# one made after the clear, is the environment.
check_target "$STORE" "cd $STORE && sudo env -i bd close CHR-1"
check_target "$STORE" "cd $STORE && sudo bash -c 'env -i bd close CHR-1'"
check_target "$STORE" "cd $STORE && env -i BEADS_DIR=$STORE/.beads bd close CHR-1"
check_target "$STORE" "cd $STORE && env -i env BEADS_DIR=$STORE/.beads bd close CHR-1"
check_target "$STORE" "cd $STORE && env -u BEADS_DIR env BEADS_DIR=$STORE/.beads bd close CHR-1"
check_target "$STORE" "cd $CD/other && BEADS_DIR=$CD/other/.beads env -u BEADS_DIR bd -C $STORE close CHR-1"
# Only what the child can see is consulted. A shell variable is not an
# environment variable: with no BEADS_DIR inherited, `BEADS_DIR=...; bd close`
# runs `bd` with none at all, and it walks up from its directory while the
# decoy stays a shell variable it never sees. `export`, `declare -x` and
# `set -a` are what make the name reach it. Reading every assignment as
# exported named the decoy, and the store written stayed local.
check_target "$STORE" "cd $STORE; BEADS_DIR=$CD/other/.beads; bd close CHR-1"
check_target "$STORE/nested/inner" "cd $STORE; export BEADS_DIR=$STORE/nested/inner/.beads; bd close CHR-1"
check_target "$STORE/nested/inner" "cd $STORE; declare -x BEADS_DIR=$STORE/nested/inner/.beads; bd close CHR-1"
check_target "$STORE/nested/inner" "cd $STORE; typeset -x BEADS_DIR=$STORE/nested/inner/.beads; bd close CHR-1"
check_target "$STORE/nested/inner" "cd $STORE; BEADS_DIR=$STORE/nested/inner/.beads; export BEADS_DIR; bd close CHR-1"
check_target "$STORE/nested/inner" "cd $STORE; set -a; BEADS_DIR=$STORE/nested/inner/.beads; bd close CHR-1"
check_target "$STORE/nested/inner" "cd $STORE; set -o allexport; BEADS_DIR=$STORE/nested/inner/.beads; bd close CHR-1"
check_target "$STORE" "cd $STORE; set -a; set +a; BEADS_DIR=$CD/other/.beads; bd close CHR-1"
check_target "$STORE" "cd $STORE; declare BEADS_DIR=$CD/other/.beads; bd close CHR-1"
# An assignment keeps the attribute the name already had, so an inherited
# BEADS_DIR reassigned is still exported.
export BEADS_DIR="$CD/other/.beads"
check_target "$STORE/nested/inner" "cd $STORE; BEADS_DIR=$STORE/nested/inner/.beads; bd close CHR-1"
# ... unless the attribute is taken away first, by `export -n`, `declare +x`
# or an `unset` -- after which a fresh assignment is a shell variable again.
check_target "$STORE" "cd $STORE; export -n BEADS_DIR; bd close CHR-1"
check_target "$STORE" "cd $STORE; declare +x BEADS_DIR; bd close CHR-1"
check_target "$STORE" "cd $STORE; unset BEADS_DIR; BEADS_DIR=$STORE/nested/inner/.beads; bd close CHR-1"
unset BEADS_DIR
# A name `unset` since is gone however it was set. Reading the export as still
# standing named a store the command never opened.
check_target "$STORE" "cd $STORE; export BEADS_DIR=$CD/other/.beads; unset BEADS_DIR; bd close CHR-1"
check_target "$STORE" "cd $STORE; export BEADS_DIR=$CD/other/.beads; unset -v BEADS_DIR; bd close CHR-1"
check_target "$STORE" "cd $STORE; export BEADS_DIR=$CD/other/.beads; unset A BEADS_DIR; bd close CHR-1"
check_target "$STORE/nested/inner" "cd $STORE; export BEADS_DIR=$STORE/nested/inner/.beads; unset -f BEADS_DIR; bd close CHR-1"
# An export or unset the shell may not reach leaves the child's environment
# unknown, as a conditional assignment leaves the value.
check_unresolved "cd $STORE; export BEADS_DIR=$CD/other/.beads; t && unset BEADS_DIR; bd close CHR-1"
check_unresolved "cd $STORE; BEADS_DIR=$CD/other/.beads; t && export BEADS_DIR; bd close CHR-1"
check_unresolved "cd $STORE; t && set -a; BEADS_DIR=$CD/other/.beads; bd close CHR-1"
# A name this scan cannot read may be any name, so every value is in doubt
# after unsetting it.
check_unresolved "cd $STORE; export BEADS_DIR=$STORE/.beads; unset \$(n); bd close CHR-1"
# A temporary prefix reaches the child whatever the name's attribute.
check_target "$STORE/nested/inner" "cd $STORE; BEADS_DIR=$STORE/nested/inner/.beads bd close CHR-1"
# The shell's own words still expand the shell variable: export decides what
# the child sees, not what `-C "$BEADS_DIR"` says.
check_target "$STORE/nested/inner" "BEADS_DIR=$STORE/nested/inner; bd -C \"\$BEADS_DIR\" close CHR-1"

# A quoted target keeps every character of the path, including ones a text
# split would have cut it at.
check_target '/tmp/a;b' 'bd -C "/tmp/a;b" close CHR-1'
check_target '/tmp/a b' 'bd -C "/tmp/a b" close CHR-1'
check_target '/tmp/a b' "bd -C '/tmp/a b' close CHR-1"
check_target '/tmp/a b' 'bd -C /tmp/a\ b close CHR-1'
check_target '/tmp/a(b)' 'bd -C "/tmp/a(b)" close CHR-1'
check_target '/tmp/a|b' 'bd -C "/tmp/a|b" close CHR-1'

# --- backslashes mean different things inside and outside quotes -------
# Unquoted, a backslash escapes whatever follows and goes. Inside double
# quotes it only escapes `$`, a backtick, `"`, another backslash and a
# newline; before anything else it is an ordinary character the path keeps.
# Applying the unquoted rules throughout named a store one character shorter
# than the one the command opened -- a path that does not exist, so the write
# went to a store nothing synced and nothing recorded.
check_target '/tmp/a\q' 'bd -C "/tmp/a\q" close CHR-1'
check_target '/tmp/aq' 'bd -C /tmp/a\q close CHR-1'
check_target '/tmp/a$b' 'bd -C "/tmp/a\$b" close CHR-1'
check_target '/tmp/a"b' 'bd -C "/tmp/a\"b" close CHR-1'
check_target '/tmp/a\b' 'bd -C "/tmp/a\\b" close CHR-1'
# Single quotes honour no escape at all.
check_target '/tmp/a\q' "bd -C '/tmp/a\\q' close CHR-1"
# `$'...'` is single-quoted in the tree and not in the shell: its escapes are
# decoded, so `$'/tmp/store\x31'` names /tmp/store1. Read as plain single
# quotes the body was the target, a path that does not exist, which the hook
# dropped in silence -- the write was found, the store it went to was not.
check_target '/tmp/store1' "bd -C \$'/tmp/store\\x31' close CHR-1"
check_target '/tmp/store1' "bd -C \$'/tmp/store\\061' close CHR-1"
check_target $'/tmp/a\tb' "bd -C \$'/tmp/a\\tb' close CHR-1"
check_target '/tmp/café' "bd -C \$'/tmp/caf\\u00e9' close CHR-1"
check_target "/tmp/a\\b'c" "bd -C \$'/tmp/a\\\\b\\'c' close CHR-1"
check_target '/tmp/store' "bd -C \$'/tmp/store' close CHR-1"
# An escape bash does not know keeps its backslash, and a pattern character is
# quoted here as it is in plain single quotes.
check_target '/tmp/a\qb' "bd -C \$'/tmp/a\\qb' close CHR-1"
check_target '/tmp/store-*' "bd -C \$'/tmp/store-*' close CHR-1"
# The bytes are a C string, so a NUL ends the value. Bytes that are not UTF-8
# name nothing this scan can carry as text: unknown, and counted, rather than
# the body as written.
check_target '/tmp/store' "bd -C \$'/tmp/store\\0junk' close CHR-1"
check_unresolved "bd -C \$'/tmp/\\xff' close CHR-1"
scan_command "bd -C \$'/tmp/\\xff' close CHR-1" "$BASE"
[ "$SCAN_UNRESOLVED" -eq 1 ] && PASS=$((PASS + 1)) || {
  FAIL=$((FAIL + 1))
  printf 'FAIL unresolved want=1 got=%s $'"'"'/tmp/\\xff'"'"'\n' "$SCAN_UNRESOLVED"
}
check sync "bd -C \$'/tmp/\\xff' close CHR-1"
# The command word and the verb are decoded the same way, and so is an
# assignment's value.
check_target '/tmp/store' "\$'b\\x64' -C /tmp/store close CHR-1"
check sync "bd \$'clo\\x73e' CHR-1"
check skip "bd \$'li\\x73t'"
check skip "\$'bd\\x78' close CHR-1"
check_target '/tmp/a1' "OUT=\$'/tmp/a\\x31'; bd -C \"\$OUT\" close CHR-1"

# --- an unquoted expansion is split into fields ------------------------
# A word is not an argument. Bash splits an unquoted expansion on IFS, so a
# value holding a space supplies two arguments and only the first is the
# target -- the second shifts everything after it along. Reading the word as
# one argument named a store the command never opened, and the one it did
# open went unregistered.
check_target '/tmp/a' 'OUT="/tmp/a b"; bd -C $OUT close CHR-1'
check_target '/tmp/a b' 'OUT="/tmp/a b"; bd -C "$OUT" close CHR-1'
# The split is per part, not per word, so one quoted half does not protect
# the other.
check_target '/tmp/a' 'A=/tmp; B="a b"; bd -C "$A"/$B close CHR-1'
# A field the split creates is an ordinary argument, and can be the verb.
check skip 'V=list; bd $V'
check sync 'V="close CHR-1"; bd $V'
# Splitting is on IFS, which an assignment in the same text can change.
check_target '/tmp/a' 'IFS=:; OUT=/tmp/a:b; bd -C $OUT close CHR-1'
# A separator that is not whitespace delimits each time it occurs, so two in
# a row bound an empty field where whitespace would bound none: `-p::bd` is
# `-p '' bd`, and the empty prompt is an argument `-p` takes. Dropping it
# handed `bd` to `-p` and lost the write.
check_target '/tmp/store' 'IFS=:; OPTS="-p::bd"; sudo $OPTS -C /tmp/store close CHR-1'
check_target '/tmp/store' 'IFS=:; OPTS="-C:/tmp/store"; bd $OPTS close CHR-1'
# The empty field is `-C`'s value and the path is the verb, so the store is
# not named; dropping the field would have named it.
check_unresolved 'IFS=:; OPTS="-C::/tmp/store"; bd $OPTS close CHR-1'
# One at the end closes nothing.
check skip 'IFS=:; V="list:"; bd $V'
# IFS whitespace around such a delimiter is absorbed into it: one delimiter
# with whitespace either side is one split, two are still an empty field.
check_target '' 'IFS=": "; OPTS="-p : bd"; sudo $OPTS -C /tmp/store close CHR-1'
check_target '/tmp/store' 'IFS=": "; OPTS="-p :: bd"; sudo $OPTS -C /tmp/store close CHR-1'
# A run of whitespace alone is one split with no empty field.
check skip 'IFS=": "; V="  list  "; bd $V'
# An IFS whose value this scan cannot read leaves splitting unknowable, so no
# store is named rather than the wrong one.
check_unresolved 'IFS=$(printf x); OUT="/tmp/a b"; bd -C $OUT close CHR-1'
check sync 'IFS=$(printf x); OUT="/tmp/a b"; bd -C $OUT close CHR-1'
# An IFS `unset` splits on the default whitespace again, whatever it held
# before. Keeping the old value split `/tmp/a:b` where the shell did not.
check_target '/tmp/a:b' 'IFS=:; unset IFS; OUT=/tmp/a:b; bd -C $OUT close CHR-1'
check_target '/tmp/a' 'IFS=:; unset IFS; OUT="/tmp/a b"; bd -C $OUT close CHR-1'
check_target '/tmp/a:b' 'IFS=:; unset -v IFS; OUT=/tmp/a:b; bd -C $OUT close CHR-1'
# A function `unset` leaves the variable alone.
check_target '/tmp/a' 'IFS=:; unset -f IFS; OUT=/tmp/a:b; bd -C $OUT close CHR-1'
# An `unset` that may not have run leaves IFS unknowable either way.
check_unresolved 'IFS=:; false && unset IFS; OUT=/tmp/a:b; bd -C $OUT close CHR-1'
# A body that touches IFS leaves it unknown after the call, as it does any
# name it assigns: which of its paths ran is not inferred.
check_unresolved 'IFS=:; f() { local IFS=" "; unset IFS; }; f; OUT=/tmp/a:b; bd -C $OUT close CHR-1'
# An expansion that is all separators supplies no argument at all, so what
# follows it is still the verb.
check sync 'E=""; bd $E close CHR-1'
check skip 'E=" "; bd $E list'
# An assignment's right-hand side is not split, however many separators it
# holds: `OUT=$X` is one value.
check_target '/tmp/a b' 'S="/tmp/a b"; OUT=$S; bd -C "$OUT" close CHR-1'
# Nor is the operand of a `cd`, which takes one word.
check_target "$CD/base/store" "D=\"$CD/base\"; cd \"\$D\"; bd -C store close CHR-1"
# A read-only command names no store to sync.
check_target '' 'bd -C /tmp/store list'
# Each write names its own.
check_target '/tmp/one /tmp/two' 'bd -C /tmp/one close CHR-1; bd -C /tmp/two close CHR-2'

# --- relative targets and cd -------------------------------------------
check_target "$BASE/store" 'bd -C store close CHR-1'
check_target "$CD/base/store" "cd $CD/base; bd -C store close CHR-1"
check_target "$CD/base/store" "cd $CD/base && bd -C store close CHR-1"
check_target "$CD/one/two/store" "cd $CD/one; cd two; bd -C store close CHR-1"
# `cd` with no operand goes to $HOME and `cd -` to a directory only the
# shell's history knows, so neither leaves a cwd this scan can name.
check_unresolved "cd $CD/base; cd; bd -C store close CHR-1"
check_unresolved "cd $CD/base; cd -; bd -C store close CHR-1"
# Its own options say nothing about where it lands.
check_target "$CD/base/store" "cd -P $CD/base; bd -C store close CHR-1"
check_target "$CD/base/store" "cd -- $CD/base; bd -C store close CHR-1"
# A `cd` to a path that is no directory fails, and the command after it runs
# where the shell already was. Recording the path anyway resolves the write
# under a directory the shell never entered -- and where that path holds no
# store, the real one is neither pushed nor registered.
check_target "$BASE/store" 'cd /nonexistent-cs-classify; bd -C store close CHR-1'
check_target "$CD/base/store" "cd $CD/base; cd $CD/base/missing; bd -C store close CHR-1"
# A `cd` whose execution depends on an exit status may not have run, so the
# directory the write happened in is unknown. Reporting no target leaves the
# roots syncing as before; reporting a guessed one names some other store.
check_unresolved 'false && cd /tmp/other; bd -C store close CHR-1'
check_unresolved 'cd /tmp/base || cd /tmp/fallback; bd -C store close CHR-1'
# The mirror of the above: what follows `||` runs only if the `cd` failed, so
# a `cd` read as successful names the directory of the branch not taken.
check_unresolved 'cd /tmp/missing || bd -C store close CHR-1'
# Given up with it, the cwd being knowable only by reasoning about which
# commands end the list.
check_unresolved 'cd /tmp/base || exit 1; bd -C store close CHR-1'
# An absolute target does not need the cwd, so an unknown one costs nothing.
check_target '/tmp/store' 'false && cd /tmp/other; bd -C /tmp/store close CHR-1'
# `pushd dir` moves the shell as `cd dir` does, and a scan that knew only `cd`
# kept the old cwd: `pushd /external; bd close X` was resolved against the
# workspace, naming its store while /external's went unregistered. The forms
# that land on an entry of the directory stack -- a bare `pushd`, a rotation,
# any `popd` -- leave the cwd unknown, the stack being the shell's alone;
# `-n` on either changes the stack and not the cwd.
check_target "$CD/base/store" "pushd $CD/base; bd -C store close CHR-1"
check_target "$CD/base/store" "pushd $CD/base >/dev/null && bd -C store close CHR-1"
check_target "$CD/base/store" "pushd -- $CD/base; bd -C store close CHR-1"
check_target "$CD/one/two/store" "pushd $CD/one; pushd two; bd -C store close CHR-1"
check_target "$STORE" "pushd $STORE; bd close CHR-1"
check_target "$BASE/store" "pushd -n $CD/base; bd -C store close CHR-1"
check_target "$BASE/store" "pushd $CD/base -n; bd -C store close CHR-1"
check_target "$BASE/store" 'pushd /nonexistent-cs-classify; bd -C store close CHR-1'
check_unresolved "pushd $CD/base; pushd; bd -C store close CHR-1"
check_unresolved "pushd $CD/base; pushd +1; bd -C store close CHR-1"
check_unresolved "pushd $CD/base; pushd -0; bd -C store close CHR-1"
check_unresolved "pushd $CD/base; popd; bd -C store close CHR-1"
check_unresolved "pushd $CD/base; popd +1; bd -C store close CHR-1"
check_unresolved 'popd; bd -C store close CHR-1'
check_target "$CD/base/store" "pushd $CD/base; popd -n; bd -C store close CHR-1"
check_unresolved "pushd \$(pick); bd -C store close CHR-1"
check_unresolved "false && pushd $CD/base; bd -C store close CHR-1"
check_unresolved "pushd $CD/base || bd -C store close CHR-1"
check_target '/tmp/store' "pushd $CD/base; popd; bd -C /tmp/store close CHR-1"
# A relative operand is looked for under each entry of CDPATH before the cwd,
# the first that is a directory winning, so `CDPATH=/external; cd repo` lands
# in /external/repo. Resolving `repo` under the tracked cwd registered and
# pushed a different store with no warning. An empty entry is the cwd, and
# an operand opening with `.` or `..`, or an absolute one, is not searched.
check_target "$CD/one/two/store" "CDPATH=$CD/one; cd two; bd -C store close CHR-1"
check_target "$CD/one/two/store" "CDPATH=/nonexistent-cs-classify:$CD/one; cd two; bd -C store close CHR-1"
check_target "$CD/one/two/store" "CDPATH=$CD/one; pushd two; bd -C store close CHR-1"
check_target "$CD/one/two/store" "cd $CD; CDPATH=one; cd two; bd -C store close CHR-1"
check_target "$CD/base/store" "cd $CD; CDPATH=:$CD/one; cd base; bd -C store close CHR-1"
mkdir -p "$CD/base/two/.beads"
check_target "$CD/base/two" "cd $CD/base; CDPATH=$CD/one; cd ./two; bd close CHR-1"
check_target "$CD/base/two" "cd $CD/base/two; CDPATH=$CD/one; cd ../two; bd close CHR-1"
check_target "$CD/base/store" "CDPATH=$CD/one; cd $CD/base; bd -C store close CHR-1"
# Nothing under CDPATH matches, so the operand resolves against the cwd.
check_target "$CD/one/two/store" "cd $CD/one; CDPATH=$CD/other; cd two; bd -C store close CHR-1"
# An unset CDPATH searches nothing; one this scan cannot read may send the
# shell anywhere, and so may a relative entry under a cwd it does not know.
check_target "$CD/one/two/store" "cd $CD/one; unset CDPATH; cd two; bd -C store close CHR-1"
check_unresolved "CDPATH=\$(pick); cd two; bd -C store close CHR-1"
check_unresolved "false && CDPATH=$CD/one; cd two; bd -C store close CHR-1"
check_unresolved "cd \$(pick); CDPATH=one:$CD/one; cd two; bd -C store close CHR-1"
check_target "$CD/one/two/store" "cd \$(pick); CDPATH=$CD/one; cd two; bd -C store close CHR-1"
# The hook's own environment answers when the text says nothing.
export CDPATH="$CD/one"
check_target "$CD/one/two/store" "cd two; bd -C store close CHR-1"
check_target "$CD/store" "env -i bash -c 'cd $CD; cd two; bd -C store close CHR-1'"
unset CDPATH

# --- variable targets --------------------------------------------------
# Resolved from the assignments the list has made where it has them, and
# from the inherited environment otherwise. The two must not be confused: an
# assignment is a prefix word, so `NAME=value` in an argument is a string.
export CS_TEST_STORE=/tmp/inherited
check_target '/tmp/inherited' 'bd -C "$CS_TEST_STORE" close CHR-1'
# A prefix assignment reaches the child's environment, not the argv the
# parent expands before the child exists, so `$CS_TEST_STORE` here is the
# inherited value and the write lands in /tmp/inherited.
check_target '/tmp/inherited' 'CS_TEST_STORE=/tmp/decoy bd -C "$CS_TEST_STORE" close CHR-1'
check_target '/tmp/inherited' 'echo CS_TEST_STORE=/tmp/decoy; bd -C "$CS_TEST_STORE" close CHR-1'
check_target '/tmp/one' 'CS_TEST_STORE=/tmp/one; bd -C "$CS_TEST_STORE" close CHR-1'
# The assignment in effect when the write runs, not the last one written.
check_target '/tmp/one' 'CS_TEST_STORE=/tmp/one; bd -C "$CS_TEST_STORE" close CHR-1; CS_TEST_STORE=/tmp/two'
# Single quotes suppress expansion, so this names a literal path -- and a
# literal one that does not start with `/` is relative, like any other.
check_target "$BASE/\$CS_TEST_STORE" "bd -C '\$CS_TEST_STORE' close CHR-1"
check_target '/tmp/$CS_TEST_STORE' "bd -C '/tmp/\$CS_TEST_STORE' close CHR-1"
# A name with no value anywhere is unresolvable, and reporting nothing is
# the honest answer.
check_unresolved 'bd -C "$CS_NO_SUCH_VAR_HERE" close CHR-1'
# An inherited name set to the empty string has a value, and it is the empty
# string -- unlike one nothing sets at all. Read as absent, the word carrying
# it was unknowable and the store it named went unregistered.
export CS_TEST_EMPTY=
check_target '/tmp/store' 'bd -C "$CS_TEST_EMPTY/tmp/store" close CHR-1'
check_unresolved 'bd -C "$CS_TEST_EMPTY" close CHR-1'
check_target "$BASE/store" 'bd -C "$CS_TEST_EMPTY"store close CHR-1'
# `X=` assigns the empty string, and the parse carries no value node for it
# rather than an empty one, so a test for that node read it as no assignment
# at all and left the inherited path standing -- naming a store the command
# never opened.
check_target '/tmp/store' 'CS_TEST_STORE=; bd -C "$CS_TEST_STORE/tmp/store" close CHR-1'
check_unresolved 'CS_TEST_STORE=; bd -C "$CS_TEST_STORE" close CHR-1'
check_target '/tmp/store' 'export CS_TEST_STORE=; bd -C "$CS_TEST_STORE/tmp/store" close CHR-1'
check_target '/tmp/store' 'declare CS_TEST_STORE=; bd -C "$CS_TEST_STORE/tmp/store" close CHR-1'
check_target '/tmp/store' 'CS_TEST_EMPTY=; bd -C "$CS_TEST_EMPTY/tmp/store" close CHR-1'
# One the shell may never reach leaves the name unknown: neither it nor the
# value before it speaks for what is in effect afterwards. Keeping the earlier
# value resolved the write against a store the command may never have opened.
check_unresolved 'false && CS_TEST_STORE=; bd -C "$CS_TEST_STORE/tmp/store" close CHR-1'
check_unresolved 'CS_TEST_STORE=/old; true && CS_TEST_STORE=/real; bd -C "$CS_TEST_STORE" close CHR-1'
scan_command 'CS_TEST_STORE=/old; true && CS_TEST_STORE=/real; bd -C "$CS_TEST_STORE" close CHR-1' "$BASE"
[ "$SCAN_UNRESOLVED" -eq 1 ] && PASS=$((PASS + 1)) || {
  FAIL=$((FAIL + 1))
  printf 'FAIL unresolved want=1 got=%s conditional assignment\n' "$SCAN_UNRESOLVED"
}
# A name the conditional path does not touch keeps its value.
check_target '/tmp/store' 'OUT=/tmp/store; true && OTHER=/x; bd -C "$OUT" close CHR-1'
# The forms that give a name no single value leave the one it had: `+=` with
# nothing to append, an array, and one element of an array.
check_target '/tmp/inherited' 'CS_TEST_STORE+=; bd -C "$CS_TEST_STORE" close CHR-1'
check_target '/tmp/inherited' 'CS_TEST_STORE=(/tmp/a /tmp/b); bd -C "$CS_TEST_STORE" close CHR-1'
check_target '/tmp/inherited' 'CS_TEST_STORE[2]=/tmp/x; bd -C "$CS_TEST_STORE" close CHR-1'
# `+=` with something to append gives the name what it had with that after
# it, so `OUT=/tmp/; OUT+=store` is /tmp/store. Recording the appended text
# alone left OUT as `store`, a relative path resolved under the launch
# directory -- a store the command never opened, while the one it wrote went
# unregistered.
check_target '/tmp/store' 'OUT=/tmp/; OUT+=store; bd -C "$OUT" close CHR-1'
check_target '/tmp/inherited/sub' 'CS_TEST_STORE+=/sub; bd -C "$CS_TEST_STORE" close CHR-1'
check_target '/tmp/store' 'OUT=/tmp; OUT+=/sto; OUT+=re; bd -C "$OUT" close CHR-1'
check_target '/tmp/store' 'export OUT=/tmp/; export OUT+=store; bd -C "$OUT" close CHR-1'
check_target '/tmp/store' 'OUT=/tmp/; declare OUT+=store; bd -C "$OUT" close CHR-1'
check_target "$HOME/store" 'OUT=; OUT+=~/store; bd -C "$OUT" close CHR-1'
# An unset name appends onto nothing, which is not the same as an unknown
# one: `X+=b` on an unset X is `b`, where an X whose value cannot be read
# leaves the result unreadable too.
check_target '/tmp/store' 'CS_NEVER_SET_ANYWHERE+=/tmp/store; bd -C "$CS_NEVER_SET_ANYWHERE" close CHR-1'
check_target '/tmp/store' 'unset OUT; OUT+=/tmp/store; bd -C "$OUT" close CHR-1'
check_unresolved 'OUT=$(pwd); OUT+=/store; bd -C "$OUT" close CHR-1'
check_unresolved 'OUT=/tmp/; OUT+=$(pwd); bd -C "$OUT" close CHR-1'
check_unresolved 'true && OUT=/tmp/; OUT+=store; bd -C "$OUT" close CHR-1'
# The same in the prefix position: the child gets the appended value, the
# command's own words the value from before it.
check_target "$STORE/nested/inner" "cd $STORE; BEADS_DIR=$STORE/nested; BEADS_DIR+=/inner/.beads bd close CHR-1"
check_target '/tmp/store' 'OUT=/tmp/ bash -c '"'"'OUT+=store; bd -C "$OUT" close CHR-1'"'"''
check_target '/tmp/store' 'export OUT=/tmp/; OUT+=store bash -c '"'"'bd -C "$OUT" close CHR-1'"'"''
unset CS_TEST_EMPTY
unset CS_TEST_STORE

# --- command substitution in the target ---------------------------------
# The value comes from running something the scan does not run, so the path
# is unknown. Reporting the word with the substitution dropped would not be
# vaguer, it would be wrong: `$(pwd)/store` would come out as `/store`.
check_unresolved 'bd -C "$(pwd)/store" close CHR-1'
check_unresolved 'bd -C "$(echo /tmp/x)/store" close CHR-1'
check_unresolved 'bd -C `pwd`/store close CHR-1'
# A substitution elsewhere in the command leaves the target alone.
check_target '/tmp/store' 'echo "$(pwd)"; bd -C /tmp/store close CHR-1'

# --- wrappers -----------------------------------------------------------
# A wrapper's own options are stepped over to find the command word. Past
# them, a `bd` that is an argument rather than the command is not a write:
# `env echo bd ...` runs echo.
check_target '/tmp/store' 'sudo -u nick bd -C /tmp/store close CHR-1'
check_target '/tmp/store' 'command bd -C /tmp/store close CHR-1'
check_target '/tmp/store' 'env FOO=bar bd -C /tmp/store close CHR-1'
check_target '/tmp/store' 'nice -n 10 bd -C /tmp/store close CHR-1'
check_target '/tmp/store' 'nice -n -5 bd -C /tmp/store close CHR-1'
check_target '/tmp/store' 'nice --adjustment 10 bd -C /tmp/store close CHR-1'
check_target '/tmp/store' 'nice --adjustment=10 bd -C /tmp/store close CHR-1'
# The historic spelling takes no letter: `nice -10 cmd` is `nice -n 10 cmd`,
# and GNU takes `--10` and `-+10` as well. Read as a bundle it held no letter
# either table knew, and the write behind it was missed outright.
check_target '/tmp/store' 'nice -10 bd -C /tmp/store close CHR-1'
check_target '/tmp/store' 'nice --10 bd -C /tmp/store close CHR-1'
check_target '/tmp/store' 'nice -+5 bd -C /tmp/store close CHR-1'
check sync 'nice -10 bd close CHR-1'
check skip 'nice -10 bd list'
check_target '/tmp/store' 'env -- bd -C /tmp/store close CHR-1'
# `--` ends `env`'s options and not its assignments: `env -- NAME=value cmd`
# still sets NAME and runs cmd. Taking the word after it as the command read
# the assignment as one, and a `bd` behind it as an argument nothing ran.
check_target '/tmp/store' 'env -- FOO=bar bd -C /tmp/store close CHR-1'
check_target "$STORE" "env -- BEADS_DIR=$STORE/.beads bd close CHR-1"
check_target "$STORE" "env -i -- A=1 BEADS_DIR=$STORE/.beads bd close CHR-1"
check_target "$STORE" "BEADS_DIR=$CD/other/.beads env -- BEADS_DIR=$STORE/.beads bd close CHR-1"
check_target '/tmp/store' 'env -- OUT=/tmp/store bash -c '"'"'bd -C "$OUT" close CHR-1'"'"''
check_target '' 'env -- FOO=bar echo bd -C /tmp/store close CHR-1'
check_target '' 'sudo echo bd -C /tmp/store close CHR-1'
# A flag that takes nothing is stepped over rather than treated as ambiguous.
# Giving up on one loses the write itself, not merely its target: nothing
# else in the invocation says a store was written.
check_target '/tmp/store' 'sudo -n bd -C /tmp/store close CHR-1'
check_target '/tmp/store' 'env -i bd -C /tmp/store close CHR-1'
check_target '/tmp/store' 'command -p bd -C /tmp/store close CHR-1'
check_target '/tmp/store' 'sudo -n -u nick bd -C /tmp/store close CHR-1'
check sync 'sudo -n bd close CHR-1'
# Bundled short flags count when every letter in the bundle takes nothing.
check_target '/tmp/store' 'sudo -nE bd -C /tmp/store close CHR-1'
# One unknown letter makes the whole bundle ambiguous: it may be the one
# that consumes the next word, which would put the command word elsewhere.
# The `bd` after it may still be the command, so the invocation is a write
# whose store is unknown. Given up in silence, it was a write nothing
# reported: no sync, no warning, and a store no later event would find.
check_unresolved 'sudo -nZ bd -C /tmp/store close CHR-1'
check_unresolved 'sudo -Z bd -C /tmp/store close CHR-1'
# ... wherever it stands among the words after, since the unknown letter may
# have taken the ones before it; and whatever the verb, since the words may
# not be `bd`'s own arguments at all.
check_unresolved 'sudo -Z echo bd close CHR-1'
check_unresolved 'sudo -Z bd list'
check_unresolved 'sudo -Z /usr/local/bin/bd close CHR-1'
# No later word names `bd`, a shell or `eval`, so nothing here can write; a
# computed command name is left alone here as everywhere else.
check skip 'sudo -Z ls -l'
check skip 'sudo -Z $CMD close CHR-1'
# `command -v` prints a path instead of running anything, so there is no
# invocation here to attribute a write to.
check skip 'command -v bd'
check skip 'command -V bd'
check skip 'command -pv bd close CHR-1'
# ... which is not the same as an unknown letter with a `bd` after it.
check_unresolved 'command -Z bd close CHR-1'
# A wrapper named by path runs the same program, and its options are its own.
# Looked up by full path the option tables had no entry for it, so the flag
# after it was read as the command word and the write was missed outright.
check_target '/tmp/store' '/usr/bin/env bd -C /tmp/store close CHR-1'
check sync '/usr/bin/env -i bd close CHR-1'
check_target '/tmp/store' '/usr/bin/env -i bd -C /tmp/store close CHR-1'
check_target '/tmp/store' '/usr/bin/sudo -u nick bd -C /tmp/store close CHR-1'
check_target '/tmp/store' 'nohup /usr/bin/env -i bd -C /tmp/store close CHR-1'
check_target '' '/usr/bin/env echo bd -C /tmp/store close CHR-1'
# The tables carry the BSD spellings as well as the GNU ones, the hook running
# under both: `env -P altpath` and `env -L user` are BSD's, `sudo -T timeout`
# is 1.9's. A letter missing from them is not merely unread -- it makes the
# bundle ambiguous and abandons the invocation, and the write inside it.
check_target '/tmp/store' 'env -P /usr/local/bin bd -C /tmp/store close CHR-1'
check_target '/tmp/store' 'env -P/usr/local/bin bd -C /tmp/store close CHR-1'
check_target '/tmp/store' 'env -iP /usr/local/bin bd -C /tmp/store close CHR-1'
check_target '/tmp/store' 'env -L nick bd -C /tmp/store close CHR-1'
check_target '/tmp/store' 'env -U nick bd -C /tmp/store close CHR-1'
check_target '/tmp/store' 'sudo -T 30 bd -C /tmp/store close CHR-1'
check_target '/tmp/store' 'sudo -T30 bd -C /tmp/store close CHR-1'
check_target '/tmp/store' 'sudo --command-timeout 30 bd -C /tmp/store close CHR-1'
check_target '/tmp/store' 'sudo --command-timeout=30 bd -C /tmp/store close CHR-1'
check_target '/tmp/store' 'sudo -nT 30 bd -C /tmp/store close CHR-1'
check_target '/tmp/store' 'sudo -t unconfined_t -r sysadm_r bd -C /tmp/store close CHR-1'
check_target '/tmp/store' 'sudo -R /jail bd -C /tmp/store close CHR-1'
check_target '/tmp/store' 'sudo -c staff bd -C /tmp/store close CHR-1'
check_target '/tmp/store' 'sudo -B bd -C /tmp/store close CHR-1'
check_target '/tmp/store' 'sudo -N -u nick bd -C /tmp/store close CHR-1'
check_target '/tmp/store' 'sudo --bell --no-update bd -C /tmp/store close CHR-1'
check_target '' 'env -P bd -C /tmp/store close CHR-1'
check_target '' 'sudo -T bd -C /tmp/store close CHR-1'
# GNU `env` takes a lone `-` as `-i` in its historical spelling. It is not a
# short bundle, so it fell to the bundle reader, which took it for an option
# it did not know and abandoned the invocation -- write and all.
check_target '/tmp/store' 'env - bd -C /tmp/store close CHR-1'
check sync 'env - bd close CHR-1'
check_target '/tmp/store' 'env - FOO=bar bd -C /tmp/store close CHR-1'
check_target "$STORE" "cd $STORE && BEADS_DIR=$CD/other/.beads env - bd close CHR-1"
check_target '/tmp/store' 'env - OUT=/tmp/store bash -c '"'"'bd -C "$OUT" close CHR-1'"'"''
check_unresolved 'export OUT=/tmp/store; env - bash -c '"'"'bd -C "$OUT" close CHR-1'"'"''
check_target "$STORE" "env - -C $STORE bd close CHR-1"
# Anywhere else a `-` is an operand, as it is to `bd` itself.
check_target '/tmp/store' 'bd -C /tmp/store import -'

# A short option's value may be attached to it. Matched as whole words those
# forms were in neither option table, so the flag was ambiguous and the whole
# invocation abandoned -- which loses the write itself, not merely its target.
check_target '/tmp/store' 'stdbuf -oL bd -C /tmp/store close CHR-1'
check_target '/tmp/store' 'nice -n10 bd -C /tmp/store close CHR-1'
check_target '/tmp/store' 'sudo -unick bd -C /tmp/store close CHR-1'
check_target '/tmp/store' 'stdbuf -oL -eL bd -C /tmp/store close CHR-1'
check_target '/tmp/store' 'stdbuf -o0 -i4096 bd -C /tmp/store close CHR-1'
check sync 'stdbuf -oL bd close CHR-1'
# The value may sit at the end of a bundle whose other letters take nothing.
check_target '/tmp/store' 'sudo -nunick bd -C /tmp/store close CHR-1'
# Past those options the command word is still read as it was, so a `bd` that
# is an argument rather than the command is not a write.
check_target '' 'stdbuf -oL echo bd -C /tmp/store close CHR-1'
# `env -a` / `--argv0` (coreutils 9.5) names what the command sees as its own
# argv[0]; the command itself is the word after that. Absent from the table,
# the short form was an unknown letter that abandoned the invocation and the
# separated long form named the value as the command, so neither the write nor
# its store was found. Only `--argv0=worker` happened to read correctly.
check_target '/tmp/store' 'env -a worker bd -C /tmp/store close CHR-1'
check_target '/tmp/store' 'env -aworker bd -C /tmp/store close CHR-1'
check_target '/tmp/store' 'env --argv0 worker bd -C /tmp/store close CHR-1'
check_target '/tmp/store' 'env --argv0=worker bd -C /tmp/store close CHR-1'
check_target '/tmp/store' 'env -i -a worker bd -C /tmp/store close CHR-1'
check sync 'env -a worker bd close CHR-1'
# The value is argv[0], not the command: a `bd` there names nothing that runs.
check_target '' 'env -a bd echo -C /tmp/store close CHR-1'
check skip 'env -a bd echo close CHR-1'
check_target '' 'env -a worker echo bd -C /tmp/store close CHR-1'
# `timeout` takes a duration between its options and the command: `timeout 30
# bd ...` runs bd. Not a wrapper at all, it was read as the command itself and
# the write was missed outright -- nothing else in the invocation says a store
# was written. `gtimeout` is the same program as Homebrew installs it.
check_target '/tmp/store' 'timeout 30 bd -C /tmp/store close CHR-1'
check_target '/tmp/store' 'timeout 1.5s bd -C /tmp/store close CHR-1'
check_target '/tmp/store' 'gtimeout 30 bd -C /tmp/store close CHR-1'
check_target '/tmp/store' '/usr/bin/timeout 30 bd -C /tmp/store close CHR-1'
check sync 'timeout 30 bd close CHR-1'
check sync 'sudo -n timeout 30 bd close CHR-1'
# Its options come before the duration, valued and value-less alike.
check_target '/tmp/store' 'timeout -k 5 30 bd -C /tmp/store close CHR-1'
check_target '/tmp/store' 'timeout -k5 -s KILL 30 bd -C /tmp/store close CHR-1'
check_target '/tmp/store' 'timeout --signal=KILL --foreground 30 bd -C /tmp/store close CHR-1'
check_target '/tmp/store' 'timeout -v -p -- 30 bd -C /tmp/store close CHR-1'
# The word after the duration is the command, whatever else follows it.
check_target '' 'timeout 30 echo bd -C /tmp/store close CHR-1'
check skip 'timeout 30 echo bd close CHR-1'
# With no duration `timeout` runs nothing, and with nothing after the duration
# there is nothing to run.
check skip 'timeout bd close CHR-1'
check skip 'timeout 30'
# An unknown letter is ambiguous here as for any wrapper.
check_unresolved 'timeout -Z 30 bd close CHR-1'

# An unknown letter is still ambiguous, whether it stands alone or opens a
# bundle: it may be the one that takes the value, which would put the command
# word elsewhere.
check_unresolved 'stdbuf -Zx bd -C /tmp/store close CHR-1'
check_unresolved 'nice -Z bd -C /tmp/store close CHR-1'
# `env -u` names the variable to unset, attached as readily as separated. Read
# as a whole word it matched no unset at all, so an inherited value answered for
# a name the command does not have -- naming a store it never opened, while the
# one it wrote went unregistered. The name must be in this process's environment
# for the case to mean anything: unset, it is unresolvable either way.
export CS_TEST_STORE=/tmp/inherited
check_target '/tmp/inherited/x' 'bash -c "bd -C \"\$CS_TEST_STORE/x\" close CHR-1"'
check_unresolved 'env -uCS_TEST_STORE bash -c "bd -C \"\$CS_TEST_STORE/x\" close CHR-1"'
check_target '/tmp/store' 'env -uFOO bd -C /tmp/store close CHR-1'
# `-i` among the letters still clears the environment, so a name it does not
# carry is unset in the child however this process answers it.
check_unresolved 'env -iuFOO bash -c "bd -C \"\$CS_TEST_STORE/x\" close CHR-1"'
# `exec -c` clears it the same way, which reading the flag as an ordinary
# value-less one did not: the inherited value answered, naming a store the
# command never opened while the one it wrote went unregistered.
check_unresolved 'exec -c bash -c "bd -C \"\$CS_TEST_STORE/x\" close CHR-1"'
check_unresolved 'exec -lc bash -c "bd -C \"\$CS_TEST_STORE/x\" close CHR-1"'
# The other two do not, `-a` naming the command and `-l` its argv[0] dash.
check_target '/tmp/inherited/x' 'exec bash -c "bd -C \"\$CS_TEST_STORE/x\" close CHR-1"'
check_target '/tmp/inherited/x' 'exec -l bash -c "bd -C \"\$CS_TEST_STORE/x\" close CHR-1"'
unset CS_TEST_STORE

# --- a wrapper that runs the command elsewhere ---------------------------
# `env -C` and `sudo -D` change the directory the command runs in, and which
# store `bd` selects turns on that directory. Stepped over as an opaque option
# value, the store above the launch directory was reported instead -- committed
# and registered, while the one the write opened went unsynced.
check_target "$STORE" "env -C $STORE bd close CHR-1"
check_target "$STORE" "env --chdir=$STORE bd close CHR-1"
check_target "$STORE" "env --chdir $STORE bd close CHR-1"
check_target "$STORE" "env -C$STORE bd close CHR-1"
# Under `sudo` the walk cannot answer: what reaches the child's environment is
# decided by a policy on disk, so BEADS_DIR -- which outranks the walk -- is
# unknowable and the store with it. A `-C` of its own names one outright, and
# that is where the chdir shows.
check_target "$STORE" "sudo -D $STORE bd -C sub/deeper close CHR-1"
check_target "$STORE" "sudo --chdir=$STORE bd -C sub/deeper close CHR-1"
check_unresolved "sudo -D $STORE bd close CHR-1"
# The directory may end a bundle whose other letters take nothing. `-i` among
# them clears the environment, which unsets BEADS_DIR rather than putting it in
# doubt as `sudo` does: the walk from the directory answers, and it answers
# with the same store either way.
check_target "$STORE" "env -vC$STORE bd close CHR-1"
check_target "$STORE" "env -iC$STORE bd close CHR-1"
check_target "$STORE" "sudo -nD$STORE bd -C sub/deeper close CHR-1"
# A relative `-C` resolves against the cwd in force before it, and a second
# against the first: the wrapper's chdir calls run in order.
check_target "$STORE" "cd $CD && env -C repo bd close CHR-1"
check_target "$STORE" "env -C $CD -C repo bd close CHR-1"
# A `-C` of its own is where `bd` starts looking, and it starts from wherever
# the wrapper put it.
check_target "$STORE" "env -C $STORE bd -C sub/deeper close CHR-1"
check_target "$STORE/nested/inner" "env -C $STORE bd -C nested/inner close CHR-1"
# The directory reaches a shell wrapper's script and an `env -S` string alike,
# both being commands this wrapper runs.
check_target "$STORE" "env -C $STORE bash -c 'bd close CHR-1'"
check_target "$STORE" "env -C $STORE -S 'bd close CHR-1'"
# A directory that is no directory now was none then either, and the wrapper
# then runs no command at all. Reported unknowable rather than walked up from:
# named under a store, the walk finds one this command never opened, which is
# the answer worse than none.
check_unresolved "env -C $STORE/nosuch bd close CHR-1"
check_unresolved "env -C $CD/nosuch bd close CHR-1"
check_unresolved 'env -C $(pwd) bd close CHR-1'
check_unresolved 'env -C "" bd close CHR-1'
# The directory it names is a word of its own, so a tilde opening it is an
# expansion -- read literally it is a relative path naming another directory.
# Attached to the flag it is not, the shell expanding one only at a word's start.
check_target "$STORE" "HOME=$CD; env -C ~/repo bd close CHR-1"
check_unresolved "HOME=$CD; env -C~/repo bd close CHR-1"
# Past the chdir the command word is read as it was, so a `bd` that is an
# argument is still not a write, and a read-only verb is still read-only.
check_target '' "env -C $STORE echo bd close CHR-1"
check skip "env -C $STORE bd list"
# An unknown letter may be the chdir flag carrying its directory attached, so
# where the command runs cannot be read. The wrapper reader gives up on such a
# bundle outright, which reports no write at all.
check_target '' "env -Zx -C $STORE bd close CHR-1"
# A wrapper with no chdir option leaves the directory alone.
check_target "$STORE" "cd $STORE && stdbuf -oL bd close CHR-1"
check_target "$STORE" "stdbuf -oL env -C $STORE bd close CHR-1"
# The change dies with the command, as a subshell's does: it is the wrapper
# process that moved, not this shell.
check_target "$STORE $BASE/store" \
  "env -C $STORE bd close CHR-1; bd -C store close CHR-2"

# --- `env -S` -----------------------------------------------------------
# `-S` splits its operand into the command and its arguments rather than
# consuming it as an opaque value, so the words are inside the string and no
# argument of the invocation names them. Stepping over it found no command at
# all: the write was reported by nothing, and for an external target that is
# the worst outcome -- the roots sync and the store is never registered.
check_target '/tmp/store' 'env -S "bd -C /tmp/store close CHR-1"'
check_target '/tmp/store' 'env --split-string "bd -C /tmp/store close CHR-1"'
check_target '/tmp/store' 'env --split-string="bd -C /tmp/store close CHR-1"'
check_target '/tmp/store' 'env -S"bd -C /tmp/store close CHR-1"'
check_target '/tmp/store' '/usr/bin/env -S "bd -C /tmp/store close CHR-1"'
# `-S` may end a bundle whose other letters take nothing.
check_target '/tmp/store' 'env -iS "bd -C /tmp/store close CHR-1"'
# The options before it are still its own.
check_target '/tmp/store' 'env -u FOO -S "bd -C /tmp/store close CHR-1"'
check sync 'env -S "bd close CHR-1"'
# The string is argv and not shell text: `-S` splits it as `env` does, and
# nothing in it is syntax. `cd` names a program that does not exist, so
# nothing runs; and a `$OUT` without braces is an error `env` stops on, on
# GNU and BSD alike. Read as script, the first entered a directory and the
# second read a variable, and the scan reported writes `env` never ran.
check_target '' "env -S \"cd $CD/other && bd -C store close CHR-1\""
check skip 'env OUT=/tmp/store -S "bd -C \"\$OUT\" close CHR-1"'
# `\_` is a separator, and inside double quotes a space; `#` opening a word
# comments out the rest; `\c` ends the string. Read as script, `\_` was
# part of one word that was not `bd`, and the write was missed outright.
check_target '/tmp/store' 'env -S '"'"'bd\_-C\_/tmp/store\_close\_CHR-1'"'"''
check_target '/tmp/a b' 'env -S '"'"'bd -C "/tmp/a\_b" close CHR-1'"'"''
check_target '/tmp/store' 'env -S "bd -C /tmp/store close CHR-1 # a note"'
check_target "$STORE" "cd $STORE; env -S 'bd close CHR-1 #-C /tmp/other'"
check_target '/tmp/store#x' 'env -S "bd -C /tmp/store#x close CHR-1"'
check_target '/tmp/store' 'env -S '"'"'bd -C /tmp/store close CHR-1\c list'"'"''
# Quotes group and the escapes `env` knows are decoded; single quotes keep
# everything but `\'"'"'` and `\\`.
check_target '/tmp/a b' 'env -S "bd -C '"'"'/tmp/a b'"'"' close CHR-1"'
check_target '/tmp/a b' 'env -S '"'"'bd -C "/tmp/a b" close CHR-1'"'"''
check_target "/tmp/a'b" 'env -S "bd -C '"'"'/tmp/a\\'"'"'b'"'"' close CHR-1"'
check_target '/tmp/a#b' 'env -S "bd -C /tmp/a\\#b close CHR-1"'
# An escape `env` does not know, or an unclosed quote, is an error on which
# it runs nothing.
check skip 'env -S "bd -C /tmp/store close CHR-1 \\q"'
check skip 'env -S "bd -C /tmp/store close '"'"'CHR-1"'
# `${NAME}` is expanded by `env` from the environment it was given, so an
# exported name or a temporary prefix answers, and a shell variable that
# was never exported does not. Where `env`'s own options touch the name,
# GNU expands the value from before them and BSD from after, so it is
# unknowable rather than either.
check_target '/tmp/store' 'CS_W_STORE=/tmp/store env -S '"'"'bd -C ${CS_W_STORE} close CHR-1'"'"''
check_target '/tmp/store' 'export CS_W_STORE=/tmp/store; env -S '"'"'bd -C ${CS_W_STORE} close CHR-1'"'"''
check_unresolved 'CS_W_STORE=/tmp/store; env -S '"'"'bd -C ${CS_W_STORE} close CHR-1'"'"''
check_unresolved 'CS_W_STORE=/old env CS_W_STORE=/tmp/store -S '"'"'bd -C ${CS_W_STORE} close CHR-1'"'"''
check_unresolved 'CS_W_STORE=/tmp/store env -u CS_W_STORE -S '"'"'bd -C ${CS_W_STORE} close CHR-1'"'"''
check_unresolved 'CS_W_STORE=/tmp/store env -i -S '"'"'bd -C ${CS_W_STORE} close CHR-1'"'"''
# The words are `env`'s own arguments again, so an option or assignment
# among them is read as one.
check_target "$STORE" "env -S 'BEADS_DIR=$STORE/.beads bd close CHR-1'"
check_target "$STORE" "env -S '-C $STORE bd close CHR-1'"
check skip 'env -S "-u BEADS_DIR echo bd close CHR-1"'
# A read-only verb inside the string is still read-only.
check skip 'env -S "bd list"'
# A string this scan cannot read may write and there is no way to learn
# whether it does, so it counts as a write with no target -- the roots sync,
# which is the answer every other unreadable write gets.
check sync 'env -S "$CMD"'
check sync 'env -S'
# A bundle holding a letter that may take a value cannot say where `-S` is,
# so the invocation is abandoned as any ambiguous wrapper is -- and the string
# opens with `bd`, so it is a write whose store is unknown.
check_unresolved 'env -zS "bd -C /tmp/store close CHR-1"'
# The arguments after the string are the command's too: `env` appends them to
# the words the split made. Scanning the string alone found `bd -C` with nothing
# after it, so the write was reported without its target -- the roots synced
# while the external store went unregistered, which nothing later recovers.
check_target '/tmp/store' 'env -S "bd -C" /tmp/store close CHR-1'
check_target '/tmp/store' 'env -S "bd" -C /tmp/store close CHR-1'
# They are argv words and not script, so a character that would be syntax in
# the text being scanned is still one argument.
check_target '/tmp/a;b' 'env -S "bd -C" "/tmp/a;b" close CHR-1'
check_target '/tmp/a b' 'env -S "bd -C" "/tmp/a b" close CHR-1'
# A read-only verb completed by them is still read-only.
check skip 'env -S "bd" list'
# An operand that cannot be read leaves the command's words incomplete, which
# is the same fail-safe case as an unreadable string.
check sync 'env -S "bd -C" "$CS_SOMETHING_UNSET" close CHR-1'
check_unresolved 'env -S "bd -C" "$CS_SOMETHING_UNSET" close CHR-1'

# --- here-documents -----------------------------------------------------
# A body is data, not script. Scanning it as commands applies a `cd` the
# shell never ran, and the write after it resolves to a store the command
# never opened -- which is then neither pushed nor registered.
check_target "$BASE/store" 'cat <<EOF
cd /tmp/other
EOF
bd -C store close CHR-1'
# `<<-` strips leading tabs from the body and from the delimiter line.
check_target "$BASE/store" "$(printf 'cat <<-EOF\n\tcd /tmp/other\n\tEOF\nbd -C store close CHR-1')"
# Quoting the delimiter makes the body literal, which does not matter to a
# body whose text is skipped either way.
check_target "$BASE/store" 'cat <<"EOF"
cd /tmp/other
EOF
bd -C store close CHR-1'
# Two on one line take their bodies in order, so the second body is not
# read as script either.
check_target "$BASE/store" 'cat <<A <<B
aaa
A
cd /tmp/other
B
bd -C store close CHR-1'
# A `cd` before the here-document is script and does apply.
check_target "$CD/other/store" "cd $CD/other
cat <<EOF
x
EOF
bd -C store close CHR-1"
# A substitution in an unquoted body is not data: the shell expands the body
# and runs it, so the write inside one is a write, and its `-C` names a store
# no other part of the command mentions.
check_target '/tmp/store' 'cat <<EOF
$(bd -C /tmp/store close CHR-1)
EOF'
check sync 'cat <<EOF
$(bd close CHR-1)
EOF'
check skip 'cat <<EOF
$(bd list)
EOF'
# The older backtick form of substitution expands in a body just the same.
check_target '/tmp/store' 'cat <<EOF
`bd -C /tmp/store close CHR-1`
EOF'
check skip 'cat <<"EOF"
`bd close CHR-1`
EOF'
# Quoting the delimiter suppresses the expansion, so nothing in the body runs.
check skip 'cat <<"EOF"
$(bd close CHR-1)
EOF'
check skip "cat <<'EOF'
\$(bd close CHR-1)
EOF"
# The body is still not script: a `cd` in one is text, and only what a
# substitution runs counts.
check_target "$BASE/store" 'cat <<EOF
cd /tmp/other
$(echo x)
EOF
bd -C store close CHR-1'
# A substitution runs in a subshell, so what it changes dies with the body.
check_target "$BASE/store" "cat <<EOF
\$(cd $CD/other)
EOF
bd -C store close CHR-1"
# Each body is examined under its own delimiter's quoting.
check_target '/tmp/store' 'cat <<"A" <<B
$(bd close CHR-9)
A
$(bd -C /tmp/store close CHR-1)
B'
# An unterminated body runs to the end of the input, as the shell reads it.
check skip 'cat <<EOF
bd close CHR-1'
# `<` and `<<<` carry no body and must not swallow what follows.
check_target '/tmp/store' 'bd -C /tmp/store close CHR-1 < input'
check_target '/tmp/store' 'bd -C /tmp/store close CHR-1 <<< here'
# The write itself may own the here-document.
check_target '/tmp/store' 'bd -C /tmp/store close CHR-1 <<EOF
x
EOF'

# --- assignment builtins ------------------------------------------------
# `export NAME=value` outlives its command, unlike a temporary prefix, so a
# later `-C "$NAME"` addresses the store it named. Reading the hook's own
# inherited value instead loses the store the write actually opened.
export CS_TEST_STORE=/tmp/inherited
check_target '/tmp/store' 'export CS_TEST_STORE=/tmp/store; bd -C "$CS_TEST_STORE" close CHR-1'
check_target '/tmp/store' 'readonly CS_TEST_STORE=/tmp/store; bd -C "$CS_TEST_STORE" close CHR-1'
check_target '/tmp/store' 'declare CS_TEST_STORE=/tmp/store; bd -C "$CS_TEST_STORE" close CHR-1'
check_target '/tmp/y' 'export CS_TEST_STORE=/tmp/x CS_OTHER=/tmp/y; bd -C "$CS_OTHER" close CHR-1'
# Only the operands that are assignments count: `export NAME` exports a name
# without changing its value, and a flag is neither.
check_target '/tmp/inherited' 'export CS_TEST_STORE; bd -C "$CS_TEST_STORE" close CHR-1'
check_target '/tmp/store' 'export -p CS_TEST_STORE=/tmp/store; bd -C "$CS_TEST_STORE" close CHR-1'
# One the shell may never reach leaves the name unknown, as a plain conditional
# assignment does: neither it nor the earlier value speaks for what is in
# effect afterwards.
check_unresolved 'false && export CS_TEST_STORE=/tmp/store; bd -C "$CS_TEST_STORE" close CHR-1'
check_unresolved 'true && declare CS_TEST_STORE=/tmp/store; bd -C "$CS_TEST_STORE" close CHR-1'
check_target '/tmp/inherited' 'true && export CS_OTHER=/tmp/store; bd -C "$CS_TEST_STORE" close CHR-1'
# A substitution in any operand runs whatever the reachability, the operands
# that assign nothing included: `export $(bd close X)` runs the write.
check sync 'export $(bd close CHR-1)'
check sync 'false && export CS_TEST_STORE=$(bd close CHR-1)'
check sync 'declare -x $(bd close CHR-1)'
# The word `export` in an argument is a string, not a builtin.
check_target '/tmp/inherited' 'echo export CS_TEST_STORE=/tmp/store; bd -C "$CS_TEST_STORE" close CHR-1'
# A substitution in the value travels with it: the path is no more knowable
# once it has been through a variable than it was in the word.
check_unresolved 'export CS_TEST_STORE=$(pwd)/store; bd -C "$CS_TEST_STORE" close CHR-1'
unset CS_TEST_STORE CS_OTHER

# --- builtins that assign without an `=` --------------------------------
# An arithmetic assignment, `let`, `read`, `printf -v`, `getopts`, `mapfile`
# and a `source` all write a name with no `NAME=value` in the text. Reading
# past them kept the value from before, and `X=/tmp/a; read X; bd -C "$X"`
# named a store the shell was never told. The name is unknown after each,
# not gone -- what it holds is something this scan cannot read.
check_unresolved 'CS_V=/tmp/a; ((CS_V=1)); bd -C "$CS_V" close CHR-1'
check_unresolved 'CS_V=/tmp/a; : $((CS_V=1)); bd -C "$CS_V" close CHR-1'
check_unresolved 'CS_V=/tmp/a; : $((CS_V += 1)); bd -C "$CS_V" close CHR-1'
check_unresolved 'CS_V=/tmp/a; : $((CS_V++)); bd -C "$CS_V" close CHR-1'
check_unresolved 'CS_V=/tmp/a; let CS_V=1; bd -C "$CS_V" close CHR-1'
check_unresolved 'CS_V=/tmp/a; for ((CS_V=0; CS_V<1; CS_V++)); do :; done; bd -C "$CS_V" close CHR-1'
check_unresolved 'CS_V=/tmp/a; read CS_V; bd -C "$CS_V" close CHR-1'
check_unresolved 'CS_V=/tmp/a; read -r CS_W CS_V </dev/null; bd -C "$CS_V" close CHR-1'
check_unresolved 'CS_V=/tmp/a; printf -v CS_V %s /tmp/b; bd -C "$CS_V" close CHR-1'
check_unresolved 'CS_V=/tmp/a; getopts a: CS_V; bd -C "$CS_V" close CHR-1'
check_unresolved 'CS_V=/tmp/a; mapfile CS_V; bd -C "$CS_V" close CHR-1'
# A sourced file may assign anything, so every name is in doubt after it.
check_unresolved 'CS_V=/tmp/a; source ./lib.sh; bd -C "$CS_V" close CHR-1'
check_unresolved 'CS_V=/tmp/a; . ./lib.sh; bd -C "$CS_V" close CHR-1'
# Only the name written is touched: an arithmetic read, another name, or a
# `printf` to stdout leaves the value standing.
check_target '/tmp/a' 'CS_V=/tmp/a; : $((CS_W = 1)); bd -C "$CS_V" close CHR-1'
check_target '/tmp/a' 'CS_V=/tmp/a; ((CS_W=1)); bd -C "$CS_V" close CHR-1'
check_target '/tmp/a' 'CS_V=/tmp/a; echo $((1 + 2)); bd -C "$CS_V" close CHR-1'
check_target '/tmp/a' 'CS_V=/tmp/a; read CS_W; bd -C "$CS_V" close CHR-1'
check_target '/tmp/a' 'CS_V=/tmp/a; printf %s CS_V; bd -C "$CS_V" close CHR-1'
# One that may not have run leaves the name unknown as any conditional
# assignment does.
check_unresolved 'CS_V=/tmp/a; false && ((CS_V=1)); bd -C "$CS_V" close CHR-1'
# The write inside any of them still runs.
check sync 'read CS_V < <(bd close CHR-1)'
check sync '(( $(bd close CHR-1 | wc -c) ))'
check sync 'let CS_V=$(bd close CHR-1 | wc -c)'

# --- bd's own global options --------------------------------------------
# A global option's value is not the verb. Reading it as one lets a value
# that happens to name a read-only verb suppress the write behind it.
check sync 'bd --actor list close CHR-1'
check sync 'bd --db /tmp/x.db close CHR-1'
check sync 'bd --dolt-auto-commit off close CHR-1'
check sync 'bd --actor show create "x"'
# The value carried in the word leaves nothing after it to step over.
check sync 'bd --actor=list close CHR-1'
# A value-less global does not consume the verb.
check skip 'bd --json list'
check skip 'bd --quiet --readonly list'
check sync 'bd --json close CHR-1'
# Nor does the value hide the store.
check_target '/tmp/store' 'bd --actor list -C /tmp/store close CHR-1'
check_target '/tmp/store' 'bd --db /tmp/x.db -C /tmp/store close CHR-1'
# A value that looks like a path is not a `-C` target: it names no store.
check_target '' 'bd --db /tmp/store close CHR-1'
check_target '/tmp/store' 'bd --directory /tmp/store close CHR-1'

# --- redirections --------------------------------------------------------
# A redirection is neither an argument nor a command boundary. Welding it to
# the word hides `bd` behind `bd>log`; reading it as a boundary hides `bd`
# behind a separator it never had. Either way the write goes unseen.
check sync 'bd close CHR-1 >/tmp/bd.log'
check sync 'bd>/tmp/bd.log close CHR-1'
check sync '>/tmp/bd.log bd close CHR-1'
check sync 'bd close CHR-1 2>/dev/null'
check sync 'bd close CHR-1 &>/dev/null'
check sync 'bd close CHR-1 >>log 2>&1'
check sync 'bd close CHR-1 <input'
# The verb still governs, so a read behind a redirection is still a read.
check skip 'bd list >/tmp/bd.log'
check skip '>/tmp/bd.log bd list'
# The file name is not an argument, so a `-C` in front of one is not a
# target and a verb after one is still the verb.
check_target '/tmp/store' 'bd -C /tmp/store close CHR-1 >log'
check_target '/tmp/store' 'bd >log -C /tmp/store close CHR-1'
# The shell removes the redirection from argv wherever it stands, so `-C`
# here really does take `close`, odd as the command looks.
check_target "$BASE/close" 'bd -C >log close CHR-1'
# A digit touching the operator is a file descriptor, not an argument, but
# one standing alone is an argument like any other.
check sync 'bd create 2'
check_target '/tmp/store' 'bd -C /tmp/store close CHR-1 2>/dev/null'
# A substitution in the file name still runs, and a write inside one counts.
check sync 'echo x > "$(bd create y)"'
# A redirection does not end the list either side of it.
check_target "$CD/other/store" "cd $CD/other >log; bd -C store close CHR-1"

# --- subshells ----------------------------------------------------------
# A `cd` inside `( ... )` or `$( ... )` dies with the subshell, so the
# command after it runs where the shell already was.
check_target "$BASE/store" "(cd $CD/other); bd -C store close CHR-1"
check_target "$BASE/store" "echo \"\$(cd $CD/other)\"; bd -C store close CHR-1"
# Inside the subshell it does apply, and a write there is still a write.
check_target "$CD/other/store" "(cd $CD/other; bd -C store close CHR-1)"
# So does every command of a pipeline, and a backgrounded one. Persisting
# what they change resolves the write after them under a directory the real
# shell never entered.
check_target "$BASE/store" "cd $CD/other & bd -C store close CHR-1"
check_target "$BASE/store" "cd $CD/other | bd -C store close CHR-1"
check_target "$BASE/store" "cd $CD/other | true; bd -C store close CHR-1"
check_target "$BASE/store" "true | cd $CD/other; bd -C store close CHR-1"
# An assignment dies with the pipeline too, leaving the name with no value
# anywhere, which is unresolvable rather than relative.
check_unresolved 'CS_PIPE_STORE=/tmp/decoy | true; bd -C "$CS_PIPE_STORE" close CHR-1'
# The write itself is still found inside one, under the cwd in force there.
check sync "true | bd close CHR-1"
check_target "$CD/other/store" "cd $CD/other; true | bd -C store close CHR-1"
# A brace group is not a subshell: it runs in this shell, and its `cd` and
# assignments reach the command after it. One nothing made conditional is as
# certain as the statements around it. Scanned in a frame, its assignment was
# restored on the way out and `OUT=/old; { OUT=/real; }; bd -C "$OUT"` named
# a store the command never opened.
check_target "$CD/other/store" "{ cd $CD/other; }
bd -C store close CHR-1"
check_target '/real' 'OUT=/old; { OUT=/real; }; bd -C "$OUT" close CHR-1'
check_target '/real' 'OUT=/old; { { OUT=/real; }; }; bd -C "$OUT" close CHR-1'
# A conditional group may not have run at all, so what it changes is unknown
# afterwards -- neither restored nor kept -- and so is its cwd.
check_unresolved 'OUT=/old; true && { OUT=/real; }; bd -C "$OUT" close CHR-1'
check_unresolved "true && { cd $CD/other; }
bd -C store close CHR-1"
# The body of an `if`, a loop or a function is the same case: a name it
# assigns is unknown after it, where it used to read as the value from before.
check_unresolved 'OUT=/old; if true; then OUT=/real; fi; bd -C "$OUT" close CHR-1'
check_unresolved 'OUT=/old; for x in 1; do OUT=/real; done; bd -C "$OUT" close CHR-1'
check_unresolved 'OUT=/old; cs_f() { OUT=/real; }; cs_f; bd -C "$OUT" close CHR-1'
check_unresolved 'OUT=/old; eval "OUT=/real"; bd -C "$OUT" close CHR-1'
scan_command 'OUT=/old; if true; then OUT=/real; fi; bd -C "$OUT" close CHR-1' "$BASE"
[ "$SCAN_UNRESOLVED" -eq 1 ] && PASS=$((PASS + 1)) || {
  FAIL=$((FAIL + 1))
  printf 'FAIL unresolved want=1 got=%s branch assignment\n' "$SCAN_UNRESOLVED"
}
# A name the body leaves alone keeps its value across it.
check_target '/tmp/store' 'OUT=/tmp/store; if true; then OTHER=/x; fi; bd -C "$OUT" close CHR-1'
check_target '/tmp/store' 'OUT=/tmp/store; cs_f() { OTHER=/x; }; cs_f; bd -C "$OUT" close CHR-1'

# --- shell wrappers ------------------------------------------------------
# A shell runs its `-c` operand as script, so the write inside it is a write
# by this command -- and its `-C` names a store nothing else here mentions,
# which SessionEnd would otherwise never revisit.
check sync 'bash -c "bd close CHR-1"'
check_target '/tmp/store' 'bash -c "bd -C /tmp/store close CHR-1"'
check_target '/tmp/store' 'sh -c "bd -C /tmp/store close CHR-1"'
check_target '/tmp/store' 'zsh -c "bd -C /tmp/store close CHR-1"'
check_target '/tmp/store' '/bin/bash -c "bd -C /tmp/store close CHR-1"'
check skip 'bash -c "bd list"'
# Single quotes around the script keep the shell from expanding it, but the
# inner shell expands it all the same.
check_target '/tmp/store' "bash -c 'bd -C /tmp/store close CHR-1'"
# The script is found past the shell's own options, whether they take a
# value or not.
check_target '/tmp/store' 'bash -x -c "bd -C /tmp/store close CHR-1"'
check_target '/tmp/store' 'bash -o pipefail -c "bd -C /tmp/store close CHR-1"'
check_target '/tmp/store' 'bash -c -x "bd -C /tmp/store close CHR-1"'
# A flag the scan cannot delimit may or may not take the word after it, so
# the operand it would name is a guess and the invocation is left alone.
check skip 'bash -Q "bd -C /tmp/store close CHR-1"'
# A long option is one name, not a bundle of letters. Read letter by letter,
# the first `-` inside `--noprofile` was a flag the scan did not know, and
# `bash --noprofile --norc -c '...'` was left alone with the write inside it.
# Only the long options that certainly take nothing are known; an unknown one
# may take the word after it and still abandons the invocation.
check_target '/tmp/store' "bash --noprofile --norc -c 'bd -C /tmp/store close CHR-1'"
check_target '/tmp/store' "bash --posix -c 'bd -C /tmp/store close CHR-1'"
check_target '/tmp/store' "bash --login -c 'bd -C /tmp/store close CHR-1'"
check_target '/tmp/store' "bash --norc -x -c 'bd -C /tmp/store close CHR-1'"
check_target '/tmp/store' "bash --rcfile /tmp/rc -c 'bd -C /tmp/store close CHR-1'"
check_target '/tmp/store' "bash --rcfile=/tmp/rc -c 'bd -C /tmp/store close CHR-1'"
check_target '/tmp/store' "bash --init-file=/tmp/rc -c 'bd -C /tmp/store close CHR-1'"
check_target '/tmp/store' "zsh --no-rcs --no-globalrcs -c 'bd -C /tmp/store close CHR-1'"
check_target '/tmp/store' "zsh --emulate sh -c 'bd -C /tmp/store close CHR-1'"
check sync "bash --noprofile --norc -c 'bd close CHR-1'"
check skip "bash --noprofile --norc -c 'bd list'"
check skip "bash --nosuchoption -c 'bd -C /tmp/store close CHR-1'"
check skip "bash --help -c 'bd -C /tmp/store close CHR-1'"
check skip "bash --version -c 'bd -C /tmp/store close CHR-1'"

# An operand this scan cannot read is the fail-safe case, as it is for `eval`
# and `env -S`: the shell runs that text whatever it says. Read as no write,
# a `bd -C /external ...` inside it left the roots unsynced as well as the
# store, and nothing later could find either. It is a write, and it is also
# counted as a target that could not be named: the text may carry a `-C`, and
# counting the write alone synced the roots in silence where every other
# unreadable target makes the hook say a store may have gone unsynced.
check sync 'bash -c "$CS_SOMETHING_UNSET"'
check sync 'sh -c "$(generate-command)"'
check sync 'bash -c -x "$CS_SOMETHING_UNSET"'
check_unresolved 'bash -c "$CS_SOMETHING_UNSET"'
for unreadable in 'bash -c "$CS_SOMETHING_UNSET"' 'sh -c "$(generate-command)"' \
  'eval "$CS_SOMETHING_UNSET"' 'env -S "$CS_SOMETHING_UNSET"' \
  'env -S "bd -C" "$CS_SOMETHING_UNSET" close CHR-1'; do
  scan_command "$unreadable" "$BASE"
  [ "$SCAN_UNRESOLVED" -eq 1 ] && PASS=$((PASS + 1)) || {
    FAIL=$((FAIL + 1))
    printf 'FAIL unresolved want=1 got=%s %s\n' "$SCAN_UNRESOLVED" "$unreadable"
  }
done
# A readable script is not: its targets are named or counted on their own.
scan_command 'bash -c "bd -C /tmp/store close CHR-1"' "$BASE"
[ "$SCAN_UNRESOLVED" -eq 0 ] && PASS=$((PASS + 1)) || {
  FAIL=$((FAIL + 1))
  printf 'FAIL unresolved want=0 got=%s readable script\n' "$SCAN_UNRESOLVED"
}
# Without `-c` the operand is a file this scan cannot read.
check skip 'bash script.sh'
check skip 'bash -x script.sh'
# ... and an unreadable operand is only the script once `-c` has been seen.
check skip 'bash "$CS_SOMETHING_UNSET"'
check skip 'bash -x "$CS_SOMETHING_UNSET"'
# The script runs in a process of its own, so what it changes does not reach
# the command after it.
check_target "$BASE/store" "bash -c \"cd $CD/other\"; bd -C store close CHR-1"
# A wrapper in front of the shell is still stepped over, and so are the
# wrapper's own options. Advancing one word at a time stopped at the first
# option and named it as the command word, which is no shell, so the script
# went unscanned and the store it opens was reported by nothing.
check_target '/tmp/store' 'sudo bash -c "bd -C /tmp/store close CHR-1"'
check_target '/tmp/store' 'env -u FOO bash -c "bd -C /tmp/store close CHR-1"'
check_target '/tmp/store' 'sudo -u nick bash -c "bd -C /tmp/store close CHR-1"'
check_target '/tmp/store' 'env -i bash -c "bd -C /tmp/store close CHR-1"'
check_target '/tmp/store' 'sudo -nE bash -c "bd -C /tmp/store close CHR-1"'
# A flag neither option table knows may or may not take the word after it,
# so where the wrapper's arguments stop is unknown and so is the command
# word. The walk stops at the wrapper rather than guessing -- but a shell
# among the words after may run the string, so the invocation is a write
# whose store is unknown rather than nothing.
check_unresolved 'sudo -Z bash -c "bd -C /tmp/store close CHR-1"'
# The word `bash` as an argument is a string, not a shell.
check skip 'echo bash -c "bd close CHR-1"'
# A temporary assignment in front of the shell speaks for none of this
# command's own words, but it does reach the child's environment, and the
# child expands its script with it in place. Discarding it read the hook's
# own inherited value and left the store the write opened unregistered.
check_target '/tmp/store' 'CS_W_STORE=/tmp/store bash -c '"'"'bd -C "$CS_W_STORE" close CHR-1'"'"''
check_target '/tmp/store' 'CS_W_STORE=/tmp/store nohup bash -c '"'"'bd -C "$CS_W_STORE" close CHR-1'"'"''
# It reaches the child through the wrappers in the shell's order: a wrapper's
# own assignment lands on top of it, and a wrapper that clears the
# environment -- or filters it by a policy this scan cannot read, as `sudo`
# does -- drops it with the rest. Seeded through regardless, the script read
# a value the child never had and named a store the command never opened.
check_target '/tmp/store' 'CS_W_STORE=/old env CS_W_STORE=/tmp/store bash -c '"'"'bd -C "$CS_W_STORE" close CHR-1'"'"''
# `env -S` expands `${NAME}` itself, from the environment it was given --
# so the prefix answers -- while a `bash -c` among the words it made sees
# the assignment `env` was given on top of it, as any child of `env` does.
check_target '/old' 'CS_W_STORE=/old env -S '"'"'bd -C ${CS_W_STORE} close CHR-1'"'"''
check_target '/tmp/store' 'CS_W_STORE=/old env -S '"'"'CS_W_STORE=/tmp/store bash -c "bd -C \"\$CS_W_STORE\" close CHR-1"'"'"''
check_unresolved 'CS_W_STORE=/tmp/store env -i bash -c '"'"'bd -C "$CS_W_STORE" close CHR-1'"'"''
check_unresolved 'CS_W_STORE=/tmp/store env -u CS_W_STORE bash -c '"'"'bd -C "$CS_W_STORE" close CHR-1'"'"''
check_unresolved 'CS_W_STORE=/tmp/store sudo bash -c '"'"'bd -C "$CS_W_STORE" close CHR-1'"'"''
check sync 'CS_W_STORE=/tmp/store sudo bash -c '"'"'bd -C "$CS_W_STORE" close CHR-1'"'"''
# ... while an assignment `env -i` carries itself is the environment.
check_target '/tmp/store' 'CS_W_STORE=/old env -i CS_W_STORE=/tmp/store bash -c '"'"'bd -C "$CS_W_STORE" close CHR-1'"'"''
# It reaches that shell only. The value dies with the child, so a later
# command sees the name with no value anywhere.
check_unresolved 'CS_W_STORE=/tmp/store bash -c '"'"'true'"'"'; bd -C "$CS_W_STORE" close CHR-1'
# And it still says nothing about the argv of the command carrying it, which
# the shell expanded before applying it.
check_unresolved 'CS_W_STORE=/tmp/decoy bd -C "$CS_W_STORE" close CHR-1'
# The prefix is part of the command: if the command runs at all it runs with
# it, whatever made the command conditional. Skipped on a conditional path, the
# script was read against the value from before it -- a store the command never
# opened.
check_target '/tmp/store' 'true && CS_W_STORE=/tmp/store bash -c '"'"'bd -C "$CS_W_STORE" close CHR-1'"'"''
check_target '/tmp/store' 'CS_W_STORE=/old; true && CS_W_STORE=/tmp/store bash -c '"'"'bd -C "$CS_W_STORE" close CHR-1'"'"''
check_target '/tmp/store' 'true && CS_W_STORE=/tmp/store env -S '"'"'bd -C ${CS_W_STORE} close CHR-1'"'"''
check_target '/tmp/store' 'if true; then CS_W_STORE=/tmp/store sh -c '"'"'bd -C "$CS_W_STORE" close CHR-1'"'"'; fi'

# --- function definitions -------------------------------------------------
# A definition stores its body rather than running it, so a `cd` in one has
# not happened when the command after it runs. Reading the body as script
# made the cwd unknown and dropped the real external target from the sync
# set and the registry.
check_target "$BASE/store" "cs_f() { cd $CD/other; }; bd -C store close CHR-1"
check_target "$BASE/store" "cs_f() {
  cd $CD/other
}
bd -C store close CHR-1"
# An assignment in one has not happened either.
check_unresolved 'cs_f() { CS_FN_STORE=/tmp/decoy; }; bd -C "$CS_FN_STORE" close CHR-1'
# The write inside a body is still a write: the function may be called, and
# dropping it strands the store it opens.
check sync 'cs_f() { bd close CHR-1; }'
check_target '/tmp/store' 'cs_f() { bd -C /tmp/store close CHR-1; }'
check skip 'cs_f() { bd list; }'
# The `function` keyword form, with and without the parentheses.
check_target "$BASE/store" "function cs_f() { cd $CD/other; }; bd -C store close CHR-1"
check_target "$BASE/store" "function cs_f { cd $CD/other; }; bd -C store close CHR-1"
# A body of the subshell form dies with its subshell, as any subshell does.
check_target "$BASE/store" "cs_f() ( cd $CD/other ); bd -C store close CHR-1"
# Nested braces inside a body do not end it early.
check_target "$BASE/store" "cs_f() { if true; then { cd $CD/other; }; fi; }
bd -C store close CHR-1"
# A body runs wherever its caller stands, which the definition does not say,
# so a relative store named inside one resolves against nothing. An absolute
# `cd` in the same body does say where the write after it lands, and one to
# an absolute path is knowable whatever the caller's directory was.
check_unresolved 'cs_f() { bd -C store close CHR-1; }'
check_target "$CD/other/store" "cs_f() { cd $CD/other; bd -C store close CHR-1; }"
check_target "$CD/other/store" "cs_f() { bd -C $CD/other/store close CHR-1; }"
# A definition the text leaves unclosed still owns the rest of it, so what
# follows is body rather than script the shell runs now.
check_target "$CD/other/store" "cs_f() { cd $CD/other
bd -C store close CHR-1"

# --- function calls -------------------------------------------------------
# A call runs the body where the caller stands, which is the only place a
# relative store named inside one can be resolved from. Without the call site
# the target was reported by nothing: the definition cannot resolve it, so the
# write went to a store that was neither pushed nor registered.
check_target "$BASE/store" 'cs_f() { bd -C store close CHR-1; }; cs_f'
check_target "$CD/base/store" "cs_f() { bd -C store close CHR-1; }
cd $CD/base
cs_f"
# The body's own `cd` still governs inside it, over the caller's directory.
check_target "$CD/other/store" "cs_f() { cd $CD/other; bd -C store close CHR-1; }
cd $CD/base
cs_f"
# A read-only body is read-only however it is reached.
check skip 'cs_f() { bd list; }; cs_f'
# The store is named once, not once per pass over the body.
check_target '/tmp/store' 'cs_f() { bd -C /tmp/store close CHR-1; }; cs_f'
check_target '/tmp/store' 'cs_f() { bd -C /tmp/store close CHR-1; }; cs_f; cs_f'
# Whether a body ran to the end, and which of its branches it took, is not
# inferred, so the cwd after a call whose body acts on it is unknown -- as it
# is after any compound command that does. A `cd` anywhere in the body counts,
# reached or not, since where the body stopped is what is not inferred.
check_unresolved "cs_f() { cd $CD/other; }
cd $CD/base
cs_f
bd -C store close CHR-1"
check_unresolved "cs_f() { return; cd $CD/other; }
cd $CD/base
cs_f
bd -C store close CHR-1"
check_unresolved "cs_f() { cd $CD/base; }
cd $CD/base
cs_f
bd -C store close CHR-1"
# A body that never touches the cwd leaves the caller's standing. Giving it
# up regardless left a write launched from an external store unregistered
# for a call that could not have moved the shell.
check_target "$CD/base/store" "cs_f() { :; }
cd $CD/base
cs_f
bd -C store close CHR-1"
check_target "$CD/base/store" "cs_f() { CS_X=1; }
cd $CD/base
cs_f
bd -C store close CHR-1"
check_target "$CD/base/store" "cd $CD/base; if true; then CS_X=1; fi; bd -C store close CHR-1"
check_target "$STORE" "cd $STORE; if true; then CS_X=1; fi; bd close CHR-1"
check_target "$CD/base/store" "cd $CD/base; for CS_X in 1 2; do :; done; bd -C store close CHR-1"
check_target "$CD/base/store" "cd $CD/base; case x in x) CS_X=1 ;; esac; bd -C store close CHR-1"
check_target "$CD/base/store" "cd $CD/base; eval 'CS_X=1'; bd -C store close CHR-1"
# One that does act on it, on any of its paths, gives it up as before -- and a
# body's `cd` in a subshell of its own does not count, having moved nothing.
check_unresolved "cd $CD/base; if true; then cd $CD/other; fi; bd -C store close CHR-1"
check_unresolved "cd $CD/base; if false; then cd $CD/other; else CS_X=1; fi; bd -C store close CHR-1"
check_unresolved "cd $CD/base; eval 'cd $CD/other'; bd -C store close CHR-1"
check_unresolved "cd $CD/base; if true; then cd \$(pick); fi; bd -C store close CHR-1"
check_target "$CD/base/store" "cd $CD/base; if true; then (cd $CD/other); fi; bd -C store close CHR-1"
check_target "$CD/base/store" "cd $CD/base; if true; then env -C $CD/other true; fi; bd -C store close CHR-1"
# A body that calls itself names no further store on the second pass.
check sync 'cs_f() { cs_f; bd close CHR-1; }; cs_f'
# A word that names no function defined here is an ordinary command.
check skip 'cs_undefined_fn'
# The definition must come first, as it must for the shell: a call before it
# runs no body.
check_unresolved 'cs_f; cs_f() { bd -C store close CHR-1; }'

# --- comments -------------------------------------------------------------
# A `#` that opens a word begins a comment, and what follows is not script.
# Reading it as script applies a `cd` the shell skipped and resolves the next
# write under a directory nothing entered.
check_target "$BASE/store" "echo start # note; cd $CD/other
bd -C store close CHR-1"
check skip 'echo hi # bd -C /tmp/store close CHR-1'
check skip '# bd close CHR-1'
check skip '   # bd close CHR-1'
check sync 'bd close CHR-1 # done'
# The line ends the comment, and the command after it is script again.
check sync 'echo hi # note
bd close CHR-1'
# Within a word it is an ordinary character: a path is not truncated at it,
# and neither is one inside quotes.
check_target '/tmp/a#b' 'bd -C /tmp/a#b close CHR-1'
check_target '/tmp/a #b' 'bd -C "/tmp/a #b" close CHR-1'
check_target '/tmp/a#b' "bd -C '/tmp/a#b' close CHR-1"
check_target '/tmp/a#b' 'bd -C /tmp/a\#b close CHR-1'
# A comment cannot open inside a here-document body, which is data.
check sync 'cat <<EOF
# not a comment
EOF
bd close CHR-1'

# --- line continuations ---------------------------------------------------
# A backslash before a newline is removed with the newline, joining the
# halves of the word around it -- inside double quotes as well as outside.
check_target '/tmp/ab' 'bd -C "/tmp/a\
b" close CHR-1'
check_target '/tmp/ab' 'bd -C /tmp/a\
b close CHR-1'
# The command is not ended by the newline it consumed.
check sync 'bd \
close CHR-1'
# Single quotes take it literally: there is no escape inside them.
check_target '/tmp/a\
b' "bd -C '/tmp/a\\
b' close CHR-1"

# --- malformed and unusual text -------------------------------------------
# A command the parser cannot read whole is read as far as it goes. Giving up
# on all of it loses the writes before the offending token, and for a `-C`
# target that is the worst outcome available: the roots sync, nothing looks
# wrong, and the external store is never registered.
check_target '/tmp/store' 'bd -C /tmp/store close CHR-1 ))))'
check_target '/tmp/store' 'bd -C /tmp/store close CHR-1 ;;;;'
# The position shfmt reports counts bytes. Cut by character count, a
# non-ASCII character before the fault left the offending token in the text,
# or put the cut past its end -- either way the prefix was abandoned and the
# write in it read as no write. One case per shape: a two-byte character, a
# run of three-byte ones, and a fault on a later line, whose cut carries the
# byte length of every line before it as well as of its own.
check sync 'echo é ; bd close CHR-1 ; )'
check sync 'echo 日本語 ; bd close CHR-1 ; )'
check sync $'echo é\necho é ; bd close CHR-1 ; )'
check_target '/tmp/store' 'echo é ; bd -C /tmp/store close CHR-1 ))))'
check skip 'echo é ; )'
check skip 'echo )))'
check skip ''
check skip '   '
# A coprocess is a subshell, and the command in one is a real invocation.
check_target '/tmp/store' 'coproc bd -C /tmp/store close CHR-1'
check skip 'coproc bd list'
# `eval` runs its operand as script, so a write inside it is a write and the
# store it names is the store. Read as an opaque word instead, this asserted a
# missed write: /tmp/store changed while the hook reported nothing and never
# registered the target, and SessionEnd knows only the workspace roots, so it
# could stay local indefinitely.
check_target '/tmp/store' 'eval "bd -C /tmp/store close CHR-1"'
check sync 'eval "bd -C /tmp/store close CHR-1"'
# The operands are joined with a space before being parsed, which is what `eval`
# itself does, so the unquoted spelling is the same script.
check_target '/tmp/store' 'eval bd -C /tmp/store close CHR-1'
check_target '/tmp/store' 'eval "bd -C" /tmp/store "close CHR-1"'
# A read-only one inside `eval` is still read-only: the fix must find the write,
# not report every `eval` as one.
check skip 'eval "bd list"'
check skip 'eval "echo bd close CHR-1"'
# An operand this scan cannot read may write and there is no way to learn
# whether it does, so it counts as a write with no target -- the roots sync --
# and as a target that could not be named, so the hook says so.
check sync 'eval "$SOMETHING_UNSET_BY_ANY_TEST"'
check_unresolved 'eval "$SOMETHING_UNSET_BY_ANY_TEST"'
check sync 'eval "$(printf %s bd\ close\ CHR-1)"'
# `eval` runs in the calling shell, so a `cd` before it applies to the script.
check_target "$CD/other/store" "cd $CD/other && eval 'bd -C store close CHR-1'"
# ... and a `cd` inside it reaches what follows, but which branch ran is not
# inferred, so the cwd after is unknown rather than guessed.
check_unresolved "eval 'cd $CD/other'; bd -C store close CHR-1"
# The command's temporary prefix is in place while `eval` expands its text, as
# it is for `bash -c`: `OUT=/real eval 'bd -C "$OUT" ...'` writes /real, and
# scanning the text without it read the value from before -- here none, so a
# real target was reported as one that could not be named.
check_target '/tmp/store' 'CS_E_STORE=/tmp/store eval '"'"'bd -C "$CS_E_STORE" close CHR-1'"'"''
check_target '/tmp/store' 'CS_E_STORE=/old; CS_E_STORE=/tmp/store eval '"'"'bd -C "$CS_E_STORE" close CHR-1'"'"''
check_target '/tmp/store' 'true && CS_E_STORE=/tmp/store eval '"'"'bd -C "$CS_E_STORE" close CHR-1'"'"''
# Whether the prefix outlives the call turns on the shell's POSIX mode, so the
# name is unknown afterwards rather than either value.
check_unresolved 'CS_E_STORE=/old; CS_E_STORE=/tmp/store eval true; bd -C "$CS_E_STORE" close CHR-1'
# A conditional `eval` is scanned as the conditional text it is: a `cd` inside
# it is not applied to what follows inside it either.
check_unresolved "true && eval 'cd $CD/other; bd -C store close CHR-1'"
check sync "true && eval 'cd $CD/other; bd -C store close CHR-1'"
# Text that contains itself terminates by being refused on second sight, rather
# than by a depth cap -- which is what used to lose a legitimately nested write.
# It names no store at any level, so the answer is `skip`; what is asserted is
# that there is an answer at all.
check skip 's='\''eval "$s"'\''; eval "$s"'
# A write nested deeper than the old cap of 4 is still found. Nesting by
# substitution rather than by `-c` because each `-c` level doubles the quoting,
# so a case written that way says more about the escaping than the scan.
check_target '/tmp/store' 'echo $(echo $(echo $(echo $(echo $(bd -C /tmp/store close CHR-1)))))'
check_target '/tmp/store' 'echo $(echo $(echo $(echo $(echo $(echo $(echo $(bd -C /tmp/store close CHR-1)))))))'
check sync 'echo $(echo $(echo $(echo $(echo $(bd close CHR-1)))))'
# A loop or case body is not certain to run, but a write in one is a write.
check_target '/tmp/store' 'until bd -C /tmp/store close CHR-1; do :; done'
check_target '/tmp/store' 'case x in *) bd -C /tmp/store close CHR-1 ;; esac'
check_target '/tmp/store' 'for i in 1; do bd -C /tmp/store close CHR-1; done'
# A `for` header runs before the body and whether or not the body does, in
# either of its forms. Visiting only a word list missed the arithmetic one.
check_target '/tmp/store' 'for ((i = $(bd -C /tmp/store close CHR-1); i < 2; i++)); do :; done'
check_target '/tmp/store' 'for ((i = 0; i < $(bd -C /tmp/store close CHR-1); i++)); do :; done'
check_target '/tmp/store' 'for ((i = 0; i < 2; i += $(bd -C /tmp/store close CHR-1))); do :; done'
check_target '/tmp/store' 'for i in $(bd -C /tmp/store close CHR-1); do :; done'
check_target '/tmp/store' 'for ((i = 0; i < 2; i++)); do bd -C /tmp/store close CHR-1; done'
# A word-iterating `for` assigns its name on every pass, though the tree spells
# no assignment. Reading the body against the value from before the loop named
# a store the command never opened, while the one it wrote went unregistered.
# With every item known the body is read once per value, which is what runs.
check_target '/real' 'OUT=/old; for OUT in /real; do bd -C "$OUT" close CHR-1; done'
check_target '/tmp/a /tmp/b' 'for d in /tmp/a /tmp/b; do bd -C "$d" close CHR-1; done'
check_target '/tmp/a b /tmp/c' 'for d in "/tmp/a b" /tmp/c; do bd -C "$d" close CHR-1; done'
check_target "$HOME/store" 'for d in ~/store; do bd -C "$d" close CHR-1; done'
check_target '/tmp/a/x /tmp/b/x' 'for d in /tmp/a /tmp/b; do bd -C "$d/x" close CHR-1; done'
check_target '/tmp/a/one /tmp/a/two /tmp/b/one /tmp/b/two' \
  'for d in /tmp/a /tmp/b; do for e in one two; do bd -C "$d/$e" close CHR-1; done; done'
check_target '/tmp/a /tmp/b' 'cs_l=/tmp/a; for d in "$cs_l" /tmp/b; do bd -C "$d" close CHR-1; done'
# A list that cannot be read leaves the name unknown, and so does no list at
# all: `for x; do` iterates the positional parameters, which the scan does not
# have. The write is still found, and the target reported as unresolved rather
# than as the value from before the loop.
check_unresolved 'OUT=/old; for OUT in $(ls); do bd -C "$OUT" close CHR-1; done'
check_unresolved 'OUT=/old; for OUT; do bd -C "$OUT" close CHR-1; done'
check_unresolved 'OUT=/old; for OUT in /real "$(x)"; do bd -C "$OUT" close CHR-1; done'
scan_command 'OUT=/old; for OUT in $(ls); do bd -C "$OUT" close CHR-1; done' "$BASE"
[ "$SCAN_MUTATES" -eq 1 ] && [ "$SCAN_UNRESOLVED" -eq 1 ] && PASS=$((PASS + 1)) || {
  FAIL=$((FAIL + 1))
  printf 'FAIL want mutates=1 unresolved=1 got mutates=%s unresolved=%s for over unknown list\n' \
    "$SCAN_MUTATES" "$SCAN_UNRESOLVED"
}
# After the loop the name is unknown either way: which pass ran last is not
# inferred, and neither is whether any did.
check_unresolved 'OUT=/old; for OUT in /real; do :; done; bd -C "$OUT" close CHR-1'
check_target '/real' 'OUT=/old; for OUT in /real; do bd -C "$OUT" close CHR-1; done; bd -C "$OUT" close CHR-2'
# Past the per-value bound the name is unknown for the body rather than the
# scan running long.
check_target '/tmp/a/1 /tmp/a/2 /tmp/a/3 /tmp/a/4 /tmp/a/5 /tmp/a/6 /tmp/a/7 /tmp/a/8 /tmp/a/9 /tmp/a/10 /tmp/a/11 /tmp/a/12 /tmp/a/13 /tmp/a/14 /tmp/a/15 /tmp/a/16' \
  'for d in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do bd -C "/tmp/a/$d" close CHR-1; done'
check_unresolved 'for d in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17; do bd -C "/tmp/a/$d" close CHR-1; done'
check_target '/tmp/a/x' 'for d in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17; do bd -C /tmp/a/x close CHR-1; done'
# A case pattern is a word the shell expands before matching it, so a
# substitution in one runs. Scanning the arms alone found nothing to sync.
check_target '/tmp/store' 'case x in "$(bd -C /tmp/store close CHR-1)") :;; esac'
check_target '/tmp/store' 'case x in a|"$(bd -C /tmp/store close CHR-1)") :;; esac'
check_target '/tmp/store' 'case x in a) :;; "$(bd -C /tmp/store close CHR-1)") :;; esac'
check sync 'case x in $(bd close CHR-1)) :;; esac'
# An assignment's index and array literal are expanded too, so a substitution
# in either runs. Visiting the value alone found neither.
check_target '/tmp/store' 'A[$(bd -C /tmp/store close CHR-1)]=v'
check_target '/tmp/store' 'A[$(bd -C /tmp/store close CHR-1 >/dev/null; echo 0)]=v'
check_target '/tmp/store' 'B=($(bd -C /tmp/store close CHR-1))'
check_target '/tmp/store' 'B=(a "$(bd -C /tmp/store close CHR-1)" c)'
check_target '/tmp/store' 'B=([$(bd -C /tmp/store close CHR-1)]=v)'
check_target '/tmp/store' 'A[$(bd -C /tmp/store close CHR-1)]+=v'
check sync 'A[$(bd close CHR-1)]=v'
check sync 'B=($(bd close CHR-1))'
check sync 'declare -a B=($(bd close CHR-1))'

# --- the parser's own version ---------------------------------------------
# Two things the scanner reads out of shfmt are not part of its output format
# and change between releases, and both fail silently rather than loudly. The
# suite ran green on a developer's 3.13 while every one of these was wrong on
# the 3.8 the CI image installs.
#
# The operator joining two commands is read from the source at the offset the
# tree gives, never from the node's `Op` code -- that code is an index into
# shfmt's operator table and every value shifted by one between the two
# versions, which made each operator read as the one below it: a pipeline was
# taken for `||` and a `cd` inside one was credited to the shell that never ran
# it. Asserted per operator, since a uniform shift is invisible to any single
# case.
check_target "$BASE/store" "cd $CD/other | bd -C store close CHR-1"
check_target "$BASE/store" "cd $CD/other | true; bd -C store close CHR-1"
check_target "$CD/other/store" "cd $CD/other && bd -C store close CHR-1"
check_unresolved "cd $CD/other || bd -C store close CHR-1"
check_target "$BASE/store" "cd $CD/other |& true; bd -C store close CHR-1"
# The repair patterns match the tokens shfmt names in its errors, which 3.8
# writes bare or in double quotes and 3.9 onward in backticks. Requiring one
# spelling finds no repair under the other, and the fragment is abandoned: the
# write is reported with no target and its store goes unregistered. One case
# per error message the repairs key on.
check_target "$CD/other/store" "cs_f() { cd $CD/other
bd -C store close CHR-1"
check_target '/tmp/store' 'if bd -C /tmp/store close CHR-1'
check_target '/tmp/store' 'while bd -C /tmp/store close CHR-1'
check_target '/tmp/store' 'until bd -C /tmp/store close CHR-1'
check_target '/tmp/store' 'then bd -C /tmp/store close CHR-1'
check_target '/tmp/store' 'bd -C "/tmp/store'

# --- PWD ------------------------------------------------------------------
# The hook runs in a process of its own, whose cwd is neither the launch
# directory nor one the command's `cd`s reach. Answering `$PWD` from it names
# a store the write never opened.
check_target "$BASE/store" 'bd -C "$PWD/store" close CHR-1'
check_target "$CD/base/store" "cd $CD/base; bd -C \"\$PWD/store\" close CHR-1"
check_target "$BASE/store" 'bd -C "${PWD}/store" close CHR-1'
# An explicit assignment wins, as it does in the shell: `PWD=/x` is let stand
# and `$PWD` expands to what it was told.
check_target '/tmp/decoy/store' 'PWD=/tmp/decoy; bd -C "$PWD/store" close CHR-1'
# ... until a `cd` succeeds, which overwrites PWD as it overwrites the cwd.
# `PWD=/decoy; cd /external; bd -C "$PWD" close X` writes /external's store;
# left standing, the assignment won over the tracked cwd and named the decoy.
check_target "$CD/base/store" "PWD=/tmp/decoy; cd $CD/base; bd -C \"\$PWD/store\" close CHR-1"
check_target "$CD/base/store" "PWD=/tmp/decoy; pushd $CD/base; bd -C \"\$PWD/store\" close CHR-1"
check_target "$CD/base/store" "export PWD=/tmp/decoy; cd $CD/base; bd -C \"\$PWD/store\" close CHR-1"
check_target "$CD/one/store" "cd $CD/base; PWD=/tmp/decoy; cd $CD/one; bd -C \"\$PWD/store\" close CHR-1"
# A `cd` that fails leaves PWD as it was, with the cwd.
check_target '/tmp/decoy/store' 'PWD=/tmp/decoy; cd /nonexistent-cs-classify; bd -C "$PWD/store" close CHR-1'
# An assignment after the `cd` is the one that stands.
check_target '/tmp/decoy/store' "cd $CD/base; PWD=/tmp/decoy; bd -C \"\$PWD/store\" close CHR-1"
# Where the cwd is unknown, so is `$PWD` -- an assignment before the move
# included, since the move overwrote it.
check_unresolved 'cd -; bd -C "$PWD/store" close CHR-1'
check_unresolved 'PWD=/tmp/decoy; cd -; bd -C "$PWD/store" close CHR-1'
check_unresolved "PWD=/tmp/decoy; popd; bd -C \"\$PWD/store\" close CHR-1"
check_unresolved "PWD=/tmp/decoy; false && cd $CD/base; bd -C \"\$PWD/store\" close CHR-1"
# `OLDPWD` names a directory only the launching shell's history knows.
check_unresolved 'bd -C "$OLDPWD/store" close CHR-1'

# --- tilde ----------------------------------------------------------------
# `~` names $HOME as the command sees it. Expanding it against the hook's own
# HOME names some other store, so the one that was written goes unregistered.
check_target '/tmp/home/store' 'HOME=/tmp/home; bd -C ~/store close CHR-1'
check_target '/tmp/home' 'HOME=/tmp/home; bd -C ~ close CHR-1'
# An assignment reaches only the scope that made it, so the one inside a
# subshell does not answer for the command after it.
check_target "$HOME/store" 'bd -C ~/store close CHR-1'
# A HOME this scan cannot read leaves the target unresolvable rather than
# resolved against the hook's own.
check_unresolved 'HOME=$(pwd); bd -C ~/store close CHR-1'
# Quoted, `~` is literal and names no home at all, so the target is relative.
check_target "$BASE/~/store" 'bd -C "~/store" close CHR-1'
# A `~` on the right of an assignment is expanded by the shell there, so the
# variable holds a path. Stored as the two literal characters, the flag saying
# it named $HOME was lost -- the field the variable produces begins with `$` --
# and the target resolved below the launch directory instead.
check_target '/tmp/home/store' 'HOME=/tmp/home; OUT=~/store; bd -C "$OUT" close CHR-1'
check_target '/tmp/home' 'HOME=/tmp/home; OUT=~; bd -C "$OUT" close CHR-1'
check_target "$HOME/store" 'OUT=~/store; bd -C "$OUT" close CHR-1'
check_target '/tmp/home/store' 'HOME=/tmp/home; export OUT=~/store; bd -C "$OUT" close CHR-1'
# Quoted on the right, it is literal there too.
check_target "$BASE/~/store" 'OUT="~/store"; bd -C "$OUT" close CHR-1'
# A HOME the scan cannot read leaves the value unresolvable rather than
# resolved against the hook's own.
check_unresolved 'HOME=$(pwd); OUT=~/store; bd -C "$OUT" close CHR-1'
# `~` past the first character is literal, being no home reference at all.
check_target "$BASE/x~/store" 'OUT=x~/store; bd -C "$OUT" close CHR-1'

# `~user` names that user's home from the passwd database, which HOME cannot
# override. Handling only `~` and `~/` left it unexpanded -- and an unexpanded
# `~user/project` is a *relative* path, so it resolved under the launch
# directory and named a store the command never opened, while the one that was
# written went unregistered.
#
# `root` is the one login name present on both this machine and CI, and its home
# differs between them (/var/root against /root), so it is read from the passwd
# database rather than written down.
ROOT_HOME=$(python3 -c 'import pwd; print(pwd.getpwnam("root").pw_dir)')
check_target "$ROOT_HOME/store" 'bd -C ~root/store close CHR-1'
check_target "$ROOT_HOME" 'bd -C ~root close CHR-1'
# HOME does not answer for it, the passwd database being the only source.
check_target "$ROOT_HOME/store" 'HOME=/tmp/home; bd -C ~root/store close CHR-1'
# Expanded on the right of an assignment too, where the shell expands it.
check_target "$ROOT_HOME/store" 'OUT=~root/store; bd -C "$OUT" close CHR-1'
# Quoted, it is literal and so relative, as `"~/store"` is.
check_target "$BASE/~root/store" 'bd -C "~root/store" close CHR-1'
# A name no user holds is left as it is, which is what the shell does with it:
# no expansion applies, so the word is the literal path it looks like.
check_target "$BASE/~cs-no-such-user/store" \
  'bd -C ~cs-no-such-user/store close CHR-1'
# Only the prefix up to the first `/` is the tilde expansion; a `~` further
# along the path is an ordinary character.
check_target "$ROOT_HOME/a~b/store" 'bd -C ~root/a~b/store close CHR-1'

# `~+` is the cwd, which is tracked here, so a `cd` before it is applied.
check_target "$BASE/store" 'bd -C ~+/store close CHR-1'
check_target "$CD/other/store" "cd $CD/other; bd -C ~+/store close CHR-1"
check_target "$BASE" 'bd -C ~+ close CHR-1'
# A cwd this scan cannot know leaves it unresolvable rather than guessed.
check_unresolved "cd \$(pwd); bd -C ~+/store close CHR-1"
# `~-` is the previous directory and the `~N` forms name entries of the shell's
# own directory stack. Neither is readable from outside that shell, so both are
# reported unresolvable rather than resolved against something else. Left to the
# relative path they look like, they named a store under the launch directory.
check_unresolved 'bd -C ~-/store close CHR-1'
check_unresolved 'bd -C ~1/store close CHR-1'
check_unresolved 'bd -C ~+2/store close CHR-1'
check_unresolved 'bd -C ~-3 close CHR-1'
# Unresolvable is counted, that count being what makes the hook say a store went
# unsynced -- the one thing left in place of the sync.
scan_command 'bd -C ~-/store close CHR-1' "$BASE"
[ "$SCAN_UNRESOLVED" -eq 1 ] && PASS=$((PASS + 1)) || {
  FAIL=$((FAIL + 1))
  printf 'FAIL unresolved want=1 got=%s ~-/store\n' "$SCAN_UNRESOLVED"
}
# The write itself is still found, so the roots sync either way.
check sync 'bd -C ~-/store close CHR-1'

# --- patterns in the target -----------------------------------------------
# An unquoted `*`, `?` or `[...]` is matched on paths when the command runs,
# and the store `bd` opens is whichever directory matched -- not the text.
# Reported as written, the target named no store and the hook dropped it in
# silence: the write was found, the store it went to was not. Unknown
# instead, and counted, so the hook says a store went unsynced.
check_unresolved 'bd -C /tmp/store-* close CHR-1'
check_unresolved 'bd -C /tmp/store-? close CHR-1'
check_unresolved 'bd -C /tmp/store-[12] close CHR-1'
check_unresolved "bd -C $STORE/nest* close CHR-1"
scan_command 'bd -C /tmp/store-* close CHR-1' "$BASE"
[ "$SCAN_UNRESOLVED" -eq 1 ] && PASS=$((PASS + 1)) || {
  FAIL=$((FAIL + 1))
  printf 'FAIL unresolved want=1 got=%s /tmp/store-*\n' "$SCAN_UNRESOLVED"
}
check sync 'bd -C /tmp/store-* close CHR-1'
# The value of an unquoted expansion is matched the same way.
check_unresolved 'OUT=/tmp/store-*; bd -C $OUT close CHR-1'
# Quoting or escaping the character makes it a character again, and the path
# is taken as written. So does a `[` with nothing to close it.
check_target '/tmp/store-*' 'bd -C "/tmp/store-*" close CHR-1'
check_target '/tmp/store-*' "bd -C '/tmp/store-*' close CHR-1"
check_target '/tmp/store-*' 'bd -C /tmp/store-\* close CHR-1'
check_target '/tmp/store-[' 'bd -C /tmp/store-[ close CHR-1'
# A `cd` to a pattern lands wherever it matched, so the cwd is unknown from
# there and a plain `bd` after it is reported as unresolved rather than
# against the directory the shell left.
check_unresolved 'cd /tmp/store-* && bd close CHR-1'
# A pattern in an assignment's value is not expanded there, so it is kept.
check_target '/tmp/store-*' 'OUT=/tmp/store-*; bd -C "$OUT" close CHR-1'
# A pattern elsewhere in the command leaves a literal target alone, and a
# read-only verb stays read-only whatever its operands look like.
check_target '/tmp/store' 'ls *.md; bd -C /tmp/store close CHR-1'
check skip 'bd search foo*'
check skip 'bd list --json | jq .[]'

# --- byte offsets ---------------------------------------------------------
# shfmt reports an operator's position as a byte offset, and a character index
# into the string lands past it once a character before it is multi-byte. The
# miss reads as "not a pipe", which applies a `cd` from one pipeline leg to the
# shell that never ran it.
check_target "$BASE/store" "echo é | cd $CD/other; bd -C store close CHR-1"
check_target "$BASE/store" "echo ééé | cd $CD/other; bd -C store close CHR-1"
check_target "$CD/other/store" "echo é; cd $CD/other; bd -C store close CHR-1"
# `&&` and `||` are read from the same offsets, so a `cd` on the right of one
# is still conditional with a multi-byte character before it.
check_unresolved "echo é && cd $CD/other; bd -C store close CHR-1"

# --- end of options -------------------------------------------------------
# `--` ends the options, so a word past it is an operand however it is spelled.
# Reading `bd create -- --help` as a help invocation suppresses a real write.
check sync 'bd create -- --help'
check sync 'bd -- create x'
check sync 'bd create -- -C /tmp/store'
# The `-C` past `--` is a title, not a target: acting on it commits a store the
# command never opened.
check_target '' 'bd create -- -C /tmp/store'
# Before `--`, both still read as they did.
check skip 'bd --help create'
check_target '/tmp/store' 'bd -C /tmp/store -- close CHR-1'
# A verb past `--` is read as one, so a read-only invocation still skips.
check skip 'bd -- list'

# --- an unknown operand holds its place -----------------------------------
# Dropping it moves the next word into the verb position, so a read-only verb
# behind an unknowable one suppressed the write the substitution named.
check sync 'bd "$(printf create)" list'
check sync 'bd $UNSET_BY_ANY_TEST_XYZ list'
check sync 'bd "$(printf dep)" list'
# An unknown verb matches no read-only entry, so the invocation counts as a
# write -- one no-op commit against a stranded one.
check sync 'bd "$(printf list)"'
# A known read-only verb ahead of an unknown operand still reads as read-only.
check skip 'bd list "$(printf x)"'
# The `-C` target is still found past an unknown operand.
check_target '/tmp/store' 'bd -C /tmp/store "$(printf close)" CHR-1'

# --- a wrapper's environment reaches the command --------------------------
# `env VAR=value` is the syntactic prefix's twin: it reaches the child, and the
# child expands its script with it in place.
check_target '/tmp/store' 'env OUT=/tmp/store bash -c "bd -C \"\$OUT\" close CHR-1"'
check_target '/tmp/store' 'env A=1 OUT=/tmp/store bash -c "bd -C \"\$OUT\" close CHR-1"'
check_target '/tmp/store' 'env -u FOO OUT=/tmp/store bash -c "bd -C \"\$OUT\" close CHR-1"'
check_target '/tmp/store' 'env -i OUT=/tmp/store bash -c "bd -C \"\$OUT\" close CHR-1"'
# A name the wrapper unset is unset in the child, whatever the hook's own
# environment says, and so is every name under `env -i`.
check_unresolved 'env -u HOME bash -c "bd -C \"\$HOME/store\" close CHR-1"'
check_unresolved 'env -i bash -c "bd -C \"\$HOME/store\" close CHR-1"'
# `sudo` and `doas` decide what passes by a policy on disk, so a name is
# unknowable there rather than guessed -- but the write is still found.
check sync 'sudo OUT=/tmp/store bash -c "bd -C \"\$OUT\" close CHR-1"'
check_unresolved 'sudo OUT=/tmp/store bash -c "bd -C \"\$OUT\" close CHR-1"'
check_target '/tmp/store' 'sudo bash -c "bd -C /tmp/store close CHR-1"'
# The wrapper's assignments reach the child only, not the command after it.
check_target '/tmp/store' 'env OUT=/tmp/decoy bash -c "bd -C /tmp/store close CHR-1"'

echo "classification: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]

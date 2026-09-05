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
# cannot be placed and the invocation is left alone, as for any wrapper.
check skip 'exec -Z bd -C /tmp/store close CHR-1'

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
check_target '' 'cd $(pwd); bd close CHR-1'
# A read-only command opens a store too, but nothing there needs syncing.
check_target '' "cd $STORE && bd list"
# A `-C` naming no directory is reported as it stands rather than walked up
# from: `bd` refuses such a path outright, so walking would name an ancestor's
# store this command never opened.
check_target "$STORE/sub/nosuch" "bd -C $STORE/sub/nosuch close CHR-1"

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
check_target '' "cd $STORE && BEADS_DIR=\$(pwd) bd close CHR-1"
# Set to nothing, it names no store and the walk applies as usual.
check_target "$STORE" "cd $STORE && BEADS_DIR= bd close CHR-1"
# The root is what holds the `.beads` the value names, so the separator after
# it is not a component of its own. Taking the empty one off named the `.beads`
# directory as the root, which holds no `.beads` itself: the hook dropped it and
# the write went to neither the push set nor the registry.
check_target "$STORE" "BEADS_DIR=$STORE/.beads/ bd close CHR-1"
check_target "$STORE" "BEADS_DIR=$STORE/.beads/// bd close CHR-1"
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
# An IFS whose value this scan cannot read leaves splitting unknowable, so no
# store is named rather than the wrong one.
check_target '' 'IFS=$(printf x); OUT="/tmp/a b"; bd -C $OUT close CHR-1'
check sync 'IFS=$(printf x); OUT="/tmp/a b"; bd -C $OUT close CHR-1'
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
check_target '' "cd $CD/base; cd; bd -C store close CHR-1"
check_target '' "cd $CD/base; cd -; bd -C store close CHR-1"
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
check_target '' 'false && cd /tmp/other; bd -C store close CHR-1'
check_target '' 'cd /tmp/base || cd /tmp/fallback; bd -C store close CHR-1'
# The mirror of the above: what follows `||` runs only if the `cd` failed, so
# a `cd` read as successful names the directory of the branch not taken.
check_target '' 'cd /tmp/missing || bd -C store close CHR-1'
# Given up with it, the cwd being knowable only by reasoning about which
# commands end the list.
check_target '' 'cd /tmp/base || exit 1; bd -C store close CHR-1'
# An absolute target does not need the cwd, so an unknown one costs nothing.
check_target '/tmp/store' 'false && cd /tmp/other; bd -C /tmp/store close CHR-1'

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
check_target '' 'bd -C "$CS_NO_SUCH_VAR_HERE" close CHR-1'
# An inherited name set to the empty string has a value, and it is the empty
# string -- unlike one nothing sets at all. Read as absent, the word carrying
# it was unknowable and the store it named went unregistered.
export CS_TEST_EMPTY=
check_target '/tmp/store' 'bd -C "$CS_TEST_EMPTY/tmp/store" close CHR-1'
check_target '' 'bd -C "$CS_TEST_EMPTY" close CHR-1'
check_target "$BASE/store" 'bd -C "$CS_TEST_EMPTY"store close CHR-1'
# `X=` assigns the empty string, and the parse carries no value node for it
# rather than an empty one, so a test for that node read it as no assignment
# at all and left the inherited path standing -- naming a store the command
# never opened.
check_target '/tmp/store' 'CS_TEST_STORE=; bd -C "$CS_TEST_STORE/tmp/store" close CHR-1'
check_target '' 'CS_TEST_STORE=; bd -C "$CS_TEST_STORE" close CHR-1'
check_target '/tmp/store' 'export CS_TEST_STORE=; bd -C "$CS_TEST_STORE/tmp/store" close CHR-1'
check_target '/tmp/store' 'declare CS_TEST_STORE=; bd -C "$CS_TEST_STORE/tmp/store" close CHR-1'
check_target '/tmp/store' 'CS_TEST_EMPTY=; bd -C "$CS_TEST_EMPTY/tmp/store" close CHR-1'
# One the shell may never reach still does not speak for the value in effect.
check_target '/tmp/inherited/tmp/store' 'false && CS_TEST_STORE=; bd -C "$CS_TEST_STORE/tmp/store" close CHR-1'
# The forms that give a name no single value leave the one it had: `+=` with
# nothing to append, an array, and one element of an array.
check_target '/tmp/inherited' 'CS_TEST_STORE+=; bd -C "$CS_TEST_STORE" close CHR-1'
check_target '/tmp/inherited' 'CS_TEST_STORE=(/tmp/a /tmp/b); bd -C "$CS_TEST_STORE" close CHR-1'
check_target '/tmp/inherited' 'CS_TEST_STORE[2]=/tmp/x; bd -C "$CS_TEST_STORE" close CHR-1'
unset CS_TEST_EMPTY
unset CS_TEST_STORE

# --- command substitution in the target ---------------------------------
# The value comes from running something the scan does not run, so the path
# is unknown. Reporting the word with the substitution dropped would not be
# vaguer, it would be wrong: `$(pwd)/store` would come out as `/store`.
check_target '' 'bd -C "$(pwd)/store" close CHR-1'
check_target '' 'bd -C "$(echo /tmp/x)/store" close CHR-1'
check_target '' 'bd -C `pwd`/store close CHR-1'
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
check_target '/tmp/store' 'env -- bd -C /tmp/store close CHR-1'
check_target '' 'env echo bd -C /tmp/store close CHR-1'
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
check_target '' 'sudo -nZ bd -C /tmp/store close CHR-1'
check_target '' 'sudo -Z bd -C /tmp/store close CHR-1'
# `command -v` prints a path instead of running anything, so there is no
# invocation here to attribute a write to.
check skip 'command -v bd'
# A wrapper named by path runs the same program, and its options are its own.
# Looked up by full path the option tables had no entry for it, so the flag
# after it was read as the command word and the write was missed outright.
check_target '/tmp/store' '/usr/bin/env bd -C /tmp/store close CHR-1'
check sync '/usr/bin/env -i bd close CHR-1'
check_target '/tmp/store' '/usr/bin/env -i bd -C /tmp/store close CHR-1'
check_target '/tmp/store' '/usr/bin/sudo -u nick bd -C /tmp/store close CHR-1'
check_target '/tmp/store' 'nohup /usr/bin/env -i bd -C /tmp/store close CHR-1'
check_target '' '/usr/bin/env echo bd -C /tmp/store close CHR-1'

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
# An unknown letter is still ambiguous, whether it stands alone or opens a
# bundle: it may be the one that takes the value, which would put the command
# word elsewhere. `nice -10` is the historic form for a niceness, and no letter
# at all.
check_target '' 'stdbuf -Zx bd -C /tmp/store close CHR-1'
check_target '' 'nice -10 bd -C /tmp/store close CHR-1'
# `env -u` names the variable to unset, attached as readily as separated. Read
# as a whole word it matched no unset at all, so an inherited value answered for
# a name the command does not have -- naming a store it never opened, while the
# one it wrote went unregistered. The name must be in this process's environment
# for the case to mean anything: unset, it is unresolvable either way.
export CS_TEST_STORE=/tmp/inherited
check_target '/tmp/inherited/x' 'bash -c "bd -C \"\$CS_TEST_STORE/x\" close CHR-1"'
check_target '' 'env -uCS_TEST_STORE bash -c "bd -C \"\$CS_TEST_STORE/x\" close CHR-1"'
check_target '/tmp/store' 'env -uFOO bd -C /tmp/store close CHR-1'
# `-i` among the letters still clears the environment, so a name it does not
# carry is unset in the child however this process answers it.
check_target '' 'env -iuFOO bash -c "bd -C \"\$CS_TEST_STORE/x\" close CHR-1"'
# `exec -c` clears it the same way, which reading the flag as an ordinary
# value-less one did not: the inherited value answered, naming a store the
# command never opened while the one it wrote went unregistered.
check_target '' 'exec -c bash -c "bd -C \"\$CS_TEST_STORE/x\" close CHR-1"'
check_target '' 'exec -lc bash -c "bd -C \"\$CS_TEST_STORE/x\" close CHR-1"'
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
check_target '' "sudo -D $STORE bd close CHR-1"
# The directory may end a bundle whose other letters take nothing. `-i` among
# them seals the environment as `sudo` does, leaving the store in doubt for the
# same reason, so a letter that does not is used to assert the directory itself.
check_target "$STORE" "env -vC$STORE bd close CHR-1"
check_target '' "env -iC$STORE bd close CHR-1"
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
check_target '' "env -C $STORE/nosuch bd close CHR-1"
check_target '' "env -C $CD/nosuch bd close CHR-1"
check_target '' 'env -C $(pwd) bd close CHR-1'
check_target '' 'env -C "" bd close CHR-1'
# The directory it names is a word of its own, so a tilde opening it is an
# expansion -- read literally it is a relative path naming another directory.
# Attached to the flag it is not, the shell expanding one only at a word's start.
check_target "$STORE" "HOME=$CD; env -C ~/repo bd close CHR-1"
check_target '' "HOME=$CD; env -C~/repo bd close CHR-1"
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
# The options before it are still its own, and the assignments among them
# reach the command the string names.
check_target '/tmp/store' 'env -u FOO -S "bd -C /tmp/store close CHR-1"'
check_target '/tmp/store' 'env OUT=/tmp/store -S "bd -C \"\$OUT\" close CHR-1"'
check sync 'env -S "bd close CHR-1"'
# The string is script, so what it says about the cwd applies inside it.
check_target "$CD/other/store" "env -S \"cd $CD/other && bd -C store close CHR-1\""
# A read-only verb inside the string is still read-only.
check skip 'env -S "bd list"'
# A string this scan cannot read may write and there is no way to learn
# whether it does, so it counts as a write with no target -- the roots sync,
# which is the answer every other unreadable write gets.
check sync 'env -S "$CMD"'
check sync 'env -S'
# A bundle holding a letter that may take a value cannot say where `-S` is,
# so the invocation is abandoned as any ambiguous wrapper is.
check_target '' 'env -zS "bd -C /tmp/store close CHR-1"'
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
check_target '' 'env -S "bd -C" "$CS_SOMETHING_UNSET" close CHR-1'

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
# One the shell may never reach must not speak for the value in effect when
# it does not.
check_target '/tmp/inherited' 'false && export CS_TEST_STORE=/tmp/store; bd -C "$CS_TEST_STORE" close CHR-1'
# The word `export` in an argument is a string, not a builtin.
check_target '/tmp/inherited' 'echo export CS_TEST_STORE=/tmp/store; bd -C "$CS_TEST_STORE" close CHR-1'
# A substitution in the value travels with it: the path is no more knowable
# once it has been through a variable than it was in the word.
check_target '' 'export CS_TEST_STORE=$(pwd)/store; bd -C "$CS_TEST_STORE" close CHR-1'
unset CS_TEST_STORE CS_OTHER

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
check_target '' 'CS_PIPE_STORE=/tmp/decoy | true; bd -C "$CS_PIPE_STORE" close CHR-1'
# The write itself is still found inside one, under the cwd in force there.
check sync "true | bd close CHR-1"
check_target "$CD/other/store" "cd $CD/other; true | bd -C store close CHR-1"
# A brace group is not a subshell -- it runs in this shell, and its `cd`
# does reach the command after it -- but `{` also opens the body of an `if`
# or a loop, whose commands are not certain to run. The cwd is left unknown
# rather than guessed, which gives up this case to keep the conditional one.
check_target '' "{ cd $CD/other; }
bd -C store close CHR-1"

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
# An operand this scan cannot read is the fail-safe case, as it is for `eval`
# and `env -S`: the shell runs that text whatever it says. Read as no write,
# a `bd -C /external ...` inside it left the roots unsynced as well as the
# store, and nothing later could find either.
check sync 'bash -c "$CS_SOMETHING_UNSET"'
check sync 'sh -c "$(generate-command)"'
check sync 'bash -c -x "$CS_SOMETHING_UNSET"'
check_target '' 'bash -c "$CS_SOMETHING_UNSET"'
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
# word. The walk stops at the wrapper rather than guessing, which is the
# answer `bd_index` already gives the same text: the `bd` here is inside a
# string no shell was recognised to run, so nothing reports it.
check skip 'sudo -Z bash -c "bd -C /tmp/store close CHR-1"'
# The word `bash` as an argument is a string, not a shell.
check skip 'echo bash -c "bd close CHR-1"'
# A temporary assignment in front of the shell speaks for none of this
# command's own words, but it does reach the child's environment, and the
# child expands its script with it in place. Discarding it read the hook's
# own inherited value and left the store the write opened unregistered.
check_target '/tmp/store' 'CS_W_STORE=/tmp/store bash -c '"'"'bd -C "$CS_W_STORE" close CHR-1'"'"''
check_target '/tmp/store' 'CS_W_STORE=/tmp/store sudo bash -c '"'"'bd -C "$CS_W_STORE" close CHR-1'"'"''
# It reaches that shell only. The value dies with the child, so a later
# command sees the name with no value anywhere.
check_target '' 'CS_W_STORE=/tmp/store bash -c '"'"'true'"'"'; bd -C "$CS_W_STORE" close CHR-1'
# And it still says nothing about the argv of the command carrying it, which
# the shell expanded before applying it.
check_target '' 'CS_W_STORE=/tmp/decoy bd -C "$CS_W_STORE" close CHR-1'

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
check_target '' 'cs_f() { CS_FN_STORE=/tmp/decoy; }; bd -C "$CS_FN_STORE" close CHR-1'
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
check_target '' 'cs_f() { bd -C store close CHR-1; }'
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
# inferred, so the cwd after a call is unknown -- as it is after any compound
# command. This gives up the case where the body changes nothing, to avoid
# naming the caller's directory for one that did `cd` somewhere unknowable.
check_target '' "cs_f() { :; }
cd $CD/base
cs_f
bd -C store close CHR-1"
# A body that calls itself names no further store on the second pass.
check sync 'cs_f() { cs_f; bd close CHR-1; }; cs_f'
# A word that names no function defined here is an ordinary command.
check skip 'cs_undefined_fn'
# The definition must come first, as it must for the shell: a call before it
# runs no body.
check_target '' 'cs_f; cs_f() { bd -C store close CHR-1; }'

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
# whether it does, so it counts as a write with no target -- the roots sync.
check sync 'eval "$SOMETHING_UNSET_BY_ANY_TEST"'
check_target '' 'eval "$SOMETHING_UNSET_BY_ANY_TEST"'
check sync 'eval "$(printf %s bd\ close\ CHR-1)"'
# `eval` runs in the calling shell, so a `cd` before it applies to the script.
check_target "$CD/other/store" "cd $CD/other && eval 'bd -C store close CHR-1'"
# ... and a `cd` inside it reaches what follows, but which branch ran is not
# inferred, so the cwd after is unknown rather than guessed.
check_target '' "eval 'cd $CD/other'; bd -C store close CHR-1"
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
check_target '' "cd $CD/other || bd -C store close CHR-1"
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
# Where the cwd is unknown, so is `$PWD`.
check_target '' 'cd -; bd -C "$PWD/store" close CHR-1'
# `OLDPWD` names a directory only the launching shell's history knows.
check_target '' 'bd -C "$OLDPWD/store" close CHR-1'

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
check_target '' 'HOME=$(pwd); bd -C ~/store close CHR-1'
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
check_target '' 'HOME=$(pwd); OUT=~/store; bd -C "$OUT" close CHR-1'
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
check_target '' "cd \$(pwd); bd -C ~+/store close CHR-1"
# `~-` is the previous directory and the `~N` forms name entries of the shell's
# own directory stack. Neither is readable from outside that shell, so both are
# reported unresolvable rather than resolved against something else. Left to the
# relative path they look like, they named a store under the launch directory.
check_target '' 'bd -C ~-/store close CHR-1'
check_target '' 'bd -C ~1/store close CHR-1'
check_target '' 'bd -C ~+2/store close CHR-1'
check_target '' 'bd -C ~-3 close CHR-1'
# Unresolvable is counted, that count being what makes the hook say a store went
# unsynced -- the one thing left in place of the sync.
scan_command 'bd -C ~-/store close CHR-1' "$BASE"
[ "$SCAN_UNRESOLVED" -eq 1 ] && PASS=$((PASS + 1)) || {
  FAIL=$((FAIL + 1))
  printf 'FAIL unresolved want=1 got=%s ~-/store\n' "$SCAN_UNRESOLVED"
}
# The write itself is still found, so the roots sync either way.
check sync 'bd -C ~-/store close CHR-1'

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
check_target '' "echo é && cd $CD/other; bd -C store close CHR-1"

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
check_target '' 'env -u HOME bash -c "bd -C \"\$HOME/store\" close CHR-1"'
check_target '' 'env -i bash -c "bd -C \"\$HOME/store\" close CHR-1"'
# `sudo` and `doas` decide what passes by a policy on disk, so a name is
# unknowable there rather than guessed -- but the write is still found.
check sync 'sudo OUT=/tmp/store bash -c "bd -C \"\$OUT\" close CHR-1"'
check_target '' 'sudo OUT=/tmp/store bash -c "bd -C \"\$OUT\" close CHR-1"'
check_target '/tmp/store' 'sudo bash -c "bd -C /tmp/store close CHR-1"'
# The wrapper's assignments reach the child only, not the command after it.
check_target '/tmp/store' 'env OUT=/tmp/decoy bash -c "bd -C /tmp/store close CHR-1"'

echo "classification: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env python3
"""Decide whether a shell command writes to a bead store, and which store.

Invoked by lib/command-scan.sh, which keeps the bash-side contract the hook
and its test suite are written against. The command text arrives on stdin and
the answer leaves on stdout as NUL-terminated fields: the mutates flag first,
then the count of `-C` targets that were named and could not be resolved to a
path, then one store path per target found, in the order they were found. Both
counts come before the paths so the paths remain everything past them. NUL
rather than newline because a path may contain a newline and a target that has
been silently truncated names some other store. A path written by a command
the shell does not wait for -- one after `&`, in a coprocess or in a process
substitution -- carries a leading `&`, which no path reported here can begin
with: every one is absolute.

The command is parsed by `shfmt --to-json` rather than scanned as text. A
regex over raw text cannot see a quote, an escape, a command prefix or an
order of execution, so each of those gaps is a separate defect and the supply
of them is unbounded: `bd -C "/tmp/a;b"`, `command bd -C /tmp/x`, `echo
OUT=/tmp/decoy; bd -C "$OUT"` and `false && cd /tmp/other; bd -C store` are
four faces of one missing parser, not four bugs. What remains here is the
semantic layer over that tree -- which directory each command runs in, which
assignments are in effect, and which invocations address a store.
"""

import json
import os
import pwd
import re
import shlex
import subprocess
import sys

# Any `bd` invocation counts as a write unless it is known to be read-only.
# Enumerating the mutating verbs instead means every verb the list misses --
# and every verb a later `bd` release adds -- strands writes locally and
# silently, where the reverse mistake costs one no-op commit.
READONLY_VERBS = set("""
list show ready blocked search query count stale status statuses types graph
children history diff info context where prime quickstart version help
memories recall export ping preflight lint orphans find-duplicates completion
""".split())

# Verbs that are read-only only in combination with a subcommand. None of the
# leading words here may appear in READONLY_VERBS, or `bd dep add` would be
# suppressed by its verb alone.
#
# `human` belongs here rather than above because it reads bare and writes under
# two of its four subcommands: `respond` comments and closes, `dismiss` closes
# permanently. Judging it by its first word alone stranded both.
# Flags that turn a read-only verb into a write. `bd ready --claim` atomically
# claims the first ready issue, so the verb alone cannot judge it: read as the
# listing it resembles, the claim sat local until some later write synced it.
WRITE_FLAGS = {
    "ready": {"--claim"},
}

READONLY_PAIRS = {
    ("dep", "list"), ("dep", "tree"), ("dep", "cycles"),
    ("label", "list"), ("label", "list-all"),
    ("gate", "list"),
    ("kv", "get"), ("kv", "list"),
    ("config", "get"), ("config", "list"), ("config", "show"),
    ("linear", "status"), ("jira", "status"), ("epic", "status"),
    ("swarm", "list"), ("swarm", "status"), ("swarm", "validate"),
    ("todo", "list"),
    ("human", "list"), ("human", "stats"),
    ("dolt", "status"), ("dolt", "log"),
}

# Words that may stand in front of the real command without changing which
# command it is: `command bd -C /tmp/x close CHR-1` is a write to /tmp/x, and
# reading `command` as the command name loses the target. The shell keywords
# the old text scanner also had to list are structural in the tree and never
# reach an argument list, so only the wrappers remain.
PREFIX_WORDS = {"exec", "builtin", "command", "env", "sudo", "doas", "nohup",
                "nice", "setsid", "stdbuf", "timeout", "gtimeout", "xargs",
                "time"}

# Those of them that run the command as a program, in a process of its own:
# a builtin behind one -- `env cd /decoy`, where a `cd` program exists --
# changes nothing in the shell that ran it. `command` and `builtin` run it in
# this shell.
SPAWN_WORDS = PREFIX_WORDS - {"builtin", "command"}

# The subset of the above that takes its own options and environment
# assignments before the command word, with the options that consume the word
# after them. Needed to find where a wrapper's arguments stop and its command
# begins: `sudo -u nick bd ...` runs bd, `env echo bd ...` runs echo, and
# telling them apart means knowing that `-u` takes `nick` while `echo` takes
# nothing. A wrapper with no such options still needs its entry, or it would
# fall through to the default.
#
# The union of the GNU and BSD spellings, since the hook runs under both:
# `env -P altpath` and `env -L user` are BSD's, `sudo -T timeout` is 1.9's.
# A letter missing here is not merely unread -- it makes the bundle ambiguous
# and abandons the invocation, and the write inside it with it.
WRAPPER_OPT_ARGS = {
    "env": {"-u", "--unset", "-C", "--chdir", "-S", "--split-string",
            "-a", "--argv0", "-P", "-L", "-U"},
    "sudo": {"-u", "--user", "-g", "--group", "-p", "--prompt",
             "-C", "--close-from", "-h", "--host", "-r", "--role",
             "-D", "--chdir", "-T", "--command-timeout", "-t", "--type",
             "-U", "--other-user", "-R", "--chroot", "-c", "--login-class"},
    "doas": {"-u", "-C", "-a"},
    "nice": {"-n", "--adjustment"},
    # The external `time` -- `/usr/bin/time`, `command time` -- rather than
    # the shell's reserved word, which the parser gives its own node. GNU's
    # `-f`/`-o` take a value; the rest, BSD's `-l` and `-h` included, do not.
    "time": {"-f", "--format", "-o", "--output"},
    "stdbuf": {"-i", "--input", "-o", "--output", "-e", "--error"},
    "exec": {"-a"},
    "timeout": {"-k", "--kill-after", "-s", "--signal"},
    "gtimeout": {"-k", "--kill-after", "-s", "--signal"},
    "xargs": {"-a", "--arg-file", "-d", "--delimiter", "-E", "-I", "-J",
              "-L", "-n", "--max-args", "-P", "--max-procs", "-R", "-S",
              "-s", "--max-chars", "--process-slot-var"},
    "command": set(), "nohup": set(), "setsid": set(),
}

# `xargs` builds the command from its arguments and its input, so it stands in
# front of the real command as the other wrappers do: `... | xargs -I{} bd
# assign {} user` runs `bd` once per input line, and reading `xargs` as the
# command left the write as an argument nothing looked at. The union of the
# GNU and BSD option sets, since the hook runs under both.
#
# `-i`, `-e` and `-l` take their value only when it is attached -- `-i{}` is
# `-I {}`, while a bare `-i` is `-I {}` too and the word after it is the
# command -- so they are neither in the table above nor value-less, and are
# read on their own. `-I`'s value is the replacement string: every later
# argument holding it is rewritten from the input, so what such an argument
# says here is not what the command receives.
XARGS_OPT_OPTIONAL = {"-i", "-e", "-l"}
XARGS_REPLACE_OPTS = {"-I", "-J"}
XARGS_DEFAULT_REPLACE = "{}"

# Operands a wrapper takes between its options and the command word. `timeout
# 30 bd -C /tmp/store close X` runs bd: the duration is neither an option nor
# the command, and reading it as the command word lost the write outright --
# nothing else in the invocation says a store was written.
WRAPPER_OPERANDS = {"timeout": 1, "gtimeout": 1}

# Options of those wrappers that stand alone. Without them every short flag
# the table above does not list is ambiguous, and an ambiguous flag abandons
# the whole invocation: `sudo -n bd close CHR-1` runs bd, and giving up on it
# would have missed the write itself, not merely its target. (An abandoned
# invocation with a `bd` still among its words is now a write whose store is
# unknown rather than silence -- see `abandoned` -- so the cost of a missing
# letter is a warning and a root sync, not a lost write.)
#
# Only flags that certainly take nothing belong here. One whose argument is
# optional -- `env --block-signal[=SIG]` -- is left out on purpose: it is
# genuinely ambiguous, and the ambiguous path is the safe one.
WRAPPER_OPT_NOARG = {
    "env": {"-i", "--ignore-environment", "-0", "--null", "-v", "--debug"},
    "sudo": {"-n", "--non-interactive", "-b", "--background", "-E",
             "--preserve-env", "-H", "--set-home", "-i", "--login", "-k",
             "--reset-timestamp", "-P", "--preserve-groups", "-S", "--stdin",
             "-s", "--shell", "-A", "--askpass", "-B", "--bell", "-N",
             "--no-update"},
    "doas": {"-n", "-s", "-L"},
    "command": {"-p"},
    "setsid": {"-f", "--fork", "-w", "--wait", "-c", "--ctty"},
    "exec": {"-c", "-l"},
    "timeout": {"--foreground", "-p", "--preserve-status", "-v", "--verbose"},
    "gtimeout": {"--foreground", "-p", "--preserve-status", "-v", "--verbose"},
    "xargs": {"-0", "--null", "-o", "--open-tty", "-p", "--interactive",
              "-r", "--no-run-if-empty", "-t", "--verbose", "-x", "--exit",
              "--show-limits"},
    "time": {"-a", "--append", "-v", "--verbose", "-p", "--portability",
             "-q", "--quiet", "-l", "-h"},
    "nice": set(), "nohup": set(), "stdbuf": set(),
}

# `exec -c` runs the command with an empty environment, which is what `env -i`
# does by another spelling: a name the command line does not carry is unset in
# the child however the hook's own environment answers it. Reading it as an
# ordinary value-less flag left `exec -c bd -C "$OUT/store" close X` resolving
# $OUT from the inherited value, naming a store the command never opened.
EXEC_CLEAR_OPTS = {"-c"}

# `command -v name` and `command -V name` print what the name would run and
# run nothing, so there is no invocation to attribute a write to -- and none
# to give up on: read as an unknown letter with a `bd` after it, the lookup
# was reported as a write whose store is unknown.
COMMAND_LOOKUP_LETTERS = set("vV")

# Shells that run their `-c` operand as script rather than running a command
# of their own. `bash -c 'bd -C /tmp/store close CHR-1'` writes that store,
# and reading `bash` as an ordinary command loses the write entirely --
# nothing else in the invocation says a store was touched, so SessionEnd
# builds its list without it and the write sits local indefinitely.
SHELL_WORDS = {"sh", "bash", "dash", "ksh", "mksh", "zsh"}

# The words after a wrapper this scan gave up on that say a write may still be
# in it: `bd` itself, a shell, or `eval`, each of which runs what follows.
# `nice -Z bd -C /external close X` names no command word this scan can place,
# but the `bd` is still there, and giving up in silence made it a write nothing
# reported -- no sync, no warning, and a store no later event would find.
ABANDONED_RUNNERS = {"bd", "eval"} | SHELL_WORDS
# What separates the words of a script read as text rather than parsed, for
# the runners above anywhere in it, once `script_text` has removed its
# quoting. See `shell_abandoned`.
SCRIPT_WORD_BREAKS = re.compile(r"[\s;&|()<>`{}$!]+")

# The historic spelling of a niceness, which `nice` takes without a letter:
# `nice -10 cmd` is `nice -n 10 cmd`, and GNU takes `--10` and `-+10` too. Read
# as a bundle it held no letter either table knew, so the invocation was
# abandoned and the write behind it missed.
NICE_ADJUST = re.compile(r"^-[-+]?[0-9]+$")

# Options of those shells that consume the word after them, and the short
# letters that certainly do not. The script is the first operand past the
# options, so the two must be told apart: `bash -o pipefail -c '...'` has its
# script two words later than `bash -x -c '...'` does. A letter in neither
# list is ambiguous, and an ambiguous one abandons the invocation rather than
# naming some other word as the script.
#
# The long options are read by name rather than by letter, since a letter read
# out of `--noprofile` is not a flag of anything: `bash --noprofile --norc -c
# '...'` runs its script, and reading the first `-` inside the word as an
# unknown short flag abandoned the invocation. Only the ones that certainly
# take nothing are listed; `--help` and `--version` run no script and are
# left out, as is any long option not known here, so an unknown one still
# abandons the invocation rather than misplacing the script.
SHELL_OPT_ARGS = {"-o", "+o", "-O", "+O", "--rcfile", "--init-file",
                  "--emulate"}
SHELL_NOARG_LETTERS = set("abcefhiklmnprstuvxBCEHPT")
SHELL_LONG_NOARG = {"--noprofile", "--norc", "--posix", "--login",
                    "--noediting", "--restricted", "--verbose", "--debugger",
                    "--pretty-print", "--protected", "--no-rcs",
                    "--no-globalrcs", "--interactive"}
# Those of them only zsh takes. bash refuses them as it does any long option it
# does not know, and runs neither a startup file nor the script: `bash
# --interactive -c '...'` exits 2 at once.
SHELL_ZSH_LONG = {"--no-rcs", "--no-globalrcs", "--interactive", "--emulate"}

# `bd`'s own global options that consume the word after them. The verb is the
# first operand that is not an option, so an option's value must be stepped
# over before it can be read: `bd --actor list close CHR-1` sets the actor to
# `list` and closes an issue, and taking `list` for the verb suppresses the
# write. Value-less globals -- `--json`, `--quiet` and the rest -- need no
# entry, since a lone `-flag` is skipped anyway.
BD_OPT_ARGS = {"-C", "--dir", "--directory", "--db", "--actor",
               "--dolt-auto-commit"}

BD_DIR_OPTS = ("-C", "--dir", "--directory")

# The one global that names the store itself rather than a directory to look
# from. It has no short form, so only the two long spellings are read.
BD_DB_OPT = "--db"

# The environment `bd` reads its store from, in the order it consults them
# when no `--db` is given. `-C` sets BEADS_DIR before either is read, so a
# BEADS_DB inherited by the hook's own `bd -C <root>` calls does not redirect
# them; it is only consulted with neither `-C` nor BEADS_DIR in force. BD_DB
# is not read at all on the path that opens a store, so it is not listed.
BD_STORE_ENV = ("BEADS_DIR", "BEADS_DB")

# `bd`'s own short flags that take nothing, which its option parser lets stand
# in a bundle before one that does: `bd -qC/tmp/store close X` writes that
# store. Needed to read the attached form of `-C`, since the letters before it
# must be known to take nothing for the rest of the word to be its value.
BD_OPT_NOARG = {"-q", "-v", "-V", "-w", "-y"}

# `bd`'s long flags that take nothing under every command that has them, from
# `--help` across `bd` 1.3.1. The word after one is read as it stands rather
# than as a possible value: `bd ready --claim "${FLAG[0]}" /ext`, FLAG holding
# `-C`, writes /ext. A flag that takes a value under any command -- `bd create
# --description` does, `bd edit --description` does not -- is left out, as is
# any a later release adds, and may still take the word after it.
BD_LONG_NOARG = set("""
--agent --all --all-fields --allow-empty-description --allow-git-origin
--allow-non-loopback --allow-stale --analyze --any-replica --apply --assigned
--auto --auto-merge --beads --blocking --bootstrap-match --box --brief
--brief-deps --by-assignee --by-label --by-priority --by-status --by-type
--cascade --chain --check-health --children --claim --claim-next --clean
--closed --compact --conclude --continue --contributor --cpu-profile
--create-only --csv --current --debug --dedup --deep --deferred --delete
--details --discard-remote --dolt --dot --dry-run --eligible-only
--empty-description --ephemeral --escalate --events --explain --export
--external --fix --fix-child-parent --flat --follow --force
--force-git-tracked --from-jsonl --full --gated --global --help --history
--hook-json --html --ignore-references --ignore-schema-skew
--include-comments --include-deferred --include-dependents
--include-ephemeral --include-gates --include-infra --include-memories
--include-templates --init-if-missing --insecure-no-auth --inspect
--interactive --json --keep-children --list --local-time --long --mcp
--memories-only --milestones --no-activity --no-adopt --no-assignee --no-auto
--no-blocked --no-color --no-commit --no-create --no-cycle-check
--no-ephemeral --no-history --no-inherit-labels --no-labels --no-memories
--no-pager --no-parent --no-pinned --no-wait --non-interactive --open
--orchestrator --ours --overdue --parallel --parse-only --perf --persist
--persistent --pinned --plain --pour --prefer-ado --prefer-github
--prefer-gitlab --prefer-jira --prefer-linear --prefer-local --prefer-newer
--prefer-notion --pretty --print --proxied-server
--proxied-server-external-tls --proxied-server-external-tls-skip-verify
--pull --pull-if-stale --pull-only --push --push-only --quiet --readonly
--ready --reconcile --refs --reinit-local --relations --remove --repair
--reverse --root-only --sandbox --schema --scrub --sections --server
--server-tls --setup-exclude --shared --shared-server --short
--show-all-paths --silent --skip-agents --skip-decay --skip-dolt --skip-hooks
--skip-labels --skip-lint --stats --stdin --stdout --stealth --strict
--suggest-next --team-server --thanks --theirs --thread --tree --unassigned
--update-config --update-refs --update-repo-id --validate --verbose --version
--wait --watch --whats-new --wisps-plane --within-from-only --yes
""".split())

# The wrapper whose `VAR=value` arguments this scan reads as the environment it
# gives the command: `env OUT=/tmp/store bash -c 'bd -C "$OUT" ...'` writes
# /tmp/store, and resolving $OUT from the hook's own environment instead names
# some other store or none.
#
# `sudo` and `doas` also accept assignments and are deliberately not here. What
# reaches the child there is decided by a policy this scan cannot read -- with
# `env_reset` in force, which is the default, a name not on the keep list is
# dropped whatever the command line says. Such a name is reported unknowable
# rather than guessed, which `prefix_env` does by sealing the child's scope.
WRAPPER_ENV_WORDS = {"env"}
WRAPPER_ENV_UNREADABLE = {"sudo", "doas"}

# `env`'s options that remove one name from the environment, and those that
# replace the environment outright. A name `env` unset is unset in the child
# however the hook's own environment answers it. A lone `-` is the historical
# spelling of `-i`, which GNU `env` still honours; it is not a short bundle,
# so it is named here rather than left to the bundle reader, which took it for
# an option it did not know and abandoned the invocation.
ENV_UNSET_OPTS = ("-u", "--unset")
ENV_CLEAR_OPTS = {"-i", "--ignore-environment", "-"}

# The environment entry bash passes an exported function in, by name, and
# defines the function from in a new process; see `imported_functions`.
BASH_FUNC_ENTRY = re.compile(r"^BASH_FUNC_(.+)%%$")

# The options by which a wrapper runs the command somewhere other than here.
# Which store a `bd` invocation writes turns on the directory it runs in, so
# `env -C /other/repo bd close X` writes /other/repo's store: stepping over the
# directory as an opaque option value reported the store above the launch
# directory instead, committing one the command never opened while the one it
# wrote went unregistered. A wrapper that cannot change to the directory runs no
# command at all, so a write reported here happened there or not at all.
WRAPPER_CHDIR_OPTS = {
    "env": {"-C", "--chdir"},
    "sudo": {"-D", "--chdir"},
}

# The options by which a wrapper returns before the command it runs has
# finished, and those that make it wait after all. `sudo -b` runs the command
# in the background; `setsid -f` forks and returns unless `-w` is given, and
# forks without `-f` too whenever it starts as a process group leader, as
# every command is under job control. See `detaches`.
WRAPPER_DETACH_OPTS = {
    "setsid": {"-f", "--fork"},
    "sudo": {"-b", "--background"},
}
WRAPPER_WAIT_OPTS = {"setsid": {"-w", "--wait"}}

# `cd`'s own options, stepped over to find the operand. `-P` and `-L` decide
# how a `..` in it is read, which `cd_dest` settles; `-e` and `-@` say nothing
# about where it lands.
CD_OPT = re.compile(r"^-[LPe@]")

# The builtins besides `cd` that move the shell. `pushd /external; bd close X`
# writes /external's store, and a scan that knew only `cd` kept the old cwd and
# named the workspace store instead. `pushd dir` lands where `cd dir` would;
# the other forms -- a bare `pushd`, a rotation, any `popd` -- land on an entry
# of a stack only the shell holds, so the cwd is unknown after them.
CHDIR_WORDS = {"cd", "pushd", "popd"}
DIR_STACK_ROTATE = re.compile(r"^[-+][0-9]+$")

# A word among a wrapper's arguments that is an assignment. `env` and `sudo`
# take any non-empty name before the `=`, not only a shell identifier: `env
# 'X-Y=1' bd -C /external close X` runs `bd`. Matched against the identifier
# shape, the word was read as the command and the write was missed.
ASSIGN_WORD = re.compile(r"^[^=]+=")
IDENTIFIER = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")

# The arithmetic operators that assign to their left operand, and the unary
# ones that assign to their only operand. `((OUT=1)); bd -C "$OUT" close X`
# runs `bd -C 1`, and a scan that read `((...))` for its substitutions alone
# kept the value from before it and named a store the command never opened.
ARITH_ASSIGN_OPS = {"=", "+=", "-=", "*=", "/=", "%=", "<<=", ">>=", "&=",
                    "^=", "|="}
ARITH_STEP_OPS = {"++", "--"}
# Every operator arithmetic has, longest first, so the one at a node's `OpPos`
# is read whole: `<<=` before `<<` before `<`, `==` before `=`. Read out of the
# source for the same reason `JOIN_OPS` is -- the node's `Op` is a string in
# one installed shfmt and a table index in another, and under the latter no
# assignment matched, so `((OUT=1))` left OUT standing with no warning.
ARITH_OPS = sorted(
    ARITH_ASSIGN_OPS | ARITH_STEP_OPS |
    {"**", "<<", ">>", "<=", ">=", "==", "!=", "&&", "||", "+", "-", "*",
     "/", "%", "<", ">", "&", "|", "^", "!", "~", "?", ":", ","},
    key=len, reverse=True)
# The assignments in arithmetic that reached the scan as text rather than as a
# tree: `let "OUT=1"` is a quoted word, which the parser leaves whole. Each
# alternative names the variable an assignment or a step acts on; an `=` that
# is half of `==`, `<=`, `>=` or `!=` is not one.
ARITH_TEXT_ASSIGN = re.compile(
    r"(?<![A-Za-z0-9_])([A-Za-z_][A-Za-z0-9_]*)\s*(?:\[[^\]]*\])?\s*"
    r"(?:(?<![<>!=])(?:[-+*/%&^|]|<<|>>)?=(?!=)|\+\+|--)"
    r"|(?:\+\+|--)\s*([A-Za-z_][A-Za-z0-9_]*)")

# The builtins that read into shell variables, with the options of each that
# take a value -- so the value is not read as a name -- and what it assigns
# when no name is given. `read OUT; bd -C "$OUT" close X` writes wherever the
# input said, and a scan that knew nothing of `read` kept the value from
# before it.
READ_WORDS = {
    "read": ("adinNptu", ["REPLY"]),
    "mapfile": ("cCdnOsu", ["MAPFILE"]),
    "readarray": ("cCdnOsu", ["MAPFILE"]),
}
# `source` runs a file in this shell, and the file may assign, `unset`, `cd`
# or define anything: every value, attribute, function and the cwd are in
# doubt after it.
SOURCE_WORDS = {"source", "."}
# The builtins read for what they do to this shell. Named by a path, each is a
# program in a process of its own, if it is there at all, which cannot act on
# the shell: `/usr/bin/cd /decoy; bd close X` writes the store it started in.
SHELL_STATE_WORDS = CHDIR_WORDS | set(READ_WORDS) | {
    "unset", "set", "shopt", "eval", "getopts", "printf"}
# The `set -o` names of the options `set` is read for, by the letter that is
# their short form; see `set_builtin`.
SET_O_LETTERS = {"allexport": "a", "monitor": "m", "physical": "P"}

# What `env -S` splits its string on, and the escapes it decodes. Outside
# single quotes `\_` is a separator too, and inside double quotes it is a
# space; the string is argv and not shell text, so nothing else is syntax.
SPLIT_STRING_BLANKS = " \t\n\r\v\f"
SPLIT_STRING_ESCAPES = {"f": "\f", "n": "\n", "r": "\r", "t": "\t",
                        "v": "\v", "#": "#", "$": "$", '"': '"', "'": "'",
                        "\\": "\\"}
# A word the scan cannot read, as shell text: an expansion with an operator
# is unknowable to `expand` whatever `_` holds.
UNREADABLE_WORD = '"${_:-}"'

# The `NAME=` an assignment opens with, where NAME can stand unquoted.
ASSIGN_NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=")

# A word in the short-option form, whose letters may be followed by a value
# attached to the last of them: `-oL`, `-n10`, `-C/tmp/store`. `--` and the long
# forms are excluded, having rules of their own, and so is a bare `-`, which is
# an operand naming standard input rather than an option.
SHORT_BUNDLE = re.compile(r"^-[^-].*$")

# The tilde prefixes naming an entry of the shell's own directory stack, whose
# contents no other process can read: `~1`, `~+2`, `~-3`. The bare-digit form
# belongs here rather than to the passwd lookup, since that is what the shell
# does with it whatever the passwd database holds.
DIR_STACK_TILDE = re.compile(r"^~[-+]?[0-9]+$")

# The operators that join two commands, longest first so `|&` is read before
# the `|` it starts with, and the subset that makes both sides subshells.
#
# Read out of the source at the position the tree gives rather than from the
# tree's own `Op` code, which is an index into shfmt's operator table and moves
# when that table gains an entry. The codes differ between the shfmt CI installs
# (3.13 numbers `&&` 11, older ones do not), and a mismatch is silent: every
# operator reads as "not a pipe", so a `cd` in a pipeline is applied to the
# shell that never ran it.
JOIN_OPS = ("|&", "&&", "||", "|")
PIPE_OPS = ("|", "|&")

# How deeply the walk may nest before its own recursion is the problem rather
# than the command's.
#
# This is a limit on this process, not a judgement about the text, and the
# distinction is the whole point: a cap low enough to be reached by a command
# somebody wrote turns a real write into "no write", which is the one direction
# the scan must never fail in. It used to be 4, and a mutating `bd` under five
# substitutions -- or five `-c` wrappers -- was silently unreported, so the
# store was neither synced nor registered and SessionEnd could not rediscover
# it. Termination no longer rests on it either: the tree is finite, a re-parsed
# script is tracked by text so one containing itself is refused, and a function
# body by name in `calling`.
#
# So reaching it is a failure and not an answer. `Unavailable` is raised, which
# the bash side reads as a scan that did not happen and answers by syncing the
# roots and warning -- the same standing it gives a broken `shfmt`.
MAX_DEPTH = 64

# How many items a word-iterating `for` may have for its body to be scanned
# once per value. Past this the name is left unknown for the body instead, so a
# `-C` through it is reported unresolved rather than the scan running long. The
# cap is per loop, and a body nested in another such loop is scanned the
# product of the two counts, so it bounds no nesting; `MAX_STEPS` does.
FOR_ITEMS_MAX = 16

# How much work one scan may do, counted in statements visited, with each
# script parsed charged as `PARSE_STEPS` of them. Nesting multiplies work that
# no cap on one construct bounds: three nested 16-item loops visit 4,096 bodies,
# four 65,536 and five a million, and the hook is killed at 60s before it has
# recorded anything -- writes earlier in the command included. A statement
# costs 25 to 50 microseconds, the more for a `bd` whose store is walked for,
# and a parse, which starts `shfmt`, about 10 milliseconds, so the budget runs
# out within a few seconds.
#
# Reaching it is a failure and not an answer, as reaching `MAX_DEPTH` is:
# `Unavailable` is raised, and the hook syncs the roots and warns.
MAX_STEPS = 50000
PARSE_STEPS = 200

# How many closers may be appended to unbalanced text before it is abandoned.
MAX_REPAIRS = 8


# --- parsing --------------------------------------------------------------


class Unavailable(Exception):
    """The scan could not be attempted, as distinct from finding no write.

    A broken `shfmt` makes every command unscannable, and answering "no write"
    for all of them strands every bead write silently. The bash side reads a
    nonzero exit as this and syncs the roots as a precaution instead.
    """

# The completion shfmt names in each of the errors an incomplete command can
# raise. A `launch-process` command is often a fragment -- a here-document whose
# delimiter line never came, a function whose brace never closed, a bare `if`
# used as a keyword prefix -- and what the shell reading it does with the text
# is not the scanner's question. Refusing to parse loses every write in it,
# which for a `-C` target is the worst outcome available: the roots sync,
# nothing looks wrong, and the external store is never registered, so neither
# the marker retry nor SessionEnd can rediscover it. So the completion shfmt
# names is supplied and the parse retried, which is what the old tokeniser's
# open-state did implicitly.
def _q(pattern):
    """`pattern` with every backtick loosened to any quoting or none.

    shfmt names the tokens in its errors in backticks, but only since 3.9 --
    3.8 uses double quotes for some and nothing for others, and 3.8 is what
    `apt-get install shfmt` gives on the CI image. A pattern that requires one
    spelling matches nothing under the other, so no repair is found and a
    fragment that should parse is abandoned: the write is then reported with no
    target and its store goes unregistered, which is the silent outcome this
    whole repair path exists to avoid. The tokens are unambiguous without any
    quoting, so accepting all three spellings costs nothing.
    """
    return re.compile(pattern.replace("`", "[`\"]?"))


_INCOMPLETE = (
    (_q(r"unclosed here-document `(.+)`$"),
     lambda t, m: t + "\n" + m.group(1) + "\n"),
    (_q(r"matching `\{` with `\}`$"), lambda t, m: t + "\n}"),
    (_q(r"matching `\(` with `\)`$"), lambda t, m: t + "\n)"),
    (_q(r"matching `\$\(` with `\)`$"), lambda t, m: t + ")"),
    (_q(r"matching `\[\[` with `\]\]`$"), lambda t, m: t + "\n]]"),
    (_q(r"closing quote `(.)`$"), lambda t, m: t + m.group(1)),
    (_q(r"must be followed by `then`$"), lambda t, m: t + "\nthen :\nfi"),
    (_q(r"must be followed by `do`$"), lambda t, m: t + "\ndo :\ndone"),
    (_q(r"statement must end with `(fi|done|esac)`$"),
     lambda t, m: t + "\n" + m.group(1)),
    (_q(r"`then` can only be used in an `if`$"),
     lambda t, m: "if :\n" + t),
    (_q(r"`(do|done|fi|esac|elif|else)` can only be used"),
     lambda t, m: t.replace(m.group(1), ":", 1)),
)


# Where shfmt says the text stopped making sense, as `line:col:`.
_AT = re.compile(r"^(\d+):(\d+):")


def truncate(text, line):
    """`text` cut back to the position `line` reports, or None.

    The last resort for text no completion repairs -- a stray `)`, a `;;`
    outside a case. What precedes the offending token is still shell the
    scanner can read, and a write in it is still a write, so the prefix is
    parsed rather than the whole command abandoned.

    The column counts bytes, as every offset shfmt reports does, so the cut
    is found in the encoded text. Counted in characters, a non-ASCII
    character before the fault put the cut past the offending token, which
    then failed the same way again -- or past the end of the text, where the
    prefix was abandoned and the write in it with it.
    """
    match = _AT.match(line)
    if not match:
        return None
    row, col = int(match.group(1)), int(match.group(2))
    raw = text.encode("utf-8")
    lines = raw.splitlines(True)
    if row < 1 or row > len(lines):
        return None
    cut = sum(len(one) for one in lines[:row - 1]) + col - 1
    if not 0 < cut < len(raw):
        return None
    return raw[:cut].decode("utf-8", "ignore")


def parse(text):
    """The syntax tree of `text` and the text it was parsed from.

    The two are returned together because a repair changes the text, and the
    tree's offsets index what was parsed rather than what was passed in. A
    caller reading a node back out of the source needs the same string shfmt
    saw. `(None, text)` when it cannot be parsed at all.

    Raises `Unavailable` when shfmt could not be run, which is a different
    answer from "this text does not parse": no command can be scanned at all,
    so reporting it as a command that writes nothing would strand every write
    of every command for as long as the install stays broken.
    """
    for _ in range(MAX_REPAIRS):
        try:
            done = subprocess.run(["shfmt", "--to-json", "-"], input=text,
                                  capture_output=True, text=True)
        except OSError as err:
            raise Unavailable("shfmt could not be run: %s" % err)
        # shfmt exits 1 for text it cannot parse. Any other failure is the tool
        # itself, not the text -- a missing library, a binary that is not one.
        if done.returncode not in (0, 1):
            raise Unavailable("shfmt exited %d" % done.returncode)
        if done.returncode == 0:
            try:
                return json.loads(done.stdout), text
            except ValueError as err:
                raise Unavailable("shfmt emitted no readable tree: %s" % err)
        lines = done.stderr.strip().splitlines()
        repaired = None
        for line in reversed(lines):
            for pattern, repair in _INCOMPLETE:
                match = pattern.search(line)
                if match:
                    repaired = repair(text, match)
                    break
            if repaired is not None:
                break
        if repaired is None:
            repaired = truncate(text, lines[0]) if lines else None
        if repaired is None or repaired == text:
            return None, text
        text = repaired
    return None, text


# --- words ----------------------------------------------------------------

# The value of a word that names something this scan cannot know: a command
# substitution it does not run, or a variable with no value here. Distinct
# from the empty string, and it travels: a value is no more knowable once it
# has been through a variable than it was in the word, so `OUT=$(pwd)/store`
# followed by `bd -C "$OUT"` is unresolvable at both ends. Dropping the
# unknown part instead would not be vaguer, it would be wrong -- `$(pwd)/store`
# would come out as `/store`, which names a real directory that is not the one
# written.
UNKNOWN = object()

# A name a wrapper unset, as `env -u NAME` does. Distinct from UNKNOWN because
# the two answer differently where the environment is read: an unset
# `BEADS_DIR` leaves `bd` walking up from its directory, which this scan can
# follow, where one that cannot be read leaves the store in doubt. Expanded in
# a word it is as unknowable as any other unset name, since `get` does not
# answer for those either.
UNSET = object()

# How a wrapper sealed the child's environment against the names it did not
# carry. CLEARED is `env -i` and `exec -c`: a name not carried is certainly
# unset in the child. OPAQUE is a wrapper whose effect cannot be read -- `sudo`,
# `doas`, a prefix word this scan cannot resolve: a name not carried may hold
# anything. Both are true, and both leave the scope's own lookups unanswered;
# they differ only where a name's absence has a meaning of its own, as
# `BEADS_DIR`'s does. Reading CLEARED as OPAQUE left `cd /external/repo && env
# -i bd close X` unresolved, and the store the walk would have found unsynced.
CLEARED = "cleared"
OPAQUE = "opaque"

# The process group leadership of a shell that leads, in the statements before
# its last: it forks each of them into its group, where none leads, so only a
# command it runs with `exec` inherits the leadership; see `leading`.
EXEC_ONLY = "exec only"


class ShellOpts:
    """A SHELLOPTS that bash made, as the process it reaches holds it.

    bash keeps the variable in step with every option in force, its defaults
    among them -- `braceexpand:hashall:interactive-comments` before any is
    set -- and this scan follows only `physical` and `monitor`, and `posix`
    as far as it can. So the string is unknowable, as is a word expanding
    it, while whether it lists each of those is known: True, False or
    UNKNOWN, which is all a bash started from it reads.
    """

    __slots__ = ("physical", "monitor", "posix")

    def __init__(self, physical, monitor, posix):
        self.physical = physical
        self.monitor = monitor
        self.posix = posix

    def __eq__(self, other):
        return isinstance(other, ShellOpts) and \
            other.physical is self.physical and \
            other.monitor is self.monitor and other.posix is self.posix

    def __hash__(self):
        return hash(ShellOpts)


def opts_option(value, option):
    """Whether the SHELLOPTS `value` lists `option`, `physical`, `monitor` or
    `posix`: True, False or UNKNOWN.

    None or UNSET is a SHELLOPTS that is not there, which lists nothing.
    """
    if value is None or value is UNSET:
        return False
    if value is UNKNOWN:
        return UNKNOWN
    if isinstance(value, ShellOpts):
        return getattr(value, option)
    return option in value.split(":")


def bash_kind(word):
    """Whether the shell `word` names is bash: True, False, or UNKNOWN for
    `sh`, which is bash on some systems and another shell on others."""
    name = word.rsplit("/", 1)[-1]
    if name == "bash":
        return True
    return UNKNOWN if name == "sh" else False


def unescape(text):
    """A literal's value with the shell's backslash escapes applied.

    shfmt reports a literal as written, so `/tmp/a\\ b` arrives with its
    backslash still in it. Leaving it there makes the path a different one --
    and one that does not exist, which the `cd` case reads as a failure.
    """
    out = []
    i = 0
    while i < len(text):
        if text[i] == "\\" and i + 1 < len(text):
            out.append(text[i + 1])
            i += 2
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


# The characters a backslash still escapes inside double quotes. Before
# anything else it is an ordinary character and stays in the value.
DQ_ESCAPES = set('$`"\\')


def unescape_dquoted(text):
    """A literal's value with the escapes double quotes honour applied.

    Inside double quotes a backslash is only special before `$`, a backtick,
    `"`, another backslash, or a newline; anywhere else it is an ordinary
    character. So `"/tmp/a\\q"` is a path with a backslash in it, where the
    unquoted rules would read it as `/tmp/aq` -- a different store, and the
    one the command opened would go unregistered.
    """
    out = []
    i = 0
    while i < len(text):
        if text[i] == "\\" and i + 1 < len(text):
            nxt = text[i + 1]
            if nxt == "\n":
                # A line continuation: both characters go.
                i += 2
                continue
            if nxt in DQ_ESCAPES:
                out.append(nxt)
                i += 2
                continue
        out.append(text[i])
        i += 1
    return "".join(out)


# The single-character escapes of `$'...'`, and the digits its numeric ones
# are made of.
ANSI_C_ESCAPES = {"a": "\a", "b": "\b", "e": "\x1b", "E": "\x1b", "f": "\f",
                  "n": "\n", "r": "\r", "t": "\t", "v": "\v", "\\": "\\",
                  "'": "'", '"': '"', "?": "?"}
OCTAL_DIGITS = "01234567"
HEX_DIGITS = "0123456789abcdefABCDEF"


def take_digits(text, at, digits, most):
    """The run of `digits` in `text` from `at`, at most `most` long."""
    end = at
    while end < len(text) and end - at < most and text[end] in digits:
        end += 1
    return text[at:end]


def unescape_ansi_c(text):
    """The value of a `$'...'` word, or UNKNOWN when it is not text.

    shfmt reports the quoted body as written, and single quotes it is not:
    `$'/tmp/store\\x31'` names /tmp/store1, and the literal body names a path
    that does not exist, which the hook dropped in silence -- the write was
    found, the store it went to was not. The escapes are bash's: the single
    characters above, `\\nnn` octal and `\\xHH` hex bytes, `\\uHHHH` and
    `\\UHHHHHHHH` code points, and `\\cX` for a control character. Any other
    backslash is kept, as bash keeps it. The bytes are a C string, so a NUL
    ends the value; bytes that are not UTF-8 name nothing this scan can carry
    as text and are reported unknowable.
    """
    out = bytearray()
    i = 0
    while i < len(text):
        char = text[i]
        if char != "\\" or i + 1 >= len(text):
            out += char.encode("utf-8")
            i += 1
            continue
        nxt = text[i + 1]
        if nxt in ANSI_C_ESCAPES:
            out += ANSI_C_ESCAPES[nxt].encode("utf-8")
            i += 2
            continue
        if nxt in OCTAL_DIGITS:
            digits = take_digits(text, i + 1, OCTAL_DIGITS, 3)
            out.append(int(digits, 8) & 0xFF)
            i += 1 + len(digits)
            continue
        if nxt == "x":
            digits = take_digits(text, i + 2, HEX_DIGITS, 2)
            if digits:
                out.append(int(digits, 16))
                i += 2 + len(digits)
                continue
        elif nxt in "uU":
            digits = take_digits(text, i + 2, HEX_DIGITS,
                                 4 if nxt == "u" else 8)
            if digits:
                try:
                    out += chr(int(digits, 16)).encode("utf-8")
                except (ValueError, UnicodeEncodeError):
                    return UNKNOWN
                i += 2 + len(digits)
                continue
        elif nxt == "c" and i + 2 < len(text):
            ctrl = text[i + 2]
            width = 3
            # The backslash itself is written `\\c\\\\`.
            if ctrl == "\\" and text[i + 3:i + 4] == "\\":
                width = 4
            if ord(ctrl) >= 0x80:
                return UNKNOWN
            out.append(ord(ctrl.upper()) ^ 0x40)
            i += width
            continue
        out += ("\\" + nxt).encode("utf-8")
        i += 2
    raw = bytes(out).split(b"\0", 1)[0]
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        return UNKNOWN


# The body of a `$'...'` word: up to the quote no backslash escapes.
ANSI_C_BODY = re.compile(r"(?:[^'\\]|\\.)*", re.S)


def script_text(text):
    """`text` with the shell's quoting removed, read as script rather than
    parsed; see `shell_abandoned`.

    Quotes join what they quote, so `b"d"` runs `bd`, and so do `$'b\\x64'`
    and `$'\\142d'`, whose escapes are bash's, and `b` + backslash-newline +
    `d`, which a line continuation joins. Single quotes keep everything, a
    backslash-newline included, and double quotes keep a backslash before a
    character they do not escape; see `unescape_dquoted`. A body that is not
    text is kept as written, and a quote left open runs to the end.
    """
    out = []
    quote = None
    i = 0
    while i < len(text):
        char, nxt = text[i], text[i + 1:i + 2]
        if quote == "'":
            if char != "'":
                out.append(char)
            else:
                quote = None
            i += 1
        elif char == "\\" and nxt:
            if nxt != "\n":
                escapes = quote is None or nxt in DQ_ESCAPES
                out.append(nxt if escapes else char + nxt)
            i += 2
        elif char == '"' or (quote is None and char == "$" and nxt == '"'):
            quote = None if quote else '"'
            i += 1 if char == '"' else 2
        elif quote is None and char == "'":
            quote = "'"
            i += 1
        elif quote is None and char == "$" and nxt == "'":
            end = ANSI_C_BODY.match(text, i + 2).end()
            body = text[i + 2:end]
            value = unescape_ansi_c(body)
            out.append(body if value is UNKNOWN else value)
            i = end + 1
        else:
            out.append(char)
            i += 1
    return "".join(out)


def is_pattern(text):
    """Whether the unquoted literal `text` is one the shell matches on paths.

    `*` and `?` always are. `[` is only with a `]` later in the same word to
    close it -- a lone `[` is the test command, and `a[1]` is a pattern while
    `a[` is not. A backslash takes the character after it out of
    consideration, as `unescape` will later take the backslash out.
    """
    i = 0
    while i < len(text):
        char = text[i]
        if char == "\\":
            i += 2
            continue
        if char in "*?":
            return True
        if char == "[" and "]" in text[i + 2:]:
            return True
        i += 1
    return False


def word_parts(word, quoted=False, nulls=False):
    """The parts of `word`, each with whether quoting protects it.

    Double quotes group their contents rather than adding a part of their own,
    so they are flattened -- but which side of them a part sits on decides both
    what its backslashes mean and whether an expansion inside it is split, so
    the context travels with the part instead of being discarded. With
    `nulls`, an empty pair is a quoted empty literal, as `''` is, where a
    field's count turns on it; see `split_fields`.
    """
    for part in word.get("Parts") or ():
        if part["Type"] == "DblQuoted":
            if nulls and not part.get("Parts"):
                yield {"Type": "Lit", "Value": ""}, True
            for inner, _ in word_parts(part, True):
                yield inner, True
        else:
            yield part, quoted


# What splits an unquoted expansion when nothing has assigned IFS, and the
# value zsh starts with, which adds a NUL.
DEFAULT_IFS = " \t\n"
ZSH_DEFAULT_IFS = " \t\n\0"

# The shells that start with the default IFS whatever their environment holds,
# as checked for bash 3.2 and 5.2, dash and zsh 5.9. POSIX lets a shell import
# it instead, so the others keep the view their environment gives them.
IFS_RESET_SHELLS = {"sh", "bash", "dash", "zsh"}


class Field:
    """One argument of a command, after expansion.

    `tilde` says the field began with an unquoted `~`, which names $HOME, and
    is true only of the first field a word produces. `assign` is the name an
    unreadable field certainly assigns, as a wrapper reads it; see
    `assignment_name`. `split` says an unreadable field may stand for several
    arguments or none; see `may_split`. `dash` says it may begin with a `-`,
    and so be an option; see `may_be_option`.
    """

    __slots__ = ("value", "tilde", "assign", "split", "dash")

    def __init__(self, value, tilde=False, assign=None, split=False,
                 dash=False):
        self.value = value
        self.tilde = tilde
        self.assign = assign
        self.split = split
        self.dash = dash


def may_be_option(word):
    """Whether `word` may expand to text opening with a `-`.

    Unless it opens with text the parse already holds, its first character
    is unknown: `FLAG=-C; bd "${FLAG[0]}" /ext close X` passes `-C /ext`,
    though the word is quoted and stays one argument. `"CHR-$N"` cannot be
    an option.
    """
    for part, _ in word_parts(word):
        if part["Type"] not in ("Lit", "SglQuoted"):
            return True
        text = part.get("Value", "")
        if text:
            return text[0] in "-\\"
    return False


def expands_elements(part, raw=None):
    """Whether the parameter expansion `part` makes a field of each element
    it reads, quoted or not.

    `"$@"` and `"${A[@]}"` do, with any operator after them, and so do
    `"${!A[@]}"`, the keys, and `"${!P@}"`, the names that start with P.
    `"${A[*]}"`, `"${!P*}"` and a length, `"${#A[@]}"`, are one field.

    Which of `*` and `@` closes a `${!P...}` is read out of `raw`, the
    encoded source, just before the closing brace: shfmt names the operator
    as text in some versions and as an index into its operator table in
    others, where the index moves; see `join_op`. Unreadable, it may be `@`.
    """
    if part.get("Length"):
        return False
    names = part.get("Names")
    if names:
        if names in ("*", "@"):
            return names == "@"
        try:
            at = part["Rbrace"]["Offset"] - 1
        except (KeyError, TypeError):
            return True
        return raw is None or raw[at:at + 1] != b"*"
    index = (part.get("Index") or {}).get("Parts") or ()
    if len(index) == 1 and index[0]["Type"] == "Lit" and \
            index[0].get("Value") == "@":
        return True
    return part["Param"]["Value"] == "@"


def may_split(word, raw=None):
    """Whether `word` may expand to other than one argument.

    An unquoted expansion is split on IFS and an unquoted pattern matched on
    paths, so `bd $OPTS close X`, OPTS holding `-C /ext`, passes `-C` and
    `/ext` as two arguments, where `"$OPTS"` stays one. A process
    substitution is one path whatever it runs. Quoting does not hold
    elements together, though: `A=(unused BEADS_DIR=/ext/.beads); env
    OUT="${A[@]}" bd close X` passes `env` both, and read as one OUT
    assignment the store it selects was missed; see `expands_elements`,
    which `raw` is passed to.
    """
    for part, quoted in word_parts(word):
        kind = part["Type"]
        if kind == "ParamExp" and expands_elements(part, raw):
            return True
        if quoted or kind in ("SglQuoted", "ProcSubst"):
            continue
        if kind != "Lit" or is_pattern(part.get("Value", "")):
            return True
    return False


def assignment_name(word, raw=None):
    """The name `word` assigns as one argument, whatever its value, or None.

    `env OUT="$(pwd)" bash -c ...` hands `env` an assignment whose value this
    scan cannot read, but which is certainly one argument and an assignment:
    it opens with an unquoted `NAME=`, and nothing in it is split or matched
    on paths. Read as an unknown word it was taken for the command, and the
    write behind it was missed. A word that may split may supply the command
    itself, so it is no such argument.

    The literal is read with its escapes applied, as the wrapper receives it:
    `env BEADS\\_DIR="$(...)" bd close X` assigns BEADS_DIR, and matched as
    written the name kept its backslash and BEADS_DIR looked unset.
    """
    parts = list(word_parts(word))
    if not parts or parts[0][1] or parts[0][0]["Type"] != "Lit" or \
            may_split(word, raw):
        return None
    match = ASSIGN_WORD.match(unescape(parts[0][0].get("Value", "")))
    if not match or match.group(0).startswith("-"):
        return None
    return match.group(0)[:-1]


def split_fields(segments, separators, keep_nulls=False):
    """The fields `segments` make, splitting only where splitting applies.

    Each segment is `(text, splittable)`. Splitting is a property of the text's
    origin rather than of the word, so it is resolved across the assembled
    segments rather than within each: `a$X` with X=` b` is two fields, since
    the separator the expansion supplied ends the field the literal began,
    while `"a$X"` is one.

    The two kinds of separator split differently. IFS whitespace -- the space,
    tab and newline in IFS -- is skipped at either end and any run of it is
    one split. Any other IFS character is a delimiter each time it occurs,
    with the IFS whitespace around it absorbed, so two in a row bound an empty
    field and one at the start opens with one; only one at the end closes
    nothing. Reading every separator as whitespace dropped the empty fields,
    and with `IFS=:` and `OPTS='-p::bd'`, `sudo $OPTS -C /external close X`
    -- which runs `sudo -p '' bd ...` -- lost the empty prompt, took `bd` for
    the prompt and missed the write.
    """
    whitespace = {char for char in separators if char in DEFAULT_IFS}
    fields = []
    current = None
    # Whether a delimiter that is not whitespace would bound an empty field
    # here: at the start, and after another such delimiter, it does; after a
    # field closed by whitespace it is the whitespace's own split.
    empty_next = True
    # Whether anything has been read yet. In bash 3.2 a quoted null -- `""`
    # -- opens a field of its own only before anything else has: `$X""` with
    # X unset is one empty argument, and with X=` ` or X=`a:` it is none and
    # one. Later bash and dash open one wherever it stands, making those one
    # and two, which is how `keep_nulls` reads it.
    seen = False
    for text, splittable in segments:
        if not splittable:
            if text or current is not None or not seen or keep_nulls:
                current = (current or "") + text
            seen = seen or bool(text)
            continue
        for char in text:
            seen = True
            if char in whitespace:
                if current is not None:
                    fields.append(current)
                    current = None
                    empty_next = False
            elif char in separators:
                if current is not None:
                    fields.append(current)
                    current = None
                elif empty_next:
                    fields.append("")
                empty_next = True
            else:
                current = (current or "") + char
    if current is not None:
        fields.append(current)
    return fields


def split_string_words(text):
    """The words `env -S text` makes, or None when `env` rejects the string.

    `-S` is not a shell. The string is split on unquoted blanks and on `\\_`,
    quotes group, `\\_` inside double quotes is a space, `#` opening a word
    comments out the rest, `\\c` ends the string, and the escapes in
    `SPLIT_STRING_ESCAPES` are decoded -- inside single quotes only `\\'` and
    `\\\\`. Nothing else is syntax: `env -S 'cd /x && bd close X'` runs a
    program called `cd`, and `env -S 'bd\\_-C\\_/external\\_close\\_X'` runs
    `bd`. Read as shell text, the first was a `cd` and the second one word
    that was not `bd`, so a write was missed with no warning.

    `${NAME}` is the one expansion, and comes back as `("var", NAME)` for the
    caller to answer from the environment `env` itself has. An escape `env`
    does not know, a `$` not opening one, or an unclosed quote is an error on
    which `env` runs nothing; None says so. GNU's manual documents all of
    this and BSD `env` behaves the same, checked on macOS.

    Each word is a list of literal strings and `("var", NAME)` pairs.
    """
    words = []
    parts = []
    buf = ""
    in_word = False
    quote = None
    i = 0
    n = len(text)

    def end_word():
        nonlocal parts, buf, in_word
        if buf:
            parts.append(buf)
            buf = ""
        if in_word:
            words.append(parts)
            parts = []
            in_word = False

    while i < n:
        char = text[i]
        if quote is None:
            if char in SPLIT_STRING_BLANKS:
                end_word()
                i += 1
                continue
            if char == "#" and not in_word:
                break
            if char in "'\"":
                quote = char
                in_word = True
                i += 1
                continue
        elif char == quote:
            quote = None
            i += 1
            continue
        if char == "\\":
            i += 1
            if i >= n:
                return None
            esc = text[i]
            i += 1
            if quote == "'":
                buf += esc if esc in "'\\" else "\\" + esc
                in_word = True
                continue
            if esc == "c":
                if quote is not None:
                    return None
                end_word()
                return words
            if esc == "_":
                if quote is None:
                    end_word()
                else:
                    buf += " "
                continue
            if esc not in SPLIT_STRING_ESCAPES:
                return None
            buf += SPLIT_STRING_ESCAPES[esc]
            in_word = True
            continue
        if char == "$" and quote != "'":
            if i + 1 >= n or text[i + 1] != "{":
                return None
            close = text.find("}", i + 2)
            name = text[i + 2:close] if close >= 0 else ""
            if not IDENTIFIER.match(name):
                return None
            if buf:
                parts.append(buf)
                buf = ""
            parts.append(("var", name))
            in_word = True
            i = close + 1
            continue
        buf += char
        in_word = True
        i += 1
    if quote is not None:
        return None
    end_word()
    return words


def opens_tilde(word):
    """Whether `word` began with an unquoted `~`, which names $HOME."""
    parts = word.get("Parts") or ()
    if not parts or parts[0]["Type"] != "Lit":
        return False
    return parts[0].get("Value", "").startswith("~")


def bead_root(start):
    """The directory whose `.beads` `bd` would select from `start`, or None.

    `bd` finds its store by walking up from the directory it runs in, so the
    store a command writes is often named by no word of it: `cd /other/repo &&
    bd close X` writes /other/repo/.beads, and `bd -C repo/sub close X` writes
    repo/.beads rather than repo/sub/.beads. Reported as the directory holding
    the store, which is what the hook syncs and records.

    None when no ancestor holds one, which is the honest answer for a store that
    does not exist yet: `bd` itself fails there, so there is nothing to sync. It
    is also the answer for a path this process cannot read, where a guess would
    name some other store.

    The filesystem is read here, as `cd` already does. The alternative -- taking
    the path as given -- is what named a subdirectory that holds no `.beads`,
    which the hook then skipped, leaving the write it described unsynced.

    The walk is the one `bd` makes: it cleans `..` out of the path by name,
    resolves the symlinks in what is left, and walks up from the directory that
    names. With `link` pointing at /ext/child, `/ws/link` opens /ext's store
    rather than /ws's, and walking up the spelled path named /ws -- a store the
    command never opened, while the one it wrote went unsynced. The answer keeps
    the command's spelling when that names the same directory, so a root still
    matches the workspace root it is.
    """
    if not start.startswith("/"):
        return None
    spelled = os.path.normpath(start)
    found = nearest_store(os.path.realpath(spelled))
    if found is None:
        return None
    named = nearest_store(spelled)
    if named is not None and same_dir(named, found):
        return named
    return found


def nearest_store(path):
    """The nearest of `path` and its ancestors holding a `.beads`, or None."""
    while True:
        if os.path.isdir(os.path.join(path, ".beads")):
            return path
        parent = os.path.dirname(path)
        if parent == path:
            return None
        path = parent


def same_dir(one, other):
    """Whether `one` and `other` are the same directory."""
    try:
        return os.path.samefile(one, other)
    except OSError:
        return False


def chdir_path(path):
    """The directory a `chdir` to the absolute `path` lands in, as `getcwd`
    then names it.

    The kernel resolves each symlink before the `..` after it, so with `link`
    pointing at /ext/child, `/ws/link/..` is /ext -- where `cd -P`, `env -C`
    and `sudo -D` all go -- and not the /ws that collapsing it by name gives.
    Every link is resolved, not only those before a `..`: after `cd -P
    /ws/link` the shell's PWD is /ext/child, so a later `cd ..` lands in /ext,
    and keeping the spelling /ws/link sent the scan to /ws instead.
    """
    return os.path.realpath(path)


def logical_path(path):
    """The absolute `path` with `.` and `..` collapsed by name, as a logical
    `cd` reads it, or None when bash refuses that reading.

    bash checks that each directory a `..` leaves exists, and that the result
    does: `cd /ws/missing/..` fails rather than landing in /ws, and the shell
    stays where it was. Collapsing by name alone moved the scan to /ws.
    """
    parts = []
    for part in path.split("/"):
        if part in ("", "."):
            continue
        if part == "..":
            if not os.path.isdir("/" + "/".join(parts)):
                return None
            parts = parts[:-1]
            continue
        parts.append(part)
    result = "/" + "/".join(parts)
    return result if os.path.isdir(result) else None


def cd_dest(target, physical):
    """Where a `cd` to the absolute `target` lands, or None when it fails.

    By default `cd` collapses `..` by name, so `cd /ws/link/..` is /ws whatever
    `link` points at, and takes the kernel's reading only when bash refuses
    that one; see `logical_path`. `cd -P`, or any `cd` under `set -P`, takes
    the kernel's reading outright: with `link` pointing at /ext/child it lands
    in /ext, and reading it by name there named /ws, a store the command never
    opened. UNKNOWN when `set -P` may or may not be in force and the two
    readings differ.
    """
    if physical is UNKNOWN:
        logical = cd_dest(target, False)
        return logical if logical == cd_dest(target, True) else UNKNOWN
    if not physical:
        spelled = logical_path(target)
        if spelled is not None:
            return spelled
    if os.path.isdir(target):
        return chdir_path(target)
    return None


def store_root(path):
    """The root holding the store a `--db` or BEADS_DB value names.

    Either takes the `.beads` directory or a file inside it, and `bd` reads
    the value the same way for both: it takes the parent, opens that if it is
    itself a `.beads`, and otherwise walks up from it looking for one -- so
    `/repo/.beads`, `/repo/.beads/` and `/repo/.beads/beads.db` all open
    /repo's store, and `/repo/sub/x.db` opens it too. Every other path this
    scan reports names the root holding a `.beads`, which is what the hook
    syncs and records, so the value is brought to that shape by the same
    steps.

    When the walk finds nothing, `bd` treats the parent as the store and
    bootstraps one there, so the parent's own parent is what stands for the
    root. It holds no `.beads`, and the hook drops it as no root -- which is
    the right end for a store that did not exist before the command ran.

    The trailing separator comes off first: `/repo/.beads/` is the same
    directory written with one after it, and taking the empty component for
    the file left `/repo/.beads` as the parent, whose own `.beads` does not
    exist.
    """
    trimmed = path.rstrip("/") or "/"
    parent = trimmed.rpartition("/")[0] or "/"
    above = parent.rpartition("/")[0] or "/"
    if parent.rpartition("/")[2] == ".beads":
        return above
    return bead_root(parent) or above


def short_opts(word, takes, alone):
    """How a bundle of short flags ends, as `(letters, opt, inline)`.

    A short option's value may be attached to it -- `stdbuf -oL`, `nice -n10`,
    `sudo -unick`, `bd -C/tmp/store` -- and may sit at the end of a bundle of
    flags that take nothing, as `bd -qC/tmp/store`. Treated as whole words, none
    of those matched either table: the wrapper forms made the invocation
    ambiguous, which abandons it and misses the write itself, and `bd -C/dir`
    lost its target while the write was still found.

    `letters` is the flags read before any value began. `opt` is the option
    taking a value, or None when the bundle takes none, and `inline` is the
    value attached to it, or None when the value is the word after it. The
    result is None when the bundle holds a letter neither table knows: it may be
    the one that takes the value, and either guess misplaces what follows.

    Only for the short forms. `--opt=value` carries its value by a rule of its
    own, and a long flag is never bundled.
    """
    if not SHORT_BUNDLE.match(word):
        return None
    letters = []
    for index, char in enumerate(word[1:], start=1):
        opt = "-" + char
        if opt in takes:
            return "".join(letters), opt, word[index + 1:] or None
        if opt not in alone:
            return None
        letters.append(char)
    return "".join(letters), None, None


def gives_value(arg):
    """Whether the assignment `arg` gives its name one value.

    `X=` assigns the empty string, and the parse gives it no value node at all
    rather than an empty one, so a test for the node read it as no assignment
    and left the name answering with whatever was inherited -- a store the
    command never opened.

    The forms that give no single value are excluded: `export X` names an
    existing value without changing it, which the parse marks `Naked`;
    `A=(1 2)` is an array and `A[2]=x` sets one element of one, for which see
    `replaces_value`; and `X+=`, having nothing to append, leaves the value it
    had.
    """
    if not arg.get("Name") or arg.get("Naked"):
        return False
    if arg.get("Array") or arg.get("Index"):
        return False
    return bool(arg.get("Value")) or not arg.get("Append")


def replaces_value(arg):
    """Whether the assignment `arg` may give its name a value this scan does
    not read.

    `$X` is element zero of an array, so `X=(/tmp/a /tmp/b)` makes it /tmp/a,
    `X[0]=/tmp/c` makes it /tmp/c, `X=()` empties it, `X+=(/tmp/d)` fills it
    when it was unset, and `X[i]=/tmp/e` does any of these for an `i` this scan
    does not evaluate. Left at the value from before, as the forms that assign
    nothing are, `X=(/real); bd -C "$X" close X` named the old store while the
    write landed in the new one. None of them is one value to record, so the
    name is forgotten instead.
    """
    if not arg.get("Name") or arg.get("Naked"):
        return False
    return bool(arg.get("Array") or arg.get("Index"))


class Scope:
    """The shell state a subshell inherits and may change without effect.

    A subshell -- `( )`, a substitution, a pipeline member, a backgrounded
    command, a shell wrapper's script -- gets the cwd and assignments in force
    and its changes die with it, so a frame is entered around it and dropped
    after. Writes found inside stay in the result, which is a finding about the
    command rather than state of the shell running it.
    """

    def __init__(self, cwd, known, assigns, sealed=False, exported=None,
                 allexport=False, lastpipe=False, monitor=False,
                 physical=False, spelled=True, bash=True, zsh=False):
        self.cwd = cwd
        self.known = known
        # Whether `cwd` is also how the shell's PWD spells the directory:
        # True; False where the PWD is one of two spellings of it, through a
        # symlink or not, so a `..` read from it may climb out either way; and
        # UNKNOWN where the PWD it inherits cannot be read at all, so it may
        # hold a `..` after a symlink itself and nothing read from it by name
        # is known -- a relative path, `$PWD`, or the walk `bd` makes, which
        # collapses the PWD it inherits by name. See `wrapper_pwd`.
        self.spelled = spelled
        # Whether anything in this frame acted on the cwd -- a `cd` taken or
        # given up on, a wrapper's directory, a sealed scope. A tentative
        # frame that never did leaves its caller's cwd standing; see
        # `tentative`.
        self.moved = False
        self.assigns = assigns
        # False, CLEARED or OPAQUE: whether this scope's environment was
        # replaced rather than added to, as `env -i` does, and if so whether
        # what replaced it can be read. A name not assigned here is then unset
        # or unknowable rather than inherited, so the hook's own environment
        # must not answer for it either way.
        self.sealed = sealed
        # Which names reach a child process, where the text has said: True
        # after `export X`, False after `export -n X` or `unset X`, UNKNOWN
        # when the text may or may not have said it. A name absent here is
        # exported exactly when it was inherited from the environment, since
        # an assignment keeps the attribute the name already had. A shell
        # variable is not an environment variable: `BEADS_DIR=/x; bd close`
        # runs `bd` with no BEADS_DIR at all unless something exported it, and
        # reading every assignment as exported named a store `bd` never saw.
        self.exported = {} if exported is None else exported
        # `set -a` in force: every later assignment is exported. UNKNOWN when
        # a `set -a` may or may not have run.
        self.allexport = allexport
        # `shopt -s lastpipe` in force: the last member of a pipeline runs in
        # this shell rather than a subshell, so `true | cd /external; bd close
        # X` writes /external's store -- as long as job control is off, which
        # `monitor` says. Both UNKNOWN when the text may or may not have set
        # them. Job control is off in the non-interactive shell the hook's
        # commands run in until a `set -m` turns it on.
        self.lastpipe = lastpipe
        self.monitor = monitor
        # `set -P` in force: a `cd` resolves symlinks before `..`, as the
        # kernel does, rather than collapsing `..` by name; see `cd_dest`.
        # UNKNOWN when the text may or may not have set it.
        self.physical = physical
        # Whether this shell is bash, whose SHELLOPTS is no stored value but
        # its options as they stand, and readonly: True, False for any other
        # -- dash, zsh, or what `env -S` runs, which is no shell at all -- and
        # UNKNOWN for `sh`. The command itself runs in bash.
        self.bash = bash
        # Whether this shell is zsh, which unlike the others ignores a CDPATH
        # in a `cd`'s own prefix; see `cd_path`.
        self.zsh = zsh

    def child(self):
        return Scope(self.cwd, self.known, dict(self.assigns), self.sealed,
                     dict(self.exported), self.allexport, self.lastpipe,
                     self.monitor, self.physical, self.spelled, self.bash,
                     self.zsh)

    def last_member_stays(self):
        """Whether a pipeline's last member runs in this shell: True, False
        or UNKNOWN."""
        if self.lastpipe is False or self.monitor is True:
            return False
        if self.lastpipe is UNKNOWN or self.monitor is UNKNOWN:
            return UNKNOWN
        return True


class Scanner:
    """Walks a command's syntax tree and records the stores it writes."""

    def __init__(self, launch_cwd, text=""):
        self.mutates = False
        self.targets = []
        # How many `-C` targets were named and could not be resolved to a path,
        # plus the scripts that could not be read at all -- an `eval "$X"` may
        # carry such a target. Reported separately from the targets themselves
        # because it is the one thing a later invocation cannot rediscover: the
        # roots sync, but the store named here is not among them and nothing
        # else names its path.
        self.unresolved = 0
        self.launch_cwd = launch_cwd
        # The text the tree was parsed from, so a node can be read back where
        # the tree gives an offset but not the source it came from. Kept encoded
        # as well, since shfmt's offsets count bytes and a Python index counts
        # characters -- see `join_op`.
        self.text = text
        self.raw = text.encode("utf-8")
        # An empty launch directory means the event did not say where the tool
        # call ran, which is not the same as its having run here: this process
        # need not share that directory, so resolving a relative target against
        # its cwd names a store under some unrelated path. Unknown from the
        # start instead, which leaves such a target unresolved.
        #
        # The shell the command runs in imports an inherited SHELLOPTS, so one
        # listing `physical` starts it in physical mode, and one listing
        # `monitor` with job control; see `shellopts_option`. It sets and
        # exports PWD as it starts, whatever this process's environment
        # holds; see `sub_scan`.
        opts = os.environ.get("SHELLOPTS", "").split(":")
        self.scope = Scope(launch_cwd, bool(launch_cwd), {},
                           exported={"PWD": True},
                           monitor="monitor" in opts,
                           physical="physical" in opts)
        self.depth = 0
        # Bodies of the functions defined so far, by name, each with the text
        # it was parsed from, and the names whose bodies are being scanned
        # right now. A body is scanned twice -- once where it is defined and
        # once at each call -- so the same store can be named more than once;
        # a repeated target is dropped rather than reported twice, since a
        # caller would sync it twice for no purpose.
        self.functions = {}
        self.calling = set()
        # Whether the table has been put in doubt, so that a command named
        # first may be a function it does not list; see `seal_opaque`.
        self.functions_sealed = False
        # The names of the functions `export -f` exported, or UNKNOWN; see
        # `imported_functions`.
        self.function_exports = set()
        # The variables unset, and the number of seals, so far; see
        # `call_function`.
        self.unset_names = set()
        self.seals = 0
        # The scripts being scanned right now, by their text. What makes text
        # that contains itself terminate: `s='eval "$s"'` names the same script
        # at every level, so the second sight of it is refused. Held by text
        # rather than counted, since the count cannot tell that case from a
        # command legitimately nested deep.
        self.scripts = set()
        # The work done so far; see `MAX_STEPS`.
        self.steps = 0
        # How many of the frames being scanned the shell does not wait for,
        # and the stores written inside one; see `in_background`.
        self.background = 0
        self.async_targets = set()
        # Whether the frames being scanned run in a process a `setsid` made a
        # process group leader, which an `exec` or `env -S` keeps, or
        # EXEC_ONLY; see `detaches` and `leading`.
        self.leader = False
        # The scope each command a wrapper moved was invoked from, by the
        # command's node; see `call`.
        self.callers = {}

    def found_target(self, path):
        if path not in self.targets:
            self.targets.append(path)
        if self.background:
            self.async_targets.add(path)

    def spend(self, steps):
        """Charges `steps` to the scan's budget, raising once it is spent."""
        self.steps += steps
        if self.steps > MAX_STEPS:
            raise Unavailable("more work than %d steps" % MAX_STEPS)

    # --- assignment state -------------------------------------------------

    def is_exported(self, name):
        """Whether `name` reaches a child process: True, False or UNKNOWN.

        What the text said wins; otherwise a name is exported exactly when it
        was inherited, since assigning to an inherited name keeps its export
        attribute. A cleared environment inherited nothing, and an opaque one
        may have inherited anything.
        """
        if name in self.scope.exported:
            return self.scope.exported[name]
        if self.scope.sealed is OPAQUE:
            return UNKNOWN
        if self.scope.sealed is CLEARED:
            return False
        return name in os.environ

    def environment_view(self, sealed):
        """The names this scope hands a new process, as that process sees them.

        A new process inherits the exported names and none of the rest, so a
        name the text assigned without exporting is unset there whatever value
        it holds here: `OUT=/real; bash -c 'bd -C "$OUT" close X'` runs `bd -C
        /store`, since the child's `$OUT` is empty. Copying the scope whole
        into the child resolved that against /real -- and did so even through
        `env -i`, which hands the child nothing at all. Under `sealed` every
        name is unset (CLEARED) or unknowable (OPAQUE), as the wrapper made it.

        Returns `(assigns, exported)` for the child scope. A name unset in the
        child is recorded as not exported there too, so a later plain
        assignment to it stays a shell variable: `unset` dropped the attribute
        with the value.
        """
        assigns = {}
        exported = {}
        missing = object()
        for name in set(self.scope.assigns) | set(self.scope.exported):
            value = self.scope.assigns.get(name, missing)
            if sealed is CLEARED:
                state = False
            elif sealed is OPAQUE:
                state = UNKNOWN
            elif value is UNSET:
                state = False
            else:
                state = self.is_exported(name)
            if state is UNKNOWN:
                assigns[name] = UNKNOWN
                exported[name] = UNKNOWN
            elif not state:
                assigns[name] = UNSET
                exported[name] = False
            elif value is not missing:
                assigns[name] = value
                exported[name] = True
            else:
                exported[name] = True
        # bash hands a child the SHELLOPTS its options make now, not the one
        # it inherited; see `ShellOpts`.
        if not sealed and self.scope.bash is not False:
            state = self.is_exported("SHELLOPTS")
            if state is True:
                assigns["SHELLOPTS"] = ShellOpts(
                    self.carried_option("physical"),
                    self.carried_option("monitor"),
                    self.carried_option("posix"))
                exported["SHELLOPTS"] = True
            elif state is UNKNOWN:
                assigns["SHELLOPTS"] = UNKNOWN
                exported["SHELLOPTS"] = UNKNOWN
        return assigns, exported

    def get(self, name):
        """The value of `name` here, or UNKNOWN when nothing names it.

        An assignment the text made wins, and otherwise the environment the
        hook runs with, which is the environment the tool call was launched
        with. Nothing is executed to answer this: a `launch-process` command is
        its own shell, so a variable it uses is either assigned in the same
        text -- which the walk has recorded, in order -- or inherited.
        """
        # bash's SHELLOPTS lists options this scan does not follow, so `bd -C
        # "/tmp/$SHELLOPTS"` names a store it cannot read; see `ShellOpts`.
        if name == "SHELLOPTS" and self.scope.bash is not False:
            return UNKNOWN
        if name in self.scope.assigns:
            value = self.scope.assigns[name]
            return UNKNOWN if value is UNSET or isinstance(value, ShellOpts) \
                else value
        # `PWD` is the one name the inherited environment answers wrongly. The
        # hook runs in its own process, whose cwd is not the launch directory
        # the command runs in and does not follow the `cd`s the command makes,
        # so the tracked cwd answers it instead -- and where that is unknown,
        # so is this. An explicit assignment still wins, which the lookup above
        # has settled: the shell lets `PWD=/decoy` stand and expands what it
        # was told.
        #
        # `OLDPWD` is left unanswered for the same reason `cd -` is: the
        # directory it names is in the launching shell's history, not here.
        if name == "PWD":
            return self.scope.cwd if self.scope.known and \
                self.scope.spelled is True \
                else UNKNOWN
        if name == "OLDPWD":
            return UNKNOWN
        if self.scope.sealed:
            return UNKNOWN
        # An inherited name set to the empty string has a value, and it is the
        # empty string. Reading that as "nothing names it" made the word
        # carrying it unknowable, so `EMPTY=; bd -C "$EMPTY/tmp/store" close X`
        # -- which writes /tmp/store -- reported no target at all, leaving an
        # external store unregistered and unpushed.
        if name not in os.environ:
            return UNKNOWN
        return os.environ[name]

    # --- word evaluation --------------------------------------------------

    def separators(self):
        """The characters that split an unquoted expansion here.

        IFS assigned in the same text is honoured, since a command that sets it
        splits by it. An IFS whose value this scan cannot read leaves splitting
        unknowable, which `expand` reports rather than guesses: assuming the
        default would split a field the command kept whole, and assuming none
        would keep one the command split.

        An IFS that is unset splits as the default does -- that is the shell's
        rule for it -- so `unset IFS` is not an unreadable one. Read as a
        value, the sentinel broke the scan, and the roots synced by the
        fallback while an external target went unregistered.
        """
        if "IFS" in self.scope.assigns:
            got = self.scope.assigns["IFS"]
            if got is UNKNOWN:
                return UNKNOWN
            if got is UNSET:
                return set(DEFAULT_IFS)
            return set(got)
        return set(DEFAULT_IFS)

    def shell_var(self, name):
        """The shell variable `name` here: its value, None if unset, UNKNOWN.

        Unlike `get`, which answers for a word and so reads "unset" as a value
        it cannot supply, this tells unset from unreadable: `CDPATH` unset
        means `cd` searches nothing, where an unreadable one means it may
        search anywhere.
        """
        if name in self.scope.assigns:
            value = self.scope.assigns[name]
            return None if value is UNSET else value
        if self.scope.sealed is OPAQUE:
            return UNKNOWN
        if self.scope.sealed is CLEARED:
            return None
        return os.environ.get(name)

    def expand(self, word, split=True):
        """The fields `word` expands to, or UNKNOWN if any part is unknowable.

        A word is not an argument: an unquoted expansion is split on IFS, so
        `OUT='/tmp/a b'; bd -C $OUT close X` passes `-C` the single field
        `/tmp/a`, and `b` is an operand. Treating the word as one argument named
        `/tmp/a b` names a store the command never opened, and misses that a
        stray operand has shifted the rest along.

        Quoting is what suppresses the split, and is carried per part rather
        than per word, so `"$A"/$B` splits its second half and not its first.

        `split` is False in the one context where the shell does not split at
        all: the right-hand side of an assignment. `OUT=$X` keeps a value with a
        space in it whole, so splitting it here would lose the store that a
        later `bd -C "$OUT"` opens.
        """
        segments = []
        for part, quoted in word_parts(word, nulls=True):
            kind = part["Type"]
            if kind == "Lit":
                text = part.get("Value", "")
                # An unquoted pattern is answered by the filesystem when the
                # command runs, and the argument it becomes is not the text:
                # `bd -C /tmp/store-* close X` opens whichever directory
                # matches. Passed through as written, the target was a path
                # naming no store, which the hook dropped without a word --
                # the write was found, the store it went to was not. Unknown
                # instead, so it is reported as a target that could not be
                # named. Not applied to an assignment's value, where the
                # shell does not expand patterns either.
                if split and not quoted and is_pattern(text):
                    return UNKNOWN
                segments.append(
                    (unescape_dquoted(text) if quoted else unescape(text),
                     False))
            elif kind == "SglQuoted":
                text = part.get("Value", "")
                # `$'...'` is single-quoted in the tree and not in the shell:
                # its escapes are decoded, so the body is not the value.
                if part.get("Dollar"):
                    text = unescape_ansi_c(text)
                    if text is UNKNOWN:
                        return UNKNOWN
                segments.append((text, False))
            elif kind == "ParamExp":
                # Only a plain reference is answered. An expansion with an
                # operator -- `${X:-/d}`, `${X#p}` -- names a value that
                # depends on more than the variable, and guessing it names
                # some other store. So does one that reads something other
                # than the variable's value: `${!X}` the variable X names,
                # `${#X}` its length, `${X[1]}` an element, `${!X*}` the
                # names that start with X. Answered with X's own value,
                # `ref=STORE; STORE=/ext; bd -C "${!ref}" close X` named
                # `<cwd>/STORE` rather than /ext.
                if part.get("Exp") or part.get("Slice") or part.get("Repl") \
                        or part.get("Excl") or part.get("Length") \
                        or part.get("Width") or part.get("Index") \
                        or part.get("Names"):
                    return UNKNOWN
                got = self.get(part["Param"]["Value"])
                if got is UNKNOWN:
                    return UNKNOWN
                # The value of an unquoted expansion is matched on paths as
                # a literal would be, so `OUT=/tmp/store-*; bd -C $OUT` is the
                # pattern case by another route. Quoting suppresses it here as
                # it does above.
                if split and not quoted and is_pattern(got):
                    return UNKNOWN
                # zsh splits it only under SH_WORD_SPLIT, which the text may
                # set or not: `zsh -c 'OUT="/a b"; bd -C $OUT close X'` writes
                # `/a b` by default and `/a` with it. Split as bash splits,
                # the scan named `/a` with no warning.
                if split and not quoted and self.scope.zsh:
                    separators = self.separators()
                    if separators is UNKNOWN or \
                            any(char in separators for char in got):
                        return UNKNOWN
                segments.append((got, not quoted))
            elif kind in ("CmdSubst", "ProcSubst"):
                # The value comes from running something the scan does not run.
                # Its writes are still real, and were collected when the walk
                # reached the word carrying it.
                return UNKNOWN
            else:
                # ArithmExp, ExtGlob and the rest name no path this scan can
                # settle. Unknown beats guessed.
                return UNKNOWN

        # An empty word is still a field: `bd -C "" close X` passes an empty
        # target, which resolves to nothing, where dropping the field would read
        # the verb as the target.
        if not split or not any(splittable for _, splittable in segments):
            return [Field("".join(text for text, _ in segments),
                          opens_tilde(word))]

        separators = self.separators()
        if separators is UNKNOWN:
            return UNKNOWN
        # bash 3.2 drops a quoted null after a split where later bash keeps
        # it: with X=` `, `sudo -p $X'' bd -C /ext close X` passes `sudo` an
        # empty prompt in bash 5.2 and none in the bash macOS ships. Where the
        # two readings disagree, so does the argument list.
        fields = split_fields(segments, separators, self.scope.bash is False)
        if self.scope.bash is not False and \
                fields != split_fields(segments, separators, True):
            return UNKNOWN
        if not fields:
            # Every field was separator: the word contributes no argument at
            # all, as `set -- $EMPTY` passes none.
            return []
        tilde = opens_tilde(word)
        return [Field(one, tilde and i == 0) for i, one in enumerate(fields)]

    def expand_args(self, args):
        """The argument list `args` becomes once every word is expanded.

        This is the list the command actually receives, which is what every
        reader below wants: one word can supply several arguments or none, so an
        index into the words is not an index into the arguments, and an option's
        value is whichever *argument* follows it.

        A word whose value is unknowable holds one slot rather than none. It
        stands for an argument the command was certainly passed, so the readers
        can still step over it -- dropping it would shift a later option's value
        into the option's place.
        """
        out = []
        for word in args:
            fields = self.expand(word)
            if fields is UNKNOWN:
                out.append(Field(UNKNOWN,
                                 assign=assignment_name(word, self.raw),
                                 split=may_split(word, self.raw),
                                 dash=may_be_option(word)))
            else:
                out.extend(fields)
        return out

    def assigned_value(self, word):
        """The value `word` gives a variable, or UNKNOWN.

        An assignment's right-hand side is not split, so this is one value
        however many separators it holds. Quoting has already been resolved by
        the parse, so `'$X'` is the literal three characters rather than a
        reference.

        A leading unquoted `~` is expanded here, where the shell expands it: the
        value stored is already a path. Carried through as the literal two
        characters instead, `OUT=~/store; bd -C "$OUT" close X` lost the flag
        that says it names $HOME -- the field the *variable* produces begins
        with `$`, not `~` -- and the target resolved below the launch directory,
        naming a store the command never opened while the one it wrote went
        unregistered.

        `word` is None for `X=`, which assigns the empty string; the parse
        carries no value node for it rather than an empty one.
        """
        if word is None:
            return ""
        fields = self.expand(word, split=False)
        if fields is UNKNOWN or len(fields) != 1:
            return UNKNOWN
        field = fields[0]
        if not field.tilde:
            return field.value
        return self.expand_tilde(field.value)

    def prior_value(self, name):
        """The value `name` holds before an append to it, or UNKNOWN.

        An unset name appends onto the empty string, which `get` cannot say:
        it answers UNKNOWN for unset and unknowable alike, since a word
        expanding an unset name is unknowable either way. An append is not --
        `X+=b` on an unset X is `b` -- so the two are told apart here.
        """
        if name in self.scope.assigns:
            value = self.scope.assigns[name]
            if isinstance(value, ShellOpts):
                return UNKNOWN
            return "" if value is UNSET else value
        if name in ("PWD", "OLDPWD"):
            return self.get(name)
        if self.scope.sealed is OPAQUE:
            return UNKNOWN
        if self.scope.sealed is CLEARED:
            return ""
        return os.environ.get(name, "")

    def assign_value(self, arg):
        """The value the assignment node `arg` leaves its name holding.

        `X+=store` appends: the name holds what it held with `store` after it,
        so `OUT=/tmp/; OUT+=store; bd -C "$OUT" close X` opens /tmp/store.
        Recording the appended text alone left OUT as `store`, a relative path
        that resolved under the launch directory -- a store the command never
        opened, while /tmp/store went unregistered.
        """
        value = self.assigned_value(arg.get("Value"))
        if not arg.get("Append") or value is UNKNOWN:
            return value
        prior = self.prior_value(arg["Name"]["Value"])
        return UNKNOWN if prior is UNKNOWN else prior + value

    def expand_tilde(self, value):
        """`value` with its leading unquoted tilde expanded, or UNKNOWN.

        Only the prefix up to the first `/` is a tilde expansion; the rest is
        an ordinary path. The forms differ in what names the home, and getting
        that wrong is not a near miss -- an unexpanded `~alice/project` is a
        *relative* path, so it resolved under the launch directory and named a
        store the command never opened, while the one it wrote went
        unregistered.

        `~` is HOME as the command sees it rather than as this process does, so
        it is read through `self.get`. `~user` is not: it comes from the passwd
        database, which HOME cannot override, and which this process reads the
        same one of. `~+` is the cwd, tracked here. What is left -- `~-` and the
        `~N` stack forms -- names a directory only the running shell's own
        history holds, and is reported unresolvable rather than guessed.

        A `~user` naming no user is left as it is, which is what the shell does
        with it: no expansion applies, so the word is the literal path it looks
        like.
        """
        prefix, slash, rest = value.partition("/")
        rest = slash + rest
        if prefix == "~":
            home = self.get("HOME")
            if home is UNKNOWN or not home:
                return UNKNOWN
            return home + rest
        if prefix == "~+":
            if not self.scope.known or self.scope.spelled is not True:
                return UNKNOWN
            # `or "/"` so a cwd of `/` does not strip to the empty string, which
            # reads downstream as no value at all rather than as the root.
            return (self.scope.cwd.rstrip("/") or "/") + rest
        if prefix == "~-" or DIR_STACK_TILDE.match(prefix):
            return UNKNOWN
        try:
            home = pwd.getpwnam(prefix[1:]).pw_dir
        except (KeyError, TypeError):
            return value
        return home + rest

    def resolve_value(self, value, tilde):
        """`value` as an absolute path, or None when it cannot be one.

        None is the deliberate answer to "unresolvable". A guessed base names
        some other store, and a target that names the wrong store is worse than
        no target at all: the roots sync either way, so the only thing a wrong
        guess adds is a commit somewhere nobody asked for.
        """
        if value is UNKNOWN or not value:
            return None
        if tilde:
            value = self.expand_tilde(value)
            if value is UNKNOWN or not value:
                return None
        if value.startswith("/"):
            return value
        if not self.scope.known:
            return None
        # A relative path read from a directory whose PWD spelling is unknown
        # is read by name from that spelling, as `bd` and a logical `cd` read
        # it. Of two spellings, through a symlink or not, only a `..` may climb
        # out differently; a spelling that cannot be read at all may hold a
        # `..` after a symlink itself, so any relative path may name another
        # directory. See `Scope.spelled`.
        if self.scope.spelled is UNKNOWN or \
                (not self.scope.spelled and ".." in value.split("/")):
            return None
        return self.scope.cwd.rstrip("/") + "/" + value

    def resolve_field(self, field):
        return self.resolve_value(field.value, field.tilde)

    # --- classification ---------------------------------------------------

    def command_word(self, args):
        """Where the command that runs is named, as `(index, split)`.

        `index` is the index in `args` of the argument naming the command, and
        is None when the invocation names no command this scan can identify,
        which is the honest answer for a wrapper whose own arguments cannot be
        delimited. A wrapper is transparent -- `command bd -C /tmp/x close
        CHR-1` is a write to /tmp/x, and reading `command` as the command name
        loses the target while still detecting the write, which is the worst of
        both. Skipping the rest of the words wholesale instead finds a `bd`
        that is an argument: `env echo bd -C /tmp/store close CHR-1` runs echo,
        and reporting a write to /tmp/store commits and pushes a store the
        command never opened.

        `split` is set instead when the command is named inside an `env -S`
        string, which is not an argument list at all; see `split_string`.

        A wrapper is matched and looked up by its basename throughout, since
        `/usr/bin/env` runs the same program as `env`. Looking the full path up
        in the option tables found no entry, so the word after it was read as
        the command: `/usr/bin/env -i bd close CHR-1` named `-i` as the command
        and the write was missed entirely.
        """
        i = 0
        while i < len(args):
            word = args[i].value
            if word is UNKNOWN:
                return i, None
            name = word.rsplit("/", 1)[-1]
            if name not in PREFIX_WORDS:
                return i, None
            if name not in WRAPPER_OPT_ARGS:
                i += 1
                continue
            if name == "command" and self.command_lookup(args, i):
                return None, None
            if name in WRAPPER_ENV_WORDS:
                split = self.split_string(args, i)
                if split is not None:
                    return i, split
            if name == "xargs":
                nxt = self.xargs_opts(args, i)
                if nxt is None:
                    self.abandoned(args, i)
                    return None, None
                i = nxt
                continue
            nxt = self.skip_wrapper_opts(args, i, name)
            if nxt is None:
                self.abandoned(args, i)
                return None, None
            i = nxt
        return None, None

    def command_lookup(self, args, start):
        """Whether the `command` at `args[start]` looks a name up and runs nothing.

        `-v` or `-V` anywhere among its leading flags makes it a lookup. A flag
        this scan cannot read may be either, and is left to the ambiguous path.
        """
        for arg in args[start + 1:]:
            word = arg.value
            if word is UNKNOWN or not SHORT_BUNDLE.match(word):
                return False
            if COMMAND_LOOKUP_LETTERS & set(word[1:]):
                return True
        return False

    def abandoned(self, args, start):
        """Records what the wrapper given up on at `args[start]` may still run.

        Its options could not be delimited, so no command word can be placed
        -- but the words after it are still there, and one of them is the
        command. Where one opens with `bd`, a shell or `eval`, the invocation
        counts as a write whose store is unknown: the roots sync and the hook
        says a store may have been missed, which is what every other write it
        cannot read gets. Given up in silence instead, `nice -10 bd -C
        /external close X` was reported by nothing.

        The first word of each is what is looked at, since an `env -S` string
        among them is a command line of its own. A word this scan cannot read
        is left alone, as a computed command name is everywhere else.
        """
        for arg in args[start + 1:]:
            value = arg.value
            if value is UNKNOWN or not value.split():
                continue
            head = value.split()[0].rsplit("/", 1)[-1]
            if head in ABANDONED_RUNNERS:
                self.mutates = True
                self.unresolved += 1
                return

    def xargs_opts(self, args, start):
        """The index of the command word past the `xargs` at `args[start]`.

        None when its options cannot be delimited, as for the other wrappers.
        `xargs` runs the command it is given with arguments read from its
        input, so `... | xargs -I{} bd assign {} user` runs `bd`; reading
        `xargs` as the command word left that write as an argument nothing
        looked at, and the writes it made stayed local until SessionEnd.

        With a replacement string in force -- `-I str`, `-J str`, `-i[str]`,
        `--replace[=str]` -- every later argument holding it is rewritten from
        the input before the command sees it, so `args` is edited in place to
        make those arguments unreadable: `xargs -I{} bd -C {} close X` names
        no store this scan can read, where the literal `{}` resolved to a
        directory of that name under the launch directory. A replacement
        string that cannot itself be read leaves the arguments as they are:
        the words it would match are the ones carrying the same expansion,
        which are unreadable already, and blanking every literal word would
        lose a `-C` the input never touches.
        """
        takes = WRAPPER_OPT_ARGS["xargs"]
        alone = WRAPPER_OPT_NOARG["xargs"]
        repl = None
        i = start + 1
        while i < len(args):
            word = args[i].value
            if word is UNKNOWN:
                # An option or the command, as for the other wrappers; see
                # `skip_wrapper_opts`.
                return None
            if word == "--":
                i += 1
                break
            if not word.startswith("-") or word == "-":
                break
            if word.startswith("--"):
                opt, sep, inline = word.partition("=")
                if opt == "--replace":
                    repl = inline if sep else XARGS_DEFAULT_REPLACE
                    i += 1
                    continue
                # `--max-lines[=N]` and `--eof[=E]` take a value only when it
                # is attached, so the bare form is value-less, as is any long
                # flag the table does not list.
                i += 1 if sep or opt not in takes else 2
                continue
            # A bundle, read letter by letter rather than by `short_opts`, since
            # the three optional-value flags fit neither of its tables: their
            # value is whatever is attached and nothing when nothing is.
            letters = word[1:]
            consumed = 1
            j = 0
            while j < len(letters):
                opt = "-" + letters[j]
                rest = letters[j + 1:]
                if opt in takes:
                    if rest:
                        value = rest
                    else:
                        value = self.opt_value(args, i)
                        consumed = 2
                    if opt in XARGS_REPLACE_OPTS:
                        repl = value
                    break
                if opt in XARGS_OPT_OPTIONAL:
                    if opt == "-i":
                        repl = rest or XARGS_DEFAULT_REPLACE
                    break
                if opt not in alone:
                    return None
                j += 1
            i += consumed
        if repl is not None and repl is not UNKNOWN and repl:
            for j in range(i, len(args)):
                value = args[j].value
                if value is not UNKNOWN and repl in value:
                    args[j] = Field(UNKNOWN)
        elif repl is None:
            # Without one, `xargs` appends what it reads to the command's
            # arguments, so an unreadable argument stands at the end: `... |
            # xargs -n1 bd close X -C` takes `-C`'s directory from the input,
            # where the scan read a `-C` with no value. It is read as an
            # operand unless an option takes it, a pipe into `xargs` carrying
            # data, as the ids in `bd ready | xargs bd close` are.
            args.append(Field(UNKNOWN))
        return i

    def split_string(self, args, start):
        """The `env -S` string of the `env` at `args[start]`.

        Returned as `(string, prefix_end)`, `prefix_end` being the index just
        past the option and its value, so the wrapper's own assignments can be
        read from the words before it. None when the invocation has no `-S`.

        `-S` does not merely consume the word after it: `env` splits that word
        into the command and its arguments, so `env -S 'bd -C /tmp/store close
        CHR-1'` writes that store. Stepping over the string as an ordinary option
        value left the invocation naming no command, and the write -- and its
        external target -- was reported by nothing.

        The string comes back as UNKNOWN when `-S` is there and its value cannot
        be read, which the caller counts as a write with no target rather than as
        no write.
        """
        i = start + 1
        while i < len(args):
            word = args[i].value
            if word is UNKNOWN and args[i].assign is not None:
                i += 1
                continue
            if word is UNKNOWN or word == "--":
                return None
            if not word.startswith("-"):
                # An assignment stands among `env`'s arguments; anything else is
                # the command word, and `-S` cannot follow it.
                if ASSIGN_WORD.match(word):
                    i += 1
                    continue
                return None
            opt, sep, inline = word.partition("=")
            if opt == "--split-string":
                if sep:
                    return inline, i + 1
                return self.opt_value(args, i), i + 2
            if word.startswith("--"):
                i += 2 if opt in WRAPPER_OPT_ARGS["env"] and not sep else 1
                continue
            # `-S` may end a bundle of flags that take nothing -- `env -iS
            # '...'` -- and may carry its string directly: `env -S'...'`. A
            # letter before it that takes a value takes the rest of the word,
            # so the `S` in `env -uSHELL` is part of a name: read as the flag,
            # the real `-S` after it went unseen, and the write with it. A
            # letter neither table knows is left to `skip_wrapper_opts`, which
            # gives up on it.
            if word in ENV_CLEAR_OPTS:
                i += 1
                continue
            bundle = short_opts(word, WRAPPER_OPT_ARGS["env"],
                                WRAPPER_OPT_NOARG["env"])
            if bundle is None:
                return None
            _, opt, inline = bundle
            if opt == "-S":
                if inline is not None:
                    return inline, i + 1
                return self.opt_value(args, i), i + 2
            i += 1 if opt is None or inline is not None else 2
        return None

    @staticmethod
    def opt_value(args, i):
        """The word after `args[i]`, or UNKNOWN when there is none to read."""
        if i + 1 < len(args):
            return args[i + 1].value
        return UNKNOWN

    def skip_wrapper_opts(self, args, start, wrapper):
        """The index of the first argument past the options of `wrapper`.

        None when they cannot be delimited. Finding the command word means
        knowing which of a wrapper's options take a value: `sudo -u nick bd
        ...` runs bd, and telling that from `env echo bd ...` means knowing
        that `-u` takes `nick` while `echo` takes nothing.

        A wrapper with operands of its own -- `timeout 30 bd ...` -- names the
        command that many words past its options. An unreadable word among
        them may be an option, the command, or for one that may split both --
        `env "${MODE[0]}" bd ...` with MODE `-i`, `env $FLAGS bd ...` -- so the
        invocation is given up on, which still counts the `bd` after it; see
        `abandoned`. Taken for the command, it hid that write. One that is
        certainly an assignment, as `env OUT="$(pwd)" bd ...` makes, is stepped
        over; see `assignment_name`.
        """
        takes = WRAPPER_OPT_ARGS[wrapper]
        alone = WRAPPER_OPT_NOARG[wrapper]
        operands = WRAPPER_OPERANDS.get(wrapper, 0)
        i = start + 1
        while i < len(args):
            word = args[i].value
            if word is UNKNOWN:
                if args[i].assign is not None:
                    i += 1
                    continue
                return None
            if word == "--":
                i += 1
                if wrapper == "env":
                    # `--` ends `env`'s options, not its assignments: `env --
                    # NAME=value cmd` still sets NAME and runs cmd. Taking the
                    # word after it as the command read the assignment as one,
                    # and `env -- BEADS_DIR=/external/.beads bd close X` was
                    # a read of something that was not `bd`.
                    while i < len(args):
                        word = args[i].value
                        if word is UNKNOWN:
                            if args[i].assign is not None:
                                i += 1
                                continue
                            return None
                        if not ASSIGN_WORD.match(word):
                            break
                        i += 1
                return min(i + operands, len(args))
            # `env -` is `env -i` in its historical spelling: an option, not
            # the command word, and not a bundle either.
            if wrapper == "env" and word in ENV_CLEAR_OPTS:
                i += 1
                continue
            if wrapper == "nice" and NICE_ADJUST.match(word):
                i += 1
                continue
            if not word.startswith("-"):
                # An assignment among a wrapper's arguments, as `env FOO=bar
                # cmd`, is neither an option nor the command word.
                if ASSIGN_WORD.match(word):
                    i += 1
                    continue
                return min(i + operands, len(args))
            if word.startswith("--"):
                # `--opt=value` carries its value, so nothing follows it. A
                # long flag neither table knows is taken to be value-less,
                # since the form that carries one is unambiguous.
                i += 1 if "=" in word or word not in takes else 2
                continue
            # A short flag's value may be attached -- `stdbuf -oL`, `nice -n10`
            # -- and may end a bundle of flags that take nothing. Read as whole
            # words those matched neither table, so the invocation was abandoned
            # as ambiguous and the write inside it missed entirely.
            bundle = short_opts(word, takes, alone)
            if bundle is None:
                # A letter neither table knows may or may not take the next
                # word, and guessing either way misplaces the command word.
                return None
            _, opt, inline = bundle
            i += 1 if opt is None or inline is not None else 2
        return i

    def wrapper_chdir(self, args, start):
        """The directory the wrappers in `args[:start]` run the command in.

        None when none of them changes it, an absolute path when one does, and
        UNKNOWN when one names a directory this scan cannot resolve. Which store
        `bd` selects turns on this: `env -C /other/repo bd close X` writes
        /other/repo's store, and stepping over the directory as an opaque option
        value reported the walk up from the launch directory instead -- a store
        the command never opened, while the one it wrote went unregistered.

        Each wrapper changes directory once, to the last directory among its
        own options: `env` and `sudo` keep only that one, so from /work `env
        -C /other -C repo bd close X` runs in /work/repo, and reading the two
        in turn named /other/repo. A relative one resolves against the
        directory in force before that wrapper, so separate wrappers chain.

        A named directory that does not exist is reported unknowable rather than
        taken as given. The wrapper fails there and runs no command at all, so
        there is no write to attribute -- but walking up from a path that is not
        a directory finds an ancestor's store the command never opened, which is
        the one answer worse than none.
        """
        cwd = None
        i = 0
        while i < start:
            word = args[i].value
            if word is UNKNOWN:
                i += 1
                continue
            name = word.rsplit("/", 1)[-1]
            opts = WRAPPER_CHDIR_OPTS.get(name)
            if opts is None:
                i += 1
                continue
            takes = WRAPPER_OPT_ARGS[name]
            alone = WRAPPER_OPT_NOARG[name]
            i += 1
            last = None
            while i < start:
                word = args[i].value
                if word is UNKNOWN:
                    i += 1
                    continue
                if word == "--":
                    i += 1
                    break
                if name == "env" and word in ENV_CLEAR_OPTS:
                    i += 1
                    continue
                if not word.startswith("-"):
                    if not ASSIGN_WORD.match(word):
                        break
                    i += 1
                    continue
                if word.startswith("--"):
                    opt, sep, inline = word.partition("=")
                    if opt in opts:
                        last = (Field(inline) if sep
                                else self.opt_field(args, i))
                    i += 1 if sep or opt not in takes else 2
                    continue
                bundle = short_opts(word, takes, alone)
                if bundle is None:
                    # A letter neither table knows may be the chdir option with
                    # its directory attached, so where the command runs -- and
                    # so which store it opens -- cannot be read.
                    return UNKNOWN
                _, opt, inline = bundle
                if opt in opts:
                    # A tilde attached to the option is not an expansion -- the
                    # shell expands one only at the start of a word -- so only
                    # the separated form can carry the flag.
                    last = (Field(inline) if inline is not None
                            else self.opt_field(args, i))
                i += 1 if opt is None or inline is not None else 2
            if last is not None:
                cwd = self.chdir_to(cwd, last)
        return cwd

    @staticmethod
    def opt_field(args, i):
        """The argument after `args[i]`, or an unreadable one when there is none.

        The `Field` rather than its value, since a directory named as its own
        argument may have begun with a tilde -- `env -C ~/repo bd close X` runs
        under $HOME, and reading the two characters literally makes it a relative
        path naming a directory the command never entered.
        """
        if i + 1 < len(args):
            return args[i + 1]
        return Field(UNKNOWN)

    def detaches(self, args, start):
        """Whether a wrapper in `args[:start]` may return before the command
        it runs has finished, as `&` does.

        `setsid -f bash -c 'sleep 5; bd -C /ext close X'` returns at once, so
        scanned as a command waited for, the hook synced and retired /ext
        before the write landed; see `in_background`. `-w` makes `setsid`
        wait, and without `-f` it forks only as a process group leader, which
        a command is under job control: `set -m; setsid sleep 2` returns in no
        time, where without `set -m` it takes two seconds. A `setsid` after
        another is one too, the first having made it lead a session of its
        own, so `setsid -w setsid sleep 2` returns at once as well: the outer
        `-w` waits only on a fork the outer one never made. Leadership lasts
        through an `exec` and through `env -S`, and a shell execs its last
        command, so a `setsid` anywhere in what such a process runs is read
        as leading too: `setsid bash -c 'setsid sleep 2'` and `setsid -w env
        -S 'setsid sleep 2'` return at once. One the shell forks would not
        lead, which costs only a record SessionEnd did not need; see
        `leads`. Only each wrapper's own options are read, so `setsid bd ...
        -f` waits.
        """
        if start is None:
            return False
        leader = self.leading(args, start)
        i = 0
        while i < start:
            word = args[i].value
            name = None if word is UNKNOWN else word.rsplit("/", 1)[-1]
            if name not in WRAPPER_DETACH_OPTS:
                i += 1
                continue
            seen, i = self.wrapper_flags(args, i, start, name)
            forks = bool(seen & WRAPPER_DETACH_OPTS[name]) or (
                name == "setsid" and (leader or self.scope.monitor is not False))
            if forks and not seen & WRAPPER_WAIT_OPTS.get(name, set()):
                return True
            leader = leader or name == "setsid"
        return False

    def leads(self, args, start):
        """Whether the command at `args[start]` runs as a process group
        leader: a `setsid` among its wrappers made it one, it runs inside a
        process that already was, or this shell has job control, which puts
        each command it forks in a group of its own; see `detaches`. So
        `set -m; env -S 'setsid X' >/dev/null` returns at once, as `env`
        execs a `setsid` that leads."""
        return self.leading(args, start) or \
            self.scope.monitor is not False or (
                start is not None and any(
                    args[j].value is not UNKNOWN and
                    args[j].value.rsplit("/", 1)[-1] == "setsid"
                    for j in range(start)))

    def leading(self, args, start):
        """Whether the command at `args[start]` runs in the process that
        leads where this scan stands: always, never, or under EXEC_ONLY only
        when the shell runs it with `exec`, perhaps behind `command` or
        `builtin`. `setsid -w bash -c 'exec setsid sleep 2; true'` returns at
        once, the `exec` keeping the leadership the fork of a statement
        before the last would lose, where `setsid -w bash -c 'setsid sleep 2;
        true'` waits. A word this scan cannot read may be the `exec`."""
        if self.leader is not EXEC_ONLY:
            return self.leader
        for j in range(start or 0):
            word = args[j].value
            if word is UNKNOWN or word == "exec":
                return True
            if word not in ("builtin", "command") and \
                    not word.startswith("-"):
                return False
        return False

    @staticmethod
    def wrapper_flags(args, i, start, name):
        """The options the wrapper `name` at `args[i]` was given, as spelled,
        and the index of the word after them."""
        takes = WRAPPER_OPT_ARGS[name]
        alone = WRAPPER_OPT_NOARG[name]
        seen = set()
        i += 1
        while i < start:
            word = args[i].value
            if word is UNKNOWN:
                i += 1
                continue
            if word == "--":
                return seen, i + 1
            if not word.startswith("-") or word == "-":
                if name not in WRAPPER_ENV_UNREADABLE or \
                        not ASSIGN_WORD.match(word):
                    break
                i += 1
                continue
            if word.startswith("--"):
                opt, sep, _ = word.partition("=")
                seen.add(opt)
                i += 1 if sep or opt not in takes else 2
                continue
            bundle = short_opts(word, takes, alone)
            if bundle is None:
                break
            letters, opt, inline = bundle
            seen.update("-" + letter for letter in letters)
            if opt is not None:
                seen.add(opt)
            i += 1 if opt is None or inline is not None else 2
        return seen, i

    def chdir_to(self, cwd, field):
        """`field` as the directory in force after changing to it from `cwd`.

        UNKNOWN once it is unknown, since a relative directory after an
        unreadable one is unreadable too. The change is a `chdir`, so a `..`
        is read after the symlinks before it; see `chdir_path`.
        """
        value = field.value
        if cwd is UNKNOWN:
            return UNKNOWN
        if value is not UNKNOWN and field.tilde:
            value = self.expand_tilde(value)
        if value is UNKNOWN or not value:
            return UNKNOWN
        if not value.startswith("/"):
            if cwd is None:
                if not self.scope.known:
                    return UNKNOWN
                cwd = self.scope.cwd
            value = cwd.rstrip("/") + "/" + value
        if not os.path.isdir(value):
            return UNKNOWN
        return chdir_path(value)

    @staticmethod
    def exec_clears(args, start, end):
        """Whether the `exec` at `args[start]` clears the child's environment.

        `-c` may stand alone or end a bundle with the other value-less flag --
        `exec -lc bd ...` -- and `-a` takes the name after it, which is not a
        flag of its own. Only the words up to `end`, the command word, are its
        options.
        """
        i = start + 1
        while i < end:
            word = args[i].value
            if word is UNKNOWN or not word.startswith("-"):
                return False
            if word == "--":
                return False
            bundle = short_opts(word, WRAPPER_OPT_ARGS["exec"],
                                WRAPPER_OPT_NOARG["exec"])
            if bundle is None:
                return False
            letters, opt, inline = bundle
            if any("-" + ch in EXEC_CLEAR_OPTS for ch in letters):
                return True
            i += 1 if opt is None or inline is not None else 2
        return False

    def wrapper_words(self, args, start):
        """The indices of the wrappers in `args[:start]` that run one another
        and then the command at `args[start]`, as `command_word` walks them,
        or None when that walk does not end there.

        A word among a wrapper's options or operands is no wrapper: in `env
        -u sudo bash -c ...`, `sudo` is the name `-u` unsets.
        """
        found = []
        i = 0
        while i is not None and i < start:
            word = args[i].value
            name = None if word is UNKNOWN else word.rsplit("/", 1)[-1]
            if name not in PREFIX_WORDS:
                return None
            found.append(i)
            if name not in WRAPPER_OPT_ARGS:
                i += 1
            elif name == "xargs":
                i = self.xargs_opts(args, i)
            else:
                i = self.skip_wrapper_opts(args, i, name)
        return found if i == start else None

    def prefix_env(self, args, start):
        """The environment the wrappers in `args[:start]` give the command.

        Returns `(assigns, sealed)`. `env OUT=/tmp/store bash -c 'bd -C "$OUT"
        ...'` writes /tmp/store, and a prefix read only for where the command
        word is left `$OUT` to be answered by the hook's own environment --
        naming some other store, or none, and leaving the one that was written
        unregistered.

        `sealed` is False, CLEARED or OPAQUE, and says what a name this does not
        carry is in the child. CLEARED is `env -i` and `exec -c`: such a name is
        unset rather than inherited. OPAQUE is a prefix whose effect on the
        environment cannot be read: `sudo` and `doas` decide what passes by a
        policy on disk, and a word this scan cannot resolve may be an
        assignment or an unset, so such a name may hold anything. Either way
        the write itself is still found, which is what matters -- the roots
        still sync, and only the store's identity is in question. The two are
        told apart because an unset `BEADS_DIR` has a meaning of its own: `bd`
        walks up from its directory, which this scan can follow, where an
        unreadable one leaves the store in doubt.

        Read in the order the shell applies them, since each wrapper acts on
        the environment the one before it built: `env -i` and `sudo` drop the
        assignments read before them, and a name unset by `-u` is carried as
        UNSET rather than dropped, so `env -u X env X=/b bd` runs with /b.
        `env` takes its options before its assignments and its assignments
        before the command, without permuting, so the order in the text is the
        order applied.
        """
        assigns = {}
        sealed = False
        i = 0
        while i < start:
            word = args[i].value
            if word is UNKNOWN:
                assigns = {}
                sealed = OPAQUE
                i += 1
                continue
            name = word.rsplit("/", 1)[-1]
            if name in WRAPPER_ENV_UNREADABLE:
                assigns = {}
                sealed = OPAQUE
                i += 1
                continue
            # `exec -c` clears the environment as `env -i` does, so a name the
            # command line does not carry is unset in the child. It takes no
            # assignments of its own, so the flag is all there is to read.
            if name == "exec":
                if self.exec_clears(args, i, start):
                    assigns = {}
                    sealed = CLEARED
                i += 1
                continue
            if name not in WRAPPER_ENV_WORDS:
                i += 1
                continue
            i += 1
            while i < start:
                word = args[i].value
                if word is UNKNOWN and args[i].assign is not None:
                    # An assignment whose value this scan cannot read leaves
                    # that one name in doubt; see `assignment_name`.
                    assigns[args[i].assign] = UNKNOWN
                    i += 1
                    continue
                if word is UNKNOWN:
                    # An option, an unset or an assignment this scan cannot
                    # read, so every name read so far is in doubt.
                    assigns = {}
                    sealed = OPAQUE
                    i += 1
                    continue
                if word == "--":
                    # The options end here and the assignments do not: `env
                    # -- BEADS_DIR=/x/.beads bd close X` runs `bd` with that
                    # BEADS_DIR. Stopping at the `--` left it unread, and the
                    # store `bd` opened was neither pushed nor registered.
                    i += 1
                    while i < start:
                        word = args[i].value
                        if word is UNKNOWN and args[i].assign is not None:
                            assigns[args[i].assign] = UNKNOWN
                            i += 1
                            continue
                        if word is UNKNOWN:
                            assigns = {}
                            sealed = OPAQUE
                            i += 1
                            continue
                        if not ASSIGN_WORD.match(word):
                            break
                        key, _, value = word.partition("=")
                        assigns[key] = value
                        i += 1
                    break
                if not word.startswith("-"):
                    if not ASSIGN_WORD.match(word):
                        break
                    key, _, value = word.partition("=")
                    assigns[key] = value
                    i += 1
                    continue
                if word in ENV_CLEAR_OPTS:
                    assigns = {}
                    sealed = CLEARED
                    i += 1
                    continue
                opt, sep, inline = word.partition("=")
                if opt in ENV_UNSET_OPTS:
                    if sep:
                        assigns[inline] = UNSET
                        i += 1
                    elif i + 1 < start:
                        nxt = args[i + 1].value
                        if nxt is UNKNOWN:
                            # Which name was unset is itself unreadable, so
                            # every name is in doubt.
                            assigns = {}
                            sealed = OPAQUE
                        else:
                            assigns[nxt] = UNSET
                        i += 2
                    else:
                        i += 1
                    continue
                if not word.startswith("--"):
                    # `-u` may carry its name attached, and may end a bundle:
                    # `env -uOUT bash -c 'bd -C "$OUT/store" ...'` unsets OUT,
                    # so the inherited value must not answer for it. Read as a
                    # whole word it matched no unset, and the store the hook's
                    # own OUT named was committed while the write went where the
                    # scan never looked.
                    bundle = short_opts(word, WRAPPER_OPT_ARGS["env"],
                                        WRAPPER_OPT_NOARG["env"])
                    if bundle is None:
                        # A letter this scan does not know may be an unset whose
                        # name cannot be identified, so every name is in doubt.
                        assigns = {}
                        sealed = OPAQUE
                        i += 1
                        continue
                    letters, bopt, binline = bundle
                    if any("-" + ch in ENV_CLEAR_OPTS for ch in letters):
                        assigns = {}
                        sealed = CLEARED
                    if bopt in ENV_UNSET_OPTS:
                        if binline is not None:
                            assigns[binline] = UNSET
                        elif i + 1 < start:
                            nxt = args[i + 1].value
                            if nxt is UNKNOWN:
                                assigns = {}
                                sealed = OPAQUE
                            else:
                                assigns[nxt] = UNSET
                    i += 1 if bopt is None or binline is not None else 2
                    continue
                if opt in WRAPPER_OPT_ARGS["env"] and not sep:
                    i += 2
                    continue
                i += 1
        return assigns, sealed

    def bd_operands(self, args, start):
        """What the `bd` at `args[start]` says: operands, `-C`, `--db`, help.

        The target and the store come back as `Field`s, since both `-C dir`
        and `-C=dir` name one and only the first carries its own argument --
        and only an argument of its own can have begun with a tilde.

        `--db` is read apart from `-C` because it names the store outright
        where `-C` names where the walk up starts, and `bd` opens the store
        `--db` names whatever `-C` says: `bd -C /repo --db /other/.beads close
        X` writes /other's store. Stepped over as a bare value, that write was
        reported against /repo, which then synced while /other sat local.

        A global option's value is stepped over before an operand is read.
        Skipping only the option itself lets its value stand in for the verb,
        and a value that happens to name a read-only one suppresses the write
        behind it: `bd --actor list close CHR-1` closes an issue. For the same
        reason another option's value is not a `-C` target -- one that happens
        to read as a path names a store the command never opened.

        `--` ends the options, and everything past it is an operand however it
        is spelled: `bd create -- --help` gives the issue the title `--help` and
        writes the store, where reading that as the help flag suppresses the
        sync.

        A repeated directory flag takes its last value -- `-C`, `--dir` and
        `--directory` all set one scalar option, and `bd -C /a -C /b close X`
        writes /b. Keeping the first pushed and registered /a while the store
        that was written went unrecorded.
        """
        operands = []
        target = None
        store = None
        helped = False
        flags = set()
        i = start + 1
        end_of_opts = False
        opaque = False
        # Whether the word before this one was an option whose arity this scan
        # does not know, which makes this word possibly its value rather than
        # an option of `bd`'s own. The help reading turns on it -- `bd update
        # CHR-1 --title --help` sets the title to `--help` and writes the
        # store, and reading that token as a help request suppressed the sync
        # -- as does whether an unreadable word may be an option. The target
        # and operand readings are left as they were, since a word skipped as
        # a supposed value is a `-C` that goes unseen, and a write whose target
        # is lost is the one outcome worse than a no-op.
        may_be_value = False
        # Whether an unreadable word before this one may have been `--`, after
        # which no word is an option: with FLAG=--, `bd kv set "${FLAG[0]}"
        # key --help` sets key to `--help`. A help flag read before one stands.
        may_have_ended = False
        while i < len(args):
            word = args[i].value
            after_unknown_opt = may_be_value
            may_be_value = False
            if word is UNKNOWN:
                # Kept as an operand rather than dropped. Dropping it moves the
                # next word into the verb position, so `bd "$(printf create)"
                # list` reads the read-only `list` as its verb and suppresses
                # the write the substitution named. An unknown verb is no verb
                # this scan knows to be read-only, which is the safe reading.
                #
                # One that may split, or may open with a `-`, may be options
                # as well -- `bd $OPTS close X`, OPTS holding `-C /ext`, and
                # `bd "${FLAG[0]}" /ext close X`, FLAG holding `-C`, both
                # write /ext -- so the store is unknown once one stands before
                # the options end. Read as an operand, it named the launch
                # directory's store. A quoted one after an option of unknown
                # arity is taken for its value, as `bd create X -d "$(cat f)"`
                # makes it: an option that takes one takes the next argument
                # whatever it holds. After one known to take nothing, `--claim`
                # among them, it is read as it stands; see `BD_LONG_NOARG`.
                if not end_of_opts and (args[i].split or (
                        args[i].dash and not after_unknown_opt)):
                    opaque = True
                    # It may be an option that takes the word after it, too:
                    # with FLAG=--title, `bd update CHR-1 "${FLAG[0]}" --help`
                    # sets the title to `--help` and writes the store.
                    may_be_value = True
                    may_have_ended = True
                operands.append(word)
                i += 1
                continue
            if not end_of_opts and word == "--":
                end_of_opts = True
                i += 1
                continue
            # A help flag is a whole argument here, so the `--help` inside
            # `--title "document --help output"` is part of its value.
            if not end_of_opts and not after_unknown_opt \
                    and not may_have_ended and word in ("-h", "--help"):
                helped = True
                i += 1
                continue
            if not end_of_opts and word.startswith("--"):
                name, sep, inline = word.partition("=")
                flags.add(name)
                if sep:
                    # `--opt=value` carries its value, so nothing follows it.
                    if name in BD_DIR_OPTS:
                        target = Field(inline)
                    elif name == BD_DB_OPT:
                        store = Field(inline)
                elif name in BD_OPT_ARGS:
                    if name in BD_DIR_OPTS and i + 1 < len(args):
                        target = args[i + 1]
                    elif name == BD_DB_OPT and i + 1 < len(args):
                        store = args[i + 1]
                    # The words a split value hands on stand where the
                    # unreadable word that may split does above: any may be
                    # the verb, a write flag, `-C`, or an option taking the
                    # word after. With OPTS=`me --title`, `bd update CHR-1
                    # --actor $OPTS --help` titles the issue `--help`.
                    if self.splits_value(args, i + 1):
                        opaque = True
                        operands.append(UNKNOWN)
                        may_be_value = True
                        may_have_ended = True
                    i += 1
                elif name not in BD_LONG_NOARG:
                    # A long flag no table knows may still take the word after
                    # it -- every per-verb option is one, `--title` among them
                    # -- so what follows is not certainly an option.
                    may_be_value = True
                i += 1
                continue
            if not end_of_opts and word.startswith("-") and word != "-":
                # `-C` may carry its directory attached, and may sit at the end
                # of a bundle of flags that take nothing: `bd -qC/tmp/store
                # close X` writes that store. Matched as a whole word, both
                # forms named no `-C` at all, so the write was found and its
                # target lost -- and an external store named by nothing else
                # goes unregistered, which no later event can recover.
                bundle = short_opts(word, BD_OPT_ARGS, BD_OPT_NOARG | {"-h"})
                if bundle is None:
                    # A letter this scan does not know may take the word after
                    # it, which would then be neither an operand nor a target.
                    # Skipping the flag alone is what it already did.
                    may_be_value = True
                    i += 1
                    continue
                letters, opt, inline = bundle
                if "h" in letters and not after_unknown_opt \
                        and not may_have_ended:
                    helped = True
                if opt is None:
                    i += 1
                    continue
                if opt in BD_DIR_OPTS:
                    if inline is not None:
                        # `bd -C=/tmp/store` opens /tmp/store: `bd`'s option
                        # parser drops one leading `=` from a value attached to
                        # a short flag. Kept, the path resolved below the launch
                        # directory and named no store that exists.
                        target = Field(inline[1:] if inline.startswith("=")
                                       else inline)
                    elif i + 1 < len(args):
                        target = args[i + 1]
                if inline is None and self.splits_value(args, i + 1):
                    opaque = True
                    operands.append(UNKNOWN)
                    may_be_value = True
                    may_have_ended = True
                i += 1 if inline is not None else 2
                continue
            operands.append(word)
            i += 1
        if opaque:
            store = Field(UNKNOWN)
        return operands, target, store, helped, flags

    @staticmethod
    def splits_value(args, i):
        """Whether the value an option takes at `args[i]` may be other than
        one argument. The option takes the first, and the rest are read on as
        arguments: with OPTS=`reviewer -C /ext`, `bd --actor $OPTS close X`
        writes /ext, where stepping over the word as one value named the
        launch directory's store, and with OPTS=`me create`, `bd --actor $OPTS
        list` creates an issue."""
        return i < len(args) and args[i].value is UNKNOWN and args[i].split

    @staticmethod
    def readonly(operands, helped, flags=frozenset()):
        """Whether a `bd` invocation with these operands only reads.

        The verb is compared whole, so `bd list-add` is not read as `bd list`
        followed by a boundary -- the one direction this must never fail in,
        since a verb wrongly judged read-only strands the write it describes.

        An operand this scan cannot read matches no entry of either table, so an
        invocation whose verb is unknowable is treated as a write. That is the
        same direction: the cost is a no-op commit, against a stranded one.

        `flags` are the long options seen, checked against WRITE_FLAGS before
        the verb tables: `bd ready --claim` writes, `bd ready` does not. A flag
        that was really another option's value -- `--title --claim` -- reads
        as a write too, which is the same direction again. So does an operand
        this scan cannot read behind such a verb: `bd ready "$(printf %s
        --claim)"` runs the claim, and the substitution is the only place the
        flag could be hiding.
        """
        if helped:
            return True
        if not operands:
            return False
        write_flags = WRITE_FLAGS.get(operands[0])
        if write_flags and (flags & write_flags
                            or any(op is UNKNOWN for op in operands[1:])):
            return False
        if operands[0] in READONLY_VERBS:
            return True
        return tuple(operands[:2]) in READONLY_PAIRS

    def shell_script(self, args, start):
        """The index of the `-c` operand of the shell at `args[start]`.

        None when the invocation runs no script this scan can read: no `-c`, a
        script named by a file the scan cannot open, or an option it cannot
        delimit. The operand is the first argument past the shell's own options,
        so the script of `sh -o pipefail -c '...'` is two further along than that
        of `sh -x -c '...'`. A flag in neither table may or may not consume the
        argument after it, so the invocation is abandoned rather than
        attributing the write to whichever argument happens to be there.

        An unreadable word once `-c` has been seen is returned rather than given
        up on. The shell runs that text whatever it says, so it is the operand as
        far as this scan can tell, and the caller counts it as a write with no
        target -- the answer `eval` and `env -S` already give their own.

        An option's value that may split is no single argument either: with
        OPTS=`pipefail -c 'bd ...'`, `bash -eo $OPTS -c true` runs that `bd`,
        the `-c` and the script among the words the value hands on. So it is
        counted as a script this scan cannot read, and the one found after it
        is read as well, being the one that runs when the value does not
        split; see `splits_value`. It is counted as it is taken, since what
        follows it is no longer what bash reads: `bash -o $OPTS --help` runs
        that script too, `--help` its `$0`.
        """
        seen_c = False
        uncertain = False

        def taken(first, end):
            nonlocal uncertain
            if not uncertain and any(self.splits_value(args, j)
                                     for j in range(first, end)):
                uncertain = True
                self.unreadable_script()

        i = start + 1
        while i < len(args):
            word = args[i].value
            if word is UNKNOWN:
                if seen_c:
                    return i
                self.shell_abandoned(args, start, i)
                return None
            if word == "--":
                i += 1
                break
            if not (word.startswith("-") or word.startswith("+")):
                break
            if word.partition("=")[0] in SHELL_ZSH_LONG and \
                    bash_kind(args[start].value) is True:
                return None
            if word in SHELL_OPT_ARGS:
                taken(i + 1, i + 2)
                i += 2
                continue
            if word.startswith("--"):
                # A long option is one name, not a bundle of letters. One
                # that carries its value -- `--rcfile=FILE` -- takes no word
                # after it; one not known here may take one, so the
                # invocation is abandoned. Unlike an unknown letter, which
                # some shell may take, it is no write: bash refuses an
                # option it does not know, and `--help` runs no script.
                opt = word.partition("=")[0]
                if opt in SHELL_LONG_NOARG or \
                        (opt in SHELL_OPT_ARGS and "=" in word):
                    i += 1
                    continue
                return None
            # In a bundle, `o` and `O` take a word after it each, in order,
            # as alone they do: `bash -euo pipefail -c '...'` runs its script
            # with pipefail on. Read as an unknown letter, the invocation was
            # dropped and the write inside missed.
            values = 0
            for ch in word[1:]:
                if ch in "oO":
                    values += 1
                    continue
                if ch not in SHELL_NOARG_LETTERS:
                    self.shell_abandoned(args, start, i)
                    return None
                if ch == "c":
                    seen_c = True
            taken(i + 1, i + 1 + values)
            i += 1 + values
        if not seen_c or i >= len(args):
            return None
        return i

    def shell_abandoned(self, args, start, i):
        """Records the shell at `args[start]`, whose options could not be
        delimited at `args[i]`, as a write with no store where it may still
        run a `-c` script: `bash -Q -c 'bd -C /ext close X'` runs it if `-Q`
        takes nothing, and left alone the write was reported by nothing. With
        no `-c` that may be there, the word after is a script file or an
        option's value, not a command.

        Which word is the script is what cannot be told, so every later word
        is read as one: any that names `bd`, `eval` or a shell anywhere in it
        counts, not only at its start, as `abandoned` reads a wrapper's. `bash
        -Q -c 'cd /ext && bd close X'` writes as surely as `bash -Q -c 'bd -C
        /ext close X'` does, and `bash -Q -c 'b"d" -C /ext close X'` too, as
        does a script spelling `bd` with `$'b\\x64'` or a line continuation,
        its quoting and escapes removed; see `script_text`. A word this scan
        cannot read after a `-c` that may be there may be the script itself,
        which runs whatever it says: `bash "${FLAG[0]}" -c "$CODE"`. One that
        may split may hold the `-c` and the script both: with FLAGS=`-c 'bd
        ...'`, `bash $FLAGS -c true` runs that `bd`. See `unreadable_script`.
        """
        if not any(self.may_be_c(arg) for arg in args[i:]):
            return
        after_c = False
        for arg in args[start + 1:]:
            if arg.value is UNKNOWN:
                if after_c or arg.split:
                    self.unreadable_script()
                    return
                after_c = True
                continue
            text = script_text(arg.value)
            if any(word.rsplit("/", 1)[-1] in ABANDONED_RUNNERS
                   for word in SCRIPT_WORD_BREAKS.split(text)):
                self.mutates = True
                self.unresolved += 1
                return
            after_c = after_c or self.may_be_c(arg)

    @staticmethod
    def may_be_c(arg):
        """Whether the shell option word `arg` may hold a `-c`."""
        return arg.value is UNKNOWN or (
            arg.value[:1] in ("-", "+") and
            not arg.value.startswith("--") and "c" in arg.value[1:])

    @staticmethod
    def shell_option(words, letter, name, value=False):
        """The state the shell options `words` leave an option in: True,
        False or UNKNOWN.

        The option is the one `-<letter>` and `-o <name>` set and `+<letter>`
        and `+o <name>` clear, as `-P` and `-o physical` do, and the last of
        them wins over `value`, the state it starts in. A new shell starts in
        logical mode unless its environment says otherwise -- see
        `shellopts_option` -- so `set -P; bash -c 'cd /ws/link/..'` lands in
        /ws, while `bash -P -c ...` lands where the link points. An option word
        this scan cannot read may be any of them.
        """
        i = 0
        while i < len(words):
            word = words[i].value
            if word is UNKNOWN:
                return UNKNOWN
            if word.startswith("--"):
                # `--<name>` sets the option as `-o <name>` does: zsh's
                # `--interactive` is its `-i`, and bash's `--login` its `-l`.
                if word == "--" + name:
                    value = True
                i += 2 if word in SHELL_OPT_ARGS else 1
                continue
            if word[:1] not in ("-", "+"):
                i += 1
                continue
            # `o` and `O` take a word each, bundled or not: `-eo physical` is
            # `-e -o physical`. Only `o` names an option of `set`.
            on = word.startswith("-")
            taken = 0
            for ch in word[1:]:
                if ch == letter:
                    value = on
                elif ch in "oO":
                    taken += 1
                    if ch == "o":
                        at = i + taken
                        option = words[at].value if at < len(words) else None
                        if option is UNKNOWN:
                            return UNKNOWN
                        if option == name:
                            value = on
            i += 1 + taken
        return value

    # --- the walk ---------------------------------------------------------

    def scoped(self, fn):
        """Runs `fn` in a frame of its own, as a subshell of this scope.

        A subshell is a forked copy of this shell. It starts with the
        functions defined here, and what it defines, unsets or forgets dies
        with it: after `go() { cd /ext; }; bash -l -c true`, or `(unset -f
        go)`, `go; bd close X` still writes /ext. A leadership only an `exec`
        would pass on does not reach it; see `leading`.
        """
        saved = self.scope
        functions = self.functions
        sealed = self.functions_sealed
        exports = self.function_exports
        unset_names = self.unset_names
        seals = self.seals
        leader = self.leader
        self.scope = saved.child()
        self.functions = dict(functions)
        if exports is not UNKNOWN:
            self.function_exports = set(exports)
        self.unset_names = set()
        if leader is EXEC_ONLY:
            self.leader = False
        try:
            fn()
        finally:
            self.scope = saved
            self.functions = functions
            self.functions_sealed = sealed
            self.function_exports = exports
            self.unset_names = unset_names
            self.seals = seals
            self.leader = leader

    def in_background(self, fn):
        """Runs `fn` as a subshell the shell does not wait for.

        The tool call can return, and the hook sync, before a write inside one
        lands: `(sleep 5; bd -C /ext close X) &` writes /ext after the sync has
        found nothing there. Its stores are reported as written in the
        background, so the hook keeps them recorded for SessionEnd.
        """
        self.background += 1
        try:
            self.scoped(fn)
        finally:
            self.background -= 1

    def tentative(self, fn):
        """Runs `fn` in a frame whose effects may or may not have happened.

        The body of a branch, a function call, or an `eval` runs in this shell,
        not a subshell -- but whether it ran to the end, and which of its paths
        it took, is what the scan declines to infer. Dropping its frame restored
        the values from before it: `OUT=/old; if t; then OUT=/real; fi; bd -C
        "$OUT" ...` was resolved against /old, a store the command may never
        have opened, while /real went unsynced. So every name the frame assigned
        is unknown afterwards instead -- and the cwd, when the frame acted on
        it. One that never did leaves the cwd standing: `if t; then X=1; fi; bd
        close X`, launched from an external store, gave the cwd up and the
        store went unregistered for a branch that could not have moved it.
        """
        saved = self.scope
        inner = saved.child()
        self.scope = inner
        try:
            fn()
        finally:
            self.scope = saved
        # A name the frame touched -- assigned, exported, unset, or dropped as
        # `cd` drops an explicit PWD -- is unknown afterwards, in value and in
        # export state alike.
        missing = object()
        for name in set(inner.assigns) | set(saved.assigns):
            if saved.assigns.get(name, missing) != \
                    inner.assigns.get(name, missing):
                saved.assigns[name] = UNKNOWN
        for name in set(inner.exported) | set(saved.exported):
            if saved.exported.get(name, missing) != \
                    inner.exported.get(name, missing):
                saved.exported[name] = UNKNOWN
        if saved.allexport != inner.allexport:
            saved.allexport = UNKNOWN
        if saved.lastpipe != inner.lastpipe:
            saved.lastpipe = UNKNOWN
        if saved.monitor != inner.monitor:
            saved.monitor = UNKNOWN
        if saved.physical != inner.physical:
            saved.physical = UNKNOWN
        # A frame that sealed its scope -- a `source`d file may export
        # anything -- leaves every name in doubt, not only those it touched:
        # `if t; then . ./select-store.sh; fi; bd close X` may run with a
        # BEADS_DIR the file set, where reading on unsealed took it for unset
        # and named the store the walk found.
        if saved.sealed != inner.sealed:
            saved.sealed = OPAQUE
        if inner.moved:
            saved.known = False
            saved.moved = True

    def sub_scan(self, stmts, cwd=None, known=None, seed=None, text=None,
                 sealed=False, conditional=False, frame="subshell",
                 process=False, physical=False, monitor=False, shell=None,
                 pwd=None, startup=False, functions=None):
        """Scans `stmts` as a subshell: its writes count, its state does not.

        `text` is the source those statements were parsed from, needed when they
        came from a parse of their own -- a `bash -c` operand -- since their
        offsets index that string and not the command this scan started with.

        `sealed` says the child's environment was replaced rather than inherited,
        as under `env -i`, so a name `seed` does not carry is unset there --
        CLEARED -- or, under a wrapper whose effect cannot be read, unknowable
        -- OPAQUE. The innermost wrapper's kind stands: `sudo bash -c 'env -i
        bash -c ...'` is cleared inside, whatever the policy outside let
        through.

        `process` says the text runs in a process of its own rather than a
        subshell of this one, as a `bash -c` operand does. A subshell is a copy
        of this shell, variables and all; a new process gets the environment,
        which is the exported names alone -- see `environment_view`. `seed` is
        what the command line handed the process on top of that, and is
        exported there, having arrived as environment. `physical` and
        `monitor` are the process's own `set -P` and `set -m` states; see
        `shell_wrapper`. `shell` names the
        program the process is -- a shell, or `env` for what `env -S` runs --
        which settles `Scope.bash` and `Scope.zsh`, and `pwd`, for a shell,
        the directory it starts in as its PWD names it and whether that
        spelling is known; see `shell_pwd`. `startup` says the shell may run
        a file before the text, which leaves its state as unknown as a
        `source` does; see `startup_runs`. `functions` is what a shell's
        function table starts as; see `imported_functions`.

        `frame` is "tentative" for text that runs in this shell rather than a
        subshell, as `eval`'s does; see `tentative`. `conditional` is then what
        it is for any statement: whether something before the text made it
        depend on an exit status.
        """
        # Exhausting the depth is this scan failing, not the command writing
        # nothing, so it is raised rather than returned. Returning quietly is
        # what made a `bd` nested past the old cap of 4 read as read-only.
        if self.depth >= MAX_DEPTH:
            raise Unavailable("nesting deeper than %d" % MAX_DEPTH)

        def run():
            if cwd is not None and cwd != self.scope.cwd:
                self.scope.cwd = cwd
                self.scope.moved = True
            if known is not None and known != self.scope.known:
                self.scope.known = known
                self.scope.moved = True
            if process:
                assigns, exported = self.environment_view(sealed)
                self.scope.assigns = assigns
                self.scope.exported = exported
                self.scope.allexport = False
                self.scope.lastpipe = False
                self.scope.monitor = monitor
                self.scope.physical = physical
            if sealed:
                self.scope.sealed = sealed
            if seed:
                self.scope.assigns.update(seed)
                for name, value in seed.items():
                    self.scope.exported[name] = value is not UNSET
            if shell is not None:
                self.scope.bash = bash_kind(shell)
                self.scope.zsh = shell == "zsh"
            if pwd is not None:
                # Every shell sets PWD as it starts, and exports it, whatever
                # it inherited: after `env -i bash -c 'cd /ws/link; ...'` a
                # child of that shell still reads `..` from /ws/link.
                self.scope.cwd, self.scope.spelled = pwd
                self.scope.assigns.pop("PWD", None)
                self.scope.exported["PWD"] = True
            if process and shell in IFS_RESET_SHELLS:
                # These shells set IFS as they start, too, ignoring the one
                # they inherit: `IFS=: bash -c 'OUT=/ext:; bd -C $OUT close
                # X'` passes `/ext:` whole. The value is set rather than the
                # name dropped, which would read it from the hook's own
                # environment: `bash -c 'bd${IFS}close${IFS}X'` runs `bd`.
                self.scope.assigns["IFS"] = \
                    ZSH_DEFAULT_IFS if shell == "zsh" else DEFAULT_IFS
            if functions is not None:
                (self.functions, self.functions_sealed,
                 self.function_exports) = functions
            if startup:
                self.seal_sourced()
            outer = self.text
            outer_raw = self.raw
            if text is not None:
                self.text = text
                self.raw = text.encode("utf-8")
            self.depth += 1
            try:
                # A process leads its group in the command it execs, and a
                # shell forks every command but its last, which it may exec,
                # and those it runs with `exec`: under `set -m`, `bash -c
                # 'setsid sleep 2; true'` waits, where `bash -c 'true; setsid
                # sleep 2'` and `bash -c 'exec setsid sleep 2; true'` return
                # at once. See `leading`.
                if process and self.leader is True and len(stmts) > 1:
                    self.leader = EXEC_ONLY
                    try:
                        self.stmts(stmts[:-1], conditional)
                    finally:
                        self.leader = True
                    self.stmts(stmts[-1:], conditional)
                else:
                    self.stmts(stmts, conditional)
            finally:
                self.depth -= 1
                self.text = outer
                self.raw = outer_raw

        if frame == "tentative":
            self.tentative(run)
        else:
            self.scoped(run)

    def word_subs(self, word):
        """Scans the substitutions in `word`, wherever in it they sit.

        One runs before the command whose word carries it, and runs whatever
        that command's own reachability is, so it is scanned where it is found
        rather than deferred. It runs in a subshell, so a `cd` or assignment
        inside it dies with it -- but its writes are real and must be kept.

        The word is walked as a tree rather than by the kinds of part it
        holds. A substitution can sit under any node of one -- inside an
        arithmetic expansion, a parameter expansion's operator word or
        replacement, a slice bound, an index -- and naming the places to look
        missed the ones not named: `$(( $(bd close X) + 1 ))` ran the write
        and reported nothing. Every statement list below a word belongs to one
        of the two substitution kinds, so descending everything is exact.
        """
        self.node_subs(word)

    def node_subs(self, node):
        if isinstance(node, dict):
            kind = node.get("Type")
            if kind == "CmdSubst":
                self.sub_scan(node.get("Stmts") or ())
                return
            # A process substitution is not waited for: `: < <(sleep 5; bd -C
            # /ext close X)` returns before the write lands. See
            # `in_background`.
            if kind == "ProcSubst":
                self.in_background(
                    lambda: self.sub_scan(node.get("Stmts") or ()))
                return
            # Arithmetic in a word assigns in this shell as `((...))` does:
            # `echo $((OUT=1))` and `${a[OUT=1]}` both set OUT.
            if kind == "ArithmExp":
                self.arith_assigns(node.get("X"))
            else:
                # An assignment's or a parameter expansion's index, and a
                # slice's bounds; the assignment node carries no `Type`.
                self.arith_assigns(node.get("Index"))
                if isinstance(node.get("Slice"), dict):
                    self.arith_assigns(node["Slice"].get("Offset"))
                    self.arith_assigns(node["Slice"].get("Length"))
            for value in node.values():
                self.node_subs(value)
        elif isinstance(node, list):
            for item in node:
                self.node_subs(item)

    def arith_assigns(self, expr):
        """Marks unknown every name the arithmetic `expr` assigns.

        Arithmetic is not evaluated here, so what a name holds after it is
        not known -- but that it no longer holds what it did is: `OUT=/decoy;
        ((OUT=1)); bd -C "$OUT" close X` runs `bd -C 1`, and keeping /decoy
        named a store the command never opened, with no warning. The targets
        of `=` and its compound forms and of `++`/`--` are marked, wherever
        they sit in the expression.

        A word the parser left whole -- `let "OUT=1"`, `(( "$E" ))` -- is
        read as text for the same shapes once expanded. A target spelled by an
        expansion this scan cannot read may be any name, so every name is in
        doubt after it, as after an `unset` it cannot read. An operand that
        cannot be read is left alone: the shell would evaluate its value as an
        expression too, so `E='OUT=1'; ((E))` assigns OUT, but nearly every
        such operand is a number, and marking every name on each would leave
        nothing resolvable after any `(( $(...) ))`.
        """
        if not isinstance(expr, dict):
            return
        kind = expr.get("Type")
        if kind == "BinaryArithm":
            if self.arith_op(expr) in ARITH_ASSIGN_OPS:
                self.arith_target(expr.get("X"))
            self.arith_assigns(expr.get("X"))
            self.arith_assigns(expr.get("Y"))
        elif kind == "UnaryArithm":
            if self.arith_op(expr) in ARITH_STEP_OPS:
                self.arith_target(expr.get("X"))
            self.arith_assigns(expr.get("X"))
        elif kind == "ParenArithm":
            self.arith_assigns(expr.get("X"))
        elif kind == "Word":
            fields = self.expand(expr, split=False)
            if fields is UNKNOWN:
                return
            for field in fields:
                for match in ARITH_TEXT_ASSIGN.finditer(field.value):
                    self.forget(match.group(1) or match.group(2))

    def arith_op(self, expr):
        """An arithmetic node's operator, as text.

        Read out of the source at `OpPos` for the reason `join_op` gives: the
        node's `Op` is a string under one installed shfmt and an index into the
        operator table under another, and an index matches no operator name,
        so every assignment read as none. None when no operator this scan
        knows stands there, which no node of the kinds asked about produces.
        """
        try:
            at = expr["OpPos"]["Offset"]
        except (KeyError, TypeError):
            return None
        for op in ARITH_OPS:
            if self.raw.startswith(op.encode("utf-8"), at):
                return op
        return None

    def arith_target(self, word):
        """Marks unknown the name the arithmetic assignment to `word` sets."""
        if not isinstance(word, dict):
            return
        fields = self.expand(word, split=False)
        if fields is UNKNOWN or len(fields) != 1:
            self.seal_opaque()
            return
        name = fields[0].value.split("[", 1)[0].strip()
        if IDENTIFIER.match(name):
            self.forget(name)

    def forget(self, name):
        """Records that `name` now holds a value this scan did not read.

        Under `set -a` the assignment exported it as well, so whether it is
        in a child's environment is in doubt too.
        """
        self.scope.assigns[name] = UNKNOWN
        if self.scope.allexport:
            self.scope.exported[name] = UNKNOWN

    def seal_opaque(self, cwd=False):
        """Puts every name, attribute and function in this scope in doubt.

        The state after something this scan cannot read acts on the shell
        itself: an `unset` of a name it cannot read, an arithmetic assignment
        to one, a `source`d file. With `cwd`, the directory is in doubt too.
        A function the file defines is no longer one the scan can follow, so
        the table is emptied and marked; see `dispatch`. So is which of them
        it exported.
        """
        # IFS is recorded rather than dropped, since `separators` reads a
        # missing one as the default: a startup or sourced file that sets
        # `IFS=:` makes `OUT=/ext:; bd -C $OUT close X` write /ext.
        self.scope.assigns = {"IFS": UNKNOWN}
        self.scope.exported = {}
        self.scope.sealed = OPAQUE
        self.functions = {}
        self.functions_sealed = True
        self.function_exports = UNKNOWN
        self.seals += 1
        if cwd:
            self.leave_cwd()

    def export_function(self, name, state):
        """Records `state`, True, False or UNKNOWN, as the export attribute
        of the function `name`; see `imported_functions`.

        bash exports only a function that is defined, so `export -f f`
        before `f() { ...; }` exports nothing.
        """
        if self.function_exports is UNKNOWN:
            return
        if state is UNKNOWN:
            self.function_exports = UNKNOWN
        elif state:
            if name in self.functions:
                self.function_exports.add(name)
        else:
            self.function_exports.discard(name)

    def imported_functions(self, shell, sealed, privileged, seed):
        """The function table a new `shell` process starts with, as `(table,
        in doubt, exported)` for `sub_scan`.

        A subshell is a copy of this shell, functions and all, but a new
        process has only what its environment carries. bash defines from it
        the functions `export -f` exported, unless privileged, and no other
        shell defines any: `bd() { :; }; bash -c 'bd -C /ext close X'` runs
        the program and writes /ext. A shell that may or may not define one
        -- `sh`, which may be bash, a privileged mode this scan cannot read,
        an environment a wrapper may have filtered -- leaves the table in
        doubt, as does an export this scan could not read.

        Each function travels as a `BASH_FUNC_<name>%%` entry, which `seed`,
        what the command line handed the process, may remove or set: after
        `env -u 'BASH_FUNC_bd%%'` bash defines no `bd`, and after `env
        'BASH_FUNC_bd%%=() { ...; }'` one from text this scan does not read,
        which leaves the table in doubt, in a cleared environment too.
        """
        kind = bash_kind(shell)
        if privileged is True or kind is False:
            return {}, False, set()
        entries = {}
        for key, value in seed.items():
            match = BASH_FUNC_ENTRY.match(key)
            if match:
                entries[match.group(1)] = value
        if any(value is not UNSET for value in entries.values()):
            return {}, True, UNKNOWN
        if sealed == CLEARED:
            return {}, False, set()
        if self.function_exports is UNKNOWN:
            return {}, True, UNKNOWN
        table = {name: self.functions[name] for name in self.function_exports
                 if name in self.functions and name not in entries}
        if table and (kind is UNKNOWN or privileged is UNKNOWN or
                      sealed == OPAQUE):
            return {}, True, UNKNOWN
        return table, False, set(table)

    def seal_sourced(self):
        """Puts all of this shell's state in doubt, as a `source`d file does.

        That is `seal_opaque` with the cwd, and with the options a later
        command is read under as well; see `dispatch`.
        """
        self.seal_opaque(cwd=True)
        self.scope.allexport = UNKNOWN
        self.scope.physical = UNKNOWN
        self.scope.monitor = UNKNOWN
        self.scope.lastpipe = UNKNOWN

    def stmts(self, stmts, conditional):
        """Scans a list of statements in order.

        `conditional` says that something before them made their execution
        depend on an exit status, which is what stops `false && cd /tmp/other;
        bd -C store ...` resolving against a directory the shell never entered.
        """
        for stmt in stmts or ():
            self.stmt(stmt, conditional)

    def join_op(self, cmd):
        """The operator joining a `BinaryCmd`'s two sides, as text.

        Read out of the source at the offset the tree gives rather than from the
        node's `Op`, which is an index into shfmt's operator table and shifts
        when that table changes -- the installed versions disagree, and a wrong
        reading is silent rather than an error. `OpPos` is the operator's own
        position, so a comment between the two sides cannot be mistaken for one.

        The offset counts bytes, so the lookup is made against the encoded text
        rather than the string: a character outside ASCII earlier in the command
        puts a character index past the operator, and the miss reads as "not a
        pipe" -- which applies a `cd` from one pipeline leg to the shell that
        never ran it.
        """
        try:
            at = cmd["OpPos"]["Offset"]
        except (KeyError, TypeError):
            return None
        for op in JOIN_OPS:
            if self.raw.startswith(op.encode("utf-8"), at):
                return op
        return None

    def stmt(self, stmt, conditional=False, follows=None):
        """Scans one statement, with its redirections.

        `follows` is the operator the statement is on the left of, empty at the
        end of a list. A `cd` followed by `||` is the mirror of a conditional
        one: what comes after runs precisely when the `cd` failed, so applying
        it names a directory the shell is in only on the branch not taken.
        """
        self.spend(1)
        # Every command of a pipeline runs in a subshell, as does one
        # backgrounded with `&`: `cd /tmp/other & bd -C store ...` leaves the
        # real shell where it was, and resolving the write under /tmp/other
        # names a store the command never opened. Nor does the shell wait for
        # the backgrounded one; see `in_background`.
        if stmt.get("Background"):
            self.in_background(lambda: self.body(stmt, conditional, follows))
        else:
            self.body(stmt, conditional, follows)

    def body(self, stmt, conditional, follows):
        for redir in stmt.get("Redirs") or ():
            # A redirection's operand is a file name, not an argument, so it
            # does not join the command's words. Its substitutions still run,
            # though, and a write inside one is a write:
            # `bd close CHR-1 > "$(bd create x)"`.
            if redir.get("Word"):
                self.word_subs(redir["Word"])
            # A here-document body is data, not script: scanning it as commands
            # applies a `cd` the shell never ran. Its substitutions do run when
            # the delimiter is unquoted, which the parse has already settled --
            # a quoted delimiter leaves the body a single literal.
            if redir.get("Hdoc"):
                self.word_subs(redir["Hdoc"])
        cmd = stmt.get("Cmd")
        if cmd:
            self.cmd(cmd, conditional, follows)

    def cmd(self, cmd, conditional, follows):
        kind = cmd["Type"]
        if kind == "CallExpr":
            self.call(cmd, conditional, follows)
        elif kind == "BinaryCmd":
            # `&&`, `||` and `|` all make what follows depend on an exit
            # status. The dependence is one-way: a command after a `&&` cannot
            # be reasoned about without evaluating what precedes it, so the
            # right side stays conditional however it is joined further on.
            op = self.join_op(cmd)
            if op in PIPE_OPS:
                # Every member of a pipeline runs in a subshell, either side of
                # the operator: `cd /tmp/other | true; bd -C store ...` leaves
                # the real shell where it was, and resolving the write under
                # /tmp/other names a store the command never opened. The
                # exception is the last member under `shopt -s lastpipe`,
                # which runs in this shell: `true | cd /external; bd close X`
                # then writes /external's store, and a frame around it
                # restored a cwd the shell had left. The tree nests a longer
                # pipeline to the left, so `Y` is always the last member.
                self.scoped(lambda: self.stmt(cmd["X"], conditional))
                stays = self.scope.last_member_stays()
                if stays is UNKNOWN:
                    self.tentative(lambda: self.stmt(cmd["Y"], True))
                elif stays:
                    self.stmt(cmd["Y"], conditional)
                else:
                    self.scoped(lambda: self.stmt(cmd["Y"], True))
            else:
                self.stmt(cmd["X"], conditional, op)
                self.stmt(cmd["Y"], True)
        elif kind == "Subshell":
            # Everything to the matching `)` runs in a subshell, so its cwd and
            # assignments must not outlive it: `(cd /tmp/other); bd -C store
            # ...` leaves the real shell where it was.
            self.scoped(lambda: self.stmts(cmd.get("Stmts"), False))
        elif kind == "Block":
            # A brace group runs in this shell, and its `cd` and assignments
            # do reach the command after it. One nothing made conditional is
            # as certain as the statements around it, so it is walked in
            # place: scanned in a frame, `OUT=/old; { OUT=/real; }; bd -C
            # "$OUT" ...` was resolved against /old, a store the command never
            # opened. A conditional one may not have run at all, so what it
            # changes is unknown afterwards rather than restored or kept.
            if conditional:
                self.tentative(lambda: self.stmts(cmd.get("Stmts"), True))
            else:
                self.stmts(cmd.get("Stmts"), False)
        elif kind == "IfClause":
            self.if_clause(cmd)
        elif kind == "WhileClause":
            self.branch(cmd.get("Cond"))
            self.branch(cmd.get("Do"))
        elif kind == "ForClause":
            self.for_clause(cmd)
        elif kind == "CaseClause":
            if cmd.get("Word"):
                self.word_subs(cmd["Word"])
            for item in cmd.get("Items") or ():
                # A pattern is a word the shell expands before matching it, so
                # a substitution in one runs: `case x in "$(bd -C /tmp/store
                # close X)") ;; esac` writes that store. Scanning only the
                # arms found nothing to sync. Every arm's patterns are
                # visited though matching stops at the first that matches --
                # a write scanned that did not run costs a no-op commit, where
                # one skipped that did run leaves the store unsynced.
                for pattern in item.get("Patterns") or ():
                    self.word_subs(pattern)
                self.branch(item.get("Stmts"))
        elif kind == "FuncDecl":
            self.func_decl(cmd)
        elif kind == "TimeClause":
            if cmd.get("Stmt"):
                self.stmt(cmd["Stmt"], conditional, follows)
        elif kind == "CoprocClause":
            # A coprocess is a subshell, and the command in one is a real
            # invocation: `coproc bd -C /tmp/store close CHR-1` writes that
            # store, and word-scanning the clause would find only its
            # substitutions and miss the write itself. The shell does not
            # wait for it; see `in_background`.
            if cmd.get("Stmt"):
                self.in_background(
                    lambda: self.stmt(cmd["Stmt"], conditional))
        elif kind == "DeclClause":
            self.decl(cmd, conditional)
        elif kind == "TestClause":
            # `[[ ]]` runs no command and writes no store, but a substitution
            # inside one still runs.
            self.walk_words(cmd)
        elif kind == "ArithmCmd":
            # `((...))` runs in this shell, so what it assigns is assigned
            # here; see `arith_assigns`.
            self.walk_words(cmd)
            self.arith_assigns(cmd.get("X"))
        elif kind == "LetClause":
            self.walk_words(cmd)
            # Named first, as one always is, it may be a function after a
            # startup or sourced file; see `dispatch`.
            if self.functions_sealed:
                self.seal_sourced()
            else:
                for expr in cmd.get("Exprs") or ():
                    self.arith_assigns(expr)

    def branch(self, stmts):
        """Scans statements that may or may not run.

        Their writes count -- a `bd` inside a loop is a write if the loop runs
        once -- but what they change must not speak for the commands after
        them: a name they assign is unknown from there, and so is the cwd they
        left behind.
        """
        if not stmts:
            return
        self.tentative(lambda: self.stmts(stmts, True))

    def for_clause(self, cmd):
        """Scans a `for`, with the name its header assigns.

        The header runs before the body and whether or not the body ever does,
        so its substitutions are scanned first, wherever the form puts them:
        `for x in $(bd close X)` and `for ((i = $(bd close X); ...))` both run
        the write, and visiting only a word list missed the arithmetic form.

        A word-iterating `for` assigns its name on every pass, which is an
        assignment the tree does not spell as one: `OUT=/old; for OUT in
        /real; do bd -C "$OUT" close X; done` writes /real, and reading the
        body against the value from before the loop named a store the command
        never opened while the one it wrote went unregistered. When every item
        is known the body is scanned once per value, which is what runs; a
        list that cannot be read, or none at all -- `for x; do` iterates the
        positional parameters, which the scan does not have -- leaves the name
        unknown for the body. It is unknown after the loop either way: which
        pass was the last is what the scan declines to infer.
        """
        loop = cmd.get("Loop") or {}
        self.node_subs(loop)
        body = cmd.get("Do")
        if loop.get("Type") == "CStyleLoop":
            # The header's three expressions assign in this shell: `for
            # ((OUT=1; OUT<2; OUT++))` leaves OUT changed for the body and
            # after it, and reading the body against the value from before
            # the loop named a store the command never opened.
            for key in ("Init", "Cond", "Post"):
                self.arith_assigns(loop.get(key))
        if loop.get("Type") != "WordIter" or not loop.get("Name"):
            self.branch(body)
            return
        name = loop["Name"]["Value"]
        values = None
        items = loop.get("Items") or ()
        if items:
            fields = self.expand_args(items)
            if 0 < len(fields) <= FOR_ITEMS_MAX and \
                    all(field.value is not UNKNOWN for field in fields):
                values = [self.expand_tilde(field.value) if field.tilde
                          else field.value for field in fields]
        # Bound as an assignment is, export state included: under `set -a` the
        # loop variable is exported, so `set -a; for BEADS_DIR in /ext/.beads;
        # do bd close X; done` opens /ext's store. Written into `assigns`
        # alone it read as a shell variable `bd` never saw.
        if values is None:
            self.forget(name)
            self.branch(body)
            return
        for value in values:
            self.bind(name, value)
            self.branch(body)
        self.forget(name)

    def bind(self, name, value):
        """Gives `name` the `value` a `for` binds, exported under `set -a`."""
        self.scope.assigns[name] = value
        if self.scope.allexport is UNKNOWN:
            self.scope.exported[name] = UNKNOWN
        elif self.scope.allexport:
            self.scope.exported[name] = True

    def if_clause(self, cmd):
        """Scans an `if`, including the `elif`s nested in its else arm.

        Every part is scanned as a branch, the condition included: an `if` is
        one compound command, and which of its arms ran is exactly what the
        scan declines to infer. So the cwd after it is unknown.
        """
        while cmd:
            self.branch(cmd.get("Cond"))
            self.branch(cmd.get("Then"))
            # A plain `else` arm is an else arm with no condition, so the same
            # loop walks it and stops.
            cmd = cmd.get("Else")

    def walk_words(self, node):
        """Scans every word anywhere under `node` for substitutions."""
        if isinstance(node, dict):
            if isinstance(node.get("Parts"), list):
                self.word_subs(node)
            for key, value in node.items():
                if key != "Parts":
                    self.walk_words(value)
        elif isinstance(node, list):
            for item in node:
                self.walk_words(item)

    def func_decl(self, cmd):
        """Scans a function body without letting it speak for the shell.

        A definition stores its body rather than running it, so a `cd` in one
        has not happened when the command after it runs. The body is scoped
        rather than skipped: what it does when called is unknown, so its `cd`s
        and assignments must not reach past the definition -- but a `bd` written
        inside one is still a write this text performs if the function is ever
        called, and dropping it would strand the store it opens.
        """
        body = cmd.get("Body")
        if not body:
            return
        # Kept so a later call can scan it again under the cwd the caller
        # stands in, which is the only place a relative target inside it can be
        # resolved from. The text it was parsed from is kept with it; see
        # `call_function`.
        if cmd.get("Name"):
            name = cmd["Name"]["Value"]
            self.functions[name] = (body, self.text, self.raw)
            # Under `set -a` a function is exported as it is defined, and
            # stays exported after `set +a`: `set -a; go() { cd /ext; }; set
            # +a; bash -c 'go; bd close X'` writes /ext. See
            # `imported_functions`.
            if self.scope.allexport is not False:
                self.export_function(name, self.scope.allexport)

        def run():
            # Scanned here too, and with the cwd unknown. A definition that is
            # never called still performs no write, but one whose call this scan
            # cannot see -- reached through `eval`, a variable, another file --
            # would otherwise strand the store its body opens. So the body is
            # scanned where it stands, on the terms the definition supports: it
            # does not say where its caller stands, so a relative path in it
            # names no directory knowable from here, while an absolute `cd`
            # inside it does say where the write after it lands.
            self.scope.known = False
            self.scope.moved = True
            self.stmt(body)

        self.scoped(run)

    def call_function(self, name, seed=None):
        """Scans the body of `name` as it runs here, in the caller's directory.

        This is what makes `f() { bd -C store ...; }; cd /x; f` name /x/store.
        The definition alone cannot: it does not say where its caller stands, so
        scanning it in place leaves a relative target unresolvable. At the call
        the cwd is known, and the body is the same text.

        `seed` is the call's temporary prefix, which is in force and exported
        while the body runs, and gives way to the values from before it once
        the body returns, whatever the body assigned to those names:
        `OUT=/decoy; f() { bd -C "$OUT" close X; }; OUT=/ext f` writes /ext,
        and OUT is /decoy again after it. bash, POSIX-mode bash, dash and zsh
        agree. An `unset` in the body takes the temporary value away instead,
        so an assignment after it outlives the call: after `OUT=/old; f() {
        unset OUT; OUT=/ext; }; OUT=/tmp f`, OUT is /ext in bash. A name the
        body may have unset is unknown after the call rather than restored,
        and so is every one after a seal in the body, which may have unset
        any.

        The body is read against the text it was defined in, which its
        offsets index: called from an `eval`, or from a child bash that
        imported it, it is not the text being scanned there, and `f() {
        ((OUT=1)); }; OUT=/decoy; eval 'f; bd -C "$OUT" close X'` read its
        operator out of the `eval` text and kept /decoy.

        Recursion is refused rather than bounded by depth, since a function that
        calls itself names no further store on the second pass. That is the whole
        termination argument here: a body already being scanned is not scanned
        again, so a chain of calls is at most as long as there are definitions.
        """
        if name in self.calling:
            return
        body, text, raw = self.functions[name]
        seed = seed or {}

        def run():
            missing = object()
            before = {each: (self.scope.assigns.get(each, missing),
                             self.scope.exported.get(each, missing))
                      for each in seed}
            for each, value in seed.items():
                self.scope.assigns[each] = value
                self.scope.exported[each] = value is not UNSET
            outer_unset, self.unset_names = self.unset_names, set()
            seals = self.seals
            outer_text, outer_raw = self.text, self.raw
            self.text, self.raw = text, raw
            try:
                self.stmt(body)
            finally:
                self.text, self.raw = outer_text, outer_raw
                unset = self.unset_names
                self.unset_names = outer_unset | unset
                for each, (value, exported) in before.items():
                    if each in unset or self.seals != seals:
                        self.scope.assigns[each] = UNKNOWN
                        self.scope.exported[each] = UNKNOWN
                        continue
                    for table, old in ((self.scope.assigns, value),
                                       (self.scope.exported, exported)):
                        if old is missing:
                            table.pop(each, None)
                        else:
                            table[each] = old

        self.calling.add(name)
        self.depth += 1
        try:
            # A call is not a subshell: a `cd` or assignment inside a function
            # does reach the command after the call. But whether the body ran
            # to the end, and which of its branches it took, is exactly what
            # the scan declines to infer -- so what it changed is unknown
            # afterwards, as it is after any compound command.
            self.tentative(run)
        finally:
            self.depth -= 1
            self.calling.discard(name)

    def decl(self, cmd, conditional):
        """Records the assignments an assignment builtin makes.

        An assignment builtin is the same thing said as a command, and unlike a
        temporary prefix it outlives the command: `export OUT=/tmp/store` leaves
        OUT set for everything after it, so a later `bd -C "$OUT"` addresses
        that store. Ignoring it read the hook's own inherited OUT instead, and
        the store the write actually opened went unpushed and unregistered.
        """
        args = cmd.get("Args") or ()
        # A substitution in any operand runs, the ones that assign nothing
        # included: `export $(bd close X)` runs the write. It runs whatever the
        # command's own reachability is, so the operands are visited for them
        # before that is consulted.
        for arg in args:
            self.node_subs(arg)
        # The parse makes a clause of one only where it is named first, so
        # after a startup or sourced file it may be a function; see
        # `dispatch`.
        if self.functions_sealed:
            self.seal_sourced()
            return
        # What the builtin says about export. `export` and `declare -x` give
        # the attribute to every name they are handed, assigned or bare;
        # `export -n` and `declare +x` take it away; `local` makes a fresh
        # variable that has it only with `-x`. The flags come first, as words
        # the parse marks naked with no name. With `-f` the names are those
        # of functions; see `export_function`.
        variant = (cmd.get("Variant") or {}).get("Value")
        state = None
        functions = False
        if variant == "export":
            state = True
        elif variant == "local":
            state = False
        for arg in args:
            if arg.get("Name") or not arg.get("Naked"):
                continue
            flag = self.assigned_value(arg.get("Value"))
            if flag is not UNKNOWN and flag.startswith("-") and \
                    "f" in flag[1:]:
                functions = True
            if flag is UNKNOWN:
                # A flag this scan cannot read may be `-x`, `-n` or `-f`, so
                # what the builtin did to the attribute is unknown, and
                # whether to a variable or a function.
                state = UNKNOWN
                if functions is False:
                    functions = UNKNOWN
            elif flag == "--":
                break
            elif variant == "export" and flag.startswith("-") and \
                    "n" in flag[1:]:
                state = False
            elif variant != "export" and flag.startswith("-") and \
                    "x" in flag[1:]:
                state = True
            elif variant != "export" and flag.startswith("+") and \
                    "x" in flag[1:]:
                state = False
        if conditional and state is not None:
            state = UNKNOWN
        if functions is not False and state is not None:
            for arg in args:
                name = (arg.get("Name") or {}).get("Value")
                if name:
                    self.export_function(
                        name, state if functions is True else UNKNOWN)
        if functions is True:
            return
        for arg in args:
            name = (arg.get("Name") or {}).get("Value")
            if not name:
                continue
            # `export OUT` exports a name without changing its value, so only
            # the operands that are assignments assign.
            if gives_value(arg) or replaces_value(arg):
                self.assign(arg, conditional)
            if state is not None:
                self.scope.exported[name] = state

    def assign(self, arg, conditional):
        """Records the assignment node `arg` in this scope.

        Its substitutions have already been visited by the caller. `X=` has no
        value node at all, and assigns the empty string.

        An assignment the shell may never reach leaves the name unknown: kept,
        the value from before it spoke for `OUT=/old; t && OUT=/real; bd -C
        "$OUT" ...` and resolved the write against /old, a store the command
        may never have opened, while /real went unsynced.

        Under `set -a` the assignment exports the name as well. Otherwise it
        leaves the attribute as it was, which `is_exported` reads.
        """
        name = arg["Name"]["Value"]
        if replaces_value(arg):
            self.forget(name)
            return
        self.scope.assigns[name] = (UNKNOWN if conditional
                                    else self.assign_value(arg))
        if self.scope.allexport is UNKNOWN:
            self.scope.exported[name] = UNKNOWN
        elif self.scope.allexport:
            self.scope.exported[name] = UNKNOWN if conditional else True

    def call(self, cmd, conditional, follows):
        """Handles one simple command.

        Records its assignments, replays a `cd` that certainly runs, and reports
        a `bd` write with the store it addresses.
        """
        assigns = cmd.get("Assigns") or ()
        args = cmd.get("Args") or ()

        # A substitution runs before the command whose word carries it, and
        # runs whatever the command's own reachability is, so every word is
        # visited for them first, prefix assignments included. An assignment
        # is walked whole rather than by its value: an index and an array
        # literal are expanded too, so `A[$(bd close X)]=v` and `B=($(bd close
        # X))` both run the write, and visiting the value alone found neither.
        for arg in assigns:
            self.node_subs(arg)
        for arg in args:
            self.word_subs(arg)

        if not args:
            # An assignment-only command is the only form whose assignments
            # outlive it. In the prefix position they reach the child's
            # environment alone: the shell expands a command's argv before
            # applying that command's own temporary assignments, so `$OUT` in
            # `OUT=/tmp/decoy bd -C "$OUT"` is the inherited value. A temporary
            # assignment therefore speaks for neither this command's arguments
            # nor any later command.
            for arg in assigns:
                if gives_value(arg) or replaces_value(arg):
                    self.assign(arg, conditional)
            return

        # The words become the argument list the command receives before any of
        # it is read, since an unquoted expansion can supply more arguments than
        # the word it came from -- or none -- and every reader below counts
        # arguments.
        fields = self.expand_args(args)
        if not fields:
            return

        start, split = self.command_word(fields)
        # A wrapper may run the command in a directory of its own, and which
        # store `bd` selects turns on the directory it runs in. Applied here,
        # once, around every reader below rather than at each of them: the
        # directory is a property of the invocation, and `-C`, BEADS_DIR and the
        # walk up all resolve against it. A frame is entered only when there is
        # one to apply, so an unwrapped `cd` still reaches the command after it.
        # An `env -S` changes directory only once its string's options are
        # read too, so its own `-C` is left to `split_wrapper`: `start` is
        # that `env` itself.
        cwd = None if start is None else self.wrapper_chdir(fields, start)
        cwd, spelled = self.wrapper_pwd(cmd, fields, start, cwd)
        if cwd is None and split is None:
            cwd, spelled = self.given_pwd(cmd, fields, start)
        # A builtin behind a wrapper that runs a program runs as a process of
        # its own, if at all, so what it changes dies with it: after `env cd
        # /decoy` the shell is where it was, and dispatching the `cd` here
        # moved the scan to /decoy. See `SPAWN_WORDS`.
        spawned = start is not None and any(
            fields[j].value is not UNKNOWN and
            fields[j].value.rsplit("/", 1)[-1] in SPAWN_WORDS
            for j in range(start))
        if cwd is not None or spawned:
            # The command's environment was settled before the wrapper moved
            # it: its prefix is expanded, and PWD inherited, in the shell that
            # runs the wrapper. So that is the scope `command_env` reads it
            # in, while everything else resolves against the wrapper's
            # directory: from /old, `env -C /new -S 'bd -C ${PWD} ...'` passes
            # `-C /old`, and `PWD="$PWD/link" env -C link bash -c ...` hands
            # the shell /ws/link, where reading either in the moved frame
            # named /new and /ws/link/link.
            #
            # A wrapper that may return before its command finishes runs it
            # as `&` does, and one a `setsid` leads passes that on to what it
            # runs; see `detaches`.
            run = self.in_background if self.detaches(fields, start) \
                else self.scoped
            leader = self.leader
            self.leader = self.leads(fields, start)
            self.callers[id(cmd)] = self.scope
            try:
                run(lambda: self.dispatch(cmd, fields, start, split,
                                          conditional, follows, cwd, spelled))
            finally:
                self.callers.pop(id(cmd), None)
                self.leader = leader
            return
        self.dispatch(cmd, fields, start, split, conditional, follows, None)

    def wrapper_pwd(self, cmd, args, end, cwd, posix=False):
        """The directory the wrappers moved the command to, as it names it,
        and whether that spelling is known.

        A wrapper's `chdir` leaves `PWD` in the environment as it was, and
        bash, dash and ksh -- like Go's `os.Getwd`, which `bd` uses -- keep an
        inherited PWD that names the directory they start in. So after `cd
        /a/link; env -C .` the command's PWD is still /a/link, and a `cd ..` or
        `bd -C ..` inside it reads `..` from there and lands in /a. Where PWD
        names some other directory, or none reaches the command, it starts
        from the physical path `getcwd` gives, which is what `cwd` holds. So
        it does in zsh, with `posix`, where a component of PWD is `.` or `..`,
        as POSIX asks.

        A PWD whose `..` follows a symlink keeps its spelling, collapsing it
        by name naming another directory: with `link` pointing at /ext/child,
        PWD=/ws/link/.. names /ext, and `cd -P .` there stays in /ext in bash
        3.2 and dash, where reading the PWD as /ws named a store the command
        never opened. `bd` does collapse it as it reads it, and walks up from
        /ws, as `bead_root` does; so does bash from 4.4, which `cd` allows for.

        A PWD this scan cannot read may be anything naming the directory, a
        `..` after a symlink included, so its spelling is UNKNOWN: a relative
        path, `$PWD`, `~+` and the walk `bd` makes from there are left
        unresolved; see `Scope.spelled`. `sudo` and `doas` are read more
        closely, as their policy passes the PWD they were handed or drops it
        and sets none of its own: the spelling is that one or the physical
        path, and only where the two differ is it in doubt -- False, or
        UNKNOWN where the one handed over hides a `..` after a symlink.
        """
        if cwd is None or cwd is UNKNOWN:
            return cwd, True
        pwd = self.command_env(cmd, args, end, "PWD")
        if pwd is not UNKNOWN:
            return self.pwd_spelling(pwd, cwd, posix)
        handed = self.handed_pwd(cmd, args, end)
        if handed is UNKNOWN:
            return cwd, UNKNOWN
        kept = self.pwd_spelling(handed, cwd, posix)
        if kept == (cwd, True):
            return kept
        return cwd, UNKNOWN if ".." in kept[0].split("/") else False

    @staticmethod
    def pwd_spelling(pwd, cwd, posix):
        """How a process started in `cwd` with PWD `pwd` spells its
        directory, as `(spelling, True)`; see `wrapper_pwd`."""
        if not isinstance(pwd, str) or not pwd.startswith("/") or \
                not same_dir(pwd, cwd):
            return cwd, True
        if posix and {".", ".."} & set(pwd.split("/")):
            return cwd, True
        collapsed = logical_path(pwd)
        if collapsed is not None and same_dir(collapsed, pwd):
            return collapsed, True
        return pwd, True

    def given_pwd(self, cmd, args, start):
        """Where the `bd` at `args[start]` reads its directory from when no
        wrapper moved it but its PWD was given rather than inherited, as
        `(cwd, spelled)` for `dispatch`; `(None, True)` when it is this
        shell's own.

        `bd` takes a PWD naming the directory it starts in as that
        directory's spelling, and reads `-C ..` from there, so from
        /ext/child, with `link` pointing there, `env PWD=/ws/link bd -C ..
        close X` and `PWD=/ws/link bd -C .. close X` both write /ws's store,
        where reading `..` from the shell's own spelling named /ext. A prefix
        or a wrapper that sets, unsets or clears PWD, or passes it by a
        policy this scan cannot read, is read as `wrapper_pwd` reads one
        that moves the command, and as `shell_pwd` reads a child shell. So
        is a PWD this shell assigned or unset since its last `cd`, or stopped
        exporting: `export PWD=/ws/link; bd -C .. close X` writes /ws's store
        too. A builtin or a function runs in this shell and reads none of it,
        but only a command named first calls a function, as in `dispatch`:
        with a function `bd` defined, `export PWD=/ws/link; command bd -C ..
        close X` runs the program, which writes /ws's store.
        """
        if start is None or start >= len(args) or not self.scope.known:
            return None, True
        word = args[start].value
        if word is UNKNOWN or (start == 0 and word in self.functions) or \
                word.rsplit("/", 1)[-1] != "bd":
            return None, True
        assigns, sealed = self.prefix_env(args, start)
        if not sealed and "PWD" not in assigns and \
                "PWD" not in self.scope.assigns and \
                self.scope.exported.get("PWD", True) is True and not any(
                    gives_value(arg) and arg["Name"]["Value"] == "PWD"
                    for arg in cmd.get("Assigns") or ()):
            return None, True
        if not os.path.isdir(self.scope.cwd):
            return None, True
        return self.wrapper_pwd(cmd, args, start, chdir_path(self.scope.cwd))

    def handed_pwd(self, cmd, args, end):
        """The PWD the last `sudo` or `doas` in `args[:end]` was handed, or
        UNKNOWN when something else may have left it unread."""
        last = None
        for i in range(end):
            word = args[i].value
            if word is UNKNOWN:
                return UNKNOWN
            if word.rsplit("/", 1)[-1] in WRAPPER_ENV_UNREADABLE:
                last = i
        if last is None:
            return UNKNOWN
        return self.command_env(cmd, args, last, "PWD")

    def dispatch(self, cmd, fields, start, split, conditional, follows, cwd,
                 spelled=True):
        """Hands the command at `fields[start]` to the reader that knows it.

        `cwd` is the directory a wrapper runs it in, or None when it runs here,
        and `spelled` whether its PWD spelling is known. Applied to this frame
        rather than passed on, so every reader below -- and every scope nested
        inside them -- resolves against it.
        """
        if cwd is not None:
            if cwd is UNKNOWN:
                # A directory named and unreadable leaves the store unknowable
                # rather than the launch directory's: `bd` runs where the wrapper
                # put it, and the walk up from here would name a store the
                # command never opened.
                self.leave_cwd()
            else:
                self.enter_cwd(cwd, spelled)

        if split is not None:
            self.split_wrapper(cmd, fields, start, split)
            return
        if start is None or start >= len(fields):
            return
        word = fields[start].value
        if word is UNKNOWN:
            return
        name = word.rsplit("/", 1)[-1]
        # A function's name may hold a `/`, and bash calls one so named, in
        # POSIX mode too, rather than running the program the path names:
        # after `./cd() { builtin cd /ext; }`, `./cd /known; bd close X`
        # writes /ext. No builtin is named by a path, so one this text
        # defined is called before the path is read as a program.
        if start == 0 and name != word and word in self.functions:
            self.call_function(word, self.prefix_seed(cmd))
            return
        if name != word and name in SHELL_STATE_WORDS:
            return

        # After a startup or sourced file, a builtin read for what it does to
        # this shell may be a function that file defined, which may do
        # anything there: with BASH_ENV defining `cd() { builtin cd /ext; }`,
        # `bash -c 'cd -L /known; env -i bd close X'` writes /ext. So the
        # state after one named first is in doubt as the file's own is.
        # `eval`'s text is still read, a write in it being one the builtin
        # makes. `builtin cd` and `command cd` pass any function by, and are
        # read as before.
        if start == 0 and self.functions_sealed and name in SHELL_STATE_WORDS:
            if name == "eval":
                self.eval_builtin(cmd, fields, start, conditional)
            self.seal_sourced()
            return

        if name in CHDIR_WORDS:
            self.cd(fields, start, conditional, follows, name, cmd)
            return

        if name == "unset":
            self.unset_builtin(fields, start, conditional)
            return

        if name == "set":
            self.set_builtin(fields, start, conditional)
            return

        if name == "shopt":
            self.shopt_builtin(fields, start, conditional)
            return

        if name in SHELL_WORDS:
            self.shell_wrapper(cmd, fields, start)
            return

        if name == "eval":
            self.eval_builtin(cmd, fields, start, conditional)
            return

        # `source` runs a file this scan does not read, in this shell: what
        # it assigns, unsets, exports, defines or `cd`s to is unknowable, so
        # nothing known before it speaks for the commands after it. `.
        # ./select-store.sh; bd close X` may have moved the shell or set
        # BEADS_DIR, and reading on with the old state named a store the
        # command never opened, with no warning. It may `set -P` or `set +P`
        # too, so how a later `cd` reads `..` is in doubt with the rest, and
        # `set -m` or `shopt -s lastpipe`, so whether a pipeline's last member
        # runs here and whether a `setsid` forks are in doubt as well. So is
        # `set -a`, which exports a later plain `BEADS_DIR=...` to `bd`.
        if word in SOURCE_WORDS:
            self.seal_sourced()
            return

        if name in READ_WORDS:
            self.read_builtin(fields, start, name)
            return

        if name == "getopts":
            for each in ("OPTIND", "OPTARG"):
                self.forget(each)
            if start + 2 < len(fields):
                target = fields[start + 2].value
                if target is UNKNOWN:
                    self.seal_opaque()
                elif IDENTIFIER.match(target):
                    self.forget(target)
            return

        if name == "printf":
            self.printf_builtin(fields, start)
            return

        # A call runs the body defined earlier in this text, and runs it here,
        # where the cwd is known. Without this a relative store named inside a
        # function was reported by nothing: the definition cannot resolve it and
        # the call did not look. Only a command named first is one: `command`
        # and every other wrapper run a program, so `bd() { command bd -C /ext
        # close X; }; bd` writes /ext.
        if start == 0 and word in self.functions:
            self.call_function(word, self.prefix_seed(cmd))
            return

        if name != "bd":
            return

        operands, target, store, helped, flags = self.bd_operands(fields, start)
        if self.readonly(operands, helped, flags):
            return
        self.mutates = True
        # Named first after a startup or sourced file, `bd` may be a function
        # that file defined, which may write any store: with BASH_ENV defining
        # `bd() { command bd -C /ext close X; }`, `bash -c 'bd -C /expected
        # close X'` writes /ext. The store the arguments name is still
        # reported, being the one the program opens. A read-only call is left
        # alone, a wrapper of that kind passing its verb on.
        if start == 0 and self.functions_sealed:
            self.unresolved += 1

        # A store outside every workspace root is one no later event would
        # revisit: SessionEnd builds its list the same way, so that write would
        # sit local indefinitely. Which store this invocation opens is therefore
        # reported for every mutating `bd`, not only for one carrying `-C`.
        #
        # `--db` names the store ahead of everything else. `-C` still has to
        # name a workspace -- `bd` refuses one holding no store -- but the
        # store written is the one `--db` names, so `bd -C /repo --db
        # /other/.beads close X` synced /repo while /other's write sat local.
        # A relative value resolves from where the command ran, not from the
        # `-C` directory, which is how `bd` reads it.
        if store is not None:
            resolved = self.resolve_field(store)
            if not resolved:
                self.unresolved += 1
                return
            self.found_db(resolved)
            return
        if target is None:
            # Without `-C`, `bd` selects its store by walking up from the
            # directory it runs in -- so `cd /other/repo && bd close X` writes
            # /other/repo/.beads, a store this reported nothing about. Reading a
            # missing `-C` as "some workspace root" was true of the common case
            # and silently wrong of that one.
            #
            # BEADS_DIR names the store outright, and only when no `-C` overrides
            # it; BEADS_DB does the same and is consulted only when BEADS_DIR is
            # unset. Both point at the store rather than the root holding it.
            # `bd` reads an empty one as unset, so after `env BEADS_DIR=
            # BEADS_DB=/ext/.beads bd close X` it writes /ext's store, where
            # stopping at the empty BEADS_DIR reported the launch directory's.
            named = None
            for env_name in BD_STORE_ENV:
                named = self.command_env(cmd, fields, start, env_name)
                if named is not None and named != "":
                    break
            if named is None:
                named = ""
            elif named is UNKNOWN:
                # A BEADS_DIR this scan cannot read may name any store, so the
                # walk-up below would be a guess rather than an answer -- and
                # would name the store the walk finds while the write went to
                # the one BEADS_DIR pointed at. The same holds of a BEADS_DB
                # that cannot be read once BEADS_DIR is known to be unset.
                self.unresolved += 1
                return
            if named:
                resolved = self.resolve_value(named, False)
                if not resolved:
                    self.unresolved += 1
                elif env_name == "BEADS_DIR":
                    # The root is what holds the `.beads` the value names, so
                    # the last component comes off -- but only once it is the
                    # last. `BEADS_DIR=/repo/.beads/` is the same directory
                    # written with a separator after it, and taking the empty
                    # component off left `/repo/.beads`, which holds no
                    # `.beads` of its own: the hook dropped it as no root, and
                    # the write went neither to the push set nor the registry.
                    trimmed = resolved.rstrip("/") or "/"
                    self.found_target(trimmed.rsplit("/", 1)[0] or "/")
                else:
                    # BEADS_DB is read as `--db` is: the directory or a file
                    # inside it, with the store found from the value's parent.
                    self.found_db(resolved)
                return
            # `bd` reads its directory from PWD where that names it, and
            # collapses a `..` in it by name, so where the PWD's spelling is
            # unknown so is where the walk starts; see `Scope.spelled`.
            if not self.scope.known or self.scope.spelled is UNKNOWN:
                self.unresolved += 1
                return
            # No ancestor holding a store is no store to sync: `bd` itself fails
            # there, so there is nothing stranded and nothing to report -- in
            # the foreground. In the background see `walk_from`.
            root = bead_root(self.scope.cwd)
            if root is not None:
                self.found_target(root)
            self.walk_from(self.scope.cwd, root)
            return
        resolved = self.resolve_field(target)
        # A `-C` that was named and could not be resolved is the one case with
        # nothing standing behind it. The roots sync, but this store is not among
        # them and no other command names its path, so neither the marker retry
        # nor SessionEnd can find it. Counted so the hook can say so, that
        # warning being the only thing left in place of the sync.
        if not resolved:
            self.unresolved += 1
            return
        # `-C` is where `bd` starts looking, not necessarily where it finds: it
        # walks up from there as it would from any cwd. So `bd -C repo/sub close
        # X` writes `repo/.beads`, and reporting the subdirectory named a root
        # the hook then skipped for holding no `.beads` -- leaving the store that
        # was written in neither the push set nor the registry.
        #
        # A `-C` naming no directory is reported as it stands rather than walked
        # up from: `bd` refuses such a path outright, so no store is written, and
        # walking would name an ancestor's store that this command never opened.
        # In the background the job may make it first; see `walk_from`.
        root = bead_root(resolved) if os.path.isdir(resolved) else None
        if root is not None:
            self.found_target(root)
        elif not self.background:
            self.found_target(resolved)
        self.walk_from(resolved, root)

    def walk_from(self, start, root):
        """Reports `start`, a directory a `bd` in the background walks up
        from, for SessionEnd to walk up from in its turn.

        `root` is what the walk finds now, which need not be what it finds
        when the write lands: the job may make a store first, where there was
        none or nearer than the one there is -- `(cd /ws/child; bd init; bd
        create X) &` under /ws's store, or `(mkdir -p /n/.beads /n/sub; bd -C
        /n/sub close X) &` -- and syncing only what the walk finds now left
        that store unsynced and unrecorded. So the start is reported too,
        marked with a leading `+`, and the hook walks up from it when
        SessionEnd comes. Not where the store is the start itself, as none can
        come nearer than that.
        """
        if not self.background:
            return
        # The start as `bd` reads it, `..` collapsed by name: with `link`
        # pointing at /r/child, `-C /r/sub/link/..` starts in /r/sub, and
        # comparing the kernel's /r with the store found there dropped it.
        start = os.path.normpath(start)
        if root is not None and same_dir(root, start):
            return
        self.found_target("+" + start)

    def found_db(self, path):
        """Reports the store the `--db` or BEADS_DB value `path` opens.

        `bd` takes the value's parent, opens that if it is itself a `.beads`,
        and otherwise walks up from it; see `store_root`. In the background
        that walk may find a store the job makes first, as `-C`'s may, so its
        start is reported too: `(mv /seed/.beads /ext/child/.beads; bd --db
        /ext/child/x.db close X) &` writes /ext/child's store, where only
        /ext's was recorded. See `walk_from`.
        """
        self.found_target(store_root(path))
        parent = (path.rstrip("/") or "/").rpartition("/")[0] or "/"
        if parent.rpartition("/")[2] != ".beads":
            self.walk_from(parent, bead_root(parent))

    def command_env(self, cmd, args, start, name):
        """The value `name` has in the environment this command runs with.

        A prefix assignment or a wrapper's own assignment reaches the child's
        environment though it speaks for none of the command's own words -- the
        shell expands argv before applying it. So `BEADS_DIR=/other/.beads bd
        close X` writes that store while `bd -C "$BEADS_DIR"` on the same line
        would not, and reading the scope alone answered for the second case only.

        None says nothing names it, which is not the same as UNKNOWN: a name that
        is simply unset leaves the default behaviour in force, where one whose
        value cannot be read leaves the store in doubt. Conflating the two makes
        every command carrying neither report an unresolvable store.

        Read in the order the shell applies them, innermost last. The prefix is
        applied first and a repeated name takes its last value, so `X=/a X=/b
        bd` runs with /b; a wrapper then sets its own on top, so `X=/a env X=/b
        bd` runs with /b too, and one that clears or filters the environment
        drops the prefix's value with the rest. Answering from the first prefix
        assignment named a store the command never opened in each of those.

        Only what the child can see is consulted. A shell variable the text
        assigned reaches the child only if it is exported -- by `export`, by
        `set -a`, or by having been inherited -- so `cd /external; BEADS_DIR=
        /decoy/.beads; bd close X`, with no BEADS_DIR in the environment,
        writes /external's store while the decoy stays a shell variable `bd`
        never sees. And a name `unset` since is gone however it was set.
        Reading every assignment as exported named the decoy in the first
        case and the stale value in the second, stranding the store written.
        """
        caller = self.callers.get(id(cmd))
        if caller is not None and caller is not self.scope:
            return self.in_scope(caller, self.command_env, cmd, args, start,
                                 name)
        wrapper_assigns, sealed = self.prefix_env(args, start)
        if name in wrapper_assigns:
            return self.env_value(wrapper_assigns[name])
        # A cleared environment is a known one: the name is unset, and what
        # follows from that -- for `BEADS_DIR`, the walk up from the directory
        # -- can be read. Only an opaque wrapper leaves it in doubt. Reading
        # the two alike left `cd /external/repo && env -i bd close X`
        # unresolved, with the store the walk names unsynced and unregistered.
        if sealed is OPAQUE:
            return UNKNOWN
        if sealed is CLEARED:
            return None
        prefix = self.prefix_values(cmd)
        if name in prefix:
            return prefix[name]
        if name == "SHELLOPTS" and self.scope.bash is not False:
            # bash's own, which no word can spell; see `ShellOpts`.
            return None if self.is_exported(name) is False else UNKNOWN
        if name in self.scope.assigns:
            value = self.scope.assigns[name]
            if value is UNSET:
                return None
            exported = self.is_exported(name)
            if exported is UNKNOWN:
                return UNKNOWN
            if not exported:
                return None
            return UNKNOWN if isinstance(value, ShellOpts) else value
        exported = self.is_exported(name)
        if exported is UNKNOWN:
            return UNKNOWN
        if not exported:
            return None
        # The shell keeps its own PWD current as it moves, so the tracked cwd
        # answers for it, as in `get`; this process's PWD is some other
        # directory. So it does in a cleared environment, a shell having set
        # and exported PWD as it started; see `sub_scan`.
        if name == "PWD":
            return self.get("PWD")
        # Exported and not assigned by the text: the value is the inherited
        # one, where there was one to inherit. `export X` of a name that has
        # no value exports nothing.
        if self.scope.sealed is OPAQUE:
            return UNKNOWN
        if self.scope.sealed is CLEARED:
            return None
        return os.environ.get(name)

    @staticmethod
    def env_value(value):
        """A recorded environment value as `command_env` reports it.

        A name a wrapper unset is recorded as UNSET so that a word expanding it
        stays unknowable, as any unset name is to `get`; read as the
        environment, it is simply absent.
        """
        return None if value is UNSET else value

    def enter_cwd(self, path, spelled=True):
        """Moves this scope to `path`, as a `cd` that succeeded does.

        A successful `cd` overwrites the shell's PWD and OLDPWD, so an explicit
        assignment to either no longer speaks: `PWD=/decoy; cd /external; bd -C
        "$PWD" close X` writes /external's store. Left standing, the assignment
        won over the tracked cwd in `get` and named the decoy. `spelled` says
        whether `path` is also the PWD's spelling; see `Scope.spelled`.
        """
        self.scope.cwd = path
        self.scope.known = True
        self.scope.spelled = spelled
        self.scope.moved = True
        self.scope.assigns.pop("PWD", None)
        self.scope.assigns.pop("OLDPWD", None)

    def leave_cwd(self):
        """Records that this scope's cwd is no longer known, PWD with it."""
        self.scope.known = False
        self.scope.moved = True
        self.scope.assigns.pop("PWD", None)
        self.scope.assigns.pop("OLDPWD", None)

    def cd(self, args, start, conditional, follows, name="cd", cmd=None):
        """Replays a `cd` that certainly runs, and gives up on one that may not.

        `false && cd /tmp/other; bd -C store ...` does not run in /tmp/other.
        Applying every `cd` in the text regardless resolves the write to a
        directory the command never entered. Unknown beats guessed: a `cd` that
        may or may not have run leaves the cwd unknown, and a relative target
        under an unknown cwd is reported as unresolvable.

        `pushd dir` lands where `cd dir` would, and is read the same way. The
        forms that land on an entry of the directory stack -- a bare `pushd`, a
        rotation, `popd` -- leave the cwd unknown, since the stack is the
        shell's alone; `-n` on either changes the stack and not the cwd.
        """
        # A `cd` followed by `||` is the same case read the other way: what
        # comes after runs precisely when the `cd` failed, so applying it names
        # a directory the shell is in only on the branch that did not happen.
        # This gives up `cd /tmp/x || exit 1; bd -C store ...`, where the cwd is
        # in fact knowable -- reasoning about which commands abort the list is
        # the kind of inference this scanner exists to avoid.
        if conditional or follows == "||":
            self.leave_cwd()
            return
        i = start + 1
        physical = self.scope.physical
        if name != "cd":
            words = [arg.value for arg in args[i:]]
            if any(word is UNKNOWN for word in words):
                self.leave_cwd()
                return
            if "-n" in words:
                return
            words = [word for word in words if word != "--"]
            if name == "popd" or not words or DIR_STACK_ROTATE.match(words[0]):
                self.leave_cwd()
                return
            i = next(j for j in range(i, len(args)) if args[j].value != "--")
        else:
            while i < len(args):
                word = args[i].value
                if word is not UNKNOWN and word == "--":
                    i += 1
                    break
                if word is UNKNOWN or not CD_OPT.match(word):
                    break
                # The last of `-L` and `-P` wins, as in bash.
                for letter in word[1:]:
                    if letter in "LP":
                        physical = letter == "P"
                i += 1
        # `cd` with no operand goes to $HOME, and `cd -` to a directory only the
        # shell's history knows.
        if i >= len(args) or args[i].value == "-":
            self.leave_cwd()
            return
        cdpath = self.cd_path(cmd)
        dest = self.cd_landing(args[i], physical, cdpath)
        # bash from 4.4 collapses an inherited PWD by name as it starts and
        # resolves a relative `cd` from that, where bash 3.2 resolves it from
        # the PWD as given; see `wrapper_pwd`. The two differ where a `..` in
        # it follows a symlink -- with PWD=/ws/link/.. in /ext, `cd -P .`
        # stays in /ext in 3.2 and lands in /ws in 5, and so does `set -P;
        # CDPATH=.; cd sibling` -- and there the cwd is unknown.
        if self.scope.bash is not False and dest is not UNKNOWN and \
                self.scope.known:
            cwd = self.scope.cwd
            base = logical_path(cwd) or chdir_path(cwd)
            if base != cwd:
                moved = self.scope.child()
                moved.cwd = base
                if self.in_scope(moved, self.cd_landing, args[i], physical,
                                 cdpath) != dest:
                    dest = UNKNOWN
        # A path that is no directory now was none when a `cd` ran in the
        # foreground, the hook scanning after the command -- but a job in the
        # background may not have made it yet: `(mkdir -p /ext/new; cd
        # /ext/new; bd init) &` is scanned before the `mkdir` runs, and
        # staying put named the launch directory's store.
        if dest is None and self.background:
            dest = UNKNOWN
        if dest is UNKNOWN:
            self.leave_cwd()
            return
        if dest is None:
            return
        # The PWD a `cd` leaves is spelled when the shell knew the spelling it
        # started from, when the operand was absolute, or when `-P` made it
        # the physical path. A relative one from an unknown spelling extends
        # that spelling, whatever it was.
        spelled = True if physical is True or args[i].tilde or \
            args[i].value.startswith("/") else self.scope.spelled
        self.enter_cwd(dest, spelled)

    def cd_landing(self, field, physical, cdpath):
        """Where a `cd` to `field` lands from this scope, `cdpath` being the
        CDPATH it searches: the directory, None when it fails, or UNKNOWN.

        A `cd` that fails leaves the shell where it was, and the command after
        it runs there: `cd /missing; bd -C store ...` writes under the launch
        directory, not under /missing. The scan cannot know the exit status,
        but it can see that a path which is no directory now was no directory
        then either -- and where that is so, the honest answer is that the cwd
        is whatever it already was. A path that cannot be resolved at all
        leaves the cwd unknown.
        """
        target = self.cdpath_target(field, cdpath, physical)
        if target is None:
            target = self.resolve_field(field)
            if target is None:
                return UNKNOWN
        if target is UNKNOWN:
            return UNKNOWN
        return cd_dest(target, physical)

    def cd_path(self, cmd):
        """The CDPATH a `cd` searches: its value, None when unset, or UNKNOWN.

        bash, dash and ksh honour one in the `cd`'s own prefix, so
        `CDPATH=/ext cd repo` lands in /ext/repo, and `CDPATH= cd repo`
        searches nothing, whatever this shell's CDPATH says; reading this
        shell's alone named the store under the cwd's `repo`. zsh ignores the
        prefix.
        """
        if cmd is not None and not self.scope.zsh:
            prefix = self.prefix_values(cmd)
            if "CDPATH" in prefix:
                return prefix["CDPATH"]
        return self.shell_var("CDPATH")

    def cdpath_target(self, field, cdpath, physical=False):
        """Where `CDPATH` sends a `cd` to `field`, if it sends it anywhere.

        A relative operand that does not open with `.` or `..` is looked for
        under each entry of CDPATH before the cwd -- an empty entry or `.`
        being the cwd -- and the first the `cd` reaches wins, as `cd` in bash
        does it. With `CDPATH=/external`, `cd repo; bd close X` writes
        /external/repo's store, and resolving `repo` under the tracked cwd
        registered and pushed a different store with no warning.

        None when CDPATH does not apply or names nothing that exists, so the
        operand resolves against the cwd as before. UNKNOWN when it may send
        the shell somewhere this scan cannot see: a CDPATH it cannot read, or
        an entry it cannot resolve before the one that would have matched --
        among them one read from a cwd whose PWD spelling is unknown, which
        `cd` reads by name; see `resolve_value`. `cdpath` is the CDPATH
        searched; see `cd_path`.
        """
        value = field.value
        if value is UNKNOWN or not value or field.tilde:
            return None
        if value.startswith("/") or value == "." or value == ".." or \
                value.startswith("./") or value.startswith("../"):
            return None
        if cdpath is None:
            return None
        if cdpath is UNKNOWN:
            return UNKNOWN
        for entry in cdpath.split(":"):
            if entry.startswith("/"):
                base = entry
            elif not self.scope.known or self.scope.spelled is UNKNOWN or \
                    (not self.scope.spelled and
                     ".." in (entry + "/" + value).split("/")):
                return UNKNOWN
            elif entry in ("", "."):
                base = self.scope.cwd
            else:
                base = self.scope.cwd.rstrip("/") + "/" + entry
            candidate = base.rstrip("/") + "/" + value
            # Reached as the `cd` would reach it, in its mode: a logical one
            # reads `..` by name, so with `link` pointing at /ext/child,
            # `CDPATH=/ws/link/..` sends `cd repo` to /ws/repo where /ext/repo
            # does not exist, and testing the kernel's path skipped the entry
            # for the next. `physical` is the `cd`'s mode.
            dest = cd_dest(candidate, physical)
            if dest is UNKNOWN:
                return UNKNOWN
            if dest is not None:
                return candidate
        return None

    def unset_builtin(self, args, start, conditional):
        """Records what `unset` removes.

        `export BEADS_DIR=/a/.beads; unset BEADS_DIR; bd close X` runs `bd` with
        no BEADS_DIR, so it walks up from its directory; reading the export as
        still standing named /a, a store the command never opened. The name is
        recorded as unset, and as no longer exported: a later plain assignment
        to it makes a fresh shell variable, whatever attribute the old one had.

        `unset -f` removes functions, which the scan then no longer calls. A
        name this scan cannot read may be any name, so every value and every
        attribute is in doubt after it -- the scope is sealed opaque, as under
        a wrapper whose effect cannot be read. On a path the shell may not
        take, what was unset is unknown rather than gone.
        """
        functions = False
        names = []
        for arg in args[start + 1:]:
            word = arg.value
            if word is UNKNOWN:
                self.seal_opaque()
                return
            if word == "--":
                continue
            if word.startswith("-") and len(word) > 1:
                if "f" in word[1:]:
                    functions = True
                continue
            names.append(word)
        for name in names:
            if functions:
                self.functions.pop(name, None)
                self.export_function(name, False)
                continue
            # bash refuses to unset its readonly SHELLOPTS, which still
            # carries its options to a child; see `carried_option`.
            refused = self.scope.bash if name == "SHELLOPTS" else False
            if refused is True:
                continue
            self.unset_names.add(name)
            if conditional or refused is UNKNOWN:
                self.scope.assigns[name] = UNKNOWN
                self.scope.exported[name] = UNKNOWN
            else:
                self.scope.assigns[name] = UNSET
                self.scope.exported[name] = False

    def read_builtin(self, args, start, name):
        """Records what `read`, `mapfile` and `readarray` assign.

        Each names the variables it fills as operands, after options some of
        which take a value that is not a name: `read -p 'Store: ' OUT` fills
        OUT and not `Store: `. With no operand each fills a default. What is
        read is input this scan does not have, so the names are unknown after
        it rather than kept: `read OUT; bd -C "$OUT" close X` wrote wherever
        the input said, while the value from before it named another store.

        An operand this scan cannot read may be any name, so every name is in
        doubt after it, as after an `unset` it cannot read.
        """
        takes, defaults = READ_WORDS[name]
        names = []
        i = start + 1
        while i < len(args):
            word = args[i].value
            if word is UNKNOWN:
                self.seal_opaque()
                return
            if word == "--":
                i += 1
                break
            if not word.startswith("-") or word == "-":
                break
            letters = word[1:]
            i += 1
            for j, letter in enumerate(letters):
                if letter not in takes:
                    continue
                value = letters[j + 1:]
                if not value and i < len(args):
                    value = args[i].value
                    i += 1
                # `read -a NAME` fills an array, which is a name too.
                if letter == "a" and name == "read":
                    if value is UNKNOWN:
                        self.seal_opaque()
                        return
                    names.append(value)
                break
        for arg in args[i:]:
            word = arg.value
            if word is UNKNOWN:
                self.seal_opaque()
                return
            names.append(word)
        for each in names or defaults:
            if IDENTIFIER.match(each):
                self.forget(each)

    def printf_builtin(self, args, start):
        """Records what `printf -v` assigns.

        `printf -v OUT '%s' /external; bd -C "$OUT" close X` writes /external,
        and the formatted value is not read here, so OUT is unknown after it.
        The name may be attached to the flag or follow it, and `-v` may follow
        `--` only as a word to print.
        """
        i = start + 1
        while i < len(args):
            word = args[i].value
            if word is UNKNOWN:
                self.seal_opaque()
                return
            if word == "--" or not word.startswith("-") or word == "-":
                return
            if word.startswith("-v"):
                if len(word) > 2:
                    target = word[2:]
                elif i + 1 < len(args):
                    target = args[i + 1].value
                else:
                    return
                if target is UNKNOWN:
                    self.seal_opaque()
                elif IDENTIFIER.match(target.split("[", 1)[0]):
                    self.forget(target.split("[", 1)[0])
                return
            i += 1

    def set_builtin(self, args, start, conditional):
        """Records `set -a`/`+a`, `set -m`/`+m` and `set -P`/`+P`.

        Under `set -a` every assignment exports its name, so `set -a;
        BEADS_DIR=/x/.beads; bd close X` runs `bd` with that BEADS_DIR though
        nothing said `export`. `set -m` turns job control on, which switches
        `lastpipe` off again; see `Scope.last_member_stays`. `set -P` makes
        every later `cd` resolve symlinks before `..`; see `cd_dest`. Only
        those three are read; the rest of `set` says nothing about which store
        a command opens.
        """
        state = {}
        i = start + 1
        while i < len(args):
            word = args[i].value
            if word is UNKNOWN:
                state = {"a": UNKNOWN, "m": UNKNOWN, "P": UNKNOWN}
                i += 1
                continue
            if word == "--" or not (word.startswith("-") or
                                    word.startswith("+")):
                break
            # Read letter by letter, as bash does: each `o`, bundled or not,
            # takes the next word as an option's name, so `set -eo physical`
            # is `set -e -o physical`. Skipping the `o` read `physical` as the
            # first operand and stopped there.
            on = word.startswith("-")
            taken = 0
            for letter in word[1:]:
                if letter in "amP":
                    state[letter] = on
                elif letter == "o":
                    taken += 1
                    if i + taken >= len(args):
                        continue
                    option = args[i + taken].value
                    if option is UNKNOWN:
                        state = {"a": UNKNOWN, "m": UNKNOWN, "P": UNKNOWN}
                    elif option in SET_O_LETTERS:
                        state[SET_O_LETTERS[option]] = on
            i += 1 + taken
        if "a" in state:
            self.scope.allexport = UNKNOWN if conditional else state["a"]
        if "m" in state:
            self.scope.monitor = UNKNOWN if conditional else state["m"]
        if "P" in state:
            self.scope.physical = UNKNOWN if conditional else state["P"]

    def shopt_builtin(self, args, start, conditional):
        """Records `shopt -s lastpipe` and `shopt -u lastpipe`.

        Under `lastpipe` the last member of a pipeline runs in this shell, so
        `shopt -s lastpipe; true | cd /external; bd close X` writes
        /external's store where a scan that put every member in a subshell
        restored the old cwd. `-o` makes `shopt` a spelling of `set -o`, so
        `shopt -so allexport` is `set -a`, `shopt -so physical` is `set -P`
        and `shopt -so monitor` is `set -m`, which puts the last member of a
        pipeline back in a subshell. Without `-s` or `-u` the builtin only
        reports, and the rest of `shopt`'s options say nothing about which
        store a command opens.
        """
        setting = None
        set_o = False
        names = []
        i = start + 1
        while i < len(args):
            word = args[i].value
            if word is UNKNOWN:
                names.append(UNKNOWN)
                i += 1
                continue
            if word == "--":
                i += 1
                break
            if word.startswith("-") and len(word) > 1:
                if "s" in word[1:]:
                    setting = True
                if "u" in word[1:]:
                    setting = False
                if "o" in word[1:]:
                    set_o = True
                i += 1
                continue
            break
        while i < len(args):
            names.append(args[i].value)
            i += 1
        if UNKNOWN in names:
            # A word that cannot be read may have been the option, or the
            # flag that set it, so whatever it could have named is unknown.
            if set_o or "allexport" in names:
                self.scope.allexport = UNKNOWN
            if set_o or "physical" in names:
                self.scope.physical = UNKNOWN
            if set_o or "monitor" in names:
                self.scope.monitor = UNKNOWN
            if not set_o:
                self.scope.lastpipe = UNKNOWN
            return
        if setting is None:
            return
        value = UNKNOWN if conditional else setting
        if set_o:
            if "allexport" in names:
                self.scope.allexport = value
            if "physical" in names:
                self.scope.physical = value
            if "monitor" in names:
                self.scope.monitor = value
        elif "lastpipe" in names:
            self.scope.lastpipe = value

    def unreadable_script(self):
        """Records a script that runs and cannot be read.

        The fail-safe case for `bash -c`, `eval` and `env -S` alike: the shell
        runs that text whatever it says, and there is no way to learn whether
        it writes. Read as no write, `bash -c "$(gen)"` holding a `bd -C
        /external ...` left the roots unsynced as well as the store, and
        neither the marker retry nor SessionEnd could find it. It counts as a
        write, so the roots sync -- and as a target that could not be named,
        so the hook says a store may have gone unsynced: the text may carry a
        `-C` nothing later can rediscover, and counting the write alone synced
        the roots in silence.
        """
        self.mutates = True
        self.unresolved += 1

    def prefix_seed(self, cmd):
        """The assignments a command's temporary prefix gives a script it runs.

        A temporary prefix speaks for no word of this command's own argv, which
        the shell expanded before applying it -- but it does reach the child's
        environment, and the child expands its script with it in place. So
        `OUT=/tmp/store bash -c 'bd -C "$OUT" ...'` writes /tmp/store, while
        discarding the prefix read the hook's own inherited OUT and left that
        store out of both the push set and the registry.

        Seeded whatever the command's own reachability: the prefix is part of
        the command, so if the command runs at all it runs with it. Skipped on a
        conditional path, `t && OUT=/real bash -c 'bd -C "$OUT" ...'` was read
        against the value before it, a store the command never opened. The
        values are those `prefix_values` reads.
        """
        return self.prefix_values(cmd)

    def prefix_values(self, cmd):
        """The values a command's temporary prefix gives the names it assigns.

        Each is expanded in turn, and whether a later one sees an earlier one
        turns on the shell. dash, zsh and bash from 4.0 on make each before
        expanding the next, so `D=/old; D=/ext BEADS_DIR="$D/.beads" bd close
        X` writes /ext's store; the bash 3.2 macOS ships does that only in
        some places -- a subshell, an `if` -- and elsewhere expands them
        against the values from before the command. In bash, then, a value
        the two readings disagree on is UNKNOWN. The command's own words see
        none of them; see `call`.

        bash refuses a prefix assignment to its readonly SHELLOPTS and runs
        the command without it, the others standing, so `SHELLOPTS=physical
        bash -c ...` hands the child the SHELLOPTS this shell had. In `sh`,
        which may be bash or not, the value is UNKNOWN.
        """
        caller = self.callers.get(id(cmd))
        if caller is not None and caller is not self.scope:
            return self.in_scope(caller, self.prefix_values, cmd)
        values = {}
        bash = self.scope.bash
        for arg in cmd.get("Assigns") or ():
            if not gives_value(arg):
                continue
            name = arg["Name"]["Value"]
            if name == "SHELLOPTS" and bash is not False:
                if bash is UNKNOWN:
                    values[name] = UNKNOWN
                continue
            value = self.with_assigns(values, self.assign_value, arg)
            if bash is not False and values and \
                    value != self.assign_value(arg):
                value = UNKNOWN
            values[name] = value
        return values

    def with_assigns(self, values, fn, *args):
        """`fn(*args)` with `values` assigned over this scope, which is left
        as it was."""
        if not values:
            return fn(*args)
        saved = self.scope
        self.scope = saved.child()
        self.scope.assigns.update(values)
        try:
            return fn(*args)
        finally:
            self.scope = saved

    def in_scope(self, scope, fn, *args):
        """`fn(*args)` read with `scope` in force, this one being restored."""
        saved = self.scope
        self.scope = scope
        try:
            return fn(*args)
        finally:
            self.scope = saved

    def shell_wrapper(self, cmd, args, start):
        """Scans the `-c` operand of a shell as the script it is.

        A shell runs that operand as script, so the write inside it is a write
        by this command. It is scanned in a scope of its own: the wrapper is a
        separate process, and a `cd` or assignment it makes dies with it rather
        than reaching the command after it.
        """
        idx = self.shell_script(args, start)
        if idx is None:
            return
        script = args[idx].value
        if script is UNKNOWN:
            self.unreadable_script()
            return
        # The prefix's assignments are seeded into the child's scope only. A
        # wrapper's own assignments reach the child the same way, and were
        # stepped over rather than read while the command word was being found:
        # `env OUT=/tmp/store bash -c ...` is the syntactic prefix's twin.
        # Applied in the shell's order, the prefix first and the wrapper on top
        # of it -- so `OUT=/a env OUT=/b bash -c ...` sees /b, and a wrapper
        # that clears or filters the environment drops the prefix's value with
        # the rest, leaving the name as unknowable as any other it did not
        # carry. Seeding the prefix through `env -i` read a value the child
        # never had.
        wrapper_assigns, sealed = self.prefix_env(args, start)
        seed = {} if sealed else self.prefix_seed(cmd)
        seed.update(wrapper_assigns)
        # Physical mode is on when the shell's own options or its SHELLOPTS
        # turn it on. bash reads SHELLOPTS after its options, and SHELLOPTS
        # only turns options on, so `env SHELLOPTS=physical bash +P -c 'cd
        # /ws/link/..'` lands where the link points, as `bash -P` does
        # whatever SHELLOPTS says. A privileged shell ignores SHELLOPTS --
        # `env SHELLOPTS=physical bash -p -c ...` lands in /ws -- and whether
        # it is privileged is settled by the last of `-p`, `+p` and `-o
        # privileged` among its options.
        words = args[start + 1:idx]
        privileged = self.shell_option(words, "p", "privileged")
        inherited = {}
        for option in ("physical", "monitor", "posix"):
            state = self.shellopts_option(cmd, args, start, option)
            if privileged is True:
                state = False
            elif privileged is UNKNOWN and state is not False:
                state = UNKNOWN
            inherited[option] = state
        own = self.shell_option(words, "P", "physical")
        if inherited["physical"] is True or own is True:
            physical = True
        elif inherited["physical"] is False and own is False:
            physical = False
        else:
            physical = UNKNOWN
        # Job control comes on from SHELLOPTS the same way, a `+m` not
        # stopping it: `env SHELLOPTS=monitor bash -c 'setsid sleep 2; true'`
        # returns at once, the `setsid` forking; see `detaches`. `-m` and
        # `-i` only ask for it, and bash grants it only with a terminal to
        # control, which a command may or may not have, so either leaves it
        # in doubt.
        asked = self.shell_option(words, "m", "monitor")
        interactive = self.shell_option(words, "i", "interactive")
        if inherited["monitor"] is True:
            monitor = True
        elif inherited["monitor"] is False and asked is False and \
                interactive is False:
            monitor = False
        else:
            monitor = UNKNOWN
        startup = self.startup_runs(cmd, args, start, words, privileged,
                                    interactive, inherited["posix"])
        shell = args[start].value.rsplit("/", 1)[-1]
        leader = self.leader
        self.leader = self.leads(args, start)
        try:
            self.scan_script(script, seed=seed, sealed=sealed, process=True,
                             physical=physical, monitor=monitor, shell=shell,
                             pwd=self.shell_pwd(cmd, args, start),
                             startup=startup,
                             functions=self.imported_functions(
                                 shell, sealed, privileged, seed))
        finally:
            self.leader = leader

    def startup_runs(self, cmd, args, start, words, privileged, interactive,
                     inherited):
        """Whether the shell at `args[start]` may run a startup file before
        its `-c` script.

        bash does: a login shell its profile unless `--noprofile`, an
        interactive one its `.bashrc` unless `--norc`, and any other the file
        BASH_ENV names, unless privileged or in POSIX mode. So
        `BASH_ENV=/tmp/select-store.sh bash -c 'bd close X'` writes whatever
        store that file exports, and what it does is as unknown as a
        `source`d file's; see `sub_scan`. bash as `sh` reads none of them for
        a `-c` script, and other shells are not read for theirs.

        Each control is read as an option, where it stands as one and as the
        last word on it says: `bash --rcfile --posix -c ...` names a file
        `--posix` and reads BASH_ENV, as does `bash --posix +o posix -c ...`.
        `-o norc` and `-o noprofile` read as the long options too, which
        costs nothing: bash refuses both and runs nothing.

        An interactive shell in POSIX mode reads the file ENV names in place
        of `.bashrc`, `--norc` or not, unless privileged: `ENV=/tmp/s.sh bash
        --posix --norc -i -c ...` runs it. POSIXLY_CORRECT puts bash in that
        mode whatever a `+o posix` says, and so does `inherited`, a SHELLOPTS
        listing `posix` that a privileged shell has not ignored: `env
        SHELLOPTS=posix ENV=/tmp/s.sh bash --norc -i -c ...` runs the file,
        and `env SHELLOPTS=posix BASH_ENV=/tmp/s.sh bash -c ...` none.

        A wrapper may make it a login shell too, by the name it runs it
        under; see `argv0_login`.
        """
        if bash_kind(args[start].value) is not True:
            return False
        login = self.shell_option(words, "l", "login")
        if login is False:
            login = self.argv0_login(args, start)
        if login is not False and \
                self.shell_option(words, "", "noprofile") is not True:
            return True
        option = self.shell_option(words, "", "posix")
        variable = self.command_env(cmd, args, start, "POSIXLY_CORRECT")
        if variable is not None and variable is not UNKNOWN:
            variable = True
        elif variable is None:
            variable = False
        states = {option, variable, inherited}
        if True in states:
            posix = True
        elif UNKNOWN in states:
            posix = UNKNOWN
        else:
            posix = False
        if interactive is not False:
            if interactive is UNKNOWN:
                return True
            bashrc = self.shell_option(words, "", "norc") is not True
            env = self.command_env(cmd, args, start, "ENV")
            env = privileged is not True and (env is UNKNOWN or bool(env))
            if posix is UNKNOWN:
                return bashrc or env
            return env if posix else bashrc
        if privileged is True or posix is True:
            return False
        env = self.command_env(cmd, args, start, "BASH_ENV")
        # `sudo` removes BASH_ENV whatever its policy keeps, so behind one
        # only an assignment made after it can pass. Only a `sudo` among the
        # wrappers is one; see `wrapper_words`.
        assigned = self.prefix_env(args, start)[0]
        found = self.wrapper_words(args, start) or ()
        if env is UNKNOWN and "BASH_ENV" not in assigned and any(
                args[j].value.rsplit("/", 1)[-1] == "sudo" for j in found):
            return False
        return env is not None and env != ""

    def argv0_login(self, args, start):
        """Whether the wrapper that runs the shell at `args[start]` names it
        with a leading `-`, which makes bash a login shell: True, False or
        UNKNOWN.

        `exec -l` adds the `-`, and `exec -a NAME` and `env -a NAME` name
        it outright, so `exec -l bash -c ...` and `exec -a -bash bash -c
        ...` are login shells. Only the last wrapper counts, since each names
        only what it runs: `exec -l nohup bash -c ...` names `nohup`. Debian's
        bash reads its profile then even for a `-c` script, where the bash
        macOS ships does so only when interactive, so `startup_runs` takes
        such a shell for one that may.
        """
        found = self.wrapper_words(args, start)
        if not found:
            return False if found == [] else UNKNOWN
        i = found[-1]
        name = args[i].value.rsplit("/", 1)[-1]
        if name not in ("exec", "env"):
            return False
        takes, alone = WRAPPER_OPT_ARGS[name], WRAPPER_OPT_NOARG[name]
        dash, argv0 = False, None
        i += 1
        while i < start:
            word = args[i].value
            if word is UNKNOWN:
                if args[i].assign is not None:
                    break
                return UNKNOWN
            if word == "-" and name == "env":
                i += 1
                continue
            if word in ("-", "--") or not word.startswith("-"):
                break
            if word.startswith("--"):
                opt, sep, inline = word.partition("=")
                if opt == "--argv0":
                    argv0 = inline if sep else self.opt_value(args, i)
                i += 1 if sep or opt not in takes else 2
                continue
            bundle = short_opts(word, takes, alone)
            if bundle is None:
                return UNKNOWN
            letters, opt, inline = bundle
            dash = dash or (name == "exec" and "l" in letters)
            if opt == "-a":
                argv0 = inline if inline is not None else \
                    self.opt_value(args, i)
            i += 1 if opt is None or inline is not None else 2
        if dash or argv0 is UNKNOWN:
            return True if dash else UNKNOWN
        return argv0 is not None and argv0.startswith("-")

    def shellopts_option(self, cmd, args, start, option):
        """Whether the shell at `args[start]` starts with `option` on from the
        `SHELLOPTS` in its environment: True, False or UNKNOWN.

        bash turns on every option an inherited SHELLOPTS lists, so `env
        SHELLOPTS=physical bash -c 'cd /ws/link/..'` lands where the link
        points; see `env_option` for what the environment carries. Only bash
        reads it; `sh` is bash on some systems and not on others, so there the
        answer is in doubt, and the other shells ignore it.
        """
        kind = bash_kind(args[start].value)
        if kind is False:
            return False
        state = self.env_option(cmd, args, start, option)
        if state is not True:
            return state
        return True if kind is True else UNKNOWN

    def env_option(self, cmd, args, start, option):
        """Whether the environment the command at `args[start]` runs with
        carries a SHELLOPTS listing `option`: True, False or UNKNOWN.

        A wrapper that sets, unsets or clears the environment decides it, and
        then a prefix assignment, where the shell takes one; see
        `prefix_values`. Otherwise it is what this shell's own SHELLOPTS
        carries; see `carried_option`.
        """
        wrapper_assigns, sealed = self.prefix_env(args, start)
        if "SHELLOPTS" in wrapper_assigns:
            return opts_option(wrapper_assigns["SHELLOPTS"], option)
        if sealed is OPAQUE:
            return UNKNOWN
        if sealed is CLEARED:
            return False
        prefix = self.prefix_values(cmd)
        if "SHELLOPTS" in prefix:
            return opts_option(prefix["SHELLOPTS"], option)
        return self.carried_option(option)

    def carried_option(self, option):
        """Whether this shell's own SHELLOPTS hands a child `option`, physical
        mode, job control or POSIX mode: True, False or UNKNOWN.

        Only an exported one reaches a child. bash keeps its SHELLOPTS in step
        with its options, so that carries the option as it stands now: `export
        SHELLOPTS; set -P; bash -c ...` starts the child physical, and `export
        SHELLOPTS; set -m; bash -c ...` with job control, while a `set +P`
        before it starts the child logical whatever was inherited. Any other
        shell holds SHELLOPTS as the plain variable it inherited or was given,
        which its own options do not touch: `env SHELLOPTS=physical dash -c
        'bash -c ...'` starts that bash physical.
        """
        exported = self.is_exported("SHELLOPTS")
        if exported is not True:
            return exported
        answers = set()
        if self.scope.bash is not False:
            # This scan does not follow bash's own POSIX mode, which `set -o
            # posix` turns on and so does assigning POSIXLY_CORRECT, so what
            # its SHELLOPTS says of `posix` is in doubt.
            answers.add(UNKNOWN if option == "posix"
                        else getattr(self.scope, option))
        if self.scope.bash is not True:
            answers.add(opts_option(self.shell_var("SHELLOPTS"), option))
        return answers.pop() if len(answers) == 1 else UNKNOWN

    def shell_pwd(self, cmd, args, start):
        """The directory the shell at `args[start]` starts in, as the PWD it
        sets names it, and whether that spelling is known.

        A shell keeps an inherited PWD that names the directory it starts in
        and otherwise sets PWD from `getcwd`, the physical path: `cd /ws/link;
        env -i bash -c 'cd ..; ...'` lands in /ext, the cleared environment
        having carried no PWD. zsh also refuses one with a `.` or `..` in it.
        See `wrapper_pwd`, which reads it the same way.
        """
        cwd = self.scope.cwd
        if not self.scope.known or not os.path.isdir(cwd):
            return cwd, self.scope.spelled
        return self.wrapper_pwd(cmd, args, start, chdir_path(cwd),
                                posix=args[start].value.rsplit("/", 1)[-1]
                                == "zsh")

    def split_wrapper(self, cmd, args, start, split):
        """Scans what `env -S <string>` runs, the string naming the command.

        `env -S 'bd -C /tmp/store close CHR-1'` writes that store: `-S` splits
        its operand into the command and its arguments, so the words are inside
        the string and no argument of this invocation names them. Reading the
        string as an opaque option value found no command at all, and for an
        external target that is the worst outcome -- the roots sync, nothing
        looks wrong, and the store is never registered.

        The string is split as `env` splits it -- see `split_string_words` --
        and not read as shell text. A shell parse is not a superset of that
        splitting: `env -S 'bd\\_-C\\_/external\\_close\\_X'` runs `bd` with
        four arguments, where the parse saw one word that was not `bd` and
        the write was missed with no warning. The words `env` makes are its
        own arguments again -- `-S` on a shebang line is how a script passes
        `env` several -- so they are scanned as the argument list of an `env`
        carrying them, each quoted so that it stays one argument: an option
        or assignment among them is `env`'s, and the command word is found
        past them as for any `env`.

        `${NAME}` in the string is expanded by `env` from its own
        environment, which is this command's before `env` applies its own
        assignments and unsets on GNU and after on BSD. Where `env` itself
        touches the name the two disagree, so the word is unknowable; where
        it does not, the environment the command would see answers.

        The arguments after the string are the command's too. `env -S 'bd -C'
        /external close CHR-1` runs `bd -C /external close CHR-1`: `-S` splits
        the string and `env` appends what follows to the words it made. Scanning
        the string alone found `bd -C` with nothing after it, so the write was
        reported without its target -- the roots synced while the external store
        went unregistered, which nothing later can recover.

        A string `env` rejects -- an escape it does not know, a `$` not
        opening `${NAME}`, an unclosed quote -- runs nothing, as does one
        holding no word. A string that cannot be read at all is the fail-safe
        case, as it is for `eval`; see `unreadable_script`. An operand that
        cannot be read is the same case, the command's words being incomplete
        without it.
        """
        string, prefix_end = split
        if string is UNKNOWN:
            self.unreadable_script()
            return
        words = split_string_words(string)
        if words is None:
            return
        own_assigns, own_sealed = self.prefix_env(
            args[start:prefix_end], prefix_end - start)
        rendered = []
        for word in words:
            text = ""
            readable = True
            for part in word:
                if isinstance(part, str):
                    text += part
                    continue
                name = part[1]
                if own_sealed or name in own_assigns:
                    value = UNKNOWN
                else:
                    value = self.command_env(cmd, args, start, name)
                if value is UNKNOWN:
                    readable = False
                    break
                text += value or ""
            if readable:
                rendered.append(shlex.quote(text))
                continue
            # An assignment keeps its name when its value cannot be read:
            # `env -S 'OPTS=${SHELLOPTS} bd ...'` runs `bd`, and rendered
            # whole as an unreadable word the assignment was taken for the
            # command and the write missed; see `assignment_name`.
            name = ASSIGN_NAME.match(text)
            rendered.append((name.group(0) if name else "") + UNREADABLE_WORD)
        for arg in args[prefix_end:]:
            if arg.value is UNKNOWN:
                self.unreadable_script()
                return
            rendered.append(shlex.quote(arg.value))
        if not rendered:
            return
        # `env` changes directory once, to the last directory among all its
        # options -- the string's included -- read from where it started, as
        # GNU and BSD `env` both do: from /launch, `env -C /other -S '-C repo
        # bd close X'` runs in /launch/repo, where entering /other first named
        # /other/repo. So the one named before the string leads what the
        # string runs, and a later `-C` there replaces it.
        outer = self.wrapper_chdir(args[start:prefix_end], prefix_end - start)
        if outer is not None:
            rendered[:0] = ["-C", UNREADABLE_WORD if outer is UNKNOWN
                            else shlex.quote(outer)]
        # The assignments `env` was given before the string reach the command
        # the string names, and were stepped over rather than read while the
        # string was being found. Layered over the prefix as in
        # `shell_wrapper`, for the same reason.
        wrapper_assigns, sealed = self.prefix_env(args, prefix_end)
        seed = {} if sealed else self.prefix_seed(cmd)
        seed.update(wrapper_assigns)
        # `env` keeps the PWD it inherited whatever directory its `-C` moves
        # to, so what the string runs reads that and not the directory: after
        # `cd /ws/link; env -C /other -S 'env -C /ext/child bash -c ...'` the
        # inner shell keeps /ws/link, where answering PWD from this frame's
        # directory named /other.
        if "PWD" not in seed:
            pwd = self.command_env(cmd, args, prefix_end, "PWD")
            seed["PWD"] = UNSET if pwd is None else pwd
        # `env` is no shell, so SHELLOPTS in what it runs is the plain
        # variable its environment carries, and a bash started there reads
        # that: `export SHELLOPTS; set -P; env -S 'bash -c ...'` starts that
        # bash physical, as it would without the `-S`. What it runs keeps
        # the process group `env` was started in; see `leads`.
        leader = self.leader
        self.leader = self.leads(args, start)
        try:
            self.scan_script("env " + " ".join(rendered), seed=seed,
                             sealed=sealed, process=True, shell="env")
        finally:
            self.leader = leader

    def eval_builtin(self, cmd, args, start, conditional):
        """Scans what `eval` runs, which is script and not an argument list.

        `eval "bd -C /tmp/store close CHR-1"` writes that store. Reading the
        operand as an opaque word missed the write entirely -- the verb and the
        path were inside a string nothing was recognised to run -- and for an
        external target that is the worst outcome available: the roots sync,
        nothing looks wrong, and the store is never registered, so neither the
        marker retry nor SessionEnd can rediscover it.

        The operands are joined with a space, which is what `eval` itself does
        before parsing them, so `eval bd -C /tmp/store close CHR-1` is the same
        script as the quoted spelling.

        An operand this scan cannot read is the fail-safe case; see
        `unreadable_script`. A `-C` inside such a string is beyond recovery
        either way, which is why it is counted as one that could not be named.
        """
        parts = []
        i = start + 1
        if i < len(args) and args[i].value == "--":
            i += 1
        while i < len(args):
            word = args[i].value
            if word is UNKNOWN:
                self.unreadable_script()
                return
            parts.append(word)
            i += 1
        if not parts:
            return
        # Not a subshell: `eval` runs in the shell that called it, so the text
        # is expanded with this shell's state -- the cwd, the assignments, and
        # the command's own temporary prefix, which `eval` sees as `bash -c`
        # does: `OUT=/real eval 'bd -C "$OUT" ...'` writes /real, and scanning
        # the text without the prefix read the value from before it. What the
        # text changes may reach the command after it, but which branch of it
        # ran is the inference this scan declines to make, and whether the
        # prefix outlives the call turns on the shell's POSIX mode -- so the
        # frame is tentative: every name it touched is unknown afterwards, as
        # is the cwd, rather than restored or guessed.
        self.scan_script(" ".join(parts), seed=self.prefix_seed(cmd),
                         cwd=self.scope.cwd, known=self.scope.known,
                         conditional=conditional, frame="tentative")

    def scan_script(self, script, seed=None, sealed=False, cwd=None,
                    known=None, conditional=False, frame="subshell",
                    process=False, physical=False, monitor=False, shell=None,
                    pwd=None, startup=False, functions=None):
        """Scans `script` as shell text, in a scope of its own.

        The text is parsed afresh, so its offsets index it and not the command
        this scan started from -- which is why `sub_scan` is given it as `text`.

        A script already being scanned is refused. That, and not a depth cap, is
        what makes text containing itself terminate: `s='eval "$s"'` names the
        same text at every level, so the second sight of it adds nothing but
        depth. Bounding by depth instead meant a command nested legitimately deep
        was read as writing nothing.
        """
        if script in self.scripts:
            return
        self.spend(PARSE_STEPS)
        tree, parsed = parse(script)
        if tree is None:
            return
        self.scripts.add(script)
        try:
            self.sub_scan(tree.get("Stmts") or (), seed=seed, text=parsed,
                          sealed=sealed, cwd=cwd, known=known,
                          conditional=conditional, frame=frame,
                          process=process, physical=physical,
                          monitor=monitor, shell=shell, pwd=pwd,
                          startup=startup, functions=functions)
        finally:
            self.scripts.discard(script)


def scan(command, launch_cwd, unwaited=False):
    """What `command` writes, launched from `launch_cwd`.

    `launch_cwd` empty says the directory is unknown rather than being this
    process's own, so a relative target under it stays unresolved. The last of
    the four answers is the set of targets written in the background, where
    one with a leading `+` is a directory `bd` walks up from rather than a
    store; see `walk_from`. `unwaited` says the caller returned as the command
    started, so every write in it is one; see `in_background`.
    """
    tree, parsed = parse(command)
    scanner = Scanner(launch_cwd, parsed)
    if unwaited:
        scanner.background += 1
    if tree is not None:
        scanner.stmts(tree.get("Stmts") or (), conditional=False)
    return (scanner.mutates, scanner.unresolved, scanner.targets,
            scanner.async_targets)


def main():
    command = sys.stdin.read()
    launch_cwd = sys.argv[1] if len(sys.argv) > 1 else os.getcwd()
    unwaited = len(sys.argv) > 2 and sys.argv[2] == "unwaited"
    try:
        mutates, unresolved, targets, background = scan(command, launch_cwd,
                                                        unwaited)
    except Unavailable as err:
        # Nothing is written to stdout, so a caller reading the first field
        # cannot mistake a scan that did not happen for one that found no
        # write. The status says the same thing for a caller that checks it.
        sys.stderr.write("command_scan: %s\n" % err)
        return 2
    # Both counts come first and always, so the targets remain everything past
    # them and a caller need not tell a count from a path.
    out = ["1" if mutates else "0", str(unresolved)] + [
        "&" + path if path in background else path for path in targets]
    sys.stdout.write("\0".join(out) + "\0")
    return 0


if __name__ == "__main__":
    sys.exit(main())

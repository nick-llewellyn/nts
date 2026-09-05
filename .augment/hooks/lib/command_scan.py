#!/usr/bin/env python3
"""Decide whether a shell command writes to a bead store, and which store.

Invoked by lib/command-scan.sh, which keeps the bash-side contract the hook
and its test suite are written against. The command text arrives on stdin and
the answer leaves on stdout as NUL-terminated fields: the mutates flag first,
then the count of `-C` targets that were named and could not be resolved to a
path, then one store path per target found, in the order they were found. Both
counts come before the paths so the paths remain everything past them. NUL
rather than newline because a path may contain a newline and a target that has
been silently truncated names some other store.

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
                "nice", "setsid", "stdbuf"}

# The subset of the above that takes its own options and environment
# assignments before the command word, with the options that consume the word
# after them. Needed to find where a wrapper's arguments stop and its command
# begins: `sudo -u nick bd ...` runs bd, `env echo bd ...` runs echo, and
# telling them apart means knowing that `-u` takes `nick` while `echo` takes
# nothing. A wrapper with no such options still needs its entry, or it would
# fall through to the default.
WRAPPER_OPT_ARGS = {
    "env": {"-u", "--unset", "-C", "--chdir", "-S", "--split-string",
            "-a", "--argv0"},
    "sudo": {"-u", "--user", "-g", "--group", "-p", "--prompt",
             "-C", "--close-from", "-h", "--host", "-r", "--role",
             "-D", "--chdir"},
    "doas": {"-u", "-C", "-a"},
    "nice": {"-n"},
    "stdbuf": {"-i", "--input", "-o", "--output", "-e", "--error"},
    "exec": {"-a"},
    "command": set(), "nohup": set(), "setsid": set(),
}

# Options of those wrappers that stand alone. Without them every short flag
# the table above does not list is ambiguous, and an ambiguous flag abandons
# the whole invocation: `sudo -n bd close CHR-1` runs bd, and giving up on it
# misses the write itself, not merely its target.
#
# Only flags that certainly take nothing belong here. One whose argument is
# optional -- `env --block-signal[=SIG]` -- is left out on purpose: it is
# genuinely ambiguous, and the ambiguous path is the safe one. So are the
# lookup flags such as `command -v`, which print a path instead of running the
# command and so name no invocation to attribute a write to.
WRAPPER_OPT_NOARG = {
    "env": {"-i", "--ignore-environment", "-0", "--null", "-v", "--debug"},
    "sudo": {"-n", "--non-interactive", "-b", "--background", "-E",
             "--preserve-env", "-H", "--set-home", "-i", "--login", "-k",
             "--reset-timestamp", "-P", "--preserve-groups", "-S", "--stdin",
             "-s", "--shell", "-A", "--askpass"},
    "doas": {"-n", "-s", "-L"},
    "command": {"-p"},
    "setsid": {"-f", "--fork", "-w", "--wait", "-c", "--ctty"},
    "exec": {"-c", "-l"},
    "nice": set(), "nohup": set(), "stdbuf": set(),
}

# `exec -c` runs the command with an empty environment, which is what `env -i`
# does by another spelling: a name the command line does not carry is unset in
# the child however the hook's own environment answers it. Reading it as an
# ordinary value-less flag left `exec -c bd -C "$OUT/store" close X` resolving
# $OUT from the inherited value, naming a store the command never opened.
EXEC_CLEAR_OPTS = {"-c"}

# Shells that run their `-c` operand as script rather than running a command
# of their own. `bash -c 'bd -C /tmp/store close CHR-1'` writes that store,
# and reading `bash` as an ordinary command loses the write entirely --
# nothing else in the invocation says a store was touched, so SessionEnd
# builds its list without it and the write sits local indefinitely.
SHELL_WORDS = {"sh", "bash", "dash", "ksh", "mksh", "zsh"}

# Options of those shells that consume the word after them, and the short
# letters that certainly do not. The script is the first operand past the
# options, so the two must be told apart: `bash -o pipefail -c '...'` has its
# script two words later than `bash -x -c '...'` does. A letter in neither
# list is ambiguous, and an ambiguous one abandons the invocation rather than
# naming some other word as the script.
SHELL_OPT_ARGS = {"-o", "+o", "-O", "+O", "--rcfile", "--init-file"}
SHELL_NOARG_LETTERS = set("abcefhiklmnprstuvxBCEHPT")

# `bd`'s own global options that consume the word after them. The verb is the
# first operand that is not an option, so an option's value must be stepped
# over before it can be read: `bd --actor list close CHR-1` sets the actor to
# `list` and closes an issue, and taking `list` for the verb suppresses the
# write. Value-less globals -- `--json`, `--quiet` and the rest -- need no
# entry, since a lone `-flag` is skipped anyway.
BD_OPT_ARGS = {"-C", "--dir", "--directory", "--db", "--actor",
               "--dolt-auto-commit"}

BD_DIR_OPTS = ("-C", "--dir", "--directory")

# `bd`'s own short flags that take nothing, which its option parser lets stand
# in a bundle before one that does: `bd -qC/tmp/store close X` writes that
# store. Needed to read the attached form of `-C`, since the letters before it
# must be known to take nothing for the rest of the word to be its value.
BD_OPT_NOARG = {"-q", "-v", "-V"}

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
# however the hook's own environment answers it.
ENV_UNSET_OPTS = ("-u", "--unset")
ENV_CLEAR_OPTS = {"-i", "--ignore-environment"}

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

# `cd`'s own options say nothing about where it lands, so they are stepped
# over to find the operand.
CD_OPT = re.compile(r"^-[LPe@]")

# A word that is an assignment.
ASSIGN_WORD = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")

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


def word_parts(word, quoted=False):
    """The parts of `word`, each with whether quoting protects it.

    Double quotes group their contents rather than adding a part of their own,
    so they are flattened -- but which side of them a part sits on decides both
    what its backslashes mean and whether an expansion inside it is split, so
    the context travels with the part instead of being discarded.
    """
    for part in word.get("Parts") or ():
        if part["Type"] == "DblQuoted":
            for inner, _ in word_parts(part, True):
                yield inner, True
        else:
            yield part, quoted


# What splits an unquoted expansion when nothing has assigned IFS.
DEFAULT_IFS = " \t\n"


class Field:
    """One argument of a command, after expansion.

    `tilde` says the field began with an unquoted `~`, which names $HOME, and
    is true only of the first field a word produces.
    """

    __slots__ = ("value", "tilde")

    def __init__(self, value, tilde=False):
        self.value = value
        self.tilde = tilde


def split_fields(segments, separators):
    """The fields `segments` make, splitting only where splitting applies.

    Each segment is `(text, splittable)`. Splitting is a property of the text's
    origin rather than of the word, so it is resolved across the assembled
    segments rather than within each: `a$X` with X=` b` is two fields, since
    the separator the expansion supplied ends the field the literal began,
    while `"a$X"` is one.
    """
    fields = []
    current = None
    for text, splittable in segments:
        if not splittable:
            current = (current or "") + text
            continue
        for char in text:
            if char in separators:
                if current is not None:
                    fields.append(current)
                    current = None
            else:
                current = (current or "") + char
    if current is not None:
        fields.append(current)
    return fields


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
    """
    if not start.startswith("/"):
        return None
    path = os.path.normpath(start)
    while True:
        if os.path.isdir(os.path.join(path, ".beads")):
            return path
        parent = os.path.dirname(path)
        if parent == path:
            return None
        path = parent


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
    `A=(1 2)` is an array; `A[2]=x` sets one element of one; and `X+=`, having
    nothing to append, leaves the value it had.
    """
    if not arg.get("Name") or arg.get("Naked"):
        return False
    if arg.get("Array") or arg.get("Index"):
        return False
    return bool(arg.get("Value")) or not arg.get("Append")


class Scope:
    """The shell state a subshell inherits and may change without effect.

    A subshell -- `( )`, a substitution, a pipeline member, a backgrounded
    command, a shell wrapper's script -- gets the cwd and assignments in force
    and its changes die with it, so a frame is entered around it and dropped
    after. Writes found inside stay in the result, which is a finding about the
    command rather than state of the shell running it.
    """

    def __init__(self, cwd, known, assigns, sealed=False):
        self.cwd = cwd
        self.known = known
        self.assigns = assigns
        # Whether this scope's environment was replaced rather than added to, as
        # `env -i` does. A name not assigned here is then unset rather than
        # inherited, so the hook's own environment must not answer for it.
        self.sealed = sealed

    def child(self):
        return Scope(self.cwd, self.known, dict(self.assigns), self.sealed)


class Scanner:
    """Walks a command's syntax tree and records the stores it writes."""

    def __init__(self, launch_cwd, text=""):
        self.mutates = False
        self.targets = []
        # How many `-C` targets were named and could not be resolved to a path.
        # Reported separately from the targets themselves because it is the one
        # thing a later invocation cannot rediscover: the roots sync, but the
        # store named here is not among them and nothing else names its path.
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
        self.scope = Scope(launch_cwd, bool(launch_cwd), {})
        self.depth = 0
        # Bodies of the functions defined so far, by name, and the names whose
        # bodies are being scanned right now. A body is scanned twice -- once
        # where it is defined and once at each call -- so the same store can be
        # named more than once; a repeated target is dropped rather than
        # reported twice, since a caller would sync it twice for no purpose.
        self.functions = {}
        self.calling = set()
        # The scripts being scanned right now, by their text. What makes text
        # that contains itself terminate: `s='eval "$s"'` names the same script
        # at every level, so the second sight of it is refused. Held by text
        # rather than counted, since the count cannot tell that case from a
        # command legitimately nested deep.
        self.scripts = set()

    def found_target(self, path):
        if path not in self.targets:
            self.targets.append(path)

    # --- assignment state -------------------------------------------------

    def get(self, name):
        """The value of `name` here, or UNKNOWN when nothing names it.

        An assignment the text made wins, and otherwise the environment the
        hook runs with, which is the environment the tool call was launched
        with. Nothing is executed to answer this: a `launch-process` command is
        its own shell, so a variable it uses is either assigned in the same
        text -- which the walk has recorded, in order -- or inherited.
        """
        if name in self.scope.assigns:
            return self.scope.assigns[name]
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
            return self.scope.cwd if self.scope.known else UNKNOWN
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
        """
        if "IFS" in self.scope.assigns:
            got = self.scope.assigns["IFS"]
            return UNKNOWN if got is UNKNOWN else set(got)
        return set(DEFAULT_IFS)

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
        for part, quoted in word_parts(word):
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
                segments.append((part.get("Value", ""), False))
            elif kind == "ParamExp":
                # Only a plain reference is answered. An expansion with an
                # operator -- `${X:-/d}`, `${X#p}` -- names a value that
                # depends on more than the variable, and guessing it names
                # some other store.
                if part.get("Exp") or part.get("Slice") or part.get("Repl"):
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
        fields = split_fields(segments, separators)
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
                out.append(Field(UNKNOWN))
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
            if not self.scope.known:
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
            if name in WRAPPER_ENV_WORDS:
                split = self.split_string(args, i)
                if split is not None:
                    return i, split
            nxt = self.skip_wrapper_opts(args, i, name)
            if nxt is None:
                return None, None
            i = nxt
        return None, None

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
            # bundle holding a letter that may take a value is left to
            # `skip_wrapper_opts`, which gives up on it as before.
            letters = word[1:]
            if "S" not in letters:
                i += 2 if word in WRAPPER_OPT_ARGS["env"] else 1
                continue
            head, _, rest = letters.partition("S")
            if not all("-" + ch in WRAPPER_OPT_NOARG["env"] for ch in head):
                return None
            if rest:
                return rest, i + 1
            return self.opt_value(args, i), i + 2
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
        """
        takes = WRAPPER_OPT_ARGS[wrapper]
        alone = WRAPPER_OPT_NOARG[wrapper]
        i = start + 1
        while i < len(args):
            word = args[i].value
            if word is UNKNOWN:
                return i
            if word == "--":
                return i + 1
            if not word.startswith("-"):
                # An assignment among a wrapper's arguments, as `env FOO=bar
                # cmd`, is neither an option nor the command word.
                if ASSIGN_WORD.match(word):
                    i += 1
                    continue
                return i
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

        Each is applied in turn, and a relative one against the directory in
        force before it, since that is what the chain of `chdir` calls does.

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
            while i < start:
                word = args[i].value
                if word is UNKNOWN:
                    i += 1
                    continue
                if word == "--":
                    i += 1
                    break
                if not word.startswith("-"):
                    if not ASSIGN_WORD.match(word):
                        break
                    i += 1
                    continue
                if word.startswith("--"):
                    opt, sep, inline = word.partition("=")
                    if opt in opts:
                        cwd = self.chdir_to(cwd, Field(inline) if sep
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
                    cwd = self.chdir_to(cwd, Field(inline)
                                        if inline is not None
                                        else self.opt_field(args, i))
                i += 1 if opt is None or inline is not None else 2
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

    def chdir_to(self, cwd, field):
        """`field` as the directory in force after changing to it from `cwd`.

        UNKNOWN once it is unknown, since a relative directory after an
        unreadable one is unreadable too.
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
        return value

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

    def prefix_env(self, args, start):
        """The environment the wrappers in `args[:start]` give the command.

        Returns `(assigns, sealed)`. `env OUT=/tmp/store bash -c 'bd -C "$OUT"
        ...'` writes /tmp/store, and a prefix read only for where the command
        word is left `$OUT` to be answered by the hook's own environment --
        naming some other store, or none, and leaving the one that was written
        unregistered.

        `sealed` says a name this does not carry is unset in the child rather
        than inherited. That is what `env -i` does, and it is also the answer for
        a prefix whose effect on the environment cannot be read: `sudo` and
        `doas` decide what passes by a policy on disk, and a word this scan
        cannot resolve may be an assignment or an unset. Sealing reports those
        names unknowable while leaving the write itself found, which is what
        matters -- the roots still sync, and only the `-C` target is in doubt.
        """
        assigns = {}
        sealed = False
        i = 0
        while i < start:
            word = args[i].value
            if word is UNKNOWN:
                sealed = True
                i += 1
                continue
            name = word.rsplit("/", 1)[-1]
            if name in WRAPPER_ENV_UNREADABLE:
                sealed = True
                i += 1
                continue
            # `exec -c` clears the environment as `env -i` does, so a name the
            # command line does not carry is unset in the child. It takes no
            # assignments of its own, so the flag is all there is to read.
            if name == "exec":
                if self.exec_clears(args, i, start):
                    sealed = True
                i += 1
                continue
            if name not in WRAPPER_ENV_WORDS:
                i += 1
                continue
            i += 1
            while i < start:
                word = args[i].value
                if word is UNKNOWN:
                    sealed = True
                    i += 1
                    continue
                if word == "--":
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
                    sealed = True
                    i += 1
                    continue
                opt, sep, inline = word.partition("=")
                if opt in ENV_UNSET_OPTS:
                    if sep:
                        assigns[inline] = UNKNOWN
                        i += 1
                    elif i + 1 < start:
                        nxt = args[i + 1].value
                        if nxt is UNKNOWN:
                            # Which name was unset is itself unreadable, so
                            # every name is in doubt.
                            sealed = True
                        else:
                            assigns[nxt] = UNKNOWN
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
                        sealed = True
                        i += 1
                        continue
                    letters, bopt, binline = bundle
                    if any("-" + ch in ENV_CLEAR_OPTS for ch in letters):
                        sealed = True
                    if bopt in ENV_UNSET_OPTS:
                        if binline is not None:
                            assigns[binline] = UNKNOWN
                        elif i + 1 < start:
                            nxt = args[i + 1].value
                            if nxt is UNKNOWN:
                                sealed = True
                            else:
                                assigns[nxt] = UNKNOWN
                    i += 1 if bopt is None or binline is not None else 2
                    continue
                if opt in WRAPPER_OPT_ARGS["env"] and not sep:
                    i += 2
                    continue
                i += 1
        return assigns, sealed

    def bd_operands(self, args, start):
        """What the `bd` at `args[start]` says: operands, `-C` target, help.

        The target comes back as a `Field`, since both `-C dir` and `-C=dir`
        name one and only the first carries its own argument -- and only an
        argument of its own can have begun with a tilde.

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
        """
        operands = []
        target = None
        helped = False
        i = start + 1
        end_of_opts = False
        # Whether the word before this one was an option whose arity this scan
        # does not know, which makes this word possibly its value rather than
        # an option of `bd`'s own. Only the help reading turns on it: `bd
        # update CHR-1 --title --help` sets the title to `--help` and writes
        # the store, and reading that token as a help request suppressed the
        # sync. The target and operand readings are left as they were, since a
        # word skipped as a supposed value is a `-C` that goes unseen, and a
        # write whose target is lost is the one outcome worse than a no-op.
        may_be_value = False
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
                    and word in ("-h", "--help"):
                helped = True
                i += 1
                continue
            if not end_of_opts and word.startswith("--"):
                name, sep, inline = word.partition("=")
                if sep:
                    # `--opt=value` carries its value, so nothing follows it.
                    if name in BD_DIR_OPTS and target is None:
                        target = Field(inline)
                elif name in BD_OPT_ARGS:
                    if name in BD_DIR_OPTS and target is None and \
                            i + 1 < len(args):
                        target = args[i + 1]
                    i += 1
                else:
                    # A long flag neither table knows may still take the word
                    # after it -- every per-verb option is one, `--title`
                    # among them -- so what follows is not certainly an option.
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
                if "h" in letters and not after_unknown_opt:
                    helped = True
                if opt is None:
                    i += 1
                    continue
                if opt in BD_DIR_OPTS and target is None:
                    if inline is not None:
                        # `bd -C=/tmp/store` opens /tmp/store: `bd`'s option
                        # parser drops one leading `=` from a value attached to
                        # a short flag. Kept, the path resolved below the launch
                        # directory and named no store that exists.
                        target = Field(inline[1:] if inline.startswith("=")
                                       else inline)
                    elif i + 1 < len(args):
                        target = args[i + 1]
                i += 1 if inline is not None else 2
                continue
            operands.append(word)
            i += 1
        return operands, target, helped

    @staticmethod
    def readonly(operands, helped):
        """Whether a `bd` invocation with these operands only reads.

        The verb is compared whole, so `bd list-add` is not read as `bd list`
        followed by a boundary -- the one direction this must never fail in,
        since a verb wrongly judged read-only strands the write it describes.

        An operand this scan cannot read matches no entry of either table, so an
        invocation whose verb is unknowable is treated as a write. That is the
        same direction: the cost is a no-op commit, against a stranded one.
        """
        if helped:
            return True
        if not operands:
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
        """
        seen_c = False
        i = start + 1
        while i < len(args):
            word = args[i].value
            if word is UNKNOWN:
                return i if seen_c else None
            if word == "--":
                i += 1
                break
            if not (word.startswith("-") or word.startswith("+")):
                break
            if word in SHELL_OPT_ARGS:
                i += 2
                continue
            for ch in word[1:]:
                if ch not in SHELL_NOARG_LETTERS:
                    return None
                if ch == "c":
                    seen_c = True
            i += 1
        if not seen_c or i >= len(args):
            return None
        return i

    # --- the walk ---------------------------------------------------------

    def scoped(self, fn):
        """Runs `fn` in a frame of its own, as a subshell of this scope."""
        saved = self.scope
        self.scope = saved.child()
        try:
            fn()
        finally:
            self.scope = saved

    def sub_scan(self, stmts, cwd=None, known=None, seed=None, text=None,
                 sealed=False):
        """Scans `stmts` as a subshell: its writes count, its state does not.

        `text` is the source those statements were parsed from, needed when they
        came from a parse of their own -- a `bash -c` operand -- since their
        offsets index that string and not the command this scan started with.

        `sealed` says the child's environment was replaced rather than inherited,
        as under `env -i`, so a name `seed` does not carry is unset there.
        """
        # Exhausting the depth is this scan failing, not the command writing
        # nothing, so it is raised rather than returned. Returning quietly is
        # what made a `bd` nested past the old cap of 4 read as read-only.
        if self.depth >= MAX_DEPTH:
            raise Unavailable("nesting deeper than %d" % MAX_DEPTH)

        def run():
            if cwd is not None:
                self.scope.cwd = cwd
            if known is not None:
                self.scope.known = known
            if sealed:
                self.scope.sealed = True
            if seed:
                self.scope.assigns.update(seed)
            outer = self.text
            outer_raw = self.raw
            if text is not None:
                self.text = text
                self.raw = text.encode("utf-8")
            self.depth += 1
            try:
                self.stmts(stmts, conditional=False)
            finally:
                self.depth -= 1
                self.text = outer
                self.raw = outer_raw

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
            if node.get("Type") in ("CmdSubst", "ProcSubst"):
                self.sub_scan(node.get("Stmts") or ())
                return
            for value in node.values():
                self.node_subs(value)
        elif isinstance(node, list):
            for item in node:
                self.node_subs(item)

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
        # Every command of a pipeline runs in a subshell, as does one
        # backgrounded with `&`: `cd /tmp/other & bd -C store ...` leaves the
        # real shell where it was, and resolving the write under /tmp/other
        # names a store the command never opened.
        if stmt.get("Background"):
            self.scoped(lambda: self.body(stmt, conditional, follows))
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
                # /tmp/other names a store the command never opened.
                self.scoped(lambda: self.stmt(cmd["X"], conditional))
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
            # A brace group runs in this shell, and its `cd` does reach the
            # command after it -- but the commands in one are not always
            # certain to run, and the group is scanned in a frame so what it
            # changes does not leak. This gives up the certain case to keep the
            # conditional one, leaving the cwd unknown rather than guessed.
            def block():
                self.stmts(cmd.get("Stmts"), conditional)
            self.scoped(block)
            self.scope.known = False
        elif kind == "IfClause":
            self.if_clause(cmd)
        elif kind == "WhileClause":
            self.branch(cmd.get("Cond"))
            self.branch(cmd.get("Do"))
        elif kind == "ForClause":
            loop = cmd.get("Loop") or {}
            for item in loop.get("Items") or ():
                self.word_subs(item)
            self.branch(cmd.get("Do"))
        elif kind == "CaseClause":
            if cmd.get("Word"):
                self.word_subs(cmd["Word"])
            for item in cmd.get("Items") or ():
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
            # substitutions and miss the write itself.
            if cmd.get("Stmt"):
                self.scoped(lambda: self.stmt(cmd["Stmt"], conditional))
        elif kind == "DeclClause":
            self.decl(cmd, conditional)
        elif kind == "TestClause":
            # `[[ ]]` runs no command and writes no store, but a substitution
            # inside one still runs.
            self.walk_words(cmd)
        elif kind in ("LetClause", "ArithmCmd"):
            self.walk_words(cmd)

    def branch(self, stmts):
        """Scans statements that may or may not run.

        Their writes count -- a `bd` inside a loop is a write if the loop runs
        once -- but what they change must not speak for the commands after
        them, and neither must the cwd they left behind.
        """
        if not stmts:
            return
        self.scoped(lambda: self.stmts(stmts, True))
        self.scope.known = False

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
        # resolved from.
        if cmd.get("Name"):
            self.functions[cmd["Name"]["Value"]] = body

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
            self.stmt(body)

        self.scoped(run)

    def call_function(self, name):
        """Scans the body of `name` as it runs here, in the caller's directory.

        This is what makes `f() { bd -C store ...; }; cd /x; f` name /x/store.
        The definition alone cannot: it does not say where its caller stands, so
        scanning it in place leaves a relative target unresolvable. At the call
        the cwd is known, and the body is the same text.

        Recursion is refused rather than bounded by depth, since a function that
        calls itself names no further store on the second pass. That is the whole
        termination argument here: a body already being scanned is not scanned
        again, so a chain of calls is at most as long as there are definitions.
        """
        if name in self.calling:
            return
        body = self.functions[name]
        self.calling.add(name)
        self.depth += 1
        try:
            # A call is not a subshell: a `cd` inside a function does reach the
            # command after the call. But whether the body ran to the end, and
            # which of its branches it took, is exactly what the scan declines
            # to infer -- so the frame is dropped and the cwd after it is
            # unknown, as it is after any compound command.
            self.scoped(lambda: self.stmt(body))
            self.scope.known = False
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
        # One the shell may never reach must not speak for the value in effect
        # when it does not.
        if conditional:
            return
        for arg in cmd.get("Args") or ():
            # Only the operands that are assignments count. `export OUT`
            # exports a name without changing its value, and a flag such as
            # `declare -x` is neither.
            if not gives_value(arg):
                continue
            self.assign(arg["Name"]["Value"], arg.get("Value"))

    def assign(self, name, word):
        """Records `name` as holding the value of `word` in this scope.

        `word` is None for `X=`, whose value is the empty string.
        """
        if word is not None:
            self.word_subs(word)
        self.scope.assigns[name] = self.assigned_value(word)

    def call(self, cmd, conditional, follows):
        """Handles one simple command.

        Records its assignments, replays a `cd` that certainly runs, and reports
        a `bd` write with the store it addresses.
        """
        assigns = cmd.get("Assigns") or ()
        args = cmd.get("Args") or ()

        # A substitution runs before the command whose word carries it, and
        # runs whatever the command's own reachability is, so every word is
        # visited for them first, prefix assignments included.
        for arg in assigns:
            if arg.get("Value"):
                self.word_subs(arg["Value"])
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
            if not conditional:
                for arg in assigns:
                    if gives_value(arg):
                        self.assign(arg["Name"]["Value"], arg.get("Value"))
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
        end = split[1] if split is not None else start
        cwd = None if end is None else self.wrapper_chdir(fields, end)
        if cwd is not None:
            self.scoped(lambda: self.dispatch(cmd, fields, start, split,
                                              conditional, follows, cwd))
            return
        self.dispatch(cmd, fields, start, split, conditional, follows, None)

    def dispatch(self, cmd, fields, start, split, conditional, follows, cwd):
        """Hands the command at `fields[start]` to the reader that knows it.

        `cwd` is the directory a wrapper runs it in, or None when it runs here.
        Applied to this frame rather than passed on, so every reader below --
        and every scope nested inside them -- resolves against it.
        """
        if cwd is not None:
            if cwd is UNKNOWN:
                # A directory named and unreadable leaves the store unknowable
                # rather than the launch directory's: `bd` runs where the wrapper
                # put it, and the walk up from here would name a store the
                # command never opened.
                self.scope.known = False
            else:
                self.scope.cwd = cwd
                self.scope.known = True

        if split is not None:
            self.split_wrapper(cmd, fields, start, split, conditional)
            return
        if start is None or start >= len(fields):
            return
        word = fields[start].value
        if word is UNKNOWN:
            return
        name = word.rsplit("/", 1)[-1]

        if name == "cd":
            self.cd(fields, start, conditional, follows)
            return

        if name in SHELL_WORDS:
            self.shell_wrapper(cmd, fields, start, conditional)
            return

        if name == "eval":
            self.eval_builtin(fields, start)
            return

        # A call runs the body defined earlier in this text, and runs it here,
        # where the cwd is known. Without this a relative store named inside a
        # function was reported by nothing: the definition cannot resolve it and
        # the call did not look.
        if word in self.functions:
            self.call_function(word)
            return

        if name != "bd":
            return

        operands, target, helped = self.bd_operands(fields, start)
        if self.readonly(operands, helped):
            return
        self.mutates = True

        # A store outside every workspace root is one no later event would
        # revisit: SessionEnd builds its list the same way, so that write would
        # sit local indefinitely. Which store this invocation opens is therefore
        # reported for every mutating `bd`, not only for one carrying `-C`.
        if target is None:
            # Without `-C`, `bd` selects its store by walking up from the
            # directory it runs in -- so `cd /other/repo && bd close X` writes
            # /other/repo/.beads, a store this reported nothing about. Reading a
            # missing `-C` as "some workspace root" was true of the common case
            # and silently wrong of that one.
            #
            # BEADS_DIR names the store outright, and only when no `-C` overrides
            # it. It points at the `.beads` directory itself, where every other
            # path here names the root holding one.
            named = self.command_env(cmd, fields, start, "BEADS_DIR")
            if named is None:
                named = ""
            elif named is UNKNOWN:
                # A BEADS_DIR this scan cannot read may name any store, so the
                # walk-up below would be a guess rather than an answer -- and
                # would name the store the walk finds while the write went to
                # the one BEADS_DIR pointed at.
                self.unresolved += 1
                return
            if named:
                resolved = self.resolve_value(named, False)
                if resolved:
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
                    self.unresolved += 1
                return
            if not self.scope.known:
                self.unresolved += 1
                return
            # No ancestor holding a store is no store to sync: `bd` itself fails
            # there, so there is nothing stranded and nothing to report.
            root = bead_root(self.scope.cwd)
            if root is not None:
                self.found_target(root)
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
        if os.path.isdir(resolved):
            resolved = bead_root(resolved) or resolved
        self.found_target(resolved)

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
        """
        for arg in cmd.get("Assigns") or ():
            if gives_value(arg) and arg["Name"]["Value"] == name:
                return self.assigned_value(arg.get("Value"))
        wrapper_assigns, sealed = self.prefix_env(args, start)
        if name in wrapper_assigns:
            return wrapper_assigns[name]
        if sealed:
            return UNKNOWN
        if name not in self.scope.assigns and name not in os.environ:
            return None
        return self.get(name)

    def cd(self, args, start, conditional, follows):
        """Replays a `cd` that certainly runs, and gives up on one that may not.

        `false && cd /tmp/other; bd -C store ...` does not run in /tmp/other.
        Applying every `cd` in the text regardless resolves the write to a
        directory the command never entered. Unknown beats guessed: a `cd` that
        may or may not have run leaves the cwd unknown, and a relative target
        under an unknown cwd is reported as unresolvable.
        """
        # A `cd` followed by `||` is the same case read the other way: what
        # comes after runs precisely when the `cd` failed, so applying it names
        # a directory the shell is in only on the branch that did not happen.
        # This gives up `cd /tmp/x || exit 1; bd -C store ...`, where the cwd is
        # in fact knowable -- reasoning about which commands abort the list is
        # the kind of inference this scanner exists to avoid.
        if conditional or follows == "||":
            self.scope.known = False
            return
        i = start + 1
        while i < len(args):
            word = args[i].value
            if word is not UNKNOWN and word == "--":
                i += 1
                break
            if word is UNKNOWN or not CD_OPT.match(word):
                break
            i += 1
        # `cd` with no operand goes to $HOME, and `cd -` to a directory only the
        # shell's history knows.
        if i >= len(args) or args[i].value == "-":
            self.scope.known = False
            return
        target = self.resolve_field(args[i])
        # A `cd` that fails leaves the shell where it was, and the command after
        # it runs there: `cd /missing; bd -C store ...` writes under the launch
        # directory, not under /missing. The scan cannot know the exit status,
        # but it can see that a path which is no directory now was no directory
        # then either -- and where that is so, the honest answer is that the cwd
        # is whatever it already was. A path that cannot be resolved at all
        # leaves the cwd unknown, as before.
        if target is None:
            self.scope.known = False
        elif os.path.isdir(target):
            self.scope.cwd = target
            self.scope.known = True

    def shell_wrapper(self, cmd, args, start, conditional):
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
            # The fail-safe case, as it is for `eval` and for `env -S`: the
            # shell runs that text whatever it says, and there is no way to
            # learn whether it writes. Read as no write, `bash -c "$(gen)"`
            # holding a `bd -C /external ...` left the roots unsynced as well
            # as the store, and neither the marker retry nor SessionEnd could
            # find it. It counts as a write with no target instead, so the
            # roots sync -- the answer every other unreadable write gets.
            self.mutates = True
            return
        # A temporary prefix speaks for no word of this command's own argv,
        # which the shell expanded before applying it -- but it does reach the
        # child's environment, and the child expands its script with it in
        # place. So `OUT=/tmp/store bash -c 'bd -C "$OUT" ...'` writes
        # /tmp/store, while discarding the prefix read the hook's own inherited
        # OUT and left that store out of both the push set and the registry.
        # The assignments are seeded into the child's scope only.
        seed = {}
        if not conditional:
            for arg in cmd.get("Assigns") or ():
                if gives_value(arg):
                    seed[arg["Name"]["Value"]] = \
                        self.assigned_value(arg.get("Value"))
        # A wrapper's own assignments reach the child the same way, and were
        # stepped over rather than read while the command word was being found:
        # `env OUT=/tmp/store bash -c ...` is the syntactic prefix's twin.
        wrapper_assigns, sealed = self.prefix_env(args, start)
        seed.update(wrapper_assigns)
        self.scan_script(script, seed=seed, sealed=sealed)

    def split_wrapper(self, cmd, args, start, split, conditional):
        """Scans what `env -S <string>` runs, the string naming the command.

        `env -S 'bd -C /tmp/store close CHR-1'` writes that store: `-S` splits
        its operand into the command and its arguments, so the words are inside
        the string and no argument of this invocation names them. Reading the
        string as an opaque option value found no command at all, and for an
        external target that is the worst outcome -- the roots sync, nothing
        looks wrong, and the store is never registered.

        The string is scanned as script, which is a superset of the splitting
        `env` itself does: what it can add is a write this scan reports where
        `env` would have passed the text along as one argument, and reporting a
        write that did not happen costs a no-op commit.

        The arguments after the string are the command's too. `env -S 'bd -C'
        /external close CHR-1` runs `bd -C /external close CHR-1`: `-S` splits
        the string and `env` appends what follows to the words it made. Scanning
        the string alone found `bd -C` with nothing after it, so the write was
        reported without its target -- the roots synced while the external store
        went unregistered, which nothing later can recover.

        They are appended quoted, since they are argv words and not script: an
        operand holding a `;` or a `$(` is one argument to the command, and
        splicing it in raw would make it syntax of the text being scanned.

        A string that cannot be read is the fail-safe case, as it is for `eval`:
        the text may write and there is no way to learn whether it does, so the
        invocation counts as a write with no target. An operand that cannot be
        read is the same case, the command's words being incomplete without it.
        """
        string, prefix_end = split
        if string is UNKNOWN:
            self.mutates = True
            return
        for arg in args[prefix_end:]:
            if arg.value is UNKNOWN:
                self.mutates = True
                return
            string += " " + shlex.quote(arg.value)
        seed = {}
        if not conditional:
            for arg in cmd.get("Assigns") or ():
                if gives_value(arg):
                    seed[arg["Name"]["Value"]] = \
                        self.assigned_value(arg.get("Value"))
        # The assignments `env` was given itself reach the command the string
        # names, and were stepped over rather than read while the string was
        # being found: `env A=/tmp/store -S 'bd -C "$A" ...'` writes /tmp/store.
        wrapper_assigns, sealed = self.prefix_env(args, prefix_end)
        seed.update(wrapper_assigns)
        self.scan_script(string, seed=seed, sealed=sealed)

    def eval_builtin(self, args, start):
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

        An operand this scan cannot read is the fail-safe case: the text may
        write and there is no way to learn whether it does, so the invocation
        counts as a write with no target. The roots then sync, which is the
        answer already given to every other unreadable write; a `-C` inside such
        a string is beyond recovery either way.
        """
        parts = []
        i = start + 1
        if i < len(args) and args[i].value == "--":
            i += 1
        while i < len(args):
            word = args[i].value
            if word is UNKNOWN:
                self.mutates = True
                return
            parts.append(word)
            i += 1
        if not parts:
            return
        # Not a subshell: `eval` runs in the shell that called it, so a `cd`
        # inside it does reach the command after. Which branch of it ran is the
        # inference this scan declines to make, so the cwd afterwards is left
        # unknown rather than guessed -- as it is after any compound command.
        self.scan_script(" ".join(parts), cwd=self.scope.cwd,
                         known=self.scope.known)
        self.scope.known = False

    def scan_script(self, script, seed=None, sealed=False, cwd=None,
                    known=None):
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
        tree, parsed = parse(script)
        if tree is None:
            return
        self.scripts.add(script)
        try:
            self.sub_scan(tree.get("Stmts") or (), seed=seed, text=parsed,
                          sealed=sealed, cwd=cwd, known=known)
        finally:
            self.scripts.discard(script)


def scan(command, launch_cwd):
    """What `command` writes, launched from `launch_cwd`.

    `launch_cwd` empty says the directory is unknown rather than being this
    process's own, so a relative target under it stays unresolved.
    """
    tree, parsed = parse(command)
    scanner = Scanner(launch_cwd, parsed)
    if tree is not None:
        scanner.stmts(tree.get("Stmts") or (), conditional=False)
    return scanner.mutates, scanner.unresolved, scanner.targets


def main():
    command = sys.stdin.read()
    launch_cwd = sys.argv[1] if len(sys.argv) > 1 else os.getcwd()
    try:
        mutates, unresolved, targets = scan(command, launch_cwd)
    except Unavailable as err:
        # Nothing is written to stdout, so a caller reading the first field
        # cannot mistake a scan that did not happen for one that found no
        # write. The status says the same thing for a caller that checks it.
        sys.stderr.write("command_scan: %s\n" % err)
        return 2
    # Both counts come first and always, so the targets remain everything past
    # them and a caller need not tell a count from a path.
    out = ["1" if mutates else "0", str(unresolved)] + targets
    sys.stdout.write("\0".join(out) + "\0")
    return 0


if __name__ == "__main__":
    sys.exit(main())


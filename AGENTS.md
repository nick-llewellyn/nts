# Agent Instructions

This project uses **bd** (beads) for issue tracking. Run `bd prime` for full workflow context.

## Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work atomically
bd close <id>         # Complete work
bd dolt push          # Push beads data to remote
```

## Pull Request Workflow (mandatory)

`main` is protected; **never `git commit` or `git push` directly to
`main`**. Every change — including agent-authored ones — must land
through a pull request. The rule applies at *commit time*, not just
push time: see [Branch Protection](#branch-protection-read-this-before-any-git-commit)
below for the local hooks that enforce it mechanically once
`core.hooksPath` is activated for the clone. A fresh checkout
that has not opted in still permits the local commit on `main`;
the GitHub-side rule refuses only the later push or PR merge, so
recovery means resetting `main` back to its authoritative remote
(typically `origin/main`, but see the multi-remote caveat in the
"Recovery when the rule is broken" section below if you cloned
from a fork) rather than preventing the commit in the first place.
Required approvals are set to **0** so a *human* contributor can
self-merge once the required status checks pass; **agents must
not** self-merge — see [Agent merge policy](#agent-merge-policy-read-this-before-any-gh-pr-merge)
below. Every PR triggers the CI workflow (including doc-only
ones); the `build`, `rust`, `rust-bridge-sync`, `hooks-syntax`,
and `hooks-behaviour` jobs all skip the heavy work on doc-only
diffs but still report a status, so branch protection resolves
without manual intervention. See
[`DEVELOPMENT.md`](DEVELOPMENT.md#contribution-workflow) for the
authoritative branch-protection table.

Standard agent loop on a fresh task:

```bash
git switch -c <type>/NTS-<num>-<short-slug>  # e.g. feat/NTS-24-coverage-upload
# ... make edits, run local quality gates (see DEVELOPMENT.md) ...
git push -u origin HEAD                # push the feature branch
gh pr create --fill                    # uses .github/pull_request_template.md
# The Linear GitHub app picks up the bare Linear identifier (e.g. NTS-24)
# from the branch name and auto-attaches the PR to the Linear issue --
# no manual `save_issue_linear` call is required. See "Linear PR Linking"
# below for the full mechanism.
# ... wait for CI; fix anything red ...
# STOP HERE. Report PR URL + CI status to the user and wait for
# explicit "merge it" before running `gh pr merge`. See
# "Agent merge policy" below — branch protection allows the
# merge, but the policy here does not.
```

Operational notes:

- The PR template under `.github/pull_request_template.md` carries
  the canonical checklist. Tick the boxes you actually ran; do not
  blanket-check items you skipped.
- The `dependency-review` job runs PR-only and fails on `high`-
  severity advisories; if it fires on a transitive bump, prefer
  pinning the offending dep over disabling the gate.
- Branch-protection details (required checks, status-check names,
  linear history, etc.) live in
  [`DEVELOPMENT.md`](DEVELOPMENT.md#contribution-workflow). Treat
  that section as the source of truth when reconciling repo
  settings.

## Agent merge policy (read this before any `gh pr merge`)

> **Hard rule:** An agent must **never** call `gh pr merge` (or
> the GitHub web "Merge pull request" button via any tool) on a
> PR it authored, regardless of CI state, regardless of whether
> the PR appears trivial, and regardless of how recently the user
> said "merge the previous one". A separate explicit "merge it"
> from the user is required for **every** merge, **every** time.

Branch protection's `required_approving_review_count: 0` exists so
that a *human* contributor can self-merge their own work without
having to round-trip a reviewer for trivial changes. Agents are
not human contributors. The PR-creation step, plus the user's
review of the diff, plus the user's explicit instruction to
merge, are the agent-authored equivalent of the review-and-merge
loop that protection rule was designed for.

This policy applies even when:

- CI is fully green and all required status checks pass.
- The PR is small (one commit, one file, one line).
- An earlier PR in the same session was merged with the user's
  permission. Permission does **not** carry forward to the next
  PR.
- The user said "fine, ship it" or similar about a *different*
  PR, even minutes earlier.
- The change reverts an earlier agent action (revert PRs also
  need explicit merge permission).
- AGENTS.md, CLAUDE.md, or any other doc says "self-merge once
  green" — that language is for human contributors. The rule in
  this section overrides it for agents.

The agent-side workflow is therefore:

1. Push the branch and open the PR (`gh pr create`).
2. Report the PR URL, the diff summary, and the CI status to the
   user.
3. **Stop.** Wait for explicit "merge it" / "go ahead and merge"
   / equivalent unambiguous instruction.
4. On receiving that instruction, `gh pr merge --squash
   --delete-branch` and report the merge result.

Recovery when this rule is broken: open a revert PR
(`git revert <squash-sha>` on a `revert/pr-<n>-<short-slug>`
branch, push, `gh pr create`) and stop at step 3 of the
workflow above. Do **not** auto-merge the revert PR either —
that would compound the original failure with the same
mistake.

## Branch Protection (read this before any `git commit`)

> **Hard rule:** Never run `git commit` while `HEAD` points at `main`
> (or `master`). The PR-only policy applies at *commit time*, not
> just push time — landing a change starts with `git switch -c`,
> not with staging on `main`.

Before staging anything, confirm the working branch:

```bash
git branch --show-current        # MUST NOT print 'main' or 'master'
```

If it does, create a feature branch first. The marker below
combines `$$` (shell PID) with `$(date +%s)` (epoch seconds) so it
is unique *per invocation*, not just per shell. A bare `$$` would
collide with a stale stash left by an aborted earlier run in the
same terminal — the second run's `git stash push` is a no-op on a
clean tree, and a `grep -qF "$m"` against the bare PID would match
the stale entry and pop it onto the new branch. The `stash@{/$m}`
lookup also selects the entry by message rather than stack
position, so an unrelated push at `refs/stash` between the create
and the pop cannot redirect a plain `git stash pop` onto the wrong
commit. A stash-count guard would only verify that *some* entry
was added — `refs/stash` is shared across worktrees, so it cannot
distinguish *our* entry from a sibling shell's. The `--index` flag
on the pop restores the staged/unstaged split as it was before
the stash; without it, files that were staged when the hook fired
come back as unstaged on the new branch and the obvious follow-up
`git commit` records nothing (or worse, an empty commit if
`--allow-empty` is in muscle memory):

```bash
m=park-pre-branch-$$-$(date +%s)
git stash push -u -m "$m"                # no-op if working tree is clean
git switch -c <type>/<short-slug>
git stash list | grep -qF "$m" && git stash pop --index "stash@{/$m}"
```

### One-time setup per clone

This repo ships `pre-commit`, `pre-merge-commit`, and `pre-push`
hooks under `tool/hooks/` that refuse direct work on `main`/
`master`. Activate them once per clone (git deliberately does not
version `.git/hooks/`, so the opt-in must be re-run on every fresh
clone):

```bash
git config core.hooksPath tool/hooks
```

Verify with:

```bash
git config --get core.hooksPath  # MUST print 'tool/hooks'
```

A fresh agent session that skips this step gets no local protection;
treat it as part of the standard ramp-up alongside `bd prime`.

### Recovery when the rule is broken

If a commit lands on a local protected branch despite the above
(the hook was off, or `--no-verify` was used), substitute
`<protected-branch>` with the branch the commit landed on
(`main` or `master` — the `pre-commit` and `pre-merge-commit`
hooks reject both):

```bash
# 1. Move the commit onto a feature branch
git switch -c <type>/<short-slug>          # branch tracks current HEAD

# 2. Reset local <protected-branch> to its remote
git switch <protected-branch>
git fetch --prune origin
git reset --hard origin/<protected-branch>

# 3. Resume on the feature branch
git switch <type>/<short-slug>
```

The recipe assumes `origin` tracks the canonical repository. If
you cloned from a fork (the common multi-remote layout has
`origin` pointing at the fork and a separate remote -- often
named `upstream` -- pointing at the canonical repo), substitute
that authoritative remote name for both `origin` references in
step 2. Resetting `<protected-branch>` against the fork would
adopt the fork's history rather than the canonical branch's;
this is the same caveat the `pre-push` hook prints in its
epilogue, mirrored here so the doc and the hook agree.

Then push the branch and open a PR via the standard loop in the
"Pull Request Workflow (mandatory)" section above. **Do not push
local `<protected-branch>`.** The two layers of defence are
asymmetric across the two branch names:

- For `main`, GitHub branch protection (with `enforce_admins: true`)
  refuses the push at the remote, and the local `pre-push` hook
  refuses it too provided `core.hooksPath` was activated for this
  clone (see "Local hook setup" in `DEVELOPMENT.md`).
- For `master`, no remote-side rule is configured in this repo —
  the local `pre-push` hook is the only line of defence. A
  contributor pushing `master` from a clone that has not run
  `git config core.hooksPath tool/hooks` will not be refused at
  the remote.

In practice `main` is the branch to substitute for almost every
contributor; `master` is covered locally for parity with the hook
alternation arms (the `pre-push` hook rejects `refs/heads/master`
just as it does `refs/heads/main`) so a clone that has only ever
known `master` -- e.g. an older fork, or a downstream that hasn't
renamed -- gets local-layer protection without needing a separate
recipe, even though it has no remote-layer protection in this
repo.

### Why this section exists

Branch protection on `main` is enforced at two layers, with CI
acting as the upstream source of the signals the remote layer
consumes:

1. **Local hooks** (`tool/hooks/pre-commit`,
   `tool/hooks/pre-merge-commit`, `tool/hooks/pre-push`) —
   `pre-commit` refuses to record a plain commit on local `main`/
   `master`; `pre-merge-commit` covers `git merge` *when git is
   about to record an actual merge commit* (which does not fire
   `pre-commit`); `pre-push` refuses to update `refs/heads/main`/
   `refs/heads/master` on the remote regardless of source branch.
   Two commit-time bypasses exist and are caught only at push
   time: (a) rebases that replay history onto local `main` (each
   replayed commit runs in detached HEAD, so `pre-commit` falls
   through), and (b) fast-forward merges (`git merge feature/foo`
   while `main` has no diverging commits advances the ref without
   creating a commit, so `pre-merge-commit` does not fire). In
   both cases the resulting `main` cannot be published without
   tripping `pre-push` and layer 2. All three hooks require
   activation per clone: `git config core.hooksPath tool/hooks`.
   Without activation, layer 1 contributes nothing.
2. **GitHub branch protection** — the rule on `main` does the
   actual blocking at the remote and consists of two configured
   gates:
     - The protection rule itself refuses direct pushes from
       non-admin contributors. `enforce_admins: true` extends
       that refusal to admin/owner accounts, closing the
       maintainer-bypass path that otherwise would let a single
       `git push` skip every required check (re-apply with
       `gh api -X POST /repos/<owner>/<repo>/branches/main/protection/enforce_admins`).
     - `required_status_checks` refuses the PR merge until the six
       listed contexts (`Detect changed paths`, `Dart tests gate`,
       `Verify FRB bindings are in sync`, `Rust build + tests +
       coverage`, `Hooks shell-syntax check`, `Hooks behaviour
       check`) report success.

CI is not a separate enforcement layer — it does not gate the
merge. It runs the workflows that publish the status checks
`required_status_checks` reads, so a regression in the workflows
is the most common way the gate ends up reporting green on
something that should not merge. The two `Hooks *` jobs in
particular exist so a PR that touches only `tool/hooks/**` still
gets validated rather than skipping every heavy job and reaching
the merge gate unverified.

The hook layer exists because the remote layer can only act once
a commit already exists locally: the branch protection rule
refuses the push from non-admin contributors (and from admins too
once `enforce_admins: true` is set), and the
`required_status_checks` gate refuses the PR merge after CI
publishes its statuses. A direct commit on local `main` is a
recoverable mistake (either remote gate plus the linear-history
rule will refuse the eventual push or merge), but it consumes a
`git reflog` window and reorders the natural workflow. Layer 1
closes that window for the two common shapes (plain commit, merge
commit) when `core.hooksPath` is activated.

## Non-Interactive Shell Commands

**ALWAYS use non-interactive flags** with file operations to avoid hanging on confirmation prompts.

Shell commands like `cp`, `mv`, and `rm` may be aliased to include `-i` (interactive) mode on some systems, causing the agent to hang indefinitely waiting for y/n input.

**Use these forms instead:**
```bash
# Force overwrite without prompting
cp -f source dest           # NOT: cp source dest
mv -f source dest           # NOT: mv source dest
rm -f file                  # NOT: rm file

# For recursive operations
rm -rf directory            # NOT: rm -r directory
cp -rf source dest          # NOT: cp -r source dest
```

**Other commands that may prompt:**
- `scp` - use `-o BatchMode=yes` for non-interactive
- `ssh` - use `-o BatchMode=yes` to fail instead of prompting
- `apt-get` - use `-y` flag
- `brew` - use `HOMEBREW_NO_AUTO_UPDATE=1` env var

## Doc-Snippet Validator

`tool/check_doc_snippets.dart` extracts fenced `dart` code blocks from the
docs (README, CHANGELOG, ARCHITECTURE, `example/example.md`), wraps fragments
in a harness, and runs `dart analyze`. CI runs it via the "Verify
documentation snippets" step.

On failure it prints the failing doc file, snippet index, and the analyzer
diagnostics. The **wrapped snippet body is suppressed by default** so verbatim
doc source is never echoed into the retained GitHub Actions log. When triaging
a real failure, opt back in:

```bash
dart run tool/check_doc_snippets.dart --print-snippets
# or, equivalently:
SNIPPET_VALIDATOR_VERBOSE=1 dart run tool/check_doc_snippets.dart
```

Prefer `--print-snippets` **locally**: a best-effort redaction pass strips
obvious secret-shaped tokens before printing, but it is defence-in-depth, not
a guarantee. `--help` lists all flags.

## DoltHub Session Completion (overrides the auto-generated block below)

DoltHub (`nick-llewellyn/nts` on dolthub.com) is the **authoritative** store
for Beads issues. The `bd dolt push` step in the auto-generated "Session
Completion" block below is a no-op without a configured remote — this section
replaces that shorthand with the full ordering required now that the remote
exists.

Fresh-clone prerequisite (one-time per clone, not committed):
```bash
bd init   # automatically configures the DoltHub remote via sync.git-remote
# Requires Dolt Credentials (key-based). Use `dolt login` or add your
# public key at https://www.dolthub.com/settings/credentials
```

**Mandatory session-close order:**

1. `git pull --rebase` — catch up code changes from `origin/main`.
2. `bd dolt pull` — pull Beads commits from DoltHub **before** pushing local
   changes. Surfaces merge conflicts here, not on push. Resolve any conflicts
   with `bd dolt status` before proceeding.
3. `bd dolt push --remote origin` — **blocking requirement**. Work is not
   complete until this succeeds. A failed push means the session's issue
   changes are not on DoltHub; fix auth / connectivity and retry until it
   succeeds.
4. Commit and push the code branch via the standard
   [Pull Request Workflow](#pull-request-workflow-mandatory).

```bash
# Full push sequence
git pull --rebase
bd dolt pull
# resolve any bd dolt status conflicts here
bd dolt push --remote origin          # MUST succeed before opening the PR
git push -u origin HEAD
gh pr create --fill
git status  # MUST show "up to date with origin"
```

**CRITICAL:** `bd dolt push --remote origin` failing is a blocking error.
Do not open the PR, do not stop the session — fix the push first.

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:ca08a54f -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd dolt push
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->

## Linear Sync Configuration

This project syncs `bd` issues to **Linear** (workspace `nick-llewellyn`, team `nts`).

### Workspace Identifiers

| Field | Value |
|---|---|
| Team | `nts` |
| Team ID | `331d8088-688e-4385-84ab-aa9642909146` |
| Project | `nts` |
| Project ID | `6cde53e1-e9e3-423b-a8a4-478bdf116d7f` |

### Initial Setup (per clone)

```bash
bd config set linear.team_id "331d8088-688e-4385-84ab-aa9642909146"
bd config set linear.project_id "6cde53e1-e9e3-423b-a8a4-478bdf116d7f"
```

The `LINEAR_API_KEY` is stored in the macOS Keychain and exported lazily via `~/.zshrc`. To verify it is set without revealing the value, run `[ -n "$LINEAR_API_KEY" ] && echo "set" || echo "not set"` before syncing.

### Sync Workflow

Always pull before pushing to avoid creating duplicates and to surface
conflicts locally:

```bash
bd linear sync --pull          # import from Linear first
bd linear sync --push          # then export local changes
```

`bd 1.0.5` adds several flags worth knowing (all confirmed via
`bd linear sync --help`):

| Flag | Purpose |
|---|---|
| `--prefer-linear` / `--prefer-local` | Conflict resolution — force one side to win when timestamps diverge. `--prefer-linear` is the *intended* way to make a pull adopt Linear's terminal state, but it is **not reliable** in practice: when local edits bumped the local `updatedAt`, an observed `--prefer-linear` pull still kept the local non-terminal state (see "Pull won't adopt Linear's state" and "Issue State Synchronization"). |
| `--pull-if-stale [--threshold 20m]` | Pull only if the local Linear cache is older than the threshold (default 20m). This is the source of the recurring `⚠ Linear data is … stale` warning. |
| `--state` (`open`, `closed`, or `all`) | Restrict the sync to issues in a given local state (default `all`). |
| `--issues a,b` / `--parent TICKET` | Scope a push to specific beads or a ticket subtree. **Required** for any push that must succeed reliably — see Gotcha #4. |
| `--create-only` | On push, only create new Linear issues; never update existing ones. |
| `--relations` | On pull, import Linear blocking relations as bd dependencies. |
| `--milestones` | On pull, reconstruct Linear project milestones as local epic parents. |
| `--type t` / `--exclude-type t` | Filter the sync to/from specific issue types. |

### Claiming an issue

`bd update <id> --claim` (and `bd update <id> --status in_progress`) write only
to the local Dolt database. They do **not** notify Linear. Until an explicit
push is performed, Linear still shows the issue as "Todo" or whatever state it
was in before the claim.

The correct sequence for claiming an issue is:

```bash
# 1. Claim locally.
bd update <id> --claim          # or: bd update <id> --status in_progress

# 2. Push the updated state to Linear. ALWAYS scope with --issues — an
#    unscoped push errors on the workspace's ambiguous state_map (Gotcha #4).
bd linear sync --push --issues <id>

# 3. Persist to DoltHub using the mandatory pull-then-push order (see
#    "DoltHub Session Completion") — pull first to surface conflicts locally.
bd dolt pull
bd dolt push --remote origin
```

A scoped single-issue push of an `in_progress` bead succeeds in practice (the
name-keyed `In Progress = in_progress` override resolves the started-type
ambiguity). Do this **before** opening a branch or writing any code, so Linear
reflects "In Progress" for the full duration of the work.

Alternatively — and more robustly — let the **Linear GitHub app** drive the
status: opening the PR transitions the linked issue to "In Progress"
automatically (see "Linear PR Linking"). The manual push above only matters for
the window between claiming and opening the PR.

### Closing an issue

`bd close` writes only to the local Dolt database. It does **not** notify
Linear. Running `bd dolt push --remote origin` afterwards persists the `CLOSED`
state to DoltHub but still does not touch Linear.

**Preferred path: let the PR close the issue.** Merging the linked PR
transitions the Linear issue to "Done" automatically (Linear GitHub app), which
side-steps the push-side mapping ambiguity entirely. A subsequent
`bd linear sync --pull --prefer-linear` is *intended* to import that "Done" as a
local `CLOSED` (see "Issue State Synchronization"), but in practice the pull is
**unreliable** — see the "Pull won't adopt Linear's state" troubleshooting entry
and the manual `bd close` fallback below, which is the expected reconciliation,
not an exceptional one.

**Manual fallback** (the `--prefer-linear` pull did not adopt Linear's state —
the common case — or the issue was abandoned, or the GitHub integration did not
fire):

```bash
# 1. Close locally, then persist to DoltHub using the mandatory pull-then-push
#    order (see "DoltHub Session Completion") — pull first to surface conflicts.
bd close <id>
bd dolt pull
bd dolt push --remote origin

# 2. Transition Linear to Done directly — do NOT rely on a push to map it.
#    Use the save_issue_linear tool or the Linear UI:
#      save_issue_linear id="<LINEAR-ID>" state="Done"
```

Whether `bd linear sync --push` maps a local `CLOSED` to Linear **Done** or
**Canceled** is **not reliably determined** for this workspace — the
`completed` and `canceled` types both map to `closed`, leaving the push inverse
ambiguous (Gotcha #1, investigated in NTS-29). A `closed`-only push does not
*error*, but the resulting Linear state is unverified for a non-terminal
target. Set the terminal Linear state **explicitly** (step 2 above) rather than
trusting a push, and prefer the PR-merge path whenever possible.

### Known Gotchas (read before every sync)

> **`bd 1.0.5` note.** These behaviours were re-verified against `bd 1.0.5`
> (Homebrew) this session. `bd 1.0.5` did **not** retire the workarounds below;
> its hardened push validator (upstream PR #3328) actually *tightened* sync,
> introducing Gotcha #4. Treat the pull-centric, scoped-push flow as mandatory,
> not optional.

#### 1. Status Mapping: CLOSED → Done vs Canceled is ambiguous

`bd`'s `linear.state_map` maps Linear **state types** to beads statuses, and the
sensible defaults map *both* `completed` **and** `canceled` to `closed`. That
makes the **push inverse ambiguous**: a local `CLOSED` has no single,
deterministic Linear target, so it may land as **Canceled** rather than
**Done**.

This workspace carries name-keyed overrides (`linear.state_map.Done = closed`,
`In Progress = in_progress`, `Todo = open`) that *attempt* to disambiguate. A
`closed`-only push no longer errors, but **whether it produces Done or Canceled
for a non-terminal Linear target is unverified** — do not assume it is fixed.

**Workaround:** Do not trust a push to set the terminal Linear state. Set
**Done** explicitly (Linear UI or `save_issue_linear` with `state: "Done"`),
or — better — let the PR-merge webhook transition it (see "Closing an issue").

**Tracking:** NTS-29 (Done) is the full investigation record; NTS-8 (open)
tracks the underlying `bd`-side mapping limitation.

#### 2. State Clobbering: Manual Linear Edits Can Be Overwritten

A push re-applies local state and can **overwrite manual status changes made
directly in Linear** (e.g. a hand-set **Done** reverting if the local state
re-maps differently).

**Mitigations in `bd 1.0.5`:**
- **Conflict-resolution flags** — `--prefer-local` / `--prefer-linear` make the
  winning side explicit instead of relying on newer-timestamp-wins.
- **Scope every push** with `--issues` (or `--parent`) so a broad sync cannot
  touch issues you did not intend.

**Rule:** After correcting statuses in Linear, never run a blind, unscoped
`bd linear sync --push`. Scope it, and reach for `--prefer-linear` when Linear
should win.

#### 3. Push Only Touches Linked Issues (intentional, hardened)

An unscoped `bd linear sync --push` only updates issues that already have an
`external_ref`; locally-created issues that have never been linked are skipped.
As of `bd 1.0.5` this is **intentional, hardened behaviour**, not a bug — the
`"Linear data has never been pulled"` warning is the signal.

**To create new Linear issues from local beads,** use `--create-only` with an
explicit scope, after a pull:

```bash
bd linear sync --pull
bd linear sync --push --create-only --issues nts-abc,nts-def
```

…but note this create path is itself subject to Gotcha #4. When it errors, the
reliable fallback is to **create the Linear issue directly** (`save_issue_linear`)
and link the bead's `external_ref` to its URL, then use an `NTS-<n>` branch so
the Linear GitHub app attaches the PR.

#### 4. `bd 1.0.5` Push Ambiguity Rejection (the new failure mode)

`bd 1.0.5`'s push validator (upstream PR #3328) **errors** rather than guessing
when the `state_map` is ambiguous:

```text
linear.state_map maps beads status X to multiple Linear states
```

The nts team triggers this because it has **two started-type states**
(*In Progress*, *In Review*) and **two open-ish states** (*Backlog* = backlog,
*Todo* = unstarted). The beads → Linear inverse for `open` and `in_progress` is
therefore non-deterministic. Per NTS-29, **every** `state_map` variant tried
(display-name keys, type-based keys, name-keyed overrides) errored on either the
`open` or `in_progress` ambiguity; the config was restored to its original state
with no net change. Upstream PR #3500 (dotted state-NAME keys) is the candidate
fix but needs source-level investigation of the validator's grouping.

**Practical consequences:**
- **Always scope pushes** with `--issues` / `--parent`. A single linked,
  `in_progress` issue pushes fine (the `In Progress` override resolves the
  started-type case); broad unscoped pushes are the ones that error.
- **Do not rely on push to create `NTS-` IDs** for brand-new beads — create the
  Linear issue directly and link `external_ref` (see Gotcha #3).
- This is a `bd`/workspace limitation, not something to "fix" by editing the map
  blindly — NTS-29 already established that no config variant resolves it.

### Troubleshooting

#### Push fails: "maps beads status … to multiple Linear states"

This is Gotcha #4. The push you ran was unscoped (or spanned `open`/
`in_progress` issues). Re-run it scoped to a single linked issue:

```bash
bd linear sync --push --issues <id>
```

For brand-new issues, create the Linear side directly (`save_issue_linear`)
instead of pushing. See Gotcha #4 for the full explanation.

#### Pull won't adopt Linear's state (e.g. a merged issue stays open locally)

`bd`'s default conflict resolution is newer-timestamp-wins; local edits (claims,
pushes) can bump the local `updatedAt` so a plain pull keeps the local state.
The documented first move is to force Linear to win:

```bash
bd linear sync --pull --prefer-linear
```

**Caveat (observed, not theoretical):** `--prefer-linear` is **not reliable**
for this. During the NTS-40 close it was run twice against an issue Linear
already showed as **Done**, and the local bead stayed `in_progress` both times.
When `--prefer-linear` does not take, reconcile manually — Linear is the
authoritative side, so close the local bead to match and persist to DoltHub:

```bash
bd close <id>                 # match Linear's terminal state locally
bd dolt pull                  # MANDATORY before any push — surface conflicts here
bd dolt push --remote origin
```

The `bd dolt pull` step is not optional: per "DoltHub Session Completion" the
mandatory push order is always pull-then-push, so DoltHub conflicts surface
locally rather than on the push. This is the same manual reconciliation as in
"Closing an issue"; the only new point is that it is required **even after
`--prefer-linear`**, not just when the PR webhook failed to fire. This is an
upstream `bd` limitation, not a repo-fixable bug (investigated under NTS-8;
push-side counterpart under NTS-29).

#### Recurring `⚠ Linear data is … stale` warning

The local Linear cache has a staleness clock. Either pull, or gate pulls on the
threshold so they only run when actually stale:

```bash
bd linear sync --pull-if-stale                 # default 20m threshold
bd linear sync --pull-if-stale --threshold 5m  # pull if older than 5 minutes
```

#### GraphQL Argument Validation Error

If `bd linear sync` fails with a "GraphQL Argument Validation" error, the stored
sync timestamp is stale (usually from a different workspace). Reset it:

```bash
bd config set linear.last_sync "0001-01-01T00:00:00Z"
```

Then retry the sync.

## Assignee Convention

This is a single-developer repository. Every issue — whether created locally
with `bd` or imported from Linear — must have its `assignee` set to
`nllewelln@gmail.com`. That is the field Linear recognises for this workspace,
so assignments round-trip across `bd linear sync` without a separate
user-mapping table.

In `bd` 1.0.5 `owner` and `assignee` are **distinct fields**, and the
convention targets `assignee` deliberately. `owner` is auto-derived from the
actor (git `user.name` / `user.email`) at `bd create` time and has **no CLI
setter** — `bd assign` and `bd update --assignee` write `assignee` only.
Locally-created beads get `owner` populated automatically; beads that arrive
via `bd linear sync --pull` land with `owner` unset and there is no sanctioned
way to backfill it. `assignee`, by contrast, is settable and round-trips to
Linear, so it is the field the audit below checks.

`bd` does not expose a `default.assignee` config key, so the rule is
agent-enforced rather than tool-enforced. The agent operating this repo
must apply it on every relevant command:

1. **Local creation.** Always pass `-a nllewelln@gmail.com` (or
   `--assignee nllewelln@gmail.com`) to `bd create`:

   ```bash
   bd create "Title" -a nllewelln@gmail.com -t task -p 2
   ```

2. **Linear pull.** `bd linear sync --pull` does not honour any default
   assignee — issues whose Linear assignee is unset land in the local
   database with an empty `assignee`. Immediately after every pull, backfill:

   ```bash
   bd linear sync --pull
   bd list --json \
     | python3 -c 'import json,sys;[print(i["id"]) for i in json.load(sys.stdin) if not i.get("assignee")]' \
     | xargs -I{} bd assign {} nllewelln@gmail.com
   ```

3. **Audit on every session.** Before claiming new work, run the same
   one-liner to catch anything that slipped through (manual `bd create`
   calls without the flag, third-party imports, schema migrations):

   ```bash
   bd list --json \
     | python3 -c 'import json,sys;[print(i["id"]) for i in json.load(sys.stdin) if not i.get("assignee")]' \
     | xargs -I{} bd assign {} nllewelln@gmail.com
   ```

   A silent run means zero unassigned issues. Note that Linear-imported beads
   may still show an empty `owner` (e.g. `nts-gbqn4m` / NTS-8); that is
   expected and harmless, because `owner` has no CLI setter and this audit
   tracks `assignee`, not `owner`.

`bd` filters assignee strings by exact match, so any divergence (e.g.
`Nicholas Llewellyn`, `nick.l`, capitalisation drift) will silently
fragment the database. Stick to the canonical `nllewelln@gmail.com`.


## Communication & Reference Convention

To ensure the human developer can easily map local activity to the Linear project:
1. **Use the Linear ID.** Every mention of an issue in chat or PR descriptions should use the Linear ID (e.g. `NTS-26`). The Beads ID is an internal detail of the local Dolt database and does not need to appear in branch names, PR titles, or PR bodies.
2. **Retrieving Mappings.** The Beads issue and Linear issue are already
   linked via the `external_ref` field in the local Dolt database. To go in
   either direction:
   - **Linear ID → Beads ID:** `bd search "NTS-26"` returns the Beads ID
     (e.g. `nts-6rh`).
   - **Beads ID → Linear ID:** `bd show nts-6rh` (or `bd show nts-6rh
     --json | jq -r .external_ref`) returns the Linear URL containing the
     identifier.
3. **Branch Naming.** Use `<type>/NTS-<num>-<slug>` (e.g.
   `feat/NTS-26-link-github-pr`). The Linear ID alone is sufficient — the
   Linear-GitHub app triggers on it, and the Beads issue is reachable via
   `bd search "NTS-26"`.

## Linear PR Linking

PR ↔ Linear-issue linkage and status tracking are handled automatically by
the **Linear GitHub app**. The app watches for the Linear identifier (e.g.
`NTS-26`) in the branch name, PR title, or PR description.

1. **Auto-Linkage.** As long as the branch name carries the Linear ID (e.g.
   `feat/NTS-26-link-github-pr`), Linear will automatically attach the PR
   to the issue.
2. **Auto-Status (Opened → In Progress).** Opening the PR automatically
   transitions the Linear issue to "In Progress".
3. **Auto-Status (Merged → Done).** Merging the PR in GitHub automatically
   transitions the Linear issue to "Done".
4. **Branch Format.** The Linear workspace is configured with the
   `identifier-title` branch format. This ensures that any branches
   manually generated via the Linear UI carry the required identifier
   and a readable slug, maintaining consistency with agent-authored
   branches.

## Issue State Synchronization

Because of the automatic "Merged → Done" transition, agents should prefer
a **pull-centric** synchronization flow:

1. **Pull to Close.** At the start of a new session (or after a merge), run
   `bd linear sync --pull --prefer-linear`. The `--prefer-linear` flag matters:
   `bd`'s default newer-timestamp-wins conflict resolution means a plain
   `--pull` can *keep* a stale local `IN_PROGRESS`/`OPEN` when local edits (a
   claim, a push) bumped the local `updatedAt` after the Linear "Done".
   `--prefer-linear` is *intended* to make Linear's terminal state win,
   importing it as a local `CLOSED`. In practice this is **unreliable** — see
   "Pull won't adopt Linear's state" in Troubleshooting; an observed
   `--prefer-linear` pull left the local bead `in_progress` despite Linear
   showing **Done**. Treat the manual `bd close` reconciliation in step 3 as the
   expected fallback, not an exceptional one.
2. **DoltHub Sync.** After the pull, persist the closed state to the
   authoritative database using the mandatory pull-then-push order from
   "DoltHub Session Completion" — `bd dolt pull` first to surface any
   conflicts locally, then `bd dolt push --remote origin`.
3. **Manual Fallback.** Manually run `bd close` whenever the `--prefer-linear`
   pull does not adopt Linear's terminal state (the common case when local edits
   bumped the local timestamp), as well as when the issue was abandoned or the
   GitHub integration failed to trigger. Do **not** rely on
   `bd linear sync --push` to set the terminal Linear state — its `CLOSED`
   inverse is ambiguous (Gotcha #1). Prefer letting the PR-merge webhook set
   **Done**, or set it explicitly via `save_issue_linear`.

## Versioning & Release Policy

This project follows a **release-only bumping** policy: metadata version
fields are not touched during ordinary feature work. Bumps land in a
dedicated release commit so that feature branches stay clean and the
version number on `main` always reflects the most recently *released*
artefact, not work-in-progress.

### Rules

1. **Metadata files stay at the current stable version during
   development.** Do not edit the `version:` field in `pubspec.yaml` or
   the `version = ` field in `rust/Cargo.toml` as part of a feature,
   fix, or refactor PR. They must remain pinned to the last released
   version (e.g. `5.1.0` / `0.5.0`) until the release commit lands.

2. **Document ongoing work under the next intended release header in
   `CHANGELOG.md`.** Do **not** use an `## Unreleased` section — file
   entries directly under the target version header (e.g. `## 5.1`,
   `## 5.2`). This makes the intended landing place explicit and
   avoids a separate "move entries from Unreleased → version" step at
   release time. The header may be a two-component version (`## 5.1`)
   while patch-level work is still accumulating; promote it to a full
   three-component header (`## 5.1.0`) only when the release commit
   itself lands.

3. **Bumps land in a dedicated release commit.** When preparing to cut
   a release, a single commit must:
   - increment `pubspec.yaml` and `rust/Cargo.toml` to the new
     version,
   - finalise the `CHANGELOG.md` header for that release (e.g.
     `## 5.1` → `## 5.1.0`, or add the patch component for a point
     release),
   - contain no other functional changes.

4. **Compatibility exception.** If a Rust crate version increment is
   strictly required mid-feature for technical compatibility (e.g. a
   dependency-resolution constraint that cannot be expressed any other
   way), the bump may land in the feature PR. Document the reason in
   the PR description. The default action is to revert.

### Rationale

Version drift across feature branches (each branch carrying its own
speculative `+1` bump) produces noisy diffs at merge time and makes
the version field on `main` an unreliable indicator of what was
actually shipped. Concentrating bumps in a release commit also gives
the release a single, greppable handle for revert/cherry-pick
purposes.

## Security: Zeroization

This project treats specific byte sequences as secrets that must not
linger in freed allocations: AEAD key material
(`rust/src/nts/aead.rs`), NTS cookies (`rust/src/nts/cookies.rs`,
`rust/src/nts/ntp.rs`, `rust/src/api/nts.rs`), the TLS exporter
outputs that derive the C2S / S2C keys (`rust/src/nts/ke.rs`), and
user-supplied root certificate bytes (`CustomRootsBytes` in
`rust/src/nts/ke.rs`). The conventions below apply uniformly to all
of these.

### Conventions

1. **Wrap heap-allocated secret bytes in `Zeroizing<Vec<u8>>` (or
   `Zeroizing<Box<[u8]>>`).** The `zeroize` crate's `Drop` impl wipes
   the backing allocation before it is returned to the allocator.

2. **Pin `zeroize ≥ 1.8`.** Its `impl Zeroize for Vec<T>` wipes the
   full capacity (`self.spare_capacity_mut().zeroize()`, added in
   1.8), so secrets stored in a `Vec<u8>` cannot leak via spare
   capacity at drop time. The lower bound is documented in
   `rust/Cargo.toml` next to the dep. Downgrading silently
   re-introduces the capacity-leak surface.

3. **Construct secret-bearing vectors without growth.** Use
   `slice.to_vec()`, `existing.clone()`, or `vec![0u8; N]` — never
   `push` / `extend` / `reserve` on a vector that will become a
   secret. Reallocation during growth leaves intermediate copies in
   the allocator that `Zeroize` cannot reach. The `zeroize` crate's
   own docstring flags this: *"Cannot ensure that previous
   reallocations did not leave values on the heap."*

4. **Prefer fixed-size arrays when the length is known statically.**
   `SivKey`, `SivKey512`, and `Aes128GcmSivKey` in `nts/aead.rs` wrap
   `[u8; N]` rather than `Vec<u8>`. Arrays have no spare capacity and
   no reallocation history by construction.

5. **Do not call `Vec::shrink_to_fit` on a secret-bearing vector
   immediately before wrapping in `Zeroizing` purely for
   capacity-leak reasons.** It is redundant with the `zeroize ≥ 1.8`
   `Vec` impl, and per the standard-library contract `shrink_to_fit`
   may itself reallocate and free a non-zeroised intermediate buffer,
   re-introducing the residual-memory surface it was meant to remove.
   The growth-free construction discipline in rule 3 is what
   actually closes the surface.

6. **Redact secret-bearing types in `Debug`.** Manual `impl
   std::fmt::Debug` implementations for `CustomRootsBytes`,
   `TrustMode`, `CookieJar`, `RecordKind` (for the `NewCookie`
   variant), `SivKey`, `SivKey512`, and `Aes128GcmSivKey` render
   placeholders (`<REDACTED: N bytes>`, count-only summaries) so
   accidental `{:?}` formatting in logs, panic messages, or
   diagnostic output cannot leak bytes.

### KE-side cookie pipeline

The records parser → KE outcome → [`CookieJar`] handoff is wrapped
end-to-end so a panic anywhere in the chain drops `Zeroizing`-aware
containers rather than naked `Vec<u8>` allocations
(`rust/src/nts/records.rs` `RecordKind::NewCookie(Zeroizing<Vec<u8>>)`,
`rust/src/nts/ke.rs` `KeOutcomePartial::cookies` /
`KeOutcome::cookies` as `Vec<Zeroizing<Vec<u8>>>`,
`rust/src/nts/cookies.rs` `CookieJar` storing
`VecDeque<Zeroizing<Vec<u8>>>` natively). The growth-free
construction discipline above still holds at every allocating
step (`body.to_vec()` and `Vec::clone()` both allocate exactly
`slice.len()` bytes with no reallocation history; `Zeroizing::new`
is a zero-cost wrapper that does not allocate or copy), so
neither the liveness surface nor the capacity surface remains
exposed.

The NTP-response cookie path
(`ServerResponse::fresh_cookies: Vec<Zeroizing<Vec<u8>>>` →
`SessionTable::deposit_cookies` → `CookieJar::put_many`) is also
closed (bd nts-wpvd / NTS-61): each cookie is wrapped in
`Zeroizing` at the parse site in `parse_server_response`
(`rust/src/nts/ntp.rs`), so the transit collection — including the
deposit-side discard paths (stale generation, evicted session)
that never reach the jar — wipes the bytes on drop instead of
freeing naked `Vec<u8>` allocations. `ServerResponse` carries a
manual redacted `Debug` (`<redacted; N cookies>`) per the
convention above.

### Custom roots parsing pipeline

`CustomRootsBytes(Arc<Zeroizing<Vec<u8>>>)` (`rust/src/nts/ke.rs`)
guarantees the **input** buffer is wiped from RAM when the final
`Arc` clone drops. The guarantee does **not** extend through every
downstream copy made during trust-anchor parsing; the scope is:

- **Input buffer:** wiped on final-clone drop, as documented in
  the `CustomRootsBytes` rustdoc and section "Conventions" above.
- **DER path** (`build_with_custom_roots`): no intermediate copy
  exists. The function calls
  `CertificateDer::from_slice(bytes)` and hands the borrowed
  `CertificateDer<'_>` straight to `RootCertStore::add`. rustls
  0.23 extracts the trust anchor inside `add`
  (`anchor_from_trusted_cert(&der)?.to_owned()`) and retains only
  the parsed anchor — not the input DER — so the borrow window
  is bounded by the `add` call and nothing new is allocated that
  would need zeroising.
- **PEM path** (`build_with_custom_roots`): the upstream
  `CertificateDer::pem_slice_iter` iterator allocates a plain `Vec<u8>`
  per certificate inside the parser; those buffers are owned by
  the yielded `CertificateDer<'static>` values and are not under
  this crate's control, so they cannot be `Zeroizing`-wrapped
  without an upstream API change. The refactor processes one
  cert per loop iteration rather than accumulating a
  `Vec<CertificateDer>`, so each PEM-allocated buffer is dropped
  immediately after its `RootCertStore::add` call. This caps the
  residual liveness window to a single iteration but does **not**
  zeroise the bytes on drop. Full closure requires an upstream
  rustls / rustls-pki-types API that accepts a `Zeroizing`-aware
  backing buffer; tracked as `nts-xdo` (upstream-watch).
- **rustls trust anchors** (post-`add`): the parsed
  `TrustAnchor` (subject, SPKI, name constraints) lives inside
  the `RootCertStore` and then inside the returned
  `ClientConfig` for the lifetime of the TLS config. Those
  components are derived from the input DER but are not the
  original DER bytes; their zeroisation is upstream of this
  crate and out of scope for `CustomRootsBytes`.

The discipline above means that on the DER path the
`CustomRootsBytes` guarantee covers the *only* allocation that
holds the input bytes, and on the PEM path it covers everything
this crate allocates — the only residual liveness window is the
upstream-owned per-cert `Vec<u8>` inside each yielded
`CertificateDer`, which is now bounded to one loop iteration.

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
Required
approvals are set to **0**, so self-merging is the expected default
once the required status checks pass. Every PR triggers the CI
workflow (including doc-only ones); the `build`, `rust`,
`rust-bridge-sync`, `hooks-syntax`, and `hooks-behaviour` jobs all
skip the heavy work on doc-only diffs but still report a status, so
branch protection resolves without manual intervention. See
[`DEVELOPMENT.md`](DEVELOPMENT.md#contribution-workflow) for the
authoritative branch-protection table.

Standard agent loop on a fresh task:

```bash
git switch -c <type>/<short-slug>      # e.g. feat/coverage-upload
# ... make edits, run local quality gates (see DEVELOPMENT.md) ...
git push -u origin HEAD                # push the feature branch
gh pr create --fill                    # uses .github/pull_request_template.md
# ... wait for CI; fix anything red ...
gh pr merge --squash --delete-branch   # self-merge once green
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

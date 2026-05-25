# Project Instructions for AI Agents

This file provides instructions and context for AI coding agents working on this project.

## DoltHub Session Completion (overrides the auto-generated block below)

DoltHub (`nick-llewellyn/nts` on dolthub.com) is the **authoritative** store
for Beads issues. The `bd dolt push` step in the auto-generated "Session
Completion" block below is a no-op without a configured remote — this section
replaces that shorthand with the full ordering required now that the remote
exists. `.beads/issues.jsonl` remains tracked in git as a secondary mirror.

Fresh-clone prerequisite (one-time per clone, not committed):
```bash
bd dolt remote add origin https://doltremoteapi.dolthub.com/nick-llewellyn/nts
# Requires DOLT_REMOTE_USER and DOLT_REMOTE_PASSWORD in the environment.
```

**Mandatory session-close order:**

1. `git pull --rebase` — catch up code changes from `origin/main`.
2. `bd dolt pull` — pull Beads commits from DoltHub **before** pushing local
   changes. Surfaces merge conflicts here, not on push. Resolve any conflicts
   with `bd dolt status` before proceeding.
3. `bd dolt push --remote origin` — **blocking requirement**. Work is not
   complete until this succeeds. A failed push means the session's issue
   changes are not on DoltHub; the JSONL mirror in the upcoming PR would then
   be the only durable record, violating the "DoltHub is authoritative"
   invariant. Fix auth / connectivity and retry until it succeeds.
4. Commit and push the code branch (including the `.beads/issues.jsonl` diff)
   via the standard Pull Request workflow. The JSONL mirror still bundles with
   every code PR per the "Beads metadata sync" rule below — do NOT open a
   `.beads/`-only PR.

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


## Build & Test

_Add your build and test commands here_

```bash
# Example:
# npm install
# npm test
```

## Architecture Overview

_Add a brief overview of your project architecture_

## Conventions & Patterns

_Add your project-specific conventions here_

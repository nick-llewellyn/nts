#!/bin/sh
# Functional tests for tool/hooks/.
#
# Sets up an isolated repo, points core.hooksPath at the in-tree hooks,
# exercises forbidden and allowed code paths, and asserts on exit codes
# and stderr content. Catches the regression shape `Hooks shell-syntax
# check` cannot: scripts that parse cleanly under `sh -n` but fail to
# enforce policy at runtime. The round-9 unquoted-heredoc bug is one
# such case -- the recipe assertion below is the explicit sentinel.
#
# Run locally:  sh tool/hooks/test_hooks.sh
# Run from CI:  same; trap-based cleanup keeps the workspace pristine.
set -eu

REPO_ROOT=$(git rev-parse --show-toplevel)
HOOKS_DIR="$REPO_ROOT/tool/hooks"

WORK_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t hooktest)
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT INT TERM

pass=0
fail=0

assert_eq() {
  if [ "$1" = "$2" ]; then
    pass=$((pass + 1)); echo "  PASS: $3"
  else
    fail=$((fail + 1))
    echo "  FAIL: $3" >&2
    echo "    expected: $1" >&2
    echo "    actual:   $2" >&2
  fi
}

assert_grep() {
  if grep -qF -- "$1" "$2"; then
    pass=$((pass + 1)); echo "  PASS: $3"
  else
    fail=$((fail + 1))
    echo "  FAIL: $3 (needle='$1' not in $2)" >&2
    sed 's/^/    | /' "$2" >&2
  fi
}

cd "$WORK_DIR"
# Pin the initial branch name so the test does not depend on the
# caller's `init.defaultBranch`. `git init -b main` lands HEAD on an
# unborn `main` ref directly; the previous shape (`git init` then
# `git checkout -b main`) would `fatal: a branch named 'main' already
# exists` on a future edit that lands a seed commit before the
# checkout when the caller's default is already `main`.
git init -q -b main .
git config user.email "test@example.invalid"
git config user.name "Hook Test"
git config commit.gpgsign false
git config core.hooksPath "$HOOKS_DIR"
echo seed > a.txt
git add a.txt
git -c core.hooksPath=/dev/null commit -q -m seed

echo "=== pre-commit ==="

echo change >> a.txt
git add a.txt
out="$WORK_DIR/pc_main.out"
set +e; git commit -m "should fail" >"$out" 2>&1; rc=$?; set -e
assert_eq 1 "$rc" "pre-commit refuses commit on main"
assert_grep 'direct commits' "$out" "pre-commit prints policy error"
# Round-9 sentinel: the unquoted-heredoc bug aborts the hook with
# an unbound-variable error under set -u, so the literal recipe
# string never appears. The round-22 stash-safety rewrite
# replaced the count-based recipe with a $$-salted marker plus
# stash@{/$m} pop, and round-23 added '$(date +%s)' to make the
# marker unique per invocation rather than per shell. The
# sentinel pins the round-23 shape -- it still catches the
# round-9 unquoted-heredoc bug (the recipe references $m, which
# would be unbound under set -u if the heredoc weren't quoted)
# and now also pins the invocation-unique marker.
assert_grep 'm=park-pre-branch-$$-$(date +%s)' "$out" \
  "pre-commit prints invocation-unique marker (round-23 shape)"
# Round-25 sentinel: pop must carry '--index' so the staged/
# unstaged split is preserved across the branch switch. Without
# it, files that were staged when the hook fired come back as
# unstaged on the new feature branch and the trailing 'git commit'
# either fails ("nothing added to commit") or, if the user passes
# '--allow-empty' from muscle memory, records an empty commit.
# This sentinel still catches the round-9 unquoted-heredoc bug
# (the recipe references $m, which would be unbound under set -u
# if the heredoc weren't quoted) and additionally pins '--index'.
assert_grep 'git stash pop --index "stash@{/$m}"' "$out" \
  "pre-commit prints recipe verbatim (round-9 sentinel, round-25 --index)"
# Round-25 negative pin: the bare 'git stash pop "stash@{/$m}"'
# (without --index) is the exact regression shape that breaks the
# follow-up 'git commit' step in the recipe. A 'grep -F' against
# the bare form anchored on the leading two-space indent (the
# recipe's indentation) catches it without false-positives from
# the surrounding prose, which uses backticks around 'stash@{/$m}'
# rather than the recipe's literal-quoted form.
set +e
grep -F '  git stash list | grep -qF "$m" && git stash pop "stash@{/$m}"' "$out" >/dev/null
grep_rc=$?; set -e
assert_eq 1 "$grep_rc" \
  "pre-commit recipe does not regress to bare 'git stash pop' without --index"
# Round-22 race-safety pin: the recipe must use a $$-salted marker
# rather than a stash-list count guard. A regression that reverts
# to 'n=$(git stash list | wc -l)' would leave 'git stash pop' open
# to the cross-worktree race documented on the new comment block.
set +e
grep -F 'n=$(git stash list | wc -l)' "$out" >/dev/null
grep_rc=$?; set -e
assert_eq 1 "$grep_rc" \
  "pre-commit recipe does not regress to the racy stash-count guard"
# Round-23 invocation-uniqueness pin: a bare 'm=park-pre-branch-$$'
# (without the '$(date +%s)' suffix) leaves a stale stash from an
# aborted earlier run in the same shell matchable by a later run's
# grep -qF, and the later run's pop applies the stale stash onto
# the new feature branch. This negative assertion catches a
# regression that drops the timestamp salt.
set +e
grep -E '^  m=park-pre-branch-\$\$$' "$out" >/dev/null
grep_rc=$?; set -e
assert_eq 1 "$grep_rc" \
  "pre-commit recipe does not regress to bare \$\$ marker"
git restore --staged a.txt
git checkout -q -- a.txt

# Legacy 'master' branch name is also covered by the main|master
# guard. Without this assertion a regression that drops the legacy
# alternation arm would leave Hooks-behaviour green even though the
# hook docs and message promise both branch names are protected.
git checkout -q -b master
echo master-change >> a.txt
git add a.txt
out="$WORK_DIR/pc_master.out"
set +e; git commit -m "should fail" >"$out" 2>&1; rc=$?; set -e
assert_eq 1 "$rc" "pre-commit refuses commit on master"
assert_grep "direct commits to 'master'" "$out" "pre-commit prints policy error for master"
git restore --staged a.txt
git checkout -q -- a.txt
git checkout -q main
git branch -q -D master

git checkout -q -b feat/test
echo more >> a.txt
git add a.txt
out="$WORK_DIR/pc_feat.out"
set +e; git commit -m "feature commit" >"$out" 2>&1; rc=$?; set -e
assert_eq 0 "$rc" "pre-commit allows commit on feature branch"

echo "=== pre-merge-commit ==="

# Build divergent history so `git merge` records a real merge commit
# (fast-forward merges record nothing and don't fire pre-merge-commit).
git checkout -q main
echo main-side > main.txt
git add main.txt
git -c core.hooksPath=/dev/null commit -q -m "main side"
git checkout -q feat/test
echo feat-side > feat.txt
git add feat.txt
git -c core.hooksPath=/dev/null commit -q -m "feat side"
git checkout -q main

out="$WORK_DIR/pmc_main.out"
set +e; git merge --no-ff feat/test -m "merge attempt" >"$out" 2>&1; rc=$?; set -e
assert_eq 1 "$rc" "pre-merge-commit refuses merge on main"
assert_grep "merging into 'main'" "$out" "pre-merge-commit prints policy error"
git merge --abort 2>/dev/null || true
git reset -q --hard HEAD

# Legacy 'master' branch name is also covered by the main|master
# guard. Without this assertion a regression that drops the legacy
# alternation arm would leave Hooks-behaviour green even though the
# hook docs and message promise both branch names are protected.
git checkout -q -b master
out="$WORK_DIR/pmc_master.out"
set +e; git merge --no-ff feat/test -m "merge attempt" >"$out" 2>&1; rc=$?; set -e
assert_eq 1 "$rc" "pre-merge-commit refuses merge on master"
assert_grep "merging into 'master'" "$out" "pre-merge-commit prints policy error for master"
git merge --abort 2>/dev/null || true
git reset -q --hard HEAD
git checkout -q main
git branch -q -D master

git checkout -q feat/test
git checkout -q -b feat/merge-target
git checkout -q feat/test
echo extra > extra.txt
git add extra.txt
git -c core.hooksPath=/dev/null commit -q -m "feat extra"
git checkout -q feat/merge-target
out="$WORK_DIR/pmc_feat.out"
set +e; git merge --no-ff feat/test -m "feature merge" >"$out" 2>&1; rc=$?; set -e
assert_eq 0 "$rc" "pre-merge-commit allows merge on feature branch"

echo "=== pre-push ==="

sha=$(git rev-parse HEAD)
zero=0000000000000000000000000000000000000000

out="$WORK_DIR/pp_main.out"
set +e
echo "refs/heads/feat/test $sha refs/heads/main $zero" \
  | "$HOOKS_DIR/pre-push" origin git@example.invalid:repo.git >"$out" 2>&1
rc=$?; set -e
assert_eq 1 "$rc" "pre-push refuses push to refs/heads/main"
assert_grep "refs/heads/main" "$out" "pre-push prints destination ref"
# The recovery recipe must drive its 'git push -u' line off the
# branch name extracted from local_ref (refs/heads/feat/test ->
# feat/test), not the ambient HEAD. A regression that reverts to
# 'git push -u origin HEAD' would publish the wrong branch when the
# refspec source is not the checked-out branch (e.g.
# `git push origin release:main` from another worktree).
assert_grep 'git push -u origin feat/test' "$out" \
  "pre-push recipe pushes the local_ref branch by name (main case)"
# Round-26 base-pin: the recipe must drive 'gh pr create --base'
# off the rejected destination, not let '--fill' fall through to
# the repo default branch. For the 'feat:main' shape the PR target
# happens to coincide with the default, so this pin is a no-op
# from the user's perspective -- but it locks in the explicit
# parameterisation so the master case below stays consistent.
assert_grep 'gh pr create --fill --base main' "$out" \
  "pre-push recipe targets PR at the rejected destination (main case)"

out="$WORK_DIR/pp_master.out"
set +e
echo "refs/heads/feat/test $sha refs/heads/master $zero" \
  | "$HOOKS_DIR/pre-push" origin git@example.invalid:repo.git >"$out" 2>&1
rc=$?; set -e
assert_eq 1 "$rc" "pre-push refuses push to refs/heads/master"
assert_grep "refs/heads/master" "$out" "pre-push prints destination ref for master"
assert_grep 'git push -u origin feat/test' "$out" \
  "pre-push recipe pushes the local_ref branch by name (master case)"
# Round-26 master-base pin: the user pushed to 'master' but
# 'gh pr create --fill' alone defaults to the repo's default
# branch ('main' in this repo). That silent retarget would land
# 'master'-intended work on 'main' with no signal to the user.
# '--base master' surfaces the intent: if 'master' exists on
# the remote, the PR opens there; if not, 'gh pr create' fails
# loudly rather than retargeting silently.
assert_grep 'gh pr create --fill --base master' "$out" \
  "pre-push recipe targets PR at the rejected destination (master case)"
# Negative pin: a regression that drops '--base $protected_branch'
# would emit the bare-fill form. Anchor on the recipe indent
# (two spaces) plus a trailing whitespace gap before the comment
# marker so the assertion does not collide with prose mentions
# of 'gh pr create --fill' elsewhere in the output.
set +e
grep -E '^  gh pr create --fill[[:space:]]+#' "$out" >/dev/null
grep_rc=$?; set -e
assert_eq 1 "$grep_rc" \
  "pre-push master recipe does not regress to bare 'gh pr create --fill'"
# Negative pin on the NO arm: the rejected push is 'feat/test:master'
# -- local refs/heads/master is untouched, so the epilogue's "reset
# local '$protected_branch'" cross-link must NOT fire here. A
# regression that re-emits the cross-link unconditionally would
# direct a contributor at the AGENTS.md "Recovery when the rule is
# broken" recipe (which resets local master to origin/master) for
# a push that did not put any commits on local master, potentially
# blowing away unrelated local work. The 'master:master' YES-arm
# coverage that pins the cross-link's *presence* lives in
# pp_master_local below; this assertion locks the suppression in
# on the NO arm.
set +e
grep -F "Recovery when the rule is broken" "$out" >/dev/null
grep_rc=$?; set -e
assert_eq 1 "$grep_rc" \
  "pre-push epilogue suppresses recovery cross-link on feat:master (NO-arm)"

# Pin the 'main:main' (and 'master:master') push shape: local_ref is
# refs/heads/main and remote_ref is refs/heads/main, so the recovery
# message must (a) tell the user to start the new feature branch from
# the local 'main' tip rather than ambient HEAD (HEAD may be checked
# out elsewhere; switching from HEAD would lose the rejected commits)
# and (b) push the new branch by name rather than 'HEAD'.
out="$WORK_DIR/pp_main_local.out"
set +e
echo "refs/heads/main $sha refs/heads/main $zero" \
  | "$HOOKS_DIR/pre-push" origin git@example.invalid:repo.git >"$out" 2>&1
rc=$?; set -e
assert_eq 1 "$rc" "pre-push refuses main:main push"
assert_grep 'git switch -c <type>/<short-slug> main' "$out" \
  "pre-push recipe branches from local_ref tip (not HEAD) for main:main"
assert_grep 'git push -u origin <type>/<short-slug>' "$out" \
  "pre-push recipe pushes the new branch by name for main:main"
# Positive pin on the YES arm: the rejected push originated from
# local refs/heads/main, so commits really did land on local 'main'
# and the recovery cross-link to AGENTS.md is the right next read.
# A regression that drops the cross-link on the YES arm would leave
# a 'main:main' pusher with only the in-arm "branch off the tip"
# advice and no pointer to the reset-local-main recipe.
assert_grep "Recovery when the rule is broken" "$out" \
  "pre-push epilogue emits recovery cross-link on main:main (YES-arm)"

# Round-24 master:master coverage: the inner 'refs/heads/main|
# refs/heads/master)' arm extracts $local_branch from $local_ref
# and uses it in 'git switch -c <type>/<short-slug> $local_branch'.
# The 'main:main' shape is pinned by pp_main_local above, but a
# regression that hardcodes 'main' in either the branch-off line
# or the recipe header would still pass that test. The hook only
# parses stdin, so 'master' need not exist locally -- the
# refspec strings are enough to drive the case-match through the
# 'refs/heads/main|refs/heads/master)' arm.
out="$WORK_DIR/pp_master_local.out"
set +e
echo "refs/heads/master $sha refs/heads/master $zero" \
  | "$HOOKS_DIR/pre-push" origin git@example.invalid:repo.git >"$out" 2>&1
rc=$?; set -e
assert_eq 1 "$rc" "pre-push refuses master:master push"
assert_grep 'git switch -c <type>/<short-slug> master' "$out" \
  "pre-push recipe branches from local_ref tip for master:master"
assert_grep "Your work is on local 'master'" "$out" \
  "pre-push recipe header names 'master' (not 'main') for master:master"
# Negative pin: a regression that hardcodes 'main' in the
# branch-off recipe would emit 'git switch -c <type>/<short-slug>
# main' here, telling a 'master' contributor to seed their branch
# from a ref that may not exist locally (the test repo deletes
# 'master' before reaching this point) and would discard the
# rejected commits if it did.
set +e
grep -F 'git switch -c <type>/<short-slug> main' "$out" >/dev/null
grep_rc=$?; set -e
assert_eq 1 "$grep_rc" \
  "pre-push master:master recipe does not seed branch from 'main'"
# Positive pin on the YES arm: same rationale as pp_main_local
# above, but locks in the master-side coverage. The cross-link
# fires here because local 'master' really did receive the
# rejected commits.
assert_grep "Recovery when the rule is broken" "$out" \
  "pre-push epilogue emits recovery cross-link on master:master (YES-arm)"
# Round-22 epilogue parameterisation pin (relocated from the NO
# arm pp_master): the shared epilogue's reset-pointer reference
# must be parameterised off remote_ref -- a regression that
# hardcodes 'origin/main' would send a 'master' contributor to
# the wrong reset target. The 'main' epilogue is implicitly
# covered by every other pp_main_local-side assertion; this one
# pins the 'master' arm. It belongs on the YES arm because the
# epilogue is now suppressed entirely on NO arms.
assert_grep "origin/master" "$out" \
  "pre-push epilogue points 'master' YES-arm pushers at origin/master, not origin/main"

# Pin the HEAD-shape recovery branch added to the recovery recipe.
# `git push <remote> HEAD:main` (or pushing from a detached HEAD) makes
# git pass local_ref=HEAD; the original 'git push -u $remote_name HEAD'
# recipe is wrong from detached HEAD and papers over the src:dst
# override otherwise. The fix routes that shape to a separate branch
# of the recovery message; this assertion locks the routing in so a
# regression that drops the case arm and falls back to the generic
# feature-branch recipe would fail here. The round-23 rewrite added
# an inner 'git symbolic-ref' resolution, so HEAD must be on a known
# branch to make the assertion deterministic; explicit checkout
# decouples this test from whatever the pre-merge-commit section
# left HEAD pointing at.
git checkout -q feat/test
out="$WORK_DIR/pp_head.out"
set +e
echo "HEAD $sha refs/heads/main $zero" \
  | "$HOOKS_DIR/pre-push" origin git@example.invalid:repo.git >"$out" 2>&1
rc=$?; set -e
assert_eq 1 "$rc" "pre-push refuses HEAD:main push"
assert_grep "HEAD points to 'feat/test'" "$out" \
  "pre-push routes HEAD push (attached to feature branch) to '*)' sub-arm"
assert_grep 'git push -u origin feat/test' "$out" \
  "pre-push HEAD '*)' sub-arm pushes the resolved branch by name"

# Round-23 HEAD-on-main routing pin: `git push <remote> HEAD:main`
# while local HEAD is attached to 'main' (or 'master') passes
# local_ref=HEAD just like the detached and feature-branch cases,
# but the recovery message must NOT suggest 'git push -u <remote>
# main' (which is the literal substitution a contributor reading
# the previous two-case message would make). The inner case must
# resolve HEAD via 'git symbolic-ref' and route the protected-
# branch attachment to the 'branch off the protected tip' recipe
# instead. Without coverage here a regression that drops the
# 'main|master)' sub-arm would leave Hooks-behaviour green.
git checkout -q main
out="$WORK_DIR/pp_head_on_main.out"
set +e
echo "HEAD $sha refs/heads/main $zero" \
  | "$HOOKS_DIR/pre-push" origin git@example.invalid:repo.git >"$out" 2>&1
rc=$?; set -e
assert_eq 1 "$rc" "pre-push refuses HEAD:main push from local main"
assert_grep "HEAD is attached to" "$out" \
  "pre-push HEAD-on-main routes to 'main|master' sub-arm (not '*)')"
assert_grep 'git switch -c <type>/<short-slug> main' "$out" \
  "pre-push HEAD-on-main recipe branches from local 'main' tip"
# Negative pin: a regression that drops the inner main|master arm
# and falls back to the '*)' sub-arm would emit
# 'git push -u origin main' here, re-pushing the protected branch.
set +e
grep -F 'git push -u origin main' "$out" >/dev/null
grep_rc=$?; set -e
assert_eq 1 "$grep_rc" \
  "pre-push HEAD-on-main does not emit 'git push -u origin main'"
git checkout -q feat/test

# Round-24 DETACHED sub-arm coverage: the round-23 'HEAD)' rewrite
# has three sub-arms ('main|master)', 'DETACHED)', '*)'). The
# 'main|master)' arm is pinned by pp_head_on_main and the '*)' arm
# by pp_head, but the 'DETACHED)' arm -- the original
# detached-HEAD recovery path that prompted the round-21 work in
# the first place -- has been untested since the round-23
# refactor. A regression that drops the case-arm or its body
# (e.g. emits the same '*)' fallback message for detached HEAD)
# would leave Hooks-behaviour green. Genuinely detach HEAD by
# pointing it at $sha rather than just simulating local_ref=HEAD;
# 'git symbolic-ref --short HEAD' in the hook will exit non-zero
# under detached HEAD and route into the 'DETACHED)' sub-arm.
git checkout -q --detach "$sha"
out="$WORK_DIR/pp_head_detached.out"
set +e
echo "HEAD $sha refs/heads/main $zero" \
  | "$HOOKS_DIR/pre-push" origin git@example.invalid:repo.git >"$out" 2>&1
rc=$?; set -e
assert_eq 1 "$rc" "pre-push refuses HEAD:main push from detached HEAD"
assert_grep 'pushed from detached HEAD' "$out" \
  "pre-push routes detached HEAD to 'DETACHED' sub-arm"
assert_grep 'git switch -c <type>/<short-slug>' "$out" \
  "pre-push DETACHED recipe attaches HEAD to a new feature branch"
# Negative pin: a regression that drops the 'DETACHED)' arm and
# falls back to the '*)' sub-arm would emit "HEAD points to
# 'DETACHED'" (the literal echo fallback in the hook's
# 'current_head=$(git symbolic-ref ... || echo "DETACHED")'
# expression) -- valid output but wrong recovery shape, since
# the '*)' recipe assumes HEAD points at a real branch by name.
set +e
grep -F "HEAD points to 'DETACHED'" "$out" >/dev/null
grep_rc=$?; set -e
assert_eq 1 "$grep_rc" \
  "pre-push DETACHED arm does not fall through to '*)' fallback message"
git checkout -q feat/test

# Pin the '(delete)' shape: `git push <remote> :main` (or `:master`)
# sets local_ref to the literal string '(delete)' and local_sha to
# 40 zeros. Before the round-21 fix, this fell into the generic '*)'
# arm and produced 'git push origin (delete)' as the recovery recipe,
# which is not a valid command. The fix routes the shape to its own
# arm with a "no recovery" message; these assertions pin (a) routing
# (the dead-end recipe substring is gone) and (b) the substantive
# message ("Deleting the protected branch is itself forbidden").
out="$WORK_DIR/pp_delete_main.out"
set +e
echo "(delete) $zero refs/heads/main $zero" \
  | "$HOOKS_DIR/pre-push" origin git@example.invalid:repo.git >"$out" 2>&1
rc=$?; set -e
assert_eq 1 "$rc" "pre-push refuses delete of refs/heads/main"
assert_grep "Deleting the protected branch is itself forbidden" "$out" \
  "pre-push routes ':main' delete shape to no-recovery message"
# Negative assertion: a regression that drops the '(delete)' arm and
# falls through to '*)' would emit this exact substring. grep -F with
# the parenthesised literal would succeed; we want it to fail (rc=1)
# so we invert with !.
set +e
grep -F 'git push origin (delete)' "$out" >/dev/null
grep_rc=$?; set -e
assert_eq 1 "$grep_rc" \
  "pre-push does not emit invalid 'git push origin (delete)' recipe"

out="$WORK_DIR/pp_delete_master.out"
set +e
echo "(delete) $zero refs/heads/master $zero" \
  | "$HOOKS_DIR/pre-push" origin git@example.invalid:repo.git >"$out" 2>&1
rc=$?; set -e
assert_eq 1 "$rc" "pre-push refuses delete of refs/heads/master"
assert_grep "Deleting the protected branch is itself forbidden" "$out" \
  "pre-push routes ':master' delete shape to no-recovery message"

# Round-22 non-branch-fallback pin: legitimate refspecs like
# 'git push origin v1.0:main' set local_ref to 'refs/tags/v1.0'
# (or any non-refs/heads/* ref) which falls into the '*)' arm of
# the inner case. Without coverage here, a regression that drops
# the '*)' arm would leave the recovery message blank for these
# shapes and Hooks-behaviour would still report green.
out="$WORK_DIR/pp_tag_main.out"
set +e
echo "refs/tags/v1.0 $sha refs/heads/main $zero" \
  | "$HOOKS_DIR/pre-push" origin git@example.invalid:repo.git >"$out" 2>&1
rc=$?; set -e
assert_eq 1 "$rc" "pre-push refuses non-branch ref pushed to main"
assert_grep 'not a branch under refs/heads/' "$out" \
  "pre-push routes non-branch refs to the fallback recovery message"
assert_grep 'git push origin refs/tags/v1.0' "$out" \
  "pre-push fallback recipe pushes the non-branch ref under its own name"

out="$WORK_DIR/pp_feat.out"
set +e
echo "refs/heads/feat/test $sha refs/heads/feat/test $zero" \
  | "$HOOKS_DIR/pre-push" origin git@example.invalid:repo.git >"$out" 2>&1
rc=$?; set -e
assert_eq 0 "$rc" "pre-push allows push to feature branch"

# Pin the remote-name parameterization added in the round-16 fix.
# Git invokes pre-push as `pre-push <remote-name> <remote-url>`; the
# recovery recipe must interpolate $1 so fork-remote contributors see
# accurate commands. A regression that hardcodes 'origin' again would
# leave the previous three tests green. The recipe pushes the
# local_ref branch by name (feat/test), not HEAD, per the round-20
# fix above.
out="$WORK_DIR/pp_main_fork.out"
set +e
echo "refs/heads/feat/test $sha refs/heads/main $zero" \
  | "$HOOKS_DIR/pre-push" fork git@example.invalid:fork.git >"$out" 2>&1
rc=$?; set -e
assert_eq 1 "$rc" "pre-push refuses push to main on alternate remote"
assert_grep 'git push -u fork feat/test' "$out" \
  "pre-push interpolates alternate remote name in recipe"
# Round-25 NO-arm epilogue suppression pin: the rejected push is
# 'feat/test:main' on remote 'fork' -- local refs/heads/main is
# untouched, so the entire "reset local '$protected_branch'"
# epilogue (and its fork-safety caveat) must be suppressed. A
# regression that re-emits the epilogue unconditionally would
# point a contributor at the AGENTS.md recovery recipe for a push
# that did not put commits on local main. The canonical-target
# property ('origin/main' rather than 'fork/main') still matters
# but now lives on the YES-arm pp_main_fork_local test below; on
# this NO arm we lock in *neither* string appearing.
set +e
grep -F 'fork/main' "$out" >/dev/null
grep_rc=$?; set -e
assert_eq 1 "$grep_rc" \
  "pre-push NO-arm fork epilogue suppressed: no 'fork/main' in output"
set +e
grep -F 'origin/main' "$out" >/dev/null
grep_rc=$?; set -e
assert_eq 1 "$grep_rc" \
  "pre-push NO-arm fork epilogue suppressed: no 'origin/main' in output"

# Round-25 YES-arm fork-remote pin: the rejected push is
# 'main:main' on remote 'fork' -- local refs/heads/main carries
# the rejected commits, so the recovery cross-link fires AND the
# fork-safety caveat applies (the reset target must be the
# canonical origin, not the destination remote). The earlier
# pp_main_fork covers the NO-arm suppression; this test covers the
# YES-arm where both the cross-link and the fork-safety property
# have observable work to do. A regression that hardcodes
# '$remote_name/$protected_branch' in the reset cross-link would
# emit 'fork/main' here and silently rewind a fork-pushing
# contributor's local 'main' to the fork's history.
out="$WORK_DIR/pp_main_fork_local.out"
set +e
echo "refs/heads/main $sha refs/heads/main $zero" \
  | "$HOOKS_DIR/pre-push" fork git@example.invalid:fork.git >"$out" 2>&1
rc=$?; set -e
assert_eq 1 "$rc" "pre-push refuses main:main push to alternate remote"
assert_grep "Recovery when the rule is broken" "$out" \
  "pre-push epilogue emits recovery cross-link on main:main fork (YES-arm)"
set +e
grep -F 'fork/main' "$out" >/dev/null
grep_rc=$?; set -e
assert_eq 1 "$grep_rc" \
  "pre-push YES-arm fork epilogue does not point reset at fork/main"
assert_grep 'origin/main' "$out" \
  "pre-push YES-arm fork epilogue points reset at origin/main (canonical)"

# Pin the ${1:-origin} fallback for the no-args invocation path. Some
# tooling (test harnesses, ad-hoc invocations, future shell wrappers)
# may run the script without args; the fallback must keep the recipe
# coherent rather than emitting a 'git push -u  feat/test' line.
out="$WORK_DIR/pp_main_noargs.out"
set +e
echo "refs/heads/feat/test $sha refs/heads/main $zero" \
  | "$HOOKS_DIR/pre-push" >"$out" 2>&1
rc=$?; set -e
assert_eq 1 "$rc" "pre-push refuses push to main with no-args invocation"
assert_grep 'git push -u origin feat/test' "$out" \
  "pre-push falls back to 'origin' when invoked with no args"

echo
echo "=== summary ==="
echo "passed: $pass"
echo "failed: $fail"
[ "$fail" -eq 0 ]

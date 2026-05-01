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
# 'n: unbound variable' under set -u, so this literal never appears.
assert_grep 'n=$(git stash list | wc -l)' "$out" "pre-commit prints recipe verbatim (round-9 sentinel)"
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

out="$WORK_DIR/pp_master.out"
set +e
echo "refs/heads/feat/test $sha refs/heads/master $zero" \
  | "$HOOKS_DIR/pre-push" origin git@example.invalid:repo.git >"$out" 2>&1
rc=$?; set -e
assert_eq 1 "$rc" "pre-push refuses push to refs/heads/master"

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
# leave the previous three tests green.
out="$WORK_DIR/pp_main_fork.out"
set +e
echo "refs/heads/feat/test $sha refs/heads/main $zero" \
  | "$HOOKS_DIR/pre-push" fork git@example.invalid:fork.git >"$out" 2>&1
rc=$?; set -e
assert_eq 1 "$rc" "pre-push refuses push to main on alternate remote"
assert_grep 'git push -u fork HEAD' "$out" "pre-push interpolates alternate remote name in recipe"

# Pin the ${1:-origin} fallback for the no-args invocation path. Some
# tooling (test harnesses, ad-hoc invocations, future shell wrappers)
# may run the script without args; the fallback must keep the recipe
# coherent rather than emitting a 'git push -u  HEAD' line.
out="$WORK_DIR/pp_main_noargs.out"
set +e
echo "refs/heads/feat/test $sha refs/heads/main $zero" \
  | "$HOOKS_DIR/pre-push" >"$out" 2>&1
rc=$?; set -e
assert_eq 1 "$rc" "pre-push refuses push to main with no-args invocation"
assert_grep 'git push -u origin HEAD' "$out" "pre-push falls back to 'origin' when invoked with no args"

echo
echo "=== summary ==="
echo "passed: $pass"
echo "failed: $fail"
[ "$fail" -eq 0 ]

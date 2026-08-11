# Contributing

Contributions are welcome. This repository has an established set of
conventions, and changes are expected to conform to them — the rules
below are prescriptive, not a starting point for negotiation. Reading
this page end to end takes a few minutes and avoids almost every
avoidable round of review.

[DEVELOPMENT.md](DEVELOPMENT.md) is the authoritative reference for the
toolchain, the CI matrix, and the branch-protection configuration. This
page is the short path; where the two disagree, `DEVELOPMENT.md` wins.

## Prerequisites

- **Flutter ≥ 3.38.0** (Dart ≥ 3.10) on the `stable` channel — that is
  the constraint `pubspec.yaml` declares. CI runs the latest `stable`
  plus 3.38.10, the oldest stable release satisfying that constraint,
  as a second matrix leg.
- **`rustup` on your `PATH`.** Do not install or select a Rust
  toolchain manually — `rust/rust-toolchain.toml` pins the version and
  rustup resolves it automatically on the first build. See the
  README's [Prerequisites](README.md#prerequisites) for the install
  steps.
- **`cargo-audit`** (`cargo install cargo-audit --locked`), only if
  your change touches `rust/Cargo.toml` or `rust/Cargo.lock`.
- **The [GitHub CLI](https://cli.github.com) (`gh`)** is optional. The
  commands below use it because it is the shorter path; every step it
  performs can be done from the GitHub web UI instead.

Nothing else is required to build, test, or submit a change. In
particular, the issue-tracking services the maintainer runs — Beads,
Dolt, and Linear — are **not** contributor prerequisites: `.beads/` is
inert in a clone that has no `bd` installed, and no git hook or CI job
invokes any of the three. SonarCloud does run as a CI step, but it
probes for `SONAR_TOKEN` and skips itself when the secret is absent,
which is always the case for pull requests from a fork; it is not a
required check. Sections of `AGENTS.md` and `CLAUDE.md` that describe
those tools are maintainer workflow; ignore them.

## One-time setup per clone

```bash
git config core.hooksPath tool/hooks
```

Git deliberately does not version `.git/hooks/`, so this opt-in has to
be re-run on every fresh clone. The hooks refuse commits and pushes on
`main` and `master`. Without them, a direct push to `main` is still
refused by branch protection on the remote — a slower and messier
recovery — but `master` carries no remote-side rule in this
repository, so the hooks are its only guard.

Verify with `git config --get core.hooksPath`, which must print
`tool/hooks`.

## The change loop

`main` is protected. Never commit to it directly — start every change
by branching:

```bash
git switch -c <type>/<short-slug>
# ... make edits, run the gates below ...
git push -u origin HEAD
gh pr create --fill   # or open the PR from the GitHub web UI
```

`<type>` is one of `feat`, `fix`, `refactor`, `chore`, `test`, or
`docs`, matching the commit-message convention. The PR title follows
`<type>: <imperative summary>`.

Pull requests are squash-merged; `main` keeps a linear history. Keep
each PR to a single coherent change — a refactor and a behaviour fix
belong in separate pull requests.

## Quality gates

Run the gates relevant to your change before pushing. The full list,
with the conditions under which each applies, is in
[DEVELOPMENT.md](DEVELOPMENT.md#contribution-workflow); the common
subset is:

```bash
dart format --output=none --set-exit-if-changed .
dart analyze .
flutter test --coverage

# Rust-touching changes
(cd rust && cargo build --locked && cargo test --lib --locked)
(cd rust && cargo clippy --lib --tests --locked -- -D warnings)

# Any change to rust/src/api/** or lib/src/ffi/**
dart run tool/check_bindings.dart

# Any change to tool/hooks/**
sh -n tool/hooks/pre-commit tool/hooks/pre-merge-commit tool/hooks/pre-push
sh tool/hooks/test_hooks.sh
```

`.github/pull_request_template.md` carries the canonical checklist.
Tick the boxes you actually ran; do not blanket-check the rest.

## What CI requires

Six status checks gate the merge: `Detect changed paths`,
`Dart tests gate`, `Verify FRB bindings are in sync`, `Rust build +
tests + coverage`, `Hooks shell-syntax check`, and `Hooks behaviour
check`. Doc-only diffs still run the workflow, but the heavy jobs skip
and report as passing.

Approvals are not required — green CI is the gate. Maintainers merge;
please do not expect to self-merge on a first contribution.

## Code conventions

- **Dart** — single-quoted string literals (`prefer_single_quotes` is
  enforced), dartdoc on every public member (`public_member_api_docs`
  is enforced by the analyzer), 80-column lines.
- **Rust** — no new `#[allow(...)]` in hand-written code. Local
  suppressions use `#[expect(lint, reason = "...")]`; see
  [Lint suppression policy](DEVELOPMENT.md#lint-suppression-policy).
- **Secret material** — AEAD keys, NTS cookies, TLS exporter output,
  and custom root bytes are subject to the zeroization rules in
  `AGENTS.md` ("Security: Zeroization"). Read that section before
  touching anything under `rust/src/nts/`.
- **Generated bindings** — never hand-edit `lib/src/ffi/**` or
  `rust/src/frb_generated.rs`. Change the Rust API and regenerate with
  `dart run tool/check_bindings.dart`, committing the result.

## Changelog and versioning

Add an entry to `CHANGELOG.md` under the next intended release header
(e.g. `## 9.2`). Do **not** create an `## Unreleased` section.

Do **not** bump the `version:` field in `pubspec.yaml` or the
`version = ` field in `rust/Cargo.toml`. This project bumps versions
only in a dedicated release commit; a bump in a feature PR will be
reverted. The full policy is in `AGENTS.md` under "Versioning &
Release Policy".

## Reporting bugs and security issues

Functional bugs and feature requests belong in
[GitHub issues](https://github.com/nick-llewellyn/nts/issues).

Do **not** report security vulnerabilities publicly. Use the process in
[SECURITY.md](SECURITY.md) — private vulnerability reporting or email.

## Licence

Contributions are accepted under the repository's MIT
[LICENSE](LICENSE).

# Copilot instructions for `nts`

`nts` is a Dart/Flutter package wrapping a Rust NTS (Network Time
Security, RFC 8915) client. Dart and Rust meet at a
`flutter_rust_bridge` boundary with generated bindings on both sides.

## Code review

Follow [`.github/skills/code-review/SKILL.md`](skills/code-review/SKILL.md)
when reviewing a pull request. It is the authoritative protocol, and it
carries two reference files:

- [`architecture.md`](skills/code-review/architecture.md) — the
  architecture-specific checks: FFI boundary and generated-binding
  drift, the sealed `NtsError` hierarchy, the two `TrustMode` fallback
  paths, zeroization, versioning, and CHANGELOG placement.
- [`output-format.md`](skills/code-review/output-format.md) — the
  mandatory summary-comment format.

Two rules from those files, restated here because they govern every
review:

**Report every finding.** Do not withhold an observation because your
internal confidence in it is low. State the uncertainty in the finding
and let the developer adjudicate. Four suppressed low-confidence
comments on PR #292 were all valid, and two were substantive.

**Use the mandatory output format.** Every review posts a summary
comment with an executive summary and an explicit verdict (**Ready to
Merge**, **Changes Requested**, or **Needs Clarification**), findings
grouped by severity (Critical/Bug, Documentation, Test Coverage,
Optimization), a per-finding action line (*Fix required before merge*,
*Consider for follow-up*, or *Clarification requested*), and a
`## Review Status` section stating whether a re-review is expected and
naming any check that could not be completed.

## Repository conventions

These apply to review comments and to any code Copilot writes.

### Generated files

`lib/src/ffi/` and `rust/src/frb_generated.rs` are generated from
`rust/src/api/`. Never hand-edit them. Regenerate with `dart run
tool/check_bindings.dart` — not bare `flutter_rust_bridge_codegen`,
which drops the script's diagnostic-message patches — and let the
"Verify FRB bindings are in sync" CI check confirm.

### Versioning

Release-only bumping. Do not change `version:` in `pubspec.yaml` or
`version` in `rust/Cargo.toml` in a feature, fix, or refactor PR —
bumps land in a dedicated release commit. The Dart package and the
Rust crate version independently.

CHANGELOG entries go under the next intended release header (e.g.
`## 9.1`), never under `## Unreleased`.

### Sealed types

`NtsError` in `lib/src/api/errors.dart` is sealed with ten variants.
Adding one is a breaking change for any consumer with an exhaustive
switch, and needs a CHANGELOG entry saying so.

Prefer exhaustive switches with no wildcard arm over `_ =>` defaults,
including in tests — the wildcard is what lets a new variant land
silently.

### Secret handling

Heap-allocated secret bytes (AEAD keys, cookies, TLS exporter output,
user-supplied root certificates) are wrapped in `Zeroizing`, built
without vector growth (`to_vec()` / `clone()` / `vec![0u8; N]`, never
`push` / `extend` / `reserve`), and given a manual redacted `Debug`
impl. `zeroize` is pinned `>= 1.8` because earlier versions do not wipe
`Vec` spare capacity. `AGENTS.md` has the full policy.

Never write a secret value into a log line, panic message, shell
command, or PR comment.

### Style

Dart: 80-column lines, `dart format` clean, `flutter_lints`. Rust:
`cargo fmt`, `cargo clippy -D warnings`.

Comments explain *why*, not *what*. Match the density of the
surrounding code — this codebase documents non-obvious rationale
thoroughly and does not narrate mechanics.

### Pull requests

`main` is protected. Work lands through a PR from a branch named
`<type>/NTS-<n>-<slug>`; the Linear identifier in the branch name is
what links the PR to its issue.

## Quality gates

Run from the repository root unless noted:

```bash
dart format --output=none --set-exit-if-changed .
dart analyze
dart run tool/check_doc_snippets.dart

(cd example && flutter test)         # example app suite
(cd rust && cargo fmt --check && cargo clippy --all-targets -- -D warnings)
(cd rust && cargo test)
```

`DEVELOPMENT.md` is authoritative for the full gate list and the
branch-protection table.

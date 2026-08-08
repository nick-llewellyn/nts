---
applyTo: "**/*.dart"
description: Review and authoring guidance for the Dart package and example app, covering the sealed NtsError hierarchy, generated bindings, and public API documentation.
---

# Dart review guidance

Full checks in
[`.github/skills/code-review/architecture.md`](../skills/code-review/architecture.md).

## Generated bindings

`lib/src/ffi/` is generated from `rust/src/api/`. Never hand-edit it — a
diff there that does not correspond to a Rust-side change will be
overwritten by the next codegen run. Report it as Critical/Bug.

Regeneration is `dart run tool/check_bindings.dart`, never bare
`flutter_rust_bridge_codegen`; the script applies patches that give the
generated catch-all arms real diagnostic messages, and running codegen
directly drops them.

## The sealed `NtsError` hierarchy

`lib/src/api/errors.dart` declares `NtsError` as `sealed` with ten
variants: `InvalidSpec`, `Network`, `KeProtocol`, `NtpProtocol`,
`Authentication`, `Timeout`, `NoCookies`, `TrustBackendUnavailable`,
`Internal`, `AbiMismatch`.

- **Adding a variant is a breaking change.** Every consumer with an
  exhaustive switch fails to compile. It needs a major-version
  CHANGELOG entry saying so, following how `AbiMismatch` was introduced
  in 8.0.0, and a dartdoc comment naming the version.
- **Prefer no wildcard arm.** A `_ =>` or `default:` in a switch over
  `NtsError` defeats the compile-time gate that makes adding a variant
  visible. Occasionally correct; flag it and ask.
- **Do not report missing arms in non-test code.** The analyzer errors
  on those, and the compile failure is the report.
- **Hand-maintained lists are the real risk.** Any list of variants,
  tags, or severities written out by hand can drift from the type it
  mirrors, and the analyzer cannot see it. It has already happened
  once: the tag-collision test omitted `AbiMismatch`.
  `_allNtsErrors` in `example/test/nts_format_test.dart` is the pattern
  to follow — an exhaustive `_variantKind` switch with no wildcard for
  the analysis-time half, plus a runtime test asserting the samples map
  onto `_NtsErrorKind.values` for the other half. A new hand-maintained
  list without an equivalent guard is a Test Coverage finding.
- **`errorTypeName` tags stay unique.** The namespace also holds
  `TrustBackendMismatch` and the CLI's synthetic `Unhandled` tag, which
  is not a sealed variant. A collision breaks log parsing silently.

## Public API

Public members carry dartdoc. Where behaviour differs by version, the
doc says which version introduced the change — the existing `NtsError`
variant docs are the model.

Argument validation happens in the Dart wrapper before FFI dispatch
(port range, timeout and concurrency bounds) and raises
`NtsErrorInvalidSpec`. Where a *newly added* parameter carries a
constraint Dart can check — a numeric range, a non-empty string, a
mutually-exclusive combination — that check belongs in the wrapper;
deferring it to Rust produces a worse diagnostic. Parameters with no
Dart-checkable constraint (booleans, enums, opaque handles) need no
wrapper check, and adding one would be noise.

## Style

80-column lines, `dart format` clean, `flutter_lints`. Prefer small
private widget classes over helper methods returning a `Widget`.
`const` constructors where possible.

Comments explain *why*. Match the surrounding density — this codebase
documents non-obvious rationale thoroughly and does not narrate
mechanics. Do not add trailing comments.

## Docs and tests

`dart` code fences in `README.md`, `CHANGELOG.md`, `ARCHITECTURE.md`,
and `example/example.md` are extracted and analyzed by
`tool/check_doc_snippets.dart` in CI. A snippet using an API changed by
the PR will fail there.

The example app has its own `pubspec.yaml` and test suite:

```bash
cd example && flutter test
```

Help text in `README.md` must match the actual parsing in
`example/bin/nts_cli.dart`. Verify against the parser, not against the
diff — this pair has drifted before.

<!--
Title format: <type>: <imperative summary>
  e.g. `fix: drop TLS 1.2 from rustls protocol versions`
       `feat: expose AesSivCmac256 in the Dart NtsKeyMaterial wrapper`
       `chore: bump flutter_rust_bridge pin from 2.12.0 to 2.13.0`
-->

## Description

<!--
What changed and why. Lead with the user-visible effect (or the bug
symptom this fixes), then the mechanism. Link the beads ticket if
this resolves one: `Closes nts-xxx`.
-->

## Type of Change

<!-- Mark one with [x]; delete the rest. -->

- [ ] **Bug fix** — non-breaking change that fixes an issue
- [ ] **Feature** — non-breaking change that adds functionality
- [ ] **Chore** — refactor, CI, docs, dependency bump, or other
      maintenance with no observable runtime effect
- [ ] **Breaking change** — fix or feature that would change existing
      public API behavior (requires major version bump)

## Testing Performed

<!--
List the gates run locally. Cross out anything that doesn't apply.
The CI matrix re-runs the Dart legs on Flutter 3.41.7 (.fvmrc pin)
and 3.38.10 (declared SDK floor) -- if a leg fails only on the
floor, that's a real signal, not a flake.
-->

- [ ] `dart format --output=none --set-exit-if-changed .`
- [ ] `dart analyze .`
- [ ] `flutter test --coverage` (Dart smoke tests in mock-mode FRB;
      mirrors CI and emits `coverage/lcov.info`)
- [ ] `(cd example && flutter pub get && flutter analyze)`
- [ ] `(cd rust && cargo build --locked && cargo test --lib --locked)`
      (Rust-touching changes)
- [ ] `dart run tool/check_bindings.dart` (any change to
      `rust/src/api/**` or hand-edits under `lib/src/ffi/**`)
- [ ] `(cd rust && cargo tarpaulin --lib --locked --skip-clean --out Lcov --output-dir coverage)`
      (mirrors CI; emits `rust/coverage/lcov.info`)
- [ ] Manual run on a real device / Simulator / Emulator <!-- describe -->

## Checklist

<!-- Required for every PR. Skipped items must be justified inline. -->

- [ ] Public API additions / changes have dartdoc comments
      (`public_member_api_docs` is enforced by the analyzer)
- [ ] `CHANGELOG.md` updated under the next-release section
- [ ] `pubspec.yaml` `version:` bumped following semver
      (patch for fixes, minor for features, major for breaking changes)
- [ ] If `rust/src/api/**` changed, `flutter_rust_bridge_codegen
      generate` was rerun and the regenerated `lib/src/ffi/**` and
      `rust/src/frb_generated.rs` are committed (no drift in CI)
- [ ] If the `flutter_rust_bridge` pin moved, both
      `pubspec.yaml` (Dart) and `rust/Cargo.toml` (Rust `=2.x.y`)
      were bumped together
- [ ] If the SDK floor was raised, `pubspec.yaml` constraints and
      `.github/workflows/ci.yml` matrix entries were updated together

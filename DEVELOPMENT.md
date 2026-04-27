# Development

Toolchain, codegen, and logging workflows for contributors to the `nts`
package. API consumers do not need any of this — `flutter pub add nts`
plus the [Getting Started](README.md#getting-started) snippet is the
full integration path. See [ARCHITECTURE.md](ARCHITECTURE.md) for the
layering this document operates on.

## Working with the Rust bridge

Three tools, distinct roles.

| Tool | Purpose | When to run |
|------|---------|-------------|
| `cargo` (in `rust/`) | Manage Rust deps, run unit tests | During Rust development |
| `flutter_rust_bridge_codegen` | Regenerate Dart bindings | After any change to `rust/src/api/*.rs` |
| `tool/check_bindings.dart` | Verify committed bindings match the generator | Before pushing changes that touch `rust/src/api/*.rs` |
| `hook/build.dart` (Native Assets) | Compile + bundle the dylib for Flutter | Automatically on `flutter build` |

### Regenerate bindings

```bash
flutter_rust_bridge_codegen generate
```

Commit the regenerated `lib/src/ffi/**` and `rust/src/frb_generated.rs`.

### Verify bindings are in sync

```bash
dart run tool/check_bindings.dart
```

Mirrors CI's drift check: regenerates bindings, applies the lint-suppression
patches that FRB cannot emit on its own (see `_lintIgnorePatches` in the
script), runs `dart format` on the output, then `git diff --exit-code`
against the watched paths. Exits non-zero with the same error message CI
emits when `lib/src/ffi/` or `rust/src/frb_generated.rs` differ from the
committed state. The pinned codegen version is read from `pubspec.yaml`
so the script and CI stay in lockstep.

#### Post-codegen lint-suppression patches

`flutter_rust_bridge_codegen` does not propagate Rust struct/enum
docstrings to its synthesized freezed sealed class wrappers and
auto-generated default constructors. pana scores the generated bindings
with a stricter ruleset than `flutter_lints` and fires
`public_member_api_docs` for every undocumented public member of those
positions (~120 lints in `lib/src/ffi/api/nts.dart` alone). Since the
underlying lints cannot be fixed at the Rust source, the script appends
the offending rule names to the file-level `// ignore_for_file:`
directive after each codegen run. The patch table lives in
`_lintIgnorePatches` and is idempotent: re-running adds nothing if the
rule is already present. If FRB ever emits the missing docs natively,
remove the corresponding entry from the table.

### Rust unit tests (no Flutter required)

```bash
cd rust && cargo test
```

### Smoke test the Dart bindings

```bash
flutter test
```

This runs `test/ffi_smoke_test.dart`, which exercises the generated
FRB API contract in mock mode. Live Dart→Rust→network round-trips
run from the example app (`example/`); the underlying Rust crate has
its own live integration probes gated behind `--ignored` (run with
`cargo test --ignored` in `rust/`).

## Rust log verbosity

The Rust crate is compiled in one of two configurations, selected by
the `verbose_logs` Native Assets user-define in the consuming app's
`pubspec.yaml`:

| `verbose_logs` | Cargo profile | `log-strip` feature | Visible log levels |
|----------------|---------------|---------------------|--------------------|
| `false` (default) | `--release` | active | `warn!` / `error!` only |
| `true` | debug | dropped (`--no-default-features`) | all (`trace!` upward, incl. `rustls`) |

The default produces a stripped binary: `release_max_level_warn` is
compiled in via the `log-strip` Cargo feature, eliding `info!` /
`debug!` / `trace!` call sites at compile time. On iOS / Android the
shipped binary is also obfuscated by IXGuard / DexGuard; the strip is
the load-bearing protection on **desktop and future web** targets,
where those obfuscators are not in play.

### Enabling verbose logs locally

To see `rustls` handshake traces and the crate's own `info!` / `debug!`
events on iOS Console.app (subsystem `com.nts.example`) or
Android `logcat`, edit the example app's pubspec and rebuild:

```yaml
# example/pubspec.yaml
hooks:
  user_defines:
    nts:
      verbose_logs: true   # <- flip this
```

```bash
cd example
flutter clean              # drop the Native Assets hook cache
flutter run                # rebuilds rust/ without --release and
                           # without log-strip default features
```

Restore `verbose_logs: false` before committing or shipping. The
default-off posture means any pipeline that does not explicitly opt
in (CI, app-store builds, downstream embedders) still gets the
stripped release binary.

`hook/build.dart` is the authoritative wiring; the toggle is
deliberately a manual pubspec edit rather than a separate Flutter
flavor so the production-vs-developer split is visible at the call
site.

## Continuous integration

`.github/workflows/ci.yml` runs four jobs on every push to `main` and
every pull request:

| Job | Cost | Purpose |
|-----|------|---------|
| `changes` | ~5 s | Classifies the diff via `dorny/paths-filter`; outputs `rust`, `bindings`, `ci` flags consumed by the gates below. |
| `build` | ~3–5 min × 2 | Dart format / analyze / `flutter test` on the SDK floor (3.38.10) and the pinned current (3.41.7). Always runs. |
| `rust` | ~5–8 min | `cargo build --locked` + `cargo test --lib` on Linux. Gated. |
| `rust-bridge-sync` | ~5–10 min | Runs `tool/check_bindings.dart` to assert the committed bindings match what the generator produces. Gated. |

### Filter-driven gating

The expensive Rust jobs are skipped unless the diff actually requires
them. Filters and gates:

| Filter | Watches | Gates |
|--------|---------|-------|
| `rust` | `rust/**`, `hook/**`, `flutter_rust_bridge.yaml`, `pubspec.yaml` | `rust`, `rust-bridge-sync` |
| `bindings` | `lib/src/ffi/**`, `tool/check_bindings.dart` | `rust-bridge-sync` |
| `ci` | `.github/workflows/**` | `rust`, `rust-bridge-sync` |

`pubspec.yaml` lives in the `rust` filter because the
`flutter_rust_bridge: 2.12.0` exact pin sits there; bumping it must
trigger a full Rust + drift run. `workflow_dispatch` (manual reruns
from the Actions UI) bypasses every gate so a forced run executes
the full pipeline.

GitHub treats skipped jobs as passing for branch-protection purposes,
so existing required-check rules continue to work unchanged.

### Trigger-level skips

Two cheaper filters run before the workflow even queues:

- **`paths-ignore`** (`.github/workflows/ci.yml`): doc / metadata
  paths — `**.md`, `LICENSE`, `.gitignore`, `.beads/**`,
  `screenshots/**` — never trigger a workflow run.
- **`[skip ci]` commit-message flag**: any commit whose message
  contains `[skip ci]`, `[ci skip]`, `[no ci]`, `[skip actions]`, or
  `[actions skip]` is bypassed by GitHub Actions. Prefer this only
  when `paths-ignore` doesn't cover the case (e.g. a single commit
  that touches both an ignored file and a non-ignored one but is
  known to be CI-irrelevant).

### When to use each layer

| Change | Behaviour |
|--------|-----------|
| Doc-only edit (`README.md`, `ARCHITECTURE.md`, …) | Workflow doesn't run (`paths-ignore`). |
| Beads issue update (`.beads/**`) | Workflow doesn't run (`paths-ignore`). |
| Screenshot asset swap (`screenshots/**`) | Workflow doesn't run (`paths-ignore`). |
| Pure Dart edit outside `lib/src/ffi/` | `build` runs; `rust` and `rust-bridge-sync` skip. |
| Rust source change (`rust/src/**`) | All three runtime jobs run. |
| Hand-edit of generated bindings | `build` and `rust-bridge-sync` run; `rust-bridge-sync` will fail with a drift error (regenerate via `flutter_rust_bridge_codegen generate` instead). |
| `pubspec.yaml` edit | All three runtime jobs run (FRB pin sits there). |
| Workflow file edit | All three runtime jobs run (validates the change end-to-end). |

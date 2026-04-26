// Native Assets build hook for `nts`.
//
// Compiles the sibling `rust/` Cargo crate via `native_toolchain_rust` and
// registers its dynamic library as a Code asset that the Flutter tool then
// bundles into the app for the target platform. This removes the manual
// `cargo build --release` + `DYLD_LIBRARY_PATH=…` dance that the example
// app currently documents in its README.
//
// Behaviour summary: invoke `cargo build [--release] --target <triple>`
// against `rust/` and emit the `cdylib` (`.dylib` on Apple, `.so` on
// Linux/Android, `.dll` on Windows) keyed off the host/target the SDK
// requested. The release/debug split is driven by the `verbose_logs`
// user-define documented below; the `hooks: ^1.0.3` API does not expose
// a separate dry-run / declare-only mode at this layer.
//
// Cross-compile targets are pinned in `rust/rust-toolchain.toml`; this hook
// itself is host-OS-agnostic. `cratePath` defaults to `rust` (which matches
// our layout) so we leave it unset and let `native_toolchain_rust` discover
// the crate.
//
// Coupling with flutter_rust_bridge: the FRB-generated loader in
// `lib/src/ffi/frb_generated.dart` references the asset id passed here.
// Keeping `assetName` as the path to the generated `.io.dart` matches the
// convention in `flutter_rust_bridge_codegen` examples; if FRB regen ever
// targets a different filename, update this string in lockstep.
//
// # `verbose_logs` user-define
//
// Flutter's `--debug`/`--release` mode is not propagated to
// native_assets hooks. The hooks API exposes `userDefines` (loaded
// from the consuming app's pubspec) as the only structured channel,
// so we use the `verbose_logs` key to flip the Rust crate between
// two configurations:
//
//   * `verbose_logs: false` (default, shipping builds):
//     - `BuildMode.release` → cargo `--release`.
//     - Default Cargo features active → `log-strip` enabled →
//       `release_max_level_warn` strips `info!`/`debug!`/`trace!`
//       at compile time. Mobile binaries are additionally protected
//       by DexGuard / IXGuard, but the strip is what matters on
//       desktop / future web targets where those obfuscators are
//       not in play.
//   * `verbose_logs: true` (developer instrumentation):
//     - `BuildMode.debug` → no `--release` flag.
//     - `--no-default-features` → `log-strip` dropped → all
//       `log::*!`/`tracing::*!` levels reach the platform
//       subscriber, including `rustls` protocol traces (its
//       `logging` feature stays on).
//
// To flip the toggle, edit the `hooks.user_defines.nts.verbose_logs`
// key in the consuming app's pubspec.yaml and run `flutter clean` so
// the Native Assets cache is dropped before the next build. See the
// package README for the full rationale.

import 'package:hooks/hooks.dart';
import 'package:native_toolchain_rust/native_toolchain_rust.dart';

Future<void> main(List<String> args) async {
  await build(args, (input, output) async {
    // The user-define is intentionally read with a permissive parser:
    // pubspec YAML can deliver booleans (`verbose_logs: true`),
    // strings (when piped from a CLI override), or the key may be
    // absent entirely (default builds, third-party embedders). Treat
    // anything that is not an explicit "true"-equivalent as the
    // production-safe path so the binary strip stays the default.
    final verboseLogsRaw = input.userDefines['verbose_logs'];
    final verboseLogs =
        verboseLogsRaw == true ||
        (verboseLogsRaw is String && verboseLogsRaw.toLowerCase() == 'true');

    final builder = RustBuilder(
      assetName: 'src/ffi/frb_generated.io.dart',
      // Flip both the cargo build profile *and* the feature set in
      // lockstep: a debug profile with `log-strip` still active would
      // be slower than release for no observability gain, and a
      // release profile without `log-strip` would leak protocol
      // traces from a binary we expect to ship. Keeping the two flags
      // co-varied here means there's exactly one place to reason
      // about the production-vs-development trade-off.
      buildMode: verboseLogs ? BuildMode.debug : BuildMode.release,
      enableDefaultFeatures: !verboseLogs,
    );
    await builder.run(input: input, output: output);
  });
}

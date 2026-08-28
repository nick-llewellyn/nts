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
// user-defined documented below; the `hooks: ^2.0.2` API does not expose
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
//
// # Android NDK floor
//
// Android 15+ requires 64-bit native libraries to be 16 KB page
// aligned. Nothing in this repository sets that alignment explicitly:
// it comes entirely from the NDK clang driver's default `-z
// max-page-size`, which was 4 KB through r27 and became 16 KB in r28.
// `native_toolchain_rust` validates the NDK only to r27 (its probe is
// for `<triple>35-clang`, introduced there), so a consumer app pinning
// `ndkVersion = "27.x"` would otherwise get a silently 4 KB-aligned
// `libnts_rust.so`. The check below reads the NDK revision out of the
// toolchain the SDK handed us and refuses to build under r28.

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:meta/meta.dart';
import 'package:native_toolchain_rust/native_toolchain_rust.dart';

/// Lowest Android NDK major version whose clang driver defaults to 16 KB
/// page alignment.
@visibleForTesting
const minimumAndroidNdkMajor = 28;

Future<void> main(List<String> args) async {
  await build(args, (input, output) async {
    if (input.config.code.targetOS == OS.android) {
      _checkAndroidNdkFloor(input.config.code.cCompiler?.compiler);
    }

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

// Resolves the NDK revision behind [compiler] and throws when it is
// below [minimumAndroidNdkMajor].
//
// Fails open at every step where the toolchain cannot be identified --
// a null compiler, an unrecognised directory layout, a missing or
// unparseable `source.properties`. A probe that cannot answer must not
// break builds on toolchain layouts we have not seen; the floor is
// enforced only when the revision is known and known to be too low.
void _checkAndroidNdkFloor(Uri? compiler) {
  final ndkRoot = androidNdkRoot(compiler);
  if (ndkRoot == null) return;
  final properties = File.fromUri(ndkRoot.resolve('source.properties'));
  if (!properties.existsSync()) return;
  final failure = androidNdkFloorFailure(properties.readAsStringSync());
  if (failure != null) {
    throw UnsupportedError(failure);
  }
}

/// Derives the NDK root from an NDK clang path, or `null` if [compiler]
/// does not sit in the layout the NDK ships.
///
/// `native_toolchain_rust` points the Rust linker at
/// `<ndk>/toolchains/llvm/prebuilt/<host>/bin/<triple>35-clang`, so the
/// root is five segments up. The intermediate segments are matched
/// rather than assumed: a compiler from anywhere else is not an NDK and
/// has no revision to read.
@visibleForTesting
Uri? androidNdkRoot(Uri? compiler) {
  if (compiler == null) return null;
  final segments = compiler.pathSegments;
  if (segments.length < 6) return null;
  final layout = segments.sublist(segments.length - 6, segments.length - 2);
  if (layout[0] != 'toolchains' ||
      layout[1] != 'llvm' ||
      layout[2] != 'prebuilt') {
    return null;
  }
  if (segments[segments.length - 2] != 'bin') return null;
  return compiler.resolve('../../../../../');
}

/// Reads `Pkg.Revision` out of an NDK [sourceProperties] and returns the
/// failure message for a revision below [minimumAndroidNdkMajor], or
/// `null` when the NDK is new enough or the revision cannot be read.
@visibleForTesting
String? androidNdkFloorFailure(String sourceProperties) {
  final revision = RegExp(
    r'^\s*Pkg\.Revision\s*=\s*(\S+)\s*$',
    multiLine: true,
  ).firstMatch(sourceProperties)?.group(1);
  if (revision == null) return null;
  final major = int.tryParse(revision.split('.').first);
  if (major == null || major >= minimumAndroidNdkMajor) return null;
  return 'Android NDK $revision is too old to build `nts`: r'
      '$minimumAndroidNdkMajor or newer is required.\n'
      'Android 15+ requires 64-bit native libraries to be 16 KB page '
      'aligned, and the NDK clang driver only defaults to a 16 KB '
      '`-z max-page-size` from r$minimumAndroidNdkMajor onwards. Building '
      '`libnts_rust.so` with NDK r$major would produce a 4 KB-aligned '
      'library that Google Play rejects.\n'
      "Set `ndkVersion` in your app's `android/app/build.gradle.kts` to "
      '`flutter.ndkVersion` (or to an installed r$minimumAndroidNdkMajor+ '
      'revision) and re-run the build.';
}

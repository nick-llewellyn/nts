// Shared FRB-bridge bootstrap for the example app's command-line tools.
//
// Both `bin/nts_cli.dart` and `bin/nts_health.dart` run via plain
// `dart run`, outside the Flutter engine and Native Assets pipeline, so
// they cannot rely on `NtsRustLib.init()` auto-resolving the bundled
// dylib the way the GUI does. This module centralises the two pieces
// they share: loading the host-arch dylib (or the in-memory mock) and
// locating it under the conventional `rust/target/release/` build path.
//
// Both functions terminate the process on an unrecoverable bootstrap
// failure (exit code 70) rather than throwing, because every caller
// would otherwise immediately print-and-exit identically — keeping that
// policy here ensures the two CLIs report load failures the same way.

import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;
import 'package:nts/nts.dart' show NtsRustLib;

import '../mock_api.dart';

/// Exit code used when the native engine itself fails to start. Mirrors
/// the value documented in `CLI_GUIDE.md`.
const int kExitBridgeFailure = 70;

/// Initialise the FRB bridge for a CLI invocation.
///
/// When [useMock] is set, binds the in-memory [MockNtsApi] (no native
/// dylib required). Otherwise loads the host-arch dylib from
/// [libraryPath] if given, falling back to [autoLocateDylib]. On any
/// unrecoverable failure (no dylib found, file missing, init threw) it
/// writes a diagnostic to stderr and exits with [kExitBridgeFailure].
Future<void> initBridge({
  required bool useMock,
  required String? libraryPath,
}) async {
  if (useMock) {
    NtsRustLib.initMock(api: MockNtsApi());
    return;
  }
  final resolved = libraryPath ?? autoLocateDylib();
  if (resolved == null) {
    stderr.writeln(
      'error: no nts_rust dylib found.\n'
      '       Build it with `cargo build --release` from the rust/\n'
      '       directory, pass --library <path>, or run with --mock.',
    );
    exit(kExitBridgeFailure);
  }
  if (!File(resolved).existsSync()) {
    stderr.writeln('error: dylib not found at $resolved');
    exit(kExitBridgeFailure);
  }
  try {
    await NtsRustLib.init(externalLibrary: ExternalLibrary.open(resolved));
  } catch (e) {
    stderr.writeln('error: failed to initialize Rust bridge: $e');
    exit(kExitBridgeFailure);
  }
}

/// Walk the well-known build locations for a host-arch dylib. Returns
/// the first match or null. Mirrors the Native Assets pipeline's stem
/// (`nts_rust`) and the `rust/target/release/` convention encoded in
/// `NtsRustLib.kDefaultExternalLibraryLoaderConfig`.
String? autoLocateDylib() {
  final ext = Platform.isMacOS
      ? 'dylib'
      : Platform.isWindows
      ? 'dll'
      : 'so';
  final prefix = Platform.isWindows ? '' : 'lib';
  final filename = '${prefix}nts_rust.$ext';
  // Search relative to (1) the example directory (`example/`), and
  // (2) the repo root — covers both `dart run bin/<tool>.dart` from the
  // example dir and `dart run example/bin/<tool>.dart` from the repo
  // root.
  final candidates = <String>[
    '${Directory.current.path}/../rust/target/release/$filename',
    '${Directory.current.path}/rust/target/release/$filename',
  ];
  for (final c in candidates) {
    if (File(c).existsSync()) return c;
  }
  return null;
}

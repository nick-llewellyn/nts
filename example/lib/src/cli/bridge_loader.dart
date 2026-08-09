// Shared FRB-bridge bootstrap for the example app's command-line tools.
//
// Both `bin/nts_cli.dart` and `bin/nts_health.dart` run via plain
// `dart run`, outside the Flutter engine and Native Assets pipeline, so
// they cannot rely on `NtsRustLib.init()` auto-resolving the bundled
// dylib the way the GUI does. This module centralises the pieces they
// share: loading the host-arch dylib (or the in-memory mock), locating
// it under the conventional `rust/target/release/` build path, and
// warning when that dylib predates the Rust sources it was built from.
//
// The freshness check exists because this path bypasses Native Assets
// entirely: `hook/build.dart` re-runs cargo (which tracks freshness
// itself) for GUI and package consumers, whereas these tools open
// whatever file happens to sit at the conventional path.
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
import '../state/nts_format.dart' show wipeRegisteredCustomRoots;

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
///
/// Every one of those exits runs before the caller can construct the
/// `NtsClient` that consumes a `--custom-roots` buffer, so each clears
/// any registered buffer via [wipeRegisteredCustomRoots] first — `exit`
/// terminates the VM without unwinding, leaving no later opportunity.
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
    wipeRegisteredCustomRoots();
    stderr.writeln(
      'error: no nts_rust dylib found.\n'
      '       Build it with `cargo build --release` from the rust/\n'
      '       directory, pass --library <path>, or run with --mock.',
    );
    exit(kExitBridgeFailure);
  }
  if (!File(resolved).existsSync()) {
    wipeRegisteredCustomRoots();
    stderr.writeln('error: dylib not found at $resolved');
    exit(kExitBridgeFailure);
  }
  final staleness = dylibStalenessWarning(resolved);
  if (staleness != null) {
    stderr.writeln(staleness);
  }
  try {
    await NtsRustLib.init(externalLibrary: ExternalLibrary.open(resolved));
  } catch (e) {
    wipeRegisteredCustomRoots();
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

/// Compare [dylibPath] against the Rust sources that produced it and
/// return a stderr-ready warning when it is older, or null when it is
/// current (or when the sources cannot be located, as with a dylib
/// passed via `--library` from outside the repo).
///
/// The dylib is expected at `<crate>/target/<profile>/<file>`, so the
/// crate root is three directories up; `src/` and `Cargo.toml` beneath
/// it are the inputs whose mtimes matter. Both must be present — a
/// `src/` without a `Cargo.toml` is some other project's layout, not a
/// crate this dylib could have been built from, and the rebuild
/// instruction would be wrong. Only a *newer source* is reported:
/// checking out an older revision leaves a newer dylib that is equally
/// wrong but indistinguishable by mtime, so this catches the forward
/// case (edit, forget to rebuild) rather than every case.
String? dylibStalenessWarning(String dylibPath) {
  final DateTime dylibStamp;
  try {
    dylibStamp = File(dylibPath).lastModifiedSync();
  } on FileSystemException {
    return null;
  }
  final crateRoot = Directory(dylibPath).parent.parent.parent;
  final manifest = File('${crateRoot.path}/Cargo.toml');
  if (!manifest.existsSync()) return null;
  final srcFiles = _listSources(Directory('${crateRoot.path}/src'));
  if (srcFiles == null) return null;
  final sources = <FileSystemEntity>[manifest, ...srcFiles];
  String? newest;
  DateTime? newestStamp;
  for (final s in sources) {
    final DateTime stamp;
    try {
      stamp = s.statSync().modified;
    } on FileSystemException {
      continue;
    }
    if (stamp.isAfter(dylibStamp) &&
        (newestStamp == null || stamp.isAfter(newestStamp))) {
      newest = s.path;
      newestStamp = stamp;
    }
  }
  if (newest == null) return null;
  return 'warning: $dylibPath is older than the Rust sources\n'
      '         that produced it (newest: $newest).\n'
      '         The bindings and the native library may disagree,\n'
      '         which surfaces as a decode error on every call.\n'
      '         Rebuild with `cargo build --release` from\n'
      '         ${crateRoot.path}.';
}

// Enumerate the crate's Rust sources, or null when `src/` is absent
// (dylib outside a crate tree — nothing to compare against).
List<FileSystemEntity>? _listSources(Directory src) {
  if (!src.existsSync()) return null;
  try {
    return src
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .toList();
  } on FileSystemException {
    return null;
  }
}

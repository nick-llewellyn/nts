// Coverage for the CLI bridge loader: the dylib freshness check, and
// the disposition a `--mock` run reaches for the bridge state it
// finds. The tools that use it run under plain `dart run`, outside the
// Native Assets pipeline, so nothing else keeps the loaded library in
// step with `rust/src/**`.
//
// The disposition group tests `mockBridgeDisposition` rather than
// `initBridge`, because the conflict arm of the latter ends in `exit`,
// which an in-process test cannot observe. The `initBridge` case below
// covers the one arm that returns: an installed mock being reused.
//
// Constructing a non-mock `NtsRustLibApi` means naming the internal
// api contract, the same way `lib/src/mock_api.dart` does.
// ignore_for_file: implementation_imports, invalid_use_of_internal_member

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:nts/src/ffi/frb_generated.dart' show NtsRustLib, NtsRustLibApi;
import 'package:nts_example/src/cli/bridge_loader.dart'
    show
        MockBridgeDisposition,
        dylibStalenessWarning,
        initBridge,
        mockBridgeDisposition;
import 'package:nts_example/src/mock_api.dart' show MockNtsApi;

/// Stand-in for the dylib-backed `NtsRustLibApiImpl`: anything that is
/// an `NtsRustLibApi` but not a [MockNtsApi]. Never dispatched
/// through — only its type is under test — so every member is left to
/// `noSuchMethod`.
class _NativeLikeApi implements NtsRustLibApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// Build a throwaway crate layout — `<root>/src/lib.rs`,
/// `<root>/Cargo.toml`, `<root>/target/release/libnts_rust.dylib` —
/// and return the dylib path. Timestamps are set explicitly so the
/// comparison under test does not depend on write ordering.
String _fixture(
  Directory root, {
  required DateTime dylib,
  required DateTime source,
}) {
  final release = Directory('${root.path}/target/release')
    ..createSync(recursive: true);
  final src = Directory('${root.path}/src')..createSync(recursive: true);

  final cargo = File('${root.path}/Cargo.toml')..writeAsStringSync('[package]');
  cargo.setLastModifiedSync(source);
  final lib = File('${src.path}/lib.rs')..writeAsStringSync('// lib');
  lib.setLastModifiedSync(source);

  final path = '${release.path}/libnts_rust.dylib';
  File(path)
    ..writeAsBytesSync(const [0])
    ..setLastModifiedSync(dylib);
  return path;
}

void main() {
  group('dylibStalenessWarning', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('nts_bridge_loader_test');
    });

    tearDown(() => root.deleteSync(recursive: true));

    test('returns null when the dylib is newer than every source', () {
      final path = _fixture(
        root,
        dylib: DateTime(2026, 7, 25, 12),
        source: DateTime(2026, 7, 20, 12),
      );
      expect(dylibStalenessWarning(path), isNull);
    });

    test('warns and names the newest source when the dylib is older', () {
      final path = _fixture(
        root,
        dylib: DateTime(2026, 7, 20, 12),
        source: DateTime(2026, 7, 25, 12),
      );
      // Push one source past the rest so the "newest" claim is
      // testable; with equal mtimes the first match legitimately wins.
      File(
        '${root.path}/src/lib.rs',
      ).setLastModifiedSync(DateTime(2026, 7, 26, 12));
      final warning = dylibStalenessWarning(path);
      expect(warning, isNotNull);
      expect(warning, contains('warning:'));
      expect(warning, contains(path));
      expect(warning, contains('cargo build --release'));
      expect(warning, contains('lib.rs'));
      // The rebuild instruction names the crate the dylib actually
      // came from, not a hard-coded `rust/` — a `--library <path>`
      // can point at a different crate entirely.
      expect(warning, contains(root.path));
    });

    test('detects a stale dylib from a nested source file', () {
      final path = _fixture(
        root,
        dylib: DateTime(2026, 7, 25, 12),
        source: DateTime(2026, 7, 20, 12),
      );
      final nested = Directory('${root.path}/src/api')
        ..createSync(recursive: true);
      File('${nested.path}/nts.rs')
        ..writeAsStringSync('// api')
        ..setLastModifiedSync(DateTime(2026, 7, 26, 12));
      expect(dylibStalenessWarning(path), contains('nts.rs'));
    });

    test('detects a stale dylib from Cargo.toml alone', () {
      final path = _fixture(
        root,
        dylib: DateTime(2026, 7, 25, 12),
        source: DateTime(2026, 7, 20, 12),
      );
      File(
        '${root.path}/Cargo.toml',
      ).setLastModifiedSync(DateTime(2026, 7, 26, 12));
      expect(dylibStalenessWarning(path), contains('Cargo.toml'));
    });

    test('stays quiet when the dylib sits outside a crate tree', () {
      // A `--library <path>` pointing at a prebuilt binary has no
      // sibling sources to compare against; that is not an error.
      final loose = File('${root.path}/libnts_rust.dylib')
        ..writeAsBytesSync(const [0]);
      expect(dylibStalenessWarning(loose.path), isNull);
    });

    test('stays quiet when src/ exists but Cargo.toml does not', () {
      // A `<root>/src` without a manifest is some other project's
      // layout, not a crate this dylib could have come from, so the
      // rebuild instruction would name the wrong directory.
      final path = _fixture(
        root,
        dylib: DateTime(2026, 7, 20, 12),
        source: DateTime(2026, 7, 25, 12),
      );
      File('${root.path}/Cargo.toml').deleteSync();
      expect(dylibStalenessWarning(path), isNull);
    });

    test('stays quiet when the dylib itself is missing', () {
      _fixture(
        root,
        dylib: DateTime(2026, 7, 25, 12),
        source: DateTime(2026, 7, 20, 12),
      );
      final absent = '${root.path}/target/release/absent.dylib';
      expect(dylibStalenessWarning(absent), isNull);
    });
  });

  group('mockBridgeDisposition', () {
    test('nothing installed -> fresh', () {
      expect(
        mockBridgeDisposition(initialized: false, api: null),
        MockBridgeDisposition.fresh,
      );
    });

    test('an installed mock -> reuse', () {
      expect(
        mockBridgeDisposition(initialized: true, api: MockNtsApi()),
        MockBridgeDisposition.reuse,
      );
    });

    test('an installed native api -> conflict', () {
      // The defect this guards: `initialized` alone is true for both,
      // so a `--mock` run would have reused the native bridge and
      // issued real handshakes against real servers.
      expect(
        mockBridgeDisposition(initialized: true, api: _NativeLikeApi()),
        MockBridgeDisposition.conflict,
      );
    });

    test('a subclassed mock still -> reuse', () {
      // Other suites install `MockNtsApi` subclasses to script the
      // bridge; the check is a subtype test, not an exact-type one.
      expect(
        mockBridgeDisposition(initialized: true, api: _ScriptedMockApi()),
        MockBridgeDisposition.reuse,
      );
    });
  });

  group('initBridge', () {
    // Installs for the process, and there is no de-init, so this is
    // the only arm of the mock path an in-process test can drive: the
    // conflict arm exits, and the fresh arm would consume the single
    // `initMock` slot this case needs.
    setUpAll(() => NtsRustLib.initMock(api: MockNtsApi()));

    test('reuses an installed mock instead of re-initialising', () async {
      final before = NtsRustLib.instance.api;
      await expectLater(
        initBridge(useMock: true, libraryPath: null),
        completes,
      );
      // A second `initMock` would throw a `StateError`; the installed
      // instance must also be the same one, not a replacement.
      expect(NtsRustLib.instance.api, same(before));
    });
  });
}

/// A [MockNtsApi] subclass, matching how the other suites script the
/// bridge, to pin that the disposition check accepts subtypes.
class _ScriptedMockApi extends MockNtsApi {}

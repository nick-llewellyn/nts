// Coverage for the CLI bridge loader's dylib freshness check. The
// tools that use it run under plain `dart run`, outside the Native
// Assets pipeline, so nothing else keeps the loaded library in step
// with `rust/src/**`.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nts_example/src/cli/bridge_loader.dart'
    show dylibStalenessWarning;

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
}

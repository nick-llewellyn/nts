// Unit tests for the Rust-intra-doc-link rewriter in
// `tool/check_bindings.dart`. FRB copies `rust/src/api/nts.rs` doc comments
// verbatim into `lib/src/ffi/api/nts.dart`, so the Dart mirror documents
// Dart APIs using Rust paths -- `[`NtsDnsPoolStats::spawn_failed`]` names
// no Dart member and renders as a dead reference. The rewriter resolves
// each path against a table *derived from the generated Dart* rather than
// from a casing rule, because FRB treats the shapes differently: plain
// enums become lowerCamelCase values, freezed sealed classes get named
// factories, a `#[frb(sync)]` `new` becomes the unnamed constructor.
//
// `@TestOn('vm')` matches the tool itself, which uses `dart:io`.
@TestOn('vm')
library;

import 'package:flutter_test/flutter_test.dart';

import '../tool/check_bindings.dart';

// A miniature stand-in for the generated bindings, carrying one instance
// of each shape the rewriter has to distinguish.
const _generated = '''
// These functions are ignored because they are not marked as `pub`: `checkout`, `ntp_short_signed_to_micros`
// These types are ignored because they are neither used by any `pub` functions: `QueryContext`

NtsDnsPoolStats ntsDnsPoolStats() => throw '';

Future<NtsTimeSample> ntsQuery({required int timeoutMs}) => throw '';

abstract class NtsClient implements RustOpaqueInterface {
  factory NtsClient() => throw '';

  static NtsClient withTrustMode({required TrustMode trustMode}) => throw '';

  Future<NtsTimeSample> query({required int timeoutMs});
}

class NtsDnsPoolStats {
  final BigInt recovered;

  final BigInt spawnFailed;
}

enum TrustBackend {
  platform,

  webpkiRoots,
}

@freezed
sealed class TrustMode with _\$TrustMode {
  const factory TrustMode.platformOnly() = TrustMode_PlatformOnly;
}
''';

void main() {
  final table = buildDartSymbolTable(const <String>[_generated]);

  group('buildDartSymbolTable', () {
    test('maps a snake_case struct field to its camelCase Dart field', () {
      expect(
        table.resolve('NtsDnsPoolStats::spawn_failed')?.dartPath,
        'NtsDnsPoolStats.spawnFailed',
      );
    });

    test('maps a PascalCase enum variant to its lowerCamelCase value', () {
      expect(
        table.resolve('TrustBackend::WebpkiRoots')?.dartPath,
        'TrustBackend.webpkiRoots',
      );
    });

    test('maps a sealed-class variant to its named factory', () {
      expect(
        table.resolve('TrustMode::PlatformOnly')?.dartPath,
        'TrustMode.platformOnly',
      );
    });

    test('maps a `#[frb(sync)]` `new` to the unnamed constructor', () {
      // FRB renders it as `NtsClient()`; `[NtsClient.new]` is dartdoc's
      // reference form for an unnamed constructor.
      expect(table.resolve('NtsClient::new')?.dartPath, 'NtsClient.new');
    });

    test('maps a snake_case method to its camelCase Dart name', () {
      expect(
        table.resolve('NtsClient::with_trust_mode')?.dartPath,
        'NtsClient.withTrustMode',
      );
    });

    test('maps a snake_case free function to its camelCase Dart name', () {
      expect(table.resolve('nts_query')?.dartPath, 'ntsQuery');
    });

    test('resolves a bare type name to itself', () {
      expect(table.resolve('NtsClient')?.dartPath, 'NtsClient');
    });

    test('resolves `Self::` against the enclosing class', () {
      expect(
        table
            .resolve('Self::recovered', enclosingClass: 'NtsDnsPoolStats')
            ?.dartPath,
        'NtsDnsPoolStats.recovered',
      );
    });

    test('leaves `Self::` unresolved with no enclosing class', () {
      expect(table.resolve('Self::recovered'), isNull);
    });

    test('records the items FRB reported as excluded', () {
      expect(table.isFrbIgnored('ntp_short_signed_to_micros'), isTrue);
      expect(table.isFrbIgnored('QueryContext'), isTrue);
      expect(table.isFrbIgnored('NtsDnsPoolStats'), isFalse);
    });

    test('does not treat a namespaced path as FRB-excluded', () {
      // `checkout` is excluded, but `NtsClient::checkout` would name a
      // member; only bare item names come from the FRB header lines.
      expect(table.isFrbIgnored('NtsClient::checkout'), isFalse);
    });
  });

  group('rewriteIntraDocLinks', () {
    test('rewrites every shape in one pass', () {
      const source = '''
/// See [`NtsDnsPoolStats::spawn_failed`], [`TrustBackend::WebpkiRoots`],
/// [`TrustMode::PlatformOnly`], [`NtsClient::new`] and [`nts_query`].
class Doc {}
''';
      final result = rewriteIntraDocLinks(source, table);
      expect(result.unresolved, isEmpty);
      expect(result.rewritten, 5);
      expect(result.source, contains('[NtsDnsPoolStats.spawnFailed]'));
      expect(result.source, contains('[TrustBackend.webpkiRoots]'));
      expect(result.source, contains('[TrustMode.platformOnly]'));
      expect(result.source, contains('[NtsClient.new]'));
      expect(result.source, contains('[ntsQuery]'));
    });

    test('resolves `Self::` against the class the doc sits inside', () {
      const source = '''
class NtsDnsPoolStats {
  /// Disjoint from [`Self::recovered`].
  final BigInt spawnFailed;
}
''';
      final result = rewriteIntraDocLinks(source, table);
      expect(result.source, contains('[NtsDnsPoolStats.recovered]'));
      expect(result.unresolved, isEmpty);
    });

    test('downgrades an FRB-excluded referent to inline code', () {
      const source = '/// See [`ntp_short_signed_to_micros`].\n';
      final result = rewriteIntraDocLinks(source, table);
      expect(result.source, '/// See `ntp_short_signed_to_micros`.\n');
      expect(result.downgraded, 1);
      expect(result.rewritten, 0);
      expect(result.unresolved, isEmpty);
    });

    test('reports an unresolvable link instead of passing it through', () {
      const source = '/// See [`NtsClient::no_such_member`].\n';
      final result = rewriteIntraDocLinks(source, table);
      expect(result.unresolved, <String>['NtsClient::no_such_member']);
      // Left verbatim so the caller can name the offending text.
      expect(result.source, source);
    });

    test('leaves an already-Dart-shaped link alone', () {
      const source = '/// See [NtsDnsPoolStats.spawnFailed].\n';
      expect(rewriteIntraDocLinks(source, table).source, source);
    });

    test('is idempotent', () {
      const source = '/// See [`nts_query`] and [`TrustMode::PlatformOnly`].\n';
      final once = rewriteIntraDocLinks(source, table);
      final twice = rewriteIntraDocLinks(once.source, table);
      expect(twice.source, once.source);
      expect(twice.rewritten, 0);
      expect(twice.unresolved, isEmpty);
    });
  });
}

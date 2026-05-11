// Pure-function coverage for the on-screen log buffer and its entry
// model. Exercises the structured `host` / `trustBackend` /
// `trustMode` fields added in 3.0.0 and the share-export column
// layout that depends on them.

import 'package:flutter_test/flutter_test.dart';
import 'package:nts/nts.dart' show TrustBackend, TrustMode;
import 'package:nts_example/src/state/log_buffer.dart';
import 'package:nts_example/src/state/log_entry.dart';

NtsLogEntry _entry({
  String source = 'nts_query',
  String message = 'OK stratum=1',
  NtsLogLevel level = NtsLogLevel.info,
  String? host,
  TrustBackend? trustBackend,
  TrustMode? trustMode,
}) => NtsLogEntry(
  timestamp: DateTime.utc(2030, 1, 2, 3, 4, 5),
  level: level,
  source: source,
  message: message,
  host: host,
  trustBackend: trustBackend,
  trustMode: trustMode,
);

void main() {
  group('NtsLogEntry.formatForExport', () {
    test('omits structured tokens when no metadata is attached', () {
      expect(
        _entry().formatForExport(),
        '2030-01-02T03:04:05.000Z INFO  nts_query  OK stratum=1',
      );
    });

    test('emits host token in fixed position when only host is set', () {
      expect(
        _entry(host: 'time.cloudflare.com').formatForExport(),
        '2030-01-02T03:04:05.000Z INFO  nts_query [host=time.cloudflare.com]'
        '  OK stratum=1',
      );
    });

    test('emits backend token without host when only backend is set', () {
      expect(
        _entry(trustBackend: TrustBackend.platform).formatForExport(),
        '2030-01-02T03:04:05.000Z INFO  nts_query [backend=platform]'
        '  OK stratum=1',
      );
    });

    test('emits mode token without host or backend', () {
      expect(
        _entry(
          source: 'system',
          message: 'TrustMode → platform-only',
          trustMode: TrustMode.platformOnly,
        ).formatForExport(),
        '2030-01-02T03:04:05.000Z INFO  system [mode=platformOnly]'
        '  TrustMode → platform-only',
      );
    });

    test('host / backend / mode appear in fixed column order when all set', () {
      expect(
        _entry(
          host: 'ntp1.dmz.terryburton.co.uk',
          trustBackend: TrustBackend.platformWithHybridFallback,
          trustMode: TrustMode.platformWithFallback,
        ).formatForExport(),
        '2030-01-02T03:04:05.000Z INFO  nts_query '
        '[host=ntp1.dmz.terryburton.co.uk] '
        '[backend=platformWithHybridFallback] '
        '[mode=platformWithFallback]  OK stratum=1',
      );
    });

    test('level is right-padded to a fixed width across severities', () {
      expect(
        _entry(level: NtsLogLevel.warn).formatForExport(),
        startsWith('2030-01-02T03:04:05.000Z WARN  '),
      );
      expect(
        _entry(level: NtsLogLevel.error).formatForExport(),
        startsWith('2030-01-02T03:04:05.000Z ERROR '),
      );
    });
  });

  group('NtsLogBuffer helpers', () {
    test('info threads structured fields onto the appended entry', () {
      final buf = NtsLogBuffer();
      buf.info(
        'nts_query',
        'OK stratum=1',
        host: 'time.cloudflare.com',
        trustBackend: TrustBackend.platform,
      );
      final e = buf.entries.value.single;
      expect(e.level, NtsLogLevel.info);
      expect(e.host, 'time.cloudflare.com');
      expect(e.trustBackend, TrustBackend.platform);
      expect(e.trustMode, isNull);
    });

    test('warn / error default the optional fields to null', () {
      final buf = NtsLogBuffer();
      buf.warn('nts_query', 'soft failure');
      buf.error('nts_query', 'hard failure');
      final entries = buf.entries.value;
      expect(entries, hasLength(2));
      expect(entries[0].level, NtsLogLevel.warn);
      expect(entries[0].host, isNull);
      expect(entries[0].trustBackend, isNull);
      expect(entries[0].trustMode, isNull);
      expect(entries[1].level, NtsLogLevel.error);
    });

    test('append publishes a new list reference so signal observers fire', () {
      final buf = NtsLogBuffer();
      final before = buf.entries.value;
      buf.info('system', 'boot');
      final after = buf.entries.value;
      expect(identical(before, after), isFalse);
      expect(after, hasLength(1));
    });

    test('exportAsText concatenates entries in chronological order', () {
      final buf = NtsLogBuffer();
      buf.info('system', 'boot');
      buf.info(
        'nts_query',
        'OK stratum=1',
        host: 'time.cloudflare.com',
        trustBackend: TrustBackend.webpkiRoots,
      );
      final lines = buf.exportAsText().split('\n');
      expect(lines, hasLength(2));
      expect(lines[0], endsWith('system  boot'));
      expect(lines[1], contains('[host=time.cloudflare.com]'));
      expect(lines[1], contains('[backend=webpkiRoots]'));
    });

    test('clear empties the buffer and publishes a fresh empty list', () {
      final buf = NtsLogBuffer();
      buf.info('system', 'boot');
      buf.clear();
      expect(buf.entries.value, isEmpty);
    });
  });
}

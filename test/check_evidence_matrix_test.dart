// Unit tests for the parser and coverage rules behind
// `tool/clock_evidence/check_evidence_matrix.dart`.
//
// That script is the close gate for NTS-180: `--require-complete` is
// what decides whether the strict clock's platform evidence is accepted
// as complete. A parser regression there would let the gate accept a
// matrix that is missing a platform, silently double-counts a
// dimension, or records a `pass` with no evidence behind it -- exactly
// the outcomes the `nts-flr8` delivery policy exists to prevent. These
// tests pin the rejection paths, which the real matrix (being valid)
// never exercises.
//
// `@TestOn('vm')` matches the tool itself, which uses `dart:io`.
@TestOn('vm')
library;

import 'package:flutter_test/flutter_test.dart';

import '../tool/clock_evidence/check_evidence_matrix.dart';

/// A minimal well-formed table for [platform] with [rows] spliced in.
List<String> _table(String platform, List<String> rows) => [
  '## $platform',
  '',
  '| dimension | status | method | evidence | next-action |',
  '|---|---|---|---|---|',
  ...rows,
];

const _validRow =
    '| source-contract | pass | source review | seen in '
    'boottime.rs | |';

void main() {
  group('parseEvidenceRows', () {
    test('reads a data row and skips the header and separator', () {
      final problems = <String>[];
      final rows = parseEvidenceRows(_table('android', [_validRow]), problems);

      expect(problems, isEmpty);
      expect(rows, hasLength(1));
      expect(rows.single.platform, 'android');
      expect(rows.single.dimension, 'source-contract');
      expect(rows.single.status, 'pass');
      expect(rows.single.method, 'source review');
      expect(rows.single.evidence, 'seen in boottime.rs');
      expect(rows.single.nextAction, isEmpty);
    });

    test('ignores tables before the first platform heading', () {
      final problems = <String>[];
      final rows = parseEvidenceRows([
        '| Status | Meaning |',
        '|---|---|',
        '| pass | Observed. |',
      ], problems);

      expect(problems, isEmpty);
      expect(rows, isEmpty);
    });

    test('rejects a row with the wrong column count', () {
      final problems = <String>[];
      final rows = parseEvidenceRows(
        _table('android', ['| source-contract | pass | ci |']),
        problems,
      );

      expect(rows, isEmpty);
      expect(problems, hasLength(1));
      expect(problems.single, contains('expected 5 columns'));
    });

    test('rejects an unknown status', () {
      final problems = <String>[];
      final rows = parseEvidenceRows(
        _table('android', ['| source-contract | probably | ci | x | |']),
        problems,
      );

      expect(rows, isEmpty);
      expect(problems.single, contains('has status "probably"'));
    });
  });

  group('checkEvidenceCoverage', () {
    /// Every dimension for [platform], all settled, so a test can make
    /// exactly one row defective and see only that problem reported.
    List<String> completeRows() => [
      for (final dimension in [
        'source-contract',
        'compilation',
        'rust-unit-tests',
        'dart-hermetic-tests',
        'native-runtime-read',
        'multi-engine',
        'bridge-teardown',
        'process-relaunch',
        'descriptor-compatibility',
        'suspend-resume',
        'locked-after-first-unlock',
        'rtc-change',
        'process-death',
        'reboot',
        'uptime-after-boot',
      ])
        '| $dimension | pass | host | observed | |',
    ];

    List<String> allPlatforms({List<String>? androidRows}) => [
      ...['android', 'ios', 'macos', 'linux', 'windows'].expand(
        (p) => _table(
          p,
          p == 'android' && androidRows != null ? androidRows : completeRows(),
        ),
      ),
    ];

    List<String> problemsFor(List<String> lines) {
      final problems = <String>[];
      checkEvidenceCoverage(parseEvidenceRows(lines, problems), problems);
      return problems;
    }

    test('accepts a complete matrix', () {
      expect(problemsFor(allPlatforms()), isEmpty);
    });

    test('reports a missing platform section', () {
      final problems = problemsFor(_table('android', completeRows()));
      expect(problems, contains(contains('no "## ios" section')));
    });

    test('reports a missing dimension', () {
      final rows = completeRows()..removeWhere((r) => r.contains('| reboot '));
      final problems = problemsFor(allPlatforms(androidRows: rows));
      expect(problems, [contains('android is missing dimension "reboot"')]);
    });

    test('reports a duplicated dimension', () {
      final rows = completeRows()..add('| reboot | pass | host | again | |');
      final problems = problemsFor(allPlatforms(androidRows: rows));
      expect(problems, [contains('records "reboot" 2 times')]);
    });

    test('reports an unknown dimension', () {
      final rows = completeRows()..add('| vibes | pass | host | good | |');
      final problems = problemsFor(allPlatforms(androidRows: rows));
      expect(problems, [contains('unknown dimension "vibes"')]);
    });

    test('reports an unknown platform section', () {
      final problems = problemsFor([
        ...allPlatforms(),
        ..._table('solaris', completeRows()),
      ]);
      expect(problems, [contains('unknown platform section "## solaris"')]);
    });

    test('reports a row with no method', () {
      final rows = completeRows()
        ..[0] = '| source-contract | pass |  | observed | |';
      final problems = problemsFor(allPlatforms(androidRows: rows));
      expect(problems, [contains('records no method')]);
    });

    test('reports a pass with no evidence', () {
      final rows = completeRows()
        ..[0] = '| source-contract | pass | host | | |';
      final problems = problemsFor(allPlatforms(androidRows: rows));
      expect(problems, [contains('is "pass" but records no evidence')]);
    });

    test('reports an n/a with no evidence', () {
      final rows = completeRows()..[0] = '| source-contract | n/a | — | | |';
      final problems = problemsFor(allPlatforms(androidRows: rows));
      expect(problems, [contains('is "n/a" but records no evidence')]);
    });

    test('reports an outstanding row with no next action', () {
      for (final status in ['pending', 'blocked', 'fail']) {
        final rows = completeRows()
          ..[0] = '| source-contract | $status | host | | |';
        final problems = problemsFor(allPlatforms(androidRows: rows));
        expect(problems, [contains('is "$status" but records no next action')]);
      }
    });

    test('accepts an outstanding row that carries a next action', () {
      final rows = completeRows()
        ..[0] = '| source-contract | pending | host | | read the source |';
      expect(problemsFor(allPlatforms(androidRows: rows)), isEmpty);
    });
  });
}

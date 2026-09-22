// Validator and reporter for the strict clock evidence matrix
// (`tool/clock_evidence/evidence_matrix.md`, NTS-180).
//
// Checks that the matrix is structurally complete -- every supported
// platform present, every dimension recorded exactly once per platform,
// every status drawn from the allowed set -- and that each row carries
// the justification its status requires: a `pass` or `n/a` needs
// evidence, anything else needs a next action. It never inspects a
// clock; the readings themselves come from
// `tool/clock_evidence/native_lifecycle_probe_test.dart` and from the
// manual device procedures the matrix names.
//
// Usage:
//
//     dart run tool/clock_evidence/check_evidence_matrix.dart [--require-complete] [--help]
//
// Exit codes:
//   0  the matrix is well-formed (and, with `--require-complete`, has no
//      outstanding rows)
//   1  a structural defect, or an outstanding row under
//      `--require-complete`
//
// `--require-complete` is the epic-close gate for `nts-flr8.7`. It is
// deliberately not wired into CI: a green CI run is not evidence that a
// physical device did anything, and making the gate pass by editing this
// file is exactly the failure the `nts-flr8` delivery policy forbids.

import 'dart:io';

const _matrixPath = 'tool/clock_evidence/evidence_matrix.md';

const _platforms = ['android', 'ios', 'macos', 'linux', 'windows'];

const _dimensions = [
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
];

/// Statuses that settle a row. Everything else is outstanding work.
const _settled = {'pass', 'n/a'};
const _statuses = {'pass', 'fail', 'pending', 'blocked', 'n/a'};

const _usage = '''
Validate the strict clock evidence matrix.

Usage:
    dart run tool/clock_evidence/check_evidence_matrix.dart [options]

Options:
    --require-complete  Also fail when any row is still pending, blocked
                        or failing. This is the nts-flr8.7 close gate.
    -h, --help          Show this message.
''';

String get _errorPrefix => Platform.environment.containsKey('GITHUB_ACTIONS')
    ? '::error::'
    : 'error: ';

class _Row {
  _Row({
    required this.platform,
    required this.dimension,
    required this.status,
    required this.evidence,
    required this.nextAction,
    required this.line,
  });

  final String platform;
  final String dimension;
  final String status;
  final String evidence;
  final String nextAction;
  final int line;
}

void main(List<String> args) {
  var requireComplete = false;
  for (final arg in args) {
    switch (arg) {
      case '--require-complete':
        requireComplete = true;
      case '-h':
      case '--help':
        stdout.write(_usage);
        return;
      default:
        stderr.writeln('${_errorPrefix}unknown argument: $arg');
        stderr.write(_usage);
        exit(1);
    }
  }

  final file = File(_matrixPath);
  if (!file.existsSync()) {
    stderr.writeln('$_errorPrefix$_matrixPath not found');
    exit(1);
  }

  final problems = <String>[];
  final rows = _parse(file.readAsLinesSync(), problems);
  _checkCoverage(rows, problems);

  if (problems.isNotEmpty) {
    for (final problem in problems) {
      stderr.writeln('$_errorPrefix$problem');
    }
    exit(1);
  }

  final outstanding = rows.where((r) => !_settled.contains(r.status)).toList();
  _report(rows, outstanding);

  if (requireComplete && outstanding.isNotEmpty) {
    stderr.writeln(
      '$_errorPrefix${outstanding.length} row(s) still outstanding; '
      'the nts-flr8.7 evidence matrix is not complete',
    );
    exit(1);
  }
}

/// Collect every data row of every `## <platform>` table.
List<_Row> _parse(List<String> lines, List<String> problems) {
  final rows = <_Row>[];
  var platform = '';
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.startsWith('## ')) {
      platform = line.substring(3).trim();
      continue;
    }
    // Only rows inside a platform section are data; the legend tables at
    // the top of the file sit before the first heading.
    if (platform.isEmpty || !line.startsWith('|')) continue;

    final cells = line
        .substring(1, line.endsWith('|') ? line.length - 1 : line.length)
        .split('|')
        .map((c) => c.trim())
        .toList();
    if (cells.length != 5) {
      problems.add(
        '$_matrixPath:${i + 1}: expected 5 columns in the $platform table, '
        'found ${cells.length}',
      );
      continue;
    }
    if (cells.first == 'dimension' || cells.first.replaceAll('-', '').isEmpty) {
      continue; // header or separator
    }
    if (!_statuses.contains(cells[1])) {
      problems.add(
        '$_matrixPath:${i + 1}: $platform/${cells[0]} has status '
        '"${cells[1]}"; allowed: ${_statuses.join(', ')}',
      );
      continue;
    }
    rows.add(
      _Row(
        platform: platform,
        dimension: cells[0],
        status: cells[1],
        evidence: cells[3],
        nextAction: cells[4],
        line: i + 1,
      ),
    );
  }
  return rows;
}

/// Every platform carries every dimension exactly once, and every row
/// carries the justification its status requires.
void _checkCoverage(List<_Row> rows, List<String> problems) {
  for (final platform in _platforms) {
    final byDimension = <String, List<_Row>>{};
    for (final row in rows.where((r) => r.platform == platform)) {
      byDimension.putIfAbsent(row.dimension, () => []).add(row);
    }
    if (byDimension.isEmpty) {
      problems.add('$_matrixPath: no "## $platform" section');
      continue;
    }
    for (final dimension in _dimensions) {
      final found = byDimension[dimension] ?? const <_Row>[];
      if (found.isEmpty) {
        problems.add(
          '$_matrixPath: $platform is missing dimension "$dimension"',
        );
      } else if (found.length > 1) {
        problems.add(
          '$_matrixPath: $platform records "$dimension" ${found.length} '
          'times (lines ${found.map((r) => r.line).join(', ')})',
        );
      }
    }
    for (final entry in byDimension.entries) {
      if (!_dimensions.contains(entry.key)) {
        problems.add(
          '$_matrixPath:${entry.value.first.line}: $platform records '
          'unknown dimension "${entry.key}"',
        );
      }
    }
  }
  for (final platform in rows.map((r) => r.platform).toSet()) {
    if (!_platforms.contains(platform)) {
      problems.add('$_matrixPath: unknown platform section "## $platform"');
    }
  }
  for (final row in rows) {
    final where = '$_matrixPath:${row.line}: ${row.platform}/${row.dimension}';
    if (_settled.contains(row.status) && row.evidence.isEmpty) {
      problems.add('$where is "${row.status}" but records no evidence');
    }
    if (!_settled.contains(row.status) && row.nextAction.isEmpty) {
      problems.add('$where is "${row.status}" but records no next action');
    }
  }
}

/// Human-readable summary. Outstanding rows are listed in full so the
/// remaining work is visible without opening the matrix.
void _report(List<_Row> rows, List<_Row> outstanding) {
  stdout.writeln('strict clock evidence matrix: ${rows.length} rows');
  for (final platform in _platforms) {
    final forPlatform = rows.where((r) => r.platform == platform);
    final settled = forPlatform
        .where((r) => _settled.contains(r.status))
        .length;
    stdout.writeln(
      '  ${platform.padRight(8)} $settled/${forPlatform.length} settled',
    );
  }
  if (outstanding.isEmpty) {
    stdout.writeln('all rows settled');
    return;
  }
  stdout.writeln('');
  stdout.writeln('outstanding (${outstanding.length}):');
  for (final row in outstanding) {
    stdout.writeln(
      '  ${row.platform}/${row.dimension} [${row.status}] - ${row.nextAction}',
    );
  }
}

// Script to extract and validate Dart code snippets in documentation.
//
// Extracts Dart code blocks from README.md, CHANGELOG.md, and ARCHITECTURE.md,
// wraps them in a basic harness if necessary, and runs `dart analyze` to
// ensure they remain syntactically valid as the API evolves.
//
// Usage:
//
//     dart run tool/check_doc_snippets.dart
//

import 'dart:io';

const _docFiles = [
  'README.md',
  'CHANGELOG.md',
  'ARCHITECTURE.md',
  'example/example.md'
];
const _snippetDir = 'tool/.snippets';

// GitHub Actions annotation prefix.
String get _errorPrefix => Platform.environment.containsKey('GITHUB_ACTIONS')
    ? '::error::'
    : 'error: ';

Future<void> main(List<String> args) async {
  var totalErrors = 0;
  final dir = Directory(_snippetDir);
  if (dir.existsSync()) {
    dir.deleteSync(recursive: true);
  }
  dir.createSync(recursive: true);

  try {
    for (final fileName in _docFiles) {
      final file = File(fileName);
      if (!file.existsSync()) {
        stdout.writeln('Skipping missing file: $fileName');
        continue;
      }

      final content = file.readAsStringSync();
      final dartBlocks =
          RegExp(r'```dart\s*\n(.*?)\n```', dotAll: true).allMatches(content);

      if (dartBlocks.isEmpty) {
        stdout.writeln('No Dart snippets found in $fileName');
        continue;
      }

      stdout.writeln('Checking ${dartBlocks.length} snippet(s) in $fileName...');

      var snippetIndex = 0;
      for (final match in dartBlocks) {
        snippetIndex++;
        final snippet = match.group(1)!;

        // Skip snippets with historical markers if they are in CHANGELOG.md.
        // Changelog migration examples often show old code that is no longer
        // valid (by design), so analyzing it would yield false positives.
        if (fileName == 'CHANGELOG.md' && _isHistoricalSnippet(snippet)) {
          stdout.writeln('  Snippet $snippetIndex: skipping (historical)');
          continue;
        }

        final snippetFile = File(
            '${dir.path}/${fileName.replaceAll(Platform.pathSeparator, '_').replaceAll('.', '_')}_$snippetIndex.dart');

        final wrappedContent = _prepareSnippet(snippet);
        snippetFile.writeAsStringSync(wrappedContent);

        final result = await Process.run('dart', ['analyze', snippetFile.path]);
        if (result.exitCode != 0) {
          totalErrors++;
          stderr.writeln(
              '${_errorPrefix}Snippet $snippetIndex in $fileName failed analysis:');
          stderr.writeln(result.stdout);
          stderr.writeln(result.stderr);
          // Print the wrapped content for debugging if it failed
          stderr.writeln('--- Wrapped snippet content ---');
          stderr.writeln(wrappedContent);
          stderr.writeln('--- End wrapped snippet content ---');
        } else {
          stdout.writeln('  Snippet $snippetIndex: OK');
        }
      }
    }
  } finally {
    if (totalErrors == 0) {
      dir.deleteSync(recursive: true);
    } else {
      stdout.writeln('Temp files preserved at ${dir.path} for debugging.');
    }
  }

  if (totalErrors > 0) {
    stderr.writeln('\nTotal snippet analysis failures: $totalErrors');
    exit(1);
  } else {
    stdout.writeln('\nAll documentation snippets passed analysis.');
  }
}

bool _isHistoricalSnippet(String snippet) {
  // Common markers for old versions in changelog examples.
  final historicalMarkers = [
    '// 1.',
    '// 2.',
    '// 3.',
    '// 4.',
    '3.0.x',
    '2.0.0',
    '1.3.x',
  ];
  return historicalMarkers.any((marker) => snippet.contains(marker));
}

String _prepareSnippet(String snippet) {
  // Extract imports using a regex that handles multi-line imports.
  // Matches from 'import ' at start of line until the next ';'.
  final importPattern = RegExp(r'^import\s+.*?;', multiLine: true, dotAll: true);
  final importMatches = importPattern.allMatches(snippet).toList();

  final imports = <String>[];
  var lastImportEnd = 0;
  for (final match in importMatches) {
    imports.add(match.group(0)!);
    lastImportEnd = match.end;
  }

  var body = snippet.substring(lastImportEnd).trim();

  // If the body looks like a switch-expression fragment (contains '// ...'),
  // try to make it exhaustive to satisfy the analyzer.
  if (body.contains('switch (') && body.contains('// ...')) {
    if (body.endsWith('};')) {
      body = body.substring(0, body.length - 2) +
          '  _ => throw UnimplementedError(),\n};';
    } else if (body.endsWith('}')) {
      body = body.substring(0, body.length - 1) +
          '  _ => throw UnimplementedError(),\n}';
    }
  }

  final sb = StringBuffer();
  // Suppress common lints that snippets intentionally trip (e.g. print for demos).
  sb.writeln(
      '// ignore_for_file: avoid_print, unused_local_variable, dead_code, deprecated_member_use');

  // Ensure basic package import is present if needed.
  if (!snippet.contains("package:nts/nts.dart") &&
      (snippet.contains('Nts') ||
          snippet.contains('ntsQuery') ||
          snippet.contains('ntsWarmCookies'))) {
    sb.writeln("import 'package:nts/nts.dart';");
  }

  for (final imp in imports) {
    sb.writeln(imp);
  }

  final hasMain = snippet.contains('void main') || snippet.contains('main()');
  final hasClass = snippet.contains('class ') ||
      snippet.contains('enum ') ||
      snippet.contains('extension ');

  if (!hasMain && !hasClass) {
    sb.writeln('Future<void> main() async {');
    // Define common missing variables to avoid "undefined name" or
    // "definitely unassigned" errors for fragments.
    sb.writeln('  final NtsError err = throw UnimplementedError();');
    sb.writeln('  final NtsServerSpec spec = throw UnimplementedError();');
    sb.writeln('  final NtsTimeSample sample = throw UnimplementedError();');
    sb.writeln('  final NtsClient client = throw UnimplementedError();');
    sb.writeln(body);
    sb.writeln('}');
  } else {
    sb.writeln(body);
  }

  return sb.toString();
}

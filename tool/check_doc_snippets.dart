// Script to extract and validate Dart code snippets in documentation.
//
// Extracts Dart code blocks from README.md, CHANGELOG.md, ARCHITECTURE.md,
// and example/example.md, wraps them in a minimal harness when they lack a
// main function or class-like declaration, and runs `dart analyze` to catch
// type errors, missing imports, and other static-analysis issues before they
// reach users.
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
  'example/example.md',
];
const _snippetDir = 'tool/.snippets';

// GitHub Actions annotation prefix.
String get _errorPrefix => Platform.environment.containsKey('GITHUB_ACTIONS')
    ? '::error::'
    : 'error: ';

Future<void> main(List<String> args) async {
  // Enforce running from the repo root so we find the docs.  Both
  // `pubspec.yaml` and `rust/Cargo.toml` must be present together --
  // `pubspec.yaml` alone is not enough because `example/pubspec.yaml`
  // also exists, so running from `example/` would otherwise slip past
  // this guard and surface as a confusing "no docs found" failure later.
  if (!File('pubspec.yaml').existsSync() ||
      !File('rust/Cargo.toml').existsSync()) {
    stderr.writeln(
      '${_errorPrefix}Script must be run from the repository root '
      '(expected both pubspec.yaml and rust/Cargo.toml).',
    );
    exit(1);
  }

  var totalErrors = 0;
  var filesFound = 0;
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
      filesFound++;

      // Normalize CRLF so the regex matches on Windows checkouts too.
      final content = file.readAsStringSync().replaceAll('\r\n', '\n');
      final dartBlocks = RegExp(
        r'```dart\s*\n(.*?)\n```',
        dotAll: true,
      ).allMatches(content).toList();

      if (dartBlocks.isEmpty) {
        stdout.writeln('No Dart snippets found in $fileName');
        continue;
      }

      stdout.writeln(
        'Checking ${dartBlocks.length} snippet(s) in $fileName...',
      );

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

        // Sanitize both '/' and '\' so paths like 'example/example.md'
        // produce a flat filename on all platforms.
        final safeFileName = fileName
            .replaceAll('/', '_')
            .replaceAll('\\', '_')
            .replaceAll('.', '_');
        final snippetFile = File(
          '${dir.path}/${safeFileName}_$snippetIndex.dart',
        );
        snippetFile.parent.createSync(recursive: true);

        final wrappedContent = _prepareSnippet(snippet);
        snippetFile.writeAsStringSync(wrappedContent);

        final result = await Process.run('dart', ['analyze', snippetFile.path]);
        if (result.exitCode != 0) {
          totalErrors++;
          stderr.writeln(
            '${_errorPrefix}Snippet $snippetIndex in $fileName failed analysis:',
          );
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

  if (filesFound == 0) {
    stderr.writeln('${_errorPrefix}No documentation files found to scan.');
    exit(1);
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
  final importPattern = RegExp(
    r'^import\s+.*?;',
    multiLine: true,
    dotAll: true,
  );
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
      body =
          '${body.substring(0, body.length - 2)}'
          '  _ => throw UnimplementedError(),\n};';
    } else if (body.endsWith('}')) {
      body =
          '${body.substring(0, body.length - 1)}'
          '  _ => throw UnimplementedError(),\n}';
    }
  }

  final hasMain = snippet.contains('void main') || snippet.contains('main()');
  final hasClass =
      snippet.contains('class ') ||
      snippet.contains('enum ') ||
      snippet.contains('extension ');
  final needsHarness = !hasMain && !hasClass;

  final sb = StringBuffer();
  // Suppress common lints that snippets intentionally trip (e.g. print for demos).
  sb.writeln(
    '// ignore_for_file: avoid_print, unused_local_variable, dead_code, deprecated_member_use',
  );

  // Always inject package:nts/nts.dart when the harness is used: the harness
  // emits NtsError/NtsServerSpec/NtsTimeSample/NtsClient typed locals, so the
  // import is required regardless of whether the snippet itself mentions those
  // symbols.  Also inject it for snippets with a top-level declaration that
  // explicitly reference nts symbols.
  if (!snippet.contains("package:nts/nts.dart") &&
      (needsHarness ||
          snippet.contains('Nts') ||
          snippet.contains('ntsQuery') ||
          snippet.contains('ntsWarmCookies'))) {
    sb.writeln("import 'package:nts/nts.dart';");
  }

  for (final imp in imports) {
    sb.writeln(imp);
  }

  if (needsHarness) {
    // Declare common typed locals via a generic stub so fragments that
    // reference these types resolve under static analysis. We deliberately
    // route through `_snippetStub<T>()` (return type `T`, not `Never`) so
    // the initializers stay statically reachable -- a bare
    // `throw UnimplementedError()` evaluates to `Never` and would make the
    // analyzer treat the entire snippet body as unreachable, silently
    // masking real issues.
    sb.writeln('T _snippetStub<T>() => throw UnimplementedError();');
    sb.writeln('Future<void> main() async {');
    sb.writeln('  final NtsError err = _snippetStub<NtsError>();');
    sb.writeln('  final NtsServerSpec spec = _snippetStub<NtsServerSpec>();');
    sb.writeln('  final NtsTimeSample sample = _snippetStub<NtsTimeSample>();');
    sb.writeln('  final NtsClient client = _snippetStub<NtsClient>();');
    sb.writeln(body);
    sb.writeln('}');
  } else {
    sb.writeln(body);
  }

  return sb.toString();
}

// Script to extract and validate Dart code snippets in documentation.
//
// Extracts Dart code blocks from README.md, CHANGELOG.md, ARCHITECTURE.md,
// and example/example.md, wraps them in a minimal harness when they lack a
// main function or top-level declaration (class, enum, extension, mixin, or
// typedef), and runs `dart analyze` to catch type errors, missing imports,
// and other static-analysis issues before they reach users.
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
  _assertSnippetDirSafe(dir);
  if (dir.existsSync()) {
    dir.deleteSync(recursive: true);
  }
  dir.createSync(recursive: true);

  // Collect snippet metadata so we can attribute analyzer output back to
  // (docFile, snippetIndex) after the single batched `dart analyze` run.
  final snippetMeta =
      <String, ({String fileName, int index, String wrapped})>{};

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
        'Extracting ${dartBlocks.length} snippet(s) from $fileName...',
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
        snippetMeta[snippetFile.path] = (
          fileName: fileName,
          index: snippetIndex,
          wrapped: wrappedContent,
        );
      }
    }

    // Run `dart analyze` once over the entire snippet directory rather than
    // once per snippet.  Spawning a fresh analyzer per snippet repeats
    // package resolution and analyzer warm-up for every block, which scales
    // badly as documentation grows.
    if (snippetMeta.isNotEmpty) {
      stdout.writeln(
        '\nAnalyzing ${snippetMeta.length} snippet(s) with '
        '`dart analyze ${dir.path}`...',
      );
      final result = await Process.run('dart', ['analyze', dir.path]);
      if (result.exitCode != 0) {
        // Attribute failures by matching snippet file paths in stdout.
        final stdoutStr = result.stdout.toString();
        final failed = <String>{};
        for (final path in snippetMeta.keys) {
          if (stdoutStr.contains(path)) {
            failed.add(path);
          }
        }
        // If we cannot attribute (unexpected output shape) treat the whole
        // batch as one failure so we still exit non-zero.
        totalErrors = failed.isEmpty ? 1 : failed.length;
        for (final path in failed) {
          final m = snippetMeta[path]!;
          stderr.writeln(
            '${_errorPrefix}Snippet ${m.index} in ${m.fileName} '
            'failed analysis ($path).',
          );
        }
        stderr.writeln('--- dart analyze output ---');
        stderr.writeln(stdoutStr);
        stderr.writeln(result.stderr);
        for (final path in failed) {
          final m = snippetMeta[path]!;
          stderr.writeln('--- Wrapped snippet ${m.index} of ${m.fileName} ---');
          stderr.writeln(m.wrapped);
        }
      } else {
        for (final m in snippetMeta.values) {
          stdout.writeln('  Snippet ${m.index} of ${m.fileName}: OK');
        }
      }
    }
  } finally {
    if (totalErrors == 0) {
      _assertSnippetDirSafe(dir);
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

/// Guards both deletion sites against the snippet directory being replaced by
/// a symlink (or a plain file) that could redirect a recursive delete outside
/// the repository.
///
/// Checks (without following the final path component):
///
/// 1. The entity at [dir.path] is a plain [Directory] or absent.
///    A symlink or regular file causes an immediate non-zero exit.
/// 2. When the entity is a directory its canonical path (all symlinks
///    resolved) must start with the canonical repository root, so a path
///    containing ".." components cannot escape the workspace.
void _assertSnippetDirSafe(Directory dir) {
  final type = FileSystemEntity.typeSync(dir.path, followLinks: false);

  if (type == FileSystemEntityType.link) {
    stderr.writeln(
      '${_errorPrefix}Refusing to delete ${dir.path}: '
      'path is a symlink. Remove it manually if safe.',
    );
    exit(1);
  }
  if (type == FileSystemEntityType.file) {
    stderr.writeln(
      '${_errorPrefix}Refusing to delete ${dir.path}: '
      'expected a directory but found a plain file. '
      'Remove it manually if safe.',
    );
    exit(1);
  }
  if (type == FileSystemEntityType.notFound) {
    // Nothing to delete; createSync() will make it fresh.
    return;
  }
  if (type != FileSystemEntityType.directory) {
    // FIFO, socket, or other special file type — refuse rather than
    // attempting resolveSymbolicLinksSync() which may throw or mislead.
    stderr.writeln(
      '${_errorPrefix}Refusing to delete ${dir.path}: '
      'unexpected file system entity type ($type). '
      'Remove it manually if safe.',
    );
    exit(1);
  }

  // type == FileSystemEntityType.directory — verify the canonical path sits
  // inside the repository root so intermediate symlinks in parent directories
  // cannot redirect the delete outside the workspace.
  final repoRoot = Directory.current.resolveSymbolicLinksSync();
  final canonical = dir.resolveSymbolicLinksSync();
  final sep = Platform.pathSeparator;
  // Normalize repoRoot so we don't build a double-separator prefix when
  // repoRoot is itself a filesystem root (e.g. POSIX '/' or Windows 'C:\').
  final repoRootPrefix =
      repoRoot.endsWith(sep) ? repoRoot : '$repoRoot$sep';
  if (canonical != repoRoot && !canonical.startsWith(repoRootPrefix)) {
    stderr.writeln(
      '${_errorPrefix}Refusing to delete ${dir.path}: '
      'canonical path $canonical is outside the repository root $repoRoot.',
    );
    exit(1);
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
  // Matches from 'import ' at the start of a (possibly indented) line until
  // the next ';'.  The leading `\s*` is required because fenced code blocks
  // inside nested Markdown lists are indented; without it, valid `import`
  // lines slip past the extractor and end up inside the generated `main()`
  // body, which then fails analysis with a spurious "directive must appear
  // before any declarations" error.
  final importPattern = RegExp(
    r'^\s*import\s+.*?;',
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

  // Detect a top-level `main` declaration without matching call-sites like
  // `foo.main()` or the literal text `main()` inside a `// ...` comment.
  // The regex anchors on (optionally indented) start-of-line and accepts
  // the common Dart return-type prefixes (`void`, `Future<void>`,
  // `FutureOr<void>`) or no prefix at all.
  final mainPattern = RegExp(
    r'^\s*(?:void\s+|Future\s*<[^>]*>\s+|FutureOr\s*<[^>]*>\s+)?main\s*\(',
    multiLine: true,
  );
  final hasMain = mainPattern.hasMatch(snippet);

  // Detect other top-level declarations that cannot be wrapped in a main()
  // function body (class, enum, extension, mixin, typedef).
  final topLevelPattern = RegExp(
    r'^\s*(?:class|enum|extension|mixin|typedef)\s+',
    multiLine: true,
  );
  final hasTopLevel = topLevelPattern.hasMatch(snippet);
  final needsHarness = !hasMain && !hasTopLevel;

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

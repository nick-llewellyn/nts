// Script to extract and validate Dart code snippets in documentation.
//
// Extracts Dart code blocks from README.md, CHANGELOG.md, ARCHITECTURE.md,
// docs/MONOTONIC_TIME.md, and example/example.md, wraps them in a minimal
// harness when they lack a
// main function or top-level declaration (class, enum, extension, mixin, or
// typedef), and runs `dart analyze` to catch type errors, missing imports,
// and other static-analysis issues before they reach users.
//
// Usage:
//
//     dart run tool/check_doc_snippets.dart [--print-snippets] [--help]
//
// On analysis failure the wrapped snippet bodies are suppressed by default so
// the verbatim doc source is not echoed into the retained CI log; pass
// `--print-snippets` (or set `SNIPPET_VALIDATOR_VERBOSE=1`) to opt back in.
//

import 'dart:convert';
import 'dart:io';

const _docFiles = [
  'README.md',
  'CHANGELOG.md',
  'ARCHITECTURE.md',
  'docs/MONOTONIC_TIME.md',
  'example/example.md',
];
const _snippetDir = 'tool/.snippets';

// GitHub Actions annotation prefix.
String get _errorPrefix => Platform.environment.containsKey('GITHUB_ACTIONS')
    ? '::error::'
    : 'error: ';

const _usage = '''
Validate Dart code snippets embedded in project documentation.

Extracts `dart` fenced code blocks from README.md, CHANGELOG.md,
ARCHITECTURE.md, docs/MONOTONIC_TIME.md, and example/example.md, wraps
fragments in a minimal harness, and runs `dart analyze` over them.

Usage: dart run tool/check_doc_snippets.dart [options]

Options:
  --print-snippets   On analysis failure, also echo the wrapped snippet body
                     for each failing snippet. Off by default: the body is the
                     verbatim doc source and is written to the retained CI log.
                     Enable only when triaging a failure (ideally locally). A
                     best-effort redaction pass strips obvious secret-shaped
                     tokens first, but is not a guarantee.
  -h, --help         Show this help and exit.

Environment:
  SNIPPET_VALIDATOR_VERBOSE=1   Same effect as --print-snippets.
''';

/// Metadata captured for each extracted snippet so analyzer output can be
/// attributed back to its origin (doc file + index) after the batched
/// `dart analyze` run, and so the wrapped body can optionally be echoed.
typedef SnippetMeta = ({String fileName, int index, String wrapped});

Future<void> main(List<String> args) async {
  // Argument parsing is intentionally dependency-free (no package:args): the
  // tool takes one optional boolean flag, so a small hand-rolled loop is
  // clearer than adding a dependency to CI tooling. `--print-snippets` and
  // `SNIPPET_VALIDATOR_VERBOSE=1` are equivalent.
  var printSnippets = Platform.environment['SNIPPET_VALIDATOR_VERBOSE'] == '1';
  for (final arg in args) {
    switch (arg) {
      case '--print-snippets':
        printSnippets = true;
      case '-h' || '--help':
        stdout.write(_usage);
        return;
      default:
        stderr.writeln('${_errorPrefix}Unknown argument: $arg\n');
        stderr.write(_usage);
        exit(2);
    }
  }

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
  final snippetMeta = <String, SnippetMeta>{};

  try {
    for (final fileName in _docFiles) {
      final file = File(fileName);
      if (!file.existsSync()) {
        stdout.writeln('Skipping missing file: $fileName');
        continue;
      }
      filesFound++;

      final content = file.readAsStringSync();
      final snippets = extractDartSnippets(content);

      if (snippets.isEmpty) {
        stdout.writeln('No Dart snippets found in $fileName');
        continue;
      }

      stdout.writeln(
        'Extracting ${snippets.length} snippet(s) from $fileName...',
      );

      var snippetIndex = 0;
      for (final snippet in snippets) {
        snippetIndex++;

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
        '`dart analyze --format=machine ${dir.path}`...',
      );
      // `--format=machine` emits one diagnostic per line as
      // `SEVERITY|TYPE|CODE|PATH|LINE|COL|LENGTH|MESSAGE`, each row carrying
      // its file path explicitly. This replaces the previous
      // `stdout.contains(path)` substring match, which was sensitive to
      // absolute-vs-relative paths, separator and case differences, and
      // missed diagnostics emitted on stderr (NTS-22).
      final result = await Process.run('dart', [
        'analyze',
        '--format=machine',
        dir.path,
      ]);
      if (result.exitCode != 0) {
        final stdoutStr = result.stdout.toString();
        final stderrStr = result.stderr.toString();
        // Parse both streams: some analyzer diagnostics surface on stderr.
        final diagnostics = parseMachineDiagnostics('$stdoutStr\n$stderrStr');
        final attributed = attributeFailures(diagnostics, snippetMeta);
        final failed = attributed.keys.toSet();
        // If we cannot attribute (unexpected output shape) treat the whole
        // batch as one failure so we still exit non-zero.
        totalErrors = failed.isEmpty ? 1 : failed.length;
        // Only switch to the compact per-snippet view when *every* failing
        // (ERROR/WARNING) diagnostic was pinned to a snippet. Under partial
        // attribution an unmatched failing diagnostic would vanish entirely --
        // absent from the rendered block and stripped from the stderr dump --
        // so fall back to the raw analyzer output to guarantee nothing is
        // hidden.
        final failingCount = diagnostics
            .where((d) => _failingSeverities.contains(d.severity))
            .length;
        final attributedCount = attributed.values.fold<int>(
          0,
          (n, ds) => n + ds.length,
        );
        final rendered = attributedCount == failingCount
            ? renderAttributedDiagnostics(attributed, snippetMeta)
            : '';
        reportAnalysisFailure(
          stderr,
          printSnippets: printSnippets,
          failed: failed,
          snippetMeta: snippetMeta,
          analyzeStdout: rendered.isNotEmpty ? rendered : stdoutStr,
          // In the rendered case the per-snippet block already lists every
          // parsed diagnostic (stdout+stderr), so strip machine-format rows
          // from the raw stderr dump to avoid printing stderr-emitted
          // diagnostics twice; non-diagnostic stderr (crash banners) is
          // preserved. The fallback keeps raw stderr so a malformed,
          // unattributable (or only partially attributable) run still surfaces
          // everything for triage.
          analyzeStderr: rendered.isNotEmpty
              ? stripMachineDiagnosticLines(stderrStr)
              : stderrStr,
        );
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

/// Writes the failure report for a non-zero `dart analyze` run to [sink].
///
/// This is the security-sensitive gate introduced by NTS-23. By default
/// ([printSnippets] false) the verbatim wrapped snippet bodies are
/// *suppressed*: only the per-snippet attribution, the analyzer diagnostics,
/// and a hint pointing at the opt-in flag are written, so the doc source is
/// never echoed into the retained CI log. When [printSnippets] is set the
/// bodies are written through [redactSnippetSecrets] as a best-effort
/// defence-in-depth pass (not a guarantee -- the body is verbatim doc source).
///
/// [failed] is the set of snippet-file paths that attribution could pin the
/// failure to. The `stdout.contains(path)` match behind it is fragile
/// (robustness is tracked as NTS-22); when it comes back empty the verbose
/// path falls back to printing every snippet in [snippetMeta] so the opt-in
/// flag still yields something to triage. The suppression branch is
/// unconditional regardless of [failed], so the default never leaks a body.
///
/// Takes a [StringSink] (rather than writing to `stderr` directly) so the gate
/// can be exercised by unit tests with a [StringBuffer]; [errorPrefix] defaults
/// to the environment-derived [_errorPrefix] but is injectable for the same
/// reason.
void reportAnalysisFailure(
  StringSink sink, {
  required bool printSnippets,
  required Set<String> failed,
  required Map<String, SnippetMeta> snippetMeta,
  required String analyzeStdout,
  required String analyzeStderr,
  String? errorPrefix,
}) {
  final prefix = errorPrefix ?? _errorPrefix;
  for (final path in failed) {
    final m = snippetMeta[path]!;
    sink.writeln(
      '${prefix}Snippet ${m.index} in ${m.fileName} '
      'failed analysis ($path).',
    );
  }
  sink.writeln('--- dart analyze output ---');
  sink.writeln(analyzeStdout);
  sink.writeln(analyzeStderr);
  if (printSnippets) {
    final toPrint = failed.isNotEmpty ? failed : snippetMeta.keys;
    for (final path in toPrint) {
      final m = snippetMeta[path]!;
      sink.writeln('--- Wrapped snippet ${m.index} of ${m.fileName} ---');
      sink.writeln(redactSnippetSecrets(m.wrapped));
    }
  } else {
    sink.writeln(
      'Wrapped snippet bodies suppressed to avoid echoing doc source '
      'into the retained CI log. Re-run with --print-snippets (or set '
      'SNIPPET_VALIDATOR_VERBOSE=1) to print them.',
    );
  }
}

/// A single parsed `dart analyze --format=machine` diagnostic row.
///
/// Machine format emits one diagnostic per line as
/// `SEVERITY|TYPE|CODE|PATH|LINE|COL|LENGTH|MESSAGE`, with `|`, `\`, and
/// newlines backslash-escaped inside individual fields.
typedef MachineDiagnostic = ({
  String severity,
  String code,
  String path,
  int line,
  int column,
  String message,
});

/// Parses `dart analyze --format=machine` output (pass the combined
/// stdout+stderr) into structured [MachineDiagnostic]s.
///
/// Lines that are blank, malformed (fewer than the eight expected fields), or
/// whose first field is not a known severity are skipped, so non-diagnostic
/// noise (progress text, a trailing summary, a crash banner) is ignored rather
/// than misparsed. Rows are split on *unescaped* `|` only (via
/// [_splitMachineFields]) because machine format escapes a literal pipe as
/// `\|`; the leading fields (SEVERITY, CODE, PATH, LINE, COL) are then read by
/// fixed index. PATH thus stays at index 3 even when it (or an earlier field)
/// contains an escaped pipe, and the MESSAGE field -- which may carry either an
/// escaped `\|` or a raw `|` -- is reconstructed by rejoining fields 7..end.
List<MachineDiagnostic> parseMachineDiagnostics(String output) {
  final diagnostics = <MachineDiagnostic>[];
  for (final line in const LineSplitter().convert(output)) {
    if (!_isMachineDiagnosticRow(line)) continue;
    final fields = _splitMachineFields(line);
    diagnostics.add((
      severity: fields[0],
      code: _unescapeMachineField(fields[2]),
      path: _unescapeMachineField(fields[3]),
      line: int.tryParse(fields[4]) ?? 0,
      column: int.tryParse(fields[5]) ?? 0,
      message: _unescapeMachineField(fields.sublist(7).join('|')),
    ));
  }
  return diagnostics;
}

/// The severities `--format=machine` can lead a diagnostic row with.
const _machineSeverities = {'ERROR', 'WARNING', 'INFO'};

/// Severities that make `dart analyze` exit non-zero, and so are attributed
/// back to a snippet. INFO-level diagnostics are non-fatal noise. Shared by
/// [attributeFailures] (its default filter) and the attribution-completeness
/// check in [main] so the two cannot disagree on what "failing" means.
const _failingSeverities = {'ERROR', 'WARNING'};

/// Splits a `--format=machine` row into fields on *unescaped* `|` only.
///
/// Machine format backslash-escapes literal pipes (`\|`) and backslashes
/// (`\\`) inside fields, so a naive `String.split('|')` would treat an escaped
/// pipe in (e.g.) PATH as a delimiter, shift every later field, and mis-parse
/// PATH/LINE/COL. This scanner keeps each `\X` pair as literal field text --
/// leaving the escape intact for [_unescapeMachineField] to resolve -- and
/// breaks the row only at a bare `|`.
List<String> _splitMachineFields(String line) {
  final fields = <String>[];
  final field = StringBuffer();
  for (var i = 0; i < line.length; i++) {
    final ch = line[i];
    if (ch == r'\' && i + 1 < line.length) {
      field
        ..write(ch)
        ..write(line[i + 1]);
      i++;
      continue;
    }
    if (ch == '|') {
      fields.add(field.toString());
      field.clear();
      continue;
    }
    field.write(ch);
  }
  fields.add(field.toString());
  return fields;
}

/// True when [line] is a `--format=machine` diagnostic row: eight or more
/// fields (split on unescaped `|`) led by a known severity. Shared by
/// [parseMachineDiagnostics] (to select rows to parse) and
/// [stripMachineDiagnosticLines] (to select rows to drop), so the two cannot
/// drift apart on what counts as a diagnostic line.
bool _isMachineDiagnosticRow(String line) {
  if (line.isEmpty) return false;
  final fields = _splitMachineFields(line);
  return fields.length >= 8 && _machineSeverities.contains(fields[0]);
}

/// Removes `--format=machine` diagnostic rows from [text], preserving every
/// other line (progress text, blank lines, analyzer crash banners).
///
/// Used on the raw stderr dump in the rendered failure report: diagnostics are
/// parsed from stdout+stderr and re-emitted in the per-snippet block, so an
/// stderr-emitted row would otherwise be printed twice. Stripping the rows here
/// keeps the report compact while still surfacing non-diagnostic stderr noise.
String stripMachineDiagnosticLines(String text) => const LineSplitter()
    .convert(text)
    .where((line) => !_isMachineDiagnosticRow(line))
    .join('\n');

/// Reverses the backslash escaping `--format=machine` applies inside fields
/// (`\|`, `\\`, `\n`, `\r`). Run over the PATH field this also un-doubles the
/// backslashes a Windows analyzer emits, so the result matches an on-disk path.
String _unescapeMachineField(String field) =>
    field.replaceAllMapped(RegExp(r'\\(.)'), (m) {
      switch (m[1]) {
        case 'n':
          return '\n';
        case 'r':
          return '\r';
        default:
          return m[1]!;
      }
    });

/// Attributes each diagnostic in [diagnostics] back to the snippet file that
/// produced it, returning a map of matched [snippetMeta] key -> its
/// diagnostics. Unmatched diagnostics (e.g. from outside the snippet dir) are
/// dropped.
///
/// Only diagnostics whose severity is in [failingSeverities] (ERROR and
/// WARNING by default) are attributed: those are exactly the severities that
/// make `dart analyze` exit non-zero. INFO-level lints (e.g. FILE_NAMES firing
/// on the synthetic `<doc>_<n>.dart` snippet filenames) are non-fatal noise and
/// would otherwise mis-attribute every snippet as failed once an unrelated
/// error triggered the run.
///
/// Matching is by *canonical* path rather than the previous fragile substring
/// test: [canonicalize] reduces both the analyzer-reported path and each
/// snippet path to a comparable key. The default ([_canonicalPathKey]) resolves
/// symlinks, absolutises, and lowercases, so absolute-vs-relative, separator,
/// and case-insensitive-filesystem differences all collapse to the same key.
/// Tests inject a pure variant so no real files are required.
Map<String, List<MachineDiagnostic>> attributeFailures(
  List<MachineDiagnostic> diagnostics,
  Map<String, SnippetMeta> snippetMeta, {
  String Function(String path) canonicalize = _canonicalPathKey,
  Set<String> failingSeverities = _failingSeverities,
}) {
  final byCanonical = <String, String>{
    for (final key in snippetMeta.keys) canonicalize(key): key,
  };
  final attributed = <String, List<MachineDiagnostic>>{};
  for (final d in diagnostics) {
    if (!failingSeverities.contains(d.severity)) continue;
    final match = byCanonical[canonicalize(d.path)];
    if (match != null) {
      (attributed[match] ??= <MachineDiagnostic>[]).add(d);
    }
  }
  return attributed;
}

/// Canonical comparison key for a filesystem [path]: symlinks resolved and the
/// path absolutised when it exists (falling back to a plain absolutise when it
/// does not), then lowercased. Lowercasing is the pragmatic form of the
/// "absolute + lowercase on case-insensitive filesystems" option from the
/// NTS-22 acceptance: it can only ever over-match two paths differing solely by
/// case, which the generated `<doc>_<n>.dart` snippet names never are.
String _canonicalPathKey(String path) {
  String resolved;
  try {
    resolved = File(path).resolveSymbolicLinksSync();
  } on FileSystemException {
    resolved = File(path).absolute.path;
  }
  return resolved.toLowerCase();
}

/// Renders [attributed] diagnostics into a compact, human-readable block for
/// the failure report -- one line per diagnostic, tagged with the originating
/// doc file and snippet index. Returns an empty string when nothing was
/// attributed (the caller then falls back to the raw analyzer output).
String renderAttributedDiagnostics(
  Map<String, List<MachineDiagnostic>> attributed,
  Map<String, SnippetMeta> snippetMeta,
) {
  final buf = StringBuffer();
  for (final entry in attributed.entries) {
    final m = snippetMeta[entry.key]!;
    for (final d in entry.value) {
      // `parseMachineDiagnostics` unescapes `\n`/`\r` into real newlines, so a
      // multi-line analyzer message would otherwise break the one-line-per-
      // diagnostic contract. Re-escape them to visible tokens before writing.
      final message = d.message.replaceAll('\n', r'\n').replaceAll('\r', r'\r');
      buf.writeln(
        '${m.fileName} (snippet ${m.index}): ${d.severity} ${d.code} '
        'at ${d.line}:${d.column} - $message',
      );
    }
  }
  return buf.toString();
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
  final repoRootPrefix = repoRoot.endsWith(sep) ? repoRoot : '$repoRoot$sep';
  if (canonical != repoRoot && !canonical.startsWith(repoRootPrefix)) {
    stderr.writeln(
      '${_errorPrefix}Refusing to delete ${dir.path}: '
      'canonical path $canonical is outside the repository root $repoRoot.',
    );
    exit(1);
  }
}

/// Extracts the body of every fenced ` ```dart ` code block in [content].
///
/// CommonMark §4.5 permits an opening or closing fence to be indented by up
/// to three spaces; fences indented four or more spaces are interpreted as
/// indented code blocks (§4.4) instead. Both fences are therefore anchored
/// to the start of a line with ` {0,3}` so that blocks nested inside list
/// items are picked up rather than silently skipped, while genuinely
/// over-indented blocks remain ignored.
///
/// Tab indentation is deliberately not matched: §2.2 expands a leading tab
/// to the next multiple of four columns, so a tab-prefixed fence is always
/// at or beyond column 4 and is therefore an indented code block, not a
/// fenced one. Blockquote (`>`) and admonition prefixes are likewise out of
/// scope -- the validator does not currently strip them, so fences inside
/// blockquotes are skipped. Add explicit handling here if a use case
/// appears.
///
/// Only three-backtick `dart`-tagged fences are recognised because this repo
/// neither uses four-plus-backtick fences nor tilde fences (see NTS-24 "Out
/// of scope").
///
/// CRLF line endings are normalised so Windows checkouts behave identically
/// to POSIX ones. The captured body is returned verbatim, including any
/// leading indentation -- Dart is whitespace-insensitive at the statement
/// level, so the downstream wrapper in [_prepareSnippet] does not need a
/// dedent pass.
List<String> extractDartSnippets(String content) {
  final normalized = content.replaceAll('\r\n', '\n');
  return _snippetRegex
      .allMatches(normalized)
      .map((match) => match.group(1)!)
      .toList(growable: false);
}

// Multi-line + dot-all so `.` spans newlines inside the lazy body capture
// while `^`/`$` continue to anchor on line boundaries for the surrounding
// fences. The lazy `(.*?)` prevents the body from greedily swallowing
// subsequent fences when a document contains several snippets. Indentation
// is spaces-only per CommonMark §2.2 tab-expansion semantics; see the
// `extractDartSnippets` docstring.
final RegExp _snippetRegex = RegExp(
  r'^ {0,3}```dart[ \t]*\n(.*?)\n^ {0,3}```[ \t]*$',
  multiLine: true,
  dotAll: true,
);

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

/// Best-effort redaction of obvious secret-shaped substrings in [body] before
/// a failing snippet is echoed to the (retained) CI log.
///
/// This runs only on the opt-in `--print-snippets` /
/// `SNIPPET_VALIDATOR_VERBOSE=1` path and is defence-in-depth, not a control:
/// the real protection is keeping secrets out of the documentation corpus.
/// It is deliberately conservative -- it targets a small set of unambiguous
/// shapes so it does not mangle ordinary example code, accepting false
/// negatives in exchange for not corrupting legitimate snippets:
///
///  * assignments keyed on a secret-ish identifier (`password`, `secret`,
///    `token`, `api_key`, `client_secret`, `access_key`, `authorization`),
///  * `Bearer <token>` authorization values,
///  * AWS access-key IDs (`AKIA` + 16 base32 chars),
///  * PEM private-key blocks.
///
/// Each match has its value replaced with `<REDACTED>` while the surrounding
/// structure (key name, separator, quoting) is preserved so the redaction is
/// obvious to a human reading the log.
String redactSnippetSecrets(String body) {
  var out = body;

  // PEM private-key blocks (any key type), including the wrapping markers.
  // Done first so the multi-line block is collapsed before the line-oriented
  // patterns below can partially match its base64 payload.
  out = out.replaceAll(
    RegExp(
      r'-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?'
      r'-----END [A-Z ]*PRIVATE KEY-----',
    ),
    '<REDACTED PRIVATE KEY>',
  );

  // `Bearer <token>` (Authorization header style). Run before the generic
  // key/value pass so the token (not just the word "Bearer") is removed.
  out = out.replaceAllMapped(
    RegExp(r'(Bearer\s+)[A-Za-z0-9._~+/=-]+', caseSensitive: false),
    (m) => '${m.group(1)}<REDACTED>',
  );

  // AWS access-key IDs.
  out = out.replaceAll(RegExp(r'AKIA[0-9A-Z]{16}'), '<REDACTED>');

  // key: "value" / key = 'value' / key=value, keyed on a secret-ish name.
  // Group 1 captures the key, separator, and any opening quote; the value run
  // up to the next quote, whitespace, comma, semicolon, or closing bracket is
  // dropped.
  out = out.replaceAllMapped(
    RegExp(
      r'''((?:password|passwd|secret|token|api[_-]?key|apikey|access[_-]?key|client[_-]?secret|authorization)\s*[:=]\s*["']?)[^"'\s,;)}]+''',
      caseSensitive: false,
    ),
    (m) => '${m.group(1)}<REDACTED>',
  );

  return out;
}

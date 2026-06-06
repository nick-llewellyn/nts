// Unit tests for the snippet-discovery regex used by
// `tool/check_doc_snippets.dart`. The validator scans Markdown sources for
// fenced ` ```dart ` blocks and feeds the bodies through `dart analyze`, so
// any fence it fails to recognise is a snippet that ships untested. Bug
// NTS-24 surfaced that the previous regex required the closing fence to sit
// in column 0, which silently dropped blocks nested in list items. These
// tests pin down the post-fix behaviour against CommonMark §4.5 -- 0-3
// spaces of indentation accepted on either fence, 4+ spaces treated as an
// indented code block and skipped. Tab indentation is also skipped because
// §2.2 expands a leading tab to column 4, putting it outside fenced-code
// territory. Blockquote (`>`) and admonition prefixes are out of scope.
//
// `@TestOn('vm')` matches the tool itself, which uses `dart:io` and is never
// intended to run in a browser.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/check_doc_snippets.dart';

void main() {
  group('extractDartSnippets', () {
    test('extracts a top-level fenced Dart block', () {
      const markdown = '''
Some prose.

```dart
final x = 1;
```

More prose.
''';
      final snippets = extractDartSnippets(markdown);
      expect(snippets, hasLength(1));
      expect(snippets.single, 'final x = 1;');
    });

    test('extracts a 2-space-indented fence inside a list item', () {
      const markdown = '''
- Bullet introducing a snippet:

  ```dart
  final y = 2;
  ```
''';
      final snippets = extractDartSnippets(markdown);
      expect(snippets, hasLength(1));
      // Body indentation is preserved -- Dart is whitespace-insensitive at
      // the statement level so the downstream wrapper does not need to
      // dedent.
      expect(snippets.single, '  final y = 2;');
    });

    test('extracts a 3-space-indented fence (CommonMark upper bound)', () {
      const markdown = '''
   ```dart
   final z = 3;
   ```
''';
      final snippets = extractDartSnippets(markdown);
      expect(snippets, hasLength(1));
      expect(snippets.single, '   final z = 3;');
    });

    test('skips a 4-space-indented fence (indented code block per §4.4)', () {
      const markdown = '''
    ```dart
    final ignored = 4;
    ```
''';
      // Four leading spaces puts the line outside fenced-code territory and
      // into indented-code-block territory, so the validator must not pick
      // it up. (The block is still rendered as `dart` source by some
      // renderers, but that is out of scope per the NTS-24 acceptance.)
      expect(extractDartSnippets(markdown), isEmpty);
    });

    test('extracts multiple blocks from the same document', () {
      const markdown = '''
```dart
final a = 1;
```

Intervening prose.

- And one nested in a list:

  ```dart
  final b = 2;
  ```
''';
      final snippets = extractDartSnippets(markdown);
      expect(snippets, hasLength(2));
      expect(snippets[0], 'final a = 1;');
      expect(snippets[1], '  final b = 2;');
    });

    test('normalises CRLF line endings before matching', () {
      // Authored on a Windows checkout (or saved by an editor that emits
      // CRLF) -- the validator must still find the fence.
      const markdown = '```dart\r\nfinal w = 5;\r\n```\r\n';
      final snippets = extractDartSnippets(markdown);
      expect(snippets, hasLength(1));
      expect(snippets.single, 'final w = 5;');
    });

    test('ignores fences tagged with a different language', () {
      const markdown = '''
```python
print("not dart")
```

```rust
fn main() {}
```
''';
      expect(extractDartSnippets(markdown), isEmpty);
    });

    test('skips a tab-indented opening fence (CommonMark §2.2)', () {
      // §2.2 expands a leading tab to the next multiple of four columns,
      // so a tab-prefixed fence sits at column 4 -- indented-code-block
      // territory, not a fenced block. The regex therefore restricts
      // indentation to ` {0,3}` rather than `[ \t]{0,3}`.
      const markdown = '\t```dart\n\tfinal t = 6;\n\t```\n';
      expect(extractDartSnippets(markdown), isEmpty);
    });
  });

  // NTS-23: the failure path can opt back into echoing wrapped snippet
  // bodies, but only after a best-effort redaction of obvious secret-shaped
  // tokens. These pin that redaction down without exercising the full
  // (process-spawning) failure path.
  group('redactSnippetSecrets', () {
    test('redacts secret-keyed assignments while preserving structure', () {
      const body = 'final apiKey = "sk-LIVE-abcdef123456";';
      final out = redactSnippetSecrets(body);
      expect(out, isNot(contains('sk-LIVE-abcdef123456')));
      expect(out, contains('<REDACTED>'));
      // Key name is preserved so the redaction reads clearly in the log.
      expect(out, contains('apiKey'));
    });

    test('redacts Bearer authorization tokens', () {
      const body = "headers['Authorization'] = 'Bearer abc.def.GHI-123';";
      final out = redactSnippetSecrets(body);
      expect(out, isNot(contains('abc.def.GHI-123')));
      expect(out, contains('Bearer <REDACTED>'));
    });

    test('redacts AWS access-key IDs', () {
      const body = 'const key = "AKIAIOSFODNN7EXAMPLE";';
      final out = redactSnippetSecrets(body);
      expect(out, isNot(contains('AKIAIOSFODNN7EXAMPLE')));
      expect(out, contains('<REDACTED>'));
    });

    test('collapses PEM private-key blocks, including the markers', () {
      const body =
          '-----BEGIN PRIVATE KEY-----\n'
          'MIIBVgIBADANBgkqhkiG9w0BAQEFA\n'
          '-----END PRIVATE KEY-----';
      final out = redactSnippetSecrets(body);
      expect(out, isNot(contains('MIIBVgIBADANBgkqhkiG9w0BAQEFA')));
      expect(out, contains('<REDACTED PRIVATE KEY>'));
    });

    test('leaves ordinary snippet code untouched', () {
      const body = 'final sample = await client.query(spec);\nprint(sample);';
      expect(redactSnippetSecrets(body), body);
    });
  });

  // NTS-23: the core security behaviour of this change is that the failure
  // report suppresses the verbatim wrapped snippet body unless explicitly
  // opted in. The redaction tests above only cover the opt-in payload; these
  // pin the *gate* itself so a future refactor cannot silently flip the
  // default to "echo the body" while the redaction tests stay green.
  // `reportAnalysisFailure` takes a StringSink so the path is exercised
  // directly, with no analyzer subprocess.
  group('reportAnalysisFailure (NTS-23 suppression gate)', () {
    const secret = 'sk-live-LEAKED-DO-NOT-LOG-9999';
    final meta = <String, SnippetMeta>{
      '/tmp/snippets/README_md_1.dart': (
        fileName: 'README.md',
        index: 1,
        wrapped: 'void main() {\n  const apiKey = "$secret";\n}\n',
      ),
    };

    test('default mode suppresses the body and emits the hint', () {
      final buf = StringBuffer();
      reportAnalysisFailure(
        buf,
        printSnippets: false,
        failed: meta.keys.toSet(),
        snippetMeta: meta,
        analyzeStdout: 'error - Undefined name - README_md_1.dart:2:9',
        analyzeStderr: '',
        errorPrefix: 'error: ',
      );
      final out = buf.toString();
      expect(out, contains('suppressed'));
      // No body header, no body content (redacted or otherwise), no secret.
      // The hint text itself contains the words "Wrapped snippet", so match
      // the body *header* prefix ('--- Wrapped snippet') to distinguish them.
      expect(out, isNot(contains('--- Wrapped snippet')));
      expect(out, isNot(contains('apiKey')));
      expect(out, isNot(contains(secret)));
    });

    test('default mode suppresses even when attribution is empty', () {
      // The security property must hold regardless of the fragile (NTS-22)
      // path-substring attribution: an empty `failed` set must not leak a
      // body in the default branch.
      final buf = StringBuffer();
      reportAnalysisFailure(
        buf,
        printSnippets: false,
        failed: <String>{},
        snippetMeta: meta,
        analyzeStdout: '',
        analyzeStderr: '',
        errorPrefix: 'error: ',
      );
      final out = buf.toString();
      expect(out, contains('suppressed'));
      expect(out, isNot(contains('apiKey')));
      expect(out, isNot(contains(secret)));
    });

    test('verbose mode prints the redacted body, no raw secret, no hint', () {
      final buf = StringBuffer();
      reportAnalysisFailure(
        buf,
        printSnippets: true,
        failed: meta.keys.toSet(),
        snippetMeta: meta,
        analyzeStdout: '',
        analyzeStderr: '',
        errorPrefix: 'error: ',
      );
      final out = buf.toString();
      expect(out, contains('--- Wrapped snippet 1 of README.md ---'));
      expect(out, contains('<REDACTED>'));
      expect(out, isNot(contains(secret)));
      expect(out, isNot(contains('suppressed')));
    });

    test(
      'verbose mode falls back to all snippets when attribution is empty',
      () {
        // With `failed` empty the opt-in path still prints something to triage
        // (every snippet) rather than nothing -- but still redacted.
        final buf = StringBuffer();
        reportAnalysisFailure(
          buf,
          printSnippets: true,
          failed: <String>{},
          snippetMeta: meta,
          analyzeStdout: '',
          analyzeStderr: '',
          errorPrefix: 'error: ',
        );
        final out = buf.toString();
        expect(out, contains('--- Wrapped snippet 1 of README.md ---'));
        expect(out, contains('<REDACTED>'));
        expect(out, isNot(contains(secret)));
      },
    );
  });

  // NTS-22: failure attribution now parses `dart analyze --format=machine`
  // rows and matches them back to snippets by canonical path, replacing the
  // fragile `stdout.contains(path)` substring test. These pin the pure parser
  // and attributor; the canonicalizer is injected so no analyzer subprocess
  // (and, for most cases, no real file) is needed.
  group('parseMachineDiagnostics (NTS-22)', () {
    test('parses a well-formed diagnostic row', () {
      const out =
          'ERROR|COMPILE_TIME_ERROR|INVALID_ASSIGNMENT|'
          '/snips/README_md_1.dart|2|11|12|'
          "A value of type 'String' can't be assigned to 'int'.";
      final d = parseMachineDiagnostics(out);
      expect(d, hasLength(1));
      expect(d.single.severity, 'ERROR');
      expect(d.single.code, 'INVALID_ASSIGNMENT');
      expect(d.single.path, '/snips/README_md_1.dart');
      expect(d.single.line, 2);
      expect(d.single.column, 11);
      expect(d.single.message, contains("can't be assigned"));
    });

    test('skips blank and malformed (non-diagnostic) lines', () {
      const out =
          'Analyzing...\n'
          '\n'
          'ERROR|COMPILE_TIME_ERROR|X|/snips/a_1.dart|1|1|1|boom\n'
          'short|row';
      final d = parseMachineDiagnostics(out);
      expect(d, hasLength(1));
      expect(d.single.path, '/snips/a_1.dart');
    });

    test('reconstructs a message that itself contains a pipe', () {
      // The MESSAGE field can legitimately contain `|`; splitting on `|`
      // over-splits it, so the parser rejoins the tail. The path must be
      // unaffected.
      const out = 'WARNING|HINT|CODE|/snips/b_2.dart|3|4|5|left | right';
      final d = parseMachineDiagnostics(out);
      expect(d.single.path, '/snips/b_2.dart');
      expect(d.single.message, 'left | right');
    });

    test('unescapes doubled backslashes in a Windows-style path', () {
      // machine format doubles backslashes inside fields, so a Windows path
      // arrives with `\\` separators; the parser must un-double them back to
      // the on-disk single-backslash form.
      const out = r'ERROR|T|C|C:\\snips\\c_1.dart|1|1|1|msg';
      final d = parseMachineDiagnostics(out);
      expect(d.single.path, r'C:\snips\c_1.dart');
    });

    test('an escaped pipe in PATH does not shift later fields', () {
      // machine format escapes a literal pipe as `\|`. Splitting on raw `|`
      // would treat it as a delimiter and shift PATH/LINE/COL; the parser must
      // split on unescaped `|` only, so PATH stays at index 3 and unescapes to
      // a single literal `|`.
      const out = r'ERROR|T|C|/snips/we\|ird_1.dart|7|3|9|boom';
      final d = parseMachineDiagnostics(out);
      expect(d, hasLength(1));
      expect(d.single.path, '/snips/we|ird_1.dart');
      expect(d.single.line, 7);
      expect(d.single.column, 3);
      expect(d.single.message, 'boom');
    });

    test('reconstructs a message containing an escaped pipe', () {
      // An escaped pipe inside MESSAGE must survive splitting and unescape to a
      // literal `|`, with PATH unaffected.
      const out = r'WARNING|HINT|CODE|/snips/b_2.dart|3|4|5|left \| right';
      final d = parseMachineDiagnostics(out);
      expect(d.single.path, '/snips/b_2.dart');
      expect(d.single.message, 'left | right');
    });

    test('parses diagnostics regardless of which stream they came from', () {
      // main() concatenates stdout+stderr before parsing; a row that arrived
      // on stderr (here following an empty stdout) must still be picked up.
      const combined =
          '\n'
          'ERROR|COMPILE_TIME_ERROR|X|/snips/d_1.dart|9|9|1|from stderr';
      final d = parseMachineDiagnostics(combined);
      expect(d, hasLength(1));
      expect(d.single.path, '/snips/d_1.dart');
    });
  });

  // NTS-22: in the rendered failure report the per-snippet block already lists
  // every parsed diagnostic, so the raw stderr dump has its machine rows
  // stripped to avoid printing stderr-emitted diagnostics twice.
  group('stripMachineDiagnosticLines (NTS-22)', () {
    test('drops machine diagnostic rows but keeps non-diagnostic noise', () {
      const stderrText =
          'Analyzing...\n'
          'ERROR|COMPILE_TIME_ERROR|X|/snips/a_1.dart|1|1|1|boom\n'
          'analyzer crashed: stack overflow';
      final out = stripMachineDiagnosticLines(stderrText);
      expect(out, contains('Analyzing...'));
      expect(out, contains('analyzer crashed: stack overflow'));
      expect(out, isNot(contains('boom')));
      expect(out, isNot(contains('/snips/a_1.dart')));
    });

    test(
      'preserves a row that itself contains a pipe but is not a diagnostic',
      () {
        // Fewer than eight fields, or a non-severity lead field, is not a
        // diagnostic row and must survive (e.g. an unrelated tool banner).
        const stderrText = 'some | piped | banner | text';
        expect(stripMachineDiagnosticLines(stderrText), stderrText);
      },
    );

    test('returns empty for empty input', () {
      expect(stripMachineDiagnosticLines(''), isEmpty);
    });
  });

  group('attributeFailures (NTS-22)', () {
    SnippetMeta metaFor(String fileName, int index) =>
        (fileName: fileName, index: index, wrapped: 'void main() {}\n');
    final snippetMeta = <String, SnippetMeta>{
      'tool/.snippets/README_md_1.dart': metaFor('README.md', 1),
      'tool/.snippets/example_example_md_2.dart': metaFor(
        'example/example.md',
        2,
      ),
    };
    // Pure canonicalizer (lowercase) so the test needs no real files.
    String lower(String p) => p.toLowerCase();

    test('attributes each diagnostic to its snippet key', () {
      final diags = parseMachineDiagnostics(
        'ERROR|T|C|tool/.snippets/README_md_1.dart|1|1|1|boom\n'
        'ERROR|T|C|tool/.snippets/example_example_md_2.dart|2|1|1|bang',
      );
      final attributed = attributeFailures(
        diags,
        snippetMeta,
        canonicalize: lower,
      );
      expect(attributed.keys, hasLength(2));
      expect(
        attributed['tool/.snippets/README_md_1.dart']!.single.message,
        'boom',
      );
      expect(
        attributed['tool/.snippets/example_example_md_2.dart']!.single.message,
        'bang',
      );
    });

    test('matches despite case differences (case-insensitive FS shape)', () {
      // Analyzer reports an upper-cased variant of the same path; the
      // lowercasing canonicalizer must still pin it to the snippet.
      final diags = parseMachineDiagnostics(
        'ERROR|T|C|TOOL/.SNIPPETS/README_MD_1.dart|1|1|1|boom',
      );
      final attributed = attributeFailures(
        diags,
        snippetMeta,
        canonicalize: lower,
      );
      expect(attributed.keys, ['tool/.snippets/README_md_1.dart']);
    });

    test('drops diagnostics that match no snippet', () {
      final diags = parseMachineDiagnostics(
        'ERROR|T|C|/somewhere/else/unrelated.dart|1|1|1|boom',
      );
      expect(
        attributeFailures(diags, snippetMeta, canonicalize: lower),
        isEmpty,
      );
    });

    test('ignores non-failing (INFO) diagnostics', () {
      // INFO-level lints (e.g. FILE_NAMES on the synthetic snippet filenames)
      // are non-fatal -- `dart analyze` exits zero for them -- so they must
      // not be attributed as failures even when an unrelated error triggers
      // the run. Only the ERROR row should be pinned.
      final diags = parseMachineDiagnostics(
        'INFO|LINT|FILE_NAMES|tool/.snippets/README_md_1.dart|1|1|1|noise\n'
        'ERROR|T|C|tool/.snippets/example_example_md_2.dart|2|1|1|real',
      );
      final attributed = attributeFailures(
        diags,
        snippetMeta,
        canonicalize: lower,
      );
      expect(attributed.keys, ['tool/.snippets/example_example_md_2.dart']);
    });

    test(
      'default canonicalizer collapses symlink/string differences to match',
      () async {
        // Exercises the real _canonicalPathKey: a string-different but
        // same-file path (on macOS the temp dir resolves through /private)
        // must collapse to the snippet key. Uses a real temp file so
        // resolveSymbolicLinksSync() has something to resolve.
        final tmp = await Directory.systemTemp.createTemp('nts22_attr_');
        try {
          final key = '${tmp.path}/README_md_1.dart';
          final f = File(key)..writeAsStringSync('void main() {}\n');
          final meta = <String, SnippetMeta>{key: metaFor('README.md', 1)};
          // Fully-resolved absolute path, a different *string* from `key`.
          final resolved = f.resolveSymbolicLinksSync();
          // Build the diagnostic directly rather than round-tripping `resolved`
          // through parseMachineDiagnostics: a Windows path contains single
          // backslashes, but machine format escapes them, so feeding the raw
          // path to the parser would let _unescapeMachineField strip separators
          // (e.g. `\U` -> `U`) and fail only on Windows. This test targets
          // _canonicalPathKey/attributeFailures, not the parser.
          final diags = <MachineDiagnostic>[
            (
              severity: 'ERROR',
              code: 'C',
              path: resolved,
              line: 1,
              column: 1,
              message: 'boom',
            ),
          ];
          // Default (filesystem) canonicalizer.
          final attributed = attributeFailures(diags, meta);
          expect(attributed.keys, [key]);
        } finally {
          await tmp.delete(recursive: true);
        }
      },
    );
  });

  group('renderAttributedDiagnostics (NTS-22)', () {
    test('keeps one line per diagnostic when a message contains newlines', () {
      // parseMachineDiagnostics unescapes `\n`/`\r` into real newlines; the
      // renderer must re-escape them so the per-snippet block stays scannable.
      final meta = <String, SnippetMeta>{
        'tool/.snippets/README_md_1.dart': (
          fileName: 'README.md',
          index: 1,
          wrapped: 'void main() {}\n',
        ),
      };
      final diags = parseMachineDiagnostics(
        'ERROR|T|C|tool/.snippets/README_md_1.dart|1|1|1|first\\nsecond\\rmore',
      );
      final attributed = attributeFailures(
        diags,
        meta,
        canonicalize: (p) => p.toLowerCase(),
      );
      final rendered = renderAttributedDiagnostics(attributed, meta);
      expect(
        const LineSplitter().convert(rendered).where((l) => l.isNotEmpty),
        hasLength(1),
      );
      expect(rendered, contains(r'first\nsecond\rmore'));
    });
  });
}

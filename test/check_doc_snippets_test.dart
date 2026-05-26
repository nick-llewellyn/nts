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
}

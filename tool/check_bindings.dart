// Canonical entry point for regenerating the FRB bindings, and the local
// equivalent of the CI `Verify FRB bindings are in sync` job. Runs
// `flutter_rust_bridge_codegen generate`, applies the post-codegen patches
// FRB cannot emit on its own (see `_lintIgnorePatches`,
// `_patchFrbGeneratedUnimplementedMessages`,
// `_patchDartFrbGeneratedUnimplementedMessages`, `_patchDartIntraDocLinks`,
// and `_patchDartFrbGeneratedDcoUnreachableMessages`), formats the
// regenerated Dart bindings, checks for orphaned generated modules
// (see `_checkForOrphanedApiModules`), and fails non-zero if
// `lib/src/ffi/` or `rust/src/frb_generated.rs` differ from the committed
// state -- including when codegen *creates* a file the repo does not yet
// track (see `_findUntrackedGeneratedFiles`; `git diff` alone reports
// only tracked-file changes).
//
// Run this script rather than `flutter_rust_bridge_codegen generate`:
// bare codegen emits the unpatched form and so reverts every patch pass
// above, which this script's own drift check then rejects.
//
// Usage:
//
//     dart run tool/check_bindings.dart
//
// Exit codes:
//   0  bindings are in sync
//   1  drift detected, an untracked generated file was found, an
//      orphaned generated module was found, or a precondition failed
//      (missing tool / wrong version)
//
// The pinned FRB version is read from `pubspec.yaml` so this script and the
// CI workflow stay in lockstep with the runtime crate.
//
// Orphaned-module check
// ---------------------
// `flutter_rust_bridge_codegen generate` regenerates
// `lib/src/ffi/api/<basename>.dart` from `rust/src/api/<basename>.rs`,
// but only if that Rust source still exposes at least one FRB-visible
// item. When the last `pub` item is removed from a Rust source (or the
// source itself is deleted), FRB drops the wire impls from
// `frb_generated.{rs,dart}` but leaves the previously-emitted Dart
// module on disk. The stale module then references symbols that no
// longer exist in the dispatcher, which surfaces as an opaque "symbol
// not found in `NtsRustLibApi`" build break under `flutter analyze` /
// `flutter test` rather than at codegen time.
//
// `_checkForOrphanedApiModules` flags any `lib/src/ffi/api/*.dart` that
// the regenerated `lib/src/ffi/frb_generated.dart` does not import,
// using the dispatcher import set as a stand-in for "this module
// contributed FRB-visible items on the most recent codegen run".
// Removal is left to the developer so an unintended deletion surfaces
// loudly rather than being papered over.

import 'dart:io';

// Paths watched for drift. Mirrors `dart_output` and `rust_output` in
// `flutter_rust_bridge.yaml`.
const _watchedPaths = <String>['lib/src/ffi', 'rust/src/frb_generated.rs'];

// Directory holding the per-Rust-module generated Dart bindings, and the
// dispatcher that imports them. Used by `_checkForOrphanedApiModules` to
// flag stale modules whose contributing Rust source no longer exposes
// any FRB-visible items.
const _generatedDartApiDir = 'lib/src/ffi/api';
const _frbGeneratedDispatcher = 'lib/src/ffi/frb_generated.dart';

// Lint-suppression patches applied after codegen. Each entry adds the
// listed lint names to the file's `// ignore_for_file:` directive.
//
// `analysis_options.yaml` enables `public_member_api_docs`,
// `prefer_final_locals`, and `prefer_const_constructors` for the entire
// package, and `lib/src/ffi/**` is intentionally not excluded so the
// local analyzer matches the surface a downstream consumer will see.
// FRB does not propagate Rust docstrings to its synthesized freezed
// wrappers / dispatcher boilerplate, and emits generated locals and
// temporaries that trip the `prefer_*` lints. None of those can be
// fixed at the Rust source level, so the offending rules are pinned at
// file scope on the generated outputs:
//
//   api/nts.dart            : public_member_api_docs (freezed wrappers)
//   frb_generated.dart      : public_member_api_docs + prefer_final_locals
//                             + prefer_const_constructors
//                             + inference_failure_on_instance_creation
//                             (dispatcher; the inference rule fires on
//                             FRB's `RustArcStaticData(...)` opaque-type
//                             initializer, which omits the unused
//                             generic parameter — see the
//                             `NtsClientImpl._kStaticData` site)
//   frb_generated.io.dart   : public_member_api_docs (FFI bindings)
//   frb_generated.web.dart  : public_member_api_docs (JS interop bindings)
//
// `prefer_single_quotes` needs no entry here: FRB's generate pipeline
// runs `dart fix` against the project's `analysis_options.yaml`, so with
// the rule enabled the emitted Dart is already single-quoted.
const _lintIgnorePatches = <String, List<String>>{
  'lib/src/ffi/api/nts.dart': <String>['public_member_api_docs'],
  'lib/src/ffi/frb_generated.dart': <String>[
    'public_member_api_docs',
    'prefer_final_locals',
    'prefer_const_constructors',
    'inference_failure_on_instance_creation',
  ],
  'lib/src/ffi/frb_generated.io.dart': <String>['public_member_api_docs'],
  'lib/src/ffi/frb_generated.web.dart': <String>['public_member_api_docs'],
};

// GitHub Actions annotation prefix; emitted only when running inside GHA so
// the workflow log surfaces drift as an error annotation.
String get _errorPrefix => Platform.environment.containsKey('GITHUB_ACTIONS')
    ? '::error::'
    : 'error: ';

Future<void> main(List<String> args) async {
  final pinnedVersion = _readPinnedFrbVersion();
  final rustPinnedVersion = _readRustPinnedFrbVersion();

  if (pinnedVersion != rustPinnedVersion) {
    stderr.writeln(
      '${_errorPrefix}flutter_rust_bridge version mismatch between '
      'pubspec.yaml and rust/Cargo.toml.\n'
      '       Dart: $pinnedVersion\n'
      '       Rust: $rustPinnedVersion\n'
      '       Coordination is required; update both sides to match.',
    );
    exit(1);
  }

  _ensureCodegenAvailable(pinnedVersion);

  await _run('flutter_rust_bridge_codegen', const ['generate']);

  // Apply lint-suppression patches that FRB does not emit on its own. Run
  // before `dart format` so the formatter sees the final content.
  _lintIgnorePatches.forEach(_addLintsToIgnoreForFile);
  _patchFrbGeneratedUnimplementedMessages();
  _patchDartFrbGeneratedUnimplementedMessages();
  _patchDartIntraDocLinks();
  final dcoPatched = _patchDartFrbGeneratedDcoUnreachableMessages();
  if (dcoPatched == 0) {
    stderr.writeln(
      '${_errorPrefix}DCO unreachable patcher found zero matches. '
      'FRB output format may have changed, breaking the \${raw[0]} assumption.',
    );
    exit(1);
  }

  // Validate the patched Dart bindings before formatting. This catches
  // patcher-induced syntax errors (e.g. if `${raw[0]}` is no longer in scope)
  // before they reach the drift check.
  await _validateGeneratedDart();

  // Format the regenerated Dart so the diff check below catches semantic
  // drift only -- not formatter noise that CI's `dart format` step would
  // otherwise re-flag. (FRB already runs rustfmt on `frb_generated.rs`.)
  await _run('dart', const ['format', 'lib/src/ffi']);

  // Detect generated modules left behind after FRB stopped contributing
  // them. Runs before the drift check so the diagnostic is the
  // dedicated orphan message rather than a generic "files differ".
  _checkForOrphanedApiModules();

  // Detect brand-new generated files the repo does not yet track. `git
  // diff` below only reports changes to tracked files, so without this
  // check a codegen run that *creates* a file (e.g. a new Rust source
  // under `rust/src/api/` emitting a new Dart module) would pass the
  // gate silently unless a tracked file happened to change alongside it.
  final untracked = await _findUntrackedGeneratedFiles();
  if (untracked.isNotEmpty) {
    stderr.writeln(
      '${_errorPrefix}found untracked file(s) under FRB bindings '
      'output paths:',
    );
    for (final path in untracked) {
      stderr.writeln('       $path');
    }
    stderr.writeln(
      '       If codegen produced them, `git add` and commit them\n'
      '       alongside the Rust change that introduced them.\n'
      '       Otherwise remove the stray file(s) and rerun this script.',
    );
    exit(1);
  }

  if (await _hasDrift()) {
    stderr.writeln(
      '${_errorPrefix}FRB bindings drifted from rust/src/api/. This run '
      'already regenerated and patched them, so commit the resulting\n'
      '       changes to lib/src/ffi/ and rust/src/frb_generated.rs.\n'
      '       To reproduce locally, run this same script -- '
      '`dart run tool/check_bindings.dart`.\n'
      '       Do not run `flutter_rust_bridge_codegen generate` directly: '
      'its unpatched\n'
      '       output reverts the post-codegen patches and re-trips this '
      'check.',
    );
    exit(1);
  }
  stdout.writeln('FRB bindings are in sync');
}

String _readPinnedFrbVersion() {
  final pubspec = File('pubspec.yaml');
  if (!pubspec.existsSync()) {
    stderr.writeln(
      '${_errorPrefix}pubspec.yaml not found (run from repo root)',
    );
    exit(1);
  }
  // Match `  flutter_rust_bridge: 2.12.0` (indented under `dependencies:`,
  // no version range, no quotes). Strict on the key name and line-anchored
  // indentation; whitespace after the colon is intentionally flexible to
  // tolerate `pub add` / YAML-formatter disagreement on the single-space
  // convention. The version literal is digits-and-dots only, so any complex
  // range or suffix would fail loudly here rather than slip past as a
  // partial match.
  final pattern = RegExp(
    r'^\s+flutter_rust_bridge:\s*([\d.]+)\s*$',
    multiLine: true,
  );
  final match = pattern.firstMatch(pubspec.readAsStringSync());
  if (match == null) {
    stderr.writeln(
      '${_errorPrefix}could not find pinned `flutter_rust_bridge:` '
      'version in pubspec.yaml',
    );
    exit(1);
  }
  return match.group(1)!;
}

String _readRustPinnedFrbVersion() {
  final cargoToml = File('rust/Cargo.toml');
  if (!cargoToml.existsSync()) {
    stderr.writeln(
      '${_errorPrefix}rust/Cargo.toml not found (run from repo root)',
    );
    exit(1);
  }
  // Match `flutter_rust_bridge = "=2.12.0"` or `flutter_rust_bridge = "2.12.0"`.
  // Strict on the dependency key/value shape (anchored to a line that starts
  // with the bare `flutter_rust_bridge` key, a single `=` separator, and a
  // double-quoted version literal with an optional leading `=` cargo-pin
  // marker); whitespace around the `=` is intentionally flexible because
  // `cargo add` / `cargo edit` and various TOML formatters disagree on
  // whether to surround the assignment with a single space. The version
  // literal itself is digits-and-dots only, so SemVer pre-release / build
  // metadata suffixes would not match and would fail loudly here rather
  // than slip past as a partial match.
  final pattern = RegExp(
    r'^flutter_rust_bridge\s*=\s*"=?([\d.]+)"',
    multiLine: true,
  );
  final match = pattern.firstMatch(cargoToml.readAsStringSync());
  if (match == null) {
    stderr.writeln(
      '${_errorPrefix}could not find pinned `flutter_rust_bridge` '
      'version in rust/Cargo.toml',
    );
    exit(1);
  }
  return match.group(1)!;
}

void _ensureCodegenAvailable(String pinnedVersion) {
  final installHint =
      '       cargo install flutter_rust_bridge_codegen '
      '--version "=$pinnedVersion" --locked';
  ProcessResult result;
  try {
    result = Process.runSync('flutter_rust_bridge_codegen', const [
      '--version',
    ]);
  } on ProcessException {
    stderr.writeln(
      '$_errorPrefix`flutter_rust_bridge_codegen` not found on PATH.\n'
      '       Install with:\n'
      '$installHint',
    );
    exit(1);
  }
  if (result.exitCode != 0) {
    stderr.writeln(
      '$_errorPrefix`flutter_rust_bridge_codegen --version` exited '
      '${result.exitCode}',
    );
    exit(1);
  }
  // `--version` prints something like: `flutter_rust_bridge_codegen 2.12.0`.
  final versionText = '${result.stdout}'.trim();
  final installed = RegExp(
    r'(\d+\.\d+\.\d+)',
  ).firstMatch(versionText)?.group(1);
  if (installed != pinnedVersion) {
    stderr.writeln(
      '${_errorPrefix}flutter_rust_bridge_codegen version mismatch.\n'
      '       installed: ${installed ?? versionText}\n'
      '       pinned   : $pinnedVersion (from pubspec.yaml)\n'
      '       Reinstall with:\n'
      '$installHint --force',
    );
    exit(1);
  }
}

Future<void> _run(String executable, List<String> args) async {
  final proc = await Process.start(
    executable,
    args,
    mode: ProcessStartMode.inheritStdio,
  );
  final code = await proc.exitCode;
  if (code != 0) {
    stderr.writeln('$_errorPrefix`$executable ${args.join(' ')}` exited $code');
    exit(code);
  }
}

// Lists files under the watched paths that exist on disk but are not
// tracked by git, sorted for deterministic output. `git status
// --porcelain` prefixes untracked entries with `?? `;
// `--untracked-files=all` makes git list individual files rather than
// collapsing a wholly-untracked directory into a single `dir/` entry,
// so the diagnostic names every offending file. Errors out on a git
// failure rather than treating "status unavailable" as "no untracked
// files".
Future<List<String>> _findUntrackedGeneratedFiles() async {
  final args = [
    'status',
    '--porcelain',
    '--untracked-files=all',
    '--',
    ..._watchedPaths,
  ];
  final status = await Process.run('git', args);
  if (status.exitCode != 0) {
    stderr.writeln(
      '$_errorPrefix`git ${args.join(' ')}` exited ${status.exitCode} '
      '(untracked-file check cannot run)',
    );
    final detail = '${status.stderr}'.trim();
    if (detail.isNotEmpty) {
      stderr.writeln('       $detail');
    }
    exit(1);
  }
  return <String>[
    // Split on LF and strip a trailing CR so CRLF output (e.g. git on
    // Windows with autocrlf) does not leave a stray `\r` on each path.
    for (final line in '${status.stdout}'.split('\n'))
      if (line.startsWith('?? '))
        line.endsWith('\r')
            ? line.substring(3, line.length - 1)
            : line.substring(3),
  ]..sort();
}

Future<bool> _hasDrift() async {
  final diff = await Process.run('git', [
    'diff',
    '--exit-code',
    '--',
    ..._watchedPaths,
  ]);
  if (diff.exitCode == 0) return false;
  // Mirror the CI step: print the file-level diff stat for context.
  final stat = await Process.run('git', [
    'diff',
    '--stat',
    '--',
    ..._watchedPaths,
  ]);
  stdout.write(stat.stdout);
  return true;
}

// Walk `lib/src/ffi/api/*.dart` and flag any primary module file that
// the regenerated dispatcher does not import. FRB writes one `import
// 'api/<basename>.dart';` line into `frb_generated.dart` for every
// Rust source under `rust/src/api/` that contributed at least one
// FRB-visible item on the most recent codegen run, so the dispatcher's
// import set is the authoritative "still contributing" stand-in.
//
// `*.freezed.dart` and `*.g.dart` companions are intentionally ignored
// by this check: they're emitted by other generators driven from the
// primary file's `part 'X.freezed.dart';` / `part 'X.g.dart';`
// directives, and the dispatcher does not import them directly. When
// the primary file is reported as orphaned, any companions next to it
// must be removed manually alongside it (the remediation message below
// names them explicitly); the check does not flag a stray companion on
// its own.
//
// Detection is read-only on purpose. Auto-deleting risks papering over
// a removal that wasn't intended; the diagnostic instructs the
// developer to remove the file explicitly.
void _checkForOrphanedApiModules() {
  final apiDir = Directory(_generatedDartApiDir);
  if (!apiDir.existsSync()) return;

  final dispatcher = File(_frbGeneratedDispatcher);
  if (!dispatcher.existsSync()) {
    stderr.writeln(
      '${_errorPrefix}expected dispatcher file not found: '
      '$_frbGeneratedDispatcher (post-codegen orphan check cannot run)',
    );
    exit(1);
  }
  final dispatcherSource = dispatcher.readAsStringSync();

  final orphans = <String>[];
  for (final entity in apiDir.listSync()) {
    if (entity is! File) continue;
    final basename = entity.uri.pathSegments.last;
    if (!basename.endsWith('.dart')) continue;
    if (basename.endsWith('.freezed.dart') || basename.endsWith('.g.dart')) {
      continue;
    }
    final importLine = "import 'api/$basename';";
    if (!dispatcherSource.contains(importLine)) {
      orphans.add(entity.path);
    }
  }
  if (orphans.isEmpty) return;
  // Sort so CI logs and local runs report orphans in a deterministic
  // order regardless of `Directory.listSync`'s filesystem-dependent
  // iteration order.
  orphans.sort();

  stderr.writeln(
    '${_errorPrefix}orphaned generated module(s) under '
    '$_generatedDartApiDir/:',
  );
  for (final path in orphans) {
    stderr.writeln('       $path');
  }
  stderr.writeln(
    '       The corresponding rust/src/api/<basename>.rs no longer exposes\n'
    '       any FRB-visible items (or has been deleted), so codegen did not\n'
    '       regenerate the file. Remove it (and any *.freezed.dart /\n'
    '       *.g.dart companions) and rerun this script.',
  );
  exit(1);
}

// Append the given lint names to the `// ignore_for_file:` directive of
// the file at `path`. Idempotent: lints already listed are left in place,
// and the directive's existing order is preserved. Errors out if the file
// or directive is missing so accidental codegen-format changes surface
// loudly rather than silently no-oping.
void _addLintsToIgnoreForFile(String path, List<String> lintsToAdd) {
  final file = File(path);
  if (!file.existsSync()) {
    stderr.writeln(
      '$_errorPrefix expected generated file not found: $path '
      '(post-codegen lint patch cannot be applied)',
    );
    exit(1);
  }
  final original = file.readAsStringSync();
  final pattern = RegExp(r'^// ignore_for_file:\s*(.+)$', multiLine: true);
  final match = pattern.firstMatch(original);
  if (match == null) {
    stderr.writeln(
      '$_errorPrefix `// ignore_for_file:` directive missing in $path '
      '(FRB output format may have changed; update _lintIgnorePatches)',
    );
    exit(1);
  }
  final existing = <String>[
    for (final raw in match.group(1)!.split(',')) raw.trim(),
  ];
  final missing = lintsToAdd.where((l) => !existing.contains(l)).toList();
  if (missing.isEmpty) return;
  final replacement =
      '// ignore_for_file: ${[...existing, ...missing].join(', ')}';
  final patched = original.replaceFirst(match.group(0)!, replacement);
  file.writeAsStringSync(patched);
  stdout.writeln(
    'Patched $path: added ${missing.join(', ')} to ignore_for_file',
  );
}

// Replace the `unimplemented!("")` arms FRB 2.12 emits as the defensive
// catch-all for `#[non_exhaustive]` enum support in its generated SSE
// encode/decode/`IntoDart` impls. The arms are unreachable for the
// exhaustive enums in `crate::api::*`, but the empty message means a
// future wire-format mismatch panics with no diagnostic context. Replace
// the empty string with a fixed marker so any unexpected panic in
// generated codec code is greppable back to its FRB origin without
// changing the runtime semantics (still `unimplemented!`, still
// unreachable in practice).
//
// Idempotent: the pattern only matches the FRB-emitted empty form, so
// running the patcher twice in a row is a no-op on the second run.
int _patchFrbGeneratedUnimplementedMessages() {
  const path = 'rust/src/frb_generated.rs';
  final file = File(path);
  if (!file.existsSync()) {
    stderr.writeln(
      '$_errorPrefix expected generated file not found: $path '
      '(post-codegen FRB-unimplemented patch cannot be applied)',
    );
    exit(1);
  }
  const needle = 'unimplemented!("");';
  const replacement =
      'unimplemented!("flutter_rust_bridge generated codec: '
      'unexpected enum variant tag in SSE wire format");';
  final original = file.readAsStringSync();
  if (!original.contains(needle)) return 0;
  final patched = original.replaceAll(needle, replacement);
  final replaced =
      needle.allMatches(original).length - needle.allMatches(patched).length;
  file.writeAsStringSync(patched);
  stdout.writeln(
    'Patched $path: replaced $replaced empty `unimplemented!("")` arm(s) '
    'with diagnostic-bearing form',
  );
  return replaced;
}

// Patches the FRB-generated Dart file to include the unexpected enum variant
// tag in the UnimplementedError message thrown by each SSE codec default arm.
// FRB emits `throw UnimplementedError('');` for these arms; the patched form
// includes `$tag_` (in scope at every default arm site) so callers can
// diagnose which wire tag triggered the error.
//
// Idempotent: the pattern only matches the FRB-emitted empty-string form, so
// running the patcher twice in a row is a no-op on the second run.
int _patchDartFrbGeneratedUnimplementedMessages() {
  const path = 'lib/src/ffi/frb_generated.dart';
  final file = File(path);
  if (!file.existsSync()) {
    stderr.writeln(
      '$_errorPrefix expected generated file not found: $path '
      '(post-codegen Dart FRB-unimplemented patch cannot be applied)',
    );
    exit(1);
  }
  const needle = "throw UnimplementedError('');";
  const replacement =
      'throw UnimplementedError(\n'
      "          'flutter_rust_bridge generated codec: "
      "unexpected enum variant tag: \$tag_',\n"
      '        );';
  final original = file.readAsStringSync();
  if (!original.contains(needle)) return 0;
  final patched = original.replaceAll(needle, replacement);
  final replaced =
      needle.allMatches(original).length - needle.allMatches(patched).length;
  file.writeAsStringSync(patched);
  stdout.writeln(
    "Patched $path: replaced $replaced empty UnimplementedError('') "
    'arm(s) with diagnostic-bearing form',
  );
  return replaced;
}

// Patches the FRB-generated Dart file to include the unexpected enum variant
// tag in the `Exception('unreachable')` thrown by each DCO codec default arm.
// FRB emits `throw Exception("unreachable");` for these arms, which the
// `dart fix` pass FRB runs during generation rewrites to single quotes
// (the project enables `prefer_single_quotes`); the patched form
// includes `${raw[0]}` (the tag local in scope at every DCO default arm site
// for tagged-variant decoders) so callers can diagnose which wire tag
// triggered the error. Symmetric to the SSE-codec patcher above, but matches
// the DCO codec's exception type and tag-access shape.
//
// Idempotent: the pattern only matches the FRB-emitted bare-'unreachable'
// form, so running the patcher twice in a row is a no-op on the second run.
int _patchDartFrbGeneratedDcoUnreachableMessages() {
  const path = 'lib/src/ffi/frb_generated.dart';
  final file = File(path);
  if (!file.existsSync()) {
    stderr.writeln(
      '$_errorPrefix expected generated file not found: $path '
      '(post-codegen Dart FRB-DCO-unreachable patch cannot be applied)',
    );
    exit(1);
  }
  const needle = "throw Exception('unreachable');";
  const replacement =
      'throw Exception(\n'
      "          'flutter_rust_bridge generated codec: "
      "unexpected enum variant tag in DCO wire format: \${raw[0]}',\n"
      '        );';
  final original = file.readAsStringSync();
  if (!original.contains(needle)) return 0;
  final patched = original.replaceAll(needle, replacement);
  final replaced =
      needle.allMatches(original).length - needle.allMatches(patched).length;
  file.writeAsStringSync(patched);
  stdout.writeln(
    "Patched $path: replaced $replaced `Exception('unreachable')` "
    'DCO arm(s) with diagnostic-bearing form',
  );
  return replaced;
}

/// Runs `dart analyze` on the primary generated Dart binding. This ensures
/// that codegen-induced changes or patcher-applied logic (notably the
/// `${raw[0]}` DCO-tag access) do not introduce syntax or static errors.
Future<void> _validateGeneratedDart() async {
  stdout.writeln('Validating patched Dart bindings...');
  await _run('dart', const ['analyze', _frbGeneratedDispatcher]);
}

// ---------------------------------------------------------------------------
// Rust intra-doc link rewriting
// ---------------------------------------------------------------------------

/// A Dart symbol reachable from a rustdoc intra-doc link.
///
/// [dartPath] is the dartdoc reference text the link is rewritten to, e.g.
/// `NtsDnsPoolStats.spawnFailed`.
class DartSymbol {
  /// Creates a symbol resolving to [dartPath].
  const DartSymbol(this.dartPath);

  /// Dartdoc reference text, without the enclosing square brackets.
  final String dartPath;

  @override
  String toString() => dartPath;
}

/// Lookup table mapping Rust paths (`Type::member`, bare item names) onto
/// the Dart symbols FRB emitted for them.
///
/// The table is *derived from the generated Dart*, never from a casing
/// rule: a Rust path only resolves if a matching Dart declaration was
/// actually parsed out of the bindings. That is what keeps the rewrite
/// honest across the shapes FRB treats differently — plain enums, freezed
/// sealed classes, struct fields, renamed constructors.
class DartSymbolTable {
  DartSymbolTable._(this._symbols, this._frbIgnored);

  final Map<String, DartSymbol> _symbols;
  final Set<String> _frbIgnored;

  /// Rust paths this table can resolve, sorted. Exposed for diagnostics
  /// and tests.
  List<String> get keys => _symbols.keys.toList()..sort();

  /// Rust item names FRB reported as excluded from the bindings.
  Set<String> get frbIgnored => Set<String>.unmodifiable(_frbIgnored);

  /// Resolves [rustPath] to a Dart symbol, or `null` when unknown.
  ///
  /// `Self::` is resolved against [enclosingClass], which callers supply
  /// from the declaration the doc comment is attached to. Dart has no
  /// `Self`, so a `Self::` link outside a class body is unresolvable.
  DartSymbol? resolve(String rustPath, {String? enclosingClass}) {
    var path = rustPath;
    if (path.startsWith('Self::')) {
      if (enclosingClass == null) return null;
      path = '$enclosingClass::${path.substring('Self::'.length)}';
    }
    return _symbols[path];
  }

  /// Whether [rustPath] names an item FRB deliberately left out of the
  /// bindings (crate-private functions, unreferenced types). Such links
  /// have no Dart target by construction and are downgraded to inline
  /// code rather than reported as errors.
  bool isFrbIgnored(String rustPath) =>
      !rustPath.contains('::') && _frbIgnored.contains(rustPath);
}

/// Builds a [DartSymbolTable] from generated Dart binding [sources].
///
/// Recognises top-level functions, classes / enums / sealed classes, their
/// fields, enum values, named and unnamed constructors, and static and
/// instance methods. Each member is registered under both the snake_case
/// and the PascalCase Rust spelling of its Dart name, because Rust struct
/// fields and free functions are snake_case while enum variants are
/// PascalCase and FRB lowerCamelCases all of them.
DartSymbolTable buildDartSymbolTable(Iterable<String> sources) {
  final symbols = <String, DartSymbol>{};
  final ignored = <String>{};

  void addMember(String container, String dartName, String rustName) {
    symbols.putIfAbsent(
      '$container::$rustName',
      () => DartSymbol('$container.$dartName'),
    );
  }

  for (final source in sources) {
    String? container;
    for (final line in source.split('\n')) {
      final ignoreMatch = _frbIgnoredHeader.firstMatch(line);
      if (ignoreMatch != null) {
        for (final m in _backtickedName.allMatches(line)) {
          ignored.add(m.group(1)!);
        }
        continue;
      }

      final containerMatch = _dartContainerDecl.firstMatch(line);
      if (containerMatch != null) {
        container = containerMatch.group(1) ?? containerMatch.group(2);
        symbols.putIfAbsent(container!, () => DartSymbol(container!));
        continue;
      }
      if (line == '}') {
        container = null;
        continue;
      }

      if (container == null) {
        final fn = _dartTopLevelFn.firstMatch(line);
        if (fn != null) {
          final name = fn.group(1)!;
          symbols.putIfAbsent(_toSnakeCase(name), () => DartSymbol(name));
        }
        continue;
      }

      final field = _dartField.firstMatch(line);
      if (field != null) {
        _registerSpellings(addMember, container, field.group(1)!);
        continue;
      }
      final namedCtor = _dartNamedFactory.firstMatch(line);
      if (namedCtor != null && namedCtor.group(1) == container) {
        _registerSpellings(addMember, container, namedCtor.group(2)!);
        continue;
      }
      final unnamedCtor = _dartUnnamedFactory.firstMatch(line);
      if (unnamedCtor != null && unnamedCtor.group(1) == container) {
        // FRB renders a `#[frb(sync)]` Rust `new` as Dart's unnamed
        // constructor; `[Type.new]` is dartdoc's reference form for it.
        addMember(container, 'new', 'new');
        continue;
      }
      final enumValue = _dartEnumValue.firstMatch(line);
      if (enumValue != null) {
        _registerSpellings(addMember, container, enumValue.group(1)!);
        continue;
      }
      final method = _dartMethod.firstMatch(line);
      if (method != null) {
        _registerSpellings(addMember, container, method.group(1)!);
      }
    }
  }
  return DartSymbolTable._(symbols, ignored);
}

void _registerSpellings(
  void Function(String container, String dartName, String rustName) add,
  String container,
  String dartName,
) {
  add(container, dartName, _toSnakeCase(dartName));
  add(container, dartName, dartName[0].toUpperCase() + dartName.substring(1));
}

String _toSnakeCase(String camel) => camel
    .replaceAllMapped(RegExp('[A-Z]'), (m) => '_${m.group(0)!.toLowerCase()}')
    .replaceFirst(RegExp('^_'), '');

// `abstract class X`, `sealed class X`, `class X`, `enum X`. Anchored at
// column 0 so nested/annotated declarations inside a body are not mistaken
// for a new container.
final _dartContainerDecl = RegExp(
  r'^(?:(?:abstract|sealed|final|base|interface)\s+)*class\s+(\w+)'
  r'|^enum\s+(\w+)',
);
final _dartTopLevelFn = RegExp(r'^[A-Za-z_][\w<>?,\s]*\s([a-z]\w*)\(');
final _dartField = RegExp(r'^  final\s+[\w<>?,\s]+\s(\w+);');
final _dartNamedFactory = RegExp(r'^  (?:const\s+)?factory\s+(\w+)\.(\w+)\(');
final _dartUnnamedFactory = RegExp(r'^  (?:const\s+)?factory\s+(\w+)\(\)');
final _dartEnumValue = RegExp(r'^  ([a-z]\w*),$');
final _dartMethod = RegExp(
  r'^  (?:static\s+)?[A-Za-z_][\w<>?,\s]*\s([a-z]\w*)\(',
);
final _frbIgnoredHeader = RegExp(r'^// These (?:function|type)s? .* ignored ');
final _backtickedName = RegExp(r'`(\w+)`');

// A rustdoc intra-doc link: `` [`path`] ``. Bare `[Foo]` links are already
// Dart-shaped (or authored text) and are left alone.
final _rustIntraDocLink = RegExp(r'\[`([\w:]+)`\]');

/// Outcome of rewriting one generated Dart source.
class IntraDocRewrite {
  /// Creates a rewrite result.
  const IntraDocRewrite(
    this.source,
    this.rewritten,
    this.downgraded,
    this.unresolved,
  );

  /// Patched source text.
  final String source;

  /// Number of links rewritten to a Dart target.
  final int rewritten;

  /// Number of links downgraded to inline code because FRB excluded the
  /// referent from the bindings.
  final int downgraded;

  /// Rust paths that resolved to nothing, in first-seen order.
  final List<String> unresolved;
}

/// Rewrites Rust intra-doc links in [source] into their Dart equivalents
/// using [table].
///
/// Links whose referent FRB excluded from the bindings are downgraded to
/// inline code, matching the convention `rust/src/api/nts.rs` already
/// applies by hand for crate-internal names. Anything else that fails to
/// resolve is reported in [IntraDocRewrite.unresolved] rather than being
/// silently left Rust-shaped.
///
/// Idempotent: the output contains no `` [`...`] `` forms, so a second
/// pass is a no-op.
IntraDocRewrite rewriteIntraDocLinks(String source, DartSymbolTable table) {
  final unresolved = <String>[];
  var rewritten = 0;
  var downgraded = 0;
  String? container;
  final out = <String>[];

  for (final line in source.split('\n')) {
    final containerMatch = _dartContainerDecl.firstMatch(line);
    if (containerMatch != null) {
      container = containerMatch.group(1) ?? containerMatch.group(2);
    } else if (line == '}') {
      container = null;
    }

    if (!line.contains('[`')) {
      out.add(line);
      continue;
    }
    // Doc comments precede their declaration, so the container in scope
    // for a member's rustdoc is the one whose body it sits in -- already
    // tracked above. A class-level doc comment sits *outside* the class,
    // where `Self` cannot appear anyway.
    final captured = container;
    out.add(
      line.replaceAllMapped(_rustIntraDocLink, (m) {
        final path = m.group(1)!;
        final symbol = table.resolve(path, enclosingClass: captured);
        if (symbol != null) {
          rewritten++;
          return '[${symbol.dartPath}]';
        }
        if (table.isFrbIgnored(path)) {
          downgraded++;
          return '`$path`';
        }
        if (!unresolved.contains(path)) unresolved.add(path);
        return m.group(0)!;
      }),
    );
  }
  return IntraDocRewrite(out.join('\n'), rewritten, downgraded, unresolved);
}

// Rewrites Rust intra-doc links in every generated Dart API module into
// their Dart equivalents. The symbol table is built across all modules so
// a cross-module reference resolves; the freezed part files contribute
// their sealed-class subtypes and carry no doc comments of their own.
//
// Exits non-zero on an unresolvable link rather than leaving it
// Rust-shaped, naming the originating `rust/src/api/*.rs` line so the
// docstring can be fixed at source.
void _patchDartIntraDocLinks() {
  final dir = Directory(_generatedDartApiDir);
  if (!dir.existsSync()) {
    stderr.writeln(
      '$_errorPrefix expected generated directory not found: '
      '$_generatedDartApiDir (intra-doc link patch cannot be applied)',
    );
    exit(1);
  }
  final files =
      dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  final sources = <String, String>{
    for (final f in files) f.path: f.readAsStringSync(),
  };
  final table = buildDartSymbolTable(sources.values);

  var rewritten = 0;
  var downgraded = 0;
  final unresolved = <String, List<String>>{};
  for (final entry in sources.entries) {
    final result = rewriteIntraDocLinks(entry.value, table);
    rewritten += result.rewritten;
    downgraded += result.downgraded;
    if (result.unresolved.isNotEmpty) {
      unresolved[entry.key] = result.unresolved;
    }
    if (result.source != entry.value) {
      File(entry.key).writeAsStringSync(result.source);
    }
  }

  if (unresolved.isNotEmpty) {
    stderr.writeln(
      '${_errorPrefix}unresolvable Rust intra-doc link(s) in the '
      'generated Dart bindings. Each one documents a Dart API using a '
      'Rust path that has no Dart counterpart, so it renders as a dead '
      'reference. Fix the rustdoc at source -- either point it at an '
      'item FRB exports, or render it as inline code like the '
      'crate-internal names already are.',
    );
    unresolved.forEach((path, paths) {
      for (final rustPath in paths) {
        stderr.writeln('       [`$rustPath`] (in $path)');
        for (final origin in _findRustOrigins(rustPath)) {
          stderr.writeln('         from $origin');
        }
      }
    });
    exit(1);
  }

  if (rewritten > 0 || downgraded > 0) {
    stdout.writeln(
      'Patched $_generatedDartApiDir: rewrote $rewritten Rust intra-doc '
      'link(s) into Dart form, downgraded $downgraded FRB-excluded '
      'reference(s) to inline code',
    );
  }
}

// Best-effort locator for the rustdoc that produced an unresolvable link.
// Scans the FRB-visible Rust API sources for the literal link text.
List<String> _findRustOrigins(String rustPath) {
  final dir = Directory('rust/src/api');
  if (!dir.existsSync()) return const <String>[];
  final needle = '[`$rustPath`]';
  final origins = <String>[];
  for (final file in dir.listSync().whereType<File>()) {
    if (!file.path.endsWith('.rs')) continue;
    final lines = file.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].contains(needle)) origins.add('${file.path}:${i + 1}');
    }
  }
  return origins;
}

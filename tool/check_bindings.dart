// Local equivalent of the CI `Verify FRB bindings are in sync` job. Runs
// `flutter_rust_bridge_codegen generate`, applies the lint-suppression
// patches FRB cannot emit on its own (see `_lintIgnorePatches`), formats
// the regenerated Dart bindings, checks for orphaned generated modules
// (see `_checkForOrphanedApiModules`), and fails non-zero if
// `lib/src/ffi/` or `rust/src/frb_generated.rs` differ from the committed
// state -- including when codegen *creates* a file the repo does not yet
// track (see `_findUntrackedGeneratedFiles`; `git diff` alone reports
// only tracked-file changes).
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
      '${_errorPrefix}FRB bindings drifted from rust/src/api/. Run '
      "'flutter_rust_bridge_codegen generate' locally and commit the result.",
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

// Local equivalent of the CI `Verify FRB bindings are in sync` job. Runs
// `flutter_rust_bridge_codegen generate`, formats the regenerated Dart
// bindings, and fails non-zero if `lib/src/ffi/` or
// `rust/src/frb_generated.rs` differ from the committed state.
//
// Usage:
//
//     dart run tool/check_bindings.dart
//
// Exit codes:
//   0  bindings are in sync
//   1  drift detected (or precondition failure: missing tool / wrong version)
//
// The pinned FRB version is read from `pubspec.yaml` so this script and the
// CI workflow stay in lockstep with the runtime crate.

import 'dart:io';

// Paths watched for drift. Mirrors `dart_output` and `rust_output` in
// `flutter_rust_bridge.yaml`.
const _watchedPaths = <String>['lib/src/ffi', 'rust/src/frb_generated.rs'];

// GitHub Actions annotation prefix; emitted only when running inside GHA so
// the workflow log surfaces drift as an error annotation.
String get _errorPrefix => Platform.environment.containsKey('GITHUB_ACTIONS')
    ? '::error::'
    : 'error: ';

Future<void> main(List<String> args) async {
  final pinnedVersion = _readPinnedFrbVersion();
  _ensureCodegenAvailable(pinnedVersion);

  await _run('flutter_rust_bridge_codegen', const ['generate']);

  // Format the regenerated Dart so the diff check below catches semantic
  // drift only -- not formatter noise that CI's `dart format` step would
  // otherwise re-flag. (FRB already runs rustfmt on `frb_generated.rs`.)
  await _run('dart', const ['format', 'lib/src/ffi']);

  if (await _hasDrift()) {
    stderr.writeln(
      "${_errorPrefix}FRB bindings drifted from rust/src/api/. Run "
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
  // no version range, no quotes). Intentionally strict to fail loudly if the
  // pin format ever changes.
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

// Standalone command-line companion to the Flutter showcase.
//
// Drives the same `nts` Rust-backed surface (`ntsQuery`,
// `ntsWarmCookies`) that the GUI uses, but exposes it as a scriptable
// terminal tool. Useful for batched probing, cron jobs, CI checks, or
// quick smoke tests in environments where launching the full Flutter
// app is overkill.
//
// The CLI carries no built-in server list and does not consult the
// GUI's bundled YAML catalog — every host is supplied positionally on
// the command line. Any RFC 8915 NTS-KE endpoint (default port 4460,
// override with `--port`) is fair game.
//
// Output mirrors the multi-line headline / continuation layout used in
// the on-screen log so a user switching between the two surfaces sees
// the same shapes.
//
// Usage examples:
//   fvm dart run bin/nts_cli.dart nts.netnod.se time.cloudflare.com
//   fvm dart run bin/nts_cli.dart --warm --timeout 10000 nts.sth1.ntp.se
//   fvm dart run bin/nts_cli.dart --mock nts.example.test
//   fvm dart run bin/nts_cli.dart --json --exit-on-error nts.netnod.se
//
// Bridge loading:
//   * `--mock` binds the same in-memory fake the example app uses, so
//     the tool is runnable without a built dylib (handy for smoke
//     tests, CI, or platforms where the Rust toolchain isn't present).
//   * Otherwise, the host-arch dylib is loaded from
//     `--library <path>` if given, falling back to the conventional
//     `rust/target/release/` location relative to the package root.
//     Build it with `cargo build --release` from `rust/`.
//
// Output modes:
//   * Default: human-readable `[ts] [LEVEL] [source] [host]  [msg]`
//     lines matching the GUI live log layout.
//   * `--json`: NDJSON — one self-contained JSON object per line, with
//     a stable envelope (`ts`, `level`, `source`, `host`, `event`)
//     plus event-specific payload fields. Suitable for `jq` / piping
//     into log aggregators.
//
// Exit semantics:
//   * Default: 0 once every host has completed, regardless of whether
//     individual hosts succeeded or failed.
//   * `--exit-on-error`: 1 if any host produced a warn-or-error result
//     (network, timeout, auth, protocol, etc). Bridge-load and arg
//     errors still use 70 / 64.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;
import 'package:nts/nts.dart'
    show NtsError, NtsServerSpec, RustLib, ntsQuery, ntsWarmCookies;

import 'package:nts_example/src/mock_api.dart';
import 'package:nts_example/src/state/nts_format.dart';

const int _kDefaultPort = 4460;
const int _kDefaultTimeoutMs = 5000;
const int _kExitHostFailure = 1;

ArgParser _buildParser() => ArgParser()
  ..addOption(
    'port',
    abbr: 'p',
    defaultsTo: '$_kDefaultPort',
    help: 'TCP port for NTS-KE on every host (default: $_kDefaultPort).',
  )
  ..addOption(
    'timeout',
    abbr: 't',
    defaultsTo: '$_kDefaultTimeoutMs',
    help:
        'Per-request timeout in milliseconds. Applied independently '
        'to the KE handshake and the UDP recv leg.',
  )
  ..addOption(
    'library',
    abbr: 'l',
    help:
        'Path to a prebuilt nts_rust dylib. If '
        'omitted, falls back to rust/target/release/.',
  )
  ..addFlag(
    'warm',
    abbr: 'w',
    negatable: false,
    help: 'Run ntsWarmCookies instead of ntsQuery.',
  )
  ..addFlag(
    'mock',
    negatable: false,
    help: 'Use the in-memory mock bridge (no native dylib required).',
  )
  ..addFlag(
    'json',
    negatable: false,
    help:
        'Emit NDJSON (one JSON object per line) instead of human '
        'log lines. Success goes to stdout, failures to stderr.',
  )
  ..addFlag(
    'exit-on-error',
    negatable: false,
    help:
        'Exit with status $_kExitHostFailure if any host produced '
        'a warn or error result. Default exits 0 regardless of '
        'per-host outcomes.',
  )
  ..addFlag('help', abbr: 'h', negatable: false, help: 'Show this help.');

Future<void> main(List<String> argv) async {
  final parser = _buildParser();
  final ArgResults args;
  try {
    args = parser.parse(argv);
  } on FormatException catch (e) {
    stderr.writeln('argument error: ${e.message}');
    stderr.writeln(parser.usage);
    exit(64);
  }

  if (args['help'] as bool || args.rest.isEmpty) {
    stdout.writeln('Usage: nts_cli [options] <host> [<host>...]');
    stdout.writeln(parser.usage);
    exit(args['help'] as bool ? 0 : 64);
  }

  final port = int.tryParse(args['port'] as String);
  final timeoutMs = int.tryParse(args['timeout'] as String);
  if (port == null || port <= 0 || port > 65535) {
    stderr.writeln('argument error: --port must be in 1..65535');
    exit(64);
  }
  if (timeoutMs == null || timeoutMs <= 0) {
    stderr.writeln('argument error: --timeout must be a positive integer');
    exit(64);
  }

  await _initBridge(
    useMock: args['mock'] as bool,
    libraryPath: args['library'] as String?,
  );

  final ctx = _Ctx(json: args['json'] as bool);

  // Fan out one Future per host. We don't `Future.wait` directly —
  // instead each call's `.then` prints as soon as its individual
  // round-trip completes, so the user sees results in completion
  // order (typically reflecting RTT) rather than batched at the end.
  final pending = <Future<void>>[];
  for (final host in args.rest) {
    final spec = NtsServerSpec(host: host, port: port);
    pending.add(
      (args['warm'] as bool)
          ? _runWarm(spec, timeoutMs, ctx)
          : _runQuery(spec, timeoutMs, ctx),
    );
  }
  await Future.wait(pending);

  if ((args['exit-on-error'] as bool) && ctx.anyFailed) {
    exit(_kExitHostFailure);
  }
}

Future<void> _initBridge({
  required bool useMock,
  required String? libraryPath,
}) async {
  if (useMock) {
    RustLib.initMock(api: MockNtsApi());
    return;
  }
  final resolved = libraryPath ?? _autoLocateDylib();
  if (resolved == null) {
    stderr.writeln(
      'error: no nts_rust dylib found.\n'
      '       Build it with `cargo build --release` from the rust/\n'
      '       directory, pass --library <path>, or run with --mock.',
    );
    exit(70);
  }
  if (!File(resolved).existsSync()) {
    stderr.writeln('error: dylib not found at $resolved');
    exit(70);
  }
  try {
    await RustLib.init(externalLibrary: ExternalLibrary.open(resolved));
  } catch (e) {
    stderr.writeln('error: failed to initialize Rust bridge: $e');
    exit(70);
  }
}

/// Walk the well-known build locations for a host-arch dylib. Returns
/// the first match or null. Mirrors the Native Assets pipeline's
/// stem (`nts_rust`) and the `rust/target/release/`
/// convention encoded in `RustLib.kDefaultExternalLibraryLoaderConfig`.
String? _autoLocateDylib() {
  final ext = Platform.isMacOS
      ? 'dylib'
      : Platform.isWindows
      ? 'dll'
      : 'so';
  final prefix = Platform.isWindows ? '' : 'lib';
  final filename = '${prefix}nts_rust.$ext';
  // Search relative to (1) the example directory (`example/`), and
  // (2) the repo root — covers both `dart run bin/nts_cli.dart` from
  // the example dir and `dart run example/bin/nts_cli.dart` from the
  // repo root.
  final candidates = <String>[
    '${Directory.current.path}/../rust/target/release/$filename',
    '${Directory.current.path}/rust/target/release/$filename',
  ];
  for (final c in candidates) {
    if (File(c).existsSync()) return c;
  }
  return null;
}

Future<void> _runQuery(NtsServerSpec spec, int timeoutMs, _Ctx ctx) async {
  ctx.start('nts_query', spec.host, 'Starting query');
  try {
    final sample = await ntsQuery(
      spec: spec,
      timeoutMs: timeoutMs,
      dnsConcurrencyCap: 0,
    );
    ctx.success(
      'nts_query',
      spec.host,
      text: formatQuerySuccess(sample),
      jsonPayload: jsonQuerySuccess(sample),
    );
  } on NtsError catch (err) {
    ctx.failure('nts_query', spec.host, err);
  } catch (err) {
    ctx.unhandled('nts_query', spec.host, err);
  }
}

Future<void> _runWarm(NtsServerSpec spec, int timeoutMs, _Ctx ctx) async {
  ctx.start('nts_warm_cookies', spec.host, 'Starting warm');
  try {
    final n = await ntsWarmCookies(
      spec: spec,
      timeoutMs: timeoutMs,
      dnsConcurrencyCap: 0,
    );
    ctx.success(
      'nts_warm_cookies',
      spec.host,
      text: formatWarmSuccess(n),
      jsonPayload: jsonWarmSuccess(n),
    );
  } on NtsError catch (err) {
    ctx.failure('nts_warm_cookies', spec.host, err);
  } catch (err) {
    ctx.unhandled('nts_warm_cookies', spec.host, err);
  }
}

/// Per-invocation output sink. Holds the `--json` toggle so the run
/// helpers don't have to thread it through every emit, and tracks
/// whether any host produced a warn / error result so `--exit-on-error`
/// can resolve to the right exit code after `Future.wait` completes.
class _Ctx {
  _Ctx({required this.json});

  final bool json;
  bool anyFailed = false;

  void start(String source, String host, String message) {
    if (json) {
      _writeJson(stdout, _envelope('INFO', source, host, 'start'));
    } else {
      _writeText(stdout, 'INFO ', source, host, message);
    }
  }

  void success(
    String source,
    String host, {
    required String text,
    required Map<String, Object?> jsonPayload,
  }) {
    if (json) {
      _writeJson(stdout, {
        ..._envelope('INFO', source, host, 'success'),
        ...jsonPayload,
      });
    } else {
      _writeText(stdout, 'INFO ', source, host, text);
    }
  }

  void failure(String source, String host, NtsError err) {
    anyFailed = true;
    final isError = isErrorSeverity(err);
    final level = isError ? 'ERROR' : 'WARN ';
    if (json) {
      _writeJson(stderr, {
        ..._envelope(isError ? 'ERROR' : 'WARN', source, host, 'error'),
        ...jsonError(err),
      });
    } else {
      _writeText(stderr, level, source, host, describeError(err));
    }
  }

  void unhandled(String source, String host, Object err) {
    anyFailed = true;
    if (json) {
      _writeJson(stderr, {
        ..._envelope('ERROR', source, host, 'error'),
        'error_type': 'Unhandled',
        'message': err.toString(),
        'severity': 'error',
      });
    } else {
      _writeText(stderr, 'ERROR', source, host, 'Unhandled: $err');
    }
  }

  Map<String, Object?> _envelope(
    String level,
    String source,
    String host,
    String event,
  ) => {
    'ts': DateTime.now().toUtc().toIso8601String(),
    'level': level,
    'source': source,
    'host': host,
    'event': event,
  };

  void _writeJson(IOSink sink, Map<String, Object?> payload) {
    sink.writeln(jsonEncode(payload));
  }

  /// Render one human-readable log line in the same `[ts] [LEVEL]
  /// [source] [host] [message]` shape the GUI uses, to keep the two
  /// surfaces' output structurally swappable. Multi-line messages keep
  /// their internal `\n + indent` shape and are written verbatim.
  void _writeText(
    IOSink sink,
    String level,
    String source,
    String host,
    String message,
  ) {
    final ts = DateTime.now().toUtc().toIso8601String();
    sink.writeln('$ts $level $source [$host]  $message');
  }
}

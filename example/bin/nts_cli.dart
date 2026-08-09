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
// Every run ends with a DNS resolver pool report (`dns_pool_stats`
// under `--json`) carrying the counters observed across the batch.
// `refused` and `spawn-failed` both surface as `dnsSaturation` /
// `dnsSpawnFailed` timeouts on the error channel, and the pair is what
// tells an operator whether raising `--dns-cap` would help (cap is the
// binding constraint) or make matters worse (the process is already at
// an OS thread ceiling).
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
import 'package:nts/nts.dart'
    show
        NtsClient,
        NtsDnsPoolStats,
        NtsError,
        NtsServerSpec,
        TrustBackend,
        TrustMode,
        kDefaultBridgeConcurrencyCap,
        kDefaultDnsConcurrencyCap,
        ntsDnsPoolStats,
        ntsQuery,
        ntsWarmCookies;

import 'package:nts_example/src/cli/bridge_loader.dart' show initBridge;
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
        'Per-request timeout in milliseconds. Single global '
        'wall-clock budget that spans DNS, NTS-KE (TCP connect, '
        'TLS handshake, record I/O) and the AEAD-NTPv4 UDP '
        'exchange as one shrinking deadline.',
  )
  ..addOption(
    'library',
    abbr: 'l',
    help:
        'Path to a prebuilt nts_rust dylib. If '
        'omitted, falls back to rust/target/release/.',
  )
  ..addOption(
    'dns-cap',
    help:
        'Ceiling on the package\'s process-wide pool of in-flight '
        'DNS resolver workers (package default: '
        '$kDefaultDnsConcurrencyCap, sized for mobile). If omitted, '
        'sized up to the host fan-out so a multi-host run cannot '
        'self-saturate the pool; values below the fan-out can '
        'surface dnsSaturation fast-fails.',
  )
  ..addOption(
    'trust-mode',
    allowed: kTrustModeFlagValues,
    help:
        'TLS trust-anchor policy for every handshake this run '
        'initiates. Left at platform-with-fallback, whether by '
        'omission or passed explicitly, the run goes through the '
        'package\'s process-wide default client; any stricter value '
        'mints one call-scoped NtsClient for the batch.',
  )
  ..addOption(
    'custom-roots',
    help:
        'Path to a PEM certificate bundle or a single DER-encoded '
        'certificate. Required by --trust-mode=custom, and rejected '
        'with every other mode.',
  )
  ..addOption(
    'require-trust-backend',
    allowed: kTrustBackendFlagValues,
    help:
        'Assert that each handshake negotiated this backend. A host '
        'that authenticated under a different one reports '
        'TrustBackendMismatch instead of success, which counts as a '
        'failure for --exit-on-error.',
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
  final dnsCapRaw = args['dns-cap'] as String?;
  int? dnsCapOverride;
  if (dnsCapRaw != null) {
    dnsCapOverride = int.tryParse(dnsCapRaw);
    if (dnsCapOverride == null || dnsCapOverride <= 0) {
      stderr.writeln('argument error: --dns-cap must be a positive integer');
      exit(64);
    }
  }

  // `allowed:` on both options means the parser has already rejected
  // anything outside the two value sets, so the parse helpers cannot
  // return null here; the `?? ` arms exist only to keep the locals
  // non-nullable.
  final trustModeRaw = args['trust-mode'] as String?;
  final trustMode = trustModeRaw == null
      ? TrustMode.platformWithFallback
      : parseTrustMode(trustModeRaw) ?? TrustMode.platformWithFallback;
  final requiredBackendRaw = args['require-trust-backend'] as String?;
  final requiredBackend = requiredBackendRaw == null
      ? null
      : parseTrustBackend(requiredBackendRaw);

  // Read the roots ahead of client construction so an unreadable path
  // is an argument error rather than a trust-policy one. Wiping this
  // buffer once the constructor has copied it is the caller's job:
  // the package zeroises only its own FFI-side copy and documents the
  // caller's list as never touched.
  //
  // Registering makes the termination sites between this read and the
  // wipe below — the pairing check, and every `initBridge` failure —
  // able to clear the bytes: `exit` does not unwind, so a `finally`
  // spanning them would be skipped.
  final customRootsPath = args['custom-roots'] as String?;
  List<int>? customRoots;
  if (customRootsPath != null) {
    try {
      customRoots = File(customRootsPath).readAsBytesSync();
    } on FileSystemException catch (e) {
      stderr.writeln('argument error: --custom-roots: ${e.message}');
      exit(64);
    }
    registerCustomRootsForWipe(customRoots);
  }

  // Pair validation belongs here, not at client construction: the
  // constructor runs the same check, but only after `initBridge`, so on
  // a machine with no loadable dylib an invalid pairing would exit with
  // the bridge-load code instead of the usage code the README documents.
  final pairingError = trustPolicyPairingError(
    trustMode: trustMode,
    customRoots: customRoots,
  );
  if (pairingError != null) {
    wipeRegisteredCustomRoots();
    stderr.writeln('argument error: $pairingError');
    exit(64);
  }

  await initBridge(
    useMock: args['mock'] as bool,
    libraryPath: args['library'] as String?,
  );

  // Default policy keeps routing through the top-level functions and
  // the process-wide default client they share, so the path every
  // pre-existing invocation takes gains no client lifecycle and no new
  // failure surface. Anything else mints exactly one client for the
  // whole fan-out, which the package documents as safe to share across
  // concurrent calls. The catch is a backstop: the pairing check above
  // already rejects every combination the constructor validates, so it
  // only fires if the two ever drift.
  NtsClient? client;
  if (trustMode != TrustMode.platformWithFallback || customRoots != null) {
    NtsError? constructionError;
    try {
      client = NtsClient(trustMode: trustMode, customRoots: customRoots);
    } on NtsError catch (err) {
      constructionError = err;
    } finally {
      // The constructor has copied the bytes by now, on every path; the
      // local is the last live reference the run holds, so wipe it here
      // rather than leaving it to process teardown. `finally` covers the
      // success path and a non-[NtsError] escape; the usage exit below
      // is deliberately outside it, because `exit` terminates the VM
      // without unwinding.
      wipeRegisteredCustomRoots();
    }
    if (constructionError != null) {
      stderr.writeln('argument error: ${describeError(constructionError)}');
      exit(64);
    }
  }

  final ctx = _Ctx(
    json: args['json'] as bool,
    trustFields: {
      if (trustModeRaw != null) 'trust_mode': trustMode.name,
      if (requiredBackend != null)
        'required_trust_backend': requiredBackend.name,
    },
  );

  // Every positional host is distinct and the loop below fans out one
  // concurrent call per host, so size both shared concurrency
  // caps to that fan-out (mirroring the catalog tools): with the
  // mobile-sized defaults (both 4), a >4-host invocation would
  // otherwise queue at the bridge admission gate, charging queue wait
  // against each host's `--timeout` budget. The caps are raised
  // *together* because a bridge cap above the DNS cap re-exposes
  // TimeoutPhase.dnsSaturation fast-fails to synchronized
  // distinct-host bursts. An explicit `--dns-cap` overrides the
  // DNS-side auto-sizing only; the help text flags the fast-fail
  // exposure a below-fan-out value re-opens.
  final hostCount = args.rest.length;
  final dnsCap =
      dnsCapOverride ??
      (hostCount > kDefaultDnsConcurrencyCap
          ? hostCount
          : kDefaultDnsConcurrencyCap);
  final bridgeCap = hostCount > kDefaultBridgeConcurrencyCap
      ? hostCount
      : kDefaultBridgeConcurrencyCap;

  // Baseline the DNS pool counters before the fan-out. They are
  // process-global and cumulative, so a single post-batch read cannot
  // attribute anything to this invocation; the trailing section below
  // reports the delta against this snapshot. Cheap enough to take
  // unconditionally — five relaxed atomic loads, no isolate hop.
  final poolBefore = ntsDnsPoolStats();

  // Fan out one Future per host. We don't `Future.wait` directly —
  // instead each call's `.then` prints as soon as its individual
  // round-trip completes, so the user sees results in completion
  // order (typically reflecting RTT) rather than batched at the end.
  // Single conversion point: the CLI surface stays milliseconds.
  final timeout = Duration(milliseconds: timeoutMs);
  final pending = <Future<void>>[];
  for (final host in args.rest) {
    final spec = NtsServerSpec(host: host, port: port);
    pending.add(
      (args['warm'] as bool)
          ? _runWarm(
              spec,
              timeout,
              ctx,
              client: client,
              requiredBackend: requiredBackend,
              dnsConcurrencyCap: dnsCap,
              bridgeConcurrencyCap: bridgeCap,
            )
          : _runQuery(
              spec,
              timeout,
              ctx,
              client: client,
              requiredBackend: requiredBackend,
              dnsConcurrencyCap: dnsCap,
              bridgeConcurrencyCap: bridgeCap,
            ),
    );
  }
  try {
    await Future.wait(pending);
  } finally {
    // The per-host helpers swallow their own failures, so the only way
    // here is a defect in the fan-out itself — but the session table
    // this client owns holds cookies and derived keys, so release it
    // on that path too rather than leaving it to process teardown.
    client?.dispose();
  }

  ctx.poolStats(poolBefore, ntsDnsPoolStats());

  if ((args['exit-on-error'] as bool) && ctx.anyFailed) {
    exit(_kExitHostFailure);
  }
}

/// One `ntsQuery` probe. Routes through [client] when the run selected
/// a non-default trust policy, and through the top-level function
/// (hence the package's default client) otherwise.
Future<void> _runQuery(
  NtsServerSpec spec,
  Duration timeout,
  _Ctx ctx, {
  required NtsClient? client,
  required TrustBackend? requiredBackend,
  required int dnsConcurrencyCap,
  required int bridgeConcurrencyCap,
}) async {
  ctx.start('nts_query', spec.host, 'Starting query');
  try {
    final sample = client == null
        ? await ntsQuery(
            spec: spec,
            timeout: timeout,
            dnsConcurrencyCap: dnsConcurrencyCap,
            bridgeConcurrencyCap: bridgeConcurrencyCap,
          )
        : await client.query(
            spec: spec,
            timeout: timeout,
            dnsConcurrencyCap: dnsConcurrencyCap,
            bridgeConcurrencyCap: bridgeConcurrencyCap,
          );
    if (requiredBackend != null && sample.trustBackend != requiredBackend) {
      ctx.trustMismatch(
        'nts_query',
        spec.host,
        requiredBackend,
        sample.trustBackend,
      );
      return;
    }
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

/// One `ntsWarmCookies` probe, with the same [client] routing and
/// [requiredBackend] assertion as [_runQuery].
Future<void> _runWarm(
  NtsServerSpec spec,
  Duration timeout,
  _Ctx ctx, {
  required NtsClient? client,
  required TrustBackend? requiredBackend,
  required int dnsConcurrencyCap,
  required int bridgeConcurrencyCap,
}) async {
  ctx.start('nts_warm_cookies', spec.host, 'Starting warm');
  try {
    final outcome = client == null
        ? await ntsWarmCookies(
            spec: spec,
            timeout: timeout,
            dnsConcurrencyCap: dnsConcurrencyCap,
            bridgeConcurrencyCap: bridgeConcurrencyCap,
          )
        : await client.warmCookies(
            spec: spec,
            timeout: timeout,
            dnsConcurrencyCap: dnsConcurrencyCap,
            bridgeConcurrencyCap: bridgeConcurrencyCap,
          );
    if (requiredBackend != null && outcome.trustBackend != requiredBackend) {
      ctx.trustMismatch(
        'nts_warm_cookies',
        spec.host,
        requiredBackend,
        outcome.trustBackend,
      );
      return;
    }
    ctx.success(
      'nts_warm_cookies',
      spec.host,
      text: formatWarmSuccess(outcome),
      jsonPayload: jsonWarmSuccess(outcome),
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
  _Ctx({required this.json, this.trustFields = const {}});

  final bool json;

  /// Run-scoped trust provenance merged into every `--json` record:
  /// `trust_mode` when `--trust-mode` was passed and
  /// `required_trust_backend` when `--require-trust-backend` was. Empty
  /// when neither flag appeared, which keeps a flagless run's records
  /// byte-identical to the pre-flag tool's. This belongs to the CLI
  /// rather than to the shared `json…` formatters, whose payloads
  /// describe one handshake, not the invocation that requested it.
  final Map<String, Object?> trustFields;

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

  /// A `--require-trust-backend` assertion failure: the handshake
  /// completed, but under a different backend than the run demanded.
  ///
  /// Emitted *instead of* the host's success record, so exactly one
  /// terminal record per host survives, and always at `ERROR` — the
  /// assertion is the operator's own policy, so there is no
  /// warn-severity variant to classify against.
  void trustMismatch(
    String source,
    String host,
    TrustBackend requiredBackend,
    TrustBackend actualBackend,
  ) {
    anyFailed = true;
    if (json) {
      _writeJson(stderr, {
        ..._envelope('ERROR', source, host, 'error'),
        ...jsonTrustMismatch(requiredBackend, actualBackend),
      });
    } else {
      _writeText(
        stderr,
        'ERROR',
        source,
        host,
        formatTrustMismatch(requiredBackend, actualBackend),
      );
    }
  }

  /// Trailing run-scoped report of the DNS resolver pool counters.
  ///
  /// Emitted after `Future.wait`, so it lands below the
  /// completion-ordered per-host lines rather than interleaved with
  /// them. Under `--json` the stream is NDJSON, so this cannot be a
  /// human-readable block — it goes out as one more object carrying
  /// the same envelope as every other record, with `event` set to
  /// `dns_pool_stats`. The envelope's `host` is `-`: the counters are
  /// process-global and belong to the run, not to any one host, but
  /// the key stays present and string-typed so a consumer can index
  /// it without a per-event branch.
  void poolStats(NtsDnsPoolStats before, NtsDnsPoolStats after) {
    if (json) {
      _writeJson(stdout, {
        ..._envelope('INFO', 'nts_dns_pool', '-', 'dns_pool_stats'),
        ...jsonDnsPoolStats(before, after),
      });
    } else {
      _writeText(
        stdout,
        'INFO ',
        'nts_dns_pool',
        '-',
        formatDnsPoolStats(before, after),
      );
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
    // Run-scoped, so it rides the envelope rather than the per-event
    // payloads: a consumer filtering a mixed stream reads the policy
    // off any record, including the trailing dns_pool_stats one.
    ...trustFields,
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

// Shared CLI scaffolding for the example app's catalog probe tools.
//
// `bin/nts_health.dart` and `bin/nts_manifest.dart` both point at a
// server-list YAML, parse the same probe flags, load the FRB bridge, and
// run the shared `probeAll` runner. This module centralises that
// boilerplate — flag definitions, positive-int validation, catalog
// loading, bridge init, and the probe call — so each tool keeps only its
// own output stage. Every unrecoverable usage/IO error exits the process
// (code [kExitUsage]) with a diagnostic on stderr, matching the
// pre-refactor behaviour of both tools.

import 'dart:io';

import 'package:args/args.dart';
import 'package:nts/nts.dart'
    show
        NtsClient,
        NtsError,
        TrustBackend,
        TrustMode,
        kDefaultBridgeConcurrencyCap,
        kDefaultDnsConcurrencyCap;

import '../data/server_catalog.dart' show parseServerYaml;
import '../data/server_entry.dart' show NtsServerEntry;
import '../health/probe.dart' show probeAll;
import '../health/server_health.dart' show HealthThresholds, ServerHealth;
import '../state/nts_format.dart'
    show
        describeError,
        kTrustBackendFlagValues,
        kTrustModeFlagValues,
        parseTrustBackend,
        parseTrustMode,
        registerCustomRootsForWipe,
        trustPolicyPairingError,
        wipeAndDeregisterCustomRoots,
        wipeRegisteredCustomRoots;
import 'bridge_loader.dart' show initBridge;

const int kDefaultPort = 4460;
const int kDefaultTimeoutMs = 5000;
const int kDefaultSamples = 3;
const int kDefaultConcurrency = 8;
const int kDefaultOffsetThresholdMs = 1000;

/// Exit code for any argument/IO usage failure (mirrors both tools).
const int kExitUsage = 64;

/// Add the probe flags shared by both catalog tools to [parser].
void addCommonProbeOptions(ArgParser parser) {
  parser
    ..addOption(
      'port',
      abbr: 'p',
      defaultsTo: '$kDefaultPort',
      help: 'TCP port for NTS-KE on every host.',
    )
    ..addOption(
      'timeout',
      abbr: 't',
      defaultsTo: '$kDefaultTimeoutMs',
      help: 'Per-request timeout in milliseconds.',
    )
    ..addOption(
      'samples',
      abbr: 'n',
      defaultsTo: '$kDefaultSamples',
      help: 'Probes per host; the median RTT is reported.',
    )
    ..addOption(
      'concurrency',
      abbr: 'c',
      defaultsTo: '$kDefaultConcurrency',
      help: 'Max hosts probed in parallel.',
    )
    ..addOption(
      'offset-threshold-ms',
      defaultsTo: '$kDefaultOffsetThresholdMs',
      help: 'Flag a host non-standard if |clock offset| exceeds this.',
    )
    ..addOption(
      'dns-cap',
      help:
          'Ceiling on the package\'s process-wide pool of in-flight '
          'DNS resolver workers (package default: '
          '$kDefaultDnsConcurrencyCap, sized for mobile). If omitted, '
          'sized up to --concurrency so a probe wave cannot '
          'self-saturate the pool; values below --concurrency can '
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
          'mints one call-scoped NtsClient for the whole catalog.',
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
          'Assert that every call resolves this trust-anchor backend. '
          'A host whose call resolved a different one is classified as '
          'a severe KE-stage TrustBackendMismatch failure, making it a '
          'drop candidate. Checked whether the call succeeded or '
          'failed, since the backend is resolved before any network '
          'I/O and so is reported on both.',
    );
}

/// Add the trailing --library / --mock / --help block to [parser].
void addBridgeAndHelpFlags(ArgParser parser) {
  parser
    ..addOption(
      'library',
      abbr: 'l',
      help:
          'Path to a prebuilt nts_rust dylib. If omitted, auto-locates '
          'one under rust/target/release/.',
    )
    ..addFlag(
      'mock',
      negatable: false,
      help: 'Use the in-memory mock bridge (no native dylib required).',
    )
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show this help.');
}

/// Parse a positive-int option, or null if missing/invalid/below [min].
int? posInt(String? raw, {int min = 1}) {
  final v = int.tryParse(raw ?? '');
  return (v == null || v < min) ? null : v;
}

/// Print [message] and [usage] to stderr, then exit [kExitUsage].
///
/// Wipes any registered `--custom-roots` buffer first: `exit` does not
/// unwind, so this is the only chance a usage failure raised after the
/// roots were read gets to clear them.
Never usageError(String message, {required String usage}) {
  wipeRegisteredCustomRoots();
  stderr.writeln('argument error: $message');
  stderr.writeln(usage);
  exit(kExitUsage);
}

/// The validated probe options shared by both tools.
class CommonProbeArgs {
  final int port;
  final int timeoutMs;
  final int samples;
  final int concurrency;
  final int offsetThresholdMs;

  /// Explicit `--dns-cap` override, or null to auto-size the DNS
  /// resolver cap to `--concurrency` in [loadAndProbeCatalog].
  final int? dnsCap;
  final bool useMock;
  final String? libraryPath;
  final String path;

  /// Resolved `--trust-mode`, defaulting to
  /// [TrustMode.platformWithFallback] when the flag is omitted.
  final TrustMode trustMode;

  /// Bytes read from `--custom-roots`, or null when the flag is omitted.
  ///
  /// Wiped in place by [loadAndProbeCatalog] once the client has copied
  /// them, so this field reads as zeros for the rest of the run. Do not
  /// treat it as a live copy of the anchor set.
  ///
  /// The wipe needs a list that accepts element assignment. That holds
  /// for what `parseCommonProbeArgs` reads (`readAsBytesSync` returns a
  /// `Uint8List`), but this constructor is public: a caller passing a
  /// `const` list, a `List.unmodifiable`, or an unmodifiable view keeps
  /// its own bytes resident, because [wipeCustomRoots] cannot clear
  /// them.
  final List<int>? customRoots;

  /// Resolved `--require-trust-backend`, or null for no assertion.
  final TrustBackend? requiredBackend;
  const CommonProbeArgs({
    required this.port,
    required this.timeoutMs,
    required this.samples,
    required this.concurrency,
    required this.offsetThresholdMs,
    required this.dnsCap,
    required this.useMock,
    required this.libraryPath,
    required this.path,
    this.trustMode = TrustMode.platformWithFallback,
    this.customRoots,
    this.requiredBackend,
  });
}

/// Validate the common flags and the single positional `<path>` from
/// [args], exiting via [usageError] (with [usage]) on any violation.
CommonProbeArgs parseCommonProbeArgs(ArgResults args, {required String usage}) {
  if (args.rest.length != 1) {
    usageError('expected exactly one <path> to a server list', usage: usage);
  }
  final port = posInt(args['port'] as String);
  final timeoutMs = posInt(args['timeout'] as String);
  final samples = posInt(args['samples'] as String);
  final concurrency = posInt(args['concurrency'] as String);
  final offsetMs = posInt(args['offset-threshold-ms'] as String, min: 0);
  if (port == null || port > 65535) {
    usageError('--port must be 1..65535', usage: usage);
  }
  if (timeoutMs == null) {
    usageError('--timeout must be a positive integer', usage: usage);
  }
  if (samples == null) {
    usageError('--samples must be >= 1', usage: usage);
  }
  if (concurrency == null) {
    usageError('--concurrency must be >= 1', usage: usage);
  }
  if (offsetMs == null) {
    usageError('--offset-threshold-ms must be >= 0', usage: usage);
  }
  final dnsCapRaw = args['dns-cap'] as String?;
  int? dnsCap;
  if (dnsCapRaw != null) {
    dnsCap = posInt(dnsCapRaw);
    if (dnsCap == null) {
      usageError('--dns-cap must be >= 1', usage: usage);
    }
  }

  // `allowed:` on both trust options means the parser has already
  // rejected anything outside the two value sets, so the parse helpers
  // cannot return null here; the `??` arm exists only to keep the local
  // non-nullable.
  final trustModeRaw = args['trust-mode'] as String?;
  final trustMode = trustModeRaw == null
      ? TrustMode.platformWithFallback
      : parseTrustMode(trustModeRaw) ?? TrustMode.platformWithFallback;
  final requiredBackendRaw = args['require-trust-backend'] as String?;
  final requiredBackend = requiredBackendRaw == null
      ? null
      : parseTrustBackend(requiredBackendRaw);

  // Read the roots here so an unreadable path is an argument error
  // rather than a trust-policy one. `loadAndProbeCatalog` wipes the
  // buffer once the client has copied it; the package zeroises only its
  // own FFI-side copy and leaves the caller's list untouched.
  //
  // Registering makes every termination site between this read and that
  // wipe — the checks below, `--per-region`, the catalog load, and
  // `initBridge` — able to clear the bytes without holding a reference.
  final customRootsPath = args['custom-roots'] as String?;
  List<int>? customRoots;
  if (customRootsPath != null) {
    try {
      customRoots = File(customRootsPath).readAsBytesSync();
    } on FileSystemException catch (e) {
      usageError('--custom-roots: ${e.message}', usage: usage);
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
    usageError(pairingError, usage: usage);
  }

  return CommonProbeArgs(
    port: port,
    timeoutMs: timeoutMs,
    samples: samples,
    concurrency: concurrency,
    offsetThresholdMs: offsetMs,
    dnsCap: dnsCap,
    useMock: args['mock'] as bool,
    libraryPath: args['library'] as String?,
    path: args.rest.single,
    trustMode: trustMode,
    customRoots: customRoots,
    requiredBackend: requiredBackend,
  );
}

/// One catalog load + probe run: the parsed [entries], their [report]
/// (completion order, not input order), and the resolved [args].
class CatalogProbeOutcome {
  final List<NtsServerEntry> entries;
  final List<ServerHealth> report;
  final CommonProbeArgs args;
  const CatalogProbeOutcome({
    required this.entries,
    required this.report,
    required this.args,
  });
}

/// Load the catalog at [common].path, init the FRB bridge, and probe
/// every host through the shared runner. Exits [kExitUsage] on a
/// missing/empty/unparseable file (bridge failures exit via `initBridge`).
Future<CatalogProbeOutcome> loadAndProbeCatalog(CommonProbeArgs common) async {
  // `parseCommonProbeArgs` registers what it reads, but [common] is
  // publicly constructible, so a caller can arrive here with roots this
  // process has never seen. Registering again covers that path and is a
  // no-op when the buffer is already tracked.
  registerCustomRootsForWipe(common.customRoots);

  // Each of these exits precedes the client construction that consumes
  // the roots, so each has to clear them itself: `exit` does not unwind.
  final file = File(common.path);
  if (!file.existsSync()) {
    wipeRegisteredCustomRoots();
    stderr.writeln('error: server list not found at ${common.path}');
    exit(kExitUsage);
  }
  final List<NtsServerEntry> entries;
  try {
    entries = parseServerYaml(file.readAsStringSync());
  } catch (e) {
    wipeRegisteredCustomRoots();
    stderr.writeln('error: failed to parse ${common.path}: $e');
    exit(kExitUsage);
  }
  if (entries.isEmpty) {
    wipeRegisteredCustomRoots();
    stderr.writeln('error: ${common.path} parsed to zero servers');
    exit(kExitUsage);
  }

  await initBridge(useMock: common.useMock, libraryPath: common.libraryPath);

  // Size the package's process-wide DNS resolver cap to the host fan-out
  // so a concurrent probe wave can never self-saturate it: with the
  // mobile-sized default (kDefaultDnsConcurrencyCap = 4) a `-c 8` run
  // starves its own excess workers, which fast-fail with
  // TimeoutPhase.dnsSaturation and get mis-bucketed as `notReplying`.
  // Each host worker holds at most one in-flight lookup, so a cap equal
  // to the worker count guarantees every worker a slot; the lower bound
  // keeps the package default for small `-c`. An explicit `--dns-cap`
  // overrides the auto-sizing; the help text flags the fast-fail
  // exposure a below-`-c` value re-opens.
  final dnsCap =
      common.dnsCap ??
      (common.concurrency > kDefaultDnsConcurrencyCap
          ? common.concurrency
          : kDefaultDnsConcurrencyCap);
  // Same sizing for the Dart-side bridge admission gate
  // (kDefaultBridgeConcurrencyCap = 4): a `-c 8` run would otherwise
  // queue its excess workers at the gate, charging the queue wait
  // against each host's probe budget and skewing (or timing out with
  // TimeoutPhase.bridgeSaturation) measurements the tool would then
  // mis-attribute to the server. A cap equal to the worker count
  // guarantees every worker immediate admission.
  final bridgeCap = common.concurrency > kDefaultBridgeConcurrencyCap
      ? common.concurrency
      : kDefaultBridgeConcurrencyCap;

  // Default policy keeps routing through the top-level functions and
  // the process-wide default client they share, so the path every
  // pre-existing invocation takes gains no client lifecycle and no new
  // failure surface. Anything else mints exactly one client for the
  // whole catalog, which the package documents as safe to share across
  // concurrent calls. The catch is a backstop: `parseCommonProbeArgs`
  // already rejects every combination the constructor validates, so it
  // only fires if the two ever drift.
  NtsClient? client;
  if (common.trustMode != TrustMode.platformWithFallback ||
      common.customRoots != null) {
    NtsError? constructionError;
    try {
      client = NtsClient(
        trustMode: common.trustMode,
        customRoots: common.customRoots,
      );
    } on NtsError catch (err) {
      constructionError = err;
    } finally {
      // The constructor has either consumed the bytes or rejected the
      // arguments by now — its pair validation throws before the copy —
      // so nothing downstream still needs them either way. The wipe is
      // in place, so it also clears the view reachable through `common`
      // and the `CatalogProbeOutcome.args` this function returns —
      // those alias the same buffer rather than holding copies of it.
      // `finally` covers the success path and a non-[NtsError] escape;
      // the usage exit below is deliberately outside it, because `exit`
      // terminates the VM without unwinding.
      //
      // Scoped to this call's buffer, not the whole registry: this
      // function suspends at `await initBridge`, so a second concurrent
      // custom-policy call can be registered by the time we resume, and
      // a blanket wipe would zero its bytes before its own constructor
      // reads them. The exits above keep the blanket form — they end
      // the process, so there is nothing left to starve.
      wipeAndDeregisterCustomRoots(common.customRoots);
    }
    if (constructionError != null) {
      stderr.writeln('argument error: ${describeError(constructionError)}');
      exit(kExitUsage);
    }
  }

  final List<ServerHealth> report;
  try {
    report = await probeAll(
      entries,
      port: common.port,
      // Single conversion point: the CLI surface stays milliseconds.
      timeout: Duration(milliseconds: common.timeoutMs),
      samples: common.samples,
      concurrency: common.concurrency,
      dnsConcurrencyCap: dnsCap,
      bridgeConcurrencyCap: bridgeCap,
      thresholds: HealthThresholds(
        offsetThresholdMicros: common.offsetThresholdMs * 1000,
      ),
      client: client,
      requiredBackend: common.requiredBackend,
      onProgress: (done, total, health) => stderr.writeln(
        '[$done/$total] ${health.hostname}: ${health.verdict.name}',
      ),
    );
  } finally {
    // probeHost swallows every per-host failure, so the only way out
    // here is a defect in the fan-out itself — but the session table
    // this client owns holds cookies and derived keys, so release it on
    // that path too rather than leaving it to process teardown.
    client?.dispose();
  }
  return CatalogProbeOutcome(entries: entries, report: report, args: common);
}

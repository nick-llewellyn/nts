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
    show kDefaultBridgeConcurrencyCap, kDefaultDnsConcurrencyCap;

import '../data/server_catalog.dart' show parseServerYaml;
import '../data/server_entry.dart' show NtsServerEntry;
import '../health/probe.dart' show probeAll;
import '../health/server_health.dart' show HealthThresholds, ServerHealth;
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
Never usageError(String message, {required String usage}) {
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
  final bool useMock;
  final String? libraryPath;
  final String path;
  const CommonProbeArgs({
    required this.port,
    required this.timeoutMs,
    required this.samples,
    required this.concurrency,
    required this.offsetThresholdMs,
    required this.useMock,
    required this.libraryPath,
    required this.path,
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
  return CommonProbeArgs(
    port: port,
    timeoutMs: timeoutMs,
    samples: samples,
    concurrency: concurrency,
    offsetThresholdMs: offsetMs,
    useMock: args['mock'] as bool,
    libraryPath: args['library'] as String?,
    path: args.rest.single,
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
  final file = File(common.path);
  if (!file.existsSync()) {
    stderr.writeln('error: server list not found at ${common.path}');
    exit(kExitUsage);
  }
  final List<NtsServerEntry> entries;
  try {
    entries = parseServerYaml(file.readAsStringSync());
  } catch (e) {
    stderr.writeln('error: failed to parse ${common.path}: $e');
    exit(kExitUsage);
  }
  if (entries.isEmpty) {
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
  // keeps the package default for small `-c`.
  final dnsCap = common.concurrency > kDefaultDnsConcurrencyCap
      ? common.concurrency
      : kDefaultDnsConcurrencyCap;
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
  final report = await probeAll(
    entries,
    port: common.port,
    timeoutMs: common.timeoutMs,
    samples: common.samples,
    concurrency: common.concurrency,
    dnsConcurrencyCap: dnsCap,
    bridgeConcurrencyCap: bridgeCap,
    thresholds: HealthThresholds(
      offsetThresholdMicros: common.offsetThresholdMs * 1000,
    ),
    onProgress: (done, total, health) => stderr.writeln(
      '[$done/$total] ${health.hostname}: ${health.verdict.name}',
    ),
  );
  return CatalogProbeOutcome(entries: entries, report: report, args: common);
}

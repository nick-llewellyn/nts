// Catalog health auditor for the example app's NTS server list.
//
// Unlike `bin/nts_cli.dart` (which probes hostnames passed positionally
// and streams a per-host log), this tool is pointed at a *server list
// file* — the same YAML schema as `assets/nts-sources.yml` — probes
// every entry, and prints an aggregated health report designed to weed
// the catalog: servers that don't reply, that fail the NTS/NTP protocol
// checks, or that answer with non-standard parameters (a non-baseline
// AEAD, an unusable stratum, or a wildly-off clock) are bucketed and
// surfaced as a "suggested removals" list. Healthy servers are ranked
// by median round-trip time over N samples.
//
// The core `nts` library ships no server list; this is example-app
// tooling only. It only *reads* the file it is given and never mutates
// the curated catalog.
//
// Usage:
//   fvm dart run bin/nts_health.dart assets/nts-sources.yml
//   fvm dart run bin/nts_health.dart --samples 5 --format json list.yml
//   fvm dart run bin/nts_health.dart --mock assets/nts-sources.yml
//
// Bridge loading and the --mock / --library flags mirror nts_cli (the
// shared loader lives in lib/src/cli/bridge_loader.dart).

import 'dart:convert';
import 'dart:io';
import 'dart:math' show min;

import 'package:args/args.dart';
import 'package:nts/nts.dart'
    show NtsError, NtsServerSpec, kDefaultDnsConcurrencyCap, ntsQuery;

import 'package:nts_example/src/cli/bridge_loader.dart' show initBridge;
import 'package:nts_example/src/data/server_catalog.dart' show parseServerYaml;
import 'package:nts_example/src/data/server_entry.dart' show NtsServerEntry;
import 'package:nts_example/src/health/health_report.dart';
import 'package:nts_example/src/health/server_health.dart';
import 'package:nts_example/src/state/nts_format.dart'
    show errorTypeName, isErrorSeverity, timeoutPhaseName;

const int _kDefaultPort = 4460;
const int _kDefaultTimeoutMs = 5000;
const int _kDefaultSamples = 3;
const int _kDefaultConcurrency = 8;
const int _kDefaultOffsetThresholdMs = 1000;
const int _kExitUsage = 64;
const int _kExitDrops = 1;
const Set<String> _kFormats = {'text', 'json', 'csv'};

ArgParser _buildParser() => ArgParser()
  ..addOption(
    'port',
    abbr: 'p',
    defaultsTo: '$_kDefaultPort',
    help: 'TCP port for NTS-KE on every host.',
  )
  ..addOption(
    'timeout',
    abbr: 't',
    defaultsTo: '$_kDefaultTimeoutMs',
    help: 'Per-request timeout in milliseconds (one global deadline).',
  )
  ..addOption(
    'samples',
    abbr: 'n',
    defaultsTo: '$_kDefaultSamples',
    help: 'Probes per host; the median RTT is reported.',
  )
  ..addOption(
    'concurrency',
    abbr: 'c',
    defaultsTo: '$_kDefaultConcurrency',
    help: 'Max hosts probed in parallel.',
  )
  ..addOption(
    'offset-threshold-ms',
    defaultsTo: '$_kDefaultOffsetThresholdMs',
    help: 'Flag a host as non-standard if |clock offset| exceeds this.',
  )
  ..addOption(
    'format',
    abbr: 'f',
    allowed: _kFormats,
    defaultsTo: 'text',
    help: 'Output format.',
  )
  ..addOption(
    'library',
    abbr: 'l',
    help:
        'Path to a prebuilt nts_rust dylib file. If omitted, '
        'auto-locates one under rust/target/release/.',
  )
  ..addFlag(
    'mock',
    negatable: false,
    help: 'Use the in-memory mock bridge (no native dylib required).',
  )
  ..addFlag(
    'fail-on-drops',
    negatable: false,
    help: 'Exit $_kExitDrops if any host is a drop candidate.',
  )
  ..addFlag('help', abbr: 'h', negatable: false, help: 'Show this help.');

String _usage(ArgParser parser) =>
    'Usage: nts_health [options] <path-to-server-list.yml>\n${parser.usage}';

/// Parse a positive-int option, or null if missing/invalid/below [min].
int? _posInt(String? raw, {int min = 1}) {
  final v = int.tryParse(raw ?? '');
  return (v == null || v < min) ? null : v;
}

void _usageError(String message, ArgParser parser) {
  stderr.writeln('argument error: $message');
  stderr.writeln(_usage(parser));
  exit(_kExitUsage);
}

Future<void> main(List<String> argv) async {
  final parser = _buildParser();
  final ArgResults args;
  try {
    args = parser.parse(argv);
  } on FormatException catch (e) {
    _usageError(e.message, parser);
    return;
  }

  if (args['help'] as bool) {
    stdout.writeln(_usage(parser));
    return;
  }
  if (args.rest.length != 1) {
    _usageError('expected exactly one <path> to a server list', parser);
  }

  final port = _posInt(args['port'] as String);
  final timeoutMs = _posInt(args['timeout'] as String);
  final samples = _posInt(args['samples'] as String);
  final concurrency = _posInt(args['concurrency'] as String);
  final offsetMs = _posInt(args['offset-threshold-ms'] as String, min: 0);
  if (port == null || port > 65535) {
    _usageError('--port must be 1..65535', parser);
  }
  if (timeoutMs == null) {
    _usageError('--timeout must be a positive int', parser);
  }
  if (samples == null) {
    _usageError('--samples must be >= 1', parser);
  }
  if (concurrency == null) {
    _usageError('--concurrency must be >= 1', parser);
  }
  if (offsetMs == null) {
    _usageError('--offset-threshold-ms must be >= 0', parser);
  }

  final path = args.rest.single;
  final file = File(path);
  if (!file.existsSync()) {
    stderr.writeln('error: server list not found at $path');
    exit(_kExitUsage);
  }
  final List<NtsServerEntry> entries;
  try {
    entries = parseServerYaml(file.readAsStringSync());
  } catch (e) {
    stderr.writeln('error: failed to parse $path: $e');
    exit(_kExitUsage);
  }
  if (entries.isEmpty) {
    stderr.writeln('error: $path parsed to zero servers');
    exit(_kExitUsage);
  }

  await initBridge(
    useMock: args['mock'] as bool,
    libraryPath: args['library'] as String?,
  );

  final thresholds = HealthThresholds(offsetThresholdMicros: offsetMs! * 1000);
  // Size the package's process-wide DNS resolver cap to the host
  // fan-out so a concurrent probe wave can never self-saturate it: with
  // the mobile-sized default (kDefaultDnsConcurrencyCap = 4) a `-c 8`
  // run starves its own excess workers, which fast-fail with
  // TimeoutPhase.dnsSaturation and get mis-bucketed as `notReplying`.
  // Each host worker holds at most one in-flight lookup, so a cap equal
  // to the worker count guarantees every worker a slot; the lower bound
  // keeps the package default for small `-c`.
  final dnsCap = concurrency! > kDefaultDnsConcurrencyCap
      ? concurrency
      : kDefaultDnsConcurrencyCap;
  final report = await _probeAll(
    entries,
    port: port!,
    timeoutMs: timeoutMs!,
    samples: samples!,
    concurrency: concurrency,
    dnsConcurrencyCap: dnsCap,
    thresholds: thresholds,
  );

  switch (args['format'] as String) {
    case 'json':
      stdout.writeln(
        const JsonEncoder.withIndent('  ').convert(jsonReport(report)),
      );
    case 'csv':
      stdout.write(csvReport(report));
    default:
      stdout.write(renderTextReport(report, source: path, samples: samples));
  }

  if ((args['fail-on-drops'] as bool) && report.any((h) => h.isDropCandidate)) {
    exit(_kExitDrops);
  }
}

/// Probe every entry with bounded fan-out, emitting per-host progress
/// to stderr so a long run shows liveness without polluting stdout.
Future<List<ServerHealth>> _probeAll(
  List<NtsServerEntry> entries, {
  required int port,
  required int timeoutMs,
  required int samples,
  required int concurrency,
  required int dnsConcurrencyCap,
  required HealthThresholds thresholds,
}) async {
  final pending = List<NtsServerEntry>.of(entries);
  final out = <ServerHealth>[];
  final total = entries.length;
  var done = 0;

  Future<void> worker() async {
    while (pending.isNotEmpty) {
      final entry = pending.removeLast();
      final health = await _probeHost(
        entry,
        port: port,
        timeoutMs: timeoutMs,
        samples: samples,
        dnsConcurrencyCap: dnsConcurrencyCap,
        thresholds: thresholds,
      );
      out.add(health);
      done++;
      stderr.writeln(
        '[$done/$total] ${entry.hostname}: ${health.verdict.name}',
      );
    }
  }

  await Future.wait([
    for (var i = 0; i < min(concurrency, total); i++) worker(),
  ]);
  return out;
}

/// Run [samples] sequential probes against one host and classify them.
Future<ServerHealth> _probeHost(
  NtsServerEntry entry, {
  required int port,
  required int timeoutMs,
  required int samples,
  required int dnsConcurrencyCap,
  required HealthThresholds thresholds,
}) async {
  final spec = NtsServerSpec(host: entry.hostname, port: port);
  final results = <ProbeResult>[];
  for (var i = 0; i < samples; i++) {
    try {
      final s = await ntsQuery(
        spec: spec,
        timeoutMs: timeoutMs,
        dnsConcurrencyCap: dnsConcurrencyCap,
      );
      final localMicros = DateTime.now().toUtc().microsecondsSinceEpoch;
      final serverEstimate = s.utcUnixMicros + s.roundTripMicros ~/ 2;
      results.add(
        ProbeOk(
          rttMicros: s.roundTripMicros,
          stratum: s.serverStratum,
          aeadId: s.aeadId,
          offsetMicros: serverEstimate - localMicros,
        ),
      );
    } on NtsError catch (err) {
      results.add(
        ProbeFailure(
          errorType: errorTypeName(err),
          errorSeverity: isErrorSeverity(err),
          phase: timeoutPhaseName(err),
        ),
      );
    } catch (_) {
      results.add(
        const ProbeFailure(errorType: 'Unhandled', errorSeverity: true),
      );
    }
  }
  return summarizeServer(
    hostname: entry.hostname,
    results: results,
    thresholds: thresholds,
  );
}

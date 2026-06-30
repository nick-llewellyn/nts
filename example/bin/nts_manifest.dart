// Reliable-server manifest generator for the example app's NTS catalog.
//
// Pointed at the same server-list YAML as `bin/nts_health.dart`
// (`assets/nts-sources.yml`), it live-probes every host through the
// shared probe runner, keeps only the `healthy`-verdict servers, groups
// them by geographic region, and selects a diverse 2-3 per region
// (distinct operators first, then lowest median RTT). The result is a
// curated, machine-readable JSON manifest a *separate* application can
// ship to pick regional servers for low-latency queries without runtime
// geolocation.
//
// This is example-app tooling: it only reads the catalog and writes the
// manifest; it never mutates the curated list. Bridge loading and the
// --mock / --library flags mirror nts_cli / nts_health.
//
// Usage:
//   fvm dart run bin/nts_manifest.dart assets/nts-sources.yml
//   fvm dart run bin/nts_manifest.dart -n 5 -o assets/reliable-servers.json \
//       assets/nts-sources.yml
//   fvm dart run bin/nts_manifest.dart --mock assets/nts-sources.yml

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:nts/nts.dart' show kDefaultDnsConcurrencyCap;

import 'package:nts_example/src/cli/bridge_loader.dart' show initBridge;
import 'package:nts_example/src/data/server_catalog.dart' show parseServerYaml;
import 'package:nts_example/src/data/server_entry.dart' show NtsServerEntry;
import 'package:nts_example/src/health/probe.dart' show probeAll;
import 'package:nts_example/src/health/server_health.dart'
    show HealthThresholds;
import 'package:nts_example/src/manifest/manifest_builder.dart'
    show buildManifest, kDefaultPerRegion;

const int _kDefaultPort = 4460;
const int _kDefaultTimeoutMs = 5000;
const int _kDefaultSamples = 3;
const int _kDefaultConcurrency = 8;
const int _kDefaultOffsetThresholdMs = 1000;
const int _kExitUsage = 64;

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
    help: 'Per-request timeout in milliseconds.',
  )
  ..addOption(
    'samples',
    abbr: 'n',
    defaultsTo: '$_kDefaultSamples',
    help: 'Probes per host; the median RTT ranks survivors.',
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
    help: 'Flag a host non-standard if |clock offset| exceeds this.',
  )
  ..addOption(
    'per-region',
    defaultsTo: '$kDefaultPerRegion',
    help: 'Max servers selected per region.',
  )
  ..addOption(
    'output',
    abbr: 'o',
    help: 'Write JSON to this file instead of stdout.',
  )
  ..addOption(
    'library',
    abbr: 'l',
    help: 'Path to a prebuilt nts_rust dylib. Defaults to auto-locate.',
  )
  ..addFlag(
    'mock',
    negatable: false,
    help: 'Use the in-memory mock bridge (no native dylib required).',
  )
  ..addFlag('help', abbr: 'h', negatable: false, help: 'Show this help.');

String _usage(ArgParser parser) =>
    'Usage: nts_manifest [options] <path-to-server-list.yml>\n${parser.usage}';

int? _posInt(String? raw, {int min = 1}) {
  final v = int.tryParse(raw ?? '');
  return (v == null || v < min) ? null : v;
}

Never _usageError(String message, ArgParser parser) {
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
  final perRegion = _posInt(args['per-region'] as String);
  if (port == null || port > 65535)
    _usageError('--port must be 1..65535', parser);
  if (timeoutMs == null) _usageError('--timeout must be positive', parser);
  if (samples == null) _usageError('--samples must be >= 1', parser);
  if (concurrency == null) _usageError('--concurrency must be >= 1', parser);
  if (offsetMs == null)
    _usageError('--offset-threshold-ms must be >= 0', parser);
  if (perRegion == null) _usageError('--per-region must be >= 1', parser);

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

  final dnsCap = concurrency > kDefaultDnsConcurrencyCap
      ? concurrency
      : kDefaultDnsConcurrencyCap;
  final report = await probeAll(
    entries,
    port: port,
    timeoutMs: timeoutMs,
    samples: samples,
    concurrency: concurrency,
    dnsConcurrencyCap: dnsCap,
    thresholds: HealthThresholds(offsetThresholdMicros: offsetMs * 1000),
    onProgress: (done, total, h) =>
        stderr.writeln('[$done/$total] ${h.hostname}: ${h.verdict.name}'),
  );

  final manifest = buildManifest(
    catalog: entries,
    health: report,
    perRegion: perRegion,
    samples: samples,
    offsetThresholdMs: offsetMs,
    source: path,
    generatedAt: DateTime.now().toUtc().toIso8601String(),
  );
  final json = const JsonEncoder.withIndent('  ').convert(manifest);

  final output = args['output'] as String?;
  if (output == null) {
    stdout.writeln(json);
  } else {
    File(output).writeAsStringSync('$json\n');
    stderr.writeln('wrote manifest to $output');
  }
}

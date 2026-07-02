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

import 'package:nts_example/src/cli/catalog_tool_args.dart';
import 'package:nts_example/src/manifest/manifest_builder.dart'
    show buildManifest, kDefaultPerRegion;

Future<void> main(List<String> argv) async {
  final parser = ArgParser();
  addCommonProbeOptions(parser);
  parser
    ..addOption(
      'per-region',
      defaultsTo: '$kDefaultPerRegion',
      help: 'Max servers selected per region.',
    )
    ..addOption(
      'output',
      abbr: 'o',
      help: 'Write JSON to this file instead of stdout.',
    );
  addBridgeAndHelpFlags(parser);

  final usage =
      'Usage: nts_manifest [options] <path-to-server-list.yml>\n'
      '${parser.usage}';
  final ArgResults args;
  try {
    args = parser.parse(argv);
  } on FormatException catch (e) {
    usageError(e.message, usage: usage);
  }
  if (args['help'] as bool) {
    stdout.writeln(usage);
    return;
  }

  final common = parseCommonProbeArgs(args, usage: usage);
  final perRegion = posInt(args['per-region'] as String);
  if (perRegion == null) {
    usageError('--per-region must be >= 1', usage: usage);
  }

  final outcome = await loadAndProbeCatalog(common);

  final manifest = buildManifest(
    catalog: outcome.entries,
    health: outcome.report,
    perRegion: perRegion,
    samples: common.samples,
    offsetThresholdMs: common.offsetThresholdMs,
    source: common.path,
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

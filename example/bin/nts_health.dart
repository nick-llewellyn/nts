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

import 'package:args/args.dart';

import 'package:nts_example/src/cli/catalog_tool_args.dart';
import 'package:nts_example/src/health/health_report.dart';

const int _kExitDrops = 1;
const Set<String> _kFormats = {'text', 'json', 'csv'};

Future<void> main(List<String> argv) async {
  final parser = ArgParser();
  addCommonProbeOptions(parser);
  parser
    ..addOption(
      'format',
      abbr: 'f',
      allowed: _kFormats,
      defaultsTo: 'text',
      help: 'Output format.',
    )
    ..addFlag(
      'fail-on-drops',
      negatable: false,
      help: 'Exit $_kExitDrops if any host is a drop candidate.',
    );
  addBridgeAndHelpFlags(parser);

  final usage =
      'Usage: nts_health [options] <path-to-server-list.yml>\n'
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
  final outcome = await loadAndProbeCatalog(common);
  final report = outcome.report;

  switch (args['format'] as String) {
    case 'json':
      stdout.writeln(
        const JsonEncoder.withIndent('  ').convert(jsonReport(report)),
      );
    case 'csv':
      stdout.write(csvReport(report));
    default:
      stdout.write(
        renderTextReport(report, source: common.path, samples: common.samples),
      );
  }

  if ((args['fail-on-drops'] as bool) && report.any((h) => h.isDropCandidate)) {
    exit(_kExitDrops);
  }
}

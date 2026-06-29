// Flutter-bound asset wrapper for the bundled NTS server catalog.
//
// Reads `assets/nts-sources.yml` through the Flutter asset bundle
// (`rootBundle`) and delegates the actual YAML → [NtsServerEntry] parse
// to the Flutter-free [parseServerYaml] in `server_catalog.dart`, which
// this library re-exports so existing GUI imports (and the parser's
// unit tests) keep resolving `parseServerYaml`, the Markdown-link
// splitting, and the schema unchanged.
//
// The parser was split out so command-line tools (`bin/nts_cli.dart`,
// `bin/nts_health.dart`) can parse the same catalog under plain
// `dart run` without importing `package:flutter/services.dart` — and
// thus `dart:ui`, which is unavailable outside the Flutter engine and
// would make those binaries fail to start.

import 'package:flutter/services.dart' show rootBundle;

import 'server_catalog.dart';
import 'server_entry.dart';

// Re-export the Flutter-free parser so existing consumers (and the
// `server_loader_test.dart` suite) that import this file keep seeing
// `parseServerYaml` unchanged.
export 'server_catalog.dart' show parseServerYaml;

/// Asset key for the bundled NTS-KE server catalog. Declared in
/// `pubspec.yaml > flutter > assets`.
const String kNtsSourcesAsset = 'assets/nts-sources.yml';

/// Reads [kNtsSourcesAsset] from the Flutter asset bundle and returns
/// a freshly-parsed list of [NtsServerEntry], sorted by hostname so
/// the UI has a stable baseline ordering before favourites kick in.
Future<List<NtsServerEntry>> loadBundledServers() async {
  final raw = await rootBundle.loadString(kNtsSourcesAsset);
  return parseServerYaml(raw);
}

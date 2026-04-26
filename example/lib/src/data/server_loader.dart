// Loads `assets/nts-sources.yml` into a list of [NtsServerEntry].
//
// The bundled file follows the schema produced by the upstream gist
// (mutin-sa/eea1c396b1e610a2da1e5550d94b0453) republished as YAML:
//
//   servers:
//     - hostname: time.cloudflare.com
//       stratum: 3
//       location: All
//       owner: Cloudflare
//       notes: Anycast
//       vm: false
//
// `hostname` and `owner` may also arrive wrapped in Markdown link
// syntax — `'[label](https://example.org)'` — because the source
// document is rendered as HTML. We split that form into the underlying
// label plus a companion URL so the UI doesn't have to repeat the
// regex on every build.
//
// Malformed individual rows are skipped (and silently dropped) rather
// than aborting the whole load, so a single broken entry never
// bricks app startup. The asset itself is mandatory: a missing or
// unparseable `servers:` key surfaces as a thrown exception that the
// app's bootstrap path renders as a banner.

import 'package:flutter/services.dart' show rootBundle;
import 'package:yaml/yaml.dart' show YamlList, YamlMap, loadYaml;

import 'server_entry.dart';

/// Asset key for the bundled NTS-KE server catalog. Declared in
/// `pubspec.yaml > flutter > assets`.
const String kNtsSourcesAsset = 'assets/nts-sources.yml';

/// Matches the upstream Markdown link form `[label](url)` used by the
/// gist for some hostnames and owner attributions. Capture group 1 is
/// the visible label, group 2 is the URL.
final RegExp _markdownLink = RegExp(r'^\[([^\]]+)\]\((.*)\)$');

/// Reads [kNtsSourcesAsset] from the Flutter asset bundle and returns
/// a freshly-parsed list of [NtsServerEntry], sorted by hostname so
/// the UI has a stable baseline ordering before favourites kick in.
Future<List<NtsServerEntry>> loadBundledServers() async {
  final raw = await rootBundle.loadString(kNtsSourcesAsset);
  return parseServerYaml(raw);
}

/// Parses a YAML document with the shape documented in this file's
/// header. Public so tests can exercise the parser without going
/// through the asset bundle.
List<NtsServerEntry> parseServerYaml(String source) {
  final doc = loadYaml(source);
  if (doc is! YamlMap) return const [];
  final servers = doc['servers'];
  if (servers is! YamlList) return const [];

  final out = <NtsServerEntry>[];
  for (final raw in servers) {
    if (raw is! YamlMap) continue;
    final entry = _entryFromMap(raw);
    if (entry != null) out.add(entry);
  }
  out.sort((a, b) => a.hostname.compareTo(b.hostname));
  return out;
}

NtsServerEntry? _entryFromMap(YamlMap row) {
  final rawHost = row['hostname'];
  if (rawHost is! String || rawHost.isEmpty) return null;
  final (host, hostUrl) = _splitMarkdownLink(rawHost);
  if (host.isEmpty) return null;

  final rawOwner = row['owner'];
  final ownerString = rawOwner is String ? rawOwner : rawOwner?.toString();
  final (owner, ownerUrl) = ownerString == null || ownerString.isEmpty
      ? ('Unknown', null)
      : _splitMarkdownLink(ownerString);

  final location = (row['location'] is String)
      ? row['location'] as String
      : 'Unknown';
  final notes = row['notes'] is String ? row['notes'] as String : null;
  final stratum = row['stratum'] is int ? row['stratum'] as int : null;
  final vm = row['vm'] == true;

  return NtsServerEntry(
    hostname: host,
    displayUrl: hostUrl,
    owner: owner,
    ownerUrl: ownerUrl,
    location: location,
    stratum: stratum,
    notes: notes,
    vm: vm,
  );
}

/// Splits a possibly-markdown-wrapped string into (label, url). Inputs
/// that don't match the `[label](url)` form are returned verbatim with
/// a `null` URL.
(String, String?) _splitMarkdownLink(String input) {
  final m = _markdownLink.firstMatch(input.trim());
  if (m == null) return (input, null);
  return (m.group(1)!, m.group(2));
}

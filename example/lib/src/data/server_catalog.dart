// Flutter-free parser for the bundled NTS server catalog YAML.
//
// This is the pure, dependency-light half of the catalog loader: it
// depends only on `package:yaml` and `server_entry.dart`, deliberately
// *not* on `package:flutter/services.dart`. That separation lets
// command-line tools run via plain `dart run` (e.g. `bin/nts_cli.dart`,
// `bin/nts_health.dart`) parse the same YAML the GUI ships, without
// pulling in `dart:ui` — which is unavailable outside the Flutter
// engine and would make those binaries fail to start.
//
// The Flutter-bound asset wrapper (`loadBundledServers`, which reads the
// asset through `rootBundle`) lives in `server_loader.dart`, which
// re-exports everything here so existing GUI imports keep working.
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
// label plus a companion URL so callers don't have to repeat the regex.
//
// Malformed individual rows are skipped (and silently dropped) rather
// than aborting the whole load, so a single broken entry never bricks a
// consumer. A missing or unparseable `servers:` key yields an empty
// list rather than throwing.

import 'package:yaml/yaml.dart' show YamlList, YamlMap, loadYaml;

import 'server_entry.dart';

/// Matches the upstream Markdown link form `[label](url)` used by the
/// gist for some hostnames and owner attributions. Capture group 1 is
/// the visible label, group 2 is the URL.
final RegExp _markdownLink = RegExp(r'^\[([^\]]+)\]\((.*)\)$');

/// Parses a YAML document with the shape documented in this file's
/// header into a list of [NtsServerEntry], sorted by hostname so
/// consumers have a stable baseline ordering.
///
/// Pure and Flutter-free: takes the raw document text directly, so both
/// the asset-bundle path and file-path-based CLI tools share one
/// parser. Returns an empty list for a missing or non-list `servers:`
/// key rather than throwing.
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

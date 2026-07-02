// Pure builder for the curated reliable-server manifest.
//
// Takes the parsed catalog plus the per-host [ServerHealth] verdicts
// produced by the shared probe runner and emits a deterministic,
// JSON-encodable map: only `healthy`-verdict hosts, grouped by region,
// with up to N per region chosen operator-diversity-first then by lowest
// median RTT. Kept Flutter-free and side-effect-free so the selection
// logic is unit-testable without the FRB bridge; `bin/nts_manifest.dart`
// is the thin live-probing wrapper around it.
//
// Determinism: no wall-clock timestamp is embedded here (the CLI adds
// provenance), and every ordering — regions via [kRegionOrder], servers
// via RTT-ascending with a hostname tiebreak — is total, so the same
// inputs always yield byte-identical JSON.

import '../data/server_entry.dart' show NtsServerEntry, kNtsKePort;
import '../health/server_health.dart' show HealthVerdict, ServerHealth;
import '../state/nts_format.dart' show aeadLabel;
import 'region.dart';

/// Default cap on servers selected per region (the "2-3 per region"
/// target rounds up to 3).
const int kDefaultPerRegion = 3;

/// One catalog entry paired with its probe verdict.
typedef ScoredServer = (NtsServerEntry entry, ServerHealth health);

/// Build the manifest map (ready for `jsonEncode`) from the [catalog]
/// and its [health] verdicts. [samples] and [offsetThresholdMs], when
/// given, are echoed into the `criteria` block as provenance.
Map<String, Object?> buildManifest({
  required List<NtsServerEntry> catalog,
  required List<ServerHealth> health,
  int perRegion = kDefaultPerRegion,
  int? samples,
  int? offsetThresholdMs,
  String? source,
  String? generatedAt,
}) {
  final byHost = {for (final h in health) h.hostname: h};

  // Pair each catalog entry with its verdict, keeping only hosts that
  // were probed, came back `healthy`, and have a median RTT to rank by.
  final healthy = <ScoredServer>[];
  for (final e in catalog) {
    final h = byHost[e.hostname];
    if (h == null || h.verdict != HealthVerdict.healthy) continue;
    if (h.medianRttMicros == null) continue;
    healthy.add((e, h));
  }

  final byRegion = <String, List<ScoredServer>>{};
  for (final pair in healthy) {
    (byRegion[regionForLocation(pair.$1.location)] ??= []).add(pair);
  }

  final regions = <String, Object?>{};
  var totalServers = 0;
  for (final region in kRegionOrder) {
    final candidates = byRegion[region];
    if (candidates == null || candidates.isEmpty) continue;
    final selected = selectForRegion(candidates, perRegion);
    totalServers += selected.length;
    regions[region] = [
      for (final p in selected) _serverJson(region, p.$1, p.$2),
    ];
  }

  return {
    'schema_version': 1,
    'generated_at': ?generatedAt,
    'source': ?source,
    'criteria': {
      'verdict': 'healthy',
      'samples': ?samples,
      'offset_threshold_ms': ?offsetThresholdMs,
      'max_per_region': perRegion,
      'selection': 'operator-diversity first, then lowest median RTT',
    },
    'totals': {'regions': regions.length, 'servers': totalServers},
    'regions': regions,
  };
}

/// Select up to [perRegion] hosts from one region's [candidates],
/// maximising distinct operators first and then preferring lowest median
/// RTT. Exposed for unit testing.
List<ScoredServer> selectForRegion(
  List<ScoredServer> candidates,
  int perRegion,
) {
  if (perRegion <= 0) return const [];
  // Total RTT-ascending order (hostname tiebreak) underlies both passes.
  final sorted = [...candidates]
    ..sort((a, b) {
      final c = a.$2.medianRttMicros!.compareTo(b.$2.medianRttMicros!);
      return c != 0 ? c : a.$1.hostname.compareTo(b.$1.hostname);
    });

  final picked = <ScoredServer>[];
  final seenOwners = <String>{};
  // Pass 1: the lowest-RTT host of each distinct operator (diversity).
  for (final p in sorted) {
    if (picked.length >= perRegion) break;
    if (seenOwners.add(p.$1.owner)) picked.add(p);
  }
  // Pass 2: backfill remaining slots with the next lowest-RTT hosts
  // irrespective of operator, so a region served by only one or two
  // operators still yields up to [perRegion] for redundancy.
  if (picked.length < perRegion) {
    for (final p in sorted) {
      if (picked.length >= perRegion) break;
      if (!picked.contains(p)) picked.add(p);
    }
  }
  return picked;
}

/// One server's JSON object: enough for a client to connect (hostname +
/// port + negotiated AEAD) and to rank/attribute it (region, location,
/// owner, stratum, median RTT, clock offset).
Map<String, Object?> _serverJson(
  String region,
  NtsServerEntry e,
  ServerHealth h,
) => {
  'hostname': e.hostname,
  'port': kNtsKePort,
  'region': region,
  'location': e.location,
  'owner': e.owner,
  if (e.ownerUrl != null) 'owner_url': e.ownerUrl,
  'stratum': h.stratum,
  'aead_id': h.aeadId,
  'aead_label': h.aeadId == null ? null : aeadLabel(h.aeadId!),
  'median_rtt_micros': h.medianRttMicros,
  'offset_micros': h.offsetMicros,
  'vm': e.vm,
};

// Unit coverage for the pure manifest builder (`manifest_builder.dart`)
// and the region mapping (`region.dart`).
//
// Requested in PR #193 review (NTS-59): the selection/mapping logic is
// exercised end-to-end by the `nts_manifest` CLI smoke run, but the
// operator-diversity tiebreak, the single-operator backfill, region
// bucketing, and the null-aware provenance block warrant focused,
// bridge-free tests so regressions surface without a network probe.

import 'package:flutter_test/flutter_test.dart';
import 'package:nts_example/src/data/server_entry.dart';
import 'package:nts_example/src/health/server_health.dart';
import 'package:nts_example/src/manifest/manifest_builder.dart';
import 'package:nts_example/src/manifest/region.dart';

NtsServerEntry _entry(
  String host, {
  required String location,
  required String owner,
  String? ownerUrl,
  int? stratum,
  bool vm = false,
}) => NtsServerEntry(
  hostname: host,
  location: location,
  owner: owner,
  ownerUrl: ownerUrl,
  stratum: stratum,
  vm: vm,
);

ServerHealth _healthy(
  String host, {
  required int rtt,
  int stratum = 1,
  int aeadId = 15,
  int offset = 0,
}) => ServerHealth(
  hostname: host,
  verdict: HealthVerdict.healthy,
  reasons: const [],
  probes: 3,
  successes: 3,
  medianRttMicros: rtt,
  stratum: stratum,
  aeadId: aeadId,
  offsetMicros: offset,
);

ScoredServer _pair(String host, String owner, int rtt) =>
    (_entry(host, location: 'Germany', owner: owner), _healthy(host, rtt: rtt));

void main() {
  group('regionForLocation', () {
    test('maps known country names to their region', () {
      expect(regionForLocation('Germany'), kRegionEurope);
      expect(regionForLocation('US'), kRegionNorthAmerica);
      expect(regionForLocation('Brazil'), kRegionSouthAmerica);
      expect(regionForLocation('Japan'), kRegionAsia);
      expect(regionForLocation('All'), kRegionGlobal);
    });

    test('is case- and whitespace-insensitive', () {
      expect(regionForLocation('  germany  '), kRegionEurope);
      expect(regionForLocation('UNITED KINGDOM'), kRegionEurope);
    });

    test('unrecognised values fall back to Other', () {
      expect(regionForLocation('Atlantis'), kRegionOther);
      expect(regionForLocation('Distro'), kRegionOther);
      expect(regionForLocation(''), kRegionOther);
    });
  });

  group('selectForRegion', () {
    test('perRegion <= 0 selects nothing', () {
      expect(selectForRegion([_pair('a', 'A', 100)], 0), isEmpty);
      expect(selectForRegion([_pair('a', 'A', 100)], -1), isEmpty);
    });

    test('prefers operator diversity over raw RTT for the 2nd slot', () {
      final candidates = [
        _pair('a1', 'A', 100),
        _pair('a2', 'A', 200),
        _pair('b1', 'B', 250),
      ];
      final picked = selectForRegion(candidates, 2);
      expect(picked.map((p) => p.$1.hostname), ['a1', 'b1']);
    });

    test('backfills a single-operator region up to perRegion by RTT', () {
      final candidates = [
        _pair('a3', 'A', 300),
        _pair('a1', 'A', 100),
        _pair('a2', 'A', 200),
      ];
      final picked = selectForRegion(candidates, 3);
      expect(picked.map((p) => p.$1.hostname), ['a1', 'a2', 'a3']);
    });

    test('equal RTT breaks ties on hostname', () {
      final candidates = [_pair('zeta', 'A', 100), _pair('alpha', 'A', 100)];
      expect(selectForRegion(candidates, 1).single.$1.hostname, 'alpha');
    });
  });

  group('buildManifest', () {
    List<NtsServerEntry> catalog() => [
      _entry('de1', location: 'Germany', owner: 'OpA', ownerUrl: 'https://a'),
      _entry('de2', location: 'Germany', owner: 'OpB'),
      _entry('us1', location: 'US', owner: 'OpC'),
      _entry('down', location: 'US', owner: 'OpD'),
    ];

    List<ServerHealth> health() => [
      _healthy('de1', rtt: 100),
      _healthy('de2', rtt: 200),
      _healthy('us1', rtt: 150),
      ServerHealth(
        hostname: 'down',
        verdict: HealthVerdict.notReplying,
        reasons: const [],
        probes: 3,
        successes: 0,
      ),
    ];

    test('keeps only healthy hosts, grouped in region order', () {
      final m = buildManifest(catalog: catalog(), health: health());
      final regions = m['regions'] as Map<String, Object?>;
      expect(regions.keys, [kRegionNorthAmerica, kRegionEurope]);
      expect((m['totals'] as Map)['servers'], 3);
      final eu = regions[kRegionEurope] as List;
      expect((eu.first as Map)['hostname'], 'de1');
    });

    test('drops healthy hosts with no median RTT', () {
      final noRtt = [
        _healthy('de1', rtt: 100),
        ServerHealth(
          hostname: 'de2',
          verdict: HealthVerdict.healthy,
          reasons: const [],
          probes: 3,
          successes: 3,
        ),
      ];
      final m = buildManifest(catalog: catalog(), health: noRtt);
      final eu = (m['regions'] as Map)[kRegionEurope] as List;
      expect(eu.map((s) => (s as Map)['hostname']), ['de1']);
    });

    test('echoes provenance and elides null-aware entries', () {
      final full = buildManifest(
        catalog: catalog(),
        health: health(),
        samples: 4,
        offsetThresholdMs: 250,
        source: 'nts-sources.yml',
        generatedAt: '2026-01-01T00:00:00Z',
      );
      expect(full['generated_at'], '2026-01-01T00:00:00Z');
      expect(full['source'], 'nts-sources.yml');
      final criteria = full['criteria'] as Map;
      expect(criteria['samples'], 4);
      expect(criteria['offset_threshold_ms'], 250);

      final bare = buildManifest(catalog: catalog(), health: health());
      expect(bare.containsKey('generated_at'), isFalse);
      expect(bare.containsKey('source'), isFalse);
      expect((bare['criteria'] as Map).containsKey('samples'), isFalse);
    });

    test('server JSON carries the connect + attribution fields', () {
      final m = buildManifest(catalog: catalog(), health: health());
      final de1 = ((m['regions'] as Map)[kRegionEurope] as List).first as Map;
      expect(de1['port'], kNtsKePort);
      expect(de1['region'], kRegionEurope);
      expect(de1['owner'], 'OpA');
      expect(de1['owner_url'], 'https://a');
      expect(de1['aead_label'], 'AES-SIV-CMAC-256(15)');
      final de2 = ((m['regions'] as Map)[kRegionEurope] as List)[1] as Map;
      expect(de2.containsKey('owner_url'), isFalse);
    });
  });
}

// Unit tests for the [AppState] reactive filter pipeline.
//
// Focused on the region-filter semantics introduced when the
// [kUniversalLocation] wildcard was added: catalogs frequently
// contain anycast / globally-reachable entries (e.g. Cloudflare)
// whose `location` is the literal string `'All'`. Those entries
// must remain visible regardless of which specific region the user
// has selected, and selecting the [kAllRegions] sentinel must show
// the entire catalog.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nts_example/src/data/server_entry.dart';
import 'package:nts_example/src/state/app_state.dart';
import 'package:nts_example/src/state/favorites_store.dart';
import 'package:nts_example/src/state/log_buffer.dart';

const _catalog = <NtsServerEntry>[
  NtsServerEntry(
    hostname: 'time.cloudflare.com',
    location: kUniversalLocation,
    owner: 'Cloudflare',
    notes: 'Anycast',
  ),
  NtsServerEntry(
    hostname: 'nts.netnod.se',
    location: 'Sweden',
    owner: 'Netnod AB',
  ),
  NtsServerEntry(
    hostname: 'ptbtime1.ptb.de',
    location: 'Germany',
    owner: 'Physikalisch-Technische Bundesanstalt',
  ),
  NtsServerEntry(
    hostname: 'nts.teambelgium.net',
    location: 'Belgium',
    owner: 'Team Belgium',
  ),
];

Future<AppState> _bootState() async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final favorites = await FavoritesStore.load();
  return AppState(
    bridgeMode: 'mock',
    bridgeLoadError: null,
    catalog: _catalog,
    favorites: favorites,
    log: NtsLogBuffer(),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppState region filter', () {
    test('kAllRegions sentinel shows the entire catalog', () async {
      final state = await _bootState();
      // Default value is kAllRegions; assert explicitly so the test
      // remains correct even if the default ever changes.
      state.regionFilter.value = kAllRegions;

      final visible = state.filtered.value.map((e) => e.hostname).toSet();
      expect(visible, equals(_catalog.map((e) => e.hostname).toSet()));
    });

    test(
      'selecting a specific region keeps universal entries visible',
      () async {
        final state = await _bootState();
        state.regionFilter.value = 'Belgium';

        final visible = state.filtered.value.map((e) => e.hostname).toSet();
        // Belgium row + Cloudflare (universal) — Sweden / Germany hidden.
        expect(
          visible,
          equals(<String>{'nts.teambelgium.net', 'time.cloudflare.com'}),
        );
      },
    );

    test('universal entries appear under every region', () async {
      final state = await _bootState();
      for (final region in const ['Sweden', 'Germany', 'Belgium']) {
        state.regionFilter.value = region;
        final hosts = state.filtered.value.map((e) => e.hostname);
        expect(
          hosts,
          contains('time.cloudflare.com'),
          reason: 'Cloudflare should remain visible under region=$region',
        );
      }
    });

    test('regions dropdown excludes the universal-location wildcard', () async {
      final state = await _bootState();
      // First entry must be the sentinel.
      expect(state.regions.first, kAllRegions);
      // The literal 'All' (kUniversalLocation) must not be offered as
      // a selectable region — it would behave identically to the
      // sentinel and confuse the user.
      expect(state.regions, isNot(contains(kUniversalLocation)));
      // Real regions present in the test catalog must still appear.
      expect(
        state.regions,
        containsAll(<String>['Belgium', 'Germany', 'Sweden']),
      );
    });

    test(
      'search and region filters compose without dropping universals',
      () async {
        final state = await _bootState();
        state.regionFilter.value = 'Germany';
        // Search term that matches Cloudflare's owner but not the
        // German entry's owner. Cloudflare should pass region (via the
        // universal wildcard) AND the search predicate; the German
        // entry should be filtered out by search.
        state.searchQuery.value = 'cloudflare';

        final visible = state.filtered.value.map((e) => e.hostname).toList();
        expect(visible, equals(<String>['time.cloudflare.com']));
      },
    );
  });
}

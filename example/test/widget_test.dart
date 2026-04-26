// Smoke tests for the nts example shell.
//
// Boot the app under the in-memory MockNtsApi (no native dylib
// needed) with a fixed three-row catalog and an empty favourites
// store, then exercise the search box, the action buttons, and the
// live log. Tests are deliberately content-light and behaviour-heavy:
// they don't assert on the YAML catalog (which is loaded at runtime
// from the asset bundle in production) but on the reactive plumbing
// the refactor introduced.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nts/nts.dart' show RustLib;
import 'package:nts_example/src/data/server_entry.dart';
import 'package:nts_example/src/home_page.dart';
import 'package:nts_example/src/mock_api.dart';
import 'package:nts_example/src/state/app_state.dart';
import 'package:nts_example/src/state/favorites_store.dart';
import 'package:nts_example/src/state/log_buffer.dart';
import 'package:nts_example/src/state/nts_controller.dart';

const _testCatalog = <NtsServerEntry>[
  NtsServerEntry(
    hostname: 'time.cloudflare.com',
    location: 'All',
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
];

Future<({AppState state, NtsController controller})> _bootHarness() async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final favorites = await FavoritesStore.load();
  final state = AppState(
    bridgeMode: 'mock',
    bridgeLoadError: null,
    catalog: _testCatalog,
    favorites: favorites,
    log: NtsLogBuffer(),
  );
  return (state: state, controller: NtsController(state));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    RustLib.initMock(api: MockNtsApi());
  });

  setUp(() {
    // The default 800x600 surface clips the third row of the server
    // list under the action panel + log card stack. Bump to a tall
    // tablet-ish viewport so every test can assert on rows without
    // having to scroll the inner ListView.
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    binding.platformDispatcher.views.first.physicalSize = const Size(
      1080,
      1800,
    );
    binding.platformDispatcher.views.first.devicePixelRatio = 1.0;
  });

  testWidgets('home page renders the catalog, action buttons and log', (
    tester,
  ) async {
    final h = await _bootHarness();
    await tester.pumpWidget(
      MaterialApp(
        home: HomePage(state: h.state, controller: h.controller),
      ),
    );
    await tester.pump();

    for (final entry in _testCatalog) {
      expect(find.text(entry.hostname), findsOneWidget);
    }
    expect(find.text('NTS Query'), findsOneWidget);
    expect(find.text('Warm Cookies'), findsOneWidget);
    expect(find.text('Live log'), findsOneWidget);
  });

  testWidgets('search filters the visible server list', (tester) async {
    final h = await _bootHarness();
    await tester.pumpWidget(
      MaterialApp(
        home: HomePage(state: h.state, controller: h.controller),
      ),
    );
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'netnod');
    await tester.pump();

    expect(find.text('nts.netnod.se'), findsOneWidget);
    expect(find.text('time.cloudflare.com'), findsNothing);
    expect(find.text('ptbtime1.ptb.de'), findsNothing);
  });

  testWidgets('tapping NTS Query funnels start + OK lines into the log', (
    tester,
  ) async {
    final h = await _bootHarness();
    await tester.pumpWidget(
      MaterialApp(
        home: HomePage(state: h.state, controller: h.controller),
      ),
    );
    await tester.pump();

    // `AppState.selected` defaults to `catalog.first`, so the buttons
    // are enabled out of the gate.
    await tester.tap(find.text('NTS Query'));
    // MockNtsApi sleeps 25-65 ms; pump generously.
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();

    final lines = h.state.log.entries.value
        .where((e) => e.source == 'nts_query')
        .toList();
    expect(lines, isNotEmpty);
    expect(lines.any((e) => e.message.startsWith('Starting query')), isTrue);
    expect(
      lines.any(
        (e) =>
            e.message.startsWith('OK ') &&
            e.message.contains('stratum=') &&
            e.message.contains('aead='),
      ),
      isTrue,
    );
  });

  testWidgets('toggling favourites re-orders the list with pinned first', (
    tester,
  ) async {
    final h = await _bootHarness();
    await tester.pumpWidget(
      MaterialApp(
        home: HomePage(state: h.state, controller: h.controller),
      ),
    );
    await tester.pump();

    h.state.favorites.toggle('ptbtime1.ptb.de');
    await tester.pump();

    final visible = h.state.filtered.value;
    expect(visible.first.hostname, 'ptbtime1.ptb.de');
  });
}

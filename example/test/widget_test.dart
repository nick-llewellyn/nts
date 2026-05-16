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
import 'package:nts/nts.dart' show RustLib, TrustMode;
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

    // Client tab is the default landing surface: catalog rows, the
    // two action buttons, the trust-status row, and the new
    // latest-result summary card all live here.
    for (final entry in _testCatalog) {
      expect(find.text(entry.hostname), findsOneWidget);
    }
    expect(find.text('NTS Query'), findsOneWidget);
    expect(find.text('Warm Cookies'), findsOneWidget);
    expect(find.text('Latest result'), findsOneWidget);

    // The full live log moved to its own tab so it can claim a full
    // viewport height. Switch over and verify the header renders.
    await tester.tap(find.text('Log'));
    await tester.pumpAndSettle();
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
    final ok = lines.firstWhere((e) => e.message.startsWith('OK '));
    expect(ok.message, contains('stratum='));
    expect(ok.message, contains('aead='));
    // 3.0.0: trust backend rides on the success line so a reader can
    // spot a fallback path without consulting the dartdoc.
    expect(ok.message, contains('trust='));
    // Host context flows through to the structured field so the on-
    // screen log and the share-export both attribute the line to a
    // specific server.
    expect(ok.host, 'time.cloudflare.com');
    // Structured trust-backend metadata is preserved on the entry so
    // log-scrapers / future filters can attribute backend-by-host
    // without re-parsing the prose message.
    expect(ok.trustBackend, isNotNull);
    // Share-export carries the new `[host=...]` and `[backend=...]`
    // tokens in their fixed columns.
    final exported = ok.formatForExport();
    expect(exported, contains('[host=time.cloudflare.com]'));
    expect(exported, contains('[backend=${ok.trustBackend!.name}]'));
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

  testWidgets('TrustMode toggle flips the signal and emits a system log line', (
    tester,
  ) async {
    final h = await _bootHarness();
    await tester.pumpWidget(
      MaterialApp(
        home: HomePage(state: h.state, controller: h.controller),
      ),
    );
    await tester.pump();

    // Default policy is platform-with-fallback.
    expect(h.state.trustMode.value, TrustMode.platformWithFallback);

    // The trust-mode selector is a DropdownButton<TrustMode> inlined
    // in the action row: tap the currently-rendered selection to
    // expand the menu, then tap the alternative.
    await tester.tap(find.text('Platform + fallback'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Platform only').last);
    await tester.pumpAndSettle();

    expect(h.state.trustMode.value, TrustMode.platformOnly);
    // The controller's subscription posts a `system` line that
    // names the new mode and the cookie-pool drop. Asserting on
    // the line rather than just the signal proves the controller
    // is wired to the signal end-to-end.
    final sys = h.state.log.entries.value
        .where((e) => e.source == 'system')
        .toList();
    expect(
      sys.any((e) => e.message.contains('TrustMode → platform-only')),
      isTrue,
    );
  });

  testWidgets('TrustStatusPanel renders the last-handshake sentinel before '
      'any per-client handshake has fired', (tester) async {
    final h = await _bootHarness();
    await tester.pumpWidget(
      MaterialApp(
        home: HomePage(state: h.state, controller: h.controller),
      ),
    );
    await tester.pump();

    expect(find.text('Trust status'), findsOneWidget);
    expect(
      find.textContaining('last-handshake-backend: (no per-client'),
      findsOneWidget,
    );
    expect(h.state.lastHandshakeBackend.value, isNull);
  });

  testWidgets(
    'a successful per-client query populates the last-handshake row',
    (tester) async {
      final h = await _bootHarness();
      await tester.pumpWidget(
        MaterialApp(
          home: HomePage(state: h.state, controller: h.controller),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('NTS Query'));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();

      // Per-client row reflects what the just-completed handshake
      // actually used; mock returns TrustBackend.platform on the
      // happy path.
      expect(h.state.lastHandshakeBackend.value, isNotNull);
      expect(find.textContaining('last-handshake-backend: '), findsOneWidget);
    },
  );

  testWidgets(
    'flipping TrustMode resets lastHandshakeBackend so the panel does '
    'not show stale attribution from the dropped client',
    (tester) async {
      final h = await _bootHarness();
      await tester.pumpWidget(
        MaterialApp(
          home: HomePage(state: h.state, controller: h.controller),
        ),
      );
      await tester.pump();

      // Drive a successful query so the last-handshake row populates.
      await tester.tap(find.text('NTS Query'));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();
      expect(h.state.lastHandshakeBackend.value, isNotNull);

      // Flip the trust mode -- the controller mints a new NtsClient
      // and must clear the now-stale attribution because the backend
      // recorded earlier belongs to a session table that has just
      // been dropped. Dropdown selection requires expanding the menu
      // first since "Platform only" is only painted once open.
      await tester.tap(find.text('Platform + fallback'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Platform only').last);
      await tester.pumpAndSettle();

      expect(h.state.trustMode.value, TrustMode.platformOnly);
      expect(h.state.lastHandshakeBackend.value, isNull);
      expect(
        find.textContaining('last-handshake-backend: (no per-client'),
        findsOneWidget,
      );
    },
  );

  testWidgets('an in-flight query that completes after a TrustMode flip does '
      'not overwrite the new client\'s attribution', (tester) async {
    final h = await _bootHarness();
    await tester.pumpWidget(
      MaterialApp(
        home: HomePage(state: h.state, controller: h.controller),
      ),
    );
    await tester.pump();

    // Kick off a query against the default (PlatformWithFallback)
    // client and immediately flip the toggle while the future is
    // still suspended on the mock's 25-65ms delay. Driving the
    // signal directly here (rather than opening the DropdownButton
    // and tapping the menu item) is deliberate: the dropdown's
    // route-open animation requires `pumpAndSettle`, which would
    // drain enough simulated time for the mock's `Future.delayed`
    // to fire before the flip — defeating the race the test is
    // specifically built to exercise. The controller's
    // `_onTrustModeChanged` subscription runs synchronously off the
    // signal write, so this still funnels through the production
    // path it cares about.
    await tester.tap(find.text('NTS Query'));
    await tester.pump();
    h.state.trustMode.value = TrustMode.platformOnly;
    await tester.pump();

    // Flush the in-flight future.
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();

    // Active client is the new (PlatformOnly) one, which has run
    // no handshake of its own; the in-flight query's completion
    // landed against a dropped client, so lastHandshakeBackend
    // must stay at its post-toggle sentinel `null`.
    expect(h.state.trustMode.value, TrustMode.platformOnly);
    expect(h.state.lastHandshakeBackend.value, isNull);

    // The success line still rides into the log (the protocol
    // event happened, the user wants to see it) but is annotated
    // so the reader knows the state-write was suppressed.
    final logs = h.state.log.entries.value
        .where((e) => e.source == 'nts_query')
        .toList();
    expect(
      logs.any((e) => e.message.contains('from previous TrustMode')),
      isTrue,
      reason: 'stale completion should be tagged in the log',
    );
  });

  testWidgets(
    'LatestResultPanel shows the empty-state copy before any query '
    'runs, then surfaces the most recent log entry afterwards',
    (tester) async {
      final h = await _bootHarness();
      await tester.pumpWidget(
        MaterialApp(
          home: HomePage(state: h.state, controller: h.controller),
        ),
      );
      await tester.pump();

      // Empty state: card header + the empty-state hint that names
      // the verb on the action button.
      expect(find.text('Latest result'), findsOneWidget);
      expect(
        find.textContaining('No queries yet'),
        findsOneWidget,
      );

      // Fire a query through the mock; the panel should swap to a
      // rendered span tree built from the latest log entry. The
      // span tree carries the `OK ` success marker emitted by
      // `formatQuerySuccess`, so we use a substring assertion
      // rather than pinning the full timestamped line.
      await tester.tap(find.text('NTS Query'));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();
      expect(
        find.textContaining('No queries yet'),
        findsNothing,
        reason: 'empty-state copy should disappear after first entry',
      );
      expect(
        find.textContaining('OK '),
        findsAtLeastNWidgets(1),
        reason: 'latest-result row should render the success line',
      );
    },
  );
}

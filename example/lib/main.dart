// Showcase entrypoint for the nts package.
//
// Bootstrap order is:
//
//   1. `WidgetsFlutterBinding.ensureInitialized` so we can hit the
//      asset bundle and `SharedPreferences` before runApp.
//   2. Bind the FRB bridge: real Rust dylib by default, in-memory
//      `MockNtsApi` when `--dart-define=NTS_BRIDGE=mock` is passed or
//      when the dylib fails to load (e.g. the host triple isn't pinned
//      in `rust/rust-toolchain.toml`). A load failure that already took
//      the entrypoint admits no mock, and short-circuits to
//      [BridgeUnavailableApp] instead of the steps below.
//   3. Load the bundled NTS server catalog from
//      `assets/nts-sources.yml`.
//   4. Hydrate the persisted favourites from `SharedPreferences`.
//   5. Wire those into a single [AppState] + [NtsController] pair and
//      hand them to the widget tree, where every reactive bit is
//      mediated through the `signals` package.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show DeviceOrientation, SystemChrome;
import 'package:nts/nts.dart' show NtsBridge, NtsBridgeState, NtsRustLib;
import 'package:signals/signals.dart' show SignalsObserver;

import 'src/data/server_entry.dart';
import 'src/data/server_loader.dart';
import 'src/home_page.dart';
import 'src/mock_api.dart';
import 'src/state/app_state.dart';
import 'src/state/favorites_store.dart';
import 'src/state/log_buffer.dart';
import 'src/state/nts_controller.dart';
import 'src/theme/nts_colors.dart';

const String _bridgeMode = String.fromEnvironment(
  'NTS_BRIDGE',
  defaultValue: 'real',
);

class _Boot {
  const _Boot({
    required this.label,
    required this.loadError,
    required this.bridgeUsable,
    required this.mockFallback,
    required this.catalog,
    required this.favorites,
  });

  final String label;
  final String? loadError;

  /// Whether a working bridge — real or mock — ended up installed. False
  /// only on the post-install initialization failure, where no `NtsClient`
  /// can be constructed and no query can be dispatched.
  final bool bridgeUsable;

  /// Whether the mock stood in for a real bridge that failed to load.
  /// Distinguishes the fallback from a run that asked for the mock, and
  /// from a working bridge that merely hit a catalog error.
  final bool mockFallback;
  final List<NtsServerEntry> catalog;
  final FavoritesStore favorites;
}

Future<_Boot> _bootstrap() async {
  String label;
  String? loadError;
  var bridgeUsable = true;
  var mockFallback = false;
  if (_bridgeMode == 'real') {
    try {
      await NtsBridge.ensureInitialized();
      label = 'real bridge';
    } catch (e) {
      // Fall back to mock so the UI still renders; the banner will
      // explain why we ended up here. Only a failure that installed
      // nothing leaves the `initMock` slot free: FRB installs its
      // state before awaiting the Rust initializers, so one of those
      // throwing leaves the bridge `native` but half-built, and a
      // second init would throw over the top of the real error. That
      // leaves no usable bridge at all, so the app renders a dead-end
      // screen rather than a UI whose every button would throw.
      if (NtsBridge.state == NtsBridgeState.uninitialized) {
        NtsRustLib.initMock(api: MockNtsApi());
        label = 'mock (load failed)';
        mockFallback = true;
      } else {
        label = 'bridge unavailable';
        bridgeUsable = false;
      }
      loadError =
          'Bridge initialization failed: $e\n'
          'The Native Assets hook (hook/build.dart) should bundle '
          'libnts_rust automatically; check that the host '
          'triple is pinned in rust/rust-toolchain.toml and that '
          '`flutter run` was used (not `dart run`). Pass '
          '--dart-define=NTS_BRIDGE=mock to silence this banner.';
    }
  } else {
    NtsRustLib.initMock(api: MockNtsApi());
    label = 'mock';
  }

  // Load the bundled YAML catalog. A missing or malformed asset
  // surfaces as an empty catalog plus a banner — we deliberately do
  // *not* fall back to a hard-coded server list, so the GUI's notion
  // of "what to probe" stays sourced exclusively from the asset.
  List<NtsServerEntry> catalog;
  try {
    catalog = await loadBundledServers();
    if (catalog.isEmpty) {
      final prefix = loadError == null ? '' : '$loadError\n\n';
      loadError =
          '${prefix}Server catalog is empty: $kNtsSourcesAsset '
          'parsed to zero usable rows. Edit that asset to populate the '
          'list.';
    }
  } catch (e) {
    catalog = const [];
    final prefix = loadError == null ? '' : '$loadError\n\n';
    loadError = '${prefix}Failed to load $kNtsSourcesAsset: $e';
  }
  final favorites = await FavoritesStore.load();
  return _Boot(
    label: label,
    loadError: loadError,
    bridgeUsable: bridgeUsable,
    mockFallback: mockFallback,
    catalog: catalog,
    favorites: favorites,
  );
}

Future<void> main() async {
  // signals 7.x installs a deprecated DevToolsSignalsObserver by
  // default in debug builds, which `developer.log`s every signal
  // create/update — including the full stringified log-buffer list on
  // each append. Disable it; re-set deliberately if the signals
  // devtools extension is ever wanted.
  SignalsObserver.instance = null;
  WidgetsFlutterBinding.ensureInitialized();
  await _lockOrientationOnPhones();
  final boot = await _bootstrap();
  if (!boot.bridgeUsable) {
    // No bridge to dispatch through, so there is nothing for the
    // controller to drive: constructing one would mint an `NtsClient`
    // over the half-built entrypoint and every button would throw.
    // Report the failure and stop.
    runApp(BridgeUnavailableApp(message: boot.loadError!));
    return;
  }
  final state = AppState(
    bridgeMode: boot.label,
    bridgeLoadError: boot.loadError,
    mockFallback: boot.mockFallback,
    catalog: boot.catalog,
    favorites: boot.favorites,
    log: NtsLogBuffer(),
  );
  state.log.info(
    'system',
    'Loaded ${boot.catalog.length} server(s); bridge=${boot.label}',
  );
  if (boot.loadError != null) {
    state.log.warn('system', boot.loadError!);
  }
  runApp(NtsExampleApp(state: state));
}

/// Locks the example app to portrait orientation when the launch
/// view's shortest side falls below the Material 600dp
/// "compact / medium" window-size-class breakpoint — the same
/// threshold M3 itself uses to switch between compact and medium
/// layouts. This is a *window-size* check, not a hardware check:
///
/// * Phones (whose physical screens are below 600dp regardless of
///   orientation) always trip the check and get locked.
/// * Tablets running fullscreen (Pixel Tablet, iPad, etc.) sit
///   well above 600dp shortest-side and do NOT get locked — they
///   keep their landscape support because the tabbed home layout
///   has the headroom to render every Client-tab panel without
///   overflow at those widths.
/// * Tablets launched into a compact multi-window slice
///   (Android split-screen, foldable folded-state, etc.) where
///   the launch view's shortest side measures below 600dp DO trip
///   the check and get locked to portrait, on the basis that the
///   slice is too narrow for landscape to work anyway. The
///   `LayoutBuilder` fallback in `_ClientTab` covers the residual
///   short-body case if the lock isn't enough.
///
/// Reading the size off `PlatformDispatcher.views.first` rather
/// than via `MediaQuery` keeps this a pure pre-`runApp` decision —
/// the lock is installed before the widget tree exists, so no
/// rebuild plumbing is needed.
///
/// `physicalSize` reports the current pixel dimensions in either
/// orientation; the `shortestSide / devicePixelRatio` projection
/// is orientation-invariant, so a phone launched in landscape is
/// still classified as compact and the OS rotates it back to
/// portrait once the preferred-orientations call lands.
///
/// On platforms where orientation is meaningless (desktop, web)
/// `SystemChrome.setPreferredOrientations` is a no-op on recent
/// Flutter versions, so the conditional doesn't need a
/// platform-specific guard.
Future<void> _lockOrientationOnPhones() async {
  final view = WidgetsBinding.instance.platformDispatcher.views.first;
  final shortestSideDp = view.physicalSize.shortestSide / view.devicePixelRatio;
  const phoneBreakpointDp = 600.0;
  if (shortestSideDp < phoneBreakpointDp) {
    await SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
  }
}

/// Owns the app-lifetime [NtsController].
///
/// Stateful purely for that ownership: the controller holds an
/// [NtsClient] whose native session table, cached AEAD keys and cookie
/// jars are released eagerly by `NtsController.dispose` rather than
/// left to the GC finalizer.
class NtsExampleApp extends StatefulWidget {
  const NtsExampleApp({super.key, required this.state});

  final AppState state;

  @override
  State<NtsExampleApp> createState() => _NtsExampleAppState();
}

class _NtsExampleAppState extends State<NtsExampleApp> {
  late final NtsController _controller = NtsController(widget.state);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Indigo-led palette. The seed (`brandPrimary`) drives the M3 tonal
    // palette as usual, but we then pin the prominent surfaces (filled
    // buttons, the app bar) to the raw seed so the brand colour reads
    // unmistakably rather than the desaturated tertiary-tinted variant
    // M3 would otherwise produce — especially in light mode, where
    // `scheme.primary` lands several stops darker than the seed.
    return MaterialApp(
      title: 'NTS',
      debugShowCheckedModeBanner: false,
      theme: _buildTheme(Brightness.light),
      darkTheme: _buildTheme(Brightness.dark),
      home: _Shell(
        loadError: widget.state.bridgeLoadError,
        mockFallback: widget.state.mockFallback,
        child: HomePage(state: widget.state, controller: _controller),
      ),
    );
  }

  /// Brand primary: Material Indigo 500. A neutral, slightly cool indigo
  /// chosen as both the M3 seed and the explicit accent on prominent
  /// surfaces. Hoisted so any future palette tweak is a one-line edit.
  static const Color brandPrimary = Color(0xFF3F51B5);

  static ThemeData _buildTheme(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: brandPrimary,
      brightness: brightness,
    );
    // Override the auto-generated `primary` with the raw brand colour
    // so every component that resolves through `scheme.primary` (filled
    // buttons, FAB, switch tracks, primary text fields, the M3 app bar
    // tint, etc.) renders the exact brand hue.
    final brandedScheme = scheme.copyWith(
      primary: brandPrimary,
      onPrimary: Colors.white,
    );
    final ntsColors = brightness == Brightness.dark
        ? NtsColors.dark(brandedScheme)
        : NtsColors.light(brandedScheme);
    return ThemeData(
      useMaterial3: true,
      colorScheme: brandedScheme,
      // Domain-specific tokens (success / warning / log timestamp) the
      // M3 ColorScheme deliberately doesn't carry. See
      // `src/theme/nts_colors.dart` for the full rationale.
      extensions: <ThemeExtension<dynamic>>[ntsColors],
      // App bar chrome: sit on the theme's surface tone (so it
      // tracks light/dark mode and recedes visually) and re-introduce
      // the brand hue on the title, icons, and any toolbar text so
      // the brand still reads loudly without dominating the bar.
      // Defined once here so every `AppBar` in the app inherits the
      // same pattern automatically.
      appBarTheme: AppBarTheme(
        backgroundColor: brandedScheme.surface,
        foregroundColor: brandPrimary,
        titleTextStyle: const TextStyle(
          color: brandPrimary,
          fontSize: 22,
          fontWeight: FontWeight.w500,
        ),
        toolbarTextStyle: const TextStyle(color: brandPrimary),
        elevation: 0,
        scrolledUnderElevation: 2,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: brandPrimary,
          foregroundColor: Colors.white,
          disabledBackgroundColor: brandedScheme.onSurface.withValues(
            alpha: 0.12,
          ),
          disabledForegroundColor: brandedScheme.onSurface.withValues(
            alpha: 0.38,
          ),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: brandPrimary,
          foregroundColor: Colors.white,
          disabledBackgroundColor: brandedScheme.onSurface.withValues(
            alpha: 0.12,
          ),
          disabledForegroundColor: brandedScheme.onSurface.withValues(
            alpha: 0.38,
          ),
        ),
      ),
    );
  }
}

class _Shell extends StatelessWidget {
  const _Shell({
    required this.child,
    required this.loadError,
    required this.mockFallback,
  });

  final Widget child;
  final String? loadError;

  /// Whether the diagnostic in [loadError] is the bridge-load failure
  /// that installed the mock. A catalog error also populates
  /// [loadError] while leaving the requested bridge in place, so the
  /// corner banner cannot be labelled off that field alone.
  final bool mockFallback;

  @override
  Widget build(BuildContext context) {
    if (loadError == null) return child;
    final banner = MaterialBanner(
      content: Text(loadError!),
      actions: const [SizedBox.shrink()],
    );
    final body = Column(
      children: [
        banner,
        Expanded(child: child),
      ],
    );
    if (!mockFallback) return body;
    return Banner(
      message: 'mock fallback',
      location: BannerLocation.topEnd,
      child: body,
    );
  }
}

/// Dead-end screen for the one failure that leaves no usable bridge: an
/// `ensureInitialized()` that threw *after* FRB installed its state, so
/// the entrypoint is occupied, half-built, and cannot be replaced in
/// this process. Nothing native-dependent is constructed — no
/// [AppState], no [NtsController] — because every call through them
/// would throw.
///
/// Public so a widget test can pump it directly; [main] is the only
/// production caller, and it cannot be driven from a test because
/// `bridgeUsable == false` requires a real half-built entrypoint.
class BridgeUnavailableApp extends StatelessWidget {
  const BridgeUnavailableApp({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NTS',
      debugShowCheckedModeBanner: false,
      theme: _NtsExampleAppState._buildTheme(Brightness.light),
      darkTheme: _NtsExampleAppState._buildTheme(Brightness.dark),
      home: Scaffold(
        appBar: AppBar(title: const Text('NTS')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error_outline, size: 48),
                const SizedBox(height: 16),
                Text(
                  'Bridge unavailable',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                Text(message, textAlign: TextAlign.center),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

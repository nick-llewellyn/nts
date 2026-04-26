// Showcase entrypoint for the nts package.
//
// Bootstrap order is:
//
//   1. `WidgetsFlutterBinding.ensureInitialized` so we can hit the
//      asset bundle and `SharedPreferences` before runApp.
//   2. Bind the FRB bridge: real Rust dylib by default, in-memory
//      `MockNtsApi` when `--dart-define=NTS_BRIDGE=mock` is passed or
//      when the dylib fails to load (e.g. the host triple isn't pinned
//      in `rust/rust-toolchain.toml`).
//   3. Load the bundled NTS server catalog from
//      `assets/nts-sources.yml`.
//   4. Hydrate the persisted favourites from `SharedPreferences`.
//   5. Wire those into a single [AppState] + [NtsController] pair and
//      hand them to the widget tree, where every reactive bit is
//      mediated through the `signals` package.

import 'package:flutter/material.dart';
import 'package:nts/nts.dart' show RustLib;

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
    required this.catalog,
    required this.favorites,
  });

  final String label;
  final String? loadError;
  final List<NtsServerEntry> catalog;
  final FavoritesStore favorites;
}

Future<_Boot> _bootstrap() async {
  String label;
  String? loadError;
  if (_bridgeMode == 'real') {
    try {
      await RustLib.init();
      label = 'real bridge';
    } catch (e) {
      // Fall back to mock so the UI still renders; the banner will
      // explain why we ended up here.
      RustLib.initMock(api: MockNtsApi());
      label = 'mock (load failed)';
      loadError =
          'RustLib.init() failed: $e\n'
          'The Native Assets hook (hook/build.dart) should bundle '
          'libnts_rust automatically; check that the host '
          'triple is pinned in rust/rust-toolchain.toml and that '
          '`flutter run` was used (not `dart run`). Pass '
          '--dart-define=NTS_BRIDGE=mock to silence this banner.';
    }
  } else {
    RustLib.initMock(api: MockNtsApi());
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
    catalog: catalog,
    favorites: favorites,
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final boot = await _bootstrap();
  final state = AppState(
    bridgeMode: boot.label,
    bridgeLoadError: boot.loadError,
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

class NtsExampleApp extends StatelessWidget {
  const NtsExampleApp({super.key, required this.state});

  final AppState state;

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
        loadError: state.bridgeLoadError,
        child: HomePage(state: state, controller: NtsController(state)),
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
  const _Shell({required this.child, required this.loadError});

  final Widget child;
  final String? loadError;

  @override
  Widget build(BuildContext context) {
    if (loadError == null) return child;
    return Banner(
      message: 'mock fallback',
      location: BannerLocation.topEnd,
      child: Column(
        children: [
          MaterialBanner(
            content: Text(loadError!),
            actions: const [SizedBox.shrink()],
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}

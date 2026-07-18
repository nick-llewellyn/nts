// Top-level showcase screen for the nts example.
//
// Split into two tabs so the catalog + action surface and the live
// log can each claim a full viewport height. Earlier revisions
// stacked everything in one Column, which on landscape phones /
// tablets squeezed `_LogHeader` past its intrinsic minimum and
// triggered `RenderFlex` overflow warnings, and made the Region
// dropdown menu in `ServerListView` visually collide with the
// action panel below it.
//
//   * **Client** tab — `ServerListView` (Expanded), `ActionPanel`,
//     `TrustStatusPanel`, `LatestResultPanel`. This is the
//     interactive surface: pick a server, pick a trust mode, fire
//     a query, read the single-entry summary.
//   * **Log** tab — `LogView` fills the whole tab body so the user
//     can scroll history without the action surface stealing
//     vertical space.
//
// Every reactive bit lives in the [AppState] / [NtsController] pair
// passed in by `main.dart`, so this widget is itself stateless.

import 'package:flutter/material.dart';

import 'state/app_state.dart';
import 'state/nts_controller.dart';
import 'widgets/action_panel.dart';
import 'widgets/custom_roots_panel.dart';
import 'widgets/latest_result_panel.dart';
import 'widgets/log_view.dart';
import 'widgets/server_list_view.dart';
import 'widgets/trust_status_panel.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key, required this.state, required this.controller});

  final AppState state;
  final NtsController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        // AppBar chrome (surface background, brand-coloured title +
        // toolbar text + icons) is defined once in `appBarTheme` so
        // every bar in the app follows the same pattern; nothing to
        // override here.
        appBar: AppBar(
          title: const Text('NTS'),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: Text(
                  state.bridgeMode,
                  style: theme.textTheme.labelMedium,
                ),
              ),
            ),
          ],
          bottom: TabBar(
            // `indicatorSize: tab` paints the selection underline
            // across the full tab cell rather than just the label
            // glyph width, so the indicator reads as a section
            // separator rather than a hairline beneath the text.
            // `labelStyle` / `unselectedLabelStyle` bump the type
            // up from the M3 default (~14sp titleSmall) to
            // titleMedium (~16sp); TabBar applies labelColor and
            // unselectedLabelColor on top from its M3 defaults.
            indicatorSize: TabBarIndicatorSize.tab,
            labelStyle: theme.textTheme.titleMedium,
            unselectedLabelStyle: theme.textTheme.titleMedium,
            tabs: const [
              Tab(text: 'Client'),
              Tab(text: 'Log'),
            ],
          ),
        ),
        body: SafeArea(
          child: TabBarView(
            children: [
              _ClientTab(state: state, controller: controller),
              LogView(state: state),
            ],
          ),
        ),
      ),
    );
  }
}

/// Catalog + action surface tab. Server list claims the upper
/// flexible region; the control / summary panels stack below
/// at intrinsic heights, separated by hairline dividers.
///
/// Switches between two layouts based on the body height:
///
/// * **Roomy** (≥ 400dp tall) — `Expanded(ServerListView)` plus the
///   intrinsic-height panels in a `Column`. This is the normal
///   phone-portrait and tablet path.
/// * **Compact** (< 400dp tall) — a `SingleChildScrollView` with a
///   fixed-height `ServerListView` on top and the panels below.
///   Covers tablet multi-window slices, foldables in the folded
///   half-state, and the brief frame during a pending phone-to-portrait
///   rotation before the orientation lock from `_lockOrientationOnPhones`
///   (in `main.dart`) takes effect. Without this dispatch the panels
///   plus the filter bar's ~120dp minimum can't both fit, and the outer
///   column surfaces a `RenderFlex` overflow.
class _ClientTab extends StatelessWidget {
  const _ClientTab({required this.state, required this.controller});

  final AppState state;
  final NtsController controller;

  /// Body-height threshold below which the layout switches to
  /// scrollable-compact mode. Sits comfortably above realistic
  /// phone-portrait and tablet-landscape body heights (each
  /// ~450dp+ after AppBar + TabBar + SafeArea), and well above the
  /// 255dp surface the original overflow report measured.
  static const double _tightHeightFloorDp = 400.0;

  /// Fixed height the server list claims in compact mode. Tuned so
  /// the filter bar (~120dp) plus a few list rows (~50dp each)
  /// stays useful without crowding out the action / status /
  /// latest-result panels stacked below.
  static const double _compactServerListHeightDp = 320.0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // The four panels below the server list are identical in
        // both layouts; only ServerListView's height-allocation
        // strategy changes.
        // Panels stacked below the server list. CustomRootsPanel is
        // zero-height when TrustMode.custom is not active, so the
        // divider before it is always rendered but the panel itself
        // collapses — this avoids a double-divider artefact.
        final bottomPanels = <Widget>[
          const Divider(height: 1),
          ActionPanel(state: state, controller: controller),
          const Divider(height: 1),
          CustomRootsPanel(state: state),
          TrustStatusPanel(state: state),
          const Divider(height: 1),
          LatestResultPanel(state: state),
        ];
        if (constraints.maxHeight < _tightHeightFloorDp) {
          // `primary: false` is load-bearing here: ServerListView's
          // inner ListView.builder default-attaches to the ambient
          // PrimaryScrollController, and a SingleChildScrollView in
          // a vertical axis would too by default. Two scroll views
          // claiming the same PrimaryScrollController throws a
          // runtime assertion the moment a real `Scrollable` builds
          // ('ScrollController attached to multiple scroll views').
          // Marking the outer scroller non-primary leaves the inner
          // ListView as the sole PrimaryScrollController consumer.
          return SingleChildScrollView(
            primary: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: _compactServerListHeightDp,
                  child: ServerListView(state: state),
                ),
                ...bottomPanels,
              ],
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: ServerListView(state: state)),
            ...bottomPanels,
          ],
        );
      },
    );
  }
}

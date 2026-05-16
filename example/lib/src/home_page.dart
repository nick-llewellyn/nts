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
//     a query, read the one-line summary.
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
          bottom: const TabBar(
            tabs: [
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
/// flexible region; the three control / summary panels stack below
/// at intrinsic heights, separated by hairline dividers.
class _ClientTab extends StatelessWidget {
  const _ClientTab({required this.state, required this.controller});

  final AppState state;
  final NtsController controller;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: ServerListView(state: state)),
        const Divider(height: 1),
        ActionPanel(state: state, controller: controller),
        const Divider(height: 1),
        TrustStatusPanel(state: state),
        const Divider(height: 1),
        LatestResultPanel(state: state),
      ],
    );
  }
}

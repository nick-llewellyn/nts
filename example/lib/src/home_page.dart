// Top-level showcase screen for the nts example.
//
// Composed of three reactive panels stacked vertically inside a
// `Scaffold`:
//
//   * `ServerListView`   — searchable / filterable / favouritable
//                           catalog loaded from `assets/nts-sources.yml`.
//   * `ActionPanel`      — the two action buttons that drive the
//                           underlying [NtsController]; outcomes go
//                           straight into the live log below.
//   * `LogView`          — bounded ring buffer of `NtsLogEntry`,
//                           rendered as a `SelectableText` so the
//                           user can copy individual lines, with a
//                           share-sheet handoff via `share_plus`.
//
// Every reactive bit lives in the [AppState] / [NtsController] pair
// passed in by `main.dart`, so this widget is itself stateless.

import 'package:flutter/material.dart';

import 'state/app_state.dart';
import 'state/nts_controller.dart';
import 'widgets/action_panel.dart';
import 'widgets/log_view.dart';
import 'widgets/server_list_view.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key, required this.state, required this.controller});

  final AppState state;
  final NtsController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
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
              child: Text(state.bridgeMode, style: theme.textTheme.labelMedium),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Server list claims the upper half; the action button
            // strip is its natural height; the log gets the remainder.
            Expanded(flex: 1, child: ServerListView(state: state)),
            const Divider(height: 1),
            ActionPanel(state: state, controller: controller),
            const Divider(height: 1),
            Expanded(flex: 1, child: LogView(state: state)),
          ],
        ),
      ),
    );
  }
}

// Action strip rendered between the server list and the live log:
// the two action buttons that drive the underlying [NtsController].
// Buttons are disabled only when no server is selected — operations
// are intentionally re-entrant, so the user can stack overlapping
// requests and watch them complete asynchronously in the log below.
// All outcome detail (sample fields, error variant, timing) lands
// directly in the log, tagged by host so concurrent results stay
// distinguishable.

import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart' show Watch;

import '../state/app_state.dart';
import '../state/nts_controller.dart';

class ActionPanel extends StatelessWidget {
  const ActionPanel({super.key, required this.state, required this.controller});

  final AppState state;
  final NtsController controller;

  @override
  Widget build(BuildContext context) {
    return Watch((context) {
      final selected = state.selected.value;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            FilledButton.icon(
              onPressed: selected == null
                  ? null
                  : () => controller.runQuery(selected),
              icon: const Icon(Icons.bolt),
              label: const Text('NTS Query'),
            ),
            const SizedBox(width: 12),
            FilledButton.tonalIcon(
              onPressed: selected == null
                  ? null
                  : () => controller.warmCookies(selected),
              icon: const Icon(Icons.cookie),
              label: const Text('Warm Cookies'),
            ),
          ],
        ),
      );
    });
  }
}

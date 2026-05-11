// Action strip rendered between the server list and the live log:
// the two action buttons that drive the underlying [NtsController]
// plus a TrustMode toggle that picks which trust-anchor policy the
// next query / warm runs under. Buttons are disabled only when no
// server is selected — operations are intentionally re-entrant, so
// the user can stack overlapping requests and watch them complete
// asynchronously in the log below. All outcome detail (sample
// fields, error variant, timing, trust backend) lands directly in
// the log, tagged by host so concurrent results stay
// distinguishable.

import 'package:flutter/material.dart';
import 'package:nts/nts.dart' show TrustMode;
import 'package:signals/signals_flutter.dart' show Watch;

import '../state/app_state.dart';
import '../state/nts_controller.dart';

class ActionPanel extends StatelessWidget {
  const ActionPanel({super.key, required this.state, required this.controller});

  final AppState state;
  final NtsController controller;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Watch((context) {
            final selected = state.selected.value;
            return Row(
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
            );
          }),
          const SizedBox(height: 12),
          _TrustModeToggle(state: state),
        ],
      ),
    );
  }
}

/// Segmented button that picks the [TrustMode] applied to subsequent
/// handshakes. Flipping the toggle prompts [NtsController] to mint a
/// fresh `NtsClient`, which drops the previous policy's cached
/// cookie pool — see the controller's `_onTrustModeChanged` for the
/// rationale.
class _TrustModeToggle extends StatelessWidget {
  const _TrustModeToggle({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Watch((context) {
      final mode = state.trustMode.value;
      return Row(
        children: [
          Text('Trust mode', style: theme.textTheme.labelMedium),
          const SizedBox(width: 12),
          Expanded(
            child: SegmentedButton<TrustMode>(
              showSelectedIcon: false,
              segments: const <ButtonSegment<TrustMode>>[
                ButtonSegment<TrustMode>(
                  value: TrustMode.platformWithFallback,
                  label: Text('Platform + fallback'),
                  icon: Icon(Icons.shield_outlined),
                ),
                ButtonSegment<TrustMode>(
                  value: TrustMode.platformOnly,
                  label: Text('Platform only'),
                  icon: Icon(Icons.lock_outline),
                ),
              ],
              selected: <TrustMode>{mode},
              onSelectionChanged: (selection) {
                state.trustMode.value = selection.first;
              },
            ),
          ),
        ],
      );
    });
  }
}

// Action strip rendered on the Client tab between `ServerListView`
// and the trust-status / latest-result panels: the three action
// buttons that drive the underlying [NtsController] plus a
// TrustMode dropdown that picks which trust-anchor policy the
// next action (query, warm, or get time) runs under — all three
// route through the same trust-mode-minted client. Buttons are
// disabled only when
// no server is selected — operations are intentionally re-entrant,
// so the user can stack overlapping requests and watch them
// complete asynchronously in the log on the sibling Log tab. All
// outcome detail (sample fields, error variant, timing, trust
// backend) lands directly in the log, tagged by host so concurrent
// results stay distinguishable; the most recent entry is also
// mirrored into the `LatestResultPanel` card below this strip so
// the user doesn't need to switch tabs for the common case.
//
// Layout uses [Wrap] so the buttons-plus-dropdown row collapses
// onto a single line on landscape tablets and wraps to two lines
// on phone-portrait widths, avoiding the prior fixed two-row layout
// that wasted ~70dp of vertical space on wide viewports.

import 'package:flutter/material.dart';
import 'package:nts/nts.dart' show TrustMode;
import 'package:signals/signals_flutter.dart' show SignalBuilder;

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
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SignalBuilder(
            builder: (context) {
              final selected = state.selected.value;
              return FilledButton.icon(
                onPressed: selected == null
                    ? null
                    : () => controller.runQuery(selected),
                icon: const Icon(Icons.bolt),
                label: const Text('NTS Query'),
              );
            },
          ),
          SignalBuilder(
            builder: (context) {
              final selected = state.selected.value;
              return FilledButton.tonalIcon(
                onPressed: selected == null
                    ? null
                    : () => controller.warmCookies(selected),
                icon: const Icon(Icons.cookie),
                label: const Text('Warm Cookies'),
              );
            },
          ),
          SignalBuilder(
            builder: (context) {
              final selected = state.selected.value;
              return FilledButton.tonalIcon(
                onPressed: selected == null
                    ? null
                    : () => controller.getTime(selected),
                icon: const Icon(Icons.schedule),
                label: const Text('Get Time'),
              );
            },
          ),
          _TrustModeDropdown(state: state),
        ],
      ),
    );
  }
}

/// Compact dropdown that picks the [TrustMode] applied to subsequent
/// handshakes. Flipping the selection prompts [NtsController] to
/// mint a fresh `NtsClient`, which drops the previous policy's
/// cached cookie pool — see the controller's `_onTrustModeChanged`
/// for the rationale.
///
/// Renders the current selection inline (no underline) so it sits
/// flush with the action buttons in the same [Wrap] row, mirroring
/// the styling of the Region dropdown in the filter bar above.
class _TrustModeDropdown extends StatelessWidget {
  const _TrustModeDropdown({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SignalBuilder(
      builder: (context) {
        final mode = state.trustMode.value;
        // `Semantics(label: 'Trust mode', container: true)` collapses
        // the icon + `DropdownButton` pair into a single accessibility
        // node and announces "Trust mode, <selected value>" on screen
        // readers, mirroring the labelling story the Region
        // `DropdownButtonFormField` gets for free via its `labelText`.
        // A sibling `Tooltip` on the icon gives sighted users the same
        // label on hover (desktop) / long-press (mobile).
        return Semantics(
          label: 'Trust mode',
          container: true,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Tooltip(
                message: 'Trust mode',
                child: Icon(
                  Icons.shield_outlined,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 6),
              DropdownButton<TrustMode>(
                value: mode,
                isDense: true,
                underline: const SizedBox.shrink(),
                onChanged: (v) {
                  if (v != null) state.trustMode.value = v;
                },
                items: const [
                  DropdownMenuItem<TrustMode>(
                    value: TrustMode.platformWithFallback,
                    child: Text('Platform + fallback'),
                  ),
                  DropdownMenuItem<TrustMode>(
                    value: TrustMode.platformOnly,
                    child: Text('Platform only'),
                  ),
                  DropdownMenuItem<TrustMode>(
                    value: TrustMode.bundledOnly,
                    child: Text('Bundled only'),
                  ),
                  DropdownMenuItem<TrustMode>(
                    value: TrustMode.custom,
                    child: Text('Custom roots'),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

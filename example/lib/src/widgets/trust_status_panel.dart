// Trust-anchor diagnostics panel. Sits above the live log and shows
// the per-instance handshake attribution: the trust backend the
// controller's `NtsClient` resolved to on its most-recent successful
// query / warm. Driven by [AppState.lastHandshakeBackend], which
// [NtsController] populates from `NtsTimeSample.trustBackend` /
// `NtsWarmCookiesOutcome.trustBackend` in-band on every success.
// Always populated after the first successful action button press,
// regardless of trust mode; reset to `null` on every TrustMode flip
// because the new client's session table has no recorded backend yet.
//
// Acts as a high-level summary of the most recent handshake row in
// the live log below: the same `TrustBackend` value the log entry's
// structured `trustBackend` field carries also lives here for
// at-a-glance reading.
//
// Earlier revisions of this panel also surfaced the process-wide
// `ntsTrustStatus()` singleton snapshot. That singleton is gated on
// the `is_default` flag of the underlying `NtsClient` (only the
// top-level `ntsQuery` / `ntsWarmCookies` routes through the default
// singleton). This example app always dispatches through a caller-
// minted client, so the singleton-scoped counters were structurally
// destined to remain at their sentinel `null` / 0 values during every
// demo run. They were removed to eliminate the cognitive disconnect
// between a successful in-log handshake and a "no handshake observed"
// singleton row.

import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart' show Watch;

import '../state/app_state.dart';
import '../state/nts_format.dart';

class TrustStatusPanel extends StatelessWidget {
  const TrustStatusPanel({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.verified_user_outlined, color: theme.colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Trust status', style: theme.textTheme.titleSmall),
                const SizedBox(height: 4),
                _LastHandshakeRow(state: state, theme: theme),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LastHandshakeRow extends StatelessWidget {
  const _LastHandshakeRow({required this.state, required this.theme});

  final AppState state;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Watch((context) {
      final backend = state.lastHandshakeBackend.value;
      final body = backend == null
          ? 'last-handshake-backend: (no per-client handshake yet)'
          : 'last-handshake-backend: ${formatTrustBackend(backend)}';
      return Text(
        body,
        style: theme.textTheme.bodySmall?.copyWith(
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      );
    });
  }
}

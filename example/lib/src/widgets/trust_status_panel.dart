// Trust-anchor diagnostics panel. Sits above the live log and shows
// two independent dimensions:
//
// 1. **Last handshake** — the trust backend the controller's
//    per-instance `NtsClient` resolved to on its most-recent
//    successful query / warm. Driven by [AppState.lastHandshakeBackend],
//    which [NtsController] populates from
//    `NtsTimeSample.trustBackend` / `NtsWarmCookiesOutcome.trustBackend`
//    in-band on every success. Always populated after the first
//    successful action button press, regardless of trust mode.
//
// 2. **Singleton snapshot** — the process-wide `ntsTrustStatus()`
//    output. Its `defaultClientBackend` only updates when the
//    *top-level* `ntsQuery` / `ntsWarmCookies` runs a handshake;
//    this example dispatches everything through a caller-minted
//    `NtsClient`, so this row stays at its `null` sentinel during
//    normal demo use. The remaining two fields
//    (`androidPlatformInitSucceeded`, `androidHybridFallbackCount`)
//    are real platform-level diagnostics and update normally.
//
// Splitting the two prevents the misleading sentinel that an
// earlier revision of this panel showed: telling the user to "run
// a query or tap refresh" when no amount of per-client handshakes
// would ever populate the singleton-scoped field.

import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart' show Watch;

import '../state/app_state.dart';
import '../state/nts_controller.dart';
import '../state/nts_format.dart';

class TrustStatusPanel extends StatelessWidget {
  const TrustStatusPanel({
    super.key,
    required this.state,
    required this.controller,
  });

  final AppState state;
  final NtsController controller;

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
                const SizedBox(height: 6),
                _SingletonSnapshotRow(state: state, theme: theme),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Refresh singleton snapshot',
            icon: const Icon(Icons.refresh),
            onPressed: controller.refreshTrustStatus,
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

class _SingletonSnapshotRow extends StatelessWidget {
  const _SingletonSnapshotRow({required this.state, required this.theme});

  final AppState state;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Watch((context) {
      final status = state.trustStatus.value;
      final body = status == null
          ? 'singleton snapshot: (tap refresh to load; '
                'defaultClientBackend will only populate after '
                'top-level ntsQuery / ntsWarmCookies runs)'
          : 'singleton snapshot:\n${formatTrustStatus(status)}';
      return Text(
        body,
        style: theme.textTheme.bodySmall?.copyWith(
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      );
    });
  }
}

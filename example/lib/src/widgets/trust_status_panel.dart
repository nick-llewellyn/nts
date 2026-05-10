// Compact panel rendering the most-recent `ntsTrustStatus()`
// snapshot. Sits above the live log so a user can see at a glance
// which trust backend the singleton client most recently resolved
// to and (on Android) whether the JNI bootstrap succeeded.
//
// The signal-driven panel updates whenever [NtsController.runQuery]
// or [NtsController.warmCookies] completes (both refresh the
// snapshot in-band) and on demand via the refresh button — the
// underlying counters are racy but per-counter monotonic, so the
// panel is fine to re-read on user action.

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
                Watch((context) {
                  final status = state.trustStatus.value;
                  final body = status == null
                      ? 'No snapshot yet — run a query or tap refresh.'
                      : formatTrustStatus(status);
                  return Text(
                    body,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  );
                }),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Refresh trust status',
            icon: const Icon(Icons.refresh),
            onPressed: controller.refreshTrustStatus,
          ),
        ],
      ),
    );
  }
}

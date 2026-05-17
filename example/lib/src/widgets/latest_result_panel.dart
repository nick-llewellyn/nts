// Single-entry summary card surfaced on the Client tab.
//
// Reads `state.log.entries.value.lastOrNull` through `Watch` and
// renders that one entry using the same span structure the full
// [LogView] uses on the Log tab — see [buildLogEntrySpans]. The
// goal is byte-for-byte rendering parity so the user can compare a
// summary line on the Client tab against its sibling row on the
// Log tab without noticing any difference in formatting.
//
// Bounded to four visible lines via [SelectableText.rich.maxLines]
// so a long success payload doesn't push the surrounding panels
// off-screen on shorter viewports; the user can flip to the Log tab
// for the full rendering.
//
// Empty-state copy reuses the verb from the action button so a new
// user is told exactly where to tap next.

import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart' show Watch;

import '../state/app_state.dart';
import '../theme/nts_colors.dart';
import 'log_view.dart' show buildLogEntrySpans;

class LatestResultPanel extends StatelessWidget {
  const LatestResultPanel({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = NtsColors.of(context);
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.history,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text('Latest result', style: theme.textTheme.titleSmall),
              ],
            ),
            const SizedBox(height: 8),
            Watch((context) {
              final latest = state.log.entries.value.lastOrNull;
              if (latest == null) {
                return Text(
                  'No queries yet — tap NTS Query to populate.',
                  style: theme.textTheme.bodySmall,
                );
              }
              return SelectableText.rich(
                TextSpan(
                  children: buildLogEntrySpans(theme, colors, latest),
                ),
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  height: 1.35,
                ),
                maxLines: 4,
              );
            }),
          ],
        ),
      ),
    );
  }
}

// Strict-clock diagnostics panel, shown below the trust-status panel
// when the clock mode is strict or compare. Renders the
// [AppState.strictClock] snapshot [NtsController] publishes after
// every strict action — provenance, native source, descriptor
// versions, generation and whether the context still accepts reads —
// plus the three context actions: Re-resolve (the only recovery after
// an invalidation), Invalidate (to exercise the fail-closed path on
// demand) and Export reference (same-boot transfer, which this
// release always refuses).
//
// In legacy mode the panel renders a zero-size [SizedBox], like
// `CustomRootsPanel`, so the legacy layout is unchanged.

import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart' show SignalBuilder;

import '../state/app_state.dart';
import '../state/nts_controller.dart';
import '../state/nts_format.dart';

class StrictClockPanel extends StatelessWidget {
  const StrictClockPanel({
    super.key,
    required this.state,
    required this.controller,
  });

  final AppState state;
  final NtsController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SignalBuilder(
      builder: (context) {
        if (state.clockMode.value == ClockMode.legacy) {
          return const SizedBox.shrink();
        }
        final snapshot = state.strictClock.value;
        final bound = snapshot is StrictClockBound ? snapshot : null;
        final usable = bound != null && bound.invalidation == null;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.timer_outlined, color: theme.colorScheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Strict clock', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 4),
                    Text(
                      describeStrictClockSnapshot(snapshot),
                      key: const Key('strict_clock_status'),
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 8,
                      children: [
                        TextButton.icon(
                          key: const Key('strict_clock_resolve_button'),
                          onPressed: controller.resolveStrictClock,
                          icon: const Icon(Icons.refresh, size: 16),
                          label: const Text('Re-resolve'),
                        ),
                        TextButton.icon(
                          key: const Key('strict_clock_invalidate_button'),
                          onPressed: usable
                              ? controller.invalidateStrictClock
                              : null,
                          icon: const Icon(Icons.block, size: 16),
                          label: const Text('Invalidate'),
                        ),
                        TextButton.icon(
                          key: const Key('strict_clock_export_button'),
                          onPressed: usable && bound.hasSyncedTime
                              ? controller.exportSameBootReference
                              : null,
                          icon: const Icon(Icons.ios_share, size: 16),
                          label: const Text('Export reference'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// One-line status for a [StrictClockSnapshot], or for `null` before
/// the first resolution attempt.
String describeStrictClockSnapshot(StrictClockSnapshot? snapshot) =>
    switch (snapshot) {
      null => 'context: (not resolved yet; Get Time or Re-resolve binds one)',
      StrictClockUnavailable(:final error) =>
        'context: unavailable \u2014 ${error.message}',
      StrictClockBound(:final invalidation?) =>
        'context: ${_clock(snapshot)} \u2014 invalidated '
            '(${invalidation.name}); reads fail closed until Re-resolve',
      StrictClockBound() =>
        'context: ${_clock(snapshot)} \u2014 valid as of the last call',
    };

String _clock(StrictClockBound bound) => formatStrictClock(
  provenance: bound.provenance,
  descriptor: bound.descriptor,
  generation: bound.generation,
);

// On-screen rendering of the live `NtsLogBuffer`.
//
// Behaviour:
//   * Auto-scrolls to the newest entry on every append, but only if
//     the user hasn't manually scrolled away from the bottom — that
//     way they can pause and read without the view yanking them
//     forward. The scroll is driven by a signals `effect()` so the
//     listener fires exactly when `entries.value` changes rather than
//     piggy-backing on widget builds.
//   * Renders the buffer as one long monospaced `SelectableText` so
//     the user can select arbitrary substrings (e.g. a single error
//     line) and copy with the standard system gesture, satisfying the
//     "highlight and copy specific log entries" requirement.
//   * Provides a share-sheet handoff via `share_plus`, exporting the
//     buffer as plain text. The system sheet routes to Mail / Drive /
//     AirDrop / Files / etc. without any further plumbing.

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:signals/signals.dart' show effect;
import 'package:signals/signals_flutter.dart' show Watch;

import '../state/app_state.dart';
import '../state/log_entry.dart';
import '../theme/nts_colors.dart';

class LogView extends StatefulWidget {
  const LogView({super.key, required this.state});

  final AppState state;

  @override
  State<LogView> createState() => _LogViewState();
}

class _LogViewState extends State<LogView> {
  final ScrollController _scroll = ScrollController();

  /// Cleanup function returned by `signals.effect()`. Disposed in
  /// [dispose] so the listener does not outlive the widget when the
  /// home page is rebuilt (e.g. on hot reload or theme switch).
  void Function()? _disposeAutoScroll;

  /// "Stickiness" tolerance, in pixels: any scroll position closer to
  /// `maxScrollExtent` than this counts as "at the bottom" and will
  /// follow new entries. Anything further up is treated as a user
  /// reading older history and is left alone.
  static const double _stickyThresholdPx = 32;

  @override
  void initState() {
    super.initState();
    // Register a signals `effect` so we re-evaluate exactly when the
    // log buffer mutates, instead of running side-effects from the
    // `Watch` builder. Reading `entries.value` once is enough to bind
    // the dependency; we don't actually need the snapshot here.
    _disposeAutoScroll = effect(() {
      // ignore: unused_local_variable
      final _ = widget.state.log.entries.value;
      _scheduleAutoScroll();
    });
  }

  @override
  void dispose() {
    _disposeAutoScroll?.call();
    _scroll.dispose();
    super.dispose();
  }

  /// Scroll the viewport to the newest entry on the next frame, but
  /// only when the user is already pinned within [_stickyThresholdPx]
  /// of the bottom — readers who scrolled up to inspect an older line
  /// are deliberately *not* yanked forward.
  void _scheduleAutoScroll() {
    // Run after the next frame so the underlying viewport has had a
    // chance to remeasure with the appended entry.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final pos = _scroll.position;
      final atBottom = pos.pixels >= pos.maxScrollExtent - _stickyThresholdPx;
      if (!atBottom) return;
      // animateTo is preferred here so a burst of appends (e.g. a
      // probe-all run) reads as a smooth follow rather than a series
      // of teleports. The 120 ms ease-out lands well below the next
      // frame budget on a 60Hz display while still being perceptible.
      _scroll.animateTo(
        pos.maxScrollExtent,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = NtsColors.of(context);
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _LogHeader(state: widget.state),
          const Divider(height: 1),
          Expanded(
            child: Watch((context) {
              final entries = widget.state.log.entries.value;
              if (entries.isEmpty) {
                return Center(
                  child: Text(
                    'Log is empty — run an NTS query to populate it.',
                    style: theme.textTheme.bodySmall,
                  ),
                );
              }
              return Scrollbar(
                controller: _scroll,
                child: SingleChildScrollView(
                  controller: _scroll,
                  padding: const EdgeInsets.all(12),
                  child: SelectableText.rich(
                    TextSpan(
                      children: [
                        for (final e in entries) ..._spansFor(theme, colors, e),
                      ],
                    ),
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                      height: 1.35,
                    ),
                  ),
                ),
              );
            }),
          ),
        ],
      ),
    );
  }

  /// Render one log entry as a sequence of styled spans so the
  /// metadata (timestamp, level, source, host) can dim into the
  /// background while the actual message stays at full strength.
  /// `SelectableText.rich` walks the span tree to assemble the copied
  /// payload, so this still yields a clean grep-friendly line when the
  /// user drags a selection across it.
  ///
  /// Colour assignment funnels through [NtsColors]:
  /// - `info` lines whose message starts with `OK ` (the success
  ///   marker emitted by `nts_format::formatQuerySuccess` /
  ///   `formatWarmSuccess`) render in `ntsSuccess` so a successful
  ///   handshake reads at a glance against neutral status lines.
  /// - other `info` lines render in the default `onSurface` tone.
  /// - `warn` and `error` map to `ntsWarning` and `ntsError`.
  static List<InlineSpan> _spansFor(
    ThemeData theme,
    NtsColors colors,
    NtsLogEntry e,
  ) {
    final messageColour = switch (e.level) {
      NtsLogLevel.info =>
        e.message.startsWith('OK ')
            ? colors.ntsSuccess
            : theme.colorScheme.onSurface,
      NtsLogLevel.warn => colors.ntsWarning,
      NtsLogLevel.error => colors.ntsError,
    };
    final dimColour = colors.logTimestamp;
    final ts = e.timestamp.toIso8601String();
    final lvl = e.level.name.toUpperCase().padRight(5);
    final hostPart = e.host == null ? '' : ' [${e.host}]';
    return [
      TextSpan(
        text: '$ts ',
        style: TextStyle(color: dimColour),
      ),
      TextSpan(
        text: '$lvl ',
        style: TextStyle(color: messageColour, fontWeight: FontWeight.w600),
      ),
      TextSpan(
        text: '${e.source}$hostPart  ',
        style: TextStyle(color: dimColour),
      ),
      TextSpan(
        text: '${e.message}\n',
        style: TextStyle(color: messageColour),
      ),
    ];
  }
}

class _LogHeader extends StatelessWidget {
  const _LogHeader({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      child: Row(
        children: [
          Icon(Icons.terminal, size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Text('Live log', style: theme.textTheme.titleSmall),
          const Spacer(),
          Watch((context) {
            final empty = state.log.entries.value.isEmpty;
            return Row(
              children: [
                IconButton(
                  tooltip: 'Share log',
                  icon: const Icon(Icons.share),
                  onPressed: empty ? null : () => _shareLog(context, state),
                ),
                IconButton(
                  tooltip: 'Clear log',
                  icon: const Icon(Icons.delete_sweep),
                  onPressed: empty ? null : state.log.clear,
                ),
              ],
            );
          }),
        ],
      ),
    );
  }

  static Future<void> _shareLog(BuildContext context, AppState state) async {
    final text = state.log.exportAsText();
    if (text.isEmpty) return;
    final params = ShareParams(
      text: text,
      subject: 'nts log (${state.bridgeMode})',
    );
    await SharePlus.instance.share(params);
  }
}

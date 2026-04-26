// Bounded ring buffer of [NtsLogEntry] exposed as a signal.
//
// The catalog has 86 servers and the user can drive arbitrarily many
// `ntsQuery` invocations per session. We cap the on-screen log at
// [_kMaxEntries] so a long debugging session can't run the device out
// of memory or freeze the UI re-rendering a six-figure list. Older
// entries roll off the front silently — they were already shareable
// at the time they scrolled past, so the trade-off favours staying
// responsive over keeping a complete forever-history.
//
// Storage is an immutable list assigned to `entries.value` rather
// than an in-place mutation. That makes signal-driven UI updates
// trivially correct: every observer sees a consistent snapshot, and
// `Watch` rebuilds fire exactly when the list reference changes
// rather than relying on listeners noticing in-place edits.

import 'package:signals/signals.dart' show Signal, signal;

import 'log_entry.dart';

const int _kMaxEntries = 500;

/// Tiny facade around a `Signal<List<NtsLogEntry>>` that owns the
/// ring-buffer policy and the convenience helpers the home page wires
/// to its action buttons.
class NtsLogBuffer {
  /// Live view of the buffer, oldest entry first. The list reference
  /// changes on every append so signal observers fire even if the
  /// length stays at the cap.
  final Signal<List<NtsLogEntry>> entries = signal<List<NtsLogEntry>>(const []);

  /// Append a single line. The append is the single mutation point —
  /// the typed helpers below all funnel through it.
  void append(NtsLogEntry entry) {
    final next = [...entries.value, entry];
    if (next.length > _kMaxEntries) {
      next.removeRange(0, next.length - _kMaxEntries);
    }
    entries.value = next;
  }

  /// Convenience helper for an info-level row.
  void info(String source, String message, {String? host}) {
    append(
      NtsLogEntry(
        timestamp: DateTime.now().toUtc(),
        level: NtsLogLevel.info,
        source: source,
        message: message,
        host: host,
      ),
    );
  }

  /// Convenience helper for a warn-level row.
  void warn(String source, String message, {String? host}) {
    append(
      NtsLogEntry(
        timestamp: DateTime.now().toUtc(),
        level: NtsLogLevel.warn,
        source: source,
        message: message,
        host: host,
      ),
    );
  }

  /// Convenience helper for an error-level row.
  void error(String source, String message, {String? host}) {
    append(
      NtsLogEntry(
        timestamp: DateTime.now().toUtc(),
        level: NtsLogLevel.error,
        source: source,
        message: message,
        host: host,
      ),
    );
  }

  /// Drop every queued entry. Wired to the "Clear" button.
  void clear() => entries.value = const [];

  /// Concatenate the current buffer in chronological order, one entry
  /// per line, suitable for piping into the system share sheet.
  String exportAsText() =>
      entries.value.map((e) => e.formatForExport()).join('\n');
}

// Single line of UI-side instrumentation rendered into the live log.
//
// The Dart side cannot intercept the `tracing::*!` / `log::*!` events
// that the Rust crate emits — those are routed straight into platform
// loggers (Android logcat / iOS unified logging) by the in-crate
// subscriber set up in `crate::ios_init`. So everything in the on-
// screen log is composed in Dart from observable side-effects: the
// invocation start, the `NtsTimeSample` we got back, or the
// `NtsError` variant we caught. That keeps the on-device experience
// useful even when the Rust-side `verbose_logs` toggle is off and the
// underlying binary has been stripped down to `warn!`/`error!`.

import 'package:nts/nts.dart' show TrustBackend, TrustMode;

/// Severity tier for a log line. Mirrors the levels the underlying
/// Rust crate would emit; used by the UI to colour-code entries and
/// by the share export to label rows.
enum NtsLogLevel { info, warn, error }

/// One row in the on-screen log buffer.
class NtsLogEntry {
  NtsLogEntry({
    required this.timestamp,
    required this.level,
    required this.source,
    required this.message,
    this.host,
    this.trustBackend,
    this.trustMode,
  });

  /// Wall-clock UTC at the moment the entry was appended. Stored
  /// rather than computed at render time so the buffer stays a
  /// faithful timeline even if the device clock changes (which is the
  /// whole point of an NTS client to begin with).
  final DateTime timestamp;

  /// Severity tier; influences foreground colour and share-export
  /// prefix.
  final NtsLogLevel level;

  /// Free-form short tag identifying the producer of the log line —
  /// e.g. `nts_query`, `nts_warm_cookies`, `system`, `catalog`.
  final String source;

  /// Optional NTS-KE host the entry pertains to. Surfaced inline by
  /// the UI so a user scanning the log can pair errors with servers
  /// without re-reading the message text.
  final String? host;

  /// Human-readable description. Should be self-contained: the share
  /// export drops timestamps and levels but always keeps the message
  /// verbatim.
  final String message;

  /// Per-handshake trust-anchor backend that authenticated the chain
  /// for the action this entry describes. Populated by
  /// [NtsController] from `NtsTimeSample.trustBackend` /
  /// `NtsWarmCookiesOutcome.trustBackend` on success entries, and
  /// from `NtsError.trustBackend` on error / warning entries whose
  /// failure fired *after* `build_tls_config` resolved a backend
  /// (so an `NtsError.keProtocol` raised by a server-side post-
  /// handshake conformance bug can still be attributed to the
  /// hybrid-fallback path that authenticated its TLS leg). `null`
  /// for entries that don't describe a completed handshake (system
  /// lines, "Starting query") and for failures that pre-dated
  /// backend resolution (DNS-saturation / DNS-timeout / connect /
  /// pre-TLS errors). Carried as a structured field rather than
  /// embedded purely in the message text so log scrapers and the
  /// share export can attribute backend-by-host without re-parsing
  /// free-form prose.
  final TrustBackend? trustBackend;

  /// Trust-mode configuration this entry was logged under. Currently
  /// emitted only by the `system` source on TrustMode-toggle
  /// transitions; `null` everywhere else. Carried for the same
  /// reason as [trustBackend]: machine-readable attribution.
  final TrustMode? trustMode;

  /// Single-line textual form used by the share-sheet export. Format
  /// is intentionally `grep`-friendly so the recipient (typically a
  /// support engineer) can pipe the pasted log through standard text
  /// tools. Optional structured fields (`host`, `trustBackend`,
  /// `trustMode`) appear in fixed positions between the source tag
  /// and the message body so a regex / awk pipeline can split the
  /// columns deterministically.
  String formatForExport() {
    final ts = timestamp.toIso8601String();
    final lvl = level.name.toUpperCase().padRight(5);
    final hostPart = host == null ? '' : ' [host=$host]';
    final backendPart = trustBackend == null
        ? ''
        : ' [backend=${trustBackend!.name}]';
    final modePart = trustMode == null ? '' : ' [mode=${trustMode!.name}]';
    return '$ts $lvl $source$hostPart$backendPart$modePart  $message';
  }
}

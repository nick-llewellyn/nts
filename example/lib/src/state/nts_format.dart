// Pure formatting helpers shared between the on-screen log
// (`NtsController`) and the standalone CLI (`bin/nts_cli.dart`).
//
// Kept presentation-only and dependency-free so both surfaces can
// serialise an `NtsTimeSample` / `NtsError` into the same canonical
// string shapes — the multi-line `OK …` headline, the AEAD label, the
// human-readable error description — without re-implementing them per
// caller. The `json…` helpers carry the same data in `Map`-shaped form
// for `--json` (NDJSON) CLI output and any other machine-readable
// consumer.

import 'package:nts/nts.dart'
    show
        NtsError,
        NtsErrorAuthentication,
        NtsErrorInternal,
        NtsErrorInvalidSpec,
        NtsErrorKeProtocol,
        NtsErrorNetwork,
        NtsErrorNoCookies,
        NtsErrorNtpProtocol,
        NtsErrorTimeout,
        NtsErrorTrustBackendUnavailable,
        NtsTimeSample,
        NtsWarmCookiesOutcome,
        TrustBackend,
        TrustMode;

/// IANA AEAD identifier → human label used in success log lines.
String aeadLabel(int id) => switch (id) {
  15 => 'AES-SIV-CMAC-256(15)',
  30 => 'AES-128-GCM-SIV(30)',
  _ => 'unknown($id)',
};

/// Round-trip time as a human-friendly string with auto-selected
/// units. The width is bounded (≤ 8 chars) so callers can right-pad
/// for column alignment in monospaced renderings.
String formatRtt(int micros) {
  if (micros < 1000) return '$micros\u00b5s';
  if (micros < 1000000) return '${(micros / 1000).toStringAsFixed(2)}ms';
  return '${(micros / 1000000).toStringAsFixed(2)}s';
}

/// Trust-anchor backend label used in success log lines and the
/// trust-status panel. Mirrors the [TrustBackend] enum names but
/// substitutes a short human form so a reader scanning the log can
/// spot a fallback path without consulting the dartdoc. Labels are
/// short and self-describing rather than constrained to a fixed
/// character bound; the SelectableText surface that renders the
/// success line wraps gracefully when the continuation row would
/// otherwise overflow.
String formatTrustBackend(TrustBackend backend) => switch (backend) {
  TrustBackend.platform => 'platform',
  // `webpki-fallback` (not `platform+hybrid-fallback`) because this
  // variant means the platform verifier *rejected* the chain and the
  // webpki-roots bundle overrode that verdict for one of the curated
  // fallback-eligible shapes (missing-OCSP-AIA chains, R8-stripped
  // AAR classes). The prior label read like "platform plus a
  // possible hybrid fallback" without saying which actually
  // authenticated. Single-token form is safe for awk/grep on the
  // CLI output that bin/nts_cli.dart produces via the same
  // formatQuerySuccess / formatWarmSuccess helpers.
  TrustBackend.platformWithHybridFallback => 'webpki-fallback',
  TrustBackend.webpkiRoots => 'webpki-roots',
  TrustBackend.custom => 'custom',
};

/// Human label for a [TrustMode] used in the toggle, status panel,
/// and any log line that needs to attribute a query to a specific
/// build-time fallback policy.
String formatTrustMode(TrustMode mode) => switch (mode) {
  TrustMode.platformWithFallback => 'platform-with-fallback',
  TrustMode.platformOnly => 'platform-only',
  TrustMode.bundledOnly => 'bundled-only',
  TrustMode.custom => 'custom',
};

/// Two-line success rendering of an `ntsQuery` result.
///
/// Headline carries the metrics a user actually scans for (RTT,
/// stratum, server time); the indented continuation carries the
/// crypto/cookie/trust metadata that matters when something is wrong
/// but is noise during normal operation. The leading `OK ` marker is
/// preserved on the headline so the share-export and any external
/// `grep` tooling can still spot success lines on a single-line scan.
String formatQuerySuccess(NtsTimeSample sample) {
  final utc = DateTime.fromMicrosecondsSinceEpoch(
    sample.utcUnixMicros,
    isUtc: true,
  );
  final rtt = formatRtt(sample.roundTripMicros).padLeft(8);
  return 'OK  rtt=$rtt  stratum=${sample.serverStratum}  '
      'utc=${utc.toIso8601String()}\n'
      '    \u2514\u2500 aead=${aeadLabel(sample.aeadId)}  '
      'cookies=${sample.freshCookies}  '
      'trust=${formatTrustBackend(sample.trustBackend)}';
}

/// Single-line success rendering of an `ntsWarmCookies` result.
/// Carries the trust backend so a warm-only diagnostic flow surfaces
/// the same backend attribution as a full query.
String formatWarmSuccess(NtsWarmCookiesOutcome outcome) =>
    'OK  recovered ${outcome.freshCookies} fresh cookie(s)  '
    'trust=${formatTrustBackend(outcome.trustBackend)}';

/// Severity classification for an [NtsError]. Network / timeout / spec
/// errors are routine when probing arbitrary hosts and warrant warn;
/// authentication, KE-/NTP-protocol, internal, and trust-backend
/// errors are genuinely interesting and stay at error. The trust-backend
/// case is a deliberate caller-side configuration choice (`PlatformOnly`)
/// the runtime cannot honour; loud surfacing is appropriate so an
/// operator notices the misconfiguration rather than treating it as a
/// transient network blip.
bool isErrorSeverity(NtsError err) =>
    err is NtsErrorAuthentication ||
    err is NtsErrorKeProtocol ||
    err is NtsErrorNtpProtocol ||
    err is NtsErrorTrustBackendUnavailable ||
    err is NtsErrorInternal;

/// Human-readable rendering of an [NtsError] suitable for the live log
/// or stderr.
///
/// Cross-variant routing notes that affect how a reader instrumenting
/// against this surface should interpret the strings:
///
/// - **AEAD-algorithm negotiation failures arrive as [NtsErrorKeProtocol],
///   not [NtsErrorAuthentication]**. The AEAD-id round-trip happens
///   inside the NTS-KE record exchange (RFC 8915 §4.1.5) before any
///   authenticated NTPv4 packet is constructed; a server that picks an
///   AEAD identifier this client does not implement is a *negotiation*
///   failure, surfaced via `KeError::UnsupportedAead` in
///   `rust/src/nts/ke.rs::validate_response` and routed to
///   `KeProtocol` by the catch-all arm of the
///   `From<KeError> for NtsError` impl in `rust/src/api/nts.rs`
///   (the defence-in-depth `AeadError::UnsupportedAlgorithm` path
///   lands at the same `KeProtocol` variant via the explicit arm of
///   the `From<AeadError> for NtsError` impl in the same file).
///   [NtsErrorAuthentication] is reserved for
///   cryptographic-verification failures on a fully negotiated AEAD
///   (tag mismatch, malformed AEAD input). A monitoring rule wired
///   to "tag mismatch" alarms must therefore key on
///   [NtsErrorAuthentication] only, not [NtsErrorKeProtocol].
/// - **NTP Kiss-of-Death (KoD) and unsynchronized-server states tunnel
///   through [NtsErrorNtpProtocol]**. The 4-octet KoD reference id
///   (`RATE`, `DENY`, `RSTR`, `NTSN`, …) and the unsynchronised-leap
///   flag are preserved verbatim in `field0`; callers that want to
///   distinguish "server told me to back off" from "server's clock is
///   not yet steered" can substring-match the message rather than
///   needing a dedicated error variant. The CLI / GUI surfaces here
///   render the message verbatim under the `NtpProtocol:` prefix so a
///   reader sees the raw KoD text for free.
String describeError(NtsError err) => switch (err) {
  NtsErrorInvalidSpec(:final message) => 'InvalidSpec: $message',
  NtsErrorNetwork(:final message) => 'Network: $message',
  NtsErrorKeProtocol(:final message) => 'KeProtocol: $message',
  NtsErrorNtpProtocol(:final message) => 'NtpProtocol: $message',
  NtsErrorAuthentication(:final message) => 'Authentication: $message',
  NtsErrorTimeout(:final phase) =>
    'Timeout (deadline expired in phase ${phase.name})',
  NtsErrorNoCookies() =>
    'NoCookies (server completed KE but issued zero cookies)',
  NtsErrorTrustBackendUnavailable(:final message) =>
    'TrustBackendUnavailable: $message',
  NtsErrorInternal(:final message) => 'Internal: $message',
};

/// Stable variant tag for an [NtsError], used as the `error_type`
/// field in machine-readable output. Mirrors the Rust enum names so
/// downstream consumers can switch on a single short string.
String errorTypeName(NtsError err) => switch (err) {
  NtsErrorInvalidSpec() => 'InvalidSpec',
  NtsErrorNetwork() => 'Network',
  NtsErrorKeProtocol() => 'KeProtocol',
  NtsErrorNtpProtocol() => 'NtpProtocol',
  NtsErrorAuthentication() => 'Authentication',
  NtsErrorTimeout() => 'Timeout',
  NtsErrorNoCookies() => 'NoCookies',
  NtsErrorTrustBackendUnavailable() => 'TrustBackendUnavailable',
  NtsErrorInternal() => 'Internal',
};

/// JSON-shaped success payload for an `ntsQuery` result. Carries
/// the raw numeric fields the GUI / log already display, plus the
/// human AEAD label so consumers don't need to reimplement
/// [aeadLabel] and the trust-backend variant tag so monitoring
/// pipelines can distinguish a platform-store handshake from a
/// hybrid-fallback or webpki-roots one without re-parsing the human
/// message.
Map<String, Object?> jsonQuerySuccess(NtsTimeSample sample) => {
  'utc_unix_micros': sample.utcUnixMicros,
  'utc': DateTime.fromMicrosecondsSinceEpoch(
    sample.utcUnixMicros,
    isUtc: true,
  ).toIso8601String(),
  'rtt_micros': sample.roundTripMicros,
  'stratum': sample.serverStratum,
  'aead_id': sample.aeadId,
  'aead_label': aeadLabel(sample.aeadId),
  'cookies': sample.freshCookies,
  'trust_backend': sample.trustBackend.name,
};

/// JSON-shaped success payload for an `ntsWarmCookies` result.
/// Mirrors the per-handshake trust-backend attribution carried by
/// [jsonQuerySuccess] so a warm-only diagnostic flow stays
/// machine-readable without a separate code path.
Map<String, Object?> jsonWarmSuccess(NtsWarmCookiesOutcome outcome) => {
  'cookies': outcome.freshCookies,
  'trust_backend': outcome.trustBackend.name,
};

/// JSON-shaped failure payload for an [NtsError]. Pairs the variant
/// tag with the same human-readable description used in text output
/// and the warn/error severity classification.
///
/// `Timeout` failures additionally carry a structured `phase` field
/// holding the [TimeoutPhase] variant name (`dnsSaturation`,
/// `dnsTimeout`, `connect`, `tls`, `keRecordIo`, `ntp`) so
/// machine-readable consumers can switch on the attribution without
/// re-parsing the human message — the whole point of carrying the
/// phase tag through the API surface in the first place.
Map<String, Object?> jsonError(NtsError err) => {
  'error_type': errorTypeName(err),
  'message': describeError(err),
  'severity': isErrorSeverity(err) ? 'error' : 'warn',
  if (err is NtsErrorTimeout) 'phase': err.phase.name,
};

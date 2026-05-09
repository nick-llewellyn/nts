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
        NtsTimeSample;

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

/// Two-line success rendering of an `ntsQuery` result.
///
/// Headline carries the metrics a user actually scans for (RTT,
/// stratum, server time); the indented continuation carries the
/// crypto/cookie metadata that matters when something is wrong but
/// is noise during normal operation. The leading `OK ` marker is
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
      'cookies=${sample.freshCookies}';
}

/// Single-line success rendering of an `ntsWarmCookies` result.
String formatWarmSuccess(int cookies) =>
    'OK  recovered $cookies fresh cookie(s)';

/// Severity classification for an [NtsError]. Network / timeout / spec
/// errors are routine when probing arbitrary hosts and warrant warn;
/// authentication and KE-/NTP-protocol errors are genuinely interesting
/// and stay at error.
bool isErrorSeverity(NtsError err) =>
    err is NtsErrorAuthentication ||
    err is NtsErrorKeProtocol ||
    err is NtsErrorNtpProtocol ||
    err is NtsErrorInternal;

/// Human-readable rendering of an [NtsError] suitable for the live log
/// or stderr.
String describeError(NtsError err) => switch (err) {
  NtsErrorInvalidSpec(:final field0) => 'InvalidSpec: $field0',
  NtsErrorNetwork(:final field0) => 'Network: $field0',
  NtsErrorKeProtocol(:final field0) => 'KeProtocol: $field0',
  NtsErrorNtpProtocol(:final field0) => 'NtpProtocol: $field0',
  NtsErrorAuthentication(:final field0) => 'Authentication: $field0',
  NtsErrorTimeout(:final field0) =>
    'Timeout (deadline expired in phase ${field0.name})',
  NtsErrorNoCookies() =>
    'NoCookies (server completed KE but issued zero cookies)',
  NtsErrorInternal(:final field0) => 'Internal: $field0',
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
  NtsErrorInternal() => 'Internal',
};

/// JSON-shaped success payload for an `ntsQuery` result. Carries the
/// raw numeric fields the GUI / log already display, plus the human
/// AEAD label so consumers don't need to reimplement [aeadLabel].
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
};

/// JSON-shaped success payload for an `ntsWarmCookies` result.
Map<String, Object?> jsonWarmSuccess(int cookies) => {'cookies': cookies};

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
  if (err is NtsErrorTimeout) 'phase': err.field0.name,
};

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
        NtsDnsPoolStats,
        NtsError,
        NtsErrorAbiMismatch,
        NtsErrorAuthentication,
        NtsErrorInternal,
        NtsErrorInvalidSpec,
        NtsErrorKeProtocol,
        NtsErrorNetwork,
        NtsErrorNoCookies,
        NtsErrorNtpProtocol,
        NtsErrorTimeout,
        NtsErrorTrustBackendUnavailable,
        NtsSyncedTime,
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

/// Accepted `--trust-mode` values, in [TrustMode] declaration order.
///
/// Doubles as the `allowed:` set for the CLI option, so the parser
/// rejects an unknown value with usage text before [parseTrustMode]
/// ever runs.
const List<String> kTrustModeFlagValues = [
  'platform-with-fallback',
  'platform-only',
  'bundled-only',
  'custom',
];

/// Accepted `--require-trust-backend` values, in [TrustBackend]
/// declaration order.
///
/// These are the kebab-cased *enum* names, deliberately not
/// [formatTrustBackend]'s output: that helper renders
/// [TrustBackend.platformWithHybridFallback] as the display label
/// `webpki-fallback`, which reads well in a log line but is a poor
/// flag value because it does not name the mode that produced it.
const List<String> kTrustBackendFlagValues = [
  'platform',
  'platform-with-hybrid-fallback',
  'webpki-roots',
  'custom',
];

/// Inverse of [formatTrustMode]; `null` for an unrecognised value.
TrustMode? parseTrustMode(String value) => switch (value) {
  'platform-with-fallback' => TrustMode.platformWithFallback,
  'platform-only' => TrustMode.platformOnly,
  'bundled-only' => TrustMode.bundledOnly,
  'custom' => TrustMode.custom,
  _ => null,
};

/// Maps a [kTrustBackendFlagValues] entry onto its [TrustBackend];
/// `null` for an unrecognised value.
TrustBackend? parseTrustBackend(String value) => switch (value) {
  'platform' => TrustBackend.platform,
  'platform-with-hybrid-fallback' => TrustBackend.platformWithHybridFallback,
  'webpki-roots' => TrustBackend.webpkiRoots,
  'custom' => TrustBackend.custom,
  _ => null,
};

/// Diagnostic for a `--trust-mode` / `--custom-roots` combination the
/// `NtsClient` constructor would reject, or `null` when the pair
/// describes a constructible policy.
///
/// Mirrors the package's own pair validation in pure Dart so a CLI can
/// fail an invalid invocation as a usage error before loading the
/// bridge — the constructor runs the same check, but only after
/// `initBridge`, which would report a missing dylib first and mask the
/// argument mistake behind a bridge-load exit code.
String? trustPolicyPairingError({
  required TrustMode trustMode,
  required List<int>? customRoots,
}) {
  if (customRoots != null && trustMode != TrustMode.custom) {
    return '--custom-roots can only be set when --trust-mode is custom';
  }
  if (trustMode == TrustMode.custom &&
      (customRoots == null || customRoots.isEmpty)) {
    return '--trust-mode custom requires a non-empty --custom-roots';
  }
  return null;
}

/// Human rendering of a `--require-trust-backend` assertion failure:
/// the handshake succeeded, but negotiated a backend other than the
/// one the run demanded.
///
/// Both backends render through [formatTrustBackend] so the line reads
/// in the same vocabulary as the `trust=` segment on the success lines
/// it replaces. The machine-readable counterpart
/// ([jsonTrustMismatch]) carries the raw enum names instead.
String formatTrustMismatch(
  TrustBackend requiredBackend,
  TrustBackend actualBackend,
) =>
    'FAIL  trust backend mismatch: '
    'required=${formatTrustBackend(requiredBackend)}  '
    'actual=${formatTrustBackend(actualBackend)}';

/// JSON-shaped payload for a `--require-trust-backend` assertion
/// failure.
///
/// `error_type` shares the namespace with [errorTypeName]'s ten
/// [NtsError] tags so a consumer switching on the field can tell a
/// policy-assertion failure from a protocol error without a second
/// branch. `trust_backend` reuses the key [jsonQuerySuccess] /
/// [jsonWarmSuccess] already use for the negotiated backend.
Map<String, Object?> jsonTrustMismatch(
  TrustBackend requiredBackend,
  TrustBackend actualBackend,
) => {
  'error_type': 'TrustBackendMismatch',
  'message': formatTrustMismatch(requiredBackend, actualBackend),
  'severity': 'error',
  'required_trust_backend': requiredBackend.name,
  'trust_backend': actualBackend.name,
};

/// Trailing `ke-warnings=[…]` segment for a non-empty list of NTS-KE
/// warning codes, or the empty string when there are none.
///
/// Carries its own two-space separator prefix, matching the column
/// spacing the surrounding renderings use, so callers concatenate it
/// directly rather than joining.
///
/// The IANA NTS-KE warning registry has no assignments as of RFC 8915,
/// so every server observed in practice sends zero codes. Rendering
/// `ke-warnings=[]` on every success line would be pure noise, hence
/// the segment is omitted entirely rather than shown empty — the
/// inverse of the JSON payloads, which carry the key unconditionally
/// so machine consumers get a stable schema.
String keWarningsSegment(List<int> codes) =>
    codes.isEmpty ? '' : '  ke-warnings=[${codes.join(',')}]';

/// Two-line success rendering of an `ntsQuery` result.
///
/// Headline carries the metrics a user actually scans for (RTT,
/// stratum, server time); the indented continuation carries the
/// crypto/cookie/trust metadata that matters when something is wrong
/// but is noise during normal operation. The leading `OK ` marker is
/// preserved on the headline so the share-export and any external
/// `grep` tooling can still spot success lines on a single-line scan.
///
/// Any NTS-KE warning codes the handshake carried are appended to the
/// continuation via [keWarningsSegment], which stays silent in the
/// (universal, today) empty case.
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
      'trust=${formatTrustBackend(sample.trustBackend)}'
      '${keWarningsSegment(sample.keWarnings)}';
}

/// Single-line success rendering of an `ntsWarmCookies` result.
/// Carries the trust backend so a warm-only diagnostic flow surfaces
/// the same backend attribution as a full query, and any NTS-KE
/// warning codes the handshake produced (omitted when empty, as in
/// [formatQuerySuccess]).
String formatWarmSuccess(NtsWarmCookiesOutcome outcome) =>
    'OK  recovered ${outcome.freshCookies} fresh cookie(s)  '
    'trust=${formatTrustBackend(outcome.trustBackend)}'
    '${keWarningsSegment(outcome.keWarnings)}';

/// Two-line success rendering of a `getTime` result.
///
/// Mirrors the [formatQuerySuccess] headline / continuation shape so
/// the log stays visually uniform. The headline carries the winning
/// sample's RTT, the burst size that fed the lowest-delay selection,
/// and the projected current UTC ([NtsSyncedTime.utcNow], not the
/// anchored instant — reading it at format time demonstrates the
/// monotonic projection the type exists for). The continuation
/// carries the worst-case error bound
/// ([NtsSyncedTime.errorBoundMicros], the RFC 5905 root-distance
/// recipe: half the winning sample's network delay plus the
/// server-reported root delay/dispersion contribution plus burst
/// jitter) and the trust-backend attribution.
String formatGetTimeSuccess(NtsSyncedTime time) {
  final rtt = formatRtt(time.roundTripMicros).padLeft(8);
  final bound = formatRtt(time.errorBoundMicros);
  return 'OK  rtt=$rtt  samples=${time.samplesUsed}  '
      'utc=${time.utcNow.toIso8601String()}\n'
      '    \u2514\u2500 error\u2264\u00b1$bound (root distance)  '
      'trust=${formatTrustBackend(time.trustBackend)}';
}

/// Two-line rendering of the DNS resolver pool counters observed
/// across one batch of probes.
///
/// [NtsDnsPoolStats] is process-global and cumulative, so `recovered`,
/// `refused` and `spawnFailed` are rendered as a [before] → [after]
/// delta: a single post-batch snapshot cannot attribute anything to
/// the invocation that read it. `inFlight` and `highWaterMark` are not
/// counters and are rendered as the [after] value directly — the
/// former is a live gauge, the latter a process-lifetime maximum, and
/// subtracting either would produce a number with no meaning.
///
/// The headline carries the two refusal counters because they are the
/// actionable pair: `refused` climbing means `dnsConcurrencyCap` is
/// the binding constraint and raising it would help, whereas
/// `spawn-failed` climbing means the process is at an OS thread or
/// memory ceiling and raising the cap would make matters worse. Both
/// collapse onto `NtsError.timeout` on the error channel, so the
/// counters are the only way to tell them apart without matching on
/// message text.
String formatDnsPoolStats(NtsDnsPoolStats before, NtsDnsPoolStats after) =>
    'DNS pool  refused=${after.refused - before.refused}  '
    'spawn-failed=${after.spawnFailed - before.spawnFailed}\n'
    '    \u2514\u2500 recovered=${after.recovered - before.recovered}  '
    'in-flight=${after.inFlight}  '
    'high-water=${after.highWaterMark} (process lifetime)';

/// Severity classification for an [NtsError]. Network / timeout / spec
/// errors are routine when probing arbitrary hosts and warrant warn;
/// authentication, KE-/NTP-protocol, internal, ABI-mismatch, and
/// trust-backend errors are genuinely interesting and stay at error.
/// The trust-backend
/// case is a deliberate caller-side configuration choice (`PlatformOnly`)
/// the runtime cannot honour; loud surfacing is appropriate so an
/// operator notices the misconfiguration rather than treating it as a
/// transient network blip. The ABI-mismatch case means the loaded
/// native library does not match these bindings at all, so every
/// subsequent call will fail the same way until it is rebuilt.
bool isErrorSeverity(NtsError err) =>
    err is NtsErrorAuthentication ||
    err is NtsErrorKeProtocol ||
    err is NtsErrorNtpProtocol ||
    err is NtsErrorTrustBackendUnavailable ||
    err is NtsErrorInternal ||
    err is NtsErrorAbiMismatch;

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
///   flag are preserved verbatim in `message`; callers that want to
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
  NtsErrorAbiMismatch(:final message) => 'AbiMismatch: $message',
};

/// Structured timeout-phase tag for an [NtsError], or `null` for any
/// shape other than [NtsErrorTimeout].
///
/// Mirrors the `phase` key emitted by [jsonError] (`bridgeSaturation`,
/// `dnsSaturation`, `dnsSpawnFailed`, `dnsTimeout`, `connect`, `tls`,
/// `keRecordIo`, `ntp`). The health classifier uses it to tell a
/// *local* resolver refusal (`dnsSaturation` or `dnsSpawnFailed`, both
/// probe-side artifacts) apart from a genuine server-side no-reply,
/// instead of collapsing every timeout onto the bare `Timeout` tag
/// from [errorTypeName].
String? timeoutPhaseName(NtsError err) =>
    err is NtsErrorTimeout ? err.phase.name : null;

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
  NtsErrorAbiMismatch() => 'AbiMismatch',
};

/// JSON-shaped success payload for an `ntsQuery` result. Carries
/// the raw numeric fields the GUI / log already display, plus the
/// human AEAD label so consumers don't need to reimplement
/// [aeadLabel] and the trust-backend variant tag so monitoring
/// pipelines can distinguish a platform-store handshake from a
/// hybrid-fallback or webpki-roots one without re-parsing the human
/// message.
///
/// `ke_warnings` is present unconditionally, as an empty list in the
/// common case, so a consumer can index the key without a
/// null-presence branch. The text renderings drop the segment when
/// empty instead; a human log line and a schema have opposite
/// tolerances for a field that is almost always vacuous.
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
  'ke_warnings': sample.keWarnings,
};

/// JSON-shaped success payload for an `ntsWarmCookies` result.
/// Mirrors the per-handshake trust-backend attribution and the
/// unconditional `ke_warnings` key carried by [jsonQuerySuccess] so a
/// warm-only diagnostic flow stays machine-readable without a
/// separate code path.
Map<String, Object?> jsonWarmSuccess(NtsWarmCookiesOutcome outcome) => {
  'cookies': outcome.freshCookies,
  'trust_backend': outcome.trustBackend.name,
  'ke_warnings': outcome.keWarnings,
};

/// JSON-shaped failure payload for an [NtsError]. Pairs the variant
/// tag with the same human-readable description used in text output
/// and the warn/error severity classification.
///
/// `Timeout` failures additionally carry a structured `phase` field
/// holding the [TimeoutPhase] variant name (`bridgeSaturation`,
/// `dnsSaturation`, `dnsSpawnFailed`, `dnsTimeout`, `connect`, `tls`,
/// `keRecordIo`, `ntp`) so machine-readable consumers can switch on
/// the attribution without re-parsing the human message — the whole
/// point of carrying the phase tag through the API surface in the
/// first place.
Map<String, Object?> jsonError(NtsError err) => {
  'error_type': errorTypeName(err),
  'message': describeError(err),
  'severity': isErrorSeverity(err) ? 'error' : 'warn',
  if (err is NtsErrorTimeout) 'phase': err.phase.name,
};

/// JSON-shaped payload for the DNS resolver pool counters observed
/// across one batch of probes. Carries the same delta-vs-gauge split
/// as [formatDnsPoolStats]: the three cumulative counters are
/// [before] → [after] deltas attributable to this invocation, while
/// `in_flight` and `high_water_mark` are absolute readings whose
/// process-lifetime scope is spelled out in the key name.
Map<String, Object?> jsonDnsPoolStats(
  NtsDnsPoolStats before,
  NtsDnsPoolStats after,
) => {
  'refused': after.refused - before.refused,
  'spawn_failed': after.spawnFailed - before.spawnFailed,
  'recovered': after.recovered - before.recovered,
  'in_flight': after.inFlight,
  'high_water_mark': after.highWaterMark,
};

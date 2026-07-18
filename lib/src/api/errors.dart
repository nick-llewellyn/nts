// Hand-written public error contract for `package:nts`.
//
// Pairs with `lib/src/api/models.dart` to form the package's stable
// public surface. The wrapper functions in `lib/src/api/nts.dart`
// catch the FRB-generated `NtsError` and convert it to one of the
// variants defined here so consumer code never imports anything from
// `lib/src/ffi/`.
//
// Design notes:
// - `NtsError` is a Dart 3 `sealed class`, not a `freezed` class, so
//   exhaustive `switch (err) { ... }` in consumers does not require
//   `freezed_annotation` on the consumer side.
// - Variants whose precondition is "the TLS handshake had at least
//   reached config-build time" carry an optional `trustBackend`
//   field with the per-handshake trust-anchor backend resolved by
//   the Rust-side handshake (and on Android upgraded to
//   `TrustBackend.platformWithHybridFallback` if the hybrid
//   verifier's per-instance fallback counter incremented during the
//   handshake). New in 3.0.0; unaffected variants
//   (`invalidSpec`, `trustBackendUnavailable`, `internal`) carry
//   no `trustBackend` field.
// - Every variant with a non-`trustBackend` payload uses a
//   named-parameter constructor (`NtsError.keProtocol(message: ...,
//   trustBackend: ...)`, `NtsError.invalidSpec(message: ...)`,
//   etc.). The five `trustBackend`-carrying variants made the
//   move in 3.0.0; the three remaining single-payload variants
//   (`invalidSpec`, `trustBackendUnavailable`, `internal`) made the
//   move in 4.0.0 for surface uniformity. The pre-3.x back-compat
//   surface — the `field0` getter aliases and the underscore-
//   prefixed typedef aliases (`NtsError_InvalidSpec`, ...) — was
//   removed in 6.0.0 after three major-version lines of deprecation.

import 'models.dart' show TrustBackend;

/// Phase of an `ntsQuery` or `ntsWarmCookies` call whose wall-clock
/// budget elapsed.
///
/// Carried as the payload of [NtsError]'s `timeout` variant so callers
/// can attribute a failure to a specific pre-NTP step instead of
/// inspecting free-form diagnostic strings. The Rust-side KE-pipeline
/// taxonomy maps onto this enum, with one Dart-authored addition:
/// [bridgeSaturation] fires in the wrapper's bridge admission gate
/// before any FFI dispatch. The [ntp] variant covers the UDP
/// send/recv phase, and the two `dns*` variants distinguish saturation
/// (cap full) from timeout (resolver slow). See `ARCHITECTURE.md`'s
/// "Phase attribution and timings" section for the full diagnostic
/// shape.
enum TimeoutPhase {
  /// Wall-clock budget elapsed while the call was queued at the
  /// Dart-side bridge admission gate, before any FFI dispatch: the
  /// calling isolate's in-flight bridge-call count stayed at or above
  /// the call's `bridgeConcurrencyCap` for the whole budget. The gate
  /// state is isolate-local, so this phase reflects saturation by the
  /// calling isolate's own calls; other isolates share the same FRB
  /// worker pool but are not observed by this counter. Raising the
  /// cap or lowering the burst's fan-out is the appropriate
  /// remediation, not lengthening `timeoutMs` — a longer budget only
  /// waits longer behind the same saturated worker pool. Unlike every
  /// other phase, this one fires before the Rust pipeline starts, so
  /// the carrying [NtsError.timeout]'s `trustBackend` is always
  /// `null`.
  bridgeSaturation,

  /// Bounded DNS resolver pool was already at capacity when the call
  /// arrived, so admission was refused without spawning a worker.
  /// Distinct from [dnsTimeout]: raising `dnsConcurrencyCap` or
  /// waiting for the in-flight pool to drain is the appropriate
  /// remediation, not lengthening `timeoutMs`.
  dnsSaturation,

  /// System resolver took longer than the remaining budget. Lengthening
  /// `timeoutMs` *or* swapping in a faster recursive resolver are the
  /// appropriate remediations; raising the concurrency cap would only
  /// allow more threads to wedge in the same lookup.
  dnsTimeout,

  /// Per-address `TcpStream::connect_timeout` budget elapsed before any
  /// KE-host candidate accepted, or the global deadline expired before
  /// the connect loop could try the next address.
  connect,

  /// TLS handshake / initial NTS-KE request write tripped the deadline.
  /// In TLS 1.3 the first write is what completes the
  /// ClientHello/ServerHello/Finished round-trip.
  tls,

  /// Read of the NTS-KE response records exceeded the remaining budget
  /// -- the server completed TLS but is now drip-feeding (or has
  /// stalled completely on) the record exchange.
  keRecordIo,

  /// AEAD-NTPv4 UDP send / recv exceeded the remaining budget. Either
  /// the destination is unreachable or the wire round-trip time was too
  /// long for the configured budget.
  ntp,
}

/// Failure surface for `ntsQuery` and `ntsWarmCookies`.
///
/// Sealed: every concrete instance is one of the eight variants
/// declared below, and exhaustive `switch (err) { ... }` on an
/// `NtsError` value is checked at compile time. Implements [Exception]
/// so `try { ... } on NtsError catch (err)` and `try { ... } on
/// Exception catch (err)` both bind it.
sealed class NtsError implements Exception {
  const NtsError._();

  /// `spec` was rejected before any I/O happened.
  const factory NtsError.invalidSpec({required String message}) =
      NtsErrorInvalidSpec;

  /// TCP/UDP I/O error or connection failure. `trustBackend` carries
  /// the per-handshake trust-anchor backend resolved before the
  /// failure fired (when the failure happened post-`build_tls_config`),
  /// or `null` when the failure pre-dated config construction.
  const factory NtsError.network({
    required String message,
    TrustBackend? trustBackend,
  }) = NtsErrorNetwork;

  /// TLS handshake or NTS-KE record exchange failed. See
  /// [NtsError.network] for `trustBackend` semantics.
  const factory NtsError.keProtocol({
    required String message,
    TrustBackend? trustBackend,
  }) = NtsErrorKeProtocol;

  /// NTPv4 packet parsing or extension validation failed. See
  /// [NtsError.network] for `trustBackend` semantics.
  const factory NtsError.ntpProtocol({
    required String message,
    TrustBackend? trustBackend,
  }) = NtsErrorNtpProtocol;

  /// AEAD seal/open failed (tag mismatch, malformed input).
  ///
  /// Reserved for cryptographic-verification failures of the AEAD
  /// primitive itself on a fully negotiated algorithm — i.e. the
  /// `Aes128Siv`/`Aes128GcmSiv` `decrypt`/`encrypt` call returned an
  /// error against a key derived from the TLS exporter. A monitoring
  /// rule wired to "tag mismatch" alarms should key on this variant
  /// only.
  ///
  /// AEAD-algorithm *negotiation* failures during NTS-KE — a server
  /// picking an AEAD identifier this client does not implement —
  /// surface as [NtsError.keProtocol] instead, not as
  /// [NtsError.authentication]. The primary path is
  /// `KeError::UnsupportedAead` raised inside
  /// `rust/src/nts/ke.rs::validate_response` and routed to
  /// `KeProtocol` by the catch-all arm of the
  /// `From<KeError> for NtsError` impl in `rust/src/api/nts.rs`.
  /// The defence-in-depth path (`AeadError::UnsupportedAlgorithm`,
  /// only reached if validation is bypassed) is routed to the same
  /// `KeProtocol` variant by the explicit arm of the
  /// `From<AeadError> for NtsError` impl in the same file. See the
  /// `describeError` dartdoc in
  /// `example/lib/src/state/nts_format.dart` for the example app's
  /// rendering of the same routing.
  const factory NtsError.authentication({
    required String message,
    TrustBackend? trustBackend,
  }) = NtsErrorAuthentication;

  /// Wall-clock budget elapsed inside one of the call's pre-NTP or NTP
  /// phases. The [TimeoutPhase] payload identifies which phase tripped
  /// the deadline so callers can choose the right remediation.
  ///
  /// `trustBackend` is typed as nullable to keep the Rust `KeFailure`
  /// attribution contract honest at the FFI boundary, but in
  /// practice every Rust-authored phase fires after
  /// `build_tls_config` returned `Ok` and therefore carries the
  /// resolved backend. Rust `perform_handshake` calls
  /// `build_tls_config` before any DNS, connect, or TLS I/O begins,
  /// then attaches the resolved backend (via the per-call
  /// `attribute` closure) to every subsequent failure site —
  /// `dnsSaturation` and `dnsTimeout` from the bounded resolver,
  /// `connect` from the per-address `TcpStream::connect_timeout`
  /// loop, `tls` from the rustls handshake / write / flush window,
  /// `keRecordIo` from the chunked record-read loop, and the
  /// post-handshake UDP-leg `ntp` phase. The Android per-instance
  /// hybrid-fallback upgrade is reflected when the
  /// `HybridVerifier`'s fallback counter incremented during the TLS
  /// write/flush window. The one exception is the Dart-authored
  /// [TimeoutPhase.bridgeSaturation], which fires in the wrapper's
  /// bridge admission gate before any FFI dispatch and therefore
  /// always carries a `null` backend.
  const factory NtsError.timeout({
    required TimeoutPhase phase,
    TrustBackend? trustBackend,
  }) = NtsErrorTimeout;

  /// Cookie jar empty after a handshake (server delivered none).
  /// Always post-handshake, so `trustBackend` is populated when the
  /// caller cares to inspect which backend authenticated the chain
  /// that produced the empty pool.
  const factory NtsError.noCookies({TrustBackend? trustBackend}) =
      NtsErrorNoCookies;

  /// Caller selected `TrustMode.platformOnly` and the platform
  /// trust-anchor backend could not be constructed. Surfaced
  /// instead of silently downgrading to the `webpki-roots` static
  /// bundle. The payload carries the underlying construction-failure
  /// diagnostic. New in 3.0.0; consumers using exhaustive
  /// `switch (err) { ... }` on `NtsError` must add an arm for this
  /// variant.
  const factory NtsError.trustBackendUnavailable({required String message}) =
      NtsErrorTrustBackendUnavailable;

  /// Bug guard for unreachable internal states.
  const factory NtsError.internal({required String message}) = NtsErrorInternal;
}

/// Variant: `spec` (or one of the integer arguments accompanying
/// it) was rejected before any I/O happened. Surfaced from two
/// layers:
///
/// - **Dart wrapper, pre-FFI dispatch (new in 4.0.0).** The four
///   wrapper entry points ([ntsQuery], [ntsWarmCookies],
///   [NtsClient.query], [NtsClient.warmCookies]) reject `spec.port`
///   outside `1..65535`, and `timeoutMs` / `dnsConcurrencyCap`
///   outside `1..0xFFFFFFFF`, with a wrapper-authored message
///   before any FFI dispatch happens. Values that would otherwise
///   escape as `RangeError` from the FRB encoder land here as
///   `NtsError.invalidSpec` instead, keeping the wrapper's
///   "single error surface" contract honest.
/// - **Rust API entry point (`rust/src/api/nts.rs::validate`).**
///   The Rust-side validator still catches the residual shapes
///   the wrapper does not check (e.g. empty `spec.host`) and
///   serves as the load-bearing guard for callers that bypass the
///   wrapper (direct Rust API consumers, in-tree integration
///   tests). Its `port` and `timeout` checks remain in place as
///   defence-in-depth, even though the wrapper now front-loads
///   them.
final class NtsErrorInvalidSpec extends NtsError {
  /// Reason the spec was rejected.
  final String message;

  /// Construct an `InvalidSpec` variant.
  const NtsErrorInvalidSpec({required this.message}) : super._();

  @override
  int get hashCode => Object.hash(NtsErrorInvalidSpec, message);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is NtsErrorInvalidSpec && message == other.message);

  @override
  String toString() => 'NtsError.invalidSpec($message)';
}

/// Variant: TCP/UDP I/O error or connection failure.
final class NtsErrorNetwork extends NtsError {
  /// Diagnostic from the underlying `io::Error`.
  final String message;

  /// Per-handshake trust-anchor backend resolved before the failure
  /// fired, or `null` if the failure pre-dated config construction.
  final TrustBackend? trustBackend;

  /// Construct a `Network` variant.
  const NtsErrorNetwork({required this.message, this.trustBackend}) : super._();

  @override
  int get hashCode => Object.hash(NtsErrorNetwork, message, trustBackend);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is NtsErrorNetwork &&
          message == other.message &&
          trustBackend == other.trustBackend);

  @override
  String toString() => trustBackend == null
      ? 'NtsError.network($message)'
      : 'NtsError.network($message, backend: ${trustBackend!.name})';
}

/// Variant: TLS handshake or NTS-KE record exchange failed.
final class NtsErrorKeProtocol extends NtsError {
  /// TLS / NTS-KE record diagnostic.
  final String message;

  /// Per-handshake trust-anchor backend resolved before the failure
  /// fired, or `null` if the failure pre-dated config construction.
  final TrustBackend? trustBackend;

  /// Construct a `KeProtocol` variant.
  const NtsErrorKeProtocol({required this.message, this.trustBackend})
    : super._();

  @override
  int get hashCode => Object.hash(NtsErrorKeProtocol, message, trustBackend);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is NtsErrorKeProtocol &&
          message == other.message &&
          trustBackend == other.trustBackend);

  @override
  String toString() => trustBackend == null
      ? 'NtsError.keProtocol($message)'
      : 'NtsError.keProtocol($message, backend: ${trustBackend!.name})';
}

/// Variant: NTPv4 packet parsing or extension validation failed.
final class NtsErrorNtpProtocol extends NtsError {
  /// NTPv4 parse / extension / KoD diagnostic. KoD kiss codes
  /// (`RATE`, `DENY`, `RSTR`, `NTSN`, ...) are preserved verbatim.
  final String message;

  /// Per-handshake trust-anchor backend resolved before the failure
  /// fired, or `null` if the failure pre-dated config construction.
  final TrustBackend? trustBackend;

  /// Construct an `NtpProtocol` variant.
  const NtsErrorNtpProtocol({required this.message, this.trustBackend})
    : super._();

  @override
  int get hashCode => Object.hash(NtsErrorNtpProtocol, message, trustBackend);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is NtsErrorNtpProtocol &&
          message == other.message &&
          trustBackend == other.trustBackend);

  @override
  String toString() => trustBackend == null
      ? 'NtsError.ntpProtocol($message)'
      : 'NtsError.ntpProtocol($message, backend: ${trustBackend!.name})';
}

/// Variant: AEAD seal/open failed (tag mismatch or malformed input).
final class NtsErrorAuthentication extends NtsError {
  /// AEAD seal/open diagnostic.
  final String message;

  /// Per-handshake trust-anchor backend resolved before the failure
  /// fired, or `null` if the failure pre-dated config construction.
  final TrustBackend? trustBackend;

  /// Construct an `Authentication` variant.
  const NtsErrorAuthentication({required this.message, this.trustBackend})
    : super._();

  @override
  int get hashCode =>
      Object.hash(NtsErrorAuthentication, message, trustBackend);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is NtsErrorAuthentication &&
          message == other.message &&
          trustBackend == other.trustBackend);

  @override
  String toString() => trustBackend == null
      ? 'NtsError.authentication($message)'
      : 'NtsError.authentication($message, backend: ${trustBackend!.name})';
}

/// Variant: wall-clock budget elapsed inside one of the call's pre-NTP
/// or NTP phases.
final class NtsErrorTimeout extends NtsError {
  /// Phase whose deadline tripped. See [TimeoutPhase] for the taxonomy.
  final TimeoutPhase phase;

  /// Per-handshake trust-anchor backend resolved before the timeout
  /// fired. Typed as nullable to keep the Rust `KeFailure`
  /// attribution contract honest at the FFI boundary, but in
  /// practice every Rust-authored `TimeoutPhase` value
  /// (`dnsSaturation`, `dnsTimeout`, `connect`, `tls`, `keRecordIo`,
  /// post-handshake `ntp`) fires after `build_tls_config` returned
  /// `Ok` and therefore carries the resolved backend — see the
  /// constructor-level [NtsError.timeout] dartdoc above for the
  /// per-phase attribution map. The Dart-authored `bridgeSaturation`
  /// phase fires before any FFI dispatch and always carries `null`.
  final TrustBackend? trustBackend;

  /// Construct a `Timeout` variant.
  const NtsErrorTimeout({required this.phase, this.trustBackend}) : super._();

  @override
  int get hashCode => Object.hash(NtsErrorTimeout, phase, trustBackend);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is NtsErrorTimeout &&
          phase == other.phase &&
          trustBackend == other.trustBackend);

  @override
  String toString() => trustBackend == null
      ? 'NtsError.timeout(${phase.name})'
      : 'NtsError.timeout(${phase.name}, backend: ${trustBackend!.name})';
}

/// Variant: cookie jar empty after a handshake (server delivered none).
final class NtsErrorNoCookies extends NtsError {
  /// Per-handshake trust-anchor backend resolved before the failure
  /// fired. Populated for every library-originated `NoCookies`
  /// failure (cache-hit short-circuit and the singleflight Leader
  /// arm both attach the resolved backend), but typed as nullable
  /// because the public factory `NtsError.noCookies()` accepts the
  /// no-backend form for callers (e.g. test fixtures) that need to
  /// construct the variant without a chain having authenticated.
  /// `toString()` preserves the no-backend form when the field is
  /// `null`.
  final TrustBackend? trustBackend;

  /// Construct a `NoCookies` variant.
  const NtsErrorNoCookies({this.trustBackend}) : super._();

  @override
  int get hashCode => Object.hash(NtsErrorNoCookies, trustBackend);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is NtsErrorNoCookies && trustBackend == other.trustBackend);

  @override
  String toString() => trustBackend == null
      ? 'NtsError.noCookies()'
      : 'NtsError.noCookies(backend: ${trustBackend!.name})';
}

/// Variant: caller selected `TrustMode.platformOnly` and the
/// platform trust-anchor backend could not be constructed.
/// New in 3.0.0; see [NtsError.trustBackendUnavailable].
final class NtsErrorTrustBackendUnavailable extends NtsError {
  /// Underlying construction-failure diagnostic from
  /// `build_with_native_verifier` (typically a `rustls::Error`
  /// rendered as a string).
  final String message;

  /// Construct a `TrustBackendUnavailable` variant.
  const NtsErrorTrustBackendUnavailable({required this.message}) : super._();

  @override
  int get hashCode => Object.hash(NtsErrorTrustBackendUnavailable, message);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is NtsErrorTrustBackendUnavailable && message == other.message);

  @override
  String toString() => 'NtsError.trustBackendUnavailable($message)';
}

/// Variant: bug guard for unreachable internal states.
final class NtsErrorInternal extends NtsError {
  /// Bug-guard diagnostic.
  final String message;

  /// Construct an `Internal` variant.
  const NtsErrorInternal({required this.message}) : super._();

  @override
  int get hashCode => Object.hash(NtsErrorInternal, message);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is NtsErrorInternal && message == other.message);

  @override
  String toString() => 'NtsError.internal($message)';
}

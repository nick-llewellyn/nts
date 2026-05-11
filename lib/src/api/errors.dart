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
//   (`invalidSpec`, `trustBackendUnavailable`, `internal`) keep
//   their pre-3.0 single-payload shape.
// - Each variant that received the `trustBackend` field also gained
//   a named-parameter constructor (`NtsError.keProtocol(message:
//   ..., trustBackend: ...)`) — the pre-3.0 single-positional shape
//   is preserved as a `field0` getter on the same variant for
//   source-level back-compat.
// - For SemVer compatibility with pre-3.0 callers, the underscore-
//   prefixed names (`NtsError_InvalidSpec`, ...) survive as deprecated
//   typedef aliases at the bottom of this file. They will be removed
//   at the next major bump.

import 'models.dart' show TrustBackend;

/// Phase of an `ntsQuery` or `ntsWarmCookies` call whose wall-clock
/// budget elapsed.
///
/// Carried as the payload of [NtsError]'s `timeout` variant so callers
/// can attribute a failure to a specific pre-NTP step instead of
/// inspecting free-form diagnostic strings. The Rust-side KE-pipeline
/// taxonomy maps onto this enum; the [ntp] variant covers the UDP
/// send/recv phase, and the two `dns*` variants distinguish saturation
/// (cap full) from timeout (resolver slow). See `ARCHITECTURE.md`'s
/// "Phase attribution and timings" section for the full diagnostic
/// shape.
enum TimeoutPhase {
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
  const factory NtsError.invalidSpec(String field0) = NtsErrorInvalidSpec;

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
  /// `trustBackend` is populated for post-TLS phases (`keRecordIo`,
  /// `ntp`) and `null` for pre-TLS phases (`dnsSaturation`,
  /// `dnsTimeout`, `connect`, `tls`) which fired before the trust
  /// backend could be resolved.
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
  const factory NtsError.trustBackendUnavailable(String field0) =
      NtsErrorTrustBackendUnavailable;

  /// Bug guard for unreachable internal states.
  const factory NtsError.internal(String field0) = NtsErrorInternal;
}

/// Variant: `spec` was rejected before any I/O happened. The check
/// runs in the Rust API entry point (`rust/src/api/nts.rs::validate`),
/// not in the Dart wrapper, which forwards `spec` verbatim.
final class NtsErrorInvalidSpec extends NtsError {
  /// Reason the spec was rejected.
  final String field0;

  /// Construct an `InvalidSpec` variant.
  const NtsErrorInvalidSpec(this.field0) : super._();

  @override
  int get hashCode => Object.hash(NtsErrorInvalidSpec, field0);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is NtsErrorInvalidSpec && field0 == other.field0);

  @override
  String toString() => 'NtsError.invalidSpec($field0)';
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

  /// Pre-3.0 alias for [message]. Will be removed in a future major.
  @Deprecated('Renamed to message; the positional payload is now named.')
  String get field0 => message;

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

  /// Pre-3.0 alias for [message]. Will be removed in a future major.
  @Deprecated('Renamed to message; the positional payload is now named.')
  String get field0 => message;

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

  /// Pre-3.0 alias for [message]. Will be removed in a future major.
  @Deprecated('Renamed to message; the positional payload is now named.')
  String get field0 => message;

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

  /// Pre-3.0 alias for [message]. Will be removed in a future major.
  @Deprecated('Renamed to message; the positional payload is now named.')
  String get field0 => message;

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
  /// fired (post-TLS phases only), or `null` for pre-TLS phases.
  final TrustBackend? trustBackend;

  /// Construct a `Timeout` variant.
  const NtsErrorTimeout({required this.phase, this.trustBackend}) : super._();

  /// Pre-3.0 alias for [phase]. Will be removed in a future major.
  @Deprecated('Renamed to phase; the positional payload is now named.')
  TimeoutPhase get field0 => phase;

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
  /// fired. Always populated for post-handshake failures (which is
  /// every `noCookies` failure by definition).
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
  final String field0;

  /// Construct a `TrustBackendUnavailable` variant.
  const NtsErrorTrustBackendUnavailable(this.field0) : super._();

  @override
  int get hashCode => Object.hash(NtsErrorTrustBackendUnavailable, field0);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is NtsErrorTrustBackendUnavailable && field0 == other.field0);

  @override
  String toString() => 'NtsError.trustBackendUnavailable($field0)';
}

/// Variant: bug guard for unreachable internal states.
final class NtsErrorInternal extends NtsError {
  /// Bug-guard diagnostic.
  final String field0;

  /// Construct an `Internal` variant.
  const NtsErrorInternal(this.field0) : super._();

  @override
  int get hashCode => Object.hash(NtsErrorInternal, field0);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is NtsErrorInternal && field0 == other.field0);

  @override
  String toString() => 'NtsError.internal($field0)';
}

// Deprecated underscore-prefixed aliases for the pre-3.0 freezed-style
// variant names. The package's stable surface uses the idiomatic Dart
// PascalCase forms (`NtsErrorInvalidSpec` etc.); these typedefs exist
// so consumer code that pattern-matched on the old names compiles
// against 3.0.x with deprecation warnings, and can be migrated before
// a future 4.x release removes them. The `camel_case_types` lint
// suppression is intentional and scoped per-typedef.

/// Pre-3.0 alias for [NtsErrorInvalidSpec]. Will be removed in a future
/// 4.x release.
@Deprecated('Renamed to NtsErrorInvalidSpec; remove the underscore.')
// ignore: camel_case_types
typedef NtsError_InvalidSpec = NtsErrorInvalidSpec;

/// Pre-3.0 alias for [NtsErrorNetwork]. Will be removed in a future
/// 4.x release.
@Deprecated('Renamed to NtsErrorNetwork; remove the underscore.')
// ignore: camel_case_types
typedef NtsError_Network = NtsErrorNetwork;

/// Pre-3.0 alias for [NtsErrorKeProtocol]. Will be removed in a future
/// 4.x release.
@Deprecated('Renamed to NtsErrorKeProtocol; remove the underscore.')
// ignore: camel_case_types
typedef NtsError_KeProtocol = NtsErrorKeProtocol;

/// Pre-3.0 alias for [NtsErrorNtpProtocol]. Will be removed in a future
/// 4.x release.
@Deprecated('Renamed to NtsErrorNtpProtocol; remove the underscore.')
// ignore: camel_case_types
typedef NtsError_NtpProtocol = NtsErrorNtpProtocol;

/// Pre-3.0 alias for [NtsErrorAuthentication]. Will be removed in a
/// future 4.x release.
@Deprecated('Renamed to NtsErrorAuthentication; remove the underscore.')
// ignore: camel_case_types
typedef NtsError_Authentication = NtsErrorAuthentication;

/// Pre-3.0 alias for [NtsErrorTimeout]. Will be removed in a future
/// 4.x release.
@Deprecated('Renamed to NtsErrorTimeout; remove the underscore.')
// ignore: camel_case_types
typedef NtsError_Timeout = NtsErrorTimeout;

/// Pre-3.0 alias for [NtsErrorNoCookies]. Will be removed in a future
/// 4.x release.
@Deprecated('Renamed to NtsErrorNoCookies; remove the underscore.')
// ignore: camel_case_types
typedef NtsError_NoCookies = NtsErrorNoCookies;

/// Pre-3.0 alias for [NtsErrorInternal]. Will be removed in a future
/// 4.x release.
@Deprecated('Renamed to NtsErrorInternal; remove the underscore.')
// ignore: camel_case_types
typedef NtsError_Internal = NtsErrorInternal;

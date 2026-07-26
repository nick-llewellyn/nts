// Conversion layer between the FFI and public surfaces.
//
// Part of the nts.dart library; see that file for the imports,
// re-exports, and defaults these declarations rely on.

part of 'nts.dart';

// --- conversion layer (FFI <-> public) -------------------------------
//
// All FFI types stay scoped to this file. Conversions are intentionally
// total (no fallback / catch-all arms) so a future Rust-side variant
// addition surfaces as an exhaustiveness error here rather than as a
// silently-dropped variant at the consumer.

ffi.NtsServerSpec _ffiSpec(NtsServerSpec spec) =>
    ffi.NtsServerSpec(host: spec.host, port: spec.port);

// `verificationTimeMs` crosses the boundary as the FRB `PlatformInt64`
// (the Rust side is `Option<i64>`). On the native platforms this package
// targets (`web`/`wasm` are excluded — see `pubspec.yaml`) `PlatformInt64`
// is an alias for `int`, so this conversion is an identity; routing
// through `PlatformInt64Util.from` keeps the to-FFI boundary explicit and
// correct independent of the FRB platform mapping, mirroring the
// `.toInt()` calls used in the FFI -> public direction. Negative values
// are rejected by `_validateRanges` before reaching here.
PlatformInt64? _ffiVerificationTime(int? ms) =>
    ms == null ? null : PlatformInt64Util.from(ms);

// Converts a resolved `Duration` budget to the FFI's millisecond `int`
// with a *ceiling*, so a live sub-millisecond remainder is never rounded
// down to a dead (zero) budget at dispatch. The forwarded value may
// exceed the true remainder by <1 ms — see the `_getTime` remaining()
// comment for the budget-accounting consequences.
int _ffiTimeoutMs(Duration d) => (d.inMicroseconds + 999) ~/ 1000;

NtsTimeSample _publicSample(ffi.NtsTimeSample s) => NtsTimeSample(
  utcUnixMicros: s.utcUnixMicros.toInt(),
  roundTripMicros: s.roundTripMicros.toInt(),
  serverStratum: s.serverStratum,
  aeadId: s.aeadId,
  freshCookies: s.freshCookies,
  phaseTimings: _publicPhase(s.phaseTimings),
  trustBackend: _publicTrustBackend(s.trustBackend),
  recvBoottimeMicros: s.recvBoottimeMicros.toInt(),
  offsetMicros: s.offsetMicros.toInt(),
  peerDelayMicros: s.peerDelayMicros.toInt(),
  rootDelayMicros: s.rootDelayMicros.toInt(),
  rootDispersionMicros: s.rootDispersionMicros.toInt(),
  serverPrecision: s.serverPrecision,
);

NtsWarmCookiesOutcome _publicWarm(ffi.NtsWarmCookiesOutcome o) =>
    NtsWarmCookiesOutcome(
      freshCookies: o.freshCookies,
      phaseTimings: _publicPhase(o.phaseTimings),
      trustBackend: _publicTrustBackend(o.trustBackend),
    );

PhaseTimings _publicPhase(ffi.PhaseTimings p) => PhaseTimings(
  dnsMicros: p.dnsMicros.toInt(),
  connectMicros: p.connectMicros.toInt(),
  tlsHandshakeMicros: p.tlsHandshakeMicros.toInt(),
  keRecordIoMicros: p.keRecordIoMicros.toInt(),
);

NtsDnsPoolStats _publicStats(ffi.NtsDnsPoolStats s) => NtsDnsPoolStats(
  inFlight: s.inFlight,
  highWaterMark: s.highWaterMark,
  recovered: s.recovered,
  refused: s.refused,
);

TimeoutPhase _publicTimeoutPhase(ffi.TimeoutPhase phase) => switch (phase) {
  ffi.TimeoutPhase.dnsSaturation => TimeoutPhase.dnsSaturation,
  ffi.TimeoutPhase.dnsTimeout => TimeoutPhase.dnsTimeout,
  ffi.TimeoutPhase.connect => TimeoutPhase.connect,
  ffi.TimeoutPhase.tls => TimeoutPhase.tls,
  ffi.TimeoutPhase.keRecordIo => TimeoutPhase.keRecordIo,
  ffi.TimeoutPhase.ntp => TimeoutPhase.ntp,
};

NtsError _publicError(ffi.NtsError err) => switch (err) {
  ffi.NtsError_InvalidSpec(:final field0) => NtsError.invalidSpec(
    message: field0,
  ),
  ffi.NtsError_Network(:final message, :final trustBackend) => NtsError.network(
    message: message,
    trustBackend: _maybePublicTrustBackend(trustBackend),
  ),
  ffi.NtsError_KeProtocol(:final message, :final trustBackend) =>
    NtsError.keProtocol(
      message: message,
      trustBackend: _maybePublicTrustBackend(trustBackend),
    ),
  ffi.NtsError_NtpProtocol(:final message, :final trustBackend) =>
    NtsError.ntpProtocol(
      message: message,
      trustBackend: _maybePublicTrustBackend(trustBackend),
    ),
  ffi.NtsError_Authentication(:final message, :final trustBackend) =>
    NtsError.authentication(
      message: message,
      trustBackend: _maybePublicTrustBackend(trustBackend),
    ),
  ffi.NtsError_Timeout(:final phase, :final trustBackend) => NtsError.timeout(
    phase: _publicTimeoutPhase(phase),
    trustBackend: _maybePublicTrustBackend(trustBackend),
  ),
  ffi.NtsError_NoCookies(:final trustBackend) => NtsError.noCookies(
    trustBackend: _maybePublicTrustBackend(trustBackend),
  ),
  ffi.NtsError_TrustBackendUnavailable(:final field0) =>
    NtsError.trustBackendUnavailable(message: field0),
  ffi.NtsError_Internal(:final field0) => NtsError.internal(message: field0),
};

TrustBackend? _maybePublicTrustBackend(ffi.TrustBackend? b) =>
    b == null ? null : _publicTrustBackend(b);

TrustBackend _publicTrustBackend(ffi.TrustBackend b) => switch (b) {
  ffi.TrustBackend.platform => TrustBackend.platform,
  ffi.TrustBackend.platformWithHybridFallback =>
    TrustBackend.platformWithHybridFallback,
  ffi.TrustBackend.webpkiRoots => TrustBackend.webpkiRoots,
  ffi.TrustBackend.custom => TrustBackend.custom,
};

TrustMode _publicTrustMode(ffi.TrustMode m) => switch (m) {
  ffi.TrustMode_PlatformWithFallback() => TrustMode.platformWithFallback,
  ffi.TrustMode_PlatformOnly() => TrustMode.platformOnly,
  ffi.TrustMode_BundledOnly() => TrustMode.bundledOnly,
  ffi.TrustMode_Custom() => TrustMode.custom,
};

ffi.TrustMode _ffiTrustMode(
  TrustMode m, [
  List<int>? customRoots,
]) => switch (m) {
  TrustMode.platformWithFallback => const ffi.TrustMode.platformWithFallback(),
  TrustMode.platformOnly => const ffi.TrustMode.platformOnly(),
  TrustMode.bundledOnly => const ffi.TrustMode.bundledOnly(),
  TrustMode.custom => ffi.TrustMode.custom(Uint8List.fromList(customRoots!)),
};

NtsTrustStatus _publicTrustStatus(ffi.NtsTrustStatus s) => NtsTrustStatus(
  defaultClientBackend: s.defaultClientBackend == null
      ? null
      : _publicTrustBackend(s.defaultClientBackend!),
  defaultBackendPlatformCount: s.defaultBackendPlatformCount,
  defaultBackendHybridCount: s.defaultBackendHybridCount,
  defaultBackendWebpkiCount: s.defaultBackendWebpkiCount,
  defaultBackendCustomCount: s.defaultBackendCustomCount,
  androidPlatformInitSucceeded: s.androidPlatformInitSucceeded,
  androidHybridFallbackCount: s.androidHybridFallbackCount,
);

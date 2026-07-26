// Input validation and deprecated-parameter resolution.
//
// Part of the nts.dart library; see that file for the imports,
// re-exports, and defaults these declarations rely on.

part of 'nts.dart';

// --- input validation -----------------------------------------------
//
// Run before every wrapper dispatches into the FFI layer. The three
// FFI-bound integer arguments hit FRB-generated `sse_encode_u_16` /
// `sse_encode_u_32` codecs that `RangeError` on out-of-range values
// before the Rust code ever runs, which would escape the wrapper's
// `on ffi.NtsError catch` contract and surface to consumers as a
// non-`NtsError` exception. Validating up front and translating to
// `NtsError.invalidSpec` keeps the wrapper's "single error surface"
// promise honest.
//
// `port` is restricted to the semantically meaningful range `1..65535`
// rather than the encoder's `0..65535`: Rust's spec validator already
// rejects `port == 0` with its own `InvalidSpec("port must be
// non-zero")`, and front-loading the check produces a wrapper-authored
// `NtsError.invalidSpec` on the returned `Future` (the four wrapper
// entry points are `async`, so the error materialises on `await`)
// before any FFI dispatch instead of a Rust-authored one after a
// futile FFI hop. `timeout` (in milliseconds) and `dnsConcurrencyCap`
// are restricted to `1..0xFFFFFFFF`: zero used to be a sentinel for
// "inherit the Rust-side default" in 1.x and 3.0.x, but consumers are
// now steered toward the named `kDefault*` constants which expose the
// actual values. `bridgeConcurrencyCap` never crosses the FFI
// boundary (the gate is pure Dart), but it is held to the same
// `1..0xFFFFFFFF` range so the three cap/budget parameters share one
// validation contract.

const int _kU32Max = 0xFFFFFFFF;

// --- deprecated-parameter resolution ----------------------------------
//
// One release of overlap: the deprecated `int` millisecond parameters
// coexist with the typed `Duration` / `DateTime` ones. These helpers
// collapse each pair onto the single value the rest of the pipeline
// uses, failing fast on any *detectable* conflict.

// `timeout` has a non-null default, so an un-migrated caller passing
// only `timeoutMs` necessarily leaves `timeout` at `kDefaultTimeout` —
// that is the silent compatibility path. An explicit non-default
// `timeout` alongside `timeoutMs` is a demonstrable conflict and is
// rejected. Known blind spot (accepted): `Duration` equality is
// value-based, so any explicit `timeout` equal to [kDefaultTimeout]
// (the constant itself or e.g. `Duration(seconds: 5)`) passed alongside
// `timeoutMs` is indistinguishable from the default case and resolves
// to `timeoutMs` without error.
Duration _resolveTimeout(Duration timeout, int? timeoutMs) {
  if (timeoutMs == null) return timeout;
  if (timeout == kDefaultTimeout) return Duration(milliseconds: timeoutMs);
  throw const NtsError.invalidSpec(
    message:
        'both timeout and the deprecated timeoutMs were provided with '
        'conflicting values; pass one or the other (prefer timeout)',
  );
}

// Both verification parameters are nullable with no default, so "both
// supplied" is an unambiguous caller mistake rather than a
// default-vs-override situation. The resolved value stays an epoch-ms
// `int?` internally (the FFI shape).
int? _resolveVerificationTime(DateTime? verificationTime, int? ms) {
  if (verificationTime != null && ms != null) {
    throw const NtsError.invalidSpec(
      message:
          'both verificationTime and the deprecated verificationTimeMs '
          'were provided; pass one or the other (prefer verificationTime)',
    );
  }
  return verificationTime?.toUtc().millisecondsSinceEpoch ?? ms;
}

// Re-wraps a resolved epoch-ms verification instant as a UTC `DateTime`
// for forwarding through the non-deprecated parameter of the underlying
// wrappers (used by the getTime orchestration entry points).
DateTime? _verificationInstant(int? resolvedMs) => resolvedMs == null
    ? null
    : DateTime.fromMillisecondsSinceEpoch(resolvedMs, isUtc: true);

// --- ABI-mismatch interception ----------------------------------------
//
// A call can dispatch into the native library successfully and still
// fail on the way back: the FRB-generated codec decodes the returned
// bytes against the layout the bindings were generated for, and a
// library built from different Rust sources produces bytes that do
// not match. The failures surface from the codec as bare Dart
// `Error`s rather than as an `ffi.NtsError`, so they escape the
// `on ffi.NtsError catch` arms and reach consumers as a raw
// `RangeError (byteOffset)` naming neither the cause nor the fix.
//
// Three shapes are attributable to a layout disagreement:
//
// - `RangeError` — a fixed-width decoder read past the end of a
//   buffer shorter than the layout expects.
// - `UnimplementedError` — an enum discriminant the generated
//   `switch` has no arm for (see `sse_decode_nts_error`'s `default`).
// - `ArgumentError` — a decoded value rejected as malformed before
//   it reaches a DTO constructor.
//
// Deliberately *not* caught: `StateError`, which FRB's dispatcher
// throws for a missed `NtsRustLib.init()`. That is a bootstrap
// ordering mistake with its own documented remediation, and the four
// entry points' dartdoc already promises it passes through
// unconverted.
//
// The wrapper validates its own integer arguments up front
// (`_validateRanges`), so an encode-side `RangeError` cannot reach
// here; anything of these shapes crossing this boundary originates
// in the decode path.
bool _isAbiDecodeFailure(Object e) =>
    e is RangeError || e is UnimplementedError || e is ArgumentError;

// Rebuild guidance carried on every converted decode failure. The
// example CLI warns about the common case ahead of the call by
// comparing timestamps, but that check cannot fire for a library
// loaded from outside a crate tree, a prebuilt binary shipped
// without sources, or one built for another architecture — those
// land here instead.
NtsError _abiMismatchError(Object cause) => NtsError.abiMismatch(
  message:
      'the loaded native library and these Dart bindings disagree on '
      'the wire layout of a value crossing the FFI boundary '
      '($cause) — rebuild the native library from the Rust sources '
      'matching this package version (`cargo build --release` in '
      '`rust/`, then regenerate bindings with '
      '`flutter_rust_bridge_codegen generate` if the Rust API '
      'changed)',
);

// Synchronous entry points dispatch through the same FRB table and
// decode through the same codecs, so they carry the same exposure.
// They have no `on ffi.NtsError catch` to widen — the Rust side
// cannot fail them — so the conversion is all they need.
T _syncGuard<T>(T Function() body) {
  try {
    return body();
  } catch (e, stack) {
    if (!_isAbiDecodeFailure(e)) rethrow;
    Error.throwWithStackTrace(_abiMismatchError(e), stack);
  }
}

// Shared resolve -> validate -> gate -> convert -> catch scaffolding
// for the four query/warmCookies entry points (top-level and
// per-client). Each entry point supplies only its own FFI invocation
// via `call`, receiving the already-converted FFI-shaped arguments.
Future<T> _dispatch<T>({
  required NtsServerSpec spec,
  required Duration timeout,
  required int? timeoutMs,
  required int dnsConcurrencyCap,
  required int bridgeConcurrencyCap,
  required DateTime? verificationTime,
  required int? verificationTimeMs,
  required Future<T> Function(
    ffi.NtsServerSpec ffiSpec,
    int ffiTimeoutMs,
    PlatformInt64? ffiVerificationMs,
  )
  call,
}) async {
  final resolvedTimeout = _resolveTimeout(timeout, timeoutMs);
  final resolvedVerificationMs = _resolveVerificationTime(
    verificationTime,
    verificationTimeMs,
  );
  _validateRanges(
    spec: spec,
    timeout: resolvedTimeout,
    dnsConcurrencyCap: dnsConcurrencyCap,
    bridgeConcurrencyCap: bridgeConcurrencyCap,
    verificationTimeMs: resolvedVerificationMs,
  );
  return _withBridgeSlot(
    bridgeConcurrencyCap: bridgeConcurrencyCap,
    timeout: resolvedTimeout,
    body: (remainingTimeout) async {
      try {
        return await call(
          _ffiSpec(spec),
          _ffiTimeoutMs(remainingTimeout),
          _ffiVerificationTime(resolvedVerificationMs),
        );
      } on ffi.NtsError catch (err, stack) {
        // Preserve the original FFI-side stack trace through the
        // conversion so debuggers point at the FRB dispatcher / Rust
        // boundary where the error originated, not at this catch site.
        Error.throwWithStackTrace(_publicError(err), stack);
      } catch (e, stack) {
        // The Rust side returned, but the generated codec could not
        // decode what came back. Preserve the stack for the same
        // reason as above — it points into the codec frame that
        // detected the layout disagreement.
        if (!_isAbiDecodeFailure(e)) rethrow;
        Error.throwWithStackTrace(_abiMismatchError(e), stack);
      }
    },
  );
}

void _validatePort(NtsServerSpec spec) {
  if (spec.port < 1 || spec.port > 65535) {
    throw NtsError.invalidSpec(
      message: 'port ${spec.port} is outside the valid range 1..65535',
    );
  }
}

void _validateRanges({
  required NtsServerSpec spec,
  required Duration timeout,
  required int dnsConcurrencyCap,
  required int bridgeConcurrencyCap,
  int? verificationTimeMs,
}) {
  _validatePort(spec);
  if (timeout < const Duration(milliseconds: 1) ||
      timeout > const Duration(milliseconds: _kU32Max)) {
    throw NtsError.invalidSpec(
      message:
          'timeout $timeout (or the deprecated timeoutMs) is outside the '
          'valid range 1ms..${_kU32Max}ms — sub-millisecond durations are '
          'rejected (1 ms floor); pass kDefaultTimeout to inherit the '
          'package default',
    );
  }
  if (dnsConcurrencyCap < 1 || dnsConcurrencyCap > _kU32Max) {
    throw NtsError.invalidSpec(
      message:
          'dnsConcurrencyCap $dnsConcurrencyCap is outside the valid '
          'range 1..$_kU32Max; pass kDefaultDnsConcurrencyCap '
          '($kDefaultDnsConcurrencyCap) to inherit the package default',
    );
  }
  if (bridgeConcurrencyCap < 1 || bridgeConcurrencyCap > _kU32Max) {
    throw NtsError.invalidSpec(
      message:
          'bridgeConcurrencyCap $bridgeConcurrencyCap is outside the valid '
          'range 1..$_kU32Max; pass kDefaultBridgeConcurrencyCap '
          '($kDefaultBridgeConcurrencyCap) to inherit the package default',
    );
  }
  // The resolved verification instant is an epoch-milliseconds value:
  // the Rust side maps it to a `UnixTime` via `Duration::from_millis(u64)`,
  // so a negative value cannot encode a real instant. Reject it here with
  // the same `invalidSpec` surface as the other range checks rather than
  // letting it silently fall back to the system clock on the Rust side.
  if (verificationTimeMs != null && verificationTimeMs < 0) {
    throw NtsError.invalidSpec(
      message:
          'verificationTime (or the deprecated verificationTimeMs) resolves '
          'to $verificationTimeMs ms, which is before the Unix epoch; it '
          'must be a non-negative epoch-milliseconds instant',
    );
  }
}

// `getTime` validation front-loads the same checks its underlying
// warm/query calls would run, so an invalid argument surfaces as
// `NtsError.invalidSpec` before the warming handshake ever dispatches
// (rather than after a successful handshake has already replaced the
// cached session). The tuning knobs themselves are internal constants
// and need no range check.
void _validateGetTime({required NtsServerSpec spec, int? verificationTimeMs}) {
  _validateRanges(
    spec: spec,
    timeout: _kGetTimeTimeout,
    dnsConcurrencyCap: kDefaultDnsConcurrencyCap,
    bridgeConcurrencyCap: kDefaultBridgeConcurrencyCap,
    verificationTimeMs: verificationTimeMs,
  );
}

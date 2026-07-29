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

// Upper bound on a resolved verification instant, mirroring
// `MAX_VERIFICATION_TIME_MS` in `rust/src/api/nts.rs`
// (9999-12-31T23:59:59Z). Anything above it cannot denote a real
// instant; front-loading the ceiling keeps far-future values on the
// same wrapper-authored `invalidSpec` surface as the other range
// checks instead of returning a Rust-authored message after a futile
// FFI hop.
const int _kMaxVerificationTimeMs = 253402300799000;

// --- verification-instant conversion ----------------------------------

// Collapses the public `DateTime?` verification instant onto the
// epoch-ms `int?` the rest of the pipeline (and the FFI shape) uses.
int? _verificationMs(DateTime? verificationTime) =>
    verificationTime?.toUtc().millisecondsSinceEpoch;

// Re-wraps a resolved epoch-ms verification instant as a UTC `DateTime`
// for forwarding through the underlying wrappers (used by the getTime
// orchestration entry points).
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

// Shared validate -> gate -> convert -> catch scaffolding for the four
// query/warmCookies entry points (top-level and per-client). Each entry
// point supplies only its own FFI invocation via `call`, receiving the
// already-converted FFI-shaped arguments.
Future<T> _dispatch<T>({
  required NtsServerSpec spec,
  required Duration timeout,
  required int dnsConcurrencyCap,
  required int bridgeConcurrencyCap,
  required DateTime? verificationTime,
  required Future<T> Function(
    ffi.NtsServerSpec ffiSpec,
    int ffiTimeoutMs,
    PlatformInt64? ffiVerificationMs,
  )
  call,
}) async {
  final resolvedVerificationMs = _verificationMs(verificationTime);
  _validateRanges(
    spec: spec,
    timeout: timeout,
    dnsConcurrencyCap: dnsConcurrencyCap,
    bridgeConcurrencyCap: bridgeConcurrencyCap,
    verificationTimeMs: resolvedVerificationMs,
  );
  return _withBridgeSlot(
    bridgeConcurrencyCap: bridgeConcurrencyCap,
    timeout: timeout,
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

// Reject a spec that cannot name a server before it reaches the FFI
// boundary. Rust's own `validate` rejects an empty host, but only
// after the dispatch; front-loading it keeps the wrapper-authored
// message and, on the synchronous `invalidate` path, fails closed
// instead of soft-failing as "no cached entry".
//
// Whitespace-only hosts are rejected rather than normalised: the
// session key is `host:port` verbatim, so silently trimming here
// would make the wrapper and the Rust-side cache disagree about
// which key a call addresses.
void _validateSpec(NtsServerSpec spec) {
  if (spec.host.trim().isEmpty) {
    throw const NtsError.invalidSpec(message: 'host must be non-empty');
  }
  _validatePort(spec);
}

void _validatePort(NtsServerSpec spec) {
  if (spec.port < 1 || spec.port > 65535) {
    throw NtsError.invalidSpec(
      message: 'port ${spec.port} is outside the valid range 1..65535',
    );
  }
}

// Reject a `trustMode` / `customRoots` pair that does not describe a
// constructible trust policy. Shared by the [NtsClient] factory and
// every entry point that routes through it, so the two surfaces
// cannot drift.
void _validateTrustPolicy({
  required TrustMode trustMode,
  required List<int>? customRoots,
}) {
  if (customRoots != null && trustMode != TrustMode.custom) {
    throw const NtsError.invalidSpec(
      message: 'customRoots can only be set when trustMode is TrustMode.custom',
    );
  }
  if (trustMode == TrustMode.custom &&
      (customRoots == null || customRoots.isEmpty)) {
    throw const NtsError.invalidSpec(
      message:
          'customRoots must be provided and non-empty when trustMode is '
          'TrustMode.custom',
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
  _validateSpec(spec);
  if (timeout < const Duration(milliseconds: 1) ||
      timeout > const Duration(milliseconds: _kU32Max)) {
    throw NtsError.invalidSpec(
      message:
          'timeout $timeout is outside the valid range '
          '1ms..${_kU32Max}ms — sub-millisecond durations are '
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
  if (verificationTimeMs != null) {
    if (verificationTimeMs < 0) {
      throw NtsError.invalidSpec(
        message:
            'verificationTime resolves to $verificationTimeMs ms, which is '
            'before the Unix epoch; it must be a non-negative '
            'epoch-milliseconds instant',
      );
    }
    if (verificationTimeMs > _kMaxVerificationTimeMs) {
      throw NtsError.invalidSpec(
        message:
            'verificationTime resolves to $verificationTimeMs ms, which '
            'exceeds $_kMaxVerificationTimeMs (9999-12-31T23:59:59Z); it '
            'must be a plausible epoch-milliseconds instant',
      );
    }
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

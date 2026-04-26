/// Authenticated Network Time Security (RFC 8915) for Dart and Flutter.
///
/// Exposes a Rust-backed NTS-KE + AEAD-NTP client through
/// `flutter_rust_bridge`. Call `RustLib.init()` once during app startup
/// before invoking any of the `nts*` entry points.
library;

// Bridge entrypoint. `RustLib.init()` must be awaited once during app
// startup before any `crateApi*` call is made.
export 'src/ffi/frb_generated.dart' show RustLib;

// Public NTS surface (RFC 8915) generated from `rust/src/api/nts.rs`.
// The `NtsError_*` variant subclasses are part of the public API: they are
// the runtime types produced by the FRB-generated freezed sealed class and
// downstream code needs them in scope to pattern-match exhaustively.
export 'src/ffi/api/nts.dart'
    show
        NtsServerSpec,
        NtsTimeSample,
        NtsError,
        NtsError_InvalidSpec,
        NtsError_Network,
        NtsError_KeProtocol,
        NtsError_NtpProtocol,
        NtsError_Authentication,
        NtsError_Timeout,
        NtsError_NoCookies,
        NtsError_Internal,
        ntsQuery,
        ntsWarmCookies;

// FRB toolchain smoke entry point. Used by `test/ffi_smoke_test.dart` and
// kept exported so the same path validates native-asset bundling later.
export 'src/ffi/api/simple.dart' show greet;

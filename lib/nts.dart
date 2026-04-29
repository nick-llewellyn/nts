/// Authenticated Network Time Security (RFC 8915) for Dart and Flutter.
///
/// Exposes a Rust-backed NTS-KE + AEAD-NTP client. Call `RustLib.init()`
/// once during app startup before invoking any of the `nts*` entry
/// points; `ntsQuery` and `ntsWarmCookies` then run a single
/// authenticated NTPv4 exchange or force a fresh handshake respectively.
///
/// The hand-written wrapper in `src/api/nts.dart` is the package's
/// stable public contract: the underlying Rust-side bindings live in
/// `src/ffi/` and are an internal implementation detail. See
/// `ARCHITECTURE.md`'s "Public API stability layer" for the rationale.
library;

// Bridge entrypoint. `RustLib.init()` must be awaited once during app
// startup before any `nts*` call is made; subsequent invocations are
// no-ops.
export 'src/ffi/frb_generated.dart' show RustLib;

// Public NTS surface (RFC 8915). The wrapper layer carries the
// dartdoc that consumers see and applies the package's default values
// for optional parameters; it forwards to the FRB-generated bindings
// for the actual FFI call.
export 'src/api/nts.dart';

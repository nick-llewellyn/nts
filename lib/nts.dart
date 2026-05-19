/// Authenticated Network Time Security (RFC 8915) for Dart and Flutter.
///
/// Exposes a Rust-backed NTS-KE + AEAD-NTP client. Initialization has
/// two independent layers; both must be in place before `ntsQuery` or
/// `ntsWarmCookies` is called:
///
/// 1. **Native platform bootstrap** — captures the platform-specific
///    handles (e.g. the Android `JavaVM` + application `Context` for
///    `rustls-platform-verifier`) so TLS 1.3 can validate against the
///    system trust store. On Android this happens automatically: the
///    bundled `NtsPlugin` runs from `GeneratedPluginRegistrant` before
///    Dart `main()`, so consumers do nothing. iOS/macOS/Linux/Windows
///    have no JVM-style bootstrap step. Hosts that bypass the standard
///    Flutter activity lifecycle (custom embeddings, isolates spawned
///    ahead of plugin registration) can call
///    `com.nllewellyn.nts.PlatformInit.init(context)` from Kotlin
///    directly.
/// 2. **Dart/FRB initialization** — `await NtsRustLib.init()` once during
///    startup before any `nts*` entry point. This loads the bundled
///    Rust dylib through the Native Assets pipeline and wires the
///    `flutter_rust_bridge` v2 dispatch table on the Dart isolate.
///    Mandatory on every platform; the plugin layer cannot perform
///    this step because it runs on the Android platform thread before
///    the Dart isolate exists. Subsequent calls are no-ops.
///
/// The hand-written wrapper in `src/api/nts.dart` is the package's
/// stable public contract: the underlying Rust-side bindings live in
/// `src/ffi/` and are an internal implementation detail. See
/// `ARCHITECTURE.md`'s "Public API stability layer" for the rationale.
library;

// Bridge entrypoint. `await NtsRustLib.init()` is mandatory on every
// platform: it loads the bundled Rust dylib via the Native Assets
// pipeline and binds the FRB v2 dispatch table on the calling isolate.
// The Android `NtsPlugin` does *not* subsume this step -- it only
// handles the JNI handle capture for `rustls-platform-verifier`, which
// is a separate concern that runs on the platform thread before Dart
// `main()` starts. Subsequent invocations are no-ops.
export 'src/ffi/frb_generated.dart' show NtsRustLib;

// Public NTS surface (RFC 8915). The wrapper layer carries the
// dartdoc that consumers see and applies the package's default values
// for optional parameters; it forwards to the FRB-generated bindings
// for the actual FFI call.
export 'src/api/nts.dart';

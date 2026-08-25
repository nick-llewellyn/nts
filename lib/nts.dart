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
/// 2. **Dart/FRB initialization** — `await NtsBridge.ensureInitialized()`
///    during startup, before any `nts*` entry point. This loads the
///    bundled Rust dylib through the Native Assets pipeline and wires
///    the `flutter_rust_bridge` v2 dispatch table on the Dart isolate.
///    Mandatory on every platform; the plugin layer cannot perform
///    this step because it runs on the Android platform thread before
///    the Dart isolate exists. Safe to call repeatedly and
///    concurrently: after the first call it completes without
///    re-initializing. The underlying `NtsRustLib.init()` rejects
///    repeat calls by contrast — it throws a `StateError` whenever the
///    entrypoint already holds state, which it does until
///    `NtsBridge.dispose()` clears it — so prefer the wrapper anywhere
///    more than one code path can reach the bootstrap.
///
/// The hand-written wrapper in `src/api/nts.dart` is the package's
/// stable public contract: the underlying Rust-side bindings live in
/// `src/ffi/` and are an internal implementation detail. See
/// `ARCHITECTURE.md`'s "Public API stability layer" for the rationale.
library;

// Bridge entrypoint. Initialization is mandatory on every platform: it
// loads the bundled Rust dylib via the Native Assets pipeline and binds
// the FRB v2 dispatch table on the calling isolate. The Android
// `NtsPlugin` does *not* subsume this step -- it only handles the JNI
// handle capture for `rustls-platform-verifier`, which is a separate
// concern that runs on the platform thread before Dart `main()` starts.
//
// The entrypoint is exported for callers that need to drive it
// directly -- supplying their own `externalLibrary:`, or relaxing
// `forceSameCodegenVersion:`. `NtsRustLib.init()` rejects a call made
// while the entrypoint holds state -- it throws a `StateError`, and
// only `NtsBridge.dispose()` clears that state again -- so ordinary
// consumers should use `NtsBridge.ensureInitialized()` below instead. Member dartdocs on the public API state that requirement as
// `NtsBridge.ensureInitialized()` accordingly; where they name
// `NtsRustLib.init()` it is as the underlying step, not as the
// recommended call.
//
// Tests that want a hand-written double use `NtsRustLib.initMock()`,
// not `init(api:)`. The `api:` parameter only substitutes the dispatch
// object: `init()` still loads a library through the Native Assets
// pipeline and still runs the content-hash check against it, so it is
// not a way to avoid the native side. `initMock()` installs the double
// without loading anything.
export 'src/ffi/frb_generated.dart' show NtsRustLib;

// Safe, idempotent lifecycle wrapper over the generated entrypoint,
// plus the `NtsBridgeState` predicate consumers need to tell an
// uninitialized bridge from a mock or a native one without reaching
// into FRB-internal members.
export 'src/api/bridge.dart';

// Public sleep-aware monotonic clock. A general-purpose primitive
// whose readings keep advancing across device deep sleep; the shared
// `MonotonicClock.instance` singleton is the same timeline the
// package uses internally for `NtsSyncedTime` projection and timeout
// budgets.
export 'src/api/clock.dart';

// Public NTS surface (RFC 8915). The wrapper layer carries the
// dartdoc that consumers see and applies the package's default values
// for optional parameters; it forwards to the FRB-generated bindings
// for the actual FFI call.
export 'src/api/nts.dart';

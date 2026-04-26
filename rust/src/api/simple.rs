// Smoke-test surface used to validate the FRB toolchain end-to-end.
// Removed once `nts.rs` carries a real round-trip.

/// Returns a greeting that round-trips a string across the FFI boundary.
///
/// Used by `test/ffi_smoke_test.dart` to verify codegen, native asset
/// bundling, and the Rust ↔ Dart marshalling layer are all wired up.
pub fn greet(name: String) -> String {
    format!("Hello, {name}, from nts_rust!")
}

/// Initialises FRB's panic + logging hooks for the current target.
///
/// Marked `#[frb(init)]` so the generated Dart side calls it automatically
/// the first time the bridge is loaded.
///
/// On non-iOS targets (Android, macOS host, desktop) this delegates to
/// `flutter_rust_bridge::setup_default_user_utils`, which installs
/// `android_logger` on Android and a panic backtrace hook everywhere.
/// On iOS we replace that helper with our own
/// [`crate::ios_init::init_logging`] so a `tracing-oslog` subscriber
/// can claim the global `log` slot under the
/// `com.nts.example` subsystem instead of FRB's generic
/// `frb_user` one — see [`crate::ios_init`] for the rationale. The
/// panic backtrace setup is still applied via the directly-exposed
/// `setup_backtrace` so iOS keeps parity with the other platforms.
#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    #[cfg(not(target_os = "ios"))]
    flutter_rust_bridge::setup_default_user_utils();

    #[cfg(target_os = "ios")]
    {
        flutter_rust_bridge::setup_backtrace();
        crate::ios_init::init_logging();
    }
}

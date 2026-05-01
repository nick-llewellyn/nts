// Bridge lifecycle hook. Carried in `api/` because FRB scans `crate::api`
// for `#[frb(init)]` items; relocating it would only swap one form of
// generated wiring for another. The function itself is unreachable from
// host-runner `cargo test --lib` runs (it fires when the dynamic library
// is loaded, which only happens on-device or via an integration test
// that links the dylib), so the file is excluded from coverage at the
// `.codecov.yml`, `rust/tarpaulin.toml`, and `ci.yml --exclude-files`
// layers — see `DEVELOPMENT.md` → "Coverage exclusion policy".

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

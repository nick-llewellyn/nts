// Crate root for `nts_rust`.
//
// Module layout:
// - `api`            — surface exposed across the FFI boundary to Dart.
// - `nts`            — internal RFC 8915 protocol layer (KE, NTPv4, AEAD).
//                      Not yet on the FFI surface; wired up in phase 3.
// - `frb_generated`  — produced by `flutter_rust_bridge_codegen generate`.
//                      Do not edit by hand; regenerate after changing `api/`.

pub mod api;
mod frb_generated;
pub(crate) mod nts;

// Re-exports the protocol parsers for cargo-fuzz harnesses in
// `rust/fuzz/`, gated behind the `__fuzzing` Cargo feature so the
// surface stays out of the published API. The `nts` module remains
// `pub(crate)` for ordinary builds; flipping `__fuzzing` re-exposes
// only the specific parser entry points that fuzz targets need to
// drive, not the whole module tree. See `rust/Cargo.toml::[features]`
// for the policy on enabling this flag (fuzz / coverage crates only).
#[cfg(feature = "__fuzzing")]
pub mod __fuzzing {
    pub use crate::nts::ntp::{parse_extensions, NtpError};
    pub use crate::nts::records::{parse_message, CodecError};
}

// Android-only: exports a JNI symbol that bootstraps `rustls-platform-verifier`
// against the Android system trust store. The matching Kotlin caller
// (`com.nllewellyn.nts.PlatformInit`) ships inside the `nts` Flutter
// plugin's Android library module (`<plugin>/android/`) and is invoked
// from `NtsPlugin.onAttachedToEngine` ahead of the Dart `main()`, before
// any FRB call can trigger a TLS handshake.
#[cfg(target_os = "android")]
pub mod android_init;

// iOS-only: installs a `tracing-oslog` subscriber so the crate's
// `tracing::*!` events and `log::*!` records (e.g. from `rustls`) reach
// Apple's unified logging system. Called once from `api::simple::init_app`
// in place of FRB's `setup_default_user_utils` on iOS — see the module
// docs for the rationale.
#[cfg(target_os = "ios")]
mod ios_init;

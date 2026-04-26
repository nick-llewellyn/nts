// Crate root for `nts_rust`.
//
// Module layout:
// - `api`            — surface exposed across the FFI boundary to Dart.
// - `nts`            — internal RFC 8915 protocol layer (KE, NTPv4, AEAD).
//                      Not yet on the FFI surface; wired up in phase 3.
// - `frb_generated`  — produced by `flutter_rust_bridge_codegen generate`.
//                      Do not edit by hand; regenerate after changing `api/`.

pub mod api;
pub(crate) mod nts;
mod frb_generated;

// Android-only: exports a JNI symbol that bootstraps `rustls-platform-verifier`
// against the Android system trust store. Called once from
// `MainActivity.onCreate` (see `RustlsBootstrap.kt` in the example app)
// before any FRB call can trigger a TLS handshake.
#[cfg(target_os = "android")]
pub mod android_init;

// iOS-only: installs a `tracing-oslog` subscriber so the crate's
// `tracing::*!` events and `log::*!` records (e.g. from `rustls`) reach
// Apple's unified logging system. Called once from `api::simple::init_app`
// in place of FRB's `setup_default_user_utils` on iOS — see the module
// docs for the rationale.
#[cfg(target_os = "ios")]
mod ios_init;

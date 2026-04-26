//! iOS-only: bridge `tracing` events and `log::*!` records into Apple's
//! unified logging system (`os_log`).
//!
//! This is the iOS counterpart to the Android logging path that ships
//! out of the box via `flutter_rust_bridge`'s `setup_default_user_utils`
//! (which installs `android_logger` on Android, surfacing every
//! `log::info!`/`warn!`/`error!` record under `logcat`).
//!
//! # Subsystem and category
//!
//! All events surface under the `os_log` subsystem
//! `com.nts.example` so a Console.app filter of
//! `process:Runner subsystem:com.nts.example` isolates the crate's
//! output from system noise. A single category (`nts`) is used
//! for the first iteration; per-module categories (`ke`, `ntp`,
//! `hybrid_verifier`, …) can be added later by registering additional
//! `OsLogger` layers with target filters when filtering pressure
//! justifies the extra wiring.
//!
//! # Why bypass `flutter_rust_bridge::setup_default_user_utils` on iOS
//!
//! That helper unconditionally calls
//! `oslog::OsLogger::new("frb_user").init()`, which claims the global
//! `log::set_logger` slot for the generic `frb_user` subsystem. Once
//! that slot is taken, `tracing_log::LogTracer::init` cannot install
//! the bridge that turns `log::*!` records (e.g. from `rustls`'s
//! `logging` feature) into `tracing` events — and our
//! `tracing-oslog` subscriber would only see direct `tracing::*!`
//! callers. Calling [`init_logging`] *instead of*
//! `setup_default_user_utils` on iOS sidesteps the conflict; we still
//! invoke `setup_backtrace` directly from `api::simple::init_app` so
//! the panic backtrace behaviour is unchanged across platforms.
//!
//! # Compile-time level stripping
//!
//! `Cargo.toml` enables both `log/release_max_level_warn` and
//! `tracing/release_max_level_warn`, so `trace!`/`debug!`/`info!` call
//! sites in either crate family are compiled away in release builds.
//! Only `warn!`/`error!` reach this subscriber in production binaries —
//! including the `nts::hybrid_verifier` Let's Encrypt R12 fallback
//! warning and any future error-level diagnostic.

use std::sync::Once;

use tracing_oslog::OsLogger;
use tracing_subscriber::layer::SubscriberExt;
use tracing_subscriber::util::SubscriberInitExt;

/// `os_log` subsystem string for every event emitted by this crate on iOS.
///
/// Mirrors the Android `logcat` tag prefix conceptually; chosen to match
/// the host application's reverse-DNS bundle convention so Console.app
/// filtering works without further configuration.
const SUBSYSTEM: &str = "com.nts.example";

/// `os_log` category attached to every event from the single subscriber.
///
/// See the module-level note on per-module categorisation: per-module
/// `OsLogger` layers can be added later when filtering pressure justifies
/// the extra wiring.
const DEFAULT_CATEGORY: &str = "nts";

/// Idempotency guard. The FRB-generated bridge calls `init_app` once on
/// first use, but a hot restart or a stray re-entrant call must not
/// double-install the subscriber (which would panic on the
/// `set_global_default` path).
static INIT: Once = Once::new();

/// Install the `tracing-oslog` subscriber and the `log → tracing`
/// bridge.
///
/// Safe to call multiple times: the actual setup runs at most once via
/// [`Once::call_once`]. The two underlying installers
/// (`LogTracer::init` and `tracing_subscriber::Registry::try_init`)
/// each return `Err` if a global has already been installed; both
/// errors are swallowed because they signal that someone else won the
/// race and the resulting state is acceptable for our purposes.
pub(crate) fn init_logging() {
    INIT.call_once(|| {
        // Forward every `log::Record` into the `tracing` event stream.
        // Must run before any `log::*!` macro in the crate or its
        // dependencies (`rustls` in particular) is invoked, so that
        // those records reach the subscriber installed below instead
        // of being dropped on the floor.
        let _ = tracing_log::LogTracer::init();

        // Single-subscriber registry with one `OsLogger` layer. The
        // `Registry` keeps the door open for adding further layers
        // (e.g. per-module categories or a `fmt::Layer` during
        // `cargo test` runs) without restructuring the init path.
        let registry = tracing_subscriber::registry()
            .with(OsLogger::new(SUBSYSTEM, DEFAULT_CATEGORY));
        if registry.try_init().is_ok() {
            // Smoke-test event: confirms the chain end-to-end the
            // first time the bridge is loaded. Visible in Console.app
            // under the configured subsystem.
            tracing::info!(
                target: "nts_rust::ios_init",
                subsystem = SUBSYSTEM,
                category = DEFAULT_CATEGORY,
                "tracing-oslog subscriber attached",
            );
        }
    });
}

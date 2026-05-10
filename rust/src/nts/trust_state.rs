//! Process-global trust-anchor diagnostic state.
//!
//! Records three observables that callers cannot recover from a
//! per-query [`crate::api::nts::NtsTimeSample`] alone:
//!
//! 1. The trust backend the *default singleton* [`crate::api::nts::NtsClient`]
//!    most recently resolved to. Custom-client callers read the
//!    per-handshake `trust_backend` field on `NtsTimeSample` /
//!    `NtsWarmCookiesOutcome` for accurate per-client attribution; this
//!    counter exists for the singleton-path callers exposed via
//!    [`crate::api::nts::nts_query`] / [`crate::api::nts::nts_warm_cookies`]
//!    who never construct an `NtsClient` themselves.
//!
//! 2. Whether `Java_com_nllewellyn_nts_PlatformInit_nativeInit` has been
//!    invoked at least once and reported success on Android. The flag
//!    only flips false → true; once set it stays set for the rest of
//!    the process lifetime, matching the latched `OnceCell` semantics
//!    of `rustls_platform_verifier::android::init_with_env`.
//!
//! 3. Cumulative count of TLS chains the Android
//!    [`crate::nts::hybrid_verifier::HybridVerifier`] has accepted via
//!    its `webpki-roots` fallback path since process start. Bumped by
//!    every `verify_server_cert` call that overrides a platform
//!    verdict; never reset.
//!
//! All three counters use atomic `Relaxed` loads/stores: the snapshot
//! returned by [`crate::api::nts::nts_trust_status`] is intended for
//! human / dashboard consumption, not for cross-thread synchronisation.
//! Per-counter monotonicity holds (the platform-init flag never
//! re-clears, the fallback counter never decreases), but cross-counter
//! invariants within a single snapshot do not — e.g. the snapshot can
//! observe a hybrid-fallback bump that happened slightly after the
//! default-backend store the same handshake produced.

use std::sync::atomic::{AtomicBool, AtomicU64, AtomicU8, Ordering};

const BACKEND_UNSET: u8 = 0;
const BACKEND_PLATFORM: u8 = 1;
const BACKEND_PLATFORM_WITH_HYBRID_FALLBACK: u8 = 2;
const BACKEND_WEBPKI_ROOTS: u8 = 3;

/// Local mirror of [`crate::api::nts::TrustBackend`] used only as the
/// argument to [`ProcessTrustState::record_default_backend`]. The
/// public enum lives in `api::nts` so it can be FRB-mirrored into
/// Dart; this enum exists in the protocol-internal `nts` module so
/// the trust-state recording path does not introduce a circular
/// dependency on the public API surface.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum InternalTrustBackend {
    Platform,
    PlatformWithHybridFallback,
    WebpkiRoots,
}

/// Snapshot returned by [`ProcessTrustState::snapshot`]. Mapped into
/// [`crate::api::nts::NtsTrustStatus`] by the public-API layer, which
/// owns the `Option<TrustBackend>` translation for the unset state.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct TrustStateSnapshot {
    pub(crate) default_backend: Option<InternalTrustBackend>,
    pub(crate) android_platform_init_succeeded: bool,
    pub(crate) android_hybrid_fallback_count: u64,
}

pub(crate) struct ProcessTrustState {
    default_backend: AtomicU8,
    android_platform_init_succeeded: AtomicBool,
    android_hybrid_fallback_count: AtomicU64,
}

impl ProcessTrustState {
    const fn new() -> Self {
        Self {
            default_backend: AtomicU8::new(BACKEND_UNSET),
            android_platform_init_succeeded: AtomicBool::new(false),
            android_hybrid_fallback_count: AtomicU64::new(0),
        }
    }

    /// Record the trust backend resolved by the *default singleton*
    /// `NtsClient`'s most recent handshake. Called from the public-API
    /// `nts_query_inner` / `nts_warm_cookies_inner` paths only when
    /// the calling client is the process-wide default; custom-client
    /// handshakes do not touch this counter so a multi-client
    /// deployment can distinguish singleton vs non-singleton attribution.
    pub(crate) fn record_default_backend(&self, b: InternalTrustBackend) {
        let v = match b {
            InternalTrustBackend::Platform => BACKEND_PLATFORM,
            InternalTrustBackend::PlatformWithHybridFallback => {
                BACKEND_PLATFORM_WITH_HYBRID_FALLBACK
            }
            InternalTrustBackend::WebpkiRoots => BACKEND_WEBPKI_ROOTS,
        };
        self.default_backend.store(v, Ordering::Relaxed);
    }

    /// Latch the Android JNI bootstrap flag. Idempotent; the flag
    /// only ever flips false → true so a second call after a
    /// successful first call is a no-op store. The
    /// `Java_com_nllewellyn_nts_PlatformInit_nativeInit` JNI symbol
    /// calls this exactly once per successful
    /// `rustls_platform_verifier::android::init_with_env` call.
    pub(crate) fn record_android_init_success(&self) {
        self.android_platform_init_succeeded
            .store(true, Ordering::Relaxed);
    }

    /// Bump the Android hybrid-verifier fallback counter. Called from
    /// `HybridVerifier::verify_server_cert` every time the
    /// `webpki-roots` fallback overrides a platform verdict.
    pub(crate) fn bump_hybrid_fallback(&self) {
        self.android_hybrid_fallback_count
            .fetch_add(1, Ordering::Relaxed);
    }

    pub(crate) fn snapshot(&self) -> TrustStateSnapshot {
        let default_backend = match self.default_backend.load(Ordering::Relaxed) {
            BACKEND_PLATFORM => Some(InternalTrustBackend::Platform),
            BACKEND_PLATFORM_WITH_HYBRID_FALLBACK => {
                Some(InternalTrustBackend::PlatformWithHybridFallback)
            }
            BACKEND_WEBPKI_ROOTS => Some(InternalTrustBackend::WebpkiRoots),
            _ => None,
        };
        TrustStateSnapshot {
            default_backend,
            android_platform_init_succeeded: self
                .android_platform_init_succeeded
                .load(Ordering::Relaxed),
            android_hybrid_fallback_count: self
                .android_hybrid_fallback_count
                .load(Ordering::Relaxed),
        }
    }
}

pub(crate) static TRUST_STATE: ProcessTrustState = ProcessTrustState::new();

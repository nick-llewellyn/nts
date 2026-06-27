//! NTS public API surface (RFC 8915).
//!
//! Two top-level convenience functions exercise the protocol across the
//! FRB v2 worker pool:
//!
//! - `nts_query` (`ntsQuery` on the Dart side) runs a full
//!   Authenticated NTPv4 exchange and returns a `NtsTimeSample`. It
//!   performs an NTS-KE handshake on demand if no cached session
//!   exists or the cookie pool is exhausted.
//! - `nts_warm_cookies` (`ntsWarmCookies` on the Dart side) forces a
//!   fresh NTS-KE handshake and ingests the delivered cookie pool
//!   without sending any NTP traffic.
//!
//! Both convenience functions delegate to a process-wide default
//! `NtsClient` via a private `default_nts_client()` accessor; callers
//! that need scoped session ownership construct their own `NtsClient`
//! and call its `query` / `warm_cookies` methods directly. The
//! `NtsClient` handle additionally exposes a synchronous default
//! constructor (`NtsClient()` on the Dart side) plus synchronous
//! `invalidate(spec)` / `clear()` cache mutators marked
//! `#[flutter_rust_bridge::frb(sync)]` so callers can drop sessions
//! without paying an isolate-hop round-trip. Each `NtsClient` owns
//! one private `SessionTable` — a `Mutex<HashMap<String, Session>>`
//! keyed by `host:port` — and that table is the only persistent
//! NTS-protocol state the bridge maintains. Two `NtsClient`
//! instances never share table state with each other or with the
//! process-wide default.
//!
//! `nts_dns_pool_stats` (`ntsDnsPoolStats` on the Dart side) is also
//! exposed from this module as a synchronous diagnostic snapshot of
//! the bounded DNS resolver counters in `crate::nts::dns`; it is
//! orthogonal to the per-host session table that `NtsClient` owns
//! and is unaffected by the per-client refactor.

use std::collections::{HashMap, HashSet, VecDeque};
use std::net::{SocketAddr, UdpSocket};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, OnceLock};
use std::time::{Duration, Instant};

use rustls::pki_types::UnixTime;
use zeroize::Zeroizing;

use crate::nts::aead::{AeadError, AeadKey};
use crate::nts::cookies::CookieJar;
use crate::nts::dns::{resolve_with_global, system_lookup, DEFAULT_MAX_INFLIGHT_DNS_LOOKUPS};
use crate::nts::ke::{
    perform_handshake, KeError, KeFailure, KeOutcome, KePhaseTimings, KeRequest, KeTimeoutPhase,
    KeTrustMode, OFFERED_AEAD_IDS,
};
use crate::nts::ntp::{build_client_request, parse_server_response, ClientRequest, NtpError};

/// IANA-assigned NTS-KE port (RFC 8915 §6).
pub const DEFAULT_KE_PORT: u16 = 4460;

/// Default UDP/TLS timeout when the caller passes 0.
const DEFAULT_TIMEOUT_MS: u32 = 5_000;

/// Per-packet Unique Identifier length (RFC 8915 §5.3 recommends 32).
const UID_LEN: usize = 32;

/// Request one fresh cookie back per query so the pool stays topped off.
const PLACEHOLDERS_PER_QUERY: usize = 1;

/// Difference between the NTP epoch (1900-01-01) and the Unix epoch (1970-01-01).
const NTP_TO_UNIX_EPOCH_SECS: u64 = 2_208_988_800;

/// Defensive ceiling for a caller-supplied `verification_time_ms`, set to
/// `9999-12-31T23:59:59Z` in epoch milliseconds. Any plausible clock-skew
/// override lands far below this; values above it cannot denote a real
/// instant and are rejected before reaching the `Duration::from_millis`
/// conversion in `establish_session`, keeping the security-relevant time
/// path away from implausible inputs.
const MAX_VERIFICATION_TIME_MS: i64 = 253_402_300_799_000;

/// Address of an NTS-KE endpoint.
#[derive(Debug, Clone)]
pub struct NtsServerSpec {
    /// Hostname for TLS SNI and certificate validation.
    pub host: String,
    /// TCP port; pass `4460` (the IANA-assigned NTS-KE default, RFC 8915 §6)
    /// unless the deployment overrides it.
    pub port: u16,
}

/// Phase of an `nts_query` (Dart: `ntsQuery`) or `nts_warm_cookies`
/// (Dart: `ntsWarmCookies`) call whose wall-clock budget elapsed.
///
/// Carried as the payload of [`NtsError`]'s `Timeout` variant so
/// callers can attribute a failure to a specific pre-NTP step
/// instead of inspecting free-form diagnostic strings. The
/// Rust-side KE-pipeline taxonomy (`KeTimeoutPhase`, internal to
/// the crate) maps onto this enum via `From`; the `Ntp` variant
/// is added at this layer for the UDP send/recv phase, and the
/// two `Dns*` variants distinguish saturation (cap full) from
/// timeout (resolver slow). See `ARCHITECTURE.md`'s "Phase
/// attribution and timings" section for the full diagnostic
/// shape.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TimeoutPhase {
    /// Bounded DNS resolver pool was already at capacity when the call
    /// arrived, so admission was refused without spawning a worker.
    /// Distinct from `DnsTimeout`: raising
    /// `dns_concurrency_cap` or waiting for the in-flight pool to
    /// drain is the appropriate remediation, not lengthening
    /// `timeout_ms`.
    DnsSaturation,
    /// System resolver took longer than the remaining budget.
    /// Lengthening `timeout_ms` *or* swapping in a faster recursive
    /// resolver are the appropriate remediations; raising the
    /// concurrency cap would only allow more threads to wedge in the
    /// same lookup.
    DnsTimeout,
    /// Per-address `TcpStream::connect_timeout` budget elapsed before
    /// any KE-host candidate accepted, or the global deadline expired
    /// before the connect loop could try the next address.
    Connect,
    /// TLS handshake / initial NTS-KE request write tripped the
    /// deadline. In TLS 1.3 the first write is what completes the
    /// ClientHello/ServerHello/Finished round-trip.
    Tls,
    /// Read of the NTS-KE response records exceeded the remaining
    /// budget — the server completed TLS but is now drip-feeding (or
    /// has stalled completely on) the record exchange.
    KeRecordIo,
    /// AEAD-NTPv4 UDP `send` / `recv` exceeded the remaining budget.
    /// Either the destination is unreachable or the wire round-trip
    /// time was too long for the configured budget.
    Ntp,
}

impl From<KeTimeoutPhase> for TimeoutPhase {
    fn from(p: KeTimeoutPhase) -> Self {
        match p {
            KeTimeoutPhase::DnsSaturation => Self::DnsSaturation,
            KeTimeoutPhase::DnsTimeout => Self::DnsTimeout,
            KeTimeoutPhase::Connect => Self::Connect,
            KeTimeoutPhase::Tls => Self::Tls,
            KeTimeoutPhase::KeRecordIo => Self::KeRecordIo,
        }
    }
}

/// Microsecond-resolution wall-clock breakdown of a successful
/// `nts_query` (Dart: `ntsQuery`) or `nts_warm_cookies`
/// (Dart: `ntsWarmCookies`) call, surfaced on the `phase_timings`
/// field of [`NtsTimeSample`] / [`NtsWarmCookiesOutcome`] (Dart:
/// `phaseTimings`).
///
/// Field semantics match the internal `KePhaseTimings` for the
/// four KE-pipeline phases. The UDP send/recv phase has no field
/// of its own; `round_trip_micros` (Dart: `roundTripMicros`) on
/// [`NtsTimeSample`] already covers it (kept for
/// backward-compatibility on the Dart side and to avoid
/// publishing the same fact in two fields). Callers who want a
/// "preNtp" wall-clock view can sum
/// `dns_micros + connect_micros + tls_handshake_micros +
/// ke_record_io_micros`; the per-call total wall-clock is that sum
/// plus `round_trip_micros`.
///
/// Phases that did not run are reported as `0` rather than absent —
/// e.g. on a cache-hit query (no KE handshake), `connect_micros`,
/// `tls_handshake_micros`, and `ke_record_io_micros` are all `0` and
/// `dns_micros` reflects only the UDP-path lookup of the NTPv4 host.
/// On a fresh-session query both KE-path and UDP-path DNS lookups
/// run; their costs are summed into a single `dns_micros` value so
/// callers do not have to reason about which path contributed.
#[derive(Debug, Clone, Copy, Default)]
pub struct PhaseTimings {
    /// Sum of wall-clock microseconds spent in the bounded DNS
    /// resolver across both the KE-host lookup (when a handshake
    /// runs) and the NTPv4-host lookup. Combined into a single
    /// field because callers diagnosing slow DNS care about the
    /// host-level cost regardless of which leg consumed it. See
    /// `ARCHITECTURE.md`'s "Timeout budget and bounded DNS"
    /// section for the resolver semantics.
    pub dns_micros: i64,
    /// Wall-clock microseconds spent in the per-address
    /// `TcpStream::connect_timeout` loop during the KE handshake.
    /// `0` on cache-hit queries.
    pub connect_micros: i64,
    /// Wall-clock microseconds spent on the rustls
    /// `Stream::write_all` + `flush` window during the KE handshake.
    /// In TLS 1.3 this includes the ClientHello/ServerHello/Finished
    /// round-trip plus the initial NTS-KE request write. `0` on
    /// cache-hit queries.
    pub tls_handshake_micros: i64,
    /// Wall-clock microseconds spent in the chunked record-read loop
    /// reading the server's NTS-KE response. `0` on cache-hit queries.
    pub ke_record_io_micros: i64,
}

impl From<KePhaseTimings> for PhaseTimings {
    fn from(t: KePhaseTimings) -> Self {
        Self {
            dns_micros: t.dns_micros,
            connect_micros: t.connect_micros,
            tls_handshake_micros: t.tls_handshake_micros,
            ke_record_io_micros: t.ke_record_io_micros,
        }
    }
}

/// Successful authenticated NTPv4 sample.
///
/// This is the raw output of one protocol exchange, not a synchronized
/// clock. See `nts_query` (Dart: `ntsQuery`) for the recommended
/// burst-and-RTT-compensation pattern callers should layer on top.
#[derive(Debug, Clone)]
pub struct NtsTimeSample {
    /// Server transmit time as microseconds since the Unix epoch, taken
    /// directly from the NTPv4 reply. No correction for the one-way
    /// network delay between the server and this caller is applied; add
    /// `round_trip_micros / 2` to estimate the server's clock at the
    /// moment the reply arrived.
    pub utc_unix_micros: i64,
    /// Wall-clock microseconds elapsed between the AEAD-NTPv4 UDP
    /// `send` and the matching `recv`. This *is* the UDP-phase
    /// wall-clock cost — there is no separate `udp_send_recv_micros`
    /// in [`PhaseTimings`] because that would publish the same fact
    /// in two fields.
    pub round_trip_micros: i64,
    /// NTP stratum reported by the server (RFC 5905 §7.3).
    pub server_stratum: u8,
    /// AEAD algorithm IANA ID negotiated during NTS-KE.
    pub aead_id: u16,
    /// Number of fresh cookies recovered from the encrypted reply.
    pub fresh_cookies: u32,
    /// Microsecond-resolution wall-clock breakdown of the pre-NTP
    /// phases of this call. Combined with `round_trip_micros`
    /// (Dart: `roundTripMicros`) it accounts for the entire
    /// wall-clock cost of `nts_query` (Dart: `ntsQuery`).
    pub phase_timings: PhaseTimings,
    /// Trust-anchor backend that authenticated this query's TLS
    /// chain. On the fresh-KE path reflects the just-completed
    /// handshake's resolution; on the steady-state cached-session
    /// path reflects the *original* handshake's value (cached on
    /// the underlying `Session`), so callers always see a concrete
    /// per-query attribution rather than a placeholder for cached
    /// queries. New in 3.0.0; mirrors the per-query observable
    /// pattern established by `phase_timings`.
    pub trust_backend: TrustBackend,
}

/// Successful outcome of `nts_warm_cookies` (Dart: `ntsWarmCookies`).
///
/// Replaces the prior bare `u32` return so the same phase-attribution
/// view available on [`NtsTimeSample`] is also available for the
/// handshake-only path callers use to refill an empty cookie pool.
#[derive(Debug, Clone)]
pub struct NtsWarmCookiesOutcome {
    /// Number of fresh cookies the server delivered with the KE response.
    pub fresh_cookies: u32,
    /// Microsecond-resolution wall-clock breakdown of the handshake
    /// that produced the cookies. The UDP NTP exchange is not part
    /// of this call, so `dns_micros` (Dart: `dnsMicros`) reflects
    /// only the KE-host lookup.
    pub phase_timings: PhaseTimings,
    /// Trust-anchor backend that authenticated this handshake's TLS
    /// chain. `nts_warm_cookies` always runs a fresh KE handshake
    /// (no cached-session short-circuit), so the value is always
    /// the just-completed handshake's resolution. New in 3.0.0.
    pub trust_backend: TrustBackend,
}

/// Snapshot of the bounded DNS resolver pool counters.
///
/// All counters are process-wide and include workers spawned by every
/// concurrent caller, including those that passed a different
/// `dns_concurrency_cap` (the underlying pool is shared by design — see
/// the `nts::dns` module docs for the global-counter rationale). The
/// snapshot is racy by construction: each counter is read with an
/// independent atomic `Relaxed` load, so combinations across counters
/// can be slightly stale — e.g. `in_flight` lagging `recovered` by one
/// bump, or `in_flight > high_water_mark` for the few-nanosecond
/// window between a worker's admission `fetch_add` on `in_flight` and
/// the subsequent `fetch_max` on `high_water_mark` in
/// `try_acquire_slot`. The actual guarantee is per-counter
/// monotonicity in each counter's natural direction (cumulative
/// counters and `high_water_mark` never decrease across consecutive
/// snapshots; every loaded value is one the counter actually held at
/// some real moment), not a cross-counter invariant within a single
/// snapshot. The snapshot does not reset cumulative counters; callers
/// that want windowed measurements snapshot at `t0` and `t1` and
/// subtract.
///
/// Operators can use the four counters to distinguish three failure
/// modes that all collapse onto `NtsError::Timeout` in the hot-path
/// error contract:
///
/// - **Healthy resolver, occasional bursts** — `in_flight` oscillates
///   below the cap, `high_water_mark` plateaus a few steps above
///   steady state, `recovered` climbs in lockstep with traffic,
///   `refused` stays flat.
/// - **Cap-bound deployment** — `refused` is climbing; raising the
///   `dns_concurrency_cap` argument on `nts_query` /
///   `nts_warm_cookies` would lower the timeout error rate.
/// - **libc-level resolver wedge** — `in_flight` is pinned at the
///   cap, `recovered` is flat, `refused` is climbing. The system
///   resolver is not making progress; raising the cap would only push
///   more threads into the same wedge.
#[derive(Debug, Clone)]
pub struct NtsDnsPoolStats {
    /// Live count of resolver workers currently pinned in the system
    /// resolver. The next admission decision will compare its `cap`
    /// argument against this number.
    pub in_flight: u32,
    /// Largest value `in_flight` has reached since process start, as
    /// published by the `fetch_max` in `try_acquire_slot` after each
    /// successful admission. Non-decreasing across consecutive
    /// snapshots, but **not** a cross-counter invariant within a
    /// single snapshot: see the struct-level note on the transient
    /// window where `in_flight > high_water_mark` between a worker's
    /// admission increment and the subsequent `fetch_max`.
    pub high_water_mark: u32,
    /// Cumulative count of detached workers that have completed and
    /// released their slot since process start. `u64` because the
    /// counter grows monotonically over a process lifetime and a
    /// 32-bit wraparound would be visible on long-running CLI / server
    /// builds with a saturated resolver.
    pub recovered: u64,
    /// Cumulative count of admission attempts that were refused
    /// because the cap was reached since process start. The expected
    /// delta when the resolver is healthy is zero.
    pub refused: u64,
}

/// Snapshot the bounded DNS resolver pool counters. Reads four atomics
/// with `Relaxed` ordering; the snapshot is intended for
/// human / dashboard consumption, not for synchronisation. See
/// [`NtsDnsPoolStats`] for the diagnostic signatures and
/// `ARCHITECTURE.md`'s "Timeout budget and bounded DNS" section for
/// the operational shape.
///
/// Marked `#[frb(sync)]` so reading four atomics does not pay the
/// future-marshalling overhead a default FRB binding would impose;
/// the function is cheap enough to call from a UI poll loop without
/// thinking about isolate hops.
#[flutter_rust_bridge::frb(sync)]
pub fn nts_dns_pool_stats() -> NtsDnsPoolStats {
    let snap = crate::nts::dns::pool_snapshot();
    NtsDnsPoolStats {
        in_flight: snap.in_flight as u32,
        high_water_mark: snap.high_water_mark as u32,
        recovered: snap.recovered,
        refused: snap.refused,
    }
}

/// Snapshot the process-global trust-anchor diagnostic state.
///
/// Returns seven observables that callers cannot recover from a
/// per-query [`NtsTimeSample`] alone:
///
/// 1. `default_client_backend` — backend the *default singleton*
///    [`NtsClient`] (the one used by [`nts_query`] and
///    [`nts_warm_cookies`]) most recently resolved to. `None` when
///    no handshake has run yet against the singleton (process just
///    started, or all queries so far went through caller-minted
///    clients). This is an overwrite-on-store event marker, not a
///    steady-state signal: callers that want trend visibility
///    should read the four counters in (2)–(5) instead, since a
///    transient `WebpkiRoots`-resolving handshake will latch this
///    field permanently until the next `Platform`-resolving one.
///    Custom-client callers should read the per-handshake
///    `trust_backend` field on [`NtsTimeSample`] /
///    [`NtsWarmCookiesOutcome`] for accurate per-client attribution
///    instead.
/// 2. `default_backend_platform_count` — cumulative count of
///    singleton handshakes that resolved to [`TrustBackend::Platform`].
/// 3. `default_backend_hybrid_count` — cumulative count of
///    singleton handshakes that resolved to
///    [`TrustBackend::PlatformWithHybridFallback`]. Always zero on
///    non-Android platforms (the fallback path only exists on Android).
/// 4. `default_backend_webpki_count` — cumulative count of
///    singleton handshakes that resolved to [`TrustBackend::WebpkiRoots`].
/// 5. `default_backend_custom_count` — cumulative count of
///    singleton handshakes that resolved to [`TrustBackend::Custom`].
/// 6. `android_platform_init_succeeded` — `true` iff
///    `com.nllewellyn.nts.PlatformInit.nativeInit` reported success
///    at least once. `false` on every other platform. A `false` value
///    on Android implies subsequent handshakes will run against the
///    `webpki-roots` static bundle regardless of [`TrustMode`].
/// 7. `android_hybrid_fallback_count` — cumulative count of TLS
///    chains the Android `HybridVerifier` has accepted via the
///    `webpki-roots` fallback path. Always zero on non-Android
///    platforms. The curated fallback-eligible failure shapes are
///    documented on the `HybridVerifier` Rust source.
///
/// Reads seven atomics with `Relaxed` ordering. The snapshot is
/// intended for human / dashboard consumption, not for cross-thread
/// synchronisation; per-counter monotonicity holds, but cross-counter
/// invariants within a single snapshot do not — e.g. the sum of the
/// four `default_backend_*_count` fields can be observed to lag the
/// `default_client_backend` pointer by a single store-pair across
/// concurrent snapshots.
///
/// Marked `#[frb(sync)]` for the same reason as
/// [`nts_dns_pool_stats`]: the underlying state read is cheap enough
/// that paying isolate-hop overhead would dominate the call.
#[flutter_rust_bridge::frb(sync)]
pub fn nts_trust_status() -> NtsTrustStatus {
    let snap = crate::nts::trust_state::TRUST_STATE.snapshot();
    NtsTrustStatus {
        default_client_backend: snap.default_backend.map(TrustBackend::from),
        default_backend_platform_count: snap.default_backend_platform_count,
        default_backend_hybrid_count: snap.default_backend_hybrid_count,
        default_backend_webpki_count: snap.default_backend_webpki_count,
        default_backend_custom_count: snap.default_backend_custom_count,
        android_platform_init_succeeded: snap.android_platform_init_succeeded,
        android_hybrid_fallback_count: snap.android_hybrid_fallback_count,
    }
}

/// Trust-anchor backend that authenticated a TLS chain, or that a
/// process-global resolution attempt landed on.
///
/// Carried per-handshake on [`NtsTimeSample`] / [`NtsWarmCookiesOutcome`]
/// and process-globally on [`NtsTrustStatus`]. See `ARCHITECTURE.md`'s
/// "Trust-anchor diagnostics" section for the operational shape.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum TrustBackend {
    /// `rustls-platform-verifier` ran against the OS trust store
    /// (system roots plus any user / MDM-installed roots). Source of
    /// truth for enterprise-managed devices and the only way to honour
    /// pinned corporate CAs.
    Platform,
    /// Android-only: the platform verifier ran first, but its result
    /// was overridden by the `webpki-roots` fallback inside
    /// `HybridVerifier` for one of the curated platform-failure shapes
    /// documented there (missing-OCSP-AIA chains such as Let's Encrypt
    /// R12, R8-stripped AAR classes). Indicates the platform verifier's
    /// view was rejected and the static bundle was authoritative for
    /// this chain.
    PlatformWithHybridFallback,
    /// `build_with_native_verifier` failed at TLS-config construction
    /// time and the static `webpki-roots` bundle authenticated the
    /// chain end-to-end. Loses visibility into MDM / user-installed
    /// roots; works against the major public NTS providers but not
    /// against corporate TLS-inspection appliances. See
    /// [`TrustMode::PlatformOnly`] for the opt-in that surfaces this
    /// path as [`NtsError::TrustBackendUnavailable`] instead.
    WebpkiRoots,
    /// Caller-supplied custom root certificates authenticated this chain.
    Custom,
}

/// Caller-selected policy for which trust-anchor backend [`NtsClient`]
/// is willing to run against. Set immutably at client construction and
/// applied to every handshake the client initiates.
///
/// The default singleton client used by the top-level convenience
/// functions ([`nts_query`], [`nts_warm_cookies`]) is constructed with
/// [`TrustMode::PlatformWithFallback`] and never changes, so existing
/// callers see no behaviour change.
#[derive(Clone, PartialEq, Eq, Hash)]
pub enum TrustMode {
    /// Platform store is the primary source of truth; on
    /// `build_with_native_verifier` failure the client silently
    /// downgrades to the `webpki-roots` static bundle. Default mode
    /// for the top-level convenience functions and for
    /// [`NtsClient::new`].
    PlatformWithFallback,
    /// Refuses every silent fallback to the `webpki-roots` static
    /// bundle. Use when a pinned corporate CA or an MDM-installed
    /// root is the load-bearing trust anchor and a silent downgrade
    /// to a static bundle would defeat the deployment's
    /// TLS-inspection posture.
    ///
    /// Two distinct surfaces are gated:
    ///
    /// 1. **Build-time** (3.0.0): `build_with_native_verifier`
    ///    failure surfaces as [`NtsError::TrustBackendUnavailable`]
    ///    rather than constructing a `webpki-roots` config.
    /// 2. **Per-chain** on Android (4.0.0, BREAKING): the
    ///    `HybridVerifier` no longer retries against `webpki-roots`
    ///    for the two curated fallback-eligible failure shapes
    ///    (missing-OCSP-AIA chains such as Let's Encrypt R12, and
    ///    R8-stripped `org.rustls.platformverifier.*` JNI failures).
    ///    Both arms now propagate the platform verifier's error
    ///    verbatim. As a result, a `PlatformOnly` Android caller
    ///    will *never* observe
    ///    [`TrustBackend::PlatformWithHybridFallback`]; that backend
    ///    is reachable only via [`TrustMode::PlatformWithFallback`]
    ///    (the historic default), where both fallback arms continue
    ///    to fire as in 3.0.x.
    PlatformOnly,
    /// Webpki-roots static bundle only; no platform-store consultation at all.
    BundledOnly,
    /// Caller-supplied custom root certificates in PEM or DER format.
    Custom(Vec<u8>),
}

impl std::fmt::Debug for TrustMode {
    /// Manual `Debug` that redacts the `Custom` root bytes.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::PlatformWithFallback => f.write_str("PlatformWithFallback"),
            Self::PlatformOnly => f.write_str("PlatformOnly"),
            Self::BundledOnly => f.write_str("BundledOnly"),
            Self::Custom(bytes) => {
                write!(f, "Custom(<REDACTED: {} bytes>)", bytes.len())
            }
        }
    }
}

impl From<TrustMode> for crate::nts::ke::KeTrustMode {
    fn from(m: TrustMode) -> Self {
        match m {
            TrustMode::PlatformWithFallback => Self::PlatformWithFallback,
            TrustMode::PlatformOnly => Self::PlatformOnly,
            TrustMode::BundledOnly => Self::BundledOnly,
            // One-time `Vec<u8>` → `CustomRootsBytes` conversion at the
            // public-API boundary.
            TrustMode::Custom(bytes) => Self::Custom(crate::nts::ke::CustomRootsBytes::new(bytes)),
        }
    }
}

impl From<crate::nts::ke::KeTrustMode> for TrustMode {
    fn from(m: crate::nts::ke::KeTrustMode) -> Self {
        match m {
            crate::nts::ke::KeTrustMode::PlatformWithFallback => Self::PlatformWithFallback,
            crate::nts::ke::KeTrustMode::PlatformOnly => Self::PlatformOnly,
            crate::nts::ke::KeTrustMode::BundledOnly => Self::BundledOnly,
            // `CustomRootsBytes` → `Vec<u8>` materialization for the public
            // FRB-marshaled wire type. Only the `NtsClient::trust_mode`
            // getter calls this; the per-`query`/per-handshake hot
            // paths stay on `KeTrustMode` and never reach here.
            crate::nts::ke::KeTrustMode::Custom(bytes) => Self::Custom(bytes.as_slice().to_vec()),
        }
    }
}

impl From<crate::nts::ke::KeTrustBackend> for TrustBackend {
    fn from(b: crate::nts::ke::KeTrustBackend) -> Self {
        match b {
            crate::nts::ke::KeTrustBackend::Platform => Self::Platform,
            crate::nts::ke::KeTrustBackend::PlatformWithHybridFallback => {
                Self::PlatformWithHybridFallback
            }
            crate::nts::ke::KeTrustBackend::WebpkiRoots => Self::WebpkiRoots,
            crate::nts::ke::KeTrustBackend::Custom => Self::Custom,
        }
    }
}

impl From<TrustBackend> for crate::nts::trust_state::InternalTrustBackend {
    fn from(b: TrustBackend) -> Self {
        match b {
            TrustBackend::Platform => Self::Platform,
            TrustBackend::PlatformWithHybridFallback => Self::PlatformWithHybridFallback,
            TrustBackend::WebpkiRoots => Self::WebpkiRoots,
            TrustBackend::Custom => Self::Custom,
        }
    }
}

impl From<crate::nts::trust_state::InternalTrustBackend> for TrustBackend {
    fn from(b: crate::nts::trust_state::InternalTrustBackend) -> Self {
        match b {
            crate::nts::trust_state::InternalTrustBackend::Platform => Self::Platform,
            crate::nts::trust_state::InternalTrustBackend::PlatformWithHybridFallback => {
                Self::PlatformWithHybridFallback
            }
            crate::nts::trust_state::InternalTrustBackend::WebpkiRoots => Self::WebpkiRoots,
            crate::nts::trust_state::InternalTrustBackend::Custom => Self::Custom,
        }
    }
}

/// Process-global trust-anchor diagnostic snapshot returned by
/// [`nts_trust_status`] (Dart: `ntsTrustStatus`).
///
/// The fields combine one overwrite-on-store event marker (which
/// backend the default singleton client *most recently* resolved
/// to), four cumulative counters that partition the singleton's
/// resolution history by backend
/// (`default_backend_platform_count`,
/// `default_backend_hybrid_count`, `default_backend_webpki_count`,
/// `default_backend_custom_count`), a static flag indicating
/// whether the Android JNI bootstrap succeeded, and one
/// Android-only fallback counter. Fields not relevant to the
/// current platform are reported with the documented "n/a"
/// sentinel rather than omitted, so the snapshot has the same
/// shape on every host.
#[derive(Debug, Clone)]
pub struct NtsTrustStatus {
    /// Backend the default singleton client most recently resolved to
    /// at handshake time. `None` when no handshake has run yet
    /// against the singleton (e.g. process just started, or all
    /// queries so far went through caller-minted [`NtsClient`]
    /// instances). This is an overwrite-on-store event marker, not
    /// a steady-state signal: prefer the four `default_backend_*_count`
    /// fields below for dashboard panels that need trend visibility
    /// across the singleton's resolution history. Custom-client
    /// callers should read the per-handshake `trust_backend` field
    /// on [`NtsTimeSample`] / [`NtsWarmCookiesOutcome`] for accurate
    /// per-client attribution.
    pub default_client_backend: Option<TrustBackend>,
    /// Cumulative count of default-singleton handshakes that resolved
    /// to [`TrustBackend::Platform`] since process start. Bumped
    /// in lock-step with each `Platform` store on
    /// `default_client_backend`. Never reset; weakly monotonic
    /// across consecutive snapshots, with the same per-counter
    /// monotonicity contract as `android_hybrid_fallback_count`.
    pub default_backend_platform_count: u64,
    /// Cumulative count of default-singleton handshakes that resolved
    /// to [`TrustBackend::PlatformWithHybridFallback`] since process
    /// start. Always zero on non-Android platforms (the
    /// platform-verifier-with-`webpki-roots`-fallback path only
    /// exists on Android). Same monotonicity contract as
    /// `default_backend_platform_count`.
    pub default_backend_hybrid_count: u64,
    /// Cumulative count of default-singleton handshakes that resolved
    /// to [`TrustBackend::WebpkiRoots`] since process start. Bumped
    /// every time `build_with_native_verifier` failed at TLS-config
    /// construction time on a [`TrustMode::PlatformWithFallback`]
    /// singleton. Same monotonicity contract as
    /// `default_backend_platform_count`.
    pub default_backend_webpki_count: u64,
    /// Cumulative count of default-singleton handshakes that resolved
    /// to [`TrustBackend::Custom`] since process start. Same monotonicity
    /// contract as `default_backend_platform_count`.
    pub default_backend_custom_count: u64,
    /// On Android: `true` iff
    /// `Java_com_nllewellyn_nts_PlatformInit_nativeInit` has been
    /// invoked at least once and reported success. `false` on every
    /// other platform (no JNI bootstrap step exists). A `false`
    /// value on Android implies the process is currently running
    /// against the `webpki-roots` static bundle for any subsequent
    /// handshake, regardless of the caller's [`TrustMode`].
    pub android_platform_init_succeeded: bool,
    /// Cumulative count of TLS chains the Android `HybridVerifier`
    /// has accepted via the `webpki-roots` fallback path since
    /// process start. Always zero on non-Android platforms (no
    /// `HybridVerifier` exists). Non-zero on Android indicates at
    /// least one chain arrived whose only platform-side failure was
    /// a curated fallback-eligible shape (missing OCSP-AIA,
    /// R8-stripped AAR classes, etc.).
    pub android_hybrid_fallback_count: u64,
}

/// Failure modes for `nts_query` (Dart: `ntsQuery`) and
/// `nts_warm_cookies` (Dart: `ntsWarmCookies`).
///
/// Variants whose precondition is "the TLS handshake had at least
/// reached config-build time" carry an optional `trust_backend`
/// field with the per-handshake trust-anchor backend resolved by
/// `build_tls_config` (a crate-internal helper in
/// `crate::nts::ke`; rendered as inline code rather than as a
/// rustdoc intra-doc link to match the convention spelled out on
/// the `Authentication` variant below — crate-internal Rust items
/// are not navigable from a Dart reader's vantage point), and on
/// Android upgraded to [`TrustBackend::PlatformWithHybridFallback`]
/// when the hybrid verifier's per-instance fallback counter
/// incremented during the handshake. `None` on those variants
/// means the backend was not yet resolved when the failure fired
/// (typically a pre-build error that was wrapped by a later
/// layer). Variants whose precondition rules out backend
/// attribution (`InvalidSpec`, `TrustBackendUnavailable`,
/// `Internal`) do not carry the field at all. New in 3.0.0.
#[derive(Debug, Clone)]
pub enum NtsError {
    /// `spec` was rejected before any I/O happened.
    InvalidSpec(String),
    /// TCP/UDP I/O error or connection failure.
    Network {
        message: String,
        trust_backend: Option<TrustBackend>,
    },
    /// TLS handshake or NTS-KE record exchange failed.
    KeProtocol {
        message: String,
        trust_backend: Option<TrustBackend>,
    },
    /// NTPv4 packet parsing or extension validation failed.
    NtpProtocol {
        message: String,
        trust_backend: Option<TrustBackend>,
    },
    /// AEAD seal/open failed (tag mismatch, malformed input).
    ///
    /// Reserved for cryptographic-verification failures of the AEAD
    /// primitive itself on a fully negotiated algorithm — i.e. the
    /// `aes_siv` / `aes_gcm_siv` `decrypt` / `encrypt` call returned
    /// an error against a key derived from the TLS exporter. A
    /// monitoring rule wired to "tag mismatch" alarms should key on
    /// this variant only.
    ///
    /// AEAD-algorithm *negotiation* failures during NTS-KE — a
    /// server picking an AEAD identifier this client does not
    /// implement — route to `NtsError::KeProtocol` instead (Dart:
    /// `NtsError.keProtocol`). The primary path is
    /// `KeError::UnsupportedAead` raised inside
    /// `crate::nts::ke::validate_response`, mapped to `KeProtocol`
    /// by the catch-all arm of the `From<KeError>` impl below;
    /// the defence-in-depth path (`AeadError::UnsupportedAlgorithm`,
    /// only reached if validation is bypassed) is mapped to the
    /// same `KeProtocol` variant by the explicit arm of the
    /// `From<AeadError>` impl. The Dart-side mirror of this
    /// routing lives on `NtsError.authentication` in
    /// `lib/src/api/errors.dart`.
    ///
    /// Names like `KeError::UnsupportedAead`,
    /// `crate::nts::ke::validate_response`, and
    /// `AeadError::UnsupportedAlgorithm` refer to crate-internal
    /// Rust items and are intentionally rendered as inline code
    /// rather than rustdoc intra-doc links: this rustdoc is mirrored
    /// into Dart via FRB, and broken cross-language links would
    /// surface as dead references on the Dart side. A Rust reader
    /// can find them via crate-internal navigation; a Dart reader
    /// has the parallel dartdoc on `NtsError.authentication` in
    /// `lib/src/api/errors.dart`.
    Authentication {
        message: String,
        trust_backend: Option<TrustBackend>,
    },
    /// Wall-clock budget elapsed inside one of the call's pre-NTP or
    /// NTP phases. The [`TimeoutPhase`] payload identifies which
    /// phase tripped the deadline so callers can choose the right
    /// remediation (raise the resolver cap on `DnsSaturation`,
    /// lengthen `timeout_ms` on `DnsTimeout` / `Connect` / `Tls` /
    /// `KeRecordIo` / `Ntp`, etc.). See [`TimeoutPhase`] for the full
    /// taxonomy.
    Timeout {
        phase: TimeoutPhase,
        trust_backend: Option<TrustBackend>,
    },
    /// Cookie jar empty after a handshake (server delivered none).
    NoCookies { trust_backend: Option<TrustBackend> },
    /// Caller selected [`TrustMode::PlatformOnly`] and
    /// `build_with_native_verifier` could not construct a
    /// platform-backed `ClientConfig`. Surfaced instead of silently
    /// downgrading to the `webpki-roots` static bundle. The payload
    /// carries the underlying construction-failure diagnostic. New
    /// in 3.0.0; consumers using exhaustive `switch` on `NtsError`
    /// must add an arm for this variant.
    TrustBackendUnavailable(String),
    /// Bug guard for unreachable internal states.
    Internal(String),
}

impl NtsError {
    /// Override the per-handshake trust-anchor backend on a freshly
    /// constructed `NtsError`. No-op for variants whose precondition
    /// rules out a backend; for the variants that do carry the field,
    /// replaces whatever the constructing site set (typically `None`
    /// from the `From<X>` impls). Used by `From<KeFailure> for
    /// NtsError` to attach the resolution computed inside
    /// `perform_handshake` after construction has already chosen the
    /// variant.
    ///
    /// `pub(crate)` rather than `pub` to keep the FRB-generated Dart
    /// class clean of helper-method boilerplate that would clash with
    /// the per-variant `trustBackend` fields freezed already emits.
    /// Dart consumers read the attribution off the per-variant field
    /// directly via the hand-written wrapper in
    /// `lib/src/api/errors.dart`.
    #[must_use]
    pub(crate) fn with_trust_backend(mut self, next: Option<TrustBackend>) -> Self {
        match &mut self {
            Self::InvalidSpec(_) | Self::TrustBackendUnavailable(_) | Self::Internal(_) => {}
            Self::Network { trust_backend, .. }
            | Self::KeProtocol { trust_backend, .. }
            | Self::NtpProtocol { trust_backend, .. }
            | Self::Authentication { trust_backend, .. }
            | Self::Timeout { trust_backend, .. }
            | Self::NoCookies { trust_backend } => {
                *trust_backend = next;
            }
        }
        self
    }
}

impl std::fmt::Display for NtsError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidSpec(m) => write!(f, "invalid NtsServerSpec: {m}"),
            Self::Network { message, .. } => write!(f, "network: {message}"),
            Self::KeProtocol { message, .. } => write!(f, "NTS-KE: {message}"),
            Self::NtpProtocol { message, .. } => write!(f, "NTPv4: {message}"),
            Self::Authentication { message, .. } => write!(f, "AEAD: {message}"),
            Self::Timeout { phase, .. } => write!(f, "operation timed out in phase {phase:?}"),
            Self::NoCookies { .. } => f.write_str("server delivered no cookies"),
            Self::TrustBackendUnavailable(m) => write!(f, "trust backend unavailable: {m}"),
            Self::Internal(m) => write!(f, "internal: {m}"),
        }
    }
}

impl std::error::Error for NtsError {}

impl From<KeError> for NtsError {
    fn from(e: KeError) -> Self {
        match e {
            // Phase-tagged timeouts surface verbatim so callers can
            // distinguish DNS saturation from a slow record read
            // without parsing the diagnostic string. Non-timeout I/O
            // failures (NXDOMAIN, ECONNREFUSED, …) reach Dart as
            // `Network` with the underlying message preserved.
            KeError::PhaseTimeout(p) => Self::Timeout {
                phase: p.into(),
                trust_backend: None,
            },
            KeError::Io(io) => Self::Network {
                message: io.to_string(),
                trust_backend: None,
            },
            KeError::Tls(t) => Self::KeProtocol {
                message: format!("TLS: {t}"),
                trust_backend: None,
            },
            KeError::NoCookies => Self::NoCookies {
                trust_backend: None,
            },
            // `TrustBackendUnavailable` only fires on the
            // `TrustMode::PlatformOnly` strict path; surface it as the
            // dedicated typed variant rather than collapsing onto
            // `KeProtocol` so callers can distinguish a platform-store
            // construction failure from a genuine TLS / KE protocol
            // failure without inspecting free-form diagnostic strings.
            KeError::TrustBackendUnavailable(m) => Self::TrustBackendUnavailable(m),
            other => Self::KeProtocol {
                message: other.to_string(),
                trust_backend: None,
            },
        }
    }
}

/// Conversion from the wrapped failure type returned by
/// [`crate::nts::ke::perform_handshake`]. Delegates the variant
/// dispatch to `From<KeError> for NtsError` and then attaches the
/// per-handshake trust-backend attribution from
/// `KeFailure.trust_backend` to the resulting `NtsError` (when
/// applicable). Variants that have no `trust_backend` field
/// (`InvalidSpec`, `TrustBackendUnavailable`, `Internal`) silently
/// drop the attribution — by construction those variants either fire
/// before any backend is resolved or describe the backend itself
/// being unusable, so attribution would be meaningless anyway.
impl From<KeFailure> for NtsError {
    fn from(f: KeFailure) -> Self {
        let public_backend = f.trust_backend.map(|b| match b {
            crate::nts::ke::KeTrustBackend::Platform => TrustBackend::Platform,
            crate::nts::ke::KeTrustBackend::PlatformWithHybridFallback => {
                TrustBackend::PlatformWithHybridFallback
            }
            crate::nts::ke::KeTrustBackend::WebpkiRoots => TrustBackend::WebpkiRoots,
            crate::nts::ke::KeTrustBackend::Custom => TrustBackend::Custom,
        });
        Self::from(f.error).with_trust_backend(public_backend)
    }
}

impl From<NtpError> for NtsError {
    #[expect(
        clippy::match_same_arms,
        reason = "the per-variant arms for `Unsynchronized` / `KissOfDeath` / \
                  `StaleCookie` are intentionally enumerated rather than \
                  collapsed via `|` or onto the catch-all `other` arm: each \
                  is documented as a candidate for promotion into a dedicated \
                  `NtsError` variant, and an explicit arm makes the future \
                  split a localised one-line change rather than a hunt \
                  through the wildcard branch"
    )]
    fn from(e: NtpError) -> Self {
        match e {
            NtpError::Aead(a) => Self::Authentication {
                message: a.to_string(),
                trust_backend: None,
            },
            // Server-attested "no usable time" signals (RFC 5905 §7.3 LI=3
            // and §7.4 stratum-0 KoD) reach Dart as `NtpProtocol` with the
            // diagnostic string preserved verbatim — for KoD this includes
            // the 4-octet kiss code (`RATE`, `DENY`, `RSTR`, `NTSN`, …) so
            // callers can inspect the message and back off appropriately.
            // We list them explicitly so a future split into dedicated
            // `NtsError` variants is a localised change rather than a hunt
            // through the catch-all arm.
            e @ NtpError::Unsynchronized => Self::NtpProtocol {
                message: e.to_string(),
                trust_backend: None,
            },
            e @ NtpError::KissOfDeath(_) => Self::NtpProtocol {
                message: e.to_string(),
                trust_backend: None,
            },
            // RFC 8915 §5.7 unauthenticated NTSN with matching UID — a
            // request-correlated rekey signal that the cached cookie is
            // no longer valid. The matching UID echoed from the request
            // is the only authenticity check available (the response
            // carries no Authenticator), so this is *not* cryptographically
            // server-attested; it is unauthenticated and guarded only by
            // UID correlation. Routed through `NtpProtocol` so the
            // Dart-facing `NtsError` enum stays stable; the eviction-side
            // effect is handled inside `nts_query` before this conversion
            // happens (see the `evict_on_rekey_signal` closure).
            e @ NtpError::StaleCookie => Self::NtpProtocol {
                message: e.to_string(),
                trust_backend: None,
            },
            other => Self::NtpProtocol {
                message: other.to_string(),
                trust_backend: None,
            },
        }
    }
}

impl From<AeadError> for NtsError {
    fn from(e: AeadError) -> Self {
        match e {
            // Algorithm-negotiation failures originate in the KE layer
            // (`validate_response`'s aead-id check) and only ever reach
            // `from_keying_material` as a defence-in-depth path. Routing
            // them to `KeProtocol` keeps the Dart-side error taxonomy
            // honest: `Authentication` is reserved for tag mismatches
            // and other cryptographic verification failures, not for
            // "this server picked an algorithm we don't implement".
            AeadError::UnsupportedAlgorithm(_) => Self::KeProtocol {
                message: e.to_string(),
                trust_backend: None,
            },
            other => Self::Authentication {
                message: other.to_string(),
                trust_backend: None,
            },
        }
    }
}

/// `?`-driven conversion used by the AEAD-NTPv4 UDP exchange in
/// [`nts_query`] (`socket.send` / `socket.recv` propagate
/// `io::Error` directly). The KE pipeline never reaches this impl —
/// it routes through `From<KeError>` which carries
/// [`KeTimeoutPhase`] via [`KeError::PhaseTimeout`] — and
/// [`bind_connected_udp_using`] does its own phase-aware translation
/// for the UDP setup leg, so the only `io::Error` shapes that
/// actually flow through here are the NTP `send`/`recv` ones. That
/// makes [`TimeoutPhase::Ntp`] the correct (and only) timeout tag
/// at this conversion site.
impl From<std::io::Error> for NtsError {
    fn from(e: std::io::Error) -> Self {
        match e.kind() {
            std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock => Self::Timeout {
                phase: TimeoutPhase::Ntp,
                trust_backend: None,
            },
            _ => Self::Network {
                message: e.to_string(),
                trust_backend: None,
            },
        }
    }
}

/// Cached per-(KE host:port) session built from a successful handshake.
struct Session {
    /// Process-wide unique identifier for *this* handshake instance.
    ///
    /// NTS cookies are cryptographically bound to the C2S/S2C keys
    /// negotiated during the KE that produced them (RFC 8915 §6). The
    /// global session table is keyed only by `host:port`, so a
    /// concurrent `nts_warm_cookies` (or a `checkout` that triggered
    /// its own re-handshake) can replace the entry while an in-flight
    /// `nts_query` is still waiting on the wire. When that query
    /// returns, its fresh cookies belong to the *old* keys; stuffing
    /// them into the new session's jar would cause every subsequent
    /// query to fail authentication. The generation is captured into
    /// `QueryContext` at checkout and re-checked at deposit time so
    /// stale cookies are dropped instead of poisoning the cache.
    generation: u64,
    aead_id: u16,
    c2s_key: AeadKey,
    s2c_key: AeadKey,
    /// NTPv4 host the KE response pointed at (often the same as the KE host).
    ntpv4_host: String,
    ntpv4_port: u16,
    jar: CookieJar,
    /// Trust-anchor backend the original KE handshake authenticated
    /// against. Cached on the `Session` so steady-state cached-session
    /// queries can populate `NtsTimeSample::trust_backend` /
    /// `NtsWarmCookiesOutcome::trust_backend` with the same value the
    /// fresh-KE path would have surfaced. Mirrors the
    /// "`phase_timings` zeros for cached paths but `trust_backend`
    /// carries the original handshake's value" pattern so callers
    /// always see a concrete attribution rather than `None` /
    /// "n/a" for cached samples.
    trust_backend: TrustBackend,
}

impl Session {
    fn cookies_remaining(&self) -> usize {
        self.jar.count(&self.ntpv4_host)
    }
}

/// Mint a fresh, monotonically-increasing session generation ID.
///
/// `Relaxed` is sufficient because the value is only ever compared for
/// equality against a snapshot taken under the same `SessionTable`
/// mutex that gates every read/write of the table. The mutex provides
/// the cross-thread happens-before relationship; the atomic is here
/// purely to give us a cheap uniqueness oracle without having to widen
/// the lock-protected state.
fn next_session_generation() -> u64 {
    static GEN: AtomicU64 = AtomicU64::new(1);
    GEN.fetch_add(1, Ordering::Relaxed)
}

/// Success payload published on the singleflight slot. Carries the
/// leader's freshly-harvested cookie count and resolved trust-anchor
/// backend so waiters on the warm-cookies path can return the
/// "delivered with the KE response" value (per the documented
/// `NtsWarmCookiesOutcome.fresh_cookies` contract) rather than a
/// post-publish snapshot of the cache that a concurrent query waiter
/// could have already drained by one cookie. The query waiter side
/// ignores the payload because its own contract is to pop a cookie
/// out of the cache anyway.
#[derive(Clone, Debug)]
struct HandshakeSlotOk {
    fresh_cookies: u32,
    trust_backend: TrustBackend,
}

/// Recover the inner `MutexGuard` from a poisoned mutex instead of
/// panicking. Every mutex in this module protects a cache or
/// singleflight registry — `SessionTable.map` (a `HashMap<String,
/// Session>` keyed by `host:port`), `SessionTable.inflight` (a
/// `HashMap<String, Arc<HandshakeSlot>>` registering in-flight
/// leaders), and `HandshakeSlot.result` (an `Option<Result<…>>`
/// holding the leader's publish slot). None of these data structures
/// carry an invariant whose violation by a mid-update panic could
/// produce silently-wrong NTS behaviour: at worst the cache holds a
/// stale entry that the next cache-invalidation or eviction path
/// reaps, and the singleflight registry self-cleans through
/// [`LeaderGuard::drop`] which already publishes an `Internal` error
/// to waiters on the leader-aborted-mid-handshake path.
///
/// Without recovery, the first `.lock().expect("…")` site that ever
/// fires (during a panic on any other thread) poisons the mutex
/// permanently and every subsequent FRB-boundary call from any
/// thread panics deterministically — a single recoverable failure
/// turns into a permanent "this `NtsClient` is dead forever" mode
/// across the Dart bridge. Recovering the inner guard preserves the
/// availability guarantee: the next caller observes the same cache
/// state the panicking thread was working against and proceeds.
///
/// Exposed as a free function rather than an extension method on
/// `Mutex` so FRB's `api/` scanner does not surface a placeholder
/// `LockExt` abstract Dart class and a `MutexGuardT` opaque
/// pointer — `#[frb(ignore)]` on a trait function suppresses the
/// function but not the trait shell, but a private free function
/// is invisible to FRB by construction (the same path that hides
/// every other private helper in this module). The `#[cfg(test)]`
/// submodule reaches it through Rust's "descendant modules see
/// private items" rule, which is all the recovery-regression
/// tests need.
fn lock_recover<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

/// Per-key singleflight slot. One slot exists per `host:port` while a
/// leader is mid-handshake, so concurrent `checkout` calls against the
/// same key park on the slot rather than each running their own
/// duplicate KE handshake. The leader publishes a
/// `Result<HandshakeSlotOk, NtsError>` when it finishes; waiters
/// receive a `Clone` of that result. Errors propagate to every waiter
/// so a leader's KE failure does not silently retry — followers see
/// the same error semantics they would have observed had they run the
/// handshake themselves.
///
/// On the warm-cookies path the success payload carries enough state
/// that waiters can return the leader's harvested count without
/// re-acquiring `SessionTable::map`. On the query path the leader
/// still installs the `Session` into `map`; query waiters loop back
/// to phase A, look up the freshly installed session, and pop a
/// cookie of their own. This naturally handles the "cookie pool
/// exhausted" case for query waiters: if more wake than the pool
/// has cookies, the extras simply re-enter the role-election loop
/// and elect a new leader for the next handshake. Each successful KE
/// handshake adds N fresh cookies (typically 8 per RFC 8915) so the
/// loop converges in `ceil(waiters / N)` handshake rounds, not
/// infinitely.
struct HandshakeSlot {
    /// `None` while the leader is mid-handshake; `Some(...)` once the
    /// leader publishes a result. Waiters block on `cv` until this is
    /// non-empty or their per-call deadline elapses.
    result: Mutex<Option<Result<HandshakeSlotOk, NtsError>>>,
    cv: Condvar,
}

impl HandshakeSlot {
    fn new() -> Self {
        Self {
            result: Mutex::new(None),
            cv: Condvar::new(),
        }
    }

    /// Park until the leader publishes a result or `deadline` elapses.
    /// Returns `Some(result_clone)` when a result is available, `None`
    /// on deadline expiry. Each waiter receives an independent
    /// `Clone` of the leader's `Result`.
    fn wait_until(&self, deadline: Instant) -> Option<Result<HandshakeSlotOk, NtsError>> {
        let mut g = lock_recover(&self.result);
        loop {
            if let Some(r) = g.as_ref() {
                return Some(r.clone());
            }
            let now = Instant::now();
            if now >= deadline {
                return None;
            }
            let (next_g, _) = self
                .cv
                .wait_timeout(g, deadline - now)
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            g = next_g;
        }
    }

    /// Publish the leader's result and wake every parked waiter. Idempotent;
    /// a second `complete` is silently ignored so the LeaderGuard's Drop
    /// path can fire after a normal explicit completion without
    /// clobbering the published value.
    fn complete(&self, result: Result<HandshakeSlotOk, NtsError>) {
        let mut g = lock_recover(&self.result);
        if g.is_none() {
            *g = Some(result);
            self.cv.notify_all();
        }
    }
}

/// RAII cleanup for the leader path. Removes the `inflight` slot when
/// the leader finishes (success or failure) and, if the leader's
/// `establish_session` panics or the leader returns early without
/// calling `complete`, signals waiters with an `Internal` error so
/// they unpark and surface a meaningful failure rather than blocking
/// against the slot until their per-call deadline elapses.
struct LeaderGuard<'a> {
    table: &'a SessionTable,
    key: String,
    slot: Arc<HandshakeSlot>,
    completed: bool,
}

impl<'a> LeaderGuard<'a> {
    fn new(table: &'a SessionTable, key: String, slot: Arc<HandshakeSlot>) -> Self {
        Self {
            table,
            key,
            slot,
            completed: false,
        }
    }

    /// Atomically (with respect to phase-B role election) publish
    /// `result` to the slot and remove the inflight registration.
    /// After this call the `Drop` impl is a no-op, so the leader can
    /// safely return without re-completing.
    ///
    /// The publish-then-remove sequence runs under one critical
    /// section on `inflight` so no new caller arriving in phase B can
    /// observe the transient state where the slot has *already been
    /// published* but the inflight entry is *still registered*. If
    /// that observation were possible the new caller would become a
    /// waiter on the now-stale slot, immediately receive the
    /// published result, loop back to phase A, find the cookie pool
    /// already drained by faster siblings, re-enter phase B, and find
    /// the same stale slot still there — busy-spinning until the
    /// leader's `inflight.remove` finally lands. Holding `inflight`
    /// across the slot publish (`HandshakeSlot::complete`'s own slot
    /// mutex is acquired briefly inside) collapses both transitions
    /// into a single atomic step against any phase-B observer. Lock
    /// order is `inflight` outer → slot mutex inner; no other call
    /// site acquires both, so this is the only site that fixes the
    /// ordering and there is no deadlock risk against the waiter
    /// path (which releases `inflight` before parking on the slot).
    fn complete(&mut self, result: Result<HandshakeSlotOk, NtsError>) {
        let mut g = lock_recover(&self.table.inflight);
        self.slot.complete(result);
        g.remove(&self.key);
        self.completed = true;
    }
}

impl Drop for LeaderGuard<'_> {
    fn drop(&mut self) {
        if !self.completed {
            // Leader path aborted before publishing (panic in
            // `establish_session`, early `?` propagation, etc.). Clean
            // up the inflight slot and surface a sentinel error so
            // waiters can unpark immediately rather than spinning on
            // their per-call deadline against a stale slot.
            //
            // Same publish-then-remove-under-`inflight` discipline as
            // `complete` above: the two transitions must be atomic
            // against any phase-B observer or a new caller could
            // become a waiter on a slot whose result is already
            // published-but-not-yet-cleared and busy-spin until the
            // remove lands.
            let mut g = lock_recover(&self.table.inflight);
            self.slot.complete(Err(NtsError::Internal(
                "singleflight leader aborted before publishing a result".into(),
            )));
            g.remove(&self.key);
        }
    }
}

/// Time-to-live for an entry in the [`SeenUidCache`]. An accepted
/// response's Unique Identifier is remembered for this long as a
/// defense-in-depth replay guard (NTS-40 / Finding #2); once it
/// elapses the entry is pruned and that UID would be accepted again.
/// Sized to comfortably exceed any plausible request/response round
/// trip — the per-call `timeout_ms` ceiling is far smaller — while
/// keeping the cache "short-lived" so it cannot grow without bound.
const SEEN_UID_TTL: Duration = Duration::from_secs(300);

/// Hard ceiling on the number of Unique Identifiers retained in the
/// [`SeenUidCache`]. Bounds worst-case memory under sustained
/// high query rates: once the cache is full the oldest entry is
/// evicted FIFO to make room, shrinking the replay-detection window
/// for the least-recently-seen UID rather than growing without
/// bound. 4096 × a 32-octet UID ≈ a few hundred KiB.
const SEEN_UID_CAP: usize = 4096;

/// Short-lived in-memory set of Unique Identifiers from server
/// responses this table has already accepted.
///
/// Layered above the per-request UID echo check in
/// [`parse_server_response`] and the AEAD seal as a defense-in-depth
/// replay guard (NTS-40 / Finding #2). The post-AEAD replay
/// protection otherwise rests entirely on two *echo* checks — the
/// response must echo the request's Unique Identifier (RFC 8915 §5.3)
/// and its `origin_timestamp` must echo the request's
/// `transmit_timestamp` (RFC 5905 §8) — neither of which keeps any
/// cross-request state. Their replay resistance therefore *assumes*
/// the client mints a unique UID per request but does not *enforce*
/// it: a CSPRNG failure or caller bug that reused a UID (alongside a
/// reused transmit timestamp) could let a previously-captured
/// response pass both echoes. Remembering accepted UIDs converts that
/// assumption into an enforced invariant within the TTL window — a
/// response whose UID was already accepted is rejected before its
/// (necessarily stale) cookies are deposited.
///
/// The AEAD remains the primary guarantee: a replay must still verify
/// under the session's S2C key, so this cache is strictly additive.
/// It is keyed on the raw UID bytes (globally unique 32-octet random
/// values per RFC 8915 §5.3) and is intentionally *not* partitioned
/// by host — a UID collision across hosts is exactly as unlikely as
/// within one, and a single global set is both simpler and strictly
/// more conservative than a per-host one.
struct SeenUidCache {
    /// UIDs in insertion order paired with their insertion instant,
    /// for age-based (TTL) and capacity-based (FIFO) pruning. The
    /// front is always the oldest entry. The UID bytes are held behind
    /// an `Arc<[u8]>` shared with `seen`, so each UID is heap-allocated
    /// once and both collections only carry a refcount bump.
    order: VecDeque<(Arc<[u8]>, Instant)>,
    /// Membership index over the same UIDs for O(1) duplicate
    /// detection. Kept in lockstep with `order` and sharing its
    /// backing allocation via `Arc<[u8]>`.
    seen: HashSet<Arc<[u8]>>,
}

impl SeenUidCache {
    fn new() -> Self {
        Self {
            order: VecDeque::new(),
            seen: HashSet::new(),
        }
    }

    /// Drop entries older than [`SEEN_UID_TTL`] relative to `now`.
    /// Entries are pushed in non-decreasing `now` order, so the front
    /// is always the oldest and a single front-to-back walk that stops
    /// at the first still-live entry suffices.
    ///
    /// This pass is TTL-only: the [`SEEN_UID_CAP`] ceiling is enforced
    /// separately, on the insertion path in [`note`](Self::note), so a
    /// rejected duplicate never evicts an unrelated UID (which would
    /// silently shrink the replay-detection window).
    fn prune(&mut self, now: Instant) {
        while let Some((_, inserted)) = self.order.front() {
            if now.duration_since(*inserted) >= SEEN_UID_TTL {
                if let Some((uid, _)) = self.order.pop_front() {
                    self.seen.remove(&uid);
                }
            } else {
                break;
            }
        }
    }

    /// Record `uid` as seen at `now`, returning `true` if it was newly
    /// recorded (accept the response) or `false` if it was already
    /// present within the TTL window (replay — reject the response).
    ///
    /// TTL pruning runs first so an expired prior sighting does not
    /// spuriously flag a replay. The [`SEEN_UID_CAP`] ceiling is
    /// enforced only once the UID is confirmed new and about to be
    /// inserted, so a rejected duplicate leaves the existing window
    /// untouched. The UID is heap-allocated once as an `Arc<[u8]>` and
    /// shared between `seen` and `order`.
    fn note(&mut self, uid: &[u8], now: Instant) -> bool {
        self.prune(now);
        if self.seen.contains(uid) {
            return false;
        }
        while self.order.len() >= SEEN_UID_CAP {
            if let Some((evicted, _)) = self.order.pop_front() {
                self.seen.remove(&evicted);
            }
        }
        let shared: Arc<[u8]> = Arc::from(uid);
        self.seen.insert(Arc::clone(&shared));
        self.order.push_back((shared, now));
        true
    }
}

/// Per-host session table keyed by `host:port` so two specs with
/// different KE ports stay isolated even when they share a hostname.
///
/// Each [`NtsClient`] owns one `SessionTable`; the convenience
/// top-level entry points ([`nts_query`], [`nts_warm_cookies`])
/// delegate to a process-wide default client, and the cache-layer
/// unit tests in this module reach that same default table through
/// a `#[cfg(test)]`-gated `default_session_table()` shim (private to
/// the crate; not part of the documented surface). The `Mutex`
/// provides interior mutability so client methods take `&self`
/// rather than `&mut self` and concurrent calls against the same
/// client serialize only for the brief window each cache lookup
/// needs.
///
/// `pub(crate)` so the FRB-generated dispatcher in
/// `rust/src/frb_generated.rs` (a sibling module of `crate::api::nts`)
/// can name the type, but not `pub` so downstream Rust crates do not
/// see it. Marked `#[flutter_rust_bridge::frb(ignore)]` so FRB does
/// not emit a public Dart binding for the type — without the ignore,
/// the private `NtsClient.table` field is enough to make FRB's parser
/// pull `SessionTable` into the bindable surface.
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct SessionTable {
    map: Mutex<HashMap<String, Session>>,
    /// Per-key singleflight registry. Holds an `Arc<HandshakeSlot>` for
    /// every `host:port` whose handshake is currently in flight, so
    /// concurrent `checkout` calls against the same key park on the
    /// existing slot instead of each running their own duplicate KE
    /// handshake. The inflight slot is removed atomically with the
    /// leader's `complete` step (see `LeaderGuard`); the `map` and
    /// `inflight` mutexes are deliberately *not* held simultaneously
    /// to avoid lock-order discipline.
    inflight: Mutex<HashMap<String, Arc<HandshakeSlot>>>,
    /// Short-lived replay guard over accepted-response Unique
    /// Identifiers (NTS-40 / Finding #2). See [`SeenUidCache`] for the
    /// threat model. Its mutex is independent of `map` / `inflight`
    /// and is taken alone, briefly, in [`note_unique_id`](Self::note_unique_id),
    /// never while either of the others is held — so it adds no
    /// lock-ordering obligation.
    seen_uids: Mutex<SeenUidCache>,
}

impl SessionTable {
    fn new() -> Self {
        Self {
            map: Mutex::new(HashMap::new()),
            inflight: Mutex::new(HashMap::new()),
            seen_uids: Mutex::new(SeenUidCache::new()),
        }
    }
}

/// Owned NTS client handle.
///
/// Each `NtsClient` owns its own session table, so two instances never
/// share cookie or key state. The handle is safe to use from multiple
/// threads concurrently — the inner table is mutex-guarded — and
/// methods take `&self`, so a single `NtsClient` can be shared by
/// reference (or via `Arc`) across the application.
///
/// The convenience top-level functions `nts_query` and
/// `nts_warm_cookies` (`ntsQuery` / `ntsWarmCookies` on the Dart
/// side) delegate to a process-wide default client. Construct an
/// explicit `NtsClient` when you need test isolation, the ability
/// to drop cached sessions on demand via `invalidate` / `clear`,
/// or scope-bounded session ownership.
///
/// `Default` is intentionally not derived so FRB does not surface a
/// `default_()` static factory in the generated Dart bindings;
/// `new` (which becomes the synchronous `NtsClient()` default
/// constructor on the Dart side) is the canonical constructor on
/// both sides.
pub struct NtsClient {
    table: SessionTable,
    /// Trust-anchor policy applied to every handshake this client
    /// initiates. Set immutably at construction; the only way to
    /// change it is to mint a new client. Plumbed down through
    /// `query`/`warm_cookies` → `nts_*_inner` → `SessionTable::checkout`
    /// → `establish_session` → `KeRequest::trust_mode` →
    /// `build_tls_config`. New in 3.0.0.
    ///
    /// Stored as the internal `KeTrustMode` (a crate-internal type
    /// with no Dart-side counterpart, distinct from the public
    /// `TrustMode` which is the wire-facing enum) so the per-`query`
    /// / per-`warm_cookies` plumbing clones a `KeTrustMode`
    /// — whose `Custom` variant holds the roots bundle behind an
    /// `Arc<[u8]>` — instead of the public `Vec<u8>` variant.
    /// Per-call cost is therefore O(1) atomic refcount bump
    /// regardless of bundle size. The single `Vec<u8>` → `Arc<[u8]>`
    /// materialization happens once, at construction time, inside
    /// the `From<TrustMode> for KeTrustMode` impl. The reverse
    /// conversion runs only when the public [`NtsClient::trust_mode`]
    /// getter (`NtsClient.trustMode` on Dart) is called, which is a
    /// diagnostics path rather than a hot loop.
    trust_mode: KeTrustMode,
    /// `true` for the process-wide default singleton client returned
    /// by [`default_nts_client`]; `false` for every caller-minted
    /// client. Drives whether the post-handshake trust-backend value
    /// is recorded into the process-global trust state for
    /// [`nts_trust_status`] to surface — only the singleton's
    /// handshakes contribute to that observable, so multi-client
    /// deployments can distinguish singleton-path attribution from
    /// custom-client attribution.
    is_default: bool,
}

impl NtsClient {
    /// Construct a fresh client with an empty session table and the
    /// default trust-anchor policy ([`TrustMode::PlatformWithFallback`]).
    ///
    /// Marked `#[flutter_rust_bridge::frb(sync)]` so the generated
    /// Dart side exposes this as the `NtsClient()` default
    /// constructor (synchronous; no isolate hop) rather than as an
    /// `await NtsClient.newInstance()` static factory.
    ///
    /// Use [`NtsClient::with_trust_mode`] to opt into
    /// [`TrustMode::PlatformOnly`] strict mode for clients that
    /// pin a corporate CA or otherwise refuse to downgrade to the
    /// `webpki-roots` static bundle. The top-level convenience
    /// functions ([`nts_query`], [`nts_warm_cookies`]) always go
    /// through a default-mode singleton and are unaffected.
    #[flutter_rust_bridge::frb(sync)]
    pub fn new() -> Self {
        Self {
            table: SessionTable::new(),
            trust_mode: KeTrustMode::PlatformWithFallback,
            is_default: false,
        }
    }

    /// Construct a fresh client with the caller-selected
    /// [`TrustMode`] policy. Equivalent to [`NtsClient::new`] when
    /// `trust_mode == TrustMode::PlatformWithFallback`; produces a
    /// strict-mode client when `trust_mode ==
    /// TrustMode::PlatformOnly`.
    ///
    /// Marked `#[flutter_rust_bridge::frb(sync)]` so the generated
    /// Dart side exposes this as a synchronous factory rather than
    /// an `await` constructor — `NtsClient.withTrustMode(TrustMode...)`
    /// (the wrapper layer further smooths this into a named-parameter
    /// optional on the Dart `NtsClient` constructor).
    #[flutter_rust_bridge::frb(sync)]
    pub fn with_trust_mode(trust_mode: TrustMode) -> Self {
        Self {
            table: SessionTable::new(),
            trust_mode: trust_mode.into(),
            is_default: false,
        }
    }

    /// Trust-anchor policy this client was constructed with. Useful
    /// for diagnostics and for callers that round-trip a client
    /// handle through their own configuration layer and need to
    /// re-derive the policy without keeping a parallel record.
    ///
    /// The returned `TrustMode::Custom` (`TrustMode.custom` on Dart)
    /// re-materializes the roots bundle as a `Vec<u8>` for the FRB
    /// wire shape, so this call is O(bundle size). It is intended
    /// for diagnostics only; the per-handshake hot path stays on
    /// the internal `KeTrustMode` (crate-internal) and never reaches
    /// this getter.
    #[flutter_rust_bridge::frb(sync)]
    pub fn trust_mode(&self) -> TrustMode {
        self.trust_mode.clone().into()
    }

    /// Per-client equivalent of the top-level `nts_query`
    /// (`ntsQuery` on the Dart side).
    pub fn query(
        &self,
        spec: NtsServerSpec,
        timeout_ms: u32,
        dns_concurrency_cap: u32,
        verification_time_ms: Option<i64>,
    ) -> Result<NtsTimeSample, NtsError> {
        nts_query_inner(
            &self.table,
            spec,
            timeout_ms,
            dns_concurrency_cap,
            self.trust_mode.clone(),
            self.is_default,
            verification_time_ms,
        )
    }

    /// Per-client equivalent of the top-level `nts_warm_cookies`
    /// (`ntsWarmCookies` on the Dart side).
    pub fn warm_cookies(
        &self,
        spec: NtsServerSpec,
        timeout_ms: u32,
        dns_concurrency_cap: u32,
        verification_time_ms: Option<i64>,
    ) -> Result<NtsWarmCookiesOutcome, NtsError> {
        nts_warm_cookies_inner(
            &self.table,
            spec,
            timeout_ms,
            dns_concurrency_cap,
            self.trust_mode.clone(),
            self.is_default,
            verification_time_ms,
        )
    }

    /// Drop the cached session for `spec`'s `host:port`, if any.
    /// Returns `true` if an entry was removed, `false` if no session
    /// was cached for that key. The next `query` or `warm_cookies`
    /// (`query` / `warmCookies` on the Dart side) for that spec
    /// triggers a fresh NTS-KE handshake.
    ///
    /// Does not validate `spec`. An invalid spec (empty host or zero
    /// port) trivially has no cached session and returns `false`.
    ///
    /// Marked `#[flutter_rust_bridge::frb(sync)]` so cache
    /// invalidation does not pay an isolate-hop round-trip; the
    /// underlying operation is one mutex acquisition and one
    /// `HashMap::remove`.
    #[flutter_rust_bridge::frb(sync)]
    pub fn invalidate(&self, spec: NtsServerSpec) -> bool {
        self.table.invalidate(&spec)
    }

    /// Drop every cached session. Cheap; intended for test cleanup
    /// and for apps that want to bound long-lived process memory by
    /// resetting the cache between work batches.
    ///
    /// Marked `#[flutter_rust_bridge::frb(sync)]` for the same
    /// reason as `invalidate`: one mutex acquisition and one
    /// `HashMap::clear`.
    #[flutter_rust_bridge::frb(sync)]
    pub fn clear(&self) {
        self.table.clear()
    }
}

/// Process-wide default `NtsClient`. Used by the top-level convenience
/// functions so existing `nts_query` / `nts_warm_cookies` callers keep
/// working unchanged after the per-client refactor.
///
/// Constructed with `is_default = true` so its handshakes record their
/// resolved trust backend into the process-global trust state surfaced
/// by [`nts_trust_status`]; caller-minted clients (which go through
/// [`NtsClient::new`] / [`NtsClient::with_trust_mode`] with
/// `is_default = false`) do not contribute to that observable so a
/// multi-client deployment can distinguish singleton-path attribution
/// from custom-client attribution.
fn default_nts_client() -> &'static NtsClient {
    static C: OnceLock<NtsClient> = OnceLock::new();
    C.get_or_init(|| NtsClient {
        table: SessionTable::new(),
        trust_mode: KeTrustMode::PlatformWithFallback,
        is_default: true,
    })
}

/// Cache-layer test accessor for the default client's table. Used by
/// the `#[cfg(test)]` `sessions` / `deposit_cookies` / `evict_session`
/// compatibility shims so the pre-refactor cache-layer unit tests in
/// this module keep operating on the same process-wide table the
/// top-level [`nts_query`] / [`nts_warm_cookies`] reach via
/// `default_nts_client().table`.
#[cfg(test)]
fn default_session_table() -> &'static SessionTable {
    &default_nts_client().table
}

/// Cache-layer test compatibility shim. The pre-refactor cache-layer
/// tests in this module poke the process-wide table directly via
/// `sessions().lock()`; rather than rewrite every test site, expose
/// the default client's inner mutex under the original name. Gated to
/// `#[cfg(test)]` so it is dead-stripped from release builds.
#[cfg(test)]
fn sessions() -> &'static Mutex<HashMap<String, Session>> {
    &default_session_table().map
}

fn session_key(spec: &NtsServerSpec) -> String {
    format!("{}:{}", spec.host, spec.port)
}

fn validate(spec: &NtsServerSpec) -> Result<(), NtsError> {
    if spec.host.is_empty() {
        return Err(NtsError::InvalidSpec("host must be non-empty".into()));
    }
    if spec.port == 0 {
        return Err(NtsError::InvalidSpec("port must be non-zero".into()));
    }
    Ok(())
}

/// Reject a caller-supplied `verification_time_ms` that cannot denote a
/// real instant. The override is an epoch-milliseconds count converted
/// to a `UnixTime` via `Duration::from_millis(u64)` in
/// `establish_session`, so a negative value is meaningless. The Dart
/// wrapper already rejects negatives before dispatch (surfacing
/// `NtsError.invalidSpec`); enforcing the same rule here gives direct
/// Rust/FFI callers identical semantics and stops a negative from
/// silently falling back to the system clock — a fallback whose
/// visibility otherwise depended on whether a cached session existed.
///
/// An implausibly large value is rejected too: anything above
/// `MAX_VERIFICATION_TIME_MS` (the year-9999 ceiling) cannot denote a
/// real instant and would otherwise feed an absurd timestamp into the
/// `Duration::from_millis` conversion on this security-relevant path.
/// `None` and any in-range non-negative value pass through unchanged.
fn validate_verification_time_ms(verification_time_ms: Option<i64>) -> Result<(), NtsError> {
    if let Some(ms) = verification_time_ms {
        if ms < 0 {
            return Err(NtsError::InvalidSpec(format!(
                "verificationTimeMs {ms} is negative; it must be a non-negative \
                 count of milliseconds since the Unix epoch"
            )));
        }
        if ms > MAX_VERIFICATION_TIME_MS {
            return Err(NtsError::InvalidSpec(format!(
                "verificationTimeMs {ms} exceeds the maximum of \
                 {MAX_VERIFICATION_TIME_MS} (9999-12-31T23:59:59Z); it must be \
                 a plausible count of milliseconds since the Unix epoch"
            )));
        }
    }
    Ok(())
}

fn effective_timeout(timeout_ms: u32) -> Duration {
    let ms = if timeout_ms == 0 {
        DEFAULT_TIMEOUT_MS
    } else {
        timeout_ms
    };
    Duration::from_millis(ms.into())
}

/// Compute the budget left for the UDP-setup leg of [`nts_query`]
/// given the call-wide `total` and the wall-clock already consumed by
/// the KE phases (`elapsed`). Returns
/// `NtsError::Timeout { phase: TimeoutPhase::Ntp, trust_backend: None }` when the call-wide budget
/// has already been exhausted, since the next blocking syscall after
/// this point is the AEAD-NTPv4 `send`/`recv` round-trip — the same
/// phase tag `bind_connected_udp_using` would emit post-DNS once it
/// detected a zero remaining slice.
///
/// Extracted from the inline subtraction in [`nts_query`] purely so
/// the saturating arithmetic is unit-testable without standing up a
/// live KE responder; the regression this guards against is the
/// fresh-`timeout` re-arm that allowed a cold query's wall-clock to
/// reach ~2x the caller's budget before returning a timeout.
fn remaining_budget_or_ntp_timeout(
    total: Duration,
    elapsed: Duration,
) -> Result<Duration, NtsError> {
    total
        .checked_sub(elapsed)
        .filter(|d| !d.is_zero())
        .ok_or(NtsError::Timeout {
            phase: TimeoutPhase::Ntp,
            trust_backend: None,
        })
}

/// Re-arm a connected UDP socket's read timeout against the
/// call-wide wall-clock budget anchored at the start of
/// [`nts_query`]. The bind-time timeout written by
/// [`bind_connected_udp_using`] is anchored at bind completion, so
/// without this re-arm a slow `send` or scheduling delay between
/// bind and the blocking `recv` lets the `recv` block for that
/// full bind-time budget on top of the time already spent —
/// overshooting the caller's `timeout_ms` contract even though the
/// `recv` itself respects its own (now stale) socket-level value.
///
/// Returns the re-armed remaining budget on success (also written
/// onto the socket) so callers can reuse it for diagnostics.
/// Short-circuits with `Timeout(Ntp)` when the call-wide budget has
/// already been consumed before `recv` even starts; surfaces a
/// failure to apply the timeout (extremely rare on a bound, connected
/// UDP socket) as `NtsError::Network`. On the short-circuit arm the
/// socket is left untouched so the caller-visible failure carries
/// the same phase tag whether the budget was exhausted just before
/// or just after the syscall would have been made.
fn arm_recv_against_call_deadline(
    socket: &UdpSocket,
    total: Duration,
    elapsed: Duration,
) -> Result<Duration, NtsError> {
    let remaining = remaining_budget_or_ntp_timeout(total, elapsed)?;
    socket
        .set_read_timeout(Some(remaining))
        .map_err(|e| NtsError::Network {
            message: format!("set_read_timeout for recv: {e}"),
            trust_backend: None,
        })?;
    Ok(remaining)
}

/// Resolve the FFI `dns_concurrency_cap` argument into a `usize`,
/// substituting [`DEFAULT_MAX_INFLIGHT_DNS_LOOKUPS`] when the caller
/// passes `0`. The default is sized for mobile (see the constant's
/// rustdoc); 0-as-default mirrors the convention `effective_timeout`
/// uses for `timeout_ms`.
fn effective_dns_concurrency_cap(dns_concurrency_cap: u32) -> usize {
    if dns_concurrency_cap == 0 {
        DEFAULT_MAX_INFLIGHT_DNS_LOOKUPS
    } else {
        dns_concurrency_cap as usize
    }
}

/// Drive a complete NTS-KE handshake and convert its outcome into a [`Session`].
///
/// The KE driver offers AES-SIV-CMAC-256 first, then AES-SIV-CMAC-512, then
/// AES-128-GCM-SIV: the 256-bit SIV-CMAC variant is the RFC 8915 §5.1
/// mandatory baseline and is what every public NTS server we tested actually
/// picks today; the 512-bit SIV-CMAC variant (RFC 8915 §5.1 optional, AEAD ID
/// 17) is added so a server that prefers the larger key still resolves to a
/// same-family AEAD rather than falling back to GCM-SIV; GCM-SIV is the
/// nonce-misuse-resistant fallback for servers that prefer it over either
/// SIV-CMAC variant. The offered set lives in [`OFFERED_AEAD_IDS`] (in
/// `crate::nts::ke`) — adding or removing an algorithm requires a
/// single-site edit there, and the cross-surface invariant tests in that
/// module catch any drift between the offered list, the `aead_key_len`
/// lookup table, and the `AeadKey::from_keying_material` constructor at CI
/// time.
///
/// Returns the `Session` together with the per-phase wall-clock
/// breakdown reported by [`perform_handshake`] so callers
/// ([`checkout`], [`nts_warm_cookies`]) can fold the KE timings into
/// the [`PhaseTimings`] surface without re-instrumenting the
/// handshake.
fn establish_session(
    spec: &NtsServerSpec,
    timeout: Duration,
    dns_concurrency_cap: usize,
    trust_mode: KeTrustMode,
    verification_time_ms: Option<i64>,
) -> Result<(Session, KePhaseTimings), NtsError> {
    // Convert the optional caller-supplied epoch-ms override into the
    // `UnixTime` the TLS verifier expects. Negative values are rejected
    // upstream at both entry points — the Dart wrapper
    // (`NtsError.invalidSpec`) and `validate_verification_time_ms` on
    // the Rust query / warm-cookie paths — so the `try_from` below is
    // belt-and-suspenders: a negative cannot reach here, and were one
    // to, it would map to `None` (system clock) rather than wrapping.
    let verification_time_override = verification_time_ms
        .and_then(|ms| u64::try_from(ms).ok())
        .map(|ms| UnixTime::since_unix_epoch(Duration::from_millis(ms)));
    let req = KeRequest {
        host: spec.host.clone(),
        port: spec.port,
        aead_algorithms: OFFERED_AEAD_IDS.to_vec(),
        timeout: Some(timeout),
        dns_concurrency_cap,
        trust_mode,
        verification_time_override,
    };
    let outcome: KeOutcome = perform_handshake(&req)?;
    let trust_backend: TrustBackend = outcome.trust_backend.into();
    let c2s_key = AeadKey::from_keying_material(outcome.aead_id, &outcome.c2s_key)
        .map_err(|e| NtsError::Internal(format!("KE produced unusable C2S key: {e}")))?;
    let s2c_key = AeadKey::from_keying_material(outcome.aead_id, &outcome.s2c_key)
        .map_err(|e| NtsError::Internal(format!("KE produced unusable S2C key: {e}")))?;
    let mut jar = CookieJar::new();
    if outcome.cookies.is_empty() {
        // Handshake itself succeeded — the empty cookie pool is the
        // server's choice, so the failure carries the same trust-
        // backend attribution a successful sample would have shown.
        return Err(NtsError::NoCookies {
            trust_backend: Some(trust_backend),
        });
    }
    jar.put_many(&outcome.ntpv4_host, outcome.cookies);
    let session = Session {
        generation: next_session_generation(),
        aead_id: outcome.aead_id,
        c2s_key,
        s2c_key,
        ntpv4_host: outcome.ntpv4_host,
        ntpv4_port: outcome.ntpv4_port,
        jar,
        trust_backend,
    };
    Ok((session, outcome.phase_timings))
}

/// Snapshot of the data a single NTPv4 exchange needs once the lock is released.
struct QueryContext {
    /// Generation of the [`Session`] this cookie/key tuple was drawn from.
    /// The deposit-side cookie writer compares it against the live session
    /// to refuse stale writes; see [`deposit_cookies`].
    session_generation: u64,
    /// Spent cookie carried across the `CookieJar` → outbound packet
    /// pipeline. Wrapped in [`Zeroizing`] so the cookie bytes are
    /// wiped from RAM when the context drops (after
    /// [`build_client_request`] has serialised the cookie onto the
    /// wire) — the residual-memory-scrape surface the in-jar
    /// zeroize-on-eviction/drop discipline does not cover on its
    /// own. Mirrors the wrapper on `Session::c2s_key`/`s2c_key`.
    cookie: Zeroizing<Vec<u8>>,
    c2s_key: AeadKey,
    s2c_key: AeadKey,
    ntpv4_host: String,
    ntpv4_port: u16,
    aead_id: u16,
    /// Trust-anchor backend the [`Session`] this context was checked
    /// out from authenticated against. Carried verbatim from the
    /// session's cached value (set at handshake time) so per-query
    /// `NtsTimeSample::trust_backend` /
    /// `NtsWarmCookiesOutcome::trust_backend` reflects the original
    /// handshake's backend on cached-session paths and the
    /// just-completed handshake's backend on fresh-KE paths.
    trust_backend: TrustBackend,
}

/// Outcome of `checkout`'s role-election step. The leader will run the
/// handshake and publish its result; the waiter parks on the slot
/// bounded by its own per-call deadline. See `checkout_with` for the
/// full state machine.
enum Role {
    Leader(Arc<HandshakeSlot>),
    Waiter(Arc<HandshakeSlot>),
}

/// The handshake callback `checkout_with` invokes from the leader path.
/// Mirrors `establish_session`'s signature; production callers pass
/// `establish_session`, cache-layer unit tests pass a controllable
/// closure (count invocations, block until released, fail
/// deterministically) so the singleflight role-election state machine
/// is exercisable without a faux NTS-KE responder.
type HandshakeFn =
    dyn Fn(&NtsServerSpec, Duration, usize) -> Result<(Session, KePhaseTimings), NtsError>;

/// Build a [`QueryContext`] from a session and a freshly-popped cookie.
/// Extracted so both the cache-hit and post-handshake branches in
/// `checkout_with` share the same construction shape.
///
/// The `cookie` parameter is a [`Zeroizing<Vec<u8>>`] (the return
/// shape of [`CookieJar::take`]) so the spent bytes ride through
/// the cache → `QueryContext` → [`ClientRequest`] → packet pipeline
/// inside the same wrapper from the jar boundary to the wire — no
/// intermediate bare `Vec<u8>` exists for a residual-memory-scrape
/// attacker to recover post-send.
fn build_query_context(s: &Session, cookie: Zeroizing<Vec<u8>>) -> QueryContext {
    QueryContext {
        session_generation: s.generation,
        cookie,
        c2s_key: s.c2s_key.clone(),
        s2c_key: s.s2c_key.clone(),
        ntpv4_host: s.ntpv4_host.clone(),
        ntpv4_port: s.ntpv4_port,
        aead_id: s.aead_id,
        trust_backend: s.trust_backend,
    }
}

impl SessionTable {
    /// Acquire (or establish) a session and pop one cookie. The returned
    /// context owns the cookie and key clones so the network exchange runs
    /// lock-free.
    ///
    /// Also returns the per-phase wall-clock breakdown of the KE
    /// handshake when one ran. On a cache-hit (the common case once the
    /// session is warm) every phase is reported as `0` because no
    /// handshake was performed; the same `0` is reported to a *waiter*
    /// that parked on a concurrent leader's singleflight slot — only
    /// the leader observes its own handshake's phase timings.
    ///
    /// Concurrent cold queries against the same `host:port` collapse
    /// onto one `establish_session` call: the first caller becomes
    /// the singleflight leader, runs the handshake without holding
    /// any lock, and publishes the result; concurrent callers park
    /// on the slot bounded by their own per-call `timeout` budget,
    /// then re-enter the cookie-take phase against the freshly
    /// installed session. Concurrent callers against *different*
    /// `host:port` keys remain fully parallel — the singleflight
    /// keys off `session_key(spec)`, not off the table itself.
    fn checkout(
        &self,
        spec: &NtsServerSpec,
        timeout: Duration,
        dns_concurrency_cap: usize,
        trust_mode: KeTrustMode,
        verification_time_ms: Option<i64>,
    ) -> Result<(QueryContext, KePhaseTimings), NtsError> {
        self.checkout_with(spec, timeout, dns_concurrency_cap, &move |s, t, c| {
            establish_session(s, t, c, trust_mode.clone(), verification_time_ms)
        })
    }

    /// Singleflight-aware checkout parameterised over the handshake
    /// callback. Production callers go through `checkout`, which binds
    /// the callback to the real `establish_session`; cache-layer unit
    /// tests pass a controllable closure so they can drive the leader
    /// path (count invocations, block until released, fail
    /// deterministically) without standing up a faux NTS-KE responder.
    /// The closure signature mirrors `establish_session`.
    #[expect(
        clippy::too_many_lines,
        reason = "linear singleflight role-election loop: phase A cache hit \
                  (`map` lock briefly), phase B leader/waiter election \
                  (`inflight` lock briefly), phase C lock-free leader body \
                  with publish-then-remove discipline, plus the per-iteration \
                  waiter park/wake/loop. Splitting across helpers obscures \
                  the lock-order discipline (the `map` and `inflight` mutexes \
                  are deliberately never held simultaneously) and the \
                  per-call deadline anchoring; the loop is kept in a single \
                  body so reviewers can verify the discipline at the call \
                  site"
    )]
    fn checkout_with(
        &self,
        spec: &NtsServerSpec,
        timeout: Duration,
        dns_concurrency_cap: usize,
        do_handshake: &HandshakeFn,
    ) -> Result<(QueryContext, KePhaseTimings), NtsError> {
        let key = session_key(spec);
        let started = Instant::now();
        loop {
            // Phase A: try the cache. Return immediately on a hit with
            // at least one cookie. Drop the `map` lock before any
            // singleflight work so a slow leader cannot serialize
            // unrelated cache hits behind itself.
            {
                let mut g = lock_recover(&self.map);
                if let Some(s) = g.get_mut(&key) {
                    if s.cookies_remaining() > 0 {
                        // `cookies_remaining > 0` implies `take` returns
                        // `Some` (both read the same per-host queue
                        // under the same `map` lock), so this should
                        // not surface in practice. Defend against the
                        // invariant being silently violated by a
                        // future `CookieJar` refactor: return
                        // `NoCookies` rather than panicking with
                        // `expect`. The pre-singleflight code surfaced
                        // the same shape on this path.
                        match s.jar.take(&s.ntpv4_host) {
                            Some(cookie) => {
                                let ctx = build_query_context(s, cookie);
                                return Ok((ctx, KePhaseTimings::default()));
                            }
                            // Cache hit but the jar is unexpectedly empty —
                            // the cached session had completed a handshake,
                            // so the failure carries that session's backend.
                            None => {
                                return Err(NtsError::NoCookies {
                                    trust_backend: Some(s.trust_backend),
                                });
                            }
                        }
                    }
                }
            }

            // Phase B: leader-or-waiter election. Holding only the
            // `inflight` lock; never the `map` lock at the same time.
            let role = {
                let mut g = lock_recover(&self.inflight);
                if let Some(slot) = g.get(&key) {
                    Role::Waiter(slot.clone())
                } else {
                    let slot = Arc::new(HandshakeSlot::new());
                    g.insert(key.clone(), slot.clone());
                    Role::Leader(slot)
                }
            };

            match role {
                Role::Leader(slot) => {
                    let mut guard = LeaderGuard::new(self, key.clone(), slot);
                    // Derive the *remaining* slice of the caller's
                    // wall-clock budget for this handshake attempt.
                    // Re-leader cases — a thread that wakes as a waiter,
                    // finds the cookie pool drained, and elects itself
                    // as the next leader — must not start a fresh
                    // `timeout`-long window; otherwise a single
                    // `checkout_with` call could overshoot the caller's
                    // documented budget by up to N rounds × `timeout`
                    // in the worst case. If the budget is already
                    // exhausted, surface `DnsTimeout`: at this point no
                    // record I/O has happened on this thread, and the
                    // next phase that *would* have run is DNS. This
                    // matches the convention
                    // [`UdpDeadline::remaining_or_timeout`] uses for
                    // pre-DNS budget exhaustion on the UDP path —
                    // tagging this as `KeRecordIo` would conflate
                    // pre-handshake budget exhaustion (operator
                    // remediation: raise `dnsConcurrencyCap` or
                    // `timeoutMs`) with the parked-waiter case below
                    // at line ~1766 (operator remediation:
                    // investigate why a leader's record I/O is the
                    // syscall blocking us). Provenance: bd nts-r54.
                    let remaining = match timeout.checked_sub(started.elapsed()) {
                        Some(d) if !d.is_zero() => d,
                        _ => {
                            guard.complete(Err(NtsError::Timeout {
                                phase: TimeoutPhase::DnsTimeout,
                                trust_backend: None,
                            }));
                            return Err(NtsError::Timeout {
                                phase: TimeoutPhase::DnsTimeout,
                                trust_backend: None,
                            });
                        }
                    };
                    let outcome = do_handshake(spec, remaining, dns_concurrency_cap);
                    match outcome {
                        Ok((session, ke_timings)) => {
                            // Capture the freshly-resolved backend before
                            // `session` moves into the table below; both
                            // `NoCookies` exit paths in this branch attach
                            // it so post-handshake failures are
                            // attributable to the same backend a
                            // successful sample on this session would
                            // surface.
                            let session_backend = session.trust_backend;
                            // Refuse to install a 0-cookie session: the
                            // leader plus every waiter would immediately
                            // fall through to NoCookies, and the next
                            // round of leaders would loop on the same
                            // (still useless) handshake outcome. Drop the
                            // session, signal NoCookies, return NoCookies
                            // — same observable shape as the pre-singleflight
                            // path, which already collapsed this case onto
                            // NoCookies for every concurrent caller.
                            if session.cookies_remaining() == 0 {
                                let err = NtsError::NoCookies {
                                    trust_backend: Some(session_backend),
                                };
                                guard.complete(Err(err.clone()));
                                return Err(err);
                            }
                            // Capture the leader's freshly-harvested
                            // cookie count *before* the pop below.
                            // This is the "delivered with the KE
                            // response" value warm-cookies waiters
                            // surface as `NtsWarmCookiesOutcome.
                            // fresh_cookies`; capturing here lets the
                            // waiter return that value verbatim
                            // without re-acquiring `map` and without
                            // racing a query waiter that might pop
                            // a cookie before the warm waiter wakes.
                            let harvested_cookies = session.cookies_remaining() as u32;
                            // Same defensive `take`-shape as the
                            // cache-hit branch: the leader's
                            // `cookies_remaining() == 0` check above
                            // guarantees the just-installed jar is
                            // non-empty, so `take` should return
                            // `Some` here. Defend against a future
                            // `CookieJar` refactor silently breaking
                            // that invariant by surfacing
                            // `NoCookies` (and signalling the
                            // singleflight slot with the same shape
                            // so waiters fail-fast on the same
                            // error) rather than panicking with
                            // `expect`.
                            let cookie_opt = {
                                let mut g = lock_recover(&self.map);
                                g.insert(key.clone(), session);
                                let s = g.get_mut(&key).expect("just inserted under this key");
                                s.jar
                                    .take(&s.ntpv4_host)
                                    .map(|cookie| (build_query_context(s, cookie), ()))
                            };
                            match cookie_opt {
                                Some((ctx, ())) => {
                                    guard.complete(Ok(HandshakeSlotOk {
                                        fresh_cookies: harvested_cookies,
                                        trust_backend: session_backend,
                                    }));
                                    return Ok((ctx, ke_timings));
                                }
                                None => {
                                    let err = NtsError::NoCookies {
                                        trust_backend: Some(session_backend),
                                    };
                                    guard.complete(Err(err.clone()));
                                    return Err(err);
                                }
                            }
                        }
                        Err(e) => {
                            guard.complete(Err(e.clone()));
                            return Err(e);
                        }
                    }
                }
                Role::Waiter(slot) => {
                    // Bound the wait by the caller's per-call wall-clock
                    // budget. `started` was captured at the top of this
                    // checkout call, so even if a slow leader runs longer
                    // than `timeout`, the waiter unparks once *its own*
                    // budget elapses and surfaces a Timeout against the
                    // KE record-IO phase (the most accurate single
                    // taxonomy bucket for "stuck waiting on a KE
                    // handshake we did not run ourselves"). Distinct
                    // from the leader's pre-handshake budget-exhaustion
                    // path above (line ~1640), which surfaces
                    // `DnsTimeout` because no record I/O has happened
                    // on the leader thread either — the two cases need
                    // separate operator remediations (parked-waiter:
                    // investigate slow leader; pre-handshake-exhausted:
                    // raise `dnsConcurrencyCap`/`timeoutMs`). See
                    // bd nts-r54.
                    let deadline = started + timeout;
                    match slot.wait_until(deadline) {
                        // Leader installed a session; loop back to phase
                        // A and pop a cookie. The slot's `Ok` payload
                        // carries the leader's harvested count and
                        // trust-backend for warm-cookies waiters; on
                        // the query path we ignore it and re-acquire
                        // `map` for our own cookie pop. If the new
                        // session was already drained by other
                        // concurrently waking waiters, we fall
                        // through to phase B again and either become
                        // the next leader or wait on the next
                        // leader's handshake — `ceil(waiters / N)`
                        // handshake rounds in the worst case, where N is
                        // the cookie-pool size per handshake.
                        Some(Ok(_)) => {}
                        Some(Err(e)) => return Err(e),
                        None => {
                            return Err(NtsError::Timeout {
                                phase: TimeoutPhase::KeRecordIo,
                                trust_backend: None,
                            });
                        }
                    }
                }
            }
        }
    }

    /// Singleflight-aware forced KE handshake. Same per-key role
    /// election as [`checkout_with`], but always runs the leader's
    /// handshake (skips the cache-hit fast-path) and returns the
    /// fresh-cookie count plus the resolved [`TrustBackend`] instead
    /// of a [`QueryContext`]. Production callers go through
    /// [`Self::warm_cookies`], which binds the handshake closure to
    /// the real [`establish_session`]; cache-layer unit tests pass
    /// a controllable closure so the singleflight role-election
    /// state machine is exercisable without standing up a faux
    /// NTS-KE responder.
    ///
    /// Concurrent forced refreshes against the same `host:port`
    /// collapse onto one KE handshake: the first arrival becomes
    /// the singleflight leader, runs the handshake without holding
    /// any lock, installs the freshly-handshaken session under the
    /// `map` lock, then publishes its harvested cookie count and
    /// resolved [`TrustBackend`] on the singleflight slot via
    /// [`HandshakeSlotOk`]; concurrent callers park on the slot
    /// bounded by their own per-call `timeout` budget and, on
    /// success, return the leader's payload verbatim without
    /// re-acquiring the session map. Waiters report
    /// `KePhaseTimings::default()` because they did not perform KE
    /// work themselves — same convention [`checkout_with`] uses for
    /// cache-hit and waiter-wake paths.
    ///
    /// Shares the singleflight key space with [`checkout_with`]:
    /// concurrent `nts_query` and `nts_warm_cookies` against the
    /// same `host:port` collapse onto one handshake, with whichever
    /// caller arrived first becoming the leader. A `nts_query`
    /// waiter ignores the slot's `HandshakeSlotOk` payload and loops
    /// back to the cache to pop a cookie of its own; a
    /// `nts_warm_cookies` waiter returns `payload.fresh_cookies` and
    /// `payload.trust_backend` directly. The warm waiter never
    /// re-reads the cache, so a concurrent `nts_query` waiter that
    /// pops one cookie out of the freshly installed jar between the
    /// leader's install and the warm waiter's wake cannot reduce the
    /// "delivered with the KE response" count surfaced as
    /// [`NtsWarmCookiesOutcome::fresh_cookies`].
    fn warm_cookies_with(
        &self,
        spec: &NtsServerSpec,
        timeout: Duration,
        dns_concurrency_cap: usize,
        do_handshake: &HandshakeFn,
    ) -> Result<(u32, KePhaseTimings, TrustBackend), NtsError> {
        let key = session_key(spec);
        let started = Instant::now();
        // Phase B: leader-or-waiter election. No Phase A — the
        // contract is "force a fresh handshake," so the cache is
        // intentionally bypassed on the leader path. Waiters
        // receive the leader's harvested cookie count and
        // trust-backend via the singleflight slot's `Ok` payload
        // (`HandshakeSlotOk`), so they never re-acquire the session
        // map and the role-election runs at most once per call.
        let role = {
            let mut g = lock_recover(&self.inflight);
            if let Some(slot) = g.get(&key) {
                Role::Waiter(slot.clone())
            } else {
                let slot = Arc::new(HandshakeSlot::new());
                g.insert(key.clone(), slot.clone());
                Role::Leader(slot)
            }
        };

        match role {
            Role::Leader(slot) => {
                let mut guard = LeaderGuard::new(self, key.clone(), slot);
                // Pre-handshake budget exhaustion surfaces `DnsTimeout`,
                // not `KeRecordIo`: no record I/O has happened on this
                // thread yet, and the next phase that *would* have run
                // is DNS. Mirrors the matching site in `checkout_with`
                // (see comment around line ~1640) and the convention
                // [`UdpDeadline::remaining_or_timeout`] uses for
                // pre-DNS budget exhaustion. The waiter case below at
                // line ~1929 keeps `KeRecordIo` because that path *is*
                // genuinely "stuck waiting on a leader's record I/O".
                // Provenance: bd nts-r54.
                let remaining = match timeout.checked_sub(started.elapsed()) {
                    Some(d) if !d.is_zero() => d,
                    _ => {
                        let err = NtsError::Timeout {
                            phase: TimeoutPhase::DnsTimeout,
                            trust_backend: None,
                        };
                        guard.complete(Err(err.clone()));
                        return Err(err);
                    }
                };
                match do_handshake(spec, remaining, dns_concurrency_cap) {
                    Ok((session, ke_timings)) => {
                        let session_backend = session.trust_backend;
                        // Refuse to install a 0-cookie session;
                        // same defensive shape as `checkout_with`.
                        if session.cookies_remaining() == 0 {
                            let err = NtsError::NoCookies {
                                trust_backend: Some(session_backend),
                            };
                            guard.complete(Err(err.clone()));
                            return Err(err);
                        }
                        // Snapshot the freshly-handshaken cookie
                        // count *before* the move. Deriving it
                        // from the post-insert lookup would
                        // either need an `expect` (the `get`
                        // immediately following an `insert` under
                        // the same lock cannot return `None`) or
                        // an `unwrap_or(0)` that would silently
                        // mask an invariant break as a misleading
                        // "warm succeeded with 0 cookies" — the
                        // exact shape the pre-handshake
                        // `cookies_remaining() == 0` guard above
                        // exists to suppress.
                        let count = session.cookies_remaining() as u32;
                        lock_recover(&self.map).insert(key.clone(), session);
                        // Publish the leader's harvested count
                        // and trust-backend on the singleflight
                        // slot so warm-cookies waiters can return
                        // the "delivered with the KE response"
                        // value verbatim, independent of any
                        // cookie pops a concurrent query waiter
                        // might race in between this install and
                        // the warm waiter's wake.
                        guard.complete(Ok(HandshakeSlotOk {
                            fresh_cookies: count,
                            trust_backend: session_backend,
                        }));
                        Ok((count, ke_timings, session_backend))
                    }
                    Err(e) => {
                        guard.complete(Err(e.clone()));
                        Err(e)
                    }
                }
            }
            Role::Waiter(slot) => {
                let deadline = started + timeout;
                match slot.wait_until(deadline) {
                    Some(Ok(payload)) => {
                        // Return the leader's harvested count
                        // verbatim from the slot payload — never
                        // re-snapshot from `map`, because a
                        // concurrent query waiter that wakes from
                        // the same slot may have already popped
                        // a cookie between the leader's install
                        // and our wake. `KePhaseTimings::default()`
                        // because we did not perform KE work
                        // ourselves (matches the convention
                        // `checkout_with` already established for
                        // its waiter and cache-hit paths).
                        Ok((
                            payload.fresh_cookies,
                            KePhaseTimings::default(),
                            payload.trust_backend,
                        ))
                    }
                    Some(Err(e)) => Err(e),
                    // Parked-waiter timeout: keeps `KeRecordIo` because
                    // the waiter is genuinely stuck on a leader's
                    // record I/O syscall. Distinct from the leader's
                    // pre-handshake budget-exhaustion path above (line
                    // ~1862), which surfaces `DnsTimeout` because no
                    // record I/O has happened on the leader thread
                    // either. Same taxonomy as the matching
                    // `checkout_with` waiter site (line ~1765). See
                    // bd nts-r54.
                    None => Err(NtsError::Timeout {
                        phase: TimeoutPhase::KeRecordIo,
                        trust_backend: None,
                    }),
                }
            }
        }
    }

    /// Production wrapper around [`Self::warm_cookies_with`] that
    /// binds the handshake closure to the real [`establish_session`].
    fn warm_cookies(
        &self,
        spec: &NtsServerSpec,
        timeout: Duration,
        dns_concurrency_cap: usize,
        trust_mode: KeTrustMode,
        verification_time_ms: Option<i64>,
    ) -> Result<(u32, KePhaseTimings, TrustBackend), NtsError> {
        self.warm_cookies_with(spec, timeout, dns_concurrency_cap, &move |s, t, c| {
            establish_session(s, t, c, trust_mode.clone(), verification_time_ms)
        })
    }

    /// Deposit fresh cookies harvested from a verified server reply.
    ///
    /// The cookies are AEAD-sealed by the server with the C2S/S2C key pair
    /// from `expected_generation`. If a concurrent `nts_warm_cookies` (or
    /// another `checkout` that ran its own re-handshake) replaced the
    /// session under `spec_key` while this query was on the wire, the
    /// cached entry now holds an unrelated key pair and these cookies
    /// would be unusable against it — every future query that spent one
    /// would round-trip through `NtsError::Authentication` and force yet
    /// another KE handshake. Drop the cookies on the floor in that case;
    /// the next query will simply re-handshake and refill the jar from
    /// scratch, which is strictly cheaper than poisoning the cache.
    /// Record the Unique Identifier echoed by an accepted server
    /// response in the short-lived [`SeenUidCache`], returning `true`
    /// if it was newly seen (the caller should accept the response) or
    /// `false` if it was already recorded within the TTL window (a
    /// replay — the caller must reject the response before depositing
    /// its now-stale cookies). See [`SeenUidCache`] for the full
    /// threat model. Defense-in-depth layered above the AEAD; NTS-40 /
    /// Finding #2.
    ///
    /// Takes the `seen_uids` mutex alone for the duration of the
    /// lookup-and-insert; it is never held alongside `map` or
    /// `inflight`, so it imposes no lock-ordering discipline.
    fn note_unique_id(&self, uid: &[u8]) -> bool {
        lock_recover(&self.seen_uids).note(uid, Instant::now())
    }

    fn deposit_cookies(&self, spec_key: &str, expected_generation: u64, cookies: Vec<Vec<u8>>) {
        if cookies.is_empty() {
            return;
        }
        let mut guard = lock_recover(&self.map);
        if let Some(session) = guard.get_mut(spec_key) {
            if session.generation != expected_generation {
                // Session has been replaced since checkout; these cookies
                // are bound to keys we no longer hold. Discard.
                return;
            }
            let host = session.ntpv4_host.clone();
            session.jar.put_many(&host, cookies);
        }
    }

    /// Drop the cached session for `spec_key` when the in-flight query that
    /// produced the rekey signal was drawn from generation
    /// `expected_generation`.
    ///
    /// Called by [`nts_query_inner`] on either rekey signal: `NtpError::Aead`
    /// (tag mismatch in `parse_server_response`, typically after the
    /// server rotated its master key out from under our cookie pool) or
    /// `NtpError::StaleCookie` (RFC 8915 §5.7 unauthenticated `NTSN`
    /// Kiss-of-Death with a matching Unique Identifier). Removing the
    /// entry rather than just clearing the jar ensures the now-unusable
    /// C2S/S2C keys are also released; the next [`checkout`](Self::checkout)
    /// sees no entry and performs a fresh KE handshake immediately, instead
    /// of draining 7 more stale cookies through identical failures and the
    /// caller's exponential backoff over multiple hours.
    ///
    /// The generation guard is symmetric with
    /// [`deposit_cookies`](Self::deposit_cookies): if a concurrent
    /// `nts_warm_cookies` (or another `checkout` that triggered its own
    /// re-handshake) installed a fresh session under the same key while
    /// this query was on the wire, the failure belongs to the old keys
    /// and the new session must not be evicted. Without the guard a
    /// single transient auth error would force every concurrent caller
    /// for the same host through a redundant re-handshake.
    fn evict_session(&self, spec_key: &str, expected_generation: u64) {
        let mut guard = lock_recover(&self.map);
        if let Some(session) = guard.get(spec_key) {
            if session.generation == expected_generation {
                guard.remove(spec_key);
            }
        }
    }

    /// Replace any existing entry for `spec`'s `host:port` with `session`.
    /// Test-only since 4.0.0: `nts_warm_cookies_inner` now installs
    /// through [`Self::warm_cookies_with`]'s singleflight leader path,
    /// which inserts under the `map` lock and then publishes the
    /// leader's harvested count on the singleflight slot, so cache
    /// installation and slot publication land in a fixed
    /// install-then-publish order even though they occur under
    /// different mutexes. The cache-layer unit tests still use this
    /// shim to seed the table directly without standing up a faux
    /// NTS-KE responder.
    #[cfg(test)]
    fn install(&self, spec: &NtsServerSpec, session: Session) {
        let key = session_key(spec);
        lock_recover(&self.map).insert(key, session);
    }

    /// Drop the cached session for `spec`'s `host:port`. Returns whether
    /// an entry was actually removed.
    fn invalidate(&self, spec: &NtsServerSpec) -> bool {
        lock_recover(&self.map).remove(&session_key(spec)).is_some()
    }

    /// Drop every cached session.
    fn clear(&self) {
        lock_recover(&self.map).clear();
    }
}

/// Cache-layer test compatibility shims. Pre-refactor cache-layer
/// tests in this module call `deposit_cookies` / `evict_session` as
/// free functions; preserve those names against the default client's
/// table so the test bodies stay untouched. Gated to `#[cfg(test)]`
/// so they are dead-stripped from release builds.
#[cfg(test)]
fn deposit_cookies(spec_key: &str, expected_generation: u64, cookies: Vec<Vec<u8>>) {
    default_session_table().deposit_cookies(spec_key, expected_generation, cookies);
}

#[cfg(test)]
fn evict_session(spec_key: &str, expected_generation: u64) {
    default_session_table().evict_session(spec_key, expected_generation);
}

/// Resolve `(host, port)` and return a UDP socket bound to the local
/// wildcard address of the matching family, already `connect()`ed to the
/// first remote candidate that accepts the binding.
///
/// Resolution honours whatever `getaddrinfo` (or its platform equivalent)
/// returns through [`ToSocketAddrs`] — on Apple, glibc, and musl that
/// already implements the RFC 6724 destination-address selection rules,
/// so no per-address scoring is needed here. The wildcard bind is the
/// idiomatic way to pick an ephemeral source port; a bound socket whose
/// family does not match the destination would emit
/// `AddrNotAvailable` / `Network is unreachable` on `connect`, which is
/// the exact failure mode this helper exists to eliminate.
///
/// The first remote address whose `bind` + `connect` pair both succeed
/// wins. Per-address failures are accumulated into a single
/// `NtsError::Network` so the caller (and therefore the Dart side via
/// FRB) sees the full picture rather than just the last error.
///
/// `timeout` is enforced as a single global deadline that spans every
/// blocking phase of the UDP setup — bounded DNS lookup (via the
/// resolver in [`crate::nts::dns`]), the per-address `bind`+`connect`
/// loop, and the read/write timeouts written onto the returned socket
/// (which then bound the subsequent `send`/`recv` in [`nts_query`]).
/// The deadline is anchored once via [`UdpDeadline::new`] and the
/// remaining budget is consulted before the lookup and again before
/// `set_read_timeout`/`set_write_timeout` so the wall-clock cost of
/// the UDP phase cannot exceed `timeout` regardless of how it is
/// distributed across DNS and I/O. Either an elapsed budget or a
/// resolver that exceeded its slice surfaces as `NtsError::Timeout`
/// rather than as a generic network error so the Dart side can
/// distinguish a stalled `getaddrinfo` from a true reachability
/// failure.
///
/// Empty resolution (e.g. NXDOMAIN) maps to
/// `NtsError::Network("no addresses resolved for host:port")`.
///
/// Single wall-clock budget shared across the UDP setup phase — the
/// bounded DNS lookup *and* the read/write timeouts written onto the
/// returned socket. Anchored once from `Instant::now() + total` at the
/// top of [`bind_connected_udp_using`] so the budget shrinks
/// monotonically as DNS consumes time, in place of the prior pattern
/// where the caller's `timeout` was passed verbatim to both phases and
/// the wall-clock cost of one UDP setup could overshoot it by up to 2x.
///
/// This is the UDP companion to the `Deadline` newtype private to
/// [`crate::nts::ke`]; the two intentionally do not share an
/// implementation because `apply_to` must be socket-type-aware
/// (`TcpStream` vs `UdpSocket`) and the duplicated surface is small.
#[derive(Debug, Clone, Copy)]
struct UdpDeadline(Instant);

impl UdpDeadline {
    /// Anchor a deadline `total` from `now`. Callers pass the entire
    /// caller-visible UDP-phase budget; subsequent steps consult
    /// [`UdpDeadline::remaining_or_timeout`] before issuing any
    /// blocking syscall or arming a socket-level timeout.
    fn new(total: Duration) -> Self {
        Self(Instant::now() + total)
    }

    /// Time left before the deadline expires. Saturates at
    /// [`Duration::ZERO`] so callers can branch on `is_zero()` without
    /// handling a negative-duration case.
    fn remaining(&self) -> Duration {
        self.0.saturating_duration_since(Instant::now())
    }

    /// Convenience wrapper that yields the remaining budget when there
    /// is still time on the clock and `NtsError::Timeout { phase, trust_backend: None }` once
    /// the deadline has elapsed. Callers use this immediately before a
    /// blocking step so an already-blown budget short-circuits cleanly
    /// instead of re-arming a zero-length socket timeout (which the
    /// platform may reject with `EINVAL`) or making a doomed
    /// `resolve_with_global` call. The `phase` argument identifies
    /// which step *would* have consumed the elapsed window — the
    /// pre-DNS callsite tags `DnsTimeout`, the post-DNS / pre-NTP
    /// callsite tags `Ntp` (the next blocking step is the AEAD-NTPv4
    /// `send`/`recv` round-trip).
    fn remaining_or_timeout(&self, phase: TimeoutPhase) -> Result<Duration, NtsError> {
        let remaining = self.remaining();
        if remaining.is_zero() {
            return Err(NtsError::Timeout {
                phase,
                trust_backend: None,
            });
        }
        Ok(remaining)
    }
}

/// UDP socket plus the wall-clock microseconds the bounded DNS lookup
/// consumed during setup. Returned by [`bind_connected_udp_using`] so
/// callers can fold the UDP-path DNS cost into [`PhaseTimings`]
/// without re-instrumenting the resolver.
#[derive(Debug)]
struct UdpBindOutcome {
    socket: UdpSocket,
    dns_micros: i64,
}

fn bind_connected_udp(
    host: &str,
    port: u16,
    timeout: Duration,
    dns_concurrency_cap: usize,
) -> Result<UdpBindOutcome, NtsError> {
    bind_connected_udp_using(host, port, timeout, dns_concurrency_cap, system_lookup)
}

/// Test-friendly variant of [`bind_connected_udp`] that takes a
/// caller-supplied lookup closure. Production callers go through
/// [`bind_connected_udp`] which forwards [`system_lookup`]; the
/// `nts-6ka` slow-DNS regression test injects a closure that
/// `thread::sleep`s past the budget so the
/// `ErrorKind::TimedOut → NtsError::Timeout` mapping can be exercised
/// deterministically without standing up an adversarial nameserver.
///
/// Honours the same single-budget-spans-DNS-and-UDP-I/O contract as
/// [`bind_connected_udp`]; see that function for the deadline rules.
fn bind_connected_udp_using<F>(
    host: &str,
    port: u16,
    timeout: Duration,
    dns_concurrency_cap: usize,
    lookup: F,
) -> Result<UdpBindOutcome, NtsError>
where
    F: FnOnce(&str, u16) -> std::io::Result<Vec<SocketAddr>> + Send + 'static,
{
    let deadline = UdpDeadline::new(timeout);
    // Pre-DNS budget exhaustion is tagged as `DnsTimeout` because
    // that is the next phase the call would have entered — see the
    // `remaining_or_timeout` rustdoc.
    let dns_budget = deadline.remaining_or_timeout(TimeoutPhase::DnsTimeout)?;
    let dns_started = Instant::now();
    let candidates: Vec<SocketAddr> =
        match resolve_with_global(host, port, dns_budget, dns_concurrency_cap, lookup) {
            Ok(v) => v,
            Err(e) => {
                // Distinguish saturation (pool already full, no worker
                // dispatched) from a slow resolver (worker dispatched
                // but `recv_timeout` fired) so callers can pick the
                // right remediation. Other I/O kinds are real lookup
                // failures and surface as `Network` with the
                // diagnostic preserved.
                return Err(match e.kind() {
                    std::io::ErrorKind::WouldBlock => NtsError::Timeout {
                        phase: TimeoutPhase::DnsSaturation,
                        trust_backend: None,
                    },
                    std::io::ErrorKind::TimedOut => NtsError::Timeout {
                        phase: TimeoutPhase::DnsTimeout,
                        trust_backend: None,
                    },
                    _ => NtsError::Network {
                        message: format!("DNS lookup failed for {host}:{port}: {e}"),
                        trust_backend: None,
                    },
                });
            }
        };
    let dns_micros = dns_started.elapsed().as_micros() as i64;
    if candidates.is_empty() {
        return Err(NtsError::Network {
            message: format!("no addresses resolved for {host}:{port}"),
            trust_backend: None,
        });
    }
    let mut errors: Vec<String> = Vec::with_capacity(candidates.len());
    for addr in &candidates {
        // `[::]:0` works as a dual-stack bind on most modern stacks but
        // causes `connect` to fail when the kernel has IPV6_V6ONLY
        // forced on (Linux with `net.ipv6.bindv6only=1`, OpenBSD by
        // default). Always pairing the bind family with the destination
        // family avoids that whole class of failure.
        let local: SocketAddr = match addr {
            SocketAddr::V4(_) => "0.0.0.0:0".parse().expect("constant is valid"),
            SocketAddr::V6(_) => "[::]:0".parse().expect("constant is valid"),
        };
        let socket = match UdpSocket::bind(local) {
            Ok(s) => s,
            Err(e) => {
                errors.push(format!("bind {local} for {addr}: {e}"));
                continue;
            }
        };
        // Set socket timeouts to the *remaining* budget rather than the
        // caller's original `timeout`. The subsequent `send`/`recv` in
        // `nts_query` inherit these values, so the only blocking
        // post-bind syscall (`recv`) trips no later than the global
        // deadline. Re-arming the original `timeout` here is exactly
        // the regression nts-zf2 fixes — it allowed the UDP phase to
        // overshoot the caller's budget by up to 2x.
        //
        // Tag a post-DNS budget exhaustion as `Ntp` because the next
        // blocking syscall after this point is the NTP `send`/`recv`.
        let socket_budget = deadline.remaining_or_timeout(TimeoutPhase::Ntp)?;
        if let Err(e) = socket.set_read_timeout(Some(socket_budget)) {
            errors.push(format!("set_read_timeout for {addr}: {e}"));
            continue;
        }
        if let Err(e) = socket.set_write_timeout(Some(socket_budget)) {
            errors.push(format!("set_write_timeout for {addr}: {e}"));
            continue;
        }
        match socket.connect(addr) {
            Ok(()) => return Ok(UdpBindOutcome { socket, dns_micros }),
            Err(e) => errors.push(format!("connect {addr}: {e}")),
        }
    }
    Err(NtsError::Network {
        message: format!(
            "failed to bind/connect any of {} resolved addresses for {host}:{port}: [{}]",
            candidates.len(),
            errors.join("; "),
        ),
        trust_backend: None,
    })
}

/// Run a complete authenticated NTPv4 exchange against `spec`.
///
/// On the first call (or after the cookie pool is exhausted) this performs a
/// full NTS-KE handshake before sending the NTPv4 request; subsequent calls
/// reuse the cached AEAD keys and spend a stored cookie. `timeout_ms` is a
/// single global wall-clock budget that spans DNS, NTS-KE (TCP connect, TLS
/// handshake, record I/O) and the AEAD-NTPv4 UDP exchange as one shrinking
/// deadline; pass `0` for the built-in `5000` ms default.
///
/// `dns_concurrency_cap` is a per-call ceiling on the process-wide bounded
/// DNS resolver (see the module docs in `nts::dns`): if the global in-flight
/// counter has already reached this value when the call attempts a lookup,
/// the call short-circuits with `NtsError::Timeout` instead of spawning
/// another worker thread. The cap defaults (when `0` is passed) to a
/// mobile-friendly value chosen to bound the worst-case stack-leak from a
/// blackholed resolver to a few MB. Server-side callers that legitimately
/// need higher fan-out can override it per call. Because the cap compares
/// against a global counter, two concurrent callers with different caps
/// share the same in-flight pool: the effective ceiling at any moment is
/// whichever caller is currently being admitted.
///
/// `verification_time_ms`, when `Some`, overrides the `now` timestamp
/// the certificate verifier reads, expressed as milliseconds since the
/// Unix epoch. It must be non-negative — a negative value returns
/// `NtsError::InvalidSpec` (see `validate_verification_time_ms`). It
/// pins every time-based check the verifier derives from that timestamp
/// — chiefly the validity window (`notBefore`/`notAfter`), plus any
/// other check the verifier consults `now` for (e.g. stapled-OCSP
/// timing) — while the non-temporal checks (signature, hostname, chain)
/// do not consult `now` and continue to use the inner verifier
/// unchanged. `None` uses the system clock, which
/// is the normal behaviour. This exists to break the cold-start
/// clock-skew deadlock where a wrong system clock would otherwise reject
/// an in-window certificate as expired or not-yet-valid.
///
/// The returned [`NtsTimeSample`] exposes the raw protocol primitives, not a
/// finished synchronized clock. `utc_unix_micros` is the server transmit
/// timestamp exactly as it appeared on the wire; it does not include any
/// compensation for the one-way network delay between the server and this
/// caller. To approximate the server's clock at the moment the reply
/// arrived, callers should add `round_trip_micros / 2` to `utc_unix_micros`
/// (the standard NTP assumption of a symmetric path). For high-precision
/// synchronization, take a burst of samples and pick the one with the
/// smallest `round_trip_micros` before applying that adjustment.
pub fn nts_query(
    spec: NtsServerSpec,
    timeout_ms: u32,
    dns_concurrency_cap: u32,
    verification_time_ms: Option<i64>,
) -> Result<NtsTimeSample, NtsError> {
    default_nts_client().query(spec, timeout_ms, dns_concurrency_cap, verification_time_ms)
}

/// Implementation shared by [`nts_query`] (which delegates to the
/// process-wide default client's table) and [`NtsClient::query`]
/// (which operates on the caller's own table). Parameterising on
/// `&SessionTable` keeps both paths bit-identical except for which
/// cache the cookies and keys live in.
///
/// Production source of the per-request 32-octet Unique Identifier
/// and AEAD nonce. The single funnel through which `nts_query_inner`
/// pulls request-scoped randomness, exposed at module scope so the
/// regression tests
/// [`tests::consecutive_request_uids_from_helper_are_distinct`] and
/// [`tests::consecutive_request_nonces_from_helper_are_distinct`] can
/// drive the same code path the production query uses (rather than
/// reimplementing the `getrandom`-then-pack-into-`ClientRequest`
/// flow inline, which would let `nts_query_inner` drift to a
/// different RNG without the test catching it).
///
/// Both byte-buffers are filled from `getrandom::fill`, which
/// the `getrandom` crate maps to the OS CSPRNG (`getentropy(2)` on
/// macOS/iOS, `getrandom(2)` on Linux/Android, `BCryptGenRandom` on
/// Windows). RFC 8915 §5.6 requires the UID be unpredictable; a
/// regression that swapped this call site for a constant-bytes stub
/// during debugging — or `getrandom` itself selecting a broken
/// backend at build time — would silently lose §5.6 replay
/// protection because the UID echo check in `parse_server_response`
/// would still match.
///
/// Returns `NtsError::Internal` (with the underlying `getrandom`
/// diagnostic preserved verbatim) on the unreachable-in-practice
/// case where the OS CSPRNG itself fails.
fn fresh_request_uid_and_nonce(nonce_len: usize) -> Result<([u8; UID_LEN], Vec<u8>), NtsError> {
    let mut uid = [0u8; UID_LEN];
    let mut nonce = vec![0u8; nonce_len];
    getrandom::fill(&mut uid)
        .map_err(|e| NtsError::Internal(format!("RNG failed for UID: {e}")))?;
    getrandom::fill(&mut nonce)
        .map_err(|e| NtsError::Internal(format!("RNG failed for nonce: {e}")))?;
    Ok((uid, nonce))
}

/// `trust_mode` is the caller's [`TrustMode`] policy (the default
/// singleton uses `PlatformWithFallback`; caller-minted clients use
/// whatever they were constructed with). `is_default_client` selects
/// whether the post-handshake trust-backend value contributes to the
/// process-global state surfaced by [`nts_trust_status`] — only
/// singleton-path handshakes contribute.
fn nts_query_inner(
    table: &SessionTable,
    spec: NtsServerSpec,
    timeout_ms: u32,
    dns_concurrency_cap: u32,
    trust_mode: KeTrustMode,
    is_default_client: bool,
    verification_time_ms: Option<i64>,
) -> Result<NtsTimeSample, NtsError> {
    validate(&spec)?;
    validate_verification_time_ms(verification_time_ms)?;
    let timeout = effective_timeout(timeout_ms);
    let cap = effective_dns_concurrency_cap(dns_concurrency_cap);
    let key = session_key(&spec);

    // Anchor the call-wide wall-clock budget *before* `checkout` so a
    // KE handshake that consumes most of `timeout` cannot re-arm a
    // fresh `timeout`-long window for the UDP setup leg below. Without
    // this anchor a cold query could overshoot the caller's budget by
    // up to 2x (KE: ~`timeout` then UDP: another fresh `timeout`),
    // which contradicts the documented "single global wall-clock
    // budget" contract on `timeout_ms`.
    let started = Instant::now();
    let (ctx, ke_timings) =
        table.checkout(&spec, timeout, cap, trust_mode, verification_time_ms)?;
    let session_generation = ctx.session_generation;
    if is_default_client {
        crate::nts::trust_state::TRUST_STATE.record_default_backend(ctx.trust_backend.into());
    }

    // Fail-fast recovery: two distinct on-wire signals indicate the
    // cached session is out of step with the server and must be
    // replaced rather than continuing to drain its now-stale cookie
    // pool through identical failures and the caller's per-source
    // exponential backoff (the multi-hour recovery stall observed
    // downstream in consumers).
    //
    // 1. `NtpError::Aead` — the local C2S seal in
    //    `build_client_request` or the S2C verify in
    //    `parse_server_response` failed a tag check. The cached
    //    C2S/S2C keys are out of step with the server's current
    //    master key (the canonical master-key-rotation symptom).
    //
    // 2. `NtpError::StaleCookie` — RFC 8915 §5.7 NTSN Kiss-of-Death
    //    with a matching Unique Identifier. A standards-compliant
    //    server that cannot validate the cookie sends an NTSN reply
    //    *without* an Authenticator (it has no usable session keys
    //    to AEAD-sign with), so a parser that only evicted on
    //    `Aead` would miss this shape entirely and the next call
    //    would keep draining the same dead cookie pool. The
    //    matching UID echoed from the request is the only
    //    authenticity signal here; an off-path attacker who could
    //    observe one wire packet and forge a UID-matching NTSN can
    //    at worst force one extra KE handshake before the next
    //    legitimate response heals the session.
    //
    // The closure operates on `NtpError` rather than the converted
    // `NtsError` because `From<NtpError>` collapses both rekey
    // signals onto distinct `NtsError` variants and we need to
    // distinguish them from sibling `NtpProtocol` shapes
    // (`UnexpectedMode`, `MissingAuthenticator`, etc.) that must
    // *not* trigger an eviction.
    //
    // Eviction is gated on `session_generation`, the snapshot
    // captured at `checkout` time, symmetric to the guard in
    // [`SessionTable::deposit_cookies`]. If a concurrent
    // `nts_warm_cookies` (or another `checkout` that triggered its
    // own re-handshake) installed a fresh session under the same key
    // while this query was on the wire, the in-flight failure belongs
    // to the old keys and the new session must survive untouched.
    // Post-handshake attribution helper. The handshake that produced
    // `ctx` already resolved its trust-backend (recorded in
    // `ctx.trust_backend`); every error fired on this leg should carry
    // that attribution so a Dart-side failure log can pair an
    // `NtsError.network`/`keProtocol`/`timeout` with the same
    // `TrustBackend` a successful sample would have surfaced.
    // Variants whose precondition rules out a backend
    // (`InvalidSpec`, `TrustBackendUnavailable`, `Internal`) silently
    // drop the attribution — see `NtsError::with_trust_backend`.
    let attribute_post_handshake =
        |e: NtsError| -> NtsError { e.with_trust_backend(Some(ctx.trust_backend)) };
    let evict_on_rekey_signal = |err: NtpError| -> NtsError {
        if matches!(&err, NtpError::Aead(_) | NtpError::StaleCookie) {
            table.evict_session(&key, session_generation);
        }
        attribute_post_handshake(NtsError::from(err))
    };

    let (uid, nonce) = fresh_request_uid_and_nonce(ctx.c2s_key.nonce_len())?;

    let transmit_timestamp = system_time_to_ntp64();
    let req = ClientRequest {
        unique_id: uid.to_vec(),
        cookie: ctx.cookie,
        placeholder_count: PLACEHOLDERS_PER_QUERY,
        nonce,
        transmit_timestamp,
    };
    let packet = build_client_request(&req, &ctx.c2s_key).map_err(evict_on_rekey_signal)?;

    // RFC 5905 is address-family agnostic; bind a local socket that matches
    // the family of whichever resolved address actually accepts a UDP
    // connection. The previous hard-coded `0.0.0.0:0` bind silently broke
    // every IPv6-only NTS endpoint (Netnod and several PTB hosts).
    //
    // Subtract the wall-clock already spent in `checkout` (DNS +
    // connect + TLS + KE record I/O on a cold query, microseconds on
    // a warm cache hit) from the caller's budget so the UDP-setup
    // deadline shares the same anchor. An already-elapsed budget
    // short-circuits with `Timeout(Ntp)` here — the next blocking
    // syscall after this point is the AEAD-NTPv4 `send`/`recv`,
    // which is the same phase `bind_connected_udp_using` would tag
    // post-DNS (see its `remaining_or_timeout` comment).
    let udp_budget = remaining_budget_or_ntp_timeout(timeout, started.elapsed())
        .map_err(attribute_post_handshake)?;
    let UdpBindOutcome {
        socket,
        dns_micros: udp_dns_micros,
    } = bind_connected_udp(&ctx.ntpv4_host, ctx.ntpv4_port, udp_budget, cap)
        .map_err(attribute_post_handshake)?;

    let send_at = Instant::now();
    socket
        .send(&packet)
        .map_err(NtsError::from)
        .map_err(attribute_post_handshake)?;

    // Re-arm the socket's read timeout against the call-wide deadline
    // before the only blocking syscall on this leg. The bind-time
    // value written by `bind_connected_udp_using` was anchored at bind
    // completion; without this re-arm a slow `send` or scheduling
    // delay between bind and recv lets the AEAD-NTPv4 `recv` block
    // for that full bind-time budget on top of the time already
    // spent, overshooting the documented single wall-clock budget on
    // `timeout_ms`. Short-circuits to `Timeout(Ntp)` if the call-wide
    // budget is already exhausted by the time we get here. See
    // `arm_recv_against_call_deadline` for the full rationale.
    arm_recv_against_call_deadline(&socket, timeout, started.elapsed())
        .map_err(attribute_post_handshake)?;

    let mut buf = [0u8; 2048];
    let n = socket
        .recv(&mut buf)
        .map_err(NtsError::from)
        .map_err(attribute_post_handshake)?;
    let rtt_micros = send_at.elapsed().as_micros() as i64;

    let response = parse_server_response(&buf[..n], &uid, transmit_timestamp, &ctx.s2c_key)
        .map_err(evict_on_rekey_signal)?;

    // NTS-40 / Finding #2: defense-in-depth replay guard above the
    // AEAD. `parse_server_response` already verified the response
    // echoes this request's Unique Identifier (RFC 8915 §5.3) and
    // `transmit_timestamp` (RFC 5905 §8) and that it seals under the
    // session's S2C key — but those are stateless *echo* checks whose
    // replay resistance assumes per-request UID uniqueness without
    // enforcing it. Reject (before depositing the response's
    // now-stale cookies) if this UID was already accepted inside the
    // short-lived window; the AEAD stays the primary guarantee and
    // this only closes the residual UID-reuse gap the finding names.
    // The session is *not* evicted — a replay is not a rekey signal,
    // so the cached keys and remaining cookies stay valid for the
    // next query.
    if !table.note_unique_id(&response.unique_id) {
        return Err(attribute_post_handshake(NtsError::NtpProtocol {
            message: format!(
                "replayed Unique Identifier: response UID already accepted \
                 within the {}s replay-guard window",
                SEEN_UID_TTL.as_secs()
            ),
            trust_backend: None,
        }));
    }

    let fresh_count = response.fresh_cookies.len() as u32;
    table.deposit_cookies(&key, session_generation, response.fresh_cookies);

    // Combine KE-path DNS time (zero on cache hits) with the UDP-path
    // DNS time so the surface field reflects the full DNS cost of
    // this call, not just one leg. See `PhaseTimings::dns_micros` for
    // the rationale.
    let mut phase_timings = PhaseTimings::from(ke_timings);
    phase_timings.dns_micros = phase_timings.dns_micros.saturating_add(udp_dns_micros);

    log::info!(
        target: "nts::query",
        "NTP sample: host={} stratum={} aead_id={} fresh_cookies={} rtt_us={} trust_backend={:?}",
        spec.host,
        response.header.stratum,
        ctx.aead_id,
        fresh_count,
        rtt_micros,
        ctx.trust_backend,
    );

    Ok(NtsTimeSample {
        utc_unix_micros: ntp64_to_unix_micros(response.header.transmit_timestamp),
        round_trip_micros: rtt_micros,
        server_stratum: response.header.stratum,
        aead_id: ctx.aead_id,
        fresh_cookies: fresh_count,
        phase_timings,
        trust_backend: ctx.trust_backend,
    })
}

/// Force a fresh NTS-KE handshake against `spec` and return the
/// cookie count along with the per-phase wall-clock breakdown.
/// Replaces any cached session for that spec.
///
/// `timeout_ms` and `dns_concurrency_cap` carry the same semantics
/// as on `nts_query` (Dart: `ntsQuery`); pass `0` for either to
/// inherit the built-in default.
///
/// The returned `phase_timings` (Dart: `phaseTimings`) on
/// [`NtsWarmCookiesOutcome`] only covers the KE handshake (DNS,
/// connect, TLS, KE record I/O) — there is no UDP NTP exchange on
/// this path, so the `Ntp` phase is implicitly zero and not
/// represented.
///
/// `verification_time_ms` carries the identical semantics as on
/// [`nts_query`]: when `Some` it substitutes the supplied
/// epoch-milliseconds instant for the system clock as the `now` the
/// certificate verifier reads (must be non-negative; a negative returns
/// `NtsError::InvalidSpec`), pinning every time-based check the verifier
/// derives from `now` — chiefly the validity window — while the
/// non-temporal checks (signature, hostname, chain) are left intact.
/// `None` uses the system clock.
pub fn nts_warm_cookies(
    spec: NtsServerSpec,
    timeout_ms: u32,
    dns_concurrency_cap: u32,
    verification_time_ms: Option<i64>,
) -> Result<NtsWarmCookiesOutcome, NtsError> {
    default_nts_client().warm_cookies(spec, timeout_ms, dns_concurrency_cap, verification_time_ms)
}

/// Implementation shared by [`nts_warm_cookies`] (default-client
/// table) and [`NtsClient::warm_cookies`] (per-client table).
///
/// `trust_mode` is the caller's [`TrustMode`] policy; `is_default_client`
/// selects whether the post-handshake trust-backend value contributes to
/// the process-global state surfaced by [`nts_trust_status`]. See
/// [`nts_query_inner`] for the symmetric plumbing on the query path.
fn nts_warm_cookies_inner(
    table: &SessionTable,
    spec: NtsServerSpec,
    timeout_ms: u32,
    dns_concurrency_cap: u32,
    trust_mode: KeTrustMode,
    is_default_client: bool,
    verification_time_ms: Option<i64>,
) -> Result<NtsWarmCookiesOutcome, NtsError> {
    validate(&spec)?;
    validate_verification_time_ms(verification_time_ms)?;
    let timeout = effective_timeout(timeout_ms);
    let cap = effective_dns_concurrency_cap(dns_concurrency_cap);
    // Route through `SessionTable::warm_cookies` so concurrent forced
    // refreshes against the same `host:port` collapse onto one KE
    // handshake via the singleflight machinery shared with `checkout`.
    // The leader runs a fresh handshake, installs its session, and
    // publishes its harvested cookie count + resolved trust-backend
    // on the singleflight slot via `HandshakeSlotOk`; waiters return
    // those values verbatim from the slot payload (no cache re-read)
    // and report `KePhaseTimings::default()` because they did not
    // perform KE work themselves. See `SessionTable::warm_cookies_with`
    // for the full state-machine documentation.
    let (count, ke_timings, trust_backend) =
        table.warm_cookies(&spec, timeout, cap, trust_mode, verification_time_ms)?;
    if is_default_client {
        crate::nts::trust_state::TRUST_STATE.record_default_backend(trust_backend.into());
    }
    log::info!(
        target: "nts::warm",
        "warm cookies: host={} cookies_in_jar={} trust_backend={:?}",
        spec.host,
        count,
        trust_backend,
    );
    Ok(NtsWarmCookiesOutcome {
        fresh_cookies: count,
        phase_timings: PhaseTimings::from(ke_timings),
        trust_backend,
    })
}

/// Convert `std::time::SystemTime::now()` to an NTPv4 64-bit timestamp.
///
/// This is used purely as the request's transmit timestamp. The server echoes
/// it back as `origin_timestamp`; the round-trip is measured locally with
/// `Instant`, so a clock that is wildly wrong here does not affect accuracy.
fn system_time_to_ntp64() -> u64 {
    let now = std::time::SystemTime::now();
    match now.duration_since(std::time::UNIX_EPOCH) {
        Ok(d) => unix_duration_to_ntp64(d),
        Err(_) => 0,
    }
}

fn unix_duration_to_ntp64(d: Duration) -> u64 {
    let secs_unix = d.as_secs();
    let secs_ntp = secs_unix.saturating_add(NTP_TO_UNIX_EPOCH_SECS);
    // NTP fraction: 32-bit fixed point of seconds (2^32 ticks per second).
    let frac = ((d.subsec_nanos() as u64) << 32) / 1_000_000_000u64;
    ((secs_ntp & 0xFFFF_FFFF) << 32) | (frac & 0xFFFF_FFFF)
}

/// Convert a 64-bit NTPv4 timestamp to microseconds since the Unix epoch.
///
/// Returns `i64::MIN`/`i64::MAX` saturation if the value lies outside the
/// representable Unix-micros range (e.g. the all-zero epoch).
fn ntp64_to_unix_micros(ntp: u64) -> i64 {
    let secs_ntp = (ntp >> 32) & 0xFFFF_FFFF;
    let frac = ntp & 0xFFFF_FFFF;
    // Convert NTP seconds (epoch 1900) to Unix seconds (epoch 1970).
    let secs_unix = (secs_ntp as i64) - (NTP_TO_UNIX_EPOCH_SECS as i64);
    // Fraction → microseconds: frac * 1_000_000 / 2^32.
    let micros = (frac.saturating_mul(1_000_000)) >> 32;
    secs_unix
        .saturating_mul(1_000_000)
        .saturating_add(micros as i64)
}

// Compile-time pin that the FFI-bridged trust enums implement
// `Hash`. See the matching pin in `crate::nts::records` for
// rationale, including the `_`-prefix-vs-`#[expect]` choice for
// the const name.
const _ASSERT_HASH_DERIVES: fn() = || {
    fn requires_hash<T: std::hash::Hash>() {}
    requires_hash::<TrustMode>();
    requires_hash::<TrustBackend>();
};

#[cfg(test)]
mod tests;

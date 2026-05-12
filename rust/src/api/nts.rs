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

use std::collections::HashMap;
use std::net::{SocketAddr, UdpSocket};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, OnceLock};
use std::time::{Duration, Instant};

use crate::nts::aead::{AeadError, AeadKey};
use crate::nts::cookies::CookieJar;
use crate::nts::dns::{resolve_with_global, system_lookup, DEFAULT_MAX_INFLIGHT_DNS_LOOKUPS};
use crate::nts::ke::{
    perform_handshake, KeError, KeFailure, KeOutcome, KePhaseTimings, KeRequest, KeTimeoutPhase,
};
use crate::nts::ntp::{build_client_request, parse_server_response, ClientRequest, NtpError};
use crate::nts::records::aead as aead_ids;

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
/// Returns three observables that callers cannot recover from a
/// per-query [`NtsTimeSample`] alone:
///
/// 1. `default_client_backend` — backend the *default singleton*
///    [`NtsClient`] (the one used by [`nts_query`] and
///    [`nts_warm_cookies`]) most recently resolved to. `None` when
///    no handshake has run yet against the singleton (process just
///    started, or all queries so far went through caller-minted
///    clients). Custom-client callers should read the per-handshake
///    `trust_backend` field on [`NtsTimeSample`] /
///    [`NtsWarmCookiesOutcome`] for accurate per-client attribution
///    instead.
/// 2. `android_platform_init_succeeded` — `true` iff
///    `com.nllewellyn.nts.PlatformInit.nativeInit` reported success
///    at least once. `false` on every other platform. A `false` value
///    on Android implies subsequent handshakes will run against the
///    `webpki-roots` static bundle regardless of [`TrustMode`].
/// 3. `android_hybrid_fallback_count` — cumulative count of TLS
///    chains the Android `HybridVerifier` has accepted via the
///    `webpki-roots` fallback path. Always zero on non-Android
///    platforms. The curated fallback-eligible failure shapes are
///    documented on the `HybridVerifier` Rust source.
///
/// Reads three atomics with `Relaxed` ordering. The snapshot is
/// intended for human / dashboard consumption, not for cross-thread
/// synchronisation; per-counter monotonicity holds, but cross-counter
/// invariants within a single snapshot do not.
///
/// Marked `#[frb(sync)]` for the same reason as
/// [`nts_dns_pool_stats`]: the underlying state read is cheap enough
/// that paying isolate-hop overhead would dominate the call.
#[flutter_rust_bridge::frb(sync)]
pub fn nts_trust_status() -> NtsTrustStatus {
    let snap = crate::nts::trust_state::TRUST_STATE.snapshot();
    NtsTrustStatus {
        default_client_backend: snap.default_backend.map(TrustBackend::from),
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
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
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
}

/// Caller-selected policy for which trust-anchor backend [`NtsClient`]
/// is willing to run against. Set immutably at client construction and
/// applied to every handshake the client initiates.
///
/// The default singleton client used by the top-level convenience
/// functions ([`nts_query`], [`nts_warm_cookies`]) is constructed with
/// [`TrustMode::PlatformWithFallback`] and never changes, so existing
/// callers see no behaviour change.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
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
    /// 2. **Per-chain** on Android (3.1.0, BREAKING): the
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
}

impl From<TrustMode> for crate::nts::ke::KeTrustMode {
    fn from(m: TrustMode) -> Self {
        match m {
            TrustMode::PlatformWithFallback => Self::PlatformWithFallback,
            TrustMode::PlatformOnly => Self::PlatformOnly,
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
        }
    }
}

impl From<TrustBackend> for crate::nts::trust_state::InternalTrustBackend {
    fn from(b: TrustBackend) -> Self {
        match b {
            TrustBackend::Platform => Self::Platform,
            TrustBackend::PlatformWithHybridFallback => Self::PlatformWithHybridFallback,
            TrustBackend::WebpkiRoots => Self::WebpkiRoots,
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
        }
    }
}

/// Process-global trust-anchor diagnostic snapshot returned by
/// [`nts_trust_status`] (Dart: `ntsTrustStatus`).
///
/// The fields combine static facts (which backend the default
/// singleton client resolved to at first-handshake time, whether the
/// Android JNI bootstrap succeeded) with one dynamic counter (how
/// many times the Android hybrid verifier has overridden the
/// platform verdict with a webpki-roots fallback since process
/// start). Fields not relevant to the current platform are reported
/// with the documented "n/a" sentinel rather than omitted, so the
/// snapshot has the same shape on every host.
#[derive(Debug, Clone)]
pub struct NtsTrustStatus {
    /// Backend the default singleton client most recently resolved to
    /// at handshake time. `None` when no handshake has run yet
    /// against the singleton (e.g. process just started, or all
    /// queries so far went through caller-minted [`NtsClient`]
    /// instances). Custom-client callers should read the per-handshake
    /// `trust_backend` field on [`NtsTimeSample`] /
    /// [`NtsWarmCookiesOutcome`] for accurate per-client attribution.
    pub default_client_backend: Option<TrustBackend>,
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
        });
        Self::from(f.error).with_trust_backend(public_backend)
    }
}

impl From<NtpError> for NtsError {
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
        let mut g = self.result.lock().expect("singleflight slot poisoned");
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
                .expect("singleflight slot poisoned");
            g = next_g;
        }
    }

    /// Publish the leader's result and wake every parked waiter. Idempotent;
    /// a second `complete` is silently ignored so the LeaderGuard's Drop
    /// path can fire after a normal explicit completion without
    /// clobbering the published value.
    fn complete(&self, result: Result<HandshakeSlotOk, NtsError>) {
        let mut g = self.result.lock().expect("singleflight slot poisoned");
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
        let mut g = self
            .table
            .inflight
            .lock()
            .expect("inflight singleflight map poisoned");
        self.slot.complete(result);
        g.remove(&self.key);
        self.completed = true;
    }
}

impl<'a> Drop for LeaderGuard<'a> {
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
            let mut g = self
                .table
                .inflight
                .lock()
                .expect("inflight singleflight map poisoned");
            self.slot.complete(Err(NtsError::Internal(
                "singleflight leader aborted before publishing a result".into(),
            )));
            g.remove(&self.key);
        }
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
}

impl SessionTable {
    fn new() -> Self {
        Self {
            map: Mutex::new(HashMap::new()),
            inflight: Mutex::new(HashMap::new()),
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
    trust_mode: TrustMode,
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
            trust_mode: TrustMode::PlatformWithFallback,
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
            trust_mode,
            is_default: false,
        }
    }

    /// Trust-anchor policy this client was constructed with. Useful
    /// for diagnostics and for callers that round-trip a client
    /// handle through their own configuration layer and need to
    /// re-derive the policy without keeping a parallel record.
    #[flutter_rust_bridge::frb(sync)]
    pub fn trust_mode(&self) -> TrustMode {
        self.trust_mode
    }

    /// Per-client equivalent of the top-level `nts_query`
    /// (`ntsQuery` on the Dart side).
    pub fn query(
        &self,
        spec: NtsServerSpec,
        timeout_ms: u32,
        dns_concurrency_cap: u32,
    ) -> Result<NtsTimeSample, NtsError> {
        nts_query_inner(
            &self.table,
            spec,
            timeout_ms,
            dns_concurrency_cap,
            self.trust_mode,
            self.is_default,
        )
    }

    /// Per-client equivalent of the top-level `nts_warm_cookies`
    /// (`ntsWarmCookies` on the Dart side).
    pub fn warm_cookies(
        &self,
        spec: NtsServerSpec,
        timeout_ms: u32,
        dns_concurrency_cap: u32,
    ) -> Result<NtsWarmCookiesOutcome, NtsError> {
        nts_warm_cookies_inner(
            &self.table,
            spec,
            timeout_ms,
            dns_concurrency_cap,
            self.trust_mode,
            self.is_default,
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
        trust_mode: TrustMode::PlatformWithFallback,
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
/// The KE driver offers AES-SIV-CMAC-256 first and AES-128-GCM-SIV second:
/// the SIV-CMAC variant is the RFC 8915 §5.1 mandatory baseline and is what
/// every public NTS server we tested actually picks today; GCM-SIV is added
/// purely so a server that prefers nonce-misuse-resistant GCM still resolves
/// to a usable AEAD instead of `UnsupportedAead`.
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
    trust_mode: TrustMode,
) -> Result<(Session, KePhaseTimings), NtsError> {
    let req = KeRequest {
        host: spec.host.clone(),
        port: spec.port,
        aead_algorithms: vec![aead_ids::AES_SIV_CMAC_256, aead_ids::AES_128_GCM_SIV],
        timeout: Some(timeout),
        dns_concurrency_cap,
        trust_mode: trust_mode.into(),
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
    cookie: Vec<u8>,
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
fn build_query_context(s: &Session, cookie: Vec<u8>) -> QueryContext {
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
        trust_mode: TrustMode,
    ) -> Result<(QueryContext, KePhaseTimings), NtsError> {
        self.checkout_with(spec, timeout, dns_concurrency_cap, &move |s, t, c| {
            establish_session(s, t, c, trust_mode)
        })
    }

    /// Singleflight-aware checkout parameterised over the handshake
    /// callback. Production callers go through `checkout`, which binds
    /// the callback to the real `establish_session`; cache-layer unit
    /// tests pass a controllable closure so they can drive the leader
    /// path (count invocations, block until released, fail
    /// deterministically) without standing up a faux NTS-KE responder.
    /// The closure signature mirrors `establish_session`.
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
                let mut g = self.map.lock().expect("session table poisoned");
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
                let mut g = self
                    .inflight
                    .lock()
                    .expect("inflight singleflight map poisoned");
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
                    // exhausted, surface the same `KeRecordIo` timeout
                    // a waiter that hit its deadline would have
                    // surfaced.
                    let remaining = match timeout.checked_sub(started.elapsed()) {
                        Some(d) if !d.is_zero() => d,
                        _ => {
                            guard.complete(Err(NtsError::Timeout {
                                phase: TimeoutPhase::KeRecordIo,
                                trust_backend: None,
                            }));
                            return Err(NtsError::Timeout {
                                phase: TimeoutPhase::KeRecordIo,
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
                                let mut g = self.map.lock().expect("session table poisoned");
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
                    // handshake we did not run ourselves").
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
                        Some(Ok(_)) => continue,
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
            let mut g = self
                .inflight
                .lock()
                .expect("inflight singleflight map poisoned");
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
                let remaining = match timeout.checked_sub(started.elapsed()) {
                    Some(d) if !d.is_zero() => d,
                    _ => {
                        let err = NtsError::Timeout {
                            phase: TimeoutPhase::KeRecordIo,
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
                        self.map
                            .lock()
                            .expect("session table poisoned")
                            .insert(key.clone(), session);
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
        trust_mode: TrustMode,
    ) -> Result<(u32, KePhaseTimings, TrustBackend), NtsError> {
        self.warm_cookies_with(spec, timeout, dns_concurrency_cap, &move |s, t, c| {
            establish_session(s, t, c, trust_mode)
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
    fn deposit_cookies(&self, spec_key: &str, expected_generation: u64, cookies: Vec<Vec<u8>>) {
        if cookies.is_empty() {
            return;
        }
        let mut guard = self.map.lock().expect("session table poisoned");
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
        let mut guard = self.map.lock().expect("session table poisoned");
        if let Some(session) = guard.get(spec_key) {
            if session.generation == expected_generation {
                guard.remove(spec_key);
            }
        }
    }

    /// Replace any existing entry for `spec`'s `host:port` with `session`.
    /// Test-only since 3.1.0: `nts_warm_cookies_inner` now installs
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
        self.map
            .lock()
            .expect("session table poisoned")
            .insert(key, session);
    }

    /// Drop the cached session for `spec`'s `host:port`. Returns whether
    /// an entry was actually removed.
    fn invalidate(&self, spec: &NtsServerSpec) -> bool {
        self.map
            .lock()
            .expect("session table poisoned")
            .remove(&session_key(spec))
            .is_some()
    }

    /// Drop every cached session.
    fn clear(&self) {
        self.map.lock().expect("session table poisoned").clear();
    }
}

/// Cache-layer test compatibility shims. Pre-refactor cache-layer
/// tests in this module call `deposit_cookies` / `evict_session` as
/// free functions; preserve those names against the default client's
/// table so the test bodies stay untouched. Gated to `#[cfg(test)]`
/// so they are dead-stripped from release builds.
#[cfg(test)]
fn deposit_cookies(spec_key: &str, expected_generation: u64, cookies: Vec<Vec<u8>>) {
    default_session_table().deposit_cookies(spec_key, expected_generation, cookies)
}

#[cfg(test)]
fn evict_session(spec_key: &str, expected_generation: u64) {
    default_session_table().evict_session(spec_key, expected_generation)
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
) -> Result<NtsTimeSample, NtsError> {
    default_nts_client().query(spec, timeout_ms, dns_concurrency_cap)
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
/// regression test
/// [`tests::consecutive_request_uids_from_helper_are_distinct`] can
/// drive the same code path the production query uses (rather than
/// reimplementing the `getrandom`-then-pack-into-`ClientRequest`
/// flow inline, which would let `nts_query_inner` drift to a
/// different RNG without the test catching it).
///
/// Both byte-buffers are filled from `getrandom::getrandom`, which
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
    getrandom::getrandom(&mut uid)
        .map_err(|e| NtsError::Internal(format!("RNG failed for UID: {e}")))?;
    getrandom::getrandom(&mut nonce)
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
    trust_mode: TrustMode,
    is_default_client: bool,
) -> Result<NtsTimeSample, NtsError> {
    validate(&spec)?;
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
    let (ctx, ke_timings) = table.checkout(&spec, timeout, cap, trust_mode)?;
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
pub fn nts_warm_cookies(
    spec: NtsServerSpec,
    timeout_ms: u32,
    dns_concurrency_cap: u32,
) -> Result<NtsWarmCookiesOutcome, NtsError> {
    default_nts_client().warm_cookies(spec, timeout_ms, dns_concurrency_cap)
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
    trust_mode: TrustMode,
    is_default_client: bool,
) -> Result<NtsWarmCookiesOutcome, NtsError> {
    validate(&spec)?;
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
    let (count, ke_timings, trust_backend) = table.warm_cookies(&spec, timeout, cap, trust_mode)?;
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validate_rejects_empty_host() {
        let err = validate(&NtsServerSpec {
            host: String::new(),
            port: 4460,
        })
        .unwrap_err();
        assert!(matches!(err, NtsError::InvalidSpec(_)), "got {err:?}");
    }

    #[test]
    fn validate_rejects_zero_port() {
        let err = validate(&NtsServerSpec {
            host: "h".into(),
            port: 0,
        })
        .unwrap_err();
        assert!(matches!(err, NtsError::InvalidSpec(_)), "got {err:?}");
    }

    /// Pins the FFI-default behaviour for `dns_concurrency_cap`: a `0`
    /// from Dart is the agreed sentinel for "use the built-in default",
    /// matching `timeout_ms`. Regressing this would silently let a
    /// pathological caller pass `0` and saturate the resolver pool
    /// (since `try_acquire_slot` with `cap = 0` always rejects).
    #[test]
    fn effective_dns_concurrency_cap_substitutes_default_when_zero() {
        assert_eq!(
            effective_dns_concurrency_cap(0),
            DEFAULT_MAX_INFLIGHT_DNS_LOOKUPS,
        );
        assert_eq!(effective_dns_concurrency_cap(1), 1);
        assert_eq!(effective_dns_concurrency_cap(32), 32);
    }

    #[test]
    fn effective_timeout_substitutes_default_when_zero() {
        assert_eq!(
            effective_timeout(0),
            Duration::from_millis(DEFAULT_TIMEOUT_MS.into())
        );
        assert_eq!(effective_timeout(1234), Duration::from_millis(1234));
    }

    #[test]
    fn ntp64_round_trips_through_micros() {
        // 2026-04-25T00:00:00Z = 1777334400 unix seconds = 3986323200 NTP seconds.
        let ntp = 3_986_323_200u64 << 32;
        assert_eq!(ntp64_to_unix_micros(ntp), 1_777_334_400 * 1_000_000);
    }

    #[test]
    fn ntp64_decodes_subsecond_fraction() {
        // 0.5s after the NTP-epoch -> -2208988800.5 Unix seconds.
        let ntp = 1u64 << 31; // top bit of low 32 set => 0.5s frac, secs=0.
        let micros = ntp64_to_unix_micros(ntp);
        assert_eq!(
            micros,
            -(NTP_TO_UNIX_EPOCH_SECS as i64) * 1_000_000 + 500_000
        );
    }

    #[test]
    fn unix_duration_round_trips_to_ntp64() {
        let d = Duration::new(1_777_334_400, 250_000_000); // 2026-04-25, 0.25s.
        let ntp = unix_duration_to_ntp64(d);
        let micros = ntp64_to_unix_micros(ntp);
        assert_eq!(micros, 1_777_334_400 * 1_000_000 + 250_000);
    }

    /// Bind a local IPv4 echo socket and verify `bind_connected_udp`
    /// resolves `127.0.0.1`, picks a matching-family local socket, and
    /// completes a round trip. This is the address-family-matching
    /// regression guard for [`bind_connected_udp`] on the IPv4 leg.
    #[test]
    fn bind_connected_udp_handles_ipv4_loopback() {
        let echo = UdpSocket::bind("127.0.0.1:0").expect("bind echo");
        let echo_port = echo.local_addr().expect("local addr").port();

        // Generous cap so the suite's parallel slow-DNS tests
        // (which leak detached workers for ~2 s) cannot saturate the
        // global pool out from under this test. Pool-cap behaviour
        // itself is covered by `dns::tests::cap_reached_returns_would_block`.
        let UdpBindOutcome { socket, .. } =
            bind_connected_udp("127.0.0.1", echo_port, Duration::from_secs(2), 64)
                .expect("bind_connected_udp");
        assert!(matches!(
            socket.local_addr().expect("local addr"),
            SocketAddr::V4(_)
        ));
        socket.send(b"ping").expect("send");
        let mut buf = [0u8; 16];
        let (n, src) = echo.recv_from(&mut buf).expect("recv");
        assert_eq!(&buf[..n], b"ping");
        assert!(matches!(src, SocketAddr::V4(_)));
    }

    /// IPv6 loopback variant. Skipped at runtime if the host kernel has
    /// no `::1` interface (e.g. some minimal CI images) — that's the
    /// only legitimate reason to skip rather than fail. The whole point
    /// of this fix is to support hosts like Netnod that publish only
    /// AAAA records, and `::1` exercises the same code path.
    #[test]
    fn bind_connected_udp_handles_ipv6_loopback() {
        let echo = match UdpSocket::bind("[::1]:0") {
            Ok(s) => s,
            Err(e) => {
                eprintln!("skipping: host lacks IPv6 loopback support ({e})");
                return;
            }
        };
        let echo_port = echo.local_addr().expect("local addr").port();

        let UdpBindOutcome { socket, .. } =
            bind_connected_udp("::1", echo_port, Duration::from_secs(2), 64)
                .expect("bind_connected_udp");
        assert!(matches!(
            socket.local_addr().expect("local addr"),
            SocketAddr::V6(_)
        ));
        socket.send(b"ping6").expect("send");
        let mut buf = [0u8; 16];
        let (n, src) = echo.recv_from(&mut buf).expect("recv");
        assert_eq!(&buf[..n], b"ping6");
        assert!(matches!(src, SocketAddr::V6(_)));
    }

    /// Build a throwaway `Session` for cookie-jar plumbing tests.
    ///
    /// Uses AES-SIV-CMAC-256 because it's the RFC 8915 §5.1 baseline
    /// and `AeadKey::from_keying_material` will accept any 32-byte
    /// blob — these tests never seal or open packets, they only
    /// exercise the session-table bookkeeping around `deposit_cookies`.
    fn make_test_session(host: &str, ntpv4_port: u16, generation: u64) -> Session {
        let key_material = [0u8; 32];
        let c2s_key = AeadKey::from_keying_material(aead_ids::AES_SIV_CMAC_256, &key_material)
            .expect("32-byte SIV key");
        let s2c_key = AeadKey::from_keying_material(aead_ids::AES_SIV_CMAC_256, &key_material)
            .expect("32-byte SIV key");
        Session {
            generation,
            aead_id: aead_ids::AES_SIV_CMAC_256,
            c2s_key,
            s2c_key,
            ntpv4_host: host.to_owned(),
            ntpv4_port,
            jar: CookieJar::new(),
            trust_backend: TrustBackend::Platform,
        }
    }

    /// Sanity check on the generation oracle: every call must return a
    /// distinct value. If this ever regresses (e.g. someone swaps the
    /// counter for a hash of the spec), the race-fix invariant in
    /// `deposit_cookies` collapses silently.
    #[test]
    fn next_session_generation_is_unique() {
        let a = next_session_generation();
        let b = next_session_generation();
        let c = next_session_generation();
        assert_ne!(a, b);
        assert_ne!(b, c);
        assert_ne!(a, c);
    }

    /// Happy path: when the cached session's generation still matches the
    /// `QueryContext`, fresh cookies land in the jar as before.
    #[test]
    fn deposit_cookies_writes_when_generation_matches() {
        let key = "deposit-match.invalid:4460";
        let gen = next_session_generation();
        let session = make_test_session("deposit-match.invalid", 123, gen);
        sessions()
            .lock()
            .expect("session table poisoned")
            .insert(key.to_owned(), session);

        deposit_cookies(key, gen, vec![vec![1, 2, 3], vec![4, 5, 6]]);

        let guard = sessions().lock().expect("session table poisoned");
        let s = guard.get(key).expect("session present");
        assert_eq!(
            s.cookies_remaining(),
            2,
            "expected both cookies to land in the matched session's jar"
        );
        // Drop the lock before we mutate the table again.
        drop(guard);
        sessions()
            .lock()
            .expect("session table poisoned")
            .remove(key);
    }

    /// Race-fix invariant: when a concurrent handshake replaces the
    /// cached session between checkout and deposit, the in-flight
    /// query's cookies are bound to the old C2S/S2C keys and must be
    /// discarded — depositing them into the new session would cause
    /// every future query to fail authentication and trigger another
    /// (wasted) re-handshake.
    #[test]
    fn deposit_cookies_drops_when_session_replaced() {
        let key = "deposit-mismatch.invalid:4460";
        // Stand up an "old" session and snapshot its generation as a
        // simulated `QueryContext.session_generation`. Generations come
        // from the real oracle so this test exercises the same
        // uniqueness guarantee `establish_session` relies on.
        let stale_generation = next_session_generation();
        let old = make_test_session("deposit-mismatch.invalid", 123, stale_generation);
        sessions()
            .lock()
            .expect("session table poisoned")
            .insert(key.to_owned(), old);

        // Simulate `nts_warm_cookies` (or another `checkout` re-handshake)
        // landing while the original query was on the wire: replace the
        // entry under the same key with a session whose generation has
        // advanced.
        let fresh_generation = next_session_generation();
        assert_ne!(
            stale_generation, fresh_generation,
            "fresh handshake must mint a distinct generation"
        );
        let fresh = make_test_session("deposit-mismatch.invalid", 123, fresh_generation);
        sessions()
            .lock()
            .expect("session table poisoned")
            .insert(key.to_owned(), fresh);

        // Deposit with the *stale* generation — must be a no-op.
        deposit_cookies(key, stale_generation, vec![vec![0xAA; 16]; 4]);

        let guard = sessions().lock().expect("session table poisoned");
        let s = guard.get(key).expect("session present");
        assert_eq!(
            s.cookies_remaining(),
            0,
            "stale-generation cookies must not poison the new session's jar",
        );
        assert_eq!(
            s.generation, fresh_generation,
            "fresh session must still be the one cached",
        );
        drop(guard);
        sessions()
            .lock()
            .expect("session table poisoned")
            .remove(key);
    }

    /// If the session was evicted entirely (no entry at the key), a
    /// late deposit is a quiet no-op rather than a panic. This was
    /// already the behaviour pre-fix; the regression test pins it
    /// explicitly so the new generation check can't accidentally
    /// reintroduce a panic on the missing-entry path.
    #[test]
    fn deposit_cookies_is_noop_when_session_missing() {
        let key = "deposit-missing.invalid:4460";
        // Ensure no leftover from another test.
        sessions()
            .lock()
            .expect("session table poisoned")
            .remove(key);
        // Any generation ID will do — the entry is absent.
        deposit_cookies(key, 1, vec![vec![1, 2, 3]]);
        // No assertion needed beyond "did not panic"; verify the table
        // really is empty for this key.
        let guard = sessions().lock().expect("session table poisoned");
        assert!(guard.get(key).is_none());
    }

    /// Happy path for the fail-fast eviction: when the cached session's
    /// generation matches the in-flight query's snapshot, a tag-mismatch
    /// failure removes the entry so the next `checkout` performs a
    /// fresh KE handshake instead of draining the rest of the now-stale
    /// cookie pool through identical authentication failures.
    #[test]
    fn evict_session_drops_entry_when_generation_matches() {
        let key = "evict-match.invalid:4460";
        let gen = next_session_generation();
        let mut session = make_test_session("evict-match.invalid", 123, gen);
        // Pre-seed the jar so we can assert the *whole* entry is gone,
        // not just its cookie queue.
        let host = session.ntpv4_host.clone();
        session
            .jar
            .put_many(&host, [vec![1u8; 16], vec![2; 16], vec![3; 16]]);
        sessions()
            .lock()
            .expect("session table poisoned")
            .insert(key.to_owned(), session);

        evict_session(key, gen);

        let guard = sessions().lock().expect("session table poisoned");
        assert!(
            guard.get(key).is_none(),
            "matching-generation eviction must drop the entry, jar and keys with it",
        );
    }

    /// Race-fix invariant: if a concurrent re-handshake replaced the
    /// cached session between checkout and the failed exchange, the
    /// in-flight failure belongs to the *old* keys; the freshly-rotated
    /// session must survive. Without this guard a single transient
    /// authentication error would force every concurrent caller for
    /// the same host through a redundant re-handshake.
    #[test]
    fn evict_session_preserves_entry_on_generation_mismatch() {
        let key = "evict-mismatch.invalid:4460";
        let stale_generation = next_session_generation();
        // The in-flight query thinks it's still on this generation.
        sessions().lock().expect("session table poisoned").insert(
            key.to_owned(),
            make_test_session("evict-mismatch.invalid", 123, stale_generation),
        );
        // Concurrent re-handshake lands while the original query was on
        // the wire: replace the entry with one whose generation has
        // advanced.
        let fresh_generation = next_session_generation();
        assert_ne!(
            stale_generation, fresh_generation,
            "generation oracle must hand out distinct values",
        );
        sessions().lock().expect("session table poisoned").insert(
            key.to_owned(),
            make_test_session("evict-mismatch.invalid", 123, fresh_generation),
        );

        // The stale-generation eviction must be a no-op.
        evict_session(key, stale_generation);

        let guard = sessions().lock().expect("session table poisoned");
        let s = guard.get(key).expect("fresh session must survive");
        assert_eq!(
            s.generation, fresh_generation,
            "stale-generation eviction must not drop the freshly-rotated session",
        );
        drop(guard);
        sessions()
            .lock()
            .expect("session table poisoned")
            .remove(key);
    }

    /// A late eviction against an already-evicted (or never-installed)
    /// entry is a quiet no-op rather than a panic. Companion to the
    /// `deposit_cookies_is_noop_when_session_missing` regression guard;
    /// pins the same property for the symmetric eviction path.
    #[test]
    fn evict_session_is_noop_when_session_missing() {
        let key = "evict-missing.invalid:4460";
        // Ensure no leftover from another test.
        sessions()
            .lock()
            .expect("session table poisoned")
            .remove(key);
        // Any generation ID will do — the entry is absent.
        evict_session(key, 1);
        let guard = sessions().lock().expect("session table poisoned");
        assert!(guard.get(key).is_none());
    }

    /// End-to-end coverage for `nts_query`'s fail-fast eviction on
    /// AEAD authentication failure. Pre-installs a session pointing
    /// at a loopback faux server, then has the faux server reply
    /// with the client's own packet but with the LI/VN/Mode byte
    /// flipped from CLIENT (3) to SERVER (4). The mode check
    /// passes, but the AEAD-sealed AAD covers the *original* byte,
    /// so `s2c_key.open_packet` fails on a tag mismatch — surfaced
    /// as `NtsError::Authentication` and routed through
    /// `evict_on_rekey_signal`. The cached entry must be gone after the
    /// call returns so the caller's next `checkout` performs a
    /// fresh KE handshake instead of draining the rest of the
    /// now-stale cookie pool through identical failures and the
    /// per-source exponential backoff that produces the multi-hour
    /// recovery stall downstream consumers observed.
    #[test]
    fn nts_query_evicts_session_on_aead_authentication_failure() {
        let faux_server = UdpSocket::bind("127.0.0.1:0").expect("bind faux server");
        faux_server
            .set_read_timeout(Some(Duration::from_secs(2)))
            .expect("set faux server read timeout");
        let server_port = faux_server.local_addr().expect("local addr").port();
        let host = "127.0.0.1";
        let key = format!("{host}:{server_port}");

        // Defensive cleanup in case a prior test crashed mid-run.
        sessions()
            .lock()
            .expect("session table poisoned")
            .remove(&key);

        // Pre-install a session with a single cookie so `checkout`
        // does not trigger a real KE handshake. The AEAD keys are
        // valid (any 32 bytes is accepted by AES-SIV-CMAC-256), so
        // `build_client_request` produces a real authenticated
        // packet that the faux server can mutate.
        let generation = next_session_generation();
        let mut session = make_test_session(host, server_port, generation);
        session.jar.put_many(host, [vec![0xAB; 32]]);
        sessions()
            .lock()
            .expect("session table poisoned")
            .insert(key.clone(), session);

        let handler = std::thread::spawn(move || {
            let mut buf = [0u8; 2048];
            let (n, src) = faux_server
                .recv_from(&mut buf)
                .expect("faux server recv_from");
            // Flip mode bits in the LI/VN/Mode byte: CLIENT (3) ->
            // SERVER (4). The AEAD-sealed AAD covers the original
            // byte, so the client's S2C open will fail on a tag
            // mismatch — same shape as a real server-side master
            // key rotation.
            buf[0] = (buf[0] & !0b0000_0111) | 0b0000_0100;
            faux_server
                .send_to(&buf[..n], src)
                .expect("faux server send_to");
        });

        let spec = NtsServerSpec {
            host: host.to_owned(),
            port: server_port,
        };
        let result = nts_query(spec, 2_000, 64);
        handler.join().expect("faux server thread panicked");

        match result {
            Err(NtsError::Authentication { .. }) => {}
            other => panic!("expected NtsError::Authentication, got {other:?}"),
        }

        let guard = sessions().lock().expect("session table poisoned");
        assert!(
            guard.get(&key).is_none(),
            "fail-fast eviction must remove the session entry on AEAD authentication failure",
        );
    }

    /// Companion to the AEAD-eviction test: a non-AEAD protocol
    /// failure (server reply still in CLIENT mode, caught by
    /// `UnexpectedMode` before AEAD verify even runs) surfaces as
    /// `NtsError::NtpProtocol` and must NOT evict the session. The
    /// cached keys are still in sync with whatever the server
    /// holds, and a redundant re-handshake on every transient
    /// wire-shape glitch would defeat the whole point of the
    /// cookie pool.
    #[test]
    fn nts_query_preserves_session_on_non_authentication_failure() {
        let faux_server = UdpSocket::bind("127.0.0.1:0").expect("bind faux server");
        faux_server
            .set_read_timeout(Some(Duration::from_secs(2)))
            .expect("set faux server read timeout");
        let server_port = faux_server.local_addr().expect("local addr").port();
        let host = "127.0.0.1";
        let key = format!("{host}:{server_port}");

        sessions()
            .lock()
            .expect("session table poisoned")
            .remove(&key);

        let generation = next_session_generation();
        let mut session = make_test_session(host, server_port, generation);
        session.jar.put_many(host, [vec![0xCD; 32]]);
        sessions()
            .lock()
            .expect("session table poisoned")
            .insert(key.clone(), session);

        let handler = std::thread::spawn(move || {
            let mut buf = [0u8; 2048];
            let (n, src) = faux_server
                .recv_from(&mut buf)
                .expect("faux server recv_from");
            // Echo the request back unmodified — mode is still
            // CLIENT (3), which `parse_server_response` rejects
            // with `UnexpectedMode` before reaching AEAD verify.
            // Maps to `NtsError::NtpProtocol`.
            faux_server
                .send_to(&buf[..n], src)
                .expect("faux server send_to");
        });

        let spec = NtsServerSpec {
            host: host.to_owned(),
            port: server_port,
        };
        let result = nts_query(spec, 2_000, 64);
        handler.join().expect("faux server thread panicked");

        match result {
            Err(NtsError::NtpProtocol { .. }) => {}
            other => panic!("expected NtsError::NtpProtocol, got {other:?}"),
        }

        let guard = sessions().lock().expect("session table poisoned");
        assert!(
            guard.get(&key).is_some(),
            "non-authentication failures must leave the cached session intact",
        );
        assert_eq!(
            guard.get(&key).expect("entry present").generation,
            generation,
            "preserved session must still be the same generation",
        );
        drop(guard);

        // Cleanup so this test does not leak global state to others.
        sessions()
            .lock()
            .expect("session table poisoned")
            .remove(&key);
    }

    /// End-to-end coverage for `nts_query`'s eviction on a
    /// standards-compliant RFC 8915 §5.7 NTSN Kiss-of-Death response.
    /// Pre-installs a session pointing at a loopback faux server, then
    /// has the faux server reply with a stratum-0 / `reference_id`=NTSN
    /// packet that echoes the request's Unique Identifier and contains
    /// no Authenticator (the shape a real server sends when its master
    /// key has rotated and the cookie can no longer be unwrapped).
    ///
    /// The previous AEAD-only eviction path missed this shape entirely:
    /// `parse_server_response` rejected it as `MissingAuthenticator`
    /// (mapped to `NtsError::NtpProtocol`) so the cached session
    /// survived and the caller would keep draining identical failures
    /// through the cookie pool. The new `NtpError::StaleCookie` arm
    /// surfaces the matching-UID NTSN distinctly and routes it through
    /// the same generation-guarded eviction as the AEAD path.
    #[test]
    fn nts_query_evicts_session_on_ntsn_kod_with_matching_uid() {
        use crate::nts::ntp::{
            ext_type, mode, parse_extensions, NtpHeader, HEADER_LEN, STRATUM_KISS_OF_DEATH,
            VERSION_4,
        };

        let faux_server = UdpSocket::bind("127.0.0.1:0").expect("bind faux server");
        faux_server
            .set_read_timeout(Some(Duration::from_secs(2)))
            .expect("set faux server read timeout");
        let server_port = faux_server.local_addr().expect("local addr").port();
        let host = "127.0.0.1";
        let key = format!("{host}:{server_port}");

        sessions()
            .lock()
            .expect("session table poisoned")
            .remove(&key);

        let generation = next_session_generation();
        let mut session = make_test_session(host, server_port, generation);
        session.jar.put_many(host, [vec![0xEF; 32]]);
        sessions()
            .lock()
            .expect("session table poisoned")
            .insert(key.clone(), session);

        let handler = std::thread::spawn(move || {
            let mut buf = [0u8; 2048];
            let (n, src) = faux_server
                .recv_from(&mut buf)
                .expect("faux server recv_from");
            // Recover the client's Unique Identifier so the reply can
            // echo it (RFC 8915 §5.7's MUST). Any other UID would be
            // treated as untrustworthy by the parser and fall through
            // to MissingAuthenticator instead of StaleCookie.
            let exts = parse_extensions(&buf[HEADER_LEN..n]).expect("parse client extensions");
            let client_uid = exts
                .iter()
                .find(|ext| ext.field_type == ext_type::UNIQUE_IDENTIFIER)
                .expect("client request must include a Unique Identifier")
                .body
                .clone();

            // Build a wire-correct §5.7 NAK: stratum 0 + ref_id NTSN +
            // server mode + echoed UID, no Authenticator and no
            // Encrypted Extension Fields.
            let mut header = NtpHeader::client_request(0);
            header.li_vn_mode = (VERSION_4 << 3) | mode::SERVER;
            header.stratum = STRATUM_KISS_OF_DEATH;
            header.reference_id = *b"NTSN";
            let mut reply = header.to_bytes().to_vec();
            reply.extend_from_slice(&crate::nts::ntp::encode_extension(
                ext_type::UNIQUE_IDENTIFIER,
                &client_uid,
            ));
            faux_server
                .send_to(&reply, src)
                .expect("faux server send_to");
        });

        let spec = NtsServerSpec {
            host: host.to_owned(),
            port: server_port,
        };
        let result = nts_query(spec, 2_000, 64);
        handler.join().expect("faux server thread panicked");

        // The unauthenticated NTSN routes through `From<NtpError>` to
        // `NtpProtocol` for the Dart-facing diagnostic, but eviction
        // already fired pre-conversion inside `evict_on_rekey_signal`.
        match result {
            Err(NtsError::NtpProtocol { message: msg, .. }) if msg.contains("NTSN") => {}
            other => panic!("expected NtpProtocol(StaleCookie) for NTSN reply, got {other:?}"),
        }

        let guard = sessions().lock().expect("session table poisoned");
        assert!(
            guard.get(&key).is_none(),
            "RFC 8915 §5.7 NTSN with matching UID must evict the cached session",
        );
    }

    /// Off-path-attacker guard at the integration layer: an
    /// NTSN-shaped reply that does NOT echo the request's Unique
    /// Identifier carries no trust signal and must NOT evict the
    /// session. Pinning this here (not just in the parser unit
    /// tests) guarantees the integration path also refuses to act
    /// on a UID-mismatched NAK.
    #[test]
    fn nts_query_preserves_session_on_ntsn_kod_with_wrong_uid() {
        use crate::nts::ntp::{ext_type, mode, NtpHeader, STRATUM_KISS_OF_DEATH, VERSION_4};

        let faux_server = UdpSocket::bind("127.0.0.1:0").expect("bind faux server");
        faux_server
            .set_read_timeout(Some(Duration::from_secs(2)))
            .expect("set faux server read timeout");
        let server_port = faux_server.local_addr().expect("local addr").port();
        let host = "127.0.0.1";
        let key = format!("{host}:{server_port}");

        sessions()
            .lock()
            .expect("session table poisoned")
            .remove(&key);

        let generation = next_session_generation();
        let mut session = make_test_session(host, server_port, generation);
        session.jar.put_many(host, [vec![0x12; 32]]);
        sessions()
            .lock()
            .expect("session table poisoned")
            .insert(key.clone(), session);

        let handler = std::thread::spawn(move || {
            let mut buf = [0u8; 2048];
            let (_n, src) = faux_server
                .recv_from(&mut buf)
                .expect("faux server recv_from");
            // Build an NTSN reply with a *different* UID — the shape
            // an off-path attacker would forge if they could send to
            // our ephemeral source port without observing our request.
            let mut header = NtpHeader::client_request(0);
            header.li_vn_mode = (VERSION_4 << 3) | mode::SERVER;
            header.stratum = STRATUM_KISS_OF_DEATH;
            header.reference_id = *b"NTSN";
            let mut reply = header.to_bytes().to_vec();
            let attacker_uid = [0xA5u8; 32];
            reply.extend_from_slice(&crate::nts::ntp::encode_extension(
                ext_type::UNIQUE_IDENTIFIER,
                &attacker_uid,
            ));
            faux_server
                .send_to(&reply, src)
                .expect("faux server send_to");
        });

        let spec = NtsServerSpec {
            host: host.to_owned(),
            port: server_port,
        };
        let result = nts_query(spec, 2_000, 64);
        handler.join().expect("faux server thread panicked");

        // Wrong-UID NTSN falls through to `MissingAuthenticator` in
        // the parser, which maps to `NtpProtocol` and bypasses the
        // eviction match arm.
        match result {
            Err(NtsError::NtpProtocol { .. }) => {}
            other => panic!("expected NtpProtocol for wrong-UID NTSN, got {other:?}"),
        }

        let guard = sessions().lock().expect("session table poisoned");
        assert!(
            guard.get(&key).is_some(),
            "wrong-UID NTSN must not evict (no authenticity signal)",
        );
        assert_eq!(
            guard.get(&key).expect("entry present").generation,
            generation,
            "preserved session must still be the same generation",
        );
        drop(guard);
        sessions()
            .lock()
            .expect("session table poisoned")
            .remove(&key);
    }

    /// A hostname that resolves to nothing maps to a structured
    /// `NtsError::Network` rather than panicking. We use the
    /// `.invalid` reserved TLD (RFC 6761 §6.4) so the test never
    /// hits a real DNS responder.
    #[test]
    fn bind_connected_udp_reports_dns_failure() {
        let err = bind_connected_udp("no-such-host.invalid", 123, Duration::from_millis(500), 64)
            .expect_err("must fail");
        match err {
            NtsError::Network { message: msg, .. } => {
                assert!(
                    msg.contains("no-such-host.invalid"),
                    "expected hostname in error, got {msg}",
                );
            }
            other => panic!("expected NtsError::Network, got {other:?}"),
        }
    }

    /// Slow-DNS regression guard for [`bind_connected_udp`]. Injects a
    /// resolver that blocks past the budget and asserts the call
    /// returns `NtsError::Timeout { phase: TimeoutPhase::DnsTimeout, trust_backend: None }` (not
    /// `NtsError::Network`) well inside the cap. Pinning the phase
    /// tag here is what consumers of the post-`nts-r2l` API rely on
    /// to attribute the failure to a stalled `getaddrinfo` rather
    /// than to a downstream NTP or KE step. Companion to
    /// `dns::tests::slow_resolver_*` and
    /// `nts::ke::tests::connect_with_timeout_surfaces_slow_dns_*`; see
    /// `nts-6ka` for the full set of injection points.
    #[test]
    fn bind_connected_udp_surfaces_slow_dns_as_timeout() {
        let budget = Duration::from_millis(50);
        let started = Instant::now();
        let result = bind_connected_udp_using("ignored.invalid", 0, budget, 64, |_host, _port| {
            std::thread::sleep(Duration::from_secs(2));
            Ok(vec![SocketAddr::from(([127, 0, 0, 1], 0))])
        });
        let elapsed = started.elapsed();

        match result {
            Err(NtsError::Timeout {
                phase: TimeoutPhase::DnsTimeout,
                trust_backend: None,
            }) => {}
            other => panic!("slow-DNS path must surface as Timeout(DnsTimeout), got {other:?}",),
        }
        let cap = budget * 5;
        assert!(
            elapsed < cap,
            "bind_connected_udp took {elapsed:?} (> {cap:?}); \
             resolver budget did not propagate",
        );
    }

    /// Pins the `UdpDeadline::remaining_or_timeout` contract: once the
    /// anchored instant has passed, the helper short-circuits with
    /// `NtsError::Timeout(_)` rather than handing back a zero-length
    /// `Duration` (which the platform would reject when fed to
    /// `set_read_timeout`). The connect/bind path in
    /// `bind_connected_udp_using` relies on this to surface budget
    /// exhaustion as a phase-tagged `Timeout` instead of
    /// `NtsError::Network`.
    #[test]
    fn udp_deadline_remaining_or_timeout_after_expiry() {
        let d = UdpDeadline::new(Duration::from_micros(1));
        std::thread::sleep(Duration::from_millis(10));
        assert!(d.remaining().is_zero(), "expired deadline must saturate");
        match d.remaining_or_timeout(TimeoutPhase::Ntp) {
            Err(NtsError::Timeout {
                phase: TimeoutPhase::Ntp,
                trust_backend: None,
            }) => {}
            other => panic!("expired deadline must yield Timeout(Ntp), got {other:?}"),
        }
    }

    /// Drives `bind_connected_udp_using` against a 127.0.0.1 echo
    /// socket but injects a resolver that consumes the bulk of the
    /// budget before returning. The post-bind `set_read_timeout` /
    /// `set_write_timeout` calls must see the *remaining* budget, not
    /// the caller's original `timeout`. We pin both bounds on the
    /// resulting socket: strictly less than the original budget (the
    /// regression this test guards against would re-arm the full
    /// duration) and strictly positive (a zero-length deadline would
    /// short-circuit before bind). Companion to nts-zf2.
    #[test]
    fn bind_connected_udp_socket_timeouts_reflect_remaining_budget() {
        let echo = UdpSocket::bind("127.0.0.1:0").expect("bind echo");
        let echo_addr = echo.local_addr().expect("local addr");
        let echo_port = echo_addr.port();

        let budget = Duration::from_millis(500);
        let dns_consumes = Duration::from_millis(200);
        let UdpBindOutcome { socket, .. } = bind_connected_udp_using(
            "ignored.invalid",
            echo_port,
            budget,
            64,
            move |_host, _port| {
                std::thread::sleep(dns_consumes);
                Ok(vec![SocketAddr::from(([127, 0, 0, 1], echo_port))])
            },
        )
        .expect("bind_connected_udp_using");

        let read_t = socket
            .read_timeout()
            .expect("read_timeout call ok")
            .expect("read timeout set");
        let write_t = socket
            .write_timeout()
            .expect("write_timeout call ok")
            .expect("write timeout set");

        // The original `timeout` was 500 ms and the resolver burned
        // 200 ms of it; the post-bind socket timeouts must therefore
        // be strictly less than 500 ms (and not zero). Allow
        // generous slack on the upper bound so this test is robust
        // to scheduling jitter on slow CI runners while still
        // catching the regression — re-arming the full `timeout`
        // would land the socket timeout at exactly 500 ms.
        let upper_bound = budget - Duration::from_millis(50);
        assert!(
            read_t > Duration::ZERO && read_t < upper_bound,
            "read_timeout {read_t:?} must be in (0, {upper_bound:?}); \
             original budget was {budget:?} and DNS consumed ~{dns_consumes:?}",
        );
        assert!(
            write_t > Duration::ZERO && write_t < upper_bound,
            "write_timeout {write_t:?} must be in (0, {upper_bound:?}); \
             original budget was {budget:?} and DNS consumed ~{dns_consumes:?}",
        );
    }

    /// Companion to `bind_connected_udp_socket_timeouts_reflect_remaining_budget`
    /// for the post-bind portion of `nts_query`. The UDP socket
    /// emerges from `bind_connected_udp` with a read timeout sized to
    /// the budget remaining at *bind* completion; without re-arming
    /// before recv, a slow `send` or scheduling delay between bind
    /// and recv would let recv block for that full bind-time budget
    /// on top of the time already spent, overshooting the documented
    /// single wall-clock budget on `timeout_ms`. Drives the helper
    /// directly with a UDP socket pre-armed to a wide read_timeout
    /// (mirroring the bind-time value) and asserts the re-arm
    /// shrinks the timeout to track the call-wide deadline anchor.
    #[test]
    fn arm_recv_against_call_deadline_shrinks_read_timeout_against_call_anchor() {
        let socket = UdpSocket::bind("127.0.0.1:0").expect("bind");
        let bind_time_value = Duration::from_secs(5);
        socket
            .set_read_timeout(Some(bind_time_value))
            .expect("seed initial read_timeout");

        let total = Duration::from_millis(500);
        let elapsed = Duration::from_millis(200);
        let remaining = arm_recv_against_call_deadline(&socket, total, elapsed)
            .expect("non-zero remaining must yield Ok");

        let read_t = socket
            .read_timeout()
            .expect("read_timeout call ok")
            .expect("read timeout still set");
        assert_eq!(
            read_t, remaining,
            "set_read_timeout must reflect the helper's returned remaining",
        );
        assert!(
            read_t < bind_time_value,
            "re-armed read_timeout {read_t:?} must be strictly less than \
             the seeded bind-time value {bind_time_value:?}",
        );
        assert!(
            read_t < total,
            "re-armed read_timeout {read_t:?} must be strictly less than \
             the call-wide budget {total:?} once {elapsed:?} has elapsed",
        );
        assert!(
            read_t > Duration::ZERO,
            "non-zero remaining must yield a strictly positive timeout, \
             got {read_t:?}",
        );
    }

    /// Expired-budget arm of `arm_recv_against_call_deadline`. Once
    /// the call-wide deadline has lapsed, the helper must
    /// short-circuit with `Timeout(Ntp)` rather than handing back a
    /// zero-length `Duration` (which `set_read_timeout` would reject
    /// on most platforms) or letting the socket be re-armed at all —
    /// the latter would drop the phase-tagged failure shape callers
    /// rely on for attribution.
    #[test]
    fn arm_recv_against_call_deadline_short_circuits_after_expiry() {
        let socket = UdpSocket::bind("127.0.0.1:0").expect("bind");
        let initial = Duration::from_secs(5);
        socket
            .set_read_timeout(Some(initial))
            .expect("seed initial read_timeout");

        let total = Duration::from_millis(100);
        let elapsed = Duration::from_millis(150);
        match arm_recv_against_call_deadline(&socket, total, elapsed) {
            Err(NtsError::Timeout {
                phase: TimeoutPhase::Ntp,
                trust_backend: None,
            }) => {}
            other => panic!("expired call-wide deadline must yield Timeout(Ntp), got {other:?}",),
        }
        let read_t = socket
            .read_timeout()
            .expect("read_timeout call ok")
            .expect("read timeout still set");
        assert_eq!(
            read_t, initial,
            "expired short-circuit must not re-arm the socket; got {read_t:?}",
        );
    }

    /// Pins `From<KeError> for NtsError` for every variant of the
    /// `KeTimeoutPhase` taxonomy. The mapping is the load-bearing
    /// hand-off between the KE layer's phase-tagged failure shape and
    /// the public Dart-facing `NtsError::Timeout(TimeoutPhase)`
    /// surface; a regression that drops one of the variants would
    /// silently re-route the failure through `KeProtocol` (the
    /// catch-all arm) and lose the attribution. The pre-existing
    /// `connect_with_timeout_*` and `bind_connected_udp_*` tests cover
    /// `Connect` and `DnsTimeout` end-to-end; this mapping test
    /// closes the residual gap on `DnsSaturation`, `Tls`, and
    /// `KeRecordIo`, and pins the full set together so the taxonomy
    /// is checked exhaustively in one place.
    #[test]
    fn ke_phase_timeout_maps_to_nts_timeout_for_every_phase() {
        let cases = [
            (KeTimeoutPhase::DnsSaturation, TimeoutPhase::DnsSaturation),
            (KeTimeoutPhase::DnsTimeout, TimeoutPhase::DnsTimeout),
            (KeTimeoutPhase::Connect, TimeoutPhase::Connect),
            (KeTimeoutPhase::Tls, TimeoutPhase::Tls),
            (KeTimeoutPhase::KeRecordIo, TimeoutPhase::KeRecordIo),
        ];
        for (ke_phase, expected) in cases {
            let mapped = NtsError::from(KeError::PhaseTimeout(ke_phase));
            match mapped {
                NtsError::Timeout { phase: got, .. } => assert_eq!(
                    got, expected,
                    "KeTimeoutPhase::{ke_phase:?} mapped to NtsError::Timeout({got:?}); \
                     expected NtsError::Timeout({expected:?})",
                ),
                other => panic!(
                    "KeTimeoutPhase::{ke_phase:?} produced {other:?}; \
                     expected NtsError::Timeout({expected:?})",
                ),
            }
        }
    }

    /// Pins `From<io::Error> for NtsError` for the UDP send/recv
    /// path. Both `TimedOut` (the standard read/write-timeout
    /// signal) and `WouldBlock` (the socket-non-blocking edge case
    /// some platforms surface for an expired SO_RCVTIMEO) must land
    /// on `Timeout(Ntp)` — that conversion site is reached only by
    /// `socket.send` / `socket.recv` in `nts_query` (the KE pipeline
    /// has its own phase-aware funnel, see the rustdoc on the
    /// `From<io::Error>` impl), so `Ntp` is the only correct tag.
    #[test]
    fn io_error_timed_out_or_would_block_maps_to_timeout_ntp() {
        for kind in [std::io::ErrorKind::TimedOut, std::io::ErrorKind::WouldBlock] {
            let io_err = std::io::Error::from(kind);
            match NtsError::from(io_err) {
                NtsError::Timeout {
                    phase: TimeoutPhase::Ntp,
                    trust_backend: None,
                } => {}
                other => panic!(
                    "io::Error of {kind:?} mapped to {other:?}; \
                     expected NtsError::Timeout(Ntp)",
                ),
            }
        }
    }

    /// End-to-end UDP send/recv-timeout regression. Binds a real
    /// `UdpSocket` against an unbound loopback port, arms a tight
    /// `SO_RCVTIMEO`, and proves that the `io::Error` the kernel
    /// returns from `recv` flows through `From<io::Error> for
    /// NtsError` as `Timeout(Ntp)`. This is the integration-level
    /// counterpart to the mapping unit test above and pins the
    /// "actual UDP send/recv timeout" path the public API surfaces
    /// to callers diagnosing a stalled NTPv4 round-trip.
    #[test]
    fn udp_recv_timeout_surfaces_as_timeout_ntp() {
        let socket = UdpSocket::bind("127.0.0.1:0").expect("bind UDP socket");
        // Connect to a port we own but never read from, so any send
        // is silently absorbed and the recv has nothing to read.
        let absorber = UdpSocket::bind("127.0.0.1:0").expect("bind absorber");
        let absorber_addr = absorber.local_addr().expect("absorber local_addr");
        socket.connect(absorber_addr).expect("connect to absorber");
        socket
            .set_read_timeout(Some(Duration::from_millis(50)))
            .expect("set_read_timeout");

        let mut buf = [0u8; 16];
        let started = Instant::now();
        let io_err = socket
            .recv(&mut buf)
            .expect_err("recv with no peer must time out");
        let elapsed = started.elapsed();
        assert!(
            matches!(
                io_err.kind(),
                std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock,
            ),
            "recv produced {:?} (kind {:?}); expected TimedOut/WouldBlock",
            io_err,
            io_err.kind(),
        );
        assert!(
            elapsed < Duration::from_secs(2),
            "recv took {elapsed:?}; SO_RCVTIMEO did not fire",
        );
        match NtsError::from(io_err) {
            NtsError::Timeout {
                phase: TimeoutPhase::Ntp,
                trust_backend: None,
            } => {}
            other => panic!(
                "UDP recv timeout mapped to {other:?}; \
                 expected NtsError::Timeout(Ntp)",
            ),
        }
    }

    /// Pins the `From<KePhaseTimings> for PhaseTimings` mapping.
    /// The Dart-facing struct is reconstructed inside `nts_query` and
    /// `nts_warm_cookies` from the KE-side breakdown; if a future
    /// edit drops or reorders one of the four micro fields the
    /// caller-visible timing dashboard would silently lose a phase.
    #[test]
    fn from_ke_phase_timings_for_phase_timings_preserves_all_micro_fields() {
        let ke = KePhaseTimings {
            dns_micros: 11,
            connect_micros: 22,
            tls_handshake_micros: 33,
            ke_record_io_micros: 44,
        };
        let pt: PhaseTimings = ke.into();
        assert_eq!(pt.dns_micros, 11);
        assert_eq!(pt.connect_micros, 22);
        assert_eq!(pt.tls_handshake_micros, 33);
        assert_eq!(pt.ke_record_io_micros, 44);
    }

    /// `Display for NtsError` is the format consumers see when an
    /// error escapes the public API as a string. The `Timeout` arm
    /// must include the phase tag verbatim — without it the new
    /// taxonomy is invisible to anything reading
    /// `format!("{e}")` rather than matching the enum directly.
    #[test]
    fn display_renders_timeout_with_phase_tag() {
        for phase in [
            TimeoutPhase::DnsSaturation,
            TimeoutPhase::DnsTimeout,
            TimeoutPhase::Connect,
            TimeoutPhase::Tls,
            TimeoutPhase::KeRecordIo,
            TimeoutPhase::Ntp,
        ] {
            let rendered = format!(
                "{}",
                NtsError::Timeout {
                    phase,
                    trust_backend: None
                }
            );
            let tag = format!("{phase:?}");
            assert!(
                rendered.contains(&tag),
                "Display for Timeout({phase:?}) was {rendered:?}; \
                 expected to contain {tag:?}",
            );
        }
    }

    /// Pins the non-timeout half of `From<KeError> for NtsError`:
    /// `KeError::Io` must surface as `NtsError::Network` with the
    /// underlying diagnostic preserved, not collapsed into a
    /// timeout. The phase-timeout half is exhausted by
    /// `ke_phase_timeout_maps_to_nts_timeout_for_every_phase`; this
    /// one guards against a future edit that mistakenly routes a
    /// real I/O failure (NXDOMAIN, ECONNREFUSED, …) through the
    /// timeout taxonomy.
    #[test]
    fn from_ke_error_io_routes_to_network_with_diagnostic() {
        let io = std::io::Error::new(std::io::ErrorKind::ConnectionRefused, "kex-refused");
        match NtsError::from(KeError::Io(io)) {
            NtsError::Network { message: msg, .. } => assert!(
                msg.contains("kex-refused"),
                "Network message {msg:?} dropped the underlying diagnostic",
            ),
            other => panic!("KeError::Io mapped to {other:?}; expected NtsError::Network",),
        }
    }

    /// Pins the call-wide budget contract `nts_query` enforces
    /// between the KE phases and the UDP-setup leg. Once `elapsed`
    /// reaches or exceeds `total`, the helper short-circuits with
    /// `Timeout(Ntp)` rather than handing back `Duration::ZERO`
    /// (which would let `bind_connected_udp_using` re-anchor a
    /// near-zero deadline and emit a misleading `DnsTimeout` tag for
    /// what is in fact a post-KE budget exhaustion). A non-zero
    /// remainder propagates through unchanged, including the
    /// boundary case where the slack is exactly one nanosecond.
    /// Regression for the "single global wall-clock budget" claim
    /// in the `nts_query` rustdoc; without this helper a cold query
    /// could overshoot the caller's budget by up to 2x by re-arming
    /// a fresh `timeout` for the UDP leg.
    #[test]
    fn remaining_budget_or_ntp_timeout_short_circuits_when_elapsed_meets_total() {
        let total = Duration::from_millis(100);
        // Slack remaining: helper hands the difference back unchanged.
        let r = remaining_budget_or_ntp_timeout(total, Duration::from_millis(40))
            .expect("non-zero slack must propagate");
        assert_eq!(r, Duration::from_millis(60));

        // Budget exactly consumed: short-circuit with Timeout(Ntp).
        match remaining_budget_or_ntp_timeout(total, total) {
            Err(NtsError::Timeout {
                phase: TimeoutPhase::Ntp,
                trust_backend: None,
            }) => {}
            other => panic!("elapsed == total must yield Timeout(Ntp), got {other:?}"),
        }

        // Budget overrun: same short-circuit, no panic on saturating sub.
        match remaining_budget_or_ntp_timeout(total, total + Duration::from_millis(50)) {
            Err(NtsError::Timeout {
                phase: TimeoutPhase::Ntp,
                trust_backend: None,
            }) => {}
            other => panic!("elapsed > total must yield Timeout(Ntp), got {other:?}"),
        }

        // Sub-microsecond slack still propagates as Ok.
        let nearly = total - Duration::from_nanos(1);
        let r = remaining_budget_or_ntp_timeout(total, nearly)
            .expect("one-nanosecond slack must propagate");
        assert_eq!(r, Duration::from_nanos(1));
    }

    // --- per-instance NtsClient / SessionTable cache layer ----------
    //
    // The `default_session_table` shim above already pins the
    // checkout / deposit_cookies / evict_session invariants against
    // the process-wide table; the tests in this section pin the
    // *per-instance* invariants the public `NtsClient` handle relies
    // on: lifecycle (`install`, `invalidate`, `clear`), per-instance
    // isolation (a fresh `SessionTable` shares no state with another
    // fresh `SessionTable` or with the default table), and the
    // `bool` return contract on `invalidate`. These tests use plain
    // `make_test_session` rather than running a real NTS-KE
    // handshake, mirroring how the existing cache-layer tests
    // exercise the deposit/evict paths without standing up a live KE
    // responder.

    /// Per-instance lifecycle: `install` adds an entry, `invalidate`
    /// returns `true` on hit and removes it, `invalidate` on a
    /// missing key returns `false` and is a no-op, and `clear`
    /// drops every remaining entry in one call.
    #[test]
    fn session_table_install_invalidate_clear_round_trip() {
        let table = SessionTable::new();
        let spec_a = NtsServerSpec {
            host: "table-rt-a.invalid".into(),
            port: 4460,
        };
        let spec_b = NtsServerSpec {
            host: "table-rt-b.invalid".into(),
            port: 4460,
        };

        let key_a = session_key(&spec_a);
        let key_b = session_key(&spec_b);

        // Install A and B; both visible under their own keys.
        table.install(&spec_a, make_test_session("table-rt-a.invalid", 123, 1));
        table.install(&spec_b, make_test_session("table-rt-b.invalid", 124, 2));
        {
            let g = table.map.lock().expect("test session table poisoned");
            assert!(g.contains_key(&key_a), "spec A must be cached");
            assert!(g.contains_key(&key_b), "spec B must be cached");
        }

        // Invalidate A: returns true, A is gone, B survives.
        assert!(
            table.invalidate(&spec_a),
            "invalidate on a present entry must return true"
        );
        {
            let g = table.map.lock().expect("test session table poisoned");
            assert!(!g.contains_key(&key_a), "spec A must be evicted");
            assert!(g.contains_key(&key_b), "spec B must survive A's eviction");
        }

        // Re-invalidate A: now a no-op that returns false.
        assert!(
            !table.invalidate(&spec_a),
            "invalidate on a missing entry must return false (no-op)"
        );

        // Clear drops everything.
        table.clear();
        let g = table.map.lock().expect("test session table poisoned");
        assert!(
            g.is_empty(),
            "clear must drop every entry; remaining keys: {:?}",
            g.keys().collect::<Vec<_>>()
        );
    }

    /// Per-instance isolation: two fresh `SessionTable`s share no
    /// state, and neither shares with the process-wide default
    /// table. Pins acceptance criterion 3 from `nts-2dd` at the
    /// cache layer (the public `NtsClient` wrapper inherits this
    /// invariant by construction since each `NtsClient::new` mints
    /// a fresh `SessionTable`).
    #[test]
    fn session_table_instances_are_independent() {
        let a = SessionTable::new();
        let b = SessionTable::new();
        let spec = NtsServerSpec {
            host: "table-iso.invalid".into(),
            port: 4460,
        };
        let key = session_key(&spec);

        a.install(&spec, make_test_session("table-iso.invalid", 200, 1));

        // B must be empty for this key.
        {
            let g = b.map.lock().expect("test session table poisoned");
            assert!(
                !g.contains_key(&key),
                "B must not see A's installed session",
            );
        }
        // A must still hold the entry it installed.
        {
            let g = a.map.lock().expect("test session table poisoned");
            assert!(g.contains_key(&key), "A must still hold its own entry");
        }
        // The default table must also not see A's entry. Wrapped in
        // an explicit clear so a stale entry from a previous test on
        // the default table cannot mask the assertion. The eviction
        // below is harmless even if the entry was never present.
        default_session_table().invalidate(&spec);
        {
            let g = default_session_table()
                .map
                .lock()
                .expect("default session table poisoned");
            assert!(
                !g.contains_key(&key),
                "default table must not see entries installed in a fresh SessionTable",
            );
        }

        // Symmetric cleanup so a parallel test on `a` does not see
        // the stub session we left behind here.
        a.clear();
    }

    /// `NtsClient::invalidate` and `NtsClient::clear` are thin
    /// pass-throughs to the owned `SessionTable`. Pins the
    /// `bool` return value on `invalidate` and the empty-after-clear
    /// invariant at the public-handle layer so a future refactor
    /// that drops the delegation surfaces here as well as in the
    /// `SessionTable` tests above.
    #[test]
    fn nts_client_invalidate_and_clear_pass_through_to_table() {
        let client = NtsClient::new();
        let spec = NtsServerSpec {
            host: "client-pass-through.invalid".into(),
            port: 4460,
        };
        let key = session_key(&spec);

        // Empty client: invalidate returns false, no panic, table
        // still empty.
        assert!(
            !client.invalidate(spec.clone()),
            "invalidate on a fresh client must return false",
        );

        // Install via the inner table, then invalidate via the
        // public method. Returns true; the entry is gone.
        client.table.install(
            &spec,
            make_test_session("client-pass-through.invalid", 1, 1),
        );
        assert!(
            client.invalidate(spec.clone()),
            "invalidate on an installed entry must return true",
        );
        {
            let g = client.table.map.lock().expect("client table poisoned");
            assert!(!g.contains_key(&key), "entry must be evicted");
        }

        // `clear` drops everything in one call. Install several
        // entries first so a single-entry clear cannot pass by
        // accident.
        for i in 0..3u16 {
            let s = NtsServerSpec {
                host: format!("client-clear-{i}.invalid"),
                port: 4460 + i,
            };
            client
                .table
                .install(&s, make_test_session(&s.host, 1, (10 + i).into()));
        }
        client.clear();
        let g = client.table.map.lock().expect("client table poisoned");
        assert!(
            g.is_empty(),
            "clear must drop every entry; remaining: {:?}",
            g.keys().collect::<Vec<_>>()
        );
    }

    /// `validate` rejects an empty host / zero port before any cache
    /// or network work happens, on both the per-client surface
    /// (`NtsClient::query`, `NtsClient::warm_cookies`) and the
    /// top-level free function (`nts_warm_cookies`). Companions to
    /// the existing pre-3.1 validation tests for `nts_query`.
    ///
    /// Operationally redundant because the four delegation paths all
    /// land in the same `validate(&spec)?` line in the `_inner`
    /// helpers; pinning each call site individually is what gives
    /// codecov a covered patch line on the per-client method bodies
    /// and on the top-level `nts_warm_cookies` 1-line delegation,
    /// which would otherwise stay uncovered until the first happy-
    /// path Rust unit test (currently only the live integration
    /// probes against real NTS endpoints, gated behind `--ignored`).
    #[test]
    fn nts_client_query_rejects_invalid_spec_via_validate() {
        let client = NtsClient::new();
        let spec = NtsServerSpec {
            host: String::new(),
            port: 4460,
        };
        match client.query(spec, 1000, 1) {
            Err(NtsError::InvalidSpec(_)) => {}
            other => panic!("expected InvalidSpec, got {other:?}"),
        }
    }

    #[test]
    fn nts_client_warm_cookies_rejects_invalid_spec_via_validate() {
        let client = NtsClient::new();
        let spec = NtsServerSpec {
            host: "ok.invalid".to_owned(),
            port: 0,
        };
        match client.warm_cookies(spec, 1000, 1) {
            Err(NtsError::InvalidSpec(_)) => {}
            other => panic!("expected InvalidSpec, got {other:?}"),
        }
    }

    #[test]
    fn nts_warm_cookies_top_level_rejects_invalid_spec_via_validate() {
        let spec = NtsServerSpec {
            host: String::new(),
            port: 4460,
        };
        match nts_warm_cookies(spec, 1000, 1) {
            Err(NtsError::InvalidSpec(_)) => {}
            other => panic!("expected InvalidSpec, got {other:?}"),
        }
    }

    /// End-to-end fail-fast eviction routed through `NtsClient::query`
    /// rather than the top-level `nts_query`. Mirrors the shape of
    /// `nts_query_evicts_session_on_aead_authentication_failure`
    /// (which exercises the same path through the process-wide
    /// default client) but pre-installs the session in the
    /// per-client table and asserts the eviction happened on
    /// *this* client's table — not the default. Pins:
    ///
    /// 1. `NtsClient::query` actually delegates to `nts_query_inner`
    ///    against `self.table` rather than against the default
    ///    table.
    /// 2. The fail-fast eviction landed on the per-client table:
    ///    after the call, the entry is gone from the client's
    ///    table, and the default table still does not see one for
    ///    this `host:port`.
    #[test]
    fn nts_client_query_evicts_session_on_aead_failure_in_client_table() {
        let faux_server = UdpSocket::bind("127.0.0.1:0").expect("bind faux server");
        faux_server
            .set_read_timeout(Some(Duration::from_secs(2)))
            .expect("set faux server read timeout");
        let server_port = faux_server.local_addr().expect("local addr").port();
        let host = "127.0.0.1";
        let key = format!("{host}:{server_port}");

        let client = NtsClient::new();
        let generation = next_session_generation();
        let mut session = make_test_session(host, server_port, generation);
        session.jar.put_many(host, [vec![0xAB; 32]]);
        client
            .table
            .map
            .lock()
            .expect("client table poisoned")
            .insert(key.clone(), session);

        let handler = std::thread::spawn(move || {
            let mut buf = [0u8; 2048];
            let (n, src) = faux_server
                .recv_from(&mut buf)
                .expect("faux server recv_from");
            // Same mode-bit flip as the default-client test: forces
            // the AEAD verify in `parse_server_response` to trip a
            // tag mismatch and raise `NtpError::Aead`, which is the
            // canonical rekey signal `nts_query_inner` evicts on.
            buf[0] = (buf[0] & !0b0000_0111) | 0b0000_0100;
            faux_server
                .send_to(&buf[..n], src)
                .expect("faux server send_to");
        });

        let spec = NtsServerSpec {
            host: host.to_owned(),
            port: server_port,
        };
        let result = client.query(spec.clone(), 2_000, 64);
        handler.join().expect("faux server thread panicked");

        match result {
            Err(NtsError::Authentication { .. }) => {}
            other => panic!("expected NtsError::Authentication, got {other:?}"),
        }

        // Eviction landed on the client's own table.
        let g = client.table.map.lock().expect("client table poisoned");
        assert!(
            g.get(&key).is_none(),
            "fail-fast eviction must remove the entry from the per-client table",
        );
        drop(g);

        // And the default table was not touched (we never installed
        // anything there for this `host:port`, and the per-client
        // call should not have leaked into it).
        let g = default_session_table()
            .map
            .lock()
            .expect("default session table poisoned");
        assert!(
            g.get(&key).is_none(),
            "per-client query must not touch the default table",
        );
    }

    /// Live integration probe — performs a real NTS-KE handshake and
    /// authenticated NTPv4 exchange against Cloudflare's public endpoint.
    /// Gated behind `--ignored` so the standard CI run never touches the
    /// network. Run manually with:
    ///   cargo test -p nts_rust nts_query_live -- --ignored --nocapture
    #[test]
    #[ignore = "requires outbound TCP/4460 + UDP/123 to time.cloudflare.com"]
    fn nts_query_live_cloudflare() {
        let spec = NtsServerSpec {
            host: "time.cloudflare.com".to_owned(),
            port: DEFAULT_KE_PORT,
        };
        let sample = nts_query(spec.clone(), 10_000, 0).expect("nts_query");
        assert_eq!(sample.aead_id, aead_ids::AES_SIV_CMAC_256);
        assert!(sample.server_stratum > 0 && sample.server_stratum < 16);
        assert!(sample.round_trip_micros > 0);
        // NTS_query asks for one fresh cookie back; some servers honour, some don't.
        assert!(sample.fresh_cookies <= 8);
        // Sanity: server time should be within ±5 minutes of local time.
        let now_us = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_micros() as i64)
            .unwrap_or(0);
        assert!(
            (sample.utc_unix_micros - now_us).abs() < 5 * 60 * 1_000_000,
            "server time {}us local time {}us",
            sample.utc_unix_micros,
            now_us,
        );

        // Second call should reuse the session and avoid a re-handshake.
        let sample2 = nts_query(spec, 10_000, 0).expect("nts_query 2");
        assert!(sample2.utc_unix_micros >= sample.utc_unix_micros);
    }

    /// IPv6-capable live probe — exercises the dual-stack code path
    /// against PTB's public NTS endpoint. PTB publishes AAAA records,
    /// so on a host that prefers IPv6 (RFC 6724 default) this drives
    /// the `[::]:0` bind branch. Gated behind `--ignored`. Run with:
    ///   cargo test -p nts_rust nts_query_live_ipv6 -- --ignored --nocapture
    /// Skipped at runtime if the host has no IPv6 connectivity at all,
    /// which `bind_connected_udp` reports via its aggregated error
    /// (every candidate failed `bind` or `connect`).
    #[test]
    #[ignore = "requires outbound TCP/4460 + UDP/123 IPv6 to ptbtime1.ptb.de"]
    fn nts_query_live_ipv6_ptb() {
        let spec = NtsServerSpec {
            host: "ptbtime1.ptb.de".to_owned(),
            port: DEFAULT_KE_PORT,
        };
        match nts_query(spec, 10_000, 0) {
            Ok(sample) => {
                assert!(sample.server_stratum > 0 && sample.server_stratum < 16);
                assert!(sample.round_trip_micros > 0);
            }
            Err(NtsError::Network { message: msg, .. }) => {
                eprintln!("skipping: no IPv6 path to ptbtime1.ptb.de ({msg})");
            }
            Err(other) => panic!("unexpected non-network failure: {other:?}"),
        }
    }

    // ------------------------------------------------------------------
    // Singleflight: concurrent cold queries against the same host
    // collapse onto one handshake; concurrent queries against different
    // hosts run their handshakes in parallel; per-call deadlines are
    // honoured by waiters; leader failures propagate to every waiter as
    // a cloned `NtsError`. See `nts-o8u` for the full design.
    // ------------------------------------------------------------------

    use std::sync::atomic::AtomicUsize;
    use std::thread;

    /// Build a `Session` with `cookie_count` cookies in the jar so the
    /// post-handshake cookie-take phase succeeds without standing up a
    /// real KE responder. Cookies are 8-byte sentinels; the singleflight
    /// tests never seal or open them.
    fn make_test_session_with_cookies(
        host: &str,
        ntpv4_port: u16,
        generation: u64,
        cookie_count: usize,
    ) -> Session {
        let mut s = make_test_session(host, ntpv4_port, generation);
        let cookies: Vec<Vec<u8>> = (0..cookie_count)
            .map(|i| (i as u64).to_le_bytes().to_vec())
            .collect();
        s.jar.put_many(host, cookies);
        s
    }

    /// Spin until `predicate` returns true, polling the singleflight
    /// state at 1ms intervals up to `timeout`. Replaces the
    /// `thread::sleep(50ms)` heuristics the singleflight tests
    /// originally used to wait for "leader has registered" or "all
    /// waiters have grabbed a slot reference" — those are deterministic
    /// signals the test can read off `table.inflight` directly, so
    /// there's no need for a fixed-duration sleep that flakes on slow
    /// or contended CI runners. Panics with a descriptive message if
    /// the predicate never becomes true; that is a real test failure
    /// (a regression that prevents the singleflight from registering
    /// or that loses waiter references) rather than a hang.
    fn await_singleflight_state<F>(table: &SessionTable, key: &str, timeout: Duration, predicate: F)
    where
        F: Fn(Option<&Arc<HandshakeSlot>>) -> bool,
    {
        let deadline = Instant::now() + timeout;
        loop {
            {
                let g = table
                    .inflight
                    .lock()
                    .expect("inflight singleflight map poisoned in test");
                if predicate(g.get(key)) {
                    return;
                }
            }
            if Instant::now() >= deadline {
                panic!(
                    "singleflight state did not converge for key {key:?} within {timeout:?}; \
                     this almost certainly means the leader never registered an inflight \
                     slot or the waiters never grabbed their slot references",
                );
            }
            thread::sleep(Duration::from_millis(1));
        }
    }

    /// One-shot release primitive used by the singleflight tests to
    /// park a leader handshake closure until the assertion-side
    /// preconditions are met. Replaces `Barrier::new(2)` for these
    /// cases because `std::sync::Barrier::wait` has no built-in
    /// timeout — if the test thread panics before reaching the
    /// matching `wait` (for example because `await_singleflight_state`
    /// times out on a regression), the leader thread parks forever
    /// and `cargo test` would have to rely on Rust's process exit to
    /// reclaim it.
    ///
    /// Two layers of safety net:
    ///
    /// 1. `ReleaseHandle::wait_release` is bounded by a per-call
    ///    `timeout` so even a leader running with a torn-down test
    ///    thread cannot park indefinitely; on timeout it returns
    ///    `Err(())` and the closure can surface a synthetic error.
    /// 2. `BoundedRelease`'s `Drop` impl signals release as part of
    ///    stack unwind. When the test panics, the local
    ///    `BoundedRelease` is dropped, which fires `release()`,
    ///    which unparks the leader closure immediately rather than
    ///    making it ride out the full `wait_release` deadline. The
    ///    `Arc<(Mutex, Condvar)>` survives long enough for the
    ///    closure to wake (it is held independently by every
    ///    `ReleaseHandle`) so the wakeup path is sound even when
    ///    the original is mid-drop.
    struct BoundedRelease {
        state: Arc<(Mutex<bool>, Condvar)>,
    }

    /// Cloneable handle to a `BoundedRelease`'s shared state. The
    /// handle is what the leader handshake closure captures and
    /// parks on; the test thread retains the `BoundedRelease`
    /// itself so its `Drop` can wake every parked handle on panic.
    #[derive(Clone)]
    struct ReleaseHandle {
        state: Arc<(Mutex<bool>, Condvar)>,
    }

    impl BoundedRelease {
        fn new() -> Self {
            Self {
                state: Arc::new((Mutex::new(false), Condvar::new())),
            }
        }

        fn handle(&self) -> ReleaseHandle {
            ReleaseHandle {
                state: self.state.clone(),
            }
        }

        /// Signal release. Idempotent — calling release twice (e.g.
        /// once explicitly from the test, once again from `Drop`)
        /// is a no-op the second time. Wakes every handle parked
        /// on `wait_release`.
        fn release(&self) {
            let (lock, cv) = &*self.state;
            *lock.lock().expect("BoundedRelease state poisoned") = true;
            cv.notify_all();
        }
    }

    impl Drop for BoundedRelease {
        fn drop(&mut self) {
            self.release();
        }
    }

    impl ReleaseHandle {
        /// Park until released or `timeout` elapses. Returns `Ok(())`
        /// when released, `Err(())` on timeout. The handshake closure
        /// translates `Err(())` into a synthetic `NtsError::Internal`
        /// so a stuck test (released-via-Drop or genuinely timed out)
        /// surfaces as a test failure rather than as a leader thread
        /// that completes successfully.
        fn wait_release(&self, timeout: Duration) -> Result<(), ()> {
            let (lock, cv) = &*self.state;
            let mut released = lock.lock().expect("BoundedRelease state poisoned");
            let deadline = Instant::now() + timeout;
            while !*released {
                let now = Instant::now();
                if now >= deadline {
                    return Err(());
                }
                let (next, _) = cv
                    .wait_timeout(released, deadline - now)
                    .expect("BoundedRelease state poisoned");
                released = next;
            }
            Ok(())
        }
    }

    /// Acceptance criterion 1: N concurrent cold checkouts against the
    /// same host collapse onto exactly one `establish_session` call.
    /// Pre-singleflight, every concurrent caller would have run its own
    /// handshake — verified by the same test against the pre-refactor
    /// path would observe `handshake_count == N`.
    #[test]
    fn checkout_collapses_concurrent_cold_queries_onto_one_handshake() {
        const N: usize = 6;
        let table = Arc::new(SessionTable::new());
        let spec = NtsServerSpec {
            host: "singleflight-collapse.test".into(),
            port: 4460,
        };
        let handshake_count = Arc::new(AtomicUsize::new(0));
        // Park the leader's handshake until the test confirms every
        // follower has reached phase B and elected the leader's slot,
        // then release. Without the park, a fast leader could complete
        // before the followers ever entered checkout. `BoundedRelease`
        // (in place of `Barrier::new(2)`) is bounded by a per-call
        // wait timeout *and* by a `Drop`-on-panic release, so a test
        // that panics in `await_singleflight_state` cannot strand the
        // leader thread.
        let release = BoundedRelease::new();
        let release_handle = release.handle();
        let do_handshake = {
            let handshake_count = handshake_count.clone();
            move |spec: &NtsServerSpec, _t: Duration, _c: usize| {
                handshake_count.fetch_add(1, Ordering::SeqCst);
                release_handle
                    .wait_release(Duration::from_secs(10))
                    .map_err(|()| NtsError::Internal("BoundedRelease timed out".into()))?;
                Ok((
                    make_test_session_with_cookies(
                        &spec.host,
                        123,
                        next_session_generation(),
                        N + 2,
                    ),
                    KePhaseTimings::default(),
                ))
            }
        };

        let handles: Vec<_> = (0..N)
            .map(|_| {
                let table = table.clone();
                let spec = spec.clone();
                let do_handshake = do_handshake.clone();
                thread::spawn(move || {
                    table
                        .checkout_with(&spec, Duration::from_secs(10), 4, &do_handshake)
                        .map(|(ctx, _)| ctx)
                })
            })
            .collect();

        // Wait until every spawned thread has reached phase B and one
        // has elected itself as the leader (registered the inflight
        // slot) and N-1 have elected as waiters (each holding a clone
        // of the slot Arc). The slot's `Arc::strong_count` reaches
        // `1 (inflight map) + 1 (LeaderGuard) + (N-1) (waiters)` =
        // `N + 1` exactly when every concurrent caller has made its
        // role-election decision; polling against that count
        // replaces the original `thread::sleep(50ms)` with a
        // deterministic singleflight-state signal that does not flake
        // under CI scheduling jitter.
        let key = session_key(&spec);
        await_singleflight_state(&table, &key, Duration::from_secs(2), |slot| {
            slot.is_some_and(|s| Arc::strong_count(s) == N + 1)
        });
        release.release();

        let mut ok_count = 0;
        for h in handles {
            let result = h.join().expect("checkout thread panicked");
            if let Err(e) = result {
                panic!("checkout failed: {e:?}");
            }
            ok_count += 1;
        }
        assert_eq!(ok_count, N, "every concurrent checkout returned a context");
        assert_eq!(
            handshake_count.load(Ordering::SeqCst),
            1,
            "exactly one handshake ran across {N} concurrent cold checkouts",
        );
    }

    /// Acceptance criterion 2: concurrent checkouts against *different*
    /// hosts continue to run their handshakes in parallel. The
    /// singleflight is keyed by `session_key(spec)` (i.e. `host:port`),
    /// so two different keys must each elect their own leader and the
    /// two handshakes must be in-flight simultaneously. Verified by
    /// gating the per-host handshakes on a shared rendezvous counter
    /// with a bounded deadline: each leader increments
    /// `arrived_count`, then polls until it sees `arrived_count == 2`.
    /// If singleflight regresses and serialises the two handshakes,
    /// the second leader never arrives, the first leader's poll
    /// deadline elapses, and the closure surfaces a synthetic
    /// `NtsError::Internal` so the test fails fast instead of
    /// hanging the CI job indefinitely (cargo test has no built-in
    /// per-test timeout and CI runs `cargo test --lib` without an
    /// external timeout wrapper).
    #[test]
    fn checkout_does_not_serialize_handshakes_across_distinct_hosts() {
        let table = Arc::new(SessionTable::new());
        let spec_a = NtsServerSpec {
            host: "singleflight-host-a.test".into(),
            port: 4460,
        };
        let spec_b = NtsServerSpec {
            host: "singleflight-host-b.test".into(),
            port: 4460,
        };
        let arrived_count = Arc::new(AtomicUsize::new(0));
        let do_handshake = {
            let arrived_count = arrived_count.clone();
            move |spec: &NtsServerSpec, _t: Duration, _c: usize| {
                // Prove both handshakes are in flight at the same
                // time: each leader announces its arrival, then
                // polls until the partner has also announced.
                // Bounded by a 10s deadline so a regression that
                // serialises the leaders surfaces as a test
                // failure rather than as a hang against cargo's
                // per-test timeout.
                arrived_count.fetch_add(1, Ordering::SeqCst);
                let deadline = Instant::now() + Duration::from_secs(10);
                while arrived_count.load(Ordering::SeqCst) < 2 {
                    if Instant::now() >= deadline {
                        return Err(NtsError::Internal(
                            "parallel-hosts rendezvous never reached 2 leaders".into(),
                        ));
                    }
                    thread::sleep(Duration::from_millis(1));
                }
                Ok((
                    make_test_session_with_cookies(&spec.host, 123, next_session_generation(), 4),
                    KePhaseTimings::default(),
                ))
            }
        };

        let h_a = {
            let table = table.clone();
            let spec_a = spec_a.clone();
            let do_handshake = do_handshake.clone();
            thread::spawn(move || {
                table.checkout_with(&spec_a, Duration::from_secs(10), 4, &do_handshake)
            })
        };
        let h_b = {
            let table = table.clone();
            let spec_b = spec_b.clone();
            let do_handshake = do_handshake.clone();
            thread::spawn(move || {
                table.checkout_with(&spec_b, Duration::from_secs(10), 4, &do_handshake)
            })
        };

        if let Err(e) = h_a.join().expect("host-a thread panicked") {
            panic!("host-a checkout failed: {e:?}");
        }
        if let Err(e) = h_b.join().expect("host-b thread panicked") {
            panic!("host-b checkout failed: {e:?}");
        }
    }

    /// Acceptance criterion 3: a waiter whose per-call deadline expires
    /// before the leader finishes returns `NtsError::Timeout`, *not*
    /// `NtsError::Internal` and not an indefinite block. The leader
    /// here parks against a release channel so the test owns when (or
    /// whether) it ever completes.
    #[test]
    fn checkout_waiter_returns_timeout_when_leader_outlasts_deadline() {
        let table = Arc::new(SessionTable::new());
        let spec = NtsServerSpec {
            host: "singleflight-waiter-timeout.test".into(),
            port: 4460,
        };
        let leader_release = BoundedRelease::new();
        let leader_release_handle = leader_release.handle();
        let do_handshake = move |spec: &NtsServerSpec, _t: Duration, _c: usize| {
            leader_release_handle
                .wait_release(Duration::from_secs(10))
                .map_err(|()| NtsError::Internal("BoundedRelease timed out".into()))?;
            Ok((
                make_test_session_with_cookies(&spec.host, 123, next_session_generation(), 4),
                KePhaseTimings::default(),
            ))
        };

        // Spawn the leader. It will park inside `do_handshake` until
        // we release `leader_release` at the end of the test.
        let leader = {
            let table = table.clone();
            let spec = spec.clone();
            let do_handshake = do_handshake.clone();
            thread::spawn(move || {
                table.checkout_with(&spec, Duration::from_secs(10), 4, &do_handshake)
            })
        };

        // Wait until the leader has actually registered an inflight
        // slot before spawning the waiter. Without this gate the
        // waiter could enter checkout *first*, become the leader
        // itself, and run a handshake — which would fail the test
        // (waiter expected to see Timeout, would instead see Ok or
        // a leader-failure shape). Replaces the original
        // `thread::sleep(50ms)` with a deterministic state signal.
        let key = session_key(&spec);
        await_singleflight_state(&table, &key, Duration::from_secs(2), |slot| slot.is_some());

        // Waiter has a tight 100ms call budget; leader is parked, so
        // the waiter must surface a Timeout once 100ms elapse.
        let waiter_started = Instant::now();
        let waiter_outcome = table.checkout_with(
            &spec,
            Duration::from_millis(100),
            4,
            &|_: &NtsServerSpec, _t: Duration, _c: usize| {
                panic!("waiter should never run a handshake; it must park on the leader's slot")
            },
        );
        let waiter_elapsed = waiter_started.elapsed();

        match waiter_outcome {
            Err(NtsError::Timeout {
                phase: TimeoutPhase::KeRecordIo,
                trust_backend: None,
            }) => {}
            Err(other) => panic!("expected Timeout(KeRecordIo); got {other:?}"),
            Ok(_) => panic!("waiter returned Ok despite a parked leader"),
        }
        assert!(
            waiter_elapsed >= Duration::from_millis(100),
            "waiter returned before its 100ms budget elapsed: {waiter_elapsed:?}",
        );
        assert!(
            waiter_elapsed < Duration::from_millis(2_000),
            "waiter overshot its budget by >2s; deadline plumbing is broken: {waiter_elapsed:?}",
        );

        // Release the leader so its thread joins cleanly.
        leader_release.release();
        if let Err(e) = leader.join().expect("leader thread panicked") {
            panic!("leader checkout failed: {e:?}");
        }
    }

    /// Acceptance criterion 4: when the leader's handshake fails,
    /// every waiter receives a cloned `NtsError` with the *same*
    /// variant/payload as the leader. Waiters must not silently retry
    /// (which would amplify load against a server that just rejected
    /// the leader's handshake) and must not see `NtsError::Internal`
    /// (which would mask the real failure shape under a sentinel).
    #[test]
    fn checkout_propagates_leader_failure_to_every_waiter() {
        const N: usize = 4;
        let table = Arc::new(SessionTable::new());
        let spec = NtsServerSpec {
            host: "singleflight-leader-fail.test".into(),
            port: 4460,
        };
        let handshake_count = Arc::new(AtomicUsize::new(0));
        let release = BoundedRelease::new();
        let release_handle = release.handle();
        let do_handshake = {
            let handshake_count = handshake_count.clone();
            move |_: &NtsServerSpec, _t: Duration, _c: usize| {
                handshake_count.fetch_add(1, Ordering::SeqCst);
                release_handle
                    .wait_release(Duration::from_secs(10))
                    .map_err(|()| NtsError::Internal("BoundedRelease timed out".into()))?;
                Err(NtsError::KeProtocol {
                    message: "synthetic leader-failure for singleflight test".into(),
                    trust_backend: None,
                })
            }
        };

        let handles: Vec<_> = (0..N)
            .map(|_| {
                let table = table.clone();
                let spec = spec.clone();
                let do_handshake = do_handshake.clone();
                thread::spawn(move || {
                    table.checkout_with(&spec, Duration::from_secs(10), 4, &do_handshake)
                })
            })
            .collect();

        // Same deterministic release pattern as criterion-1: wait
        // until every spawned thread has reached phase B, with one
        // leader (registered the inflight slot) and N-1 waiters
        // (each holding a clone of the slot Arc), before allowing
        // the leader to finish with a failure. Otherwise late
        // arrivals would observe an empty inflight after the
        // leader's `complete` and start their own (now-real)
        // handshakes, which would fail the `handshake_count == 1`
        // assertion below for reasons unrelated to the singleflight
        // fan-out semantic this test is verifying.
        let key = session_key(&spec);
        await_singleflight_state(&table, &key, Duration::from_secs(2), |slot| {
            slot.is_some_and(|s| Arc::strong_count(s) == N + 1)
        });
        release.release();

        for h in handles {
            let result = h.join().expect("thread panicked");
            match result {
                Err(NtsError::KeProtocol { message: msg, .. }) => {
                    assert_eq!(msg, "synthetic leader-failure for singleflight test");
                }
                Err(other) => {
                    panic!("expected the leader's KeProtocol; got {other:?}")
                }
                Ok(_) => panic!("checkout returned Ok despite the leader failing"),
            }
        }
        assert_eq!(
            handshake_count.load(Ordering::SeqCst),
            1,
            "exactly one handshake ran; waiters did not silently retry",
        );
    }

    /// Acceptance criterion 5 (and a regression guard): the existing
    /// session-generation invariant — every install mints a *distinct*
    /// generation, even when multiple leaders run back-to-back through
    /// the singleflight loop — survives the refactor. Without this,
    /// `deposit_cookies` could silently accept stale cookies from a
    /// superseded session, which is exactly the race the generation
    /// counter exists to prevent. A failing assertion here would mean
    /// the singleflight is sharing generation values across handshakes,
    /// not that the singleflight is broken per se.
    #[test]
    fn checkout_consecutive_handshakes_get_distinct_generations() {
        let table = Arc::new(SessionTable::new());
        let spec = NtsServerSpec {
            host: "singleflight-generations.test".into(),
            port: 4460,
        };
        // Each handshake delivers exactly 1 cookie, so the next caller
        // re-enters phase B and triggers another handshake.
        let do_handshake = move |spec: &NtsServerSpec, _t: Duration, _c: usize| {
            Ok((
                make_test_session_with_cookies(&spec.host, 123, next_session_generation(), 1),
                KePhaseTimings::default(),
            ))
        };

        let mut generations = Vec::with_capacity(3);
        for _ in 0..3 {
            let (ctx, _) = table
                .checkout_with(&spec, Duration::from_secs(5), 4, &do_handshake)
                .unwrap_or_else(|e| panic!("checkout failed: {e:?}"));
            generations.push(ctx.session_generation);
        }
        // All three must be distinct: each handshake mints its own
        // generation via `next_session_generation()`, and each
        // checkout drains the just-installed jar of its single cookie,
        // forcing the next call to re-handshake.
        assert_eq!(generations.len(), 3);
        assert_ne!(generations[0], generations[1]);
        assert_ne!(generations[1], generations[2]);
        assert_ne!(generations[0], generations[2]);
    }

    // ------------------------------------------------------------------
    // Trust-anchor diagnostics + strict-mode tests (nts-21j, 3.0.0).
    //
    // Pin the public conversions between `TrustMode`/`TrustBackend` and
    // their protocol-layer mirrors, the `NtsError` mapping for the new
    // `TrustBackendUnavailable` variant, and the `NtsClient` round-trip
    // of `trust_mode()` so a future refactor of either layer surfaces
    // here rather than in a downstream consumer's exhaustive `switch`.
    // ------------------------------------------------------------------

    /// Acceptance criterion 4 (default trust mode is unchanged): a
    /// freshly-constructed `NtsClient` reports
    /// `TrustMode::PlatformWithFallback`. The default singleton path
    /// surfaced by `nts_query` / `nts_warm_cookies` likewise reaches
    /// `establish_session` with this mode (verified by the live
    /// integration tests further up).
    #[test]
    fn nts_client_default_trust_mode_is_platform_with_fallback() {
        let client = NtsClient::new();
        assert_eq!(client.trust_mode(), TrustMode::PlatformWithFallback);
    }

    /// Acceptance criterion 3 (strict mode is opt-in): a client minted
    /// with `TrustMode::PlatformOnly` round-trips that mode through
    /// `trust_mode()` and `is_default == false`, so subsequent
    /// handshakes reach `build_tls_config` with the strict policy and
    /// do not contribute to the singleton-path observable surfaced by
    /// `nts_trust_status`.
    #[test]
    fn nts_client_with_trust_mode_round_trips_strict() {
        let client = NtsClient::with_trust_mode(TrustMode::PlatformOnly);
        assert_eq!(client.trust_mode(), TrustMode::PlatformOnly);
        assert!(!client.is_default);
    }

    /// Pin the `KeError::TrustBackendUnavailable -> NtsError::TrustBackendUnavailable`
    /// mapping. The failure shape is the load-bearing observable for
    /// strict-mode callers — collapsing it onto `KeProtocol` would
    /// re-introduce the silent-downgrade hazard the strict mode is
    /// meant to surface as a typed error.
    #[test]
    fn ke_error_trust_backend_unavailable_maps_to_typed_nts_error() {
        let ke_err = KeError::TrustBackendUnavailable("synthetic test failure".into());
        let nts_err: NtsError = ke_err.into();
        match nts_err {
            NtsError::TrustBackendUnavailable(msg) => {
                assert!(
                    msg.contains("synthetic test failure"),
                    "diagnostic should be preserved verbatim, got {msg:?}",
                );
            }
            other => panic!("expected TrustBackendUnavailable, got {other:?}"),
        }
    }

    /// Pin the `From` round-trips between the public `TrustMode` /
    /// `TrustBackend` enums and their protocol-layer mirrors. The
    /// `From` chain is the only thing keeping `establish_session`'s
    /// trust-mode plumbing from silently dropping a variant on
    /// either end of the boundary.
    #[test]
    fn trust_mode_and_backend_conversions_are_total() {
        // TrustMode -> KeTrustMode
        for m in [TrustMode::PlatformWithFallback, TrustMode::PlatformOnly] {
            let ke: crate::nts::ke::KeTrustMode = m.into();
            match (m, ke) {
                (
                    TrustMode::PlatformWithFallback,
                    crate::nts::ke::KeTrustMode::PlatformWithFallback,
                ) => {}
                (TrustMode::PlatformOnly, crate::nts::ke::KeTrustMode::PlatformOnly) => {}
                _ => panic!("TrustMode -> KeTrustMode mapping diverged"),
            }
        }
        // KeTrustBackend -> TrustBackend
        for b in [
            crate::nts::ke::KeTrustBackend::Platform,
            crate::nts::ke::KeTrustBackend::PlatformWithHybridFallback,
            crate::nts::ke::KeTrustBackend::WebpkiRoots,
        ] {
            let public: TrustBackend = b.into();
            match (b, public) {
                (crate::nts::ke::KeTrustBackend::Platform, TrustBackend::Platform) => {}
                (
                    crate::nts::ke::KeTrustBackend::PlatformWithHybridFallback,
                    TrustBackend::PlatformWithHybridFallback,
                ) => {}
                (crate::nts::ke::KeTrustBackend::WebpkiRoots, TrustBackend::WebpkiRoots) => {}
                _ => panic!("KeTrustBackend -> TrustBackend mapping diverged"),
            }
        }
    }

    /// `nts_trust_status()` must be safe to call with no prior
    /// handshake (process just started, or all queries went through
    /// caller-minted clients). Snapshot fields land at their
    /// documented "no signal yet" values rather than panicking on a
    /// missing observation.
    #[test]
    fn nts_trust_status_snapshot_is_safe_with_no_handshake() {
        let status = nts_trust_status();
        // android_platform_init_succeeded is always false off-Android;
        // on Android the test harness does not invoke the JNI bootstrap
        // either, so the same assertion holds.
        assert!(!status.android_platform_init_succeeded);
        // hybrid_fallback_count is `Relaxed` and global; we cannot
        // assert == 0 because earlier tests in this process may have
        // exercised the Android-only code path. Assert weak monotonicity:
        // calling snapshot twice shows the second value is >= the first.
        let second = nts_trust_status();
        assert!(second.android_hybrid_fallback_count >= status.android_hybrid_fallback_count);
    }

    /// Cached-session checkouts must surface the original handshake's
    /// `trust_backend` via `QueryContext`, mirroring how
    /// `phase_timings` is zeroed-but-present on the cache-hit path.
    /// Without this the per-query `NtsTimeSample::trust_backend`
    /// attribution would degrade on every cached query and callers
    /// would not be able to round-trip provenance through their
    /// observability layer.
    #[test]
    fn checkout_cache_hit_preserves_session_trust_backend() {
        let table = SessionTable::new();
        let spec = NtsServerSpec {
            host: "trust-backend-cache-hit.test".into(),
            port: 4460,
        };
        // Pre-install a session whose trust_backend is
        // `PlatformWithHybridFallback` (a non-default value, so a
        // regression that hard-codes Platform on the cache-hit path
        // surfaces as a value mismatch).
        let mut session = make_test_session_with_cookies(
            "trust-backend-cache-hit.test",
            4460,
            next_session_generation(),
            4,
        );
        session.trust_backend = TrustBackend::PlatformWithHybridFallback;
        table.install(&spec, session);
        let (ctx, _) = table
            .checkout(
                &spec,
                Duration::from_secs(5),
                4,
                TrustMode::PlatformWithFallback,
            )
            .expect("cache hit");
        assert_eq!(ctx.trust_backend, TrustBackend::PlatformWithHybridFallback);
    }

    /// `nts-upv` acceptance criterion: N concurrent
    /// `warm_cookies_with` calls against the same `host:port`
    /// collapse onto exactly ONE KE handshake. Pre-3.1.0
    /// `nts_warm_cookies` called `establish_session` directly,
    /// bypassing the singleflight machinery and producing N parallel
    /// handshakes. Same `BoundedRelease` + `await_singleflight_state`
    /// test pattern as `checkout_collapses_concurrent_cold_queries_*`
    /// so the deterministic-release shape stays uniform across the
    /// two singleflight entry points.
    #[test]
    fn warm_cookies_collapses_concurrent_forced_refreshes_onto_one_handshake() {
        const N: usize = 6;
        let table = Arc::new(SessionTable::new());
        let spec = NtsServerSpec {
            host: "warm-singleflight-collapse.test".into(),
            port: 4460,
        };
        let handshake_count = Arc::new(AtomicUsize::new(0));
        let release = BoundedRelease::new();
        let release_handle = release.handle();
        // Synthetic non-default KePhaseTimings sentinel returned by
        // the test handshake closure. The leader surfaces these
        // verbatim from `do_handshake`; waiters surface
        // `KePhaseTimings::default()` because they did not perform KE
        // work themselves. The two are observationally
        // distinguishable, so the test can assert exactly 1 leader
        // and N-1 waiters by inspecting `phase_timings` alongside
        // counting handshake-closure invocations.
        let leader_timings = KePhaseTimings {
            dns_micros: 11,
            connect_micros: 22,
            tls_handshake_micros: 33,
            ke_record_io_micros: 44,
        };
        let do_handshake = {
            let handshake_count = handshake_count.clone();
            move |spec: &NtsServerSpec, _t: Duration, _c: usize| {
                handshake_count.fetch_add(1, Ordering::SeqCst);
                release_handle
                    .wait_release(Duration::from_secs(10))
                    .map_err(|()| NtsError::Internal("BoundedRelease timed out".into()))?;
                Ok((
                    make_test_session_with_cookies(
                        &spec.host,
                        123,
                        next_session_generation(),
                        N + 2,
                    ),
                    leader_timings,
                ))
            }
        };

        let handles: Vec<_> = (0..N)
            .map(|_| {
                let table = table.clone();
                let spec = spec.clone();
                let do_handshake = do_handshake.clone();
                thread::spawn(move || {
                    table.warm_cookies_with(&spec, Duration::from_secs(10), 4, &do_handshake)
                })
            })
            .collect();

        let key = session_key(&spec);
        await_singleflight_state(&table, &key, Duration::from_secs(2), |slot| {
            slot.is_some_and(|s| Arc::strong_count(s) == N + 1)
        });
        release.release();

        let mut leader_count = 0;
        let mut waiter_count = 0;
        for h in handles {
            let (count, timings, _backend) = h
                .join()
                .expect("warm_cookies thread panicked")
                .expect("warm_cookies returned Err");
            assert!(
                count > 0,
                "every concurrent warm reported a non-zero cookie count",
            );
            if timings == KePhaseTimings::default() {
                waiter_count += 1;
            } else {
                assert_eq!(
                    timings, leader_timings,
                    "leader surfaced unexpected KePhaseTimings",
                );
                leader_count += 1;
            }
        }
        assert_eq!(
            leader_count, 1,
            "exactly one caller observed leader timings"
        );
        assert_eq!(
            waiter_count,
            N - 1,
            "the remaining N-1 callers observed waiter (default) timings",
        );
        assert_eq!(
            handshake_count.load(Ordering::SeqCst),
            1,
            "exactly one handshake ran across {N} concurrent warm_cookies",
        );
    }

    /// Singleflight failure-fan-out semantic: when the leader's
    /// handshake fails, every waiter receives a cloned `NtsError`
    /// with the same variant/payload as the leader. Mirrors
    /// `checkout_propagates_leader_failure_to_every_waiter`.
    #[test]
    fn warm_cookies_propagates_leader_failure_to_every_waiter() {
        const N: usize = 4;
        let table = Arc::new(SessionTable::new());
        let spec = NtsServerSpec {
            host: "warm-singleflight-leader-fail.test".into(),
            port: 4460,
        };
        let handshake_count = Arc::new(AtomicUsize::new(0));
        let release = BoundedRelease::new();
        let release_handle = release.handle();
        let do_handshake = {
            let handshake_count = handshake_count.clone();
            move |_: &NtsServerSpec, _t: Duration, _c: usize| {
                handshake_count.fetch_add(1, Ordering::SeqCst);
                release_handle
                    .wait_release(Duration::from_secs(10))
                    .map_err(|()| NtsError::Internal("BoundedRelease timed out".into()))?;
                Err(NtsError::KeProtocol {
                    message: "synthetic warm-leader-failure for singleflight test".into(),
                    trust_backend: None,
                })
            }
        };

        let handles: Vec<_> = (0..N)
            .map(|_| {
                let table = table.clone();
                let spec = spec.clone();
                let do_handshake = do_handshake.clone();
                thread::spawn(move || {
                    table.warm_cookies_with(&spec, Duration::from_secs(10), 4, &do_handshake)
                })
            })
            .collect();

        let key = session_key(&spec);
        await_singleflight_state(&table, &key, Duration::from_secs(2), |slot| {
            slot.is_some_and(|s| Arc::strong_count(s) == N + 1)
        });
        release.release();

        for h in handles {
            match h.join().expect("thread panicked") {
                Err(NtsError::KeProtocol { message: msg, .. }) => {
                    assert_eq!(msg, "synthetic warm-leader-failure for singleflight test");
                }
                Err(other) => panic!("expected KeProtocol; got {other:?}"),
                Ok(_) => panic!("warm_cookies returned Ok despite leader failure"),
            }
        }
        assert_eq!(
            handshake_count.load(Ordering::SeqCst),
            1,
            "waiters did not silently retry the failed handshake",
        );
    }

    /// Cross-API singleflight collapse: a concurrent `checkout_with`
    /// (NTP-query path) and `warm_cookies_with` (forced-refresh path)
    /// against the same `host:port` collapse onto exactly ONE KE
    /// handshake. Both APIs share the same `inflight` registry keyed
    /// off `session_key(spec)`, so whichever caller arrives first
    /// becomes the leader and the other parks on the same slot.
    /// This is the property that lets a UI binding both a
    /// "refresh time" button (warm) and an underlying poll (query)
    /// keep its KE-wire footprint bounded under rapid taps.
    #[test]
    fn warm_cookies_collapses_with_concurrent_query_against_same_host() {
        let table = Arc::new(SessionTable::new());
        let spec = NtsServerSpec {
            host: "warm-and-query-singleflight-collapse.test".into(),
            port: 4460,
        };
        let handshake_count = Arc::new(AtomicUsize::new(0));
        let release = BoundedRelease::new();
        let release_handle = release.handle();
        let do_handshake = {
            let handshake_count = handshake_count.clone();
            move |spec: &NtsServerSpec, _t: Duration, _c: usize| {
                handshake_count.fetch_add(1, Ordering::SeqCst);
                release_handle
                    .wait_release(Duration::from_secs(10))
                    .map_err(|()| NtsError::Internal("BoundedRelease timed out".into()))?;
                Ok((
                    make_test_session_with_cookies(&spec.host, 123, next_session_generation(), 4),
                    KePhaseTimings::default(),
                ))
            }
        };

        let warm = {
            let table = table.clone();
            let spec = spec.clone();
            let do_handshake = do_handshake.clone();
            thread::spawn(move || {
                table.warm_cookies_with(&spec, Duration::from_secs(10), 4, &do_handshake)
            })
        };
        let query = {
            let table = table.clone();
            let spec = spec.clone();
            let do_handshake = do_handshake.clone();
            thread::spawn(move || {
                table
                    .checkout_with(&spec, Duration::from_secs(10), 4, &do_handshake)
                    .map(|(ctx, _)| ctx)
            })
        };

        // Wait until both threads have registered against the same
        // inflight slot (one as leader, one as waiter); strong count
        // = 1 (inflight map) + 1 (LeaderGuard) + 1 (waiter Arc clone)
        // = 3, regardless of which API arrived first.
        let key = session_key(&spec);
        await_singleflight_state(&table, &key, Duration::from_secs(2), |slot| {
            slot.is_some_and(|s| Arc::strong_count(s) == 3)
        });
        release.release();

        let warm_outcome = warm
            .join()
            .expect("warm thread panicked")
            .expect("warm_cookies returned Err");
        let query_outcome = query
            .join()
            .expect("query thread panicked")
            .expect("checkout returned Err");
        assert!(warm_outcome.0 > 0, "warm reported a non-zero cookie count");
        assert!(
            !query_outcome.cookie.is_empty(),
            "query returned a non-empty cookie",
        );
        assert_eq!(
            handshake_count.load(Ordering::SeqCst),
            1,
            "concurrent warm + query collapsed onto one handshake",
        );
    }

    /// Contract test for `NtsWarmCookiesOutcome.fresh_cookies` /
    /// `NtsTimeSample.freshCookies` ("Number of fresh cookies the
    /// server delivered with the KE response"): a `warm_cookies_with`
    /// waiter must surface the leader's *harvested* cookie count even
    /// when a concurrent `checkout_with` leader has popped one
    /// cookie out of the freshly installed jar before the warm
    /// waiter wakes.
    ///
    /// Forces query-leader-first ordering by spawning the query
    /// thread, awaiting its `LeaderGuard` registration via the
    /// `Arc::strong_count == 2` rendezvous, then spawning the warm
    /// waiter. The leader's `checkout_with` install-then-pop happens
    /// under the `map` lock and *before* `HandshakeSlot::complete`
    /// publishes the slot result, so by the time the warm waiter
    /// wakes the cache holds `delivered - 1` cookies — observably
    /// fewer than the contract value. Pre-fix code (warm waiter
    /// snapshots `cookies_remaining()` from the cache) reports
    /// `delivered - 1`; post-fix code (warm waiter reads
    /// `HandshakeSlotOk.fresh_cookies` from the slot payload)
    /// reports `delivered`.
    #[test]
    fn warm_cookies_waiter_reports_delivered_count_when_query_leader_pops_first() {
        const DELIVERED: usize = 4;
        let table = Arc::new(SessionTable::new());
        let spec = NtsServerSpec {
            host: "warm-waiter-vs-query-leader-pop.test".into(),
            port: 4460,
        };
        let handshake_count = Arc::new(AtomicUsize::new(0));
        let release = BoundedRelease::new();
        let release_handle = release.handle();
        let do_handshake = {
            let handshake_count = handshake_count.clone();
            move |spec: &NtsServerSpec, _t: Duration, _c: usize| {
                handshake_count.fetch_add(1, Ordering::SeqCst);
                release_handle
                    .wait_release(Duration::from_secs(10))
                    .map_err(|()| NtsError::Internal("BoundedRelease timed out".into()))?;
                Ok((
                    make_test_session_with_cookies(
                        &spec.host,
                        123,
                        next_session_generation(),
                        DELIVERED,
                    ),
                    KePhaseTimings::default(),
                ))
            }
        };

        // Phase 1: spawn query, wait for it to register as leader.
        // Strong count = 1 (inflight map) + 1 (LeaderGuard) = 2.
        let key = session_key(&spec);
        let query = {
            let table = table.clone();
            let spec = spec.clone();
            let do_handshake = do_handshake.clone();
            thread::spawn(move || {
                table
                    .checkout_with(&spec, Duration::from_secs(10), 4, &do_handshake)
                    .map(|(ctx, _)| ctx)
            })
        };
        await_singleflight_state(&table, &key, Duration::from_secs(2), |slot| {
            slot.is_some_and(|s| Arc::strong_count(s) == 2)
        });

        // Phase 2: spawn warm waiter. Strong count rises to 3.
        let warm = {
            let table = table.clone();
            let spec = spec.clone();
            let do_handshake = do_handshake.clone();
            thread::spawn(move || {
                table.warm_cookies_with(&spec, Duration::from_secs(10), 4, &do_handshake)
            })
        };
        await_singleflight_state(&table, &key, Duration::from_secs(2), |slot| {
            slot.is_some_and(|s| Arc::strong_count(s) == 3)
        });

        // Phase 3: release the leader. It installs the session,
        // pops one cookie under the `map` lock, then publishes the
        // slot result. The warm waiter wakes after the pop has
        // already landed in the cache.
        release.release();

        let warm_outcome = warm
            .join()
            .expect("warm thread panicked")
            .expect("warm_cookies returned Err");
        let query_outcome = query
            .join()
            .expect("query thread panicked")
            .expect("checkout returned Err");

        assert!(
            !query_outcome.cookie.is_empty(),
            "query leader returned a non-empty cookie",
        );
        assert_eq!(
            warm_outcome.0, DELIVERED as u32,
            "warm waiter reported the leader's harvested count, \
             not a post-pop snapshot of the cache",
        );
        assert_eq!(
            handshake_count.load(Ordering::SeqCst),
            1,
            "query leader + warm waiter collapsed onto one handshake",
        );
    }

    /// Singleflight is keyed by `session_key(spec)`, so concurrent
    /// `warm_cookies_with` calls against *different* hosts continue to
    /// run their handshakes in parallel. Mirrors
    /// `checkout_does_not_serialize_handshakes_across_distinct_hosts`.
    #[test]
    fn warm_cookies_does_not_serialize_across_distinct_hosts() {
        let table = Arc::new(SessionTable::new());
        let spec_a = NtsServerSpec {
            host: "warm-host-a.test".into(),
            port: 4460,
        };
        let spec_b = NtsServerSpec {
            host: "warm-host-b.test".into(),
            port: 4460,
        };
        // Bounded rendezvous: each leader bumps `arrived_count`, then
        // polls until it reaches 2. If singleflight ever regresses
        // and serialises the two warms, the second leader never
        // arrives, the first leader's poll deadline elapses, and the
        // closure returns a synthetic `Internal` so the test fails
        // fast instead of hanging the CI job.
        let arrived_count = Arc::new(AtomicUsize::new(0));
        let do_handshake = {
            let arrived_count = arrived_count.clone();
            move |spec: &NtsServerSpec, _t: Duration, _c: usize| {
                arrived_count.fetch_add(1, Ordering::SeqCst);
                let deadline = Instant::now() + Duration::from_secs(2);
                while arrived_count.load(Ordering::SeqCst) < 2 {
                    if Instant::now() >= deadline {
                        return Err(NtsError::Internal(
                            "second handshake never arrived; singleflight is serialising hosts"
                                .into(),
                        ));
                    }
                    thread::sleep(Duration::from_millis(1));
                }
                Ok((
                    make_test_session_with_cookies(&spec.host, 123, next_session_generation(), 4),
                    KePhaseTimings::default(),
                ))
            }
        };

        let warm_a = {
            let table = table.clone();
            let do_handshake = do_handshake.clone();
            thread::spawn(move || {
                table.warm_cookies_with(&spec_a, Duration::from_secs(10), 4, &do_handshake)
            })
        };
        let warm_b = {
            let table = table.clone();
            let do_handshake = do_handshake.clone();
            thread::spawn(move || {
                table.warm_cookies_with(&spec_b, Duration::from_secs(10), 4, &do_handshake)
            })
        };

        warm_a
            .join()
            .expect("warm_a panicked")
            .expect("warm_a returned Err — singleflight is serialising distinct hosts");
        warm_b
            .join()
            .expect("warm_b panicked")
            .expect("warm_b returned Err — singleflight is serialising distinct hosts");
    }

    /// Waiter timeout: when the leader's handshake outlasts the
    /// waiter's per-call deadline, the waiter must surface
    /// `Timeout(KeRecordIo)` — same `phase` taxonomy
    /// `checkout_with`'s waiter path uses for the same shape.
    /// Mirror of `checkout_waiter_returns_timeout_when_leader_outlasts_deadline`.
    #[test]
    fn warm_cookies_waiter_returns_timeout_when_leader_outlasts_deadline() {
        let table = Arc::new(SessionTable::new());
        let spec = NtsServerSpec {
            host: "warm-singleflight-waiter-timeout.test".into(),
            port: 4460,
        };
        let leader_release = BoundedRelease::new();
        let leader_release_handle = leader_release.handle();
        let do_handshake = move |spec: &NtsServerSpec, _t: Duration, _c: usize| {
            leader_release_handle
                .wait_release(Duration::from_secs(10))
                .map_err(|()| NtsError::Internal("BoundedRelease timed out".into()))?;
            Ok((
                make_test_session_with_cookies(&spec.host, 123, next_session_generation(), 4),
                KePhaseTimings::default(),
            ))
        };

        let leader = {
            let table = table.clone();
            let spec = spec.clone();
            let do_handshake = do_handshake.clone();
            thread::spawn(move || {
                table.warm_cookies_with(&spec, Duration::from_secs(10), 4, &do_handshake)
            })
        };

        // Wait until the leader has registered an inflight slot
        // before spawning the waiter, otherwise the waiter could
        // become the leader itself and run a handshake.
        let key = session_key(&spec);
        await_singleflight_state(&table, &key, Duration::from_secs(2), |slot| slot.is_some());

        let waiter_started = Instant::now();
        let waiter_outcome = table.warm_cookies_with(
            &spec,
            Duration::from_millis(100),
            4,
            &|_: &NtsServerSpec, _t: Duration, _c: usize| {
                panic!("waiter should never run a handshake; it must park on the leader's slot")
            },
        );
        let waiter_elapsed = waiter_started.elapsed();

        match waiter_outcome {
            Err(NtsError::Timeout {
                phase: TimeoutPhase::KeRecordIo,
                trust_backend: None,
            }) => {}
            Err(other) => panic!("expected Timeout(KeRecordIo); got {other:?}"),
            Ok(_) => panic!("waiter returned Ok despite a parked leader"),
        }
        assert!(
            waiter_elapsed >= Duration::from_millis(100),
            "waiter returned before its 100ms budget elapsed: {waiter_elapsed:?}",
        );
        assert!(
            waiter_elapsed < Duration::from_millis(2_000),
            "waiter overshot its budget by >2s; deadline plumbing is broken: {waiter_elapsed:?}",
        );

        leader_release.release();
        if let Err(e) = leader.join().expect("leader thread panicked") {
            panic!("leader warm_cookies failed: {e:?}");
        }
    }

    /// Pre-handshake budget exhaustion on a re-elected leader: when
    /// a thread enters `warm_cookies_with` with `started.elapsed()`
    /// already exceeding `timeout`, the leader path must surface
    /// `Timeout(KeRecordIo)` *before* invoking `do_handshake`, so a
    /// caller's documented per-call wall-clock budget cannot be
    /// silently extended by a re-leader's fresh `timeout`-long
    /// window. Driven directly via a `Duration::ZERO` budget on a
    /// fresh table so the leader's `checked_sub` returns `None`
    /// on the very first iteration. The handshake closure asserts
    /// it is never invoked.
    #[test]
    fn warm_cookies_leader_budget_exhausted_before_handshake_returns_timeout() {
        let table = SessionTable::new();
        let spec = NtsServerSpec {
            host: "warm-singleflight-budget-exhausted.test".into(),
            port: 4460,
        };
        let outcome = table.warm_cookies_with(
            &spec,
            Duration::ZERO,
            4,
            &|_: &NtsServerSpec, _t: Duration, _c: usize| {
                panic!("do_handshake must not be invoked when the per-call budget is exhausted")
            },
        );
        match outcome {
            Err(NtsError::Timeout {
                phase: TimeoutPhase::KeRecordIo,
                trust_backend: None,
            }) => {}
            Err(other) => panic!("expected Timeout(KeRecordIo); got {other:?}"),
            Ok(_) => panic!("warm_cookies returned Ok despite an exhausted budget"),
        }
        // The inflight slot must have been cleaned up by the
        // LeaderGuard so a follow-up call against the same key can
        // become a fresh leader; otherwise a single budget-exhaustion
        // event would permanently strand future warms behind a
        // slot whose result is `Timeout`.
        let key = session_key(&spec);
        let g = table
            .inflight
            .lock()
            .expect("inflight singleflight map poisoned");
        assert!(
            !g.contains_key(&key),
            "inflight slot leaked after budget-exhaustion path",
        );
    }

    /// Defensive shape: a handshake that returns a `Session` with
    /// zero cookies must surface `NtsError::NoCookies` from the
    /// leader path — same shape `checkout_with` uses for the same
    /// case. A regression that installed the empty session would
    /// cause every concurrent waiter to fall through to a misleading
    /// "warm succeeded with 0 cookies" outcome (`fresh_cookies: 0`),
    /// which the pre-handshake guard exists to prevent.
    #[test]
    fn warm_cookies_leader_refuses_zero_cookie_session() {
        let table = SessionTable::new();
        let spec = NtsServerSpec {
            host: "warm-singleflight-zero-cookie.test".into(),
            port: 4460,
        };
        let do_handshake = |spec: &NtsServerSpec, _t: Duration, _c: usize| {
            // `make_test_session` returns a session whose `jar` has
            // no cookies in it (cookie_count == 0); install would
            // otherwise have written a useless session into the map.
            let session = make_test_session(&spec.host, 123, next_session_generation());
            Ok((session, KePhaseTimings::default()))
        };
        match table.warm_cookies_with(&spec, Duration::from_secs(5), 4, &do_handshake) {
            Err(NtsError::NoCookies {
                trust_backend: Some(_),
            }) => {}
            Err(other) => panic!("expected NoCookies(Some(_)); got {other:?}"),
            Ok((count, _, _)) => {
                panic!("warm_cookies returned Ok with count={count} despite a 0-cookie handshake",)
            }
        }
        // The leader must NOT have installed the empty session, so
        // a subsequent call sees an empty cache and re-elects.
        let key = session_key(&spec);
        let g = table.map.lock().expect("session table poisoned");
        assert!(
            !g.contains_key(&key),
            "leader installed a 0-cookie session despite the defensive refusal",
        );
    }

    /// Round-trip every `TrustBackend` variant through the `From`
    /// conversion to `InternalTrustBackend` (used by the trust-state
    /// recording path) and back, pinning the bidirectional mapping. A
    /// future Rust-side variant addition surfaces as a non-compiling
    /// match arm in *both* `From` impls; this test additionally pins
    /// the invariant that the round-trip preserves identity for every
    /// listed variant rather than collapsing two onto a single internal
    /// counterpart.
    #[test]
    fn trust_backend_round_trips_through_internal() {
        for variant in [
            TrustBackend::Platform,
            TrustBackend::PlatformWithHybridFallback,
            TrustBackend::WebpkiRoots,
        ] {
            let internal: crate::nts::trust_state::InternalTrustBackend = variant.into();
            let back: TrustBackend = internal.into();
            assert_eq!(back, variant, "variant {variant:?} did not round-trip");
        }
    }

    /// `KeTrustBackend` (the KE-layer-internal taxonomy) maps onto
    /// `TrustBackend` (the public-API enum that crosses the FRB
    /// boundary). Pin every variant so a Rust-side rename in `nts::ke`
    /// surfaces as a non-compiling arm here rather than as a silent
    /// re-attribution at the consumer.
    #[test]
    fn ke_trust_backend_maps_to_public_trust_backend() {
        use crate::nts::ke::KeTrustBackend;
        for (ke_variant, public_variant) in [
            (KeTrustBackend::Platform, TrustBackend::Platform),
            (
                KeTrustBackend::PlatformWithHybridFallback,
                TrustBackend::PlatformWithHybridFallback,
            ),
            (KeTrustBackend::WebpkiRoots, TrustBackend::WebpkiRoots),
        ] {
            let mapped: TrustBackend = ke_variant.into();
            assert_eq!(mapped, public_variant, "{ke_variant:?} did not map");
        }
    }

    /// `TrustMode` (the public-API enum) maps onto `KeTrustMode` (the
    /// KE-layer-internal taxonomy). Same exhaustiveness guard as the
    /// `KeTrustBackend` test above, on the inbound side of the
    /// boundary.
    #[test]
    fn trust_mode_maps_to_ke_trust_mode() {
        use crate::nts::ke::KeTrustMode;
        for (public_variant, ke_variant) in [
            (
                TrustMode::PlatformWithFallback,
                KeTrustMode::PlatformWithFallback,
            ),
            (TrustMode::PlatformOnly, KeTrustMode::PlatformOnly),
        ] {
            let mapped: KeTrustMode = public_variant.into();
            assert_eq!(mapped, ke_variant, "{public_variant:?} did not map");
        }
    }

    /// `nts_trust_status()` reads the process-global `TRUST_STATE`
    /// snapshot and converts the internal types onto the public DTO.
    /// Tests cannot mutate the singleton without interfering with
    /// every other test in the suite, so this test asserts only the
    /// shape contract — that the call returns a well-formed
    /// `NtsTrustStatus` whose fields agree with the singleton snapshot
    /// taken at the same moment. The variant-by-variant conversion is
    /// covered separately by `trust_backend_round_trips_through_internal`
    /// against fresh `ProcessTrustState` instances.
    #[test]
    fn nts_trust_status_reads_singleton_and_converts_shape() {
        let status = nts_trust_status();
        let snap = crate::nts::trust_state::TRUST_STATE.snapshot();
        // `default_client_backend` may be `None` if no singleton
        // handshake has run in this process yet; the contract is
        // that *if* the snapshot says `Some`, the public DTO carries
        // the matching `TrustBackend` variant.
        match (snap.default_backend, status.default_client_backend) {
            (None, None) => {}
            (Some(internal), Some(public)) => {
                let mapped: TrustBackend = internal.into();
                assert_eq!(public, mapped);
            }
            other => panic!(
                "default_backend Option-shape mismatch between snapshot \
                 and DTO: {other:?}"
            ),
        }
        assert_eq!(
            status.android_platform_init_succeeded,
            snap.android_platform_init_succeeded,
        );
        assert_eq!(
            status.android_hybrid_fallback_count,
            snap.android_hybrid_fallback_count,
        );
    }

    /// `NtsClient::with_trust_mode` plumbs the requested mode onto the
    /// constructed handle and the `trust_mode()` accessor reads it
    /// back. `NtsClient::new` is the documented equivalent of
    /// `with_trust_mode(PlatformWithFallback)`. Both invariants are
    /// what the Dart-side wrapper relies on to round-trip the
    /// caller's policy through the FRB boundary.
    #[test]
    fn nts_client_trust_mode_round_trips_construction_choice() {
        assert_eq!(
            NtsClient::new().trust_mode(),
            TrustMode::PlatformWithFallback
        );
        assert_eq!(
            NtsClient::with_trust_mode(TrustMode::PlatformWithFallback).trust_mode(),
            TrustMode::PlatformWithFallback,
        );
        assert_eq!(
            NtsClient::with_trust_mode(TrustMode::PlatformOnly).trust_mode(),
            TrustMode::PlatformOnly,
        );
    }

    /// Pins the RFC 8915 §5.6 unpredictability property at the
    /// *production* UID-generation site by driving the same module-
    /// scope helper [`super::fresh_request_uid_and_nonce`] that
    /// `nts_query_inner` uses to mint per-request UIDs and nonces.
    ///
    /// Anchoring the assertion to the helper (rather than calling
    /// `getrandom::getrandom` directly here in the test) means a
    /// regression where `nts_query_inner` stops calling the helper —
    /// or where the helper itself is rewritten to reuse a cached
    /// UID, swap in constant bytes during a debugging session, or
    /// pull from a broken RNG — would actually be caught by this
    /// test. A test that reimplemented the `getrandom`-then-pack-
    /// into-`ClientRequest` flow inline would *not* catch any of
    /// those shapes, because the production code path would have
    /// drifted out from under the test.
    ///
    /// To keep the production code path honest end-to-end the test
    /// also serialises each UID into a `ClientRequest` and runs it
    /// through `build_client_request`, then parses the resulting
    /// wire bytes back to recover the on-wire UID extension and
    /// asserts uniqueness on those bodies. This catches a hypo-
    /// thetical regression where the helper returns distinct UIDs
    /// but `build_client_request` pins them to a constant on the
    /// wire (today the production wire encoding is a verbatim copy
    /// of `req.unique_id`, but the test holds independently of that).
    ///
    /// Why this lives in `api::nts::tests` rather than
    /// `nts::ntp::tests`: `nts::ntp` is intentionally
    /// `getrandom`/`rand`-free (the module-level rustdoc says "all
    /// randomness is supplied by the caller"); the production UID-
    /// generation call site is in `nts_query_inner` here in
    /// `api::nts`, and so is the helper that funnels its randomness.
    ///
    /// 100 iterations catches the gross-brokenness shape; the
    /// birthday bound at 256 bits of UID entropy makes a real-RNG
    /// collision astronomically unlikely, so this test does not
    /// flake on healthy `getrandom`.
    #[test]
    fn consecutive_request_uids_from_helper_are_distinct() {
        use crate::nts::ntp::{
            build_client_request, ext_type, parse_extensions, ClientRequest, HEADER_LEN,
        };
        use std::collections::HashSet;

        let c2s_key = AeadKey::from_keying_material(15, &[0x11u8; 32])
            .expect("c2s key constructs from canonical SIV-CMAC-256 material");
        let nonce_len = c2s_key.nonce_len();
        let cookie = vec![0x55u8; 64];

        let mut seen = HashSet::with_capacity(100);
        for iteration in 0..100 {
            // Production helper: same call site as `nts_query_inner`.
            let (uid, nonce) = super::fresh_request_uid_and_nonce(nonce_len)
                .unwrap_or_else(|e| panic!("iteration {iteration}: helper failed: {e:?}"));

            let req = ClientRequest {
                unique_id: uid.to_vec(),
                cookie: cookie.clone(),
                placeholder_count: 0,
                nonce,
                transmit_timestamp: 0,
            };
            let packet = build_client_request(&req, &c2s_key)
                .unwrap_or_else(|e| panic!("iteration {iteration}: build_client_request: {e:?}"));
            let extensions = parse_extensions(&packet[HEADER_LEN..])
                .unwrap_or_else(|e| panic!("iteration {iteration}: parse_extensions: {e:?}"));
            let on_wire_uid = extensions
                .iter()
                .find(|ext| ext.field_type == ext_type::UNIQUE_IDENTIFIER)
                .unwrap_or_else(|| panic!("iteration {iteration}: UID extension missing on wire"))
                .body
                .clone();
            assert_eq!(
                on_wire_uid.len(),
                UID_LEN,
                "iteration {iteration}: on-wire UID length is not {UID_LEN}",
            );
            assert!(
                seen.insert(on_wire_uid.clone()),
                "iteration {iteration}: UID collision against earlier iteration ({on_wire_uid:02x?})",
            );
        }
        assert_eq!(
            seen.len(),
            100,
            "expected 100 distinct UIDs, got {}",
            seen.len()
        );
    }
}

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
    perform_handshake, KeError, KeOutcome, KePhaseTimings, KeRequest, KeTimeoutPhase,
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

/// Failure modes for `nts_query` (Dart: `ntsQuery`) and
/// `nts_warm_cookies` (Dart: `ntsWarmCookies`).
#[derive(Debug, Clone)]
pub enum NtsError {
    /// `spec` was rejected before any I/O happened.
    InvalidSpec(String),
    /// TCP/UDP I/O error or connection failure.
    Network(String),
    /// TLS handshake or NTS-KE record exchange failed.
    KeProtocol(String),
    /// NTPv4 packet parsing or extension validation failed.
    NtpProtocol(String),
    /// AEAD seal/open failed (tag mismatch, malformed input).
    Authentication(String),
    /// Wall-clock budget elapsed inside one of the call's pre-NTP or
    /// NTP phases. The [`TimeoutPhase`] payload identifies which
    /// phase tripped the deadline so callers can choose the right
    /// remediation (raise the resolver cap on `DnsSaturation`,
    /// lengthen `timeout_ms` on `DnsTimeout` / `Connect` / `Tls` /
    /// `KeRecordIo` / `Ntp`, etc.). See [`TimeoutPhase`] for the full
    /// taxonomy.
    Timeout(TimeoutPhase),
    /// Cookie jar empty after a handshake (server delivered none).
    NoCookies,
    /// Bug guard for unreachable internal states.
    Internal(String),
}

impl std::fmt::Display for NtsError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidSpec(m) => write!(f, "invalid NtsServerSpec: {m}"),
            Self::Network(m) => write!(f, "network: {m}"),
            Self::KeProtocol(m) => write!(f, "NTS-KE: {m}"),
            Self::NtpProtocol(m) => write!(f, "NTPv4: {m}"),
            Self::Authentication(m) => write!(f, "AEAD: {m}"),
            Self::Timeout(p) => write!(f, "operation timed out in phase {p:?}"),
            Self::NoCookies => f.write_str("server delivered no cookies"),
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
            KeError::PhaseTimeout(p) => Self::Timeout(p.into()),
            KeError::Io(io) => Self::Network(io.to_string()),
            KeError::Tls(t) => Self::KeProtocol(format!("TLS: {t}")),
            KeError::NoCookies => Self::NoCookies,
            other => Self::KeProtocol(other.to_string()),
        }
    }
}

impl From<NtpError> for NtsError {
    fn from(e: NtpError) -> Self {
        match e {
            NtpError::Aead(a) => Self::Authentication(a.to_string()),
            // Server-attested "no usable time" signals (RFC 5905 §7.3 LI=3
            // and §7.4 stratum-0 KoD) reach Dart as `NtpProtocol` with the
            // diagnostic string preserved verbatim — for KoD this includes
            // the 4-octet kiss code (`RATE`, `DENY`, `RSTR`, `NTSN`, …) so
            // callers can inspect the message and back off appropriately.
            // We list them explicitly so a future split into dedicated
            // `NtsError` variants is a localised change rather than a hunt
            // through the catch-all arm.
            e @ NtpError::Unsynchronized => Self::NtpProtocol(e.to_string()),
            e @ NtpError::KissOfDeath(_) => Self::NtpProtocol(e.to_string()),
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
            e @ NtpError::StaleCookie => Self::NtpProtocol(e.to_string()),
            other => Self::NtpProtocol(other.to_string()),
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
            AeadError::UnsupportedAlgorithm(_) => Self::KeProtocol(e.to_string()),
            other => Self::Authentication(other.to_string()),
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
            std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock => {
                Self::Timeout(TimeoutPhase::Ntp)
            }
            _ => Self::Network(e.to_string()),
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

/// Per-key singleflight slot. One slot exists per `host:port` while a
/// leader is mid-handshake, so concurrent `checkout` calls against the
/// same key park on the slot rather than each running their own
/// duplicate KE handshake. The leader publishes a `Result<(), NtsError>`
/// when it finishes; waiters receive a `Clone` of that result. Errors
/// propagate to every waiter so a leader's KE failure does not
/// silently retry — followers see the same error semantics they would
/// have observed had they run the handshake themselves.
///
/// The slot does *not* carry the `Session` itself; the leader installs
/// the session into `SessionTable::map` and the waiters re-acquire
/// `map`, look up the freshly installed session, and pop a cookie of
/// their own. This naturally handles the "cookie pool exhausted"
/// case: if more waiters wake than the pool has cookies, the extras
/// simply re-enter the role-election loop and elect a new leader for
/// the next handshake. Each successful KE handshake adds N fresh
/// cookies (typically 8 per RFC 8915) so the loop converges in
/// `ceil(waiters / N)` handshake rounds, not infinitely.
struct HandshakeSlot {
    /// `None` while the leader is mid-handshake; `Some(...)` once the
    /// leader publishes a result. Waiters block on `cv` until this is
    /// non-empty or their per-call deadline elapses.
    result: Mutex<Option<Result<(), NtsError>>>,
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
    fn wait_until(&self, deadline: Instant) -> Option<Result<(), NtsError>> {
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
    fn complete(&self, result: Result<(), NtsError>) {
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
    fn complete(&mut self, result: Result<(), NtsError>) {
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
}

impl NtsClient {
    /// Construct a fresh client with an empty session table.
    ///
    /// Marked `#[flutter_rust_bridge::frb(sync)]` so the generated
    /// Dart side exposes this as the `NtsClient()` default
    /// constructor (synchronous; no isolate hop) rather than as an
    /// `await NtsClient.newInstance()` static factory.
    #[flutter_rust_bridge::frb(sync)]
    pub fn new() -> Self {
        Self {
            table: SessionTable::new(),
        }
    }

    /// Per-client equivalent of the top-level `nts_query`
    /// (`ntsQuery` on the Dart side).
    pub fn query(
        &self,
        spec: NtsServerSpec,
        timeout_ms: u32,
        dns_concurrency_cap: u32,
    ) -> Result<NtsTimeSample, NtsError> {
        nts_query_inner(&self.table, spec, timeout_ms, dns_concurrency_cap)
    }

    /// Per-client equivalent of the top-level `nts_warm_cookies`
    /// (`ntsWarmCookies` on the Dart side).
    pub fn warm_cookies(
        &self,
        spec: NtsServerSpec,
        timeout_ms: u32,
        dns_concurrency_cap: u32,
    ) -> Result<NtsWarmCookiesOutcome, NtsError> {
        nts_warm_cookies_inner(&self.table, spec, timeout_ms, dns_concurrency_cap)
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
fn default_nts_client() -> &'static NtsClient {
    static C: OnceLock<NtsClient> = OnceLock::new();
    C.get_or_init(NtsClient::new)
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
/// `NtsError::Timeout(TimeoutPhase::Ntp)` when the call-wide budget
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
        .ok_or(NtsError::Timeout(TimeoutPhase::Ntp))
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
        .map_err(|e| NtsError::Network(format!("set_read_timeout for recv: {e}")))?;
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
) -> Result<(Session, KePhaseTimings), NtsError> {
    let req = KeRequest {
        host: spec.host.clone(),
        port: spec.port,
        aead_algorithms: vec![aead_ids::AES_SIV_CMAC_256, aead_ids::AES_128_GCM_SIV],
        timeout: Some(timeout),
        dns_concurrency_cap,
    };
    let outcome: KeOutcome = perform_handshake(&req)?;
    let c2s_key = AeadKey::from_keying_material(outcome.aead_id, &outcome.c2s_key)
        .map_err(|e| NtsError::Internal(format!("KE produced unusable C2S key: {e}")))?;
    let s2c_key = AeadKey::from_keying_material(outcome.aead_id, &outcome.s2c_key)
        .map_err(|e| NtsError::Internal(format!("KE produced unusable S2C key: {e}")))?;
    let mut jar = CookieJar::new();
    if outcome.cookies.is_empty() {
        return Err(NtsError::NoCookies);
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
    ) -> Result<(QueryContext, KePhaseTimings), NtsError> {
        self.checkout_with(spec, timeout, dns_concurrency_cap, &|s, t, c| {
            establish_session(s, t, c)
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
                            None => return Err(NtsError::NoCookies),
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
                            guard.complete(Err(NtsError::Timeout(TimeoutPhase::KeRecordIo)));
                            return Err(NtsError::Timeout(TimeoutPhase::KeRecordIo));
                        }
                    };
                    let outcome = do_handshake(spec, remaining, dns_concurrency_cap);
                    match outcome {
                        Ok((session, ke_timings)) => {
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
                                guard.complete(Err(NtsError::NoCookies));
                                return Err(NtsError::NoCookies);
                            }
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
                                    guard.complete(Ok(()));
                                    return Ok((ctx, ke_timings));
                                }
                                None => {
                                    guard.complete(Err(NtsError::NoCookies));
                                    return Err(NtsError::NoCookies);
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
                        // A and pop a cookie. If the new session was
                        // already drained by other concurrently waking
                        // waiters, we fall through to phase B again and
                        // either become the next leader or wait on the
                        // next leader's handshake — `ceil(waiters / N)`
                        // handshake rounds in the worst case, where N is
                        // the cookie-pool size per handshake.
                        Some(Ok(())) => continue,
                        Some(Err(e)) => return Err(e),
                        None => {
                            return Err(NtsError::Timeout(TimeoutPhase::KeRecordIo));
                        }
                    }
                }
            }
        }
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
    /// Used by [`nts_warm_cookies_inner`] after a successful KE handshake.
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
    /// is still time on the clock and `NtsError::Timeout(phase)` once
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
            return Err(NtsError::Timeout(phase));
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
                    std::io::ErrorKind::WouldBlock => {
                        NtsError::Timeout(TimeoutPhase::DnsSaturation)
                    }
                    std::io::ErrorKind::TimedOut => NtsError::Timeout(TimeoutPhase::DnsTimeout),
                    _ => NtsError::Network(format!("DNS lookup failed for {host}:{port}: {e}")),
                });
            }
        };
    let dns_micros = dns_started.elapsed().as_micros() as i64;
    if candidates.is_empty() {
        return Err(NtsError::Network(format!(
            "no addresses resolved for {host}:{port}"
        )));
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
    Err(NtsError::Network(format!(
        "failed to bind/connect any of {} resolved addresses for {host}:{port}: [{}]",
        candidates.len(),
        errors.join("; "),
    )))
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
fn nts_query_inner(
    table: &SessionTable,
    spec: NtsServerSpec,
    timeout_ms: u32,
    dns_concurrency_cap: u32,
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
    let (ctx, ke_timings) = table.checkout(&spec, timeout, cap)?;
    let session_generation = ctx.session_generation;

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
    let evict_on_rekey_signal = |err: NtpError| -> NtsError {
        if matches!(&err, NtpError::Aead(_) | NtpError::StaleCookie) {
            table.evict_session(&key, session_generation);
        }
        NtsError::from(err)
    };

    let mut uid = [0u8; UID_LEN];
    let mut nonce = vec![0u8; ctx.c2s_key.nonce_len()];
    getrandom::getrandom(&mut uid)
        .map_err(|e| NtsError::Internal(format!("RNG failed for UID: {e}")))?;
    getrandom::getrandom(&mut nonce)
        .map_err(|e| NtsError::Internal(format!("RNG failed for nonce: {e}")))?;

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
    let udp_budget = remaining_budget_or_ntp_timeout(timeout, started.elapsed())?;
    let UdpBindOutcome {
        socket,
        dns_micros: udp_dns_micros,
    } = bind_connected_udp(&ctx.ntpv4_host, ctx.ntpv4_port, udp_budget, cap)?;

    let send_at = Instant::now();
    socket.send(&packet)?;

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
    arm_recv_against_call_deadline(&socket, timeout, started.elapsed())?;

    let mut buf = [0u8; 2048];
    let n = socket.recv(&mut buf)?;
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

    Ok(NtsTimeSample {
        utc_unix_micros: ntp64_to_unix_micros(response.header.transmit_timestamp),
        round_trip_micros: rtt_micros,
        server_stratum: response.header.stratum,
        aead_id: ctx.aead_id,
        fresh_cookies: fresh_count,
        phase_timings,
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
fn nts_warm_cookies_inner(
    table: &SessionTable,
    spec: NtsServerSpec,
    timeout_ms: u32,
    dns_concurrency_cap: u32,
) -> Result<NtsWarmCookiesOutcome, NtsError> {
    validate(&spec)?;
    let timeout = effective_timeout(timeout_ms);
    let cap = effective_dns_concurrency_cap(dns_concurrency_cap);
    let (session, ke_timings) = establish_session(&spec, timeout, cap)?;
    let count = session.cookies_remaining() as u32;
    table.install(&spec, session);
    Ok(NtsWarmCookiesOutcome {
        fresh_cookies: count,
        phase_timings: PhaseTimings::from(ke_timings),
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
            Err(NtsError::Authentication(_)) => {}
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
            Err(NtsError::NtpProtocol(_)) => {}
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
            Err(NtsError::NtpProtocol(ref msg)) if msg.contains("NTSN") => {}
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
            Err(NtsError::NtpProtocol(_)) => {}
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
            NtsError::Network(msg) => {
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
    /// returns `NtsError::Timeout(TimeoutPhase::DnsTimeout)` (not
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
            Err(NtsError::Timeout(TimeoutPhase::DnsTimeout)) => {}
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
            Err(NtsError::Timeout(TimeoutPhase::Ntp)) => {}
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
            Err(NtsError::Timeout(TimeoutPhase::Ntp)) => {}
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
                NtsError::Timeout(got) => assert_eq!(
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
                NtsError::Timeout(TimeoutPhase::Ntp) => {}
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
            NtsError::Timeout(TimeoutPhase::Ntp) => {}
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
            let rendered = format!("{}", NtsError::Timeout(phase));
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
            NtsError::Network(msg) => assert!(
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
            Err(NtsError::Timeout(TimeoutPhase::Ntp)) => {}
            other => panic!("elapsed == total must yield Timeout(Ntp), got {other:?}"),
        }

        // Budget overrun: same short-circuit, no panic on saturating sub.
        match remaining_budget_or_ntp_timeout(total, total + Duration::from_millis(50)) {
            Err(NtsError::Timeout(TimeoutPhase::Ntp)) => {}
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
            Err(NtsError::Authentication(_)) => {}
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
            Err(NtsError::Network(msg)) => {
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
            Err(NtsError::Timeout(TimeoutPhase::KeRecordIo)) => {}
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
                Err(NtsError::KeProtocol(
                    "synthetic leader-failure for singleflight test".into(),
                ))
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
                Err(NtsError::KeProtocol(msg)) => {
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
}

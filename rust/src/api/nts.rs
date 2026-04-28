//! NTS public API surface (RFC 8915).
//!
//! Two synchronous entry points are exposed across the FRB v2 worker pool:
//!
//! - [`nts_query`] runs a full Authenticated NTPv4 exchange and returns a
//!   [`NtsTimeSample`]. It performs an NTS-KE handshake on demand if no
//!   cached session exists or the cookie pool is exhausted.
//! - [`nts_warm_cookies`] forces a fresh NTS-KE handshake and ingests the
//!   delivered cookie pool without sending any NTP traffic.
//!
//! Per-host session state (negotiated AEAD keys, NTPv4 destination, cookie
//! jar) lives in a process-wide `Mutex<HashMap>` keyed by `host:port`. This
//! is the only persistent state the bridge maintains.

use std::collections::HashMap;
use std::net::{SocketAddr, ToSocketAddrs, UdpSocket};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use crate::nts::aead::{AeadError, AeadKey};
use crate::nts::cookies::CookieJar;
use crate::nts::ke::{perform_handshake, KeError, KeOutcome, KeRequest};
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

/// Successful authenticated NTPv4 sample.
///
/// This is the raw output of one protocol exchange, not a synchronized
/// clock. See [`nts_query`] for the recommended burst-and-RTT-compensation
/// pattern callers should layer on top.
#[derive(Debug, Clone)]
pub struct NtsTimeSample {
    /// Server transmit time as microseconds since the Unix epoch, taken
    /// directly from the NTPv4 reply. No correction for the one-way
    /// network delay between the server and this caller is applied; add
    /// `round_trip_micros / 2` to estimate the server's clock at the
    /// moment the reply arrived.
    pub utc_unix_micros: i64,
    /// Wall-clock microseconds elapsed between client send and client receive.
    pub round_trip_micros: i64,
    /// NTP stratum reported by the server (RFC 5905 §7.3).
    pub server_stratum: u8,
    /// AEAD algorithm IANA ID negotiated during NTS-KE.
    pub aead_id: u16,
    /// Number of fresh cookies recovered from the encrypted reply.
    pub fresh_cookies: u32,
}

/// Failure modes for [`nts_query`] and [`nts_warm_cookies`].
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
    /// UDP receive timed out.
    Timeout,
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
            Self::Timeout => f.write_str("operation timed out"),
            Self::NoCookies => f.write_str("server delivered no cookies"),
            Self::Internal(m) => write!(f, "internal: {m}"),
        }
    }
}

impl std::error::Error for NtsError {}

impl From<KeError> for NtsError {
    fn from(e: KeError) -> Self {
        match e {
            // Funnel through `From<std::io::Error>` so `TimedOut` /
            // `WouldBlock` (the kinds produced by `connect_timeout` and
            // by socket read/write deadlines) surface as `Timeout`
            // rather than being flattened into `Network`. Without this,
            // a blackholed TCP/4460 destination would arrive on the
            // Dart side as a generic network error after the connect
            // deadline fired.
            KeError::Io(io) => Self::from(io),
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

impl From<std::io::Error> for NtsError {
    fn from(e: std::io::Error) -> Self {
        match e.kind() {
            std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock => Self::Timeout,
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
/// equality against a snapshot taken under the same `sessions()` mutex
/// that gates every read/write of the session table. The mutex
/// provides the cross-thread happens-before relationship; the atomic
/// is here purely to give us a cheap uniqueness oracle without having
/// to widen the lock-protected state.
fn next_session_generation() -> u64 {
    static GEN: AtomicU64 = AtomicU64::new(1);
    GEN.fetch_add(1, Ordering::Relaxed)
}

/// Process-wide session table. Sessions are keyed by `host:port` so two specs
/// with different KE ports stay isolated even when they share a hostname.
fn sessions() -> &'static Mutex<HashMap<String, Session>> {
    static S: OnceLock<Mutex<HashMap<String, Session>>> = OnceLock::new();
    S.get_or_init(|| Mutex::new(HashMap::new()))
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

/// Drive a complete NTS-KE handshake and convert its outcome into a [`Session`].
///
/// The KE driver offers AES-SIV-CMAC-256 first and AES-128-GCM-SIV second:
/// the SIV-CMAC variant is the RFC 8915 §5.1 mandatory baseline and is what
/// every public NTS server we tested actually picks today; GCM-SIV is added
/// purely so a server that prefers nonce-misuse-resistant GCM still resolves
/// to a usable AEAD instead of `UnsupportedAead`.
fn establish_session(spec: &NtsServerSpec, timeout: Duration) -> Result<Session, NtsError> {
    let req = KeRequest {
        host: spec.host.clone(),
        port: spec.port,
        aead_algorithms: vec![aead_ids::AES_SIV_CMAC_256, aead_ids::AES_128_GCM_SIV],
        timeout: Some(timeout),
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
    Ok(Session {
        generation: next_session_generation(),
        aead_id: outcome.aead_id,
        c2s_key,
        s2c_key,
        ntpv4_host: outcome.ntpv4_host,
        ntpv4_port: outcome.ntpv4_port,
        jar,
    })
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

/// Acquire (or establish) a session and pop one cookie. The returned context
/// owns the cookie and key clones so the network exchange runs lock-free.
fn checkout(spec: &NtsServerSpec, timeout: Duration) -> Result<QueryContext, NtsError> {
    let key = session_key(spec);
    let mut guard = sessions().lock().expect("session table poisoned");
    let need_handshake = match guard.get(&key) {
        Some(s) => s.cookies_remaining() == 0,
        None => true,
    };
    if need_handshake {
        // Drop the lock across the multi-RTT KE handshake so other queries
        // against unrelated hosts aren't serialized behind it.
        drop(guard);
        let session = establish_session(spec, timeout)?;
        let mut g = sessions().lock().expect("session table poisoned");
        g.insert(key.clone(), session);
        guard = g;
    }
    let session = guard
        .get_mut(&key)
        .ok_or_else(|| NtsError::Internal("session vanished after install".into()))?;
    let cookie = session
        .jar
        .take(&session.ntpv4_host)
        .ok_or(NtsError::NoCookies)?;
    Ok(QueryContext {
        session_generation: session.generation,
        cookie,
        c2s_key: session.c2s_key.clone(),
        s2c_key: session.s2c_key.clone(),
        ntpv4_host: session.ntpv4_host.clone(),
        ntpv4_port: session.ntpv4_port,
        aead_id: session.aead_id,
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
fn deposit_cookies(spec_key: &str, expected_generation: u64, cookies: Vec<Vec<u8>>) {
    if cookies.is_empty() {
        return;
    }
    let mut guard = sessions().lock().expect("session table poisoned");
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
/// FRB) sees the full picture rather than just the last error. `timeout`
/// is applied identically to read and write deadlines on the returned
/// socket.
///
/// Empty resolution (e.g. NXDOMAIN) maps to
/// `NtsError::Network("no addresses resolved for host:port")`.
fn bind_connected_udp(host: &str, port: u16, timeout: Duration) -> Result<UdpSocket, NtsError> {
    let candidates: Vec<SocketAddr> = (host, port)
        .to_socket_addrs()
        .map_err(|e| NtsError::Network(format!("DNS lookup failed for {host}:{port}: {e}")))?
        .collect();
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
        if let Err(e) = socket.set_read_timeout(Some(timeout)) {
            errors.push(format!("set_read_timeout for {addr}: {e}"));
            continue;
        }
        if let Err(e) = socket.set_write_timeout(Some(timeout)) {
            errors.push(format!("set_write_timeout for {addr}: {e}"));
            continue;
        }
        match socket.connect(addr) {
            Ok(()) => return Ok(socket),
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
/// reuse the cached AEAD keys and spend a stored cookie. `timeout_ms` is
/// applied independently to the KE handshake and to the UDP recv; pass `0`
/// for the built-in `5000` ms default.
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
pub fn nts_query(spec: NtsServerSpec, timeout_ms: u32) -> Result<NtsTimeSample, NtsError> {
    validate(&spec)?;
    let timeout = effective_timeout(timeout_ms);
    let key = session_key(&spec);

    let ctx = checkout(&spec, timeout)?;

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
    let packet = build_client_request(&req, &ctx.c2s_key)?;

    // RFC 5905 is address-family agnostic; bind a local socket that matches
    // the family of whichever resolved address actually accepts a UDP
    // connection. The previous hard-coded `0.0.0.0:0` bind silently broke
    // every IPv6-only NTS endpoint (Netnod and several PTB hosts).
    let socket = bind_connected_udp(&ctx.ntpv4_host, ctx.ntpv4_port, timeout)?;

    let send_at = Instant::now();
    socket.send(&packet)?;

    let mut buf = [0u8; 2048];
    let n = socket.recv(&mut buf)?;
    let rtt_micros = send_at.elapsed().as_micros() as i64;

    let response = parse_server_response(&buf[..n], &uid, transmit_timestamp, &ctx.s2c_key)?;
    let fresh_count = response.fresh_cookies.len() as u32;
    deposit_cookies(&key, ctx.session_generation, response.fresh_cookies);

    Ok(NtsTimeSample {
        utc_unix_micros: ntp64_to_unix_micros(response.header.transmit_timestamp),
        round_trip_micros: rtt_micros,
        server_stratum: response.header.stratum,
        aead_id: ctx.aead_id,
        fresh_cookies: fresh_count,
    })
}

/// Force a fresh NTS-KE handshake against `spec` and return the number of
/// cookies the server delivered. Replaces any cached session for that spec.
pub fn nts_warm_cookies(spec: NtsServerSpec, timeout_ms: u32) -> Result<u32, NtsError> {
    validate(&spec)?;
    let timeout = effective_timeout(timeout_ms);
    let session = establish_session(&spec, timeout)?;
    let count = session.cookies_remaining() as u32;
    let key = session_key(&spec);
    let mut guard = sessions().lock().expect("session table poisoned");
    guard.insert(key, session);
    Ok(count)
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

        let socket = bind_connected_udp("127.0.0.1", echo_port, Duration::from_secs(2))
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

        let socket = bind_connected_udp("::1", echo_port, Duration::from_secs(2))
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

    /// A hostname that resolves to nothing maps to a structured
    /// `NtsError::Network` rather than panicking. We use the
    /// `.invalid` reserved TLD (RFC 6761 §6.4) so the test never
    /// hits a real DNS responder.
    #[test]
    fn bind_connected_udp_reports_dns_failure() {
        let err = bind_connected_udp("no-such-host.invalid", 123, Duration::from_millis(500))
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
        let sample = nts_query(spec.clone(), 10_000).expect("nts_query");
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
        let sample2 = nts_query(spec, 10_000).expect("nts_query 2");
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
        match nts_query(spec, 10_000) {
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
}

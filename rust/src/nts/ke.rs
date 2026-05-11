//! NTS-KE handshake driver (RFC 8915 §4).
//!
//! Synchronous, single-threaded, no async runtime. The handshake is a
//! TCP connect → TLS 1.3 handshake (ALPN `ntske/1`) → exchange of two
//! short record blobs → TLS exporter call → close. The whole thing
//! finishes in well under a second on a healthy network and integrates
//! cleanly into the FRB v2 worker pool as a plain `pub fn`.

use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::sync::Arc;
use std::time::{Duration, Instant};

use super::dns::{resolve_with_global, system_lookup};

use rustls::pki_types::ServerName;
use rustls::{ClientConfig, ClientConnection, RootCertStore, Stream, SupportedProtocolVersion};

use super::records::{
    aead, parse_message, serialize_message, CodecError, Record, RecordKind, MAX_MESSAGE_BYTES,
    NEXT_PROTO_NTPV4,
};

/// RFC 8915 §5.1 fixed exporter label.
const EXPORTER_LABEL: &[u8] = b"EXPORTER-network-time-security";

/// RFC 8915 §4.1.6 — default NTPv4 port when the server omits a Port record.
const DEFAULT_NTPV4_PORT: u16 = 123;

/// IANA "NTS Key Establishment" ALPN protocol identifier (RFC 8915 §4).
const ALPN_NTSKE: &[u8] = b"ntske/1";

/// RFC 8915 §3 — "TLS 1.3 [RFC8446] is the minimum version of TLS that
/// MUST be supported. Earlier versions of TLS MUST NOT be negotiated."
///
/// Pinned to a single-element slice so the rustls config builder cannot
/// fall through to its `with_safe_default_protocol_versions()` path,
/// which (with `--features tls12` enabled anywhere in the dep graph)
/// would also offer TLS 1.2. Combined with the omission of the `tls12`
/// Cargo feature on the `rustls` dependency in `Cargo.toml`, this is a
/// belt-and-braces enforcement of the RFC's downgrade prohibition. See
/// `tls_protocol_versions_are_tls13_only` test below for the regression
/// guard that pins this constant.
const TLS_PROTOCOL_VERSIONS: &[&SupportedProtocolVersion] = &[&rustls::version::TLS13];

/// Single wall-clock budget shared across every blocking phase of one
/// NTS-KE handshake — DNS lookup, per-address TCP connect attempts, TLS
/// handshake, and the chunked record-exchange read loop. Captured once
/// from `Instant::now() + total` at the top of `perform_handshake` so
/// the budget shrinks monotonically as those phases consume time, in
/// place of the prior pattern where each phase received a fresh
/// `Duration` and the wall-clock cost of a single handshake could
/// overshoot the caller's `req.timeout` by 2-3x.
#[derive(Debug, Clone, Copy)]
struct Deadline(Instant);

impl Deadline {
    /// Anchor a deadline `total` from `now`. Callers pass the entire
    /// caller-visible budget (`req.timeout`); subsequent phases consult
    /// [`Deadline::remaining`] before issuing any blocking syscall.
    fn new(total: Duration) -> Self {
        Self(Instant::now() + total)
    }

    /// Time left before the deadline expires. Saturates at
    /// [`Duration::ZERO`] so callers can branch on `is_zero()` without
    /// handling a negative-duration case.
    fn remaining(&self) -> Duration {
        self.0.saturating_duration_since(Instant::now())
    }

    /// Refresh `tcp`'s read+write timeouts so the *next* blocking
    /// syscall on that socket fires no later than the global deadline.
    /// Returns `io::ErrorKind::TimedOut` when the deadline has already
    /// elapsed; callers that want phase-attributed errors should use
    /// [`Deadline::apply_to_with_phase`] instead. Re-applied between
    /// phases (post-connect, before each write/flush, and once per
    /// iteration of the chunked read loop) so a slow trickle from the
    /// server cannot extend the total wall-clock cost past
    /// `req.timeout`.
    fn apply_to(&self, tcp: &TcpStream) -> std::io::Result<()> {
        let remaining = self.remaining();
        if remaining.is_zero() {
            return Err(std::io::Error::new(
                std::io::ErrorKind::TimedOut,
                "NTS-KE deadline elapsed",
            ));
        }
        tcp.set_read_timeout(Some(remaining))?;
        tcp.set_write_timeout(Some(remaining))?;
        Ok(())
    }

    /// Phase-aware variant of [`Deadline::apply_to`]. Translates a
    /// budget-exhausted result directly into `KeError::PhaseTimeout`
    /// so the caller does not have to rely on the
    /// `io::ErrorKind::TimedOut → NtsError::Timeout` round-trip
    /// (which loses phase attribution).
    fn apply_to_with_phase(&self, tcp: &TcpStream, phase: KeTimeoutPhase) -> Result<(), KeError> {
        let remaining = self.remaining();
        if remaining.is_zero() {
            return Err(KeError::PhaseTimeout(phase));
        }
        tcp.set_read_timeout(Some(remaining)).map_err(KeError::Io)?;
        tcp.set_write_timeout(Some(remaining))
            .map_err(KeError::Io)?;
        Ok(())
    }

    /// Yield the remaining budget when there is still time on the
    /// clock and `KeError::PhaseTimeout(phase)` once it has elapsed.
    /// Used immediately before a blocking step so an already-blown
    /// budget short-circuits with the phase that *would* have
    /// consumed it, rather than producing a generic timeout.
    fn check_or_timeout(&self, phase: KeTimeoutPhase) -> Result<Duration, KeError> {
        let remaining = self.remaining();
        if remaining.is_zero() {
            return Err(KeError::PhaseTimeout(phase));
        }
        Ok(remaining)
    }
}

/// Translate an `io::Error` raised inside the bounded DNS resolver
/// into the matching [`KeError::PhaseTimeout`] tag. `WouldBlock` is
/// the cap-saturation signal published by
/// [`crate::nts::dns::try_acquire_slot`]; `TimedOut` is the
/// budget-exceeded signal from `recv_timeout`. Anything else is a
/// real lookup failure (NXDOMAIN, network unreachable, …) and stays
/// as `KeError::Io` so the `From<KeError> for NtsError` mapping can
/// route it onto `NtsError::Network` with the diagnostic preserved.
fn dns_error_to_ke(e: std::io::Error) -> KeError {
    match e.kind() {
        std::io::ErrorKind::WouldBlock => KeError::PhaseTimeout(KeTimeoutPhase::DnsSaturation),
        std::io::ErrorKind::TimedOut => KeError::PhaseTimeout(KeTimeoutPhase::DnsTimeout),
        _ => KeError::Io(e),
    }
}

/// Translate an `io::Error` raised during per-address TCP connect
/// into the matching [`KeError`]. `TimedOut` (the deadline-driven
/// shape) becomes `KeError::PhaseTimeout(Connect)`; non-timeout
/// failures (`ConnectionRefused`, `NetworkUnreachable`, …) stay as
/// `KeError::Io` so they reach Dart as `NtsError::Network`.
fn connect_error_to_ke(e: std::io::Error) -> KeError {
    match e.kind() {
        std::io::ErrorKind::TimedOut => KeError::PhaseTimeout(KeTimeoutPhase::Connect),
        _ => KeError::Io(e),
    }
}

/// Translate an `io::Error` from the TLS / record I/O phases. The
/// rustls Stream surfaces a stalled TCP read/write as
/// `io::ErrorKind::TimedOut` from the underlying socket; that is the
/// phase-tag we want. Other shapes are real I/O failures and stay
/// as [`KeError::Io`].
fn phase_io_to_ke(e: std::io::Error, phase: KeTimeoutPhase) -> KeError {
    match e.kind() {
        std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock => {
            KeError::PhaseTimeout(phase)
        }
        _ => KeError::Io(e),
    }
}

/// Trust-anchor policy for [`KeRequest`]. Mirrors
/// [`crate::api::nts::TrustMode`] across the protocol-layer boundary
/// so the protocol module stays independent of the public-API enum
/// definition.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeTrustMode {
    /// Platform store first, `webpki-roots` static bundle on
    /// `build_with_native_verifier` failure. Default behaviour
    /// preserved across all releases prior to 3.0.0.
    PlatformWithFallback,
    /// Platform store only; `build_with_native_verifier` failure
    /// surfaces as [`KeError::TrustBackendUnavailable`] rather than
    /// downgrading to the static bundle.
    PlatformOnly,
}

/// Trust-anchor backend that authenticated this handshake's TLS chain.
/// Populated by [`perform_handshake`] from the `build_tls_config`
/// resolution and (on Android) from the per-handshake hybrid-fallback
/// observation. Mirrors [`crate::api::nts::TrustBackend`] across the
/// protocol-layer boundary.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeTrustBackend {
    Platform,
    PlatformWithHybridFallback,
    WebpkiRoots,
}

/// Inputs for a single NTS-KE handshake.
#[derive(Debug, Clone)]
pub struct KeRequest {
    /// Hostname to connect to and to use as TLS SNI / cert-validation name.
    pub host: String,
    /// TCP port; RFC 8915 §6 reserves 4460.
    pub port: u16,
    /// AEAD algorithm IDs the client offers, in order of preference.
    /// At least one of `aead::AES_SIV_CMAC_*` must be present.
    pub aead_algorithms: Vec<u16>,
    /// Read/write timeout applied to the underlying TCP socket.
    pub timeout: Option<Duration>,
    /// Per-call ceiling on the process-wide bounded DNS resolver pool
    /// (see [`crate::nts::dns`]). Compared against the global in-flight
    /// counter before the resolver thread is dispatched; saturation
    /// surfaces as `io::ErrorKind::WouldBlock` which the
    /// `From<io::Error> for NtsError` mapping reuses for `Timeout`.
    pub dns_concurrency_cap: usize,
    /// Trust-anchor policy for this handshake. Threads through
    /// [`build_tls_config`] to control the
    /// `build_with_native_verifier` failure-fallback decision. New
    /// in 3.0.0; the public-API layer (`crate::api::nts::NtsClient`)
    /// sets this from its own `TrustMode` field per call, and unit
    /// tests construct `KeRequest` literally with the desired
    /// variant. Pre-3.0 callers that did not name this field
    /// should add `trust_mode: KeTrustMode::PlatformWithFallback`
    /// to preserve existing behaviour.
    pub trust_mode: KeTrustMode,
}

/// Phase of an NTS-KE handshake whose budget elapsed.
///
/// Carried by [`KeError::PhaseTimeout`] so the `From<KeError> for NtsError`
/// mapping in `api/nts.rs` can attribute a failure to a specific
/// pre-handshake step rather than collapsing every wall-clock-bound
/// failure onto an opaque `Timeout`. See `ARCHITECTURE.md`'s "Phase
/// attribution and timings" section for the diagnostic shape.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeTimeoutPhase {
    /// Bounded DNS resolver pool was already at capacity when the call
    /// arrived. Surfaces as `io::ErrorKind::WouldBlock` from
    /// [`crate::nts::dns::resolve_with_global`].
    DnsSaturation,
    /// Resolver took longer than the remaining budget. Surfaces as
    /// `io::ErrorKind::TimedOut` from the bounded resolver.
    DnsTimeout,
    /// Per-address `TcpStream::connect_timeout` budget elapsed before
    /// any candidate accepted, or the global deadline expired before
    /// the connect loop could try the next address.
    Connect,
    /// TLS handshake / initial request write tripped the deadline.
    /// Covers the rustls `Stream::write_all` + `flush` window inside
    /// [`perform_handshake`]; in TLS 1.3 the first write completes the
    /// ClientHello/ServerHello/Finished round-trip.
    Tls,
    /// Read of the NTS-KE response records exceeded the remaining
    /// budget — the server completed TLS but is now drip-feeding (or
    /// has stalled completely on) the record exchange.
    KeRecordIo,
}

/// Microsecond-resolution wall-clock breakdown of a successful
/// NTS-KE handshake. Populated by [`perform_handshake`] and exposed
/// to the FFI as `PhaseTimings` once a query returns an
/// `NtsTimeSample` (the on-success companion to
/// [`KeError::PhaseTimeout`] for failure attribution).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct KePhaseTimings {
    /// Time spent inside [`crate::nts::dns::resolve_with_global`] for
    /// the KE host. `0` for callers that pass `req.timeout = None`
    /// because the unbounded path bypasses the resolver helper.
    pub dns_micros: i64,
    /// Time spent in the per-address `TcpStream::connect_timeout`
    /// loop. Cumulative across attempts when the first address fails.
    pub connect_micros: i64,
    /// Time spent on the rustls `Stream::write_all` + `flush` window.
    /// In TLS 1.3 this includes the ClientHello/ServerHello/Finished
    /// round-trip plus the initial NTS-KE request write.
    pub tls_handshake_micros: i64,
    /// Time spent in the chunked record read loop reading the server's
    /// NTS-KE response.
    pub ke_record_io_micros: i64,
}

/// TCP connection and the timing breakdown that produced it.
#[derive(Debug)]
struct ConnectedTcp {
    stream: TcpStream,
    dns_micros: i64,
    connect_micros: i64,
}

/// All artifacts negotiated during a successful handshake.
#[derive(Debug, Clone)]
pub struct KeOutcome {
    /// Server's chosen NTPv4 host (defaults to `request.host` when omitted).
    pub ntpv4_host: String,
    /// Server's chosen NTPv4 port (defaults to 123 when omitted).
    pub ntpv4_port: u16,
    /// AEAD algorithm IANA ID the server selected.
    pub aead_id: u16,
    /// Client-to-server AEAD key exported from the TLS session.
    pub c2s_key: Vec<u8>,
    /// Server-to-client AEAD key exported from the TLS session.
    pub s2c_key: Vec<u8>,
    /// Initial cookie pool delivered with the response.
    pub cookies: Vec<Vec<u8>>,
    /// Non-fatal warning codes (RFC 8915 §4.1.5 record type 3).
    pub warnings: Vec<u16>,
    /// Microsecond-resolution per-phase wall-clock breakdown of the
    /// handshake. `0` for any phase the call did not enter (e.g.
    /// `req.timeout = None` short-circuits the bounded DNS resolver,
    /// leaving `dns_micros` at zero).
    pub phase_timings: KePhaseTimings,
    /// Trust-anchor backend that authenticated this handshake's TLS
    /// chain. Reflects the `build_tls_config` resolution at config
    /// time plus, on Android, the per-handshake hybrid-fallback
    /// observation: `Platform` if the platform verifier alone
    /// accepted the chain, `PlatformWithHybridFallback` if the
    /// Android `HybridVerifier` overrode a platform verdict via the
    /// `webpki-roots` fallback, `WebpkiRoots` if `build_tls_config`
    /// itself fell back to the static bundle at construction time.
    pub trust_backend: KeTrustBackend,
}

#[derive(Debug)]
pub enum KeError {
    Io(std::io::Error),
    /// A timeout-shaped failure (`io::ErrorKind::TimedOut` or
    /// `WouldBlock`) tagged with the handshake phase it tripped.
    /// `From<KeError> for NtsError` maps this to
    /// `NtsError::Timeout(TimeoutPhase)` so callers can distinguish
    /// DNS saturation from a slow record I/O without inspecting
    /// free-form strings.
    PhaseTimeout(KeTimeoutPhase),
    Tls(rustls::Error),
    InvalidServerName,
    Codec(CodecError),
    /// Server returned an Error record (RFC 8915 §4.1.5 record type 2).
    ServerError(u16),
    /// A critical record we don't recognize was received (RFC 8915 §4.1.4).
    UnknownCritical(u16),
    MissingNextProtocol,
    /// `TrustMode::PlatformOnly` was selected and
    /// `build_with_native_verifier` failed. The payload carries the
    /// underlying `rustls::Error` rendered as a string so the API
    /// layer can preserve the diagnostic on the typed
    /// `NtsError::TrustBackendUnavailable` mapping. Distinct from
    /// `Tls` because the error happens during `ClientConfig`
    /// construction, before any TLS handshake bytes go on the wire,
    /// and reflects a deployment-policy decision rather than a
    /// protocol failure.
    TrustBackendUnavailable(String),
    /// RFC 8915 §4.1.2 — "The NTS Next Protocol Negotiation record [...]
    /// MUST be sent with the Critical Bit set." A server that ships this
    /// record without the C bit is either non-compliant or attempting a
    /// downgrade by encouraging clients to skip a record they would
    /// otherwise be forced to honour; reject before any further parsing.
    NonCriticalNextProtocol,
    NoCommonProtocol,
    MissingAead,
    /// RFC 8915 §4.1.5 — "The AEAD Algorithm Negotiation record [...]
    /// MUST be sent with the Critical Bit set." Same threat shape as
    /// `NonCriticalNextProtocol`: silently accepting a non-critical
    /// AeadAlgorithm record would let an on-path adversary nudge the
    /// client toward an algorithm it would otherwise reject.
    NonCriticalAeadAlgorithm,
    UnsupportedAead(u16),
    NoCookies,
    /// Response exceeded the codec's hard cap before EOF.
    MessageTooLarge,
}

/// A [`KeError`] paired with the trust-anchor backend resolved by
/// [`build_tls_config`] before the failure fired.
///
/// Always `None` for failures that fired *before* `build_tls_config`
/// returned `Ok` (no TLS configuration existed yet, so no backend can
/// be attributed). Always `Some(b)` for post-build failures that
/// happened after the configuration was assembled — including TLS
/// handshake failures, KE record-exchange failures, and any
/// derived-key extraction failures. On Android, when the
/// `HybridVerifier`'s per-instance fallback counter incremented during
/// the handshake, `b == PlatformWithHybridFallback`; otherwise it
/// matches `build.initial_backend`.
///
/// `pub` because it sits on `perform_handshake`'s public signature
/// and threads through `From<KeFailure> for crate::api::nts::NtsError`
/// at the API boundary so the public-API error variants can carry
/// per-handshake trust-backend attribution on the wire.
///
/// `From<KeError> for KeFailure` exists so internal `?`-sites that
/// happen *before* `build_tls_config` succeeds auto-convert with
/// `trust_backend: None` (which is the only correct attribution at
/// that point); post-build sites in `perform_handshake` use
/// [`KeFailure::with_backend`] explicitly so the resolved backend is
/// attached.
#[derive(Debug)]
pub struct KeFailure {
    pub error: KeError,
    pub trust_backend: Option<KeTrustBackend>,
}

impl KeFailure {
    /// Construct a failure with the resolved trust-backend attached.
    /// Used at every `map_err` site in [`perform_handshake`] that fires
    /// after `build_tls_config` has succeeded.
    pub fn with_backend(error: KeError, trust_backend: Option<KeTrustBackend>) -> Self {
        Self {
            error,
            trust_backend,
        }
    }
}

/// Auto-conversion for `?`-propagated errors that fire *before*
/// `build_tls_config` returns `Ok` — there is no resolved backend yet,
/// so `None` is the only honest attribution.
impl From<KeError> for KeFailure {
    fn from(error: KeError) -> Self {
        Self {
            error,
            trust_backend: None,
        }
    }
}

impl std::fmt::Display for KeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Io(e) => write!(f, "I/O error: {e}"),
            Self::PhaseTimeout(p) => write!(f, "NTS-KE timeout in phase {p:?}"),
            Self::Tls(e) => write!(f, "TLS error: {e}"),
            Self::InvalidServerName => f.write_str("hostname is not a valid TLS SNI value"),
            Self::Codec(e) => write!(f, "NTS-KE codec error: {e}"),
            Self::ServerError(c) => write!(f, "server returned NTS-KE error code {c}"),
            Self::UnknownCritical(t) => {
                write!(f, "server sent unknown critical record type {t}")
            }
            Self::MissingNextProtocol => f.write_str("response missing Next Protocol record"),
            Self::NonCriticalNextProtocol => {
                f.write_str("Next Protocol record received without Critical bit (RFC 8915 §4.1.2)")
            }
            Self::NoCommonProtocol => f.write_str("server does not support NTPv4"),
            Self::MissingAead => f.write_str("response missing AEAD Algorithm record"),
            Self::NonCriticalAeadAlgorithm => {
                f.write_str("AEAD Algorithm record received without Critical bit (RFC 8915 §4.1.5)")
            }
            Self::UnsupportedAead(id) => write!(f, "server selected unsupported AEAD ID {id}"),
            Self::NoCookies => f.write_str("response delivered no cookies"),
            Self::MessageTooLarge => {
                write!(f, "NTS-KE response exceeded {MAX_MESSAGE_BYTES}-byte cap",)
            }
            Self::TrustBackendUnavailable(m) => {
                write!(f, "trust backend unavailable (PlatformOnly mode): {m}")
            }
        }
    }
}

impl std::error::Error for KeError {}

impl From<std::io::Error> for KeError {
    fn from(e: std::io::Error) -> Self {
        Self::Io(e)
    }
}

impl From<rustls::Error> for KeError {
    fn from(e: rustls::Error) -> Self {
        Self::Tls(e)
    }
}

impl From<CodecError> for KeError {
    fn from(e: CodecError) -> Self {
        Self::Codec(e)
    }
}

/// AEAD key length in octets per RFC 8915 §5.1 (SIV-CMAC family) and
/// RFC 8452 §4 (GCM-SIV).
fn aead_key_len(id: u16) -> Option<usize> {
    match id {
        aead::AES_SIV_CMAC_256 => Some(32),
        aead::AES_SIV_CMAC_384 => Some(48),
        aead::AES_SIV_CMAC_512 => Some(64),
        aead::AES_128_GCM_SIV => Some(16),
        _ => None,
    }
}

/// Build the 5-octet RFC 8915 §5.1 exporter context for the given direction.
///
/// `s2c == false` → C2S (last byte 0x00).
/// `s2c == true`  → S2C (last byte 0x01).
fn exporter_context(aead_id: u16, s2c: bool) -> [u8; 5] {
    let aead_be = aead_id.to_be_bytes();
    [
        0x00,
        0x00,
        aead_be[0],
        aead_be[1],
        if s2c { 0x01 } else { 0x00 },
    ]
}

/// Build the client request blob: NextProtocol(NTPv4), AeadAlgorithm(prefs), EOM.
///
/// All three records are critical (RFC 8915 §4.1.5 mandates the first two as
/// critical; we mark EOM critical to match every reference implementation).
fn build_request(aead_algorithms: &[u16]) -> Vec<u8> {
    serialize_message(&[
        Record::new(true, RecordKind::NextProtocol(vec![NEXT_PROTO_NTPV4])),
        Record::new(true, RecordKind::AeadAlgorithm(aead_algorithms.to_vec())),
        Record::new(true, RecordKind::EndOfMessage),
    ])
}

/// Apply RFC 8915 §4 server-response validation rules to a parsed record list.
///
/// Returns the synthesized [`KeOutcome`] sans the exported keys; the caller
/// fills those in once the response has been validated against the live TLS
/// session it came from.
fn validate_response(
    request_host: &str,
    offered_aead: &[u16],
    records: &[Record],
) -> Result<KeOutcomePartial, KeError> {
    for r in records {
        if let RecordKind::Error(code) = r.kind {
            return Err(KeError::ServerError(code));
        }
        if r.critical {
            if let RecordKind::Unknown { record_type: t, .. } = &r.kind {
                return Err(KeError::UnknownCritical(*t));
            }
        }
    }
    // RFC 8915 §4.1.2 — the NextProtocol record MUST carry the Critical
    // bit. We capture the bit alongside the value (rather than checking
    // for presence first and the bit second) so a non-critical record is
    // surfaced via its dedicated error variant instead of being silently
    // ignored as if it were absent — that would collapse a downgrade
    // attempt into the indistinguishable "missing record" path.
    let (np_critical, next_proto) = records
        .iter()
        .find_map(|r| match &r.kind {
            RecordKind::NextProtocol(v) => Some((r.critical, v.as_slice())),
            _ => None,
        })
        .ok_or(KeError::MissingNextProtocol)?;
    if !np_critical {
        return Err(KeError::NonCriticalNextProtocol);
    }
    if !next_proto.contains(&NEXT_PROTO_NTPV4) {
        return Err(KeError::NoCommonProtocol);
    }
    // RFC 8915 §4.1.5 — same Critical-bit requirement as NextProtocol,
    // and same anti-downgrade rationale; see comment above.
    let (aead_critical, aead_id) = records
        .iter()
        .find_map(|r| match &r.kind {
            RecordKind::AeadAlgorithm(v) => v.first().copied().map(|id| (r.critical, id)),
            _ => None,
        })
        .ok_or(KeError::MissingAead)?;
    if !aead_critical {
        return Err(KeError::NonCriticalAeadAlgorithm);
    }
    if !offered_aead.contains(&aead_id) {
        return Err(KeError::UnsupportedAead(aead_id));
    }
    if aead_key_len(aead_id).is_none() {
        return Err(KeError::UnsupportedAead(aead_id));
    }
    let cookies: Vec<Vec<u8>> = records
        .iter()
        .filter_map(|r| match &r.kind {
            RecordKind::NewCookie(b) => Some(b.clone()),
            _ => None,
        })
        .collect();
    if cookies.is_empty() {
        return Err(KeError::NoCookies);
    }
    let ntpv4_host = records
        .iter()
        .find_map(|r| match &r.kind {
            RecordKind::Server(s) => Some(s.clone()),
            _ => None,
        })
        .unwrap_or_else(|| request_host.to_owned());
    let ntpv4_port = records
        .iter()
        .find_map(|r| match &r.kind {
            RecordKind::Port(p) => Some(*p),
            _ => None,
        })
        .unwrap_or(DEFAULT_NTPV4_PORT);
    let warnings = records
        .iter()
        .filter_map(|r| match r.kind {
            RecordKind::Warning(c) => Some(c),
            _ => None,
        })
        .collect();
    Ok(KeOutcomePartial {
        ntpv4_host,
        ntpv4_port,
        aead_id,
        cookies,
        warnings,
    })
}

#[derive(Debug)]
struct KeOutcomePartial {
    ntpv4_host: String,
    ntpv4_port: u16,
    aead_id: u16,
    cookies: Vec<Vec<u8>>,
    warnings: Vec<u16>,
}

/// Result of [`build_tls_config`]: the assembled `ClientConfig`, the
/// trust backend resolved at construction time (`Platform` if the
/// platform verifier was wired up, `WebpkiRoots` if the static-bundle
/// fallback fired), and on Android a handle to the per-build
/// `HybridVerifier` so [`perform_handshake`] can sample its
/// per-instance fallback counter after the handshake to tell
/// `Platform` from `PlatformWithHybridFallback` for *this* chain.
///
/// `pub(crate)` because every caller — [`build_tls_config`],
/// [`build_tls_config_inner`] (both cfg arms), and
/// [`perform_handshake`] — lives inside this module; the type is
/// not part of the public Rust API surface.
pub(crate) struct TlsConfigBuild {
    pub(crate) config: Arc<ClientConfig>,
    pub(crate) initial_backend: KeTrustBackend,
    /// `Some` only on Android and only when the platform path resolved
    /// successfully; `None` on every other platform and on the
    /// `WebpkiRoots` hard-fallback path. `perform_handshake` uses
    /// `Option::map(|h| h.fallback_count())` to read the
    /// per-handshake fallback signal without needing platform-gated
    /// match arms in the call site.
    #[cfg(target_os = "android")]
    pub(crate) hybrid: Option<Arc<crate::nts::hybrid_verifier::HybridVerifier>>,
}

/// Build a `ClientConfig` with the platform trust store, `ntske/1` ALPN,
/// and TLS 1.3 as the only acceptable protocol version (RFC 8915 §3).
///
/// Idempotently installs `ring` as the default crypto provider; an error from
/// `install_default()` after the first call is benign (provider already set).
///
/// All three builder paths below funnel through
/// [`ClientConfig::builder_with_protocol_versions`] with
/// [`TLS_PROTOCOL_VERSIONS`] so the resulting config will refuse to
/// negotiate TLS 1.2 even if a future `Cargo.toml` edit re-introduces
/// the `tls12` feature on the `rustls` dependency. The two layers of
/// defence are deliberate: the feature gate trims TLS 1.2 code from the
/// shipped binary, and the in-code constant guarantees protocol-version
/// pinning for any caller that re-enables that code by mistake.
///
/// Verifier selection:
/// - **Android**: `HybridVerifier` (platform verifier with a webpki-roots
///   fallback that activates only on `CertificateError::Revoked` or the
///   `rustls-platform-verifier` JNI-failure marker, to work around
///   missing-OCSP-AIA chains such as Let's Encrypt R12 and R8-stripped
///   AAR classes). Defined in the `crate::nts::hybrid_verifier` module
///   (Android-only; gated by `#[cfg(target_os = "android")]` on its
///   declaration in `nts/mod.rs`, so the rustdoc link is omitted to
///   keep docs warning-free on non-Android targets).
/// - **Other platforms**: bare `rustls_platform_verifier::Verifier`,
///   constructed directly rather than via `ConfigVerifierExt` because
///   that helper hard-codes `with_safe_default_protocol_versions()`
///   which would re-admit TLS 1.2 if the `tls12` feature is on.
/// - **Hard fallback**: a static webpki-roots config. Used when
///   `build_with_native_verifier` errors *and* `trust_mode ==
///   PlatformWithFallback`. Under `PlatformOnly` the same
///   construction failure surfaces as
///   [`KeError::TrustBackendUnavailable`] so callers who pinned a
///   corporate CA see a typed failure instead of a silent downgrade.
///
/// `pub(crate)` because every caller — [`perform_handshake`] and the
/// in-module test fixture — lives inside this module; the function
/// is not part of the public Rust API surface.
pub(crate) fn build_tls_config(trust_mode: KeTrustMode) -> Result<TlsConfigBuild, KeError> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    build_tls_config_inner(trust_mode)
}

#[cfg(target_os = "android")]
fn build_tls_config_inner(trust_mode: KeTrustMode) -> Result<TlsConfigBuild, KeError> {
    match build_with_native_verifier_android() {
        Ok((mut cfg, hybrid)) => {
            cfg.alpn_protocols = vec![ALPN_NTSKE.to_vec()];
            Ok(TlsConfigBuild {
                config: Arc::new(cfg),
                initial_backend: KeTrustBackend::Platform,
                hybrid: Some(hybrid),
            })
        }
        Err(e) => match trust_mode {
            KeTrustMode::PlatformOnly => Err(KeError::TrustBackendUnavailable(e.to_string())),
            KeTrustMode::PlatformWithFallback => {
                let mut cfg = build_with_webpki_roots()?;
                cfg.alpn_protocols = vec![ALPN_NTSKE.to_vec()];
                Ok(TlsConfigBuild {
                    config: Arc::new(cfg),
                    initial_backend: KeTrustBackend::WebpkiRoots,
                    hybrid: None,
                })
            }
        },
    }
}

#[cfg(not(target_os = "android"))]
fn build_tls_config_inner(trust_mode: KeTrustMode) -> Result<TlsConfigBuild, KeError> {
    match build_with_native_verifier() {
        Ok(mut cfg) => {
            cfg.alpn_protocols = vec![ALPN_NTSKE.to_vec()];
            Ok(TlsConfigBuild {
                config: Arc::new(cfg),
                initial_backend: KeTrustBackend::Platform,
            })
        }
        Err(e) => match trust_mode {
            KeTrustMode::PlatformOnly => Err(KeError::TrustBackendUnavailable(e.to_string())),
            KeTrustMode::PlatformWithFallback => {
                let mut cfg = build_with_webpki_roots()?;
                cfg.alpn_protocols = vec![ALPN_NTSKE.to_vec()];
                Ok(TlsConfigBuild {
                    config: Arc::new(cfg),
                    initial_backend: KeTrustBackend::WebpkiRoots,
                })
            }
        },
    }
}

#[cfg(target_os = "android")]
fn build_with_native_verifier_android() -> Result<
    (
        ClientConfig,
        Arc<crate::nts::hybrid_verifier::HybridVerifier>,
    ),
    rustls::Error,
> {
    use crate::nts::hybrid_verifier::HybridVerifier;
    let hybrid = Arc::new(HybridVerifier::new());
    let cfg = ClientConfig::builder_with_protocol_versions(TLS_PROTOCOL_VERSIONS)
        .dangerous()
        .with_custom_certificate_verifier(hybrid.clone())
        .with_no_client_auth();
    Ok((cfg, hybrid))
}

#[cfg(not(target_os = "android"))]
fn build_with_native_verifier() -> Result<ClientConfig, rustls::Error> {
    // We deliberately bypass `rustls_platform_verifier::ConfigVerifierExt`
    // here. That extension trait calls `ClientConfig::builder()` (which
    // expands to `with_safe_default_protocol_versions()`) and would re-
    // admit TLS 1.2 in any build that has the `rustls/tls12` feature on
    // — see RFC 8915 §3 for why that is forbidden. Constructing the
    // `Verifier` directly and threading it through the protocol-version-
    // pinned builder keeps the TLS 1.3-only invariant intact.
    use rustls_platform_verifier::Verifier as PlatformVerifier;
    Ok(
        ClientConfig::builder_with_protocol_versions(TLS_PROTOCOL_VERSIONS)
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(PlatformVerifier::new()))
            .with_no_client_auth(),
    )
}

fn build_with_webpki_roots() -> Result<ClientConfig, KeError> {
    let mut roots = RootCertStore::empty();
    roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
    Ok(
        ClientConfig::builder_with_protocol_versions(TLS_PROTOCOL_VERSIONS)
            .with_root_certificates(roots)
            .with_no_client_auth(),
    )
}

/// Drive a complete NTS-KE handshake against `req.host:req.port` and return
/// the negotiated AEAD parameters, exporter-derived keys, and cookie pool.
///
/// `req.timeout`, when set, is enforced as a single global deadline that
/// spans every blocking phase of the handshake — DNS lookup, per-address
/// TCP connect, TLS handshake, request write, response read loop. The
/// deadline is anchored once at the top of the function (via
/// [`Deadline::new`]) and the remaining budget is re-applied to the
/// underlying `TcpStream`'s read/write timeouts before each phase, so
/// the wall-clock cost cannot exceed the caller's budget regardless of
/// how time is distributed across phases. `req.timeout = None` keeps
/// the prior unbounded behaviour for callers that opt out of timeout
/// enforcement entirely.
pub fn perform_handshake(req: &KeRequest) -> Result<KeOutcome, KeFailure> {
    if req.aead_algorithms.is_empty() {
        return Err(KeError::MissingAead.into());
    }
    let build = build_tls_config(req.trust_mode)?;
    // Snapshot the per-instance hybrid-fallback counter *before* the
    // handshake so we can detect a fallback firing on this specific
    // chain. Only meaningful on Android with the platform path; `None`
    // on other platforms and on the WebpkiRoots hard-fallback path.
    #[cfg(target_os = "android")]
    let pre_fallback = build.hybrid.as_ref().map(|h| h.fallback_count());
    let initial_backend = build.initial_backend;

    // Closure that resolves the trust-backend attribution given the
    // handshake's current observable state. Called both in the success
    // path (to populate `KeOutcome.trust_backend`) and in every
    // post-build error path (to populate `KeFailure.trust_backend`),
    // so the same attribution logic produces the same answer for the
    // same chain whether the handshake succeeded or failed downstream.
    //
    // On non-Android the answer is fully determined at config-build
    // time. On Android the platform path is initially `Platform` and
    // upgrades to `PlatformWithHybridFallback` if and only if
    // `HybridVerifier::verify_server_cert` bumped its per-instance
    // counter past the snapshot we took above — which can only have
    // happened during the TLS handshake `write_all`/`flush` window
    // that completes before `read_to_end_capped` reads the first
    // KE record byte. That means a `KeFailure` raised by record
    // parsing or any later step correctly inherits the same
    // upgraded attribution that a successful handshake would have
    // recorded.
    let resolve_backend = || -> KeTrustBackend {
        #[cfg(target_os = "android")]
        {
            match (initial_backend, &build.hybrid, pre_fallback) {
                (KeTrustBackend::Platform, Some(h), Some(pre)) if h.fallback_count() > pre => {
                    KeTrustBackend::PlatformWithHybridFallback
                }
                (b, _, _) => b,
            }
        }
        #[cfg(not(target_os = "android"))]
        {
            initial_backend
        }
    };
    // Closure that attaches the resolved backend to a `KeError`. Used
    // at every `map_err` site below so post-build failures carry the
    // same attribution a successful handshake would have produced.
    let attribute = |error: KeError| -> KeFailure {
        KeFailure::with_backend(error, Some(resolve_backend()))
    };

    let server_name = ServerName::try_from(req.host.as_str())
        .map_err(|_| KeError::InvalidServerName)
        .map_err(attribute)?;
    let server_name = server_name.to_owned();
    let mut conn = ClientConnection::new(build.config.clone(), server_name)
        .map_err(KeError::from)
        .map_err(attribute)?;

    let deadline = req.timeout.map(Deadline::new);
    let connected = connect_with_deadline_using(
        req.host.as_str(),
        req.port,
        deadline,
        req.dns_concurrency_cap,
        system_lookup,
    )
    .map_err(attribute)?;
    let ConnectedTcp {
        stream: mut tcp,
        dns_micros,
        connect_micros,
    } = connected;
    if let Some(d) = deadline.as_ref() {
        d.apply_to_with_phase(&tcp, KeTimeoutPhase::Tls)
            .map_err(attribute)?;
    }

    let request = build_request(&req.aead_algorithms);
    // Time the TLS handshake + initial request write. In TLS 1.3,
    // rustls drives the ClientHello/ServerHello/Finished round-trip
    // lazily on the first `write_all`, so the wall-clock cost of the
    // handshake is folded into the write/flush window. The subsequent
    // record-read loop is timed separately so callers can attribute a
    // stalled record exchange to `KeRecordIo` rather than to TLS.
    let tls_started = Instant::now();
    let response = {
        let mut stream = Stream::new(&mut conn, &mut tcp);
        if let Some(d) = deadline.as_ref() {
            d.apply_to_with_phase(stream.sock, KeTimeoutPhase::Tls)
                .map_err(attribute)?;
        }
        stream
            .write_all(&request)
            .map_err(|e| attribute(phase_io_to_ke(e, KeTimeoutPhase::Tls)))?;
        if let Some(d) = deadline.as_ref() {
            d.apply_to_with_phase(stream.sock, KeTimeoutPhase::Tls)
                .map_err(attribute)?;
        }
        stream
            .flush()
            .map_err(|e| attribute(phase_io_to_ke(e, KeTimeoutPhase::Tls)))?;
        let tls_handshake_micros = tls_started.elapsed().as_micros() as i64;
        let record_started = Instant::now();
        let response = read_to_end_capped(&mut stream, deadline.as_ref()).map_err(attribute)?;
        let ke_record_io_micros = record_started.elapsed().as_micros() as i64;
        (response, tls_handshake_micros, ke_record_io_micros)
    };
    let (response, tls_handshake_micros, ke_record_io_micros) = response;

    let records = parse_message(&response).map_err(KeError::from).map_err(attribute)?;
    let partial = validate_response(&req.host, &req.aead_algorithms, &records).map_err(attribute)?;

    let key_len = aead_key_len(partial.aead_id).expect("validated above");
    let c2s_ctx = exporter_context(partial.aead_id, false);
    let s2c_ctx = exporter_context(partial.aead_id, true);
    let c2s_key = conn
        .export_keying_material(vec![0u8; key_len], EXPORTER_LABEL, Some(&c2s_ctx))
        .map_err(KeError::from)
        .map_err(attribute)?;
    let s2c_key = conn
        .export_keying_material(vec![0u8; key_len], EXPORTER_LABEL, Some(&s2c_ctx))
        .map_err(KeError::from)
        .map_err(attribute)?;

    conn.send_close_notify();
    let _ = Stream::new(&mut conn, &mut tcp).flush();

    let trust_backend = resolve_backend();

    // `ntp_host` / `ntp_port` are emitted as separate `key=value`
    // pairs rather than a combined `host:port` token because
    // `partial.ntpv4_host` can be an IPv6 literal (RFC 8915 §4.1.7
    // `Server` record carries an arbitrary host string), and a flat
    // `host:port` join makes the address-vs-port boundary
    // unparseable for log scrapers when the host itself contains
    // colons (e.g. `2001:db8::1` + port `4460`).
    log::info!(
        target: "nts::ke",
        "KE handshake ok: host={} aead_id={} cookies={} ntp_host={} ntp_port={} trust_backend={:?}",
        req.host,
        partial.aead_id,
        partial.cookies.len(),
        partial.ntpv4_host,
        partial.ntpv4_port,
        trust_backend,
    );

    Ok(KeOutcome {
        ntpv4_host: partial.ntpv4_host,
        ntpv4_port: partial.ntpv4_port,
        aead_id: partial.aead_id,
        c2s_key,
        s2c_key,
        cookies: partial.cookies,
        warnings: partial.warnings,
        phase_timings: KePhaseTimings {
            dns_micros,
            connect_micros,
            tls_handshake_micros,
            ke_record_io_micros,
        },
        trust_backend,
    })
}

/// Open a TCP connection to `host:port`, bounded by `timeout`.
///
/// When `timeout` is `Some`, a single deadline is established before any
/// I/O begins and is shared by the DNS lookup *and* every per-address
/// `TcpStream::connect_timeout` attempt. The lookup runs through the
/// bounded resolver in [`crate::nts::dns`], which offloads the blocking
/// system call to a worker thread; this prevents a slow or blackholed
/// `getaddrinfo` from stretching the wall-clock cost beyond the
/// caller's budget. Once the deadline has elapsed, the next operation
/// yields a `TimedOut` `io::Error` which the `From<KeError> for
/// NtsError` mapping translates to `NtsError::Timeout` on the Dart
/// side. This replaces the prior plain `TcpStream::connect` call, whose
/// OS-default connect timeout could leave the FFI future hanging for
/// tens of seconds when TCP/4460 is blackholed.
///
/// When `timeout` is `None` (no caller deadline), falls through to
/// [`TcpStream::connect`] for parity with the previous behaviour.
#[cfg(test)]
fn connect_with_timeout(
    host: &str,
    port: u16,
    timeout: Option<Duration>,
) -> Result<ConnectedTcp, KeError> {
    connect_with_timeout_using(
        host,
        port,
        timeout,
        crate::nts::dns::DEFAULT_MAX_INFLIGHT_DNS_LOOKUPS,
        system_lookup,
    )
}

/// Test-friendly variant of [`connect_with_timeout`] that takes a
/// caller-supplied lookup closure. Production callers go through
/// [`connect_with_timeout`] which forwards [`system_lookup`]; the
/// `nts-6ka` slow-DNS regression test injects a closure that
/// `thread::sleep`s past the budget so the deadline path can be
/// exercised deterministically without standing up an adversarial
/// nameserver. Behaviour is otherwise identical to
/// [`connect_with_timeout`].
#[cfg(test)]
fn connect_with_timeout_using<F>(
    host: &str,
    port: u16,
    timeout: Option<Duration>,
    dns_concurrency_cap: usize,
    lookup: F,
) -> Result<ConnectedTcp, KeError>
where
    F: FnOnce(&str, u16) -> std::io::Result<Vec<SocketAddr>> + Send + 'static,
{
    connect_with_deadline_using(
        host,
        port,
        timeout.map(Deadline::new),
        dns_concurrency_cap,
        lookup,
    )
}

/// Core connect helper bounded by an optional [`Deadline`]. When
/// `deadline` is `Some`, the same instant bounds the DNS lookup *and*
/// every per-`SocketAddr` `TcpStream::connect_timeout` attempt, so the
/// total wall-clock cost cannot exceed the caller's original budget.
/// When `deadline` is `None`, falls through to a plain
/// [`TcpStream::connect`] for parity with callers that explicitly opted
/// out of timeout enforcement.
///
/// Pulled out as a standalone helper so [`perform_handshake`] can build
/// its [`Deadline`] once at the top and thread the same instance
/// through both this connect step and the subsequent socket-timeout
/// refreshes during TLS I/O — the previous duration-per-phase API
/// allowed each phase to consume up to `req.timeout` in isolation.
///
/// Returns the connected `TcpStream` together with the wall-clock time
/// spent inside DNS resolution and the per-address connect loop, so
/// [`perform_handshake`] can populate
/// [`KeOutcome::phase_timings`] without re-instrumenting each call
/// site. When `deadline` is `None` (unbounded path) both fields are
/// reported as `0` since the unbounded `TcpStream::connect` does its
/// own internal lookup that is not separately measurable.
fn connect_with_deadline_using<F>(
    host: &str,
    port: u16,
    deadline: Option<Deadline>,
    dns_concurrency_cap: usize,
    lookup: F,
) -> Result<ConnectedTcp, KeError>
where
    F: FnOnce(&str, u16) -> std::io::Result<Vec<SocketAddr>> + Send + 'static,
{
    let Some(deadline) = deadline else {
        let stream = TcpStream::connect((host, port))?;
        return Ok(ConnectedTcp {
            stream,
            dns_micros: 0,
            connect_micros: 0,
        });
    };
    let initial = deadline.check_or_timeout(KeTimeoutPhase::DnsTimeout)?;
    // Bound the resolver by the live remaining budget rather than the
    // caller's original duration. A stalled getaddrinfo would otherwise
    // consume the entire budget before the first connect attempt could
    // even start.
    let dns_started = Instant::now();
    let addrs = resolve_with_global(host, port, initial, dns_concurrency_cap, lookup)
        .map_err(dns_error_to_ke)?;
    let dns_micros = dns_started.elapsed().as_micros() as i64;
    let connect_started = Instant::now();
    let mut last_err: Option<std::io::Error> = None;
    for addr in addrs {
        let remaining = deadline.check_or_timeout(KeTimeoutPhase::Connect)?;
        match TcpStream::connect_timeout(&addr, remaining) {
            Ok(stream) => {
                let connect_micros = connect_started.elapsed().as_micros() as i64;
                return Ok(ConnectedTcp {
                    stream,
                    dns_micros,
                    connect_micros,
                });
            }
            Err(e) => last_err = Some(e),
        }
    }
    Err(connect_error_to_ke(last_err.unwrap_or_else(|| {
        std::io::Error::new(
            std::io::ErrorKind::AddrNotAvailable,
            format!("no addresses resolved for {host}:{port}"),
        )
    })))
}

/// Read until the peer closes the TLS stream or the cap is reached.
///
/// Servers terminate the NTS-KE message with a record-level End-of-Message
/// followed by a TLS `close_notify`; rustls surfaces that as a clean EOF on
/// the next read. A `WouldBlock` from the underlying TCP socket is mapped to
/// `KeError::PhaseTimeout(KeRecordIo)` so callers can attribute the
/// failure to the record-read phase rather than to a generic
/// `Network` error.
///
/// When `deadline` is `Some`, the loop refreshes the underlying
/// `TcpStream`'s read/write timeouts before every `stream.read` call so
/// the budget shrinks per-iteration. Without this refresh,
/// `set_read_timeout` would re-arm a fresh `remaining` window for every
/// chunk and a slow trickle from the server could extend the total
/// wall-clock cost past the caller's `req.timeout`. A deadline already
/// expired before the next read is surfaced as
/// `KeError::PhaseTimeout(KeRecordIo)`.
fn read_to_end_capped(
    stream: &mut Stream<'_, ClientConnection, TcpStream>,
    deadline: Option<&Deadline>,
) -> Result<Vec<u8>, KeError> {
    let mut buf = Vec::with_capacity(4096);
    let mut chunk = [0u8; 4096];
    loop {
        if let Some(d) = deadline {
            d.apply_to_with_phase(stream.sock, KeTimeoutPhase::KeRecordIo)?;
        }
        match stream.read(&mut chunk) {
            Ok(0) => return Ok(buf),
            Ok(n) => {
                if buf.len() + n > MAX_MESSAGE_BYTES {
                    return Err(KeError::MessageTooLarge);
                }
                buf.extend_from_slice(&chunk[..n]);
            }
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(phase_io_to_ke(e, KeTimeoutPhase::KeRecordIo)),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::nts::records::record_type;

    fn rec(critical: bool, kind: RecordKind) -> Record {
        Record::new(critical, kind)
    }

    /// RFC 8915 §3 forbids negotiating any TLS version below 1.3. The
    /// configuration constant must contain exactly one element pointing
    /// at `rustls::version::TLS13`. If a future edit slips `TLS12` back
    /// into this slice (or empties it, which would also be a downgrade
    /// vector since rustls would then fall through to the safe-default
    /// version set), this test fails before the change can land.
    #[test]
    fn tls_protocol_versions_are_tls13_only() {
        assert_eq!(
            TLS_PROTOCOL_VERSIONS.len(),
            1,
            "expected exactly one allowed TLS version"
        );
        let v = TLS_PROTOCOL_VERSIONS[0];
        assert_eq!(
            v.version,
            rustls::ProtocolVersion::TLSv1_3,
            "RFC 8915 §3 requires TLS 1.3 only; got {:?}",
            v.version,
        );
    }

    /// `build_tls_config` is the single funnel through which every
    /// handshake-bound `ClientConfig` flows. The integration property we
    /// can assert from outside the rustls crate (whose `versions` field
    /// is `pub(crate)`) is that the config builds without error and
    /// advertises the `ntske/1` ALPN identifier required by RFC 8915 §4.
    /// The TLS 1.3-only invariant is enforced by two upstream guards:
    /// the omission of the `rustls/tls12` Cargo feature in
    /// `rust/Cargo.toml` (build-time, removes TLS 1.2 code
    /// from the binary entirely) and the `TLS_PROTOCOL_VERSIONS`
    /// constant pinned by `tls_protocol_versions_are_tls13_only` above
    /// (in-code, refuses to negotiate TLS 1.2 even if a future edit
    /// re-adds the feature). Together those two checks make a runtime
    /// version probe redundant at this layer.
    #[test]
    fn build_tls_config_advertises_ntske_alpn() {
        let build = build_tls_config(KeTrustMode::PlatformWithFallback).expect("config builds");
        assert_eq!(build.config.alpn_protocols, vec![ALPN_NTSKE.to_vec()]);
    }

    /// `PlatformOnly` and `PlatformWithFallback` differ only on the
    /// `build_with_native_verifier` failure path: when the verifier
    /// constructs successfully (the host's normal case), both modes
    /// must produce a config that advertises the `ntske/1` ALPN and
    /// reports `KeTrustBackend::Platform`. The failure-path divergence
    /// (`PlatformOnly` → `KeError::TrustBackendUnavailable` vs
    /// `PlatformWithFallback` → `KeTrustBackend::WebpkiRoots`) is not
    /// reachable from a unit test on the host because
    /// `build_with_native_verifier` does not fail there; it requires
    /// the faux-responder fixture tracked separately.
    #[test]
    fn build_tls_config_platform_only_succeeds_when_verifier_constructs() {
        let build = build_tls_config(KeTrustMode::PlatformOnly).expect("config builds");
        assert_eq!(build.config.alpn_protocols, vec![ALPN_NTSKE.to_vec()]);
        assert_eq!(build.initial_backend, KeTrustBackend::Platform);
    }

    #[test]
    fn build_request_emits_expected_bytes() {
        // NextProtocol(NTPv4) crit + AeadAlgorithm(SIV-256) crit + EOM crit.
        // 4-byte hdr + 2 (proto) | 4 + 2 (aead) | 4 (eom) = 16 octets.
        let bytes = build_request(&[aead::AES_SIV_CMAC_256]);
        let expected = vec![
            0x80,
            record_type::NEXT_PROTOCOL as u8,
            0x00,
            0x02,
            0x00,
            0x00, // type 1, NTPv4
            0x80,
            record_type::AEAD_ALGORITHM as u8,
            0x00,
            0x02,
            0x00,
            0x0F, // type 4, SIV-256
            0x80,
            record_type::END_OF_MESSAGE as u8,
            0x00,
            0x00, // type 0
        ];
        assert_eq!(bytes, expected);
    }

    #[test]
    fn exporter_context_matches_rfc_8915() {
        // RFC 8915 §5.1: 5 octets — proto (NTPv4=0), AEAD ID, direction byte.
        assert_eq!(
            exporter_context(aead::AES_SIV_CMAC_256, false),
            [0, 0, 0, 15, 0]
        );
        assert_eq!(
            exporter_context(aead::AES_SIV_CMAC_256, true),
            [0, 0, 0, 15, 1]
        );
        assert_eq!(
            exporter_context(aead::AES_SIV_CMAC_384, false),
            [0, 0, 0, 16, 0]
        );
        assert_eq!(
            exporter_context(aead::AES_SIV_CMAC_512, true),
            [0, 0, 0, 17, 1]
        );
    }

    #[test]
    fn aead_key_lengths_match_rfc_8915() {
        assert_eq!(aead_key_len(aead::AES_SIV_CMAC_256), Some(32));
        assert_eq!(aead_key_len(aead::AES_SIV_CMAC_384), Some(48));
        assert_eq!(aead_key_len(aead::AES_SIV_CMAC_512), Some(64));
        // RFC 8452 §4 — AES-128-GCM-SIV uses a 128-bit key.
        assert_eq!(aead_key_len(aead::AES_128_GCM_SIV), Some(16));
        assert_eq!(aead_key_len(0xFFFF), None);
        assert_eq!(aead_key_len(14), None);
    }

    fn well_formed_response() -> Vec<Record> {
        vec![
            rec(true, RecordKind::NextProtocol(vec![NEXT_PROTO_NTPV4])),
            rec(
                true,
                RecordKind::AeadAlgorithm(vec![aead::AES_SIV_CMAC_256]),
            ),
            rec(false, RecordKind::NewCookie(vec![1, 2, 3, 4, 5, 6, 7, 8])),
            rec(
                false,
                RecordKind::NewCookie(vec![9, 10, 11, 12, 13, 14, 15, 16]),
            ),
            rec(true, RecordKind::EndOfMessage),
        ]
    }

    #[test]
    fn validate_response_accepts_minimal_well_formed() {
        let records = well_formed_response();
        let p = validate_response("time.example.com", &[aead::AES_SIV_CMAC_256], &records).unwrap();
        assert_eq!(p.aead_id, aead::AES_SIV_CMAC_256);
        assert_eq!(p.cookies.len(), 2);
        assert_eq!(p.ntpv4_host, "time.example.com");
        assert_eq!(p.ntpv4_port, 123);
        assert!(p.warnings.is_empty());
    }

    #[test]
    fn validate_response_honors_server_and_port_override() {
        let mut records = well_formed_response();
        records.insert(
            2,
            rec(false, RecordKind::Server("ntp.alt.example".to_owned())),
        );
        records.insert(3, rec(false, RecordKind::Port(4123)));
        let p = validate_response("ke.example.com", &[aead::AES_SIV_CMAC_256], &records).unwrap();
        assert_eq!(p.ntpv4_host, "ntp.alt.example");
        assert_eq!(p.ntpv4_port, 4123);
    }

    #[test]
    fn validate_response_propagates_server_error() {
        let records = vec![
            rec(true, RecordKind::NextProtocol(vec![NEXT_PROTO_NTPV4])),
            rec(true, RecordKind::Error(2)),
            rec(true, RecordKind::EndOfMessage),
        ];
        match validate_response("h", &[aead::AES_SIV_CMAC_256], &records) {
            Err(KeError::ServerError(2)) => {}
            other => panic!("expected ServerError(2), got {other:?}"),
        }
    }

    #[test]
    fn validate_response_rejects_unknown_critical() {
        let records = vec![
            rec(true, RecordKind::NextProtocol(vec![NEXT_PROTO_NTPV4])),
            rec(
                true,
                RecordKind::Unknown {
                    record_type: 0x4242,
                    body: vec![],
                },
            ),
            rec(true, RecordKind::EndOfMessage),
        ];
        match validate_response("h", &[aead::AES_SIV_CMAC_256], &records) {
            Err(KeError::UnknownCritical(0x4242)) => {}
            other => panic!("expected UnknownCritical, got {other:?}"),
        }
    }

    #[test]
    fn validate_response_rejects_no_common_protocol() {
        let records = vec![
            rec(true, RecordKind::NextProtocol(vec![0xFFFF])),
            rec(
                true,
                RecordKind::AeadAlgorithm(vec![aead::AES_SIV_CMAC_256]),
            ),
            rec(false, RecordKind::NewCookie(vec![0; 8])),
            rec(true, RecordKind::EndOfMessage),
        ];
        match validate_response("h", &[aead::AES_SIV_CMAC_256], &records) {
            Err(KeError::NoCommonProtocol) => {}
            other => panic!("expected NoCommonProtocol, got {other:?}"),
        }
    }

    #[test]
    fn validate_response_rejects_unsupported_aead() {
        let records = vec![
            rec(true, RecordKind::NextProtocol(vec![NEXT_PROTO_NTPV4])),
            rec(true, RecordKind::AeadAlgorithm(vec![999])),
            rec(false, RecordKind::NewCookie(vec![0; 8])),
            rec(true, RecordKind::EndOfMessage),
        ];
        match validate_response("h", &[aead::AES_SIV_CMAC_256], &records) {
            Err(KeError::UnsupportedAead(999)) => {}
            other => panic!("expected UnsupportedAead(999), got {other:?}"),
        }
    }

    #[test]
    fn validate_response_rejects_no_cookies() {
        let records = vec![
            rec(true, RecordKind::NextProtocol(vec![NEXT_PROTO_NTPV4])),
            rec(
                true,
                RecordKind::AeadAlgorithm(vec![aead::AES_SIV_CMAC_256]),
            ),
            rec(true, RecordKind::EndOfMessage),
        ];
        match validate_response("h", &[aead::AES_SIV_CMAC_256], &records) {
            Err(KeError::NoCookies) => {}
            other => panic!("expected NoCookies, got {other:?}"),
        }
    }

    /// RFC 8915 §4.1.2 — a NextProtocol record without the Critical bit
    /// is a protocol violation and must be rejected before any further
    /// processing of the response. Crafted response is otherwise
    /// well-formed (correct kind, NTPv4 protocol ID, valid AEAD, present
    /// cookies) so the only signal driving the rejection is the cleared
    /// C bit on the first record.
    #[test]
    fn validate_response_rejects_non_critical_next_protocol() {
        let mut records = well_formed_response();
        records[0] = rec(false, RecordKind::NextProtocol(vec![NEXT_PROTO_NTPV4]));
        match validate_response("h", &[aead::AES_SIV_CMAC_256], &records) {
            Err(KeError::NonCriticalNextProtocol) => {}
            other => panic!("expected NonCriticalNextProtocol, got {other:?}"),
        }
    }

    /// RFC 8915 §4.1.5 — symmetric to the NextProtocol case above; an
    /// AeadAlgorithm record without the Critical bit must short-circuit
    /// the handshake before key export.
    #[test]
    fn validate_response_rejects_non_critical_aead_algorithm() {
        let mut records = well_formed_response();
        records[1] = rec(
            false,
            RecordKind::AeadAlgorithm(vec![aead::AES_SIV_CMAC_256]),
        );
        match validate_response("h", &[aead::AES_SIV_CMAC_256], &records) {
            Err(KeError::NonCriticalAeadAlgorithm) => {}
            other => panic!("expected NonCriticalAeadAlgorithm, got {other:?}"),
        }
    }

    /// When both the NextProtocol and AeadAlgorithm records lack the
    /// Critical bit, the NextProtocol violation must surface first —
    /// it appears earlier in `validate_response` and rejecting on it
    /// keeps the diagnostic deterministic for callers that pattern-match
    /// on the variant for retry/backoff classification.
    #[test]
    fn validate_response_rejects_non_critical_next_protocol_first() {
        let mut records = well_formed_response();
        records[0] = rec(false, RecordKind::NextProtocol(vec![NEXT_PROTO_NTPV4]));
        records[1] = rec(
            false,
            RecordKind::AeadAlgorithm(vec![aead::AES_SIV_CMAC_256]),
        );
        match validate_response("h", &[aead::AES_SIV_CMAC_256], &records) {
            Err(KeError::NonCriticalNextProtocol) => {}
            other => panic!("expected NonCriticalNextProtocol, got {other:?}"),
        }
    }

    /// When the client offers `[SIV-CMAC-256, AES-128-GCM-SIV]` and the server
    /// echoes a single AeadAlgorithm record, `validate_response` must accept
    /// whichever ID the server actually picked. The KE driver itself does not
    /// re-prioritise — that's the server's prerogative per RFC 8915 §4.1.5 —
    /// but it must not reject either of the offered IDs.
    #[test]
    fn validate_response_accepts_either_offered_aead() {
        let offered = [aead::AES_SIV_CMAC_256, aead::AES_128_GCM_SIV];

        let mut server_picks_siv = well_formed_response();
        if let RecordKind::AeadAlgorithm(v) = &mut server_picks_siv[1].kind {
            *v = vec![aead::AES_SIV_CMAC_256];
        }
        let p1 = validate_response("h", &offered, &server_picks_siv).unwrap();
        assert_eq!(p1.aead_id, aead::AES_SIV_CMAC_256);

        let mut server_picks_gcm = well_formed_response();
        if let RecordKind::AeadAlgorithm(v) = &mut server_picks_gcm[1].kind {
            *v = vec![aead::AES_128_GCM_SIV];
        }
        let p2 = validate_response("h", &offered, &server_picks_gcm).unwrap();
        assert_eq!(p2.aead_id, aead::AES_128_GCM_SIV);
    }

    /// `build_request` must serialise multi-AEAD offers in the order the
    /// caller specified — the AeadAlgorithm record is a `Vec<u16>` whose
    /// position-zero element is the client's most-preferred algorithm
    /// (RFC 8915 §4.1.5). This test pins that ordering as a regression guard
    /// since the KE driver's preference is set by `establish_session` in
    /// `api/nts.rs` and we don't want a future refactor to silently flip it.
    #[test]
    fn build_request_preserves_aead_preference_order() {
        let bytes = build_request(&[aead::AES_SIV_CMAC_256, aead::AES_128_GCM_SIV]);
        // Body of the AeadAlgorithm record is at offset 10 (4 hdr + 2 body for
        // NextProtocol + 4 hdr) — easier to parse it back than count by hand.
        let records = parse_message(&bytes).unwrap();
        let aead_record = records
            .iter()
            .find_map(|r| match &r.kind {
                RecordKind::AeadAlgorithm(v) => Some(v.clone()),
                _ => None,
            })
            .expect("AeadAlgorithm record present");
        assert_eq!(
            aead_record,
            vec![aead::AES_SIV_CMAC_256, aead::AES_128_GCM_SIV]
        );
    }

    /// `connect_with_timeout` must honour the caller's deadline when the
    /// destination is blackholed. RFC 5737 reserves `192.0.2.0/24`
    /// (TEST-NET-1) for documentation; no public network advertises a
    /// route for it, so a SYN to `192.0.2.1:4460` either gets dropped on
    /// the wire (deadline fires mid-SYN) or rejected locally with a
    /// routing error (`EHOSTUNREACH` / `ENETUNREACH`). Both outcomes
    /// satisfy the contract — what we assert is that the call returns
    /// well inside the OS-default ~75 s connect window, which is the
    /// regression this helper exists to prevent. When the deadline
    /// itself fires, the result must be
    /// `KeError::PhaseTimeout(KeTimeoutPhase::Connect)` so the
    /// `From<KeError> for NtsError` mapping produces
    /// `NtsError::Timeout(TimeoutPhase::Connect)` rather than a
    /// generic `Network` error.
    #[test]
    fn connect_with_timeout_respects_budget_for_unroutable_ip() {
        let budget = Duration::from_millis(500);
        let started = Instant::now();
        let result = connect_with_timeout("192.0.2.1", 4460, Some(budget));
        let elapsed = started.elapsed();

        let err = result.expect_err("connecting to 192.0.2.1:4460 must fail");

        // The cap is generous enough to absorb scheduling jitter on slow
        // CI runners while still being orders of magnitude tighter than
        // the OS-default connect timeout this code path replaces.
        let cap = Duration::from_secs(5);
        assert!(
            elapsed < cap,
            "connect took {elapsed:?} (> {cap:?}); OS-default connect \
             timeout is leaking through (err = {err:?})",
        );

        // When the deadline elapsed (rather than the OS rejecting
        // immediately), the variant must be PhaseTimeout(Connect) so
        // downstream error mapping produces NtsError::Timeout(Connect).
        if elapsed >= budget {
            assert!(
                matches!(err, KeError::PhaseTimeout(KeTimeoutPhase::Connect)),
                "deadline elapsed after {elapsed:?} but error was \
                 {err:?}; would not surface as NtsError::Timeout(Connect)",
            );
        }
    }

    /// Slow-DNS regression guard for [`connect_with_timeout`]. Injects a
    /// resolver that blocks past the budget and asserts the call returns
    /// `KeError::PhaseTimeout(DnsTimeout)` well inside the cap.
    /// Pinning the variant here is what the `From<KeError> for
    /// NtsError` mapping in `api/nts.rs` relies on to surface stalled
    /// `getaddrinfo` as `NtsError::Timeout(DnsTimeout)` rather than as
    /// a generic network error. Companion to `dns::tests::slow_resolver_*`
    /// and `api::nts::tests::bind_connected_udp_surfaces_slow_dns_*`;
    /// see `nts-6ka` for the full set of injection points.
    #[test]
    fn connect_with_timeout_surfaces_slow_dns_as_timed_out() {
        let budget = Duration::from_millis(50);
        let started = Instant::now();
        // Generous cap so this test stays isolated from any other
        // test in the suite that holds slots in the global resolver
        // pool. The test is pinning the slow-DNS → DnsTimeout mapping,
        // not the cap-exhaustion path (which has dedicated coverage in
        // `dns::tests::cap_reached_returns_would_block`).
        let result =
            connect_with_timeout_using("ignored.invalid", 0, Some(budget), 64, |_host, _port| {
                std::thread::sleep(Duration::from_secs(2));
                Ok(vec![SocketAddr::from(([127, 0, 0, 1], 0))])
            });
        let elapsed = started.elapsed();

        let err = result.expect_err("slow resolver must trip the deadline");
        assert!(
            matches!(err, KeError::PhaseTimeout(KeTimeoutPhase::DnsTimeout)),
            "slow-DNS path must surface as PhaseTimeout(DnsTimeout), got {err:?}",
        );
        let cap = budget * 5;
        assert!(
            elapsed < cap,
            "connect_with_timeout took {elapsed:?} (> {cap:?}); \
             resolver budget did not propagate",
        );
    }

    /// Pins the `Deadline::remaining` saturation contract: once the
    /// anchored instant has passed, `remaining()` reports zero rather
    /// than panicking on the underlying `Duration` subtraction.
    /// `apply_to` and the connect/read paths in `perform_handshake`
    /// rely on `is_zero()` as the "deadline elapsed" signal, so
    /// regressing this would silently re-enable budget overshoot.
    #[test]
    fn deadline_remaining_saturates_at_zero_after_expiry() {
        let d = Deadline::new(Duration::from_micros(1));
        std::thread::sleep(Duration::from_millis(10));
        assert!(
            d.remaining().is_zero(),
            "expired deadline must saturate at zero, got {:?}",
            d.remaining(),
        );
    }

    /// `Deadline::apply_to` is the funnel that translates "budget
    /// elapsed" into the `io::Error` shape the `From<KeError> for
    /// NtsError` mapping in `api/nts.rs` recognises as
    /// `NtsError::Timeout`. Any other `ErrorKind` would surface as
    /// `NtsError::Network`, which is exactly the regression this
    /// helper exists to prevent.
    #[test]
    fn deadline_apply_to_returns_timed_out_when_expired() {
        let d = Deadline::new(Duration::from_micros(1));
        std::thread::sleep(Duration::from_millis(10));
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let tcp = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
        let err = d.apply_to(&tcp).expect_err("expired deadline must fail");
        assert_eq!(err.kind(), std::io::ErrorKind::TimedOut);
    }

    /// `apply_to` must shrink the socket's read/write timeouts to the
    /// remaining budget (not re-arm the original duration). Pinning
    /// both bounds — strictly positive and bounded above by the
    /// configured budget — guarantees that subsequent socket syscalls
    /// will trip well before the original `req.timeout` could have
    /// allowed them to.
    #[test]
    fn deadline_apply_to_sets_socket_timeouts_within_remaining_budget() {
        let budget = Duration::from_millis(500);
        let d = Deadline::new(budget);
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let tcp = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
        d.apply_to(&tcp).expect("non-zero remaining");
        let read_t = tcp.read_timeout().unwrap().expect("read timeout set");
        let write_t = tcp.write_timeout().unwrap().expect("write timeout set");
        assert!(
            read_t > Duration::ZERO && read_t <= budget,
            "read timeout {read_t:?} must be in (0, {budget:?}]",
        );
        assert!(
            write_t > Duration::ZERO && write_t <= budget,
            "write timeout {write_t:?} must be in (0, {budget:?}]",
        );
    }

    /// Phase-aware variant of `apply_to`. Translates an expired
    /// budget directly to `KeError::PhaseTimeout(phase)` so the
    /// phase tag survives without round-tripping through
    /// `io::ErrorKind::TimedOut`. Pinning every supported phase here
    /// ensures a future edit that hard-codes a single phase can't
    /// silently regress the attribution.
    #[test]
    fn deadline_apply_to_with_phase_returns_phase_timeout_when_expired() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        for phase in [
            KeTimeoutPhase::DnsSaturation,
            KeTimeoutPhase::DnsTimeout,
            KeTimeoutPhase::Connect,
            KeTimeoutPhase::Tls,
            KeTimeoutPhase::KeRecordIo,
        ] {
            let d = Deadline::new(Duration::from_micros(1));
            std::thread::sleep(Duration::from_millis(10));
            let tcp = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
            match d.apply_to_with_phase(&tcp, phase) {
                Err(KeError::PhaseTimeout(got)) => assert_eq!(got, phase),
                other => panic!(
                    "expired apply_to_with_phase({phase:?}) yielded {other:?}; \
                     expected KeError::PhaseTimeout({phase:?})",
                ),
            }
        }
    }

    /// Non-expired companion to the test above: when budget remains,
    /// `apply_to_with_phase` must shrink the socket's read+write
    /// timeouts to a strictly-positive value bounded above by the
    /// configured budget. Same shape as
    /// `deadline_apply_to_sets_socket_timeouts_within_remaining_budget`
    /// but exercising the phase-aware entry point.
    #[test]
    fn deadline_apply_to_with_phase_sets_socket_timeouts_within_remaining() {
        let budget = Duration::from_millis(500);
        let d = Deadline::new(budget);
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let tcp = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
        d.apply_to_with_phase(&tcp, KeTimeoutPhase::Tls)
            .expect("non-zero remaining");
        let read_t = tcp.read_timeout().unwrap().expect("read timeout set");
        let write_t = tcp.write_timeout().unwrap().expect("write timeout set");
        assert!(
            read_t > Duration::ZERO && read_t <= budget,
            "read timeout {read_t:?} must be in (0, {budget:?}]",
        );
        assert!(
            write_t > Duration::ZERO && write_t <= budget,
            "write timeout {write_t:?} must be in (0, {budget:?}]",
        );
    }

    /// `check_or_timeout` is the funnel `connect_with_deadline_using`
    /// consults before each blocking step. An expired budget must
    /// short-circuit with the supplied phase tag; a live budget must
    /// hand back the remaining slack so the caller can pass it to
    /// `connect_timeout` / `resolve_with_global` unchanged.
    #[test]
    fn deadline_check_or_timeout_short_circuits_after_expiry() {
        let d = Deadline::new(Duration::from_micros(1));
        std::thread::sleep(Duration::from_millis(10));
        match d.check_or_timeout(KeTimeoutPhase::DnsTimeout) {
            Err(KeError::PhaseTimeout(KeTimeoutPhase::DnsTimeout)) => {}
            other => panic!(
                "expired check_or_timeout yielded {other:?}; \
                 expected KeError::PhaseTimeout(DnsTimeout)",
            ),
        }

        let live = Deadline::new(Duration::from_millis(500));
        let remaining = live
            .check_or_timeout(KeTimeoutPhase::Connect)
            .expect("non-zero remaining");
        assert!(
            remaining > Duration::ZERO && remaining <= Duration::from_millis(500),
            "live check_or_timeout returned {remaining:?}; \
             expected (0, 500ms]",
        );
    }

    /// Pins the three branches of `dns_error_to_ke`. The
    /// bounded-DNS resolver surfaces three distinct `io::Error`
    /// kinds and each must route to a distinct `KeError` shape so
    /// the `From<KeError> for NtsError` mapping in `api/nts.rs`
    /// preserves the difference between pool saturation, deadline
    /// expiry, and a real lookup failure.
    #[test]
    fn dns_error_to_ke_translates_each_io_kind() {
        match dns_error_to_ke(std::io::Error::from(std::io::ErrorKind::WouldBlock)) {
            KeError::PhaseTimeout(KeTimeoutPhase::DnsSaturation) => {}
            other => panic!("WouldBlock -> {other:?}; expected DnsSaturation"),
        }
        match dns_error_to_ke(std::io::Error::from(std::io::ErrorKind::TimedOut)) {
            KeError::PhaseTimeout(KeTimeoutPhase::DnsTimeout) => {}
            other => panic!("TimedOut -> {other:?}; expected DnsTimeout"),
        }
        let raw = std::io::Error::new(std::io::ErrorKind::AddrNotAvailable, "nxdomain");
        match dns_error_to_ke(raw) {
            KeError::Io(e) => assert!(
                e.to_string().contains("nxdomain"),
                "Io passthrough lost diagnostic: {e}",
            ),
            other => panic!("AddrNotAvailable -> {other:?}; expected KeError::Io"),
        }
    }

    /// Companion to `dns_error_to_ke_translates_each_io_kind` for the
    /// per-address connect leg. `TimedOut` is the only deadline
    /// signal `TcpStream::connect_timeout` raises; non-timeout
    /// kinds (`ConnectionRefused`, `NetworkUnreachable`, …) must
    /// reach Dart as `NtsError::Network` with the diagnostic
    /// preserved.
    #[test]
    fn connect_error_to_ke_translates_io_kinds() {
        match connect_error_to_ke(std::io::Error::from(std::io::ErrorKind::TimedOut)) {
            KeError::PhaseTimeout(KeTimeoutPhase::Connect) => {}
            other => panic!("TimedOut -> {other:?}; expected Connect"),
        }
        let raw = std::io::Error::new(std::io::ErrorKind::ConnectionRefused, "ECONNREFUSED");
        match connect_error_to_ke(raw) {
            KeError::Io(e) => assert!(
                e.to_string().contains("ECONNREFUSED"),
                "Io passthrough lost diagnostic: {e}",
            ),
            other => panic!("ConnectionRefused -> {other:?}; expected KeError::Io"),
        }
    }

    /// Companion translator for the TLS / record I/O legs. A stalled
    /// rustls Stream surfaces `TimedOut`/`WouldBlock` from the
    /// underlying socket and must inherit the caller-supplied phase
    /// tag (`Tls` or `KeRecordIo`); other kinds stay as
    /// `KeError::Io` so a real I/O error doesn't get mislabelled as
    /// a budget exhaustion.
    #[test]
    fn phase_io_to_ke_translates_each_io_kind() {
        for phase in [KeTimeoutPhase::Tls, KeTimeoutPhase::KeRecordIo] {
            for kind in [std::io::ErrorKind::TimedOut, std::io::ErrorKind::WouldBlock] {
                let io = std::io::Error::from(kind);
                match phase_io_to_ke(io, phase) {
                    KeError::PhaseTimeout(got) => assert_eq!(got, phase),
                    other => panic!(
                        "{kind:?} for {phase:?} -> {other:?}; \
                         expected PhaseTimeout({phase:?})",
                    ),
                }
            }
            let raw = std::io::Error::new(std::io::ErrorKind::UnexpectedEof, "eof");
            match phase_io_to_ke(raw, phase) {
                KeError::Io(e) => assert!(e.to_string().contains("eof")),
                other => panic!("UnexpectedEof for {phase:?} -> {other:?}; expected Io"),
            }
        }
    }

    /// `Display for KeError` is the string the public API surfaces
    /// when a non-timeout shape escapes via `KeProtocol(format!("{e}"))`.
    /// The `PhaseTimeout` arm must include the phase tag verbatim
    /// so a log line still distinguishes "budget elapsed during
    /// connect" from "budget elapsed during TLS handshake".
    #[test]
    fn ke_error_display_renders_phase_timeout_with_phase_tag() {
        for phase in [
            KeTimeoutPhase::DnsSaturation,
            KeTimeoutPhase::DnsTimeout,
            KeTimeoutPhase::Connect,
            KeTimeoutPhase::Tls,
            KeTimeoutPhase::KeRecordIo,
        ] {
            let rendered = format!("{}", KeError::PhaseTimeout(phase));
            let tag = format!("{phase:?}");
            assert!(
                rendered.contains(&tag),
                "Display for PhaseTimeout({phase:?}) was {rendered:?}; \
                 expected to contain {tag:?}",
            );
        }
    }

    /// Companion to the `Deadline` unit tests: drives the same
    /// blackholed-IP scenario as
    /// `connect_with_timeout_respects_budget_for_unroutable_ip`,
    /// but through `connect_with_deadline_using` directly to prove the
    /// new entry point honours an externally-supplied deadline (the
    /// shape `perform_handshake` passes in). Without this, a future
    /// edit could accidentally regress the connect helper to use the
    /// caller's original duration on each iteration.
    #[test]
    fn connect_with_deadline_respects_external_deadline_for_unroutable_ip() {
        let budget = Duration::from_millis(500);
        let deadline = Some(Deadline::new(budget));
        let started = Instant::now();
        let result = connect_with_deadline_using(
            "192.0.2.1",
            4460,
            deadline,
            crate::nts::dns::DEFAULT_MAX_INFLIGHT_DNS_LOOKUPS,
            system_lookup,
        );
        let elapsed = started.elapsed();
        assert!(result.is_err(), "connecting to TEST-NET-1 must fail");
        let cap = Duration::from_secs(5);
        assert!(
            elapsed < cap,
            "connect_with_deadline_using took {elapsed:?} (> {cap:?}); \
             OS-default connect timeout is leaking through",
        );
    }

    /// Live integration probe against Cloudflare's public NTS-KE endpoint.
    ///
    /// Gated behind `--ignored` so the standard CI run never depends on the
    /// public network. Run manually with:
    ///   cargo test -p nts_rust nts::ke::tests::ke_live -- --ignored --nocapture
    #[test]
    #[ignore = "requires outbound TCP/4460 to time.cloudflare.com"]
    fn ke_live_cloudflare() {
        let req = KeRequest {
            host: "time.cloudflare.com".to_owned(),
            port: 4460,
            aead_algorithms: vec![aead::AES_SIV_CMAC_256],
            timeout: Some(Duration::from_secs(10)),
            dns_concurrency_cap: crate::nts::dns::DEFAULT_MAX_INFLIGHT_DNS_LOOKUPS,
            trust_mode: KeTrustMode::PlatformWithFallback,
        };
        let outcome = perform_handshake(&req).expect("handshake");
        assert_eq!(outcome.aead_id, aead::AES_SIV_CMAC_256);
        assert_eq!(outcome.c2s_key.len(), 32);
        assert_eq!(outcome.s2c_key.len(), 32);
        assert_ne!(outcome.c2s_key, outcome.s2c_key);
        assert!(
            outcome.cookies.len() >= 8,
            "expected ≥8 cookies, got {}",
            outcome.cookies.len()
        );
        assert!(outcome.ntpv4_port > 0);
    }
}

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
use zeroize::Zeroizing;

use super::records::{
    aead, parse_message, serialize_message, CodecError, ErrorCode, Record, RecordKind,
    WarningCode, NEXT_PROTO_NTPV4,
};

/// RFC 8915 §5.1 fixed exporter label.
const EXPORTER_LABEL: &[u8] = b"EXPORTER-network-time-security";

/// RFC 8915 §4.1.6 — default NTPv4 port when the server omits a Port record.
const DEFAULT_NTPV4_PORT: u16 = 123;

/// IANA "NTS Key Establishment" ALPN protocol identifier (RFC 8915 §4).
const ALPN_NTSKE: &[u8] = b"ntske/1";

/// Per-handshake streaming-read budget for the NTS-KE response. The
/// codec ([`super::records::parse_message`]) caps individual messages
/// at [`super::records::MAX_MESSAGE_BYTES`] (64 KiB, the RFC 8915
/// §4.1.4 upper bound for a *valid* message), but real NTS-KE
/// responses from public servers (Cloudflare, Netnod, NTS.net.nz) are
/// well under 1 KiB. A belt-and-braces deployment ceiling well below
/// the codec ceiling keeps a malicious or buggy server from forcing
/// the read accumulator in [`read_to_end_capped`] to grow toward the
/// 64 KiB limit on every failed handshake — 64 KiB × N concurrent
/// handshakes is a memory-pressure vector on a memory-constrained
/// mobile process. Comparable Rust NTS implementations cap the
/// streaming layer at 4 KiB
/// (`ntpd-rs::ntp-proto::nts::messages::MAX_MESSAGE_SIZE`); 16 KiB is
/// a more permissive ceiling that still rejects oversized responses
/// in the streaming layer before the codec sees them. The codec
/// ceiling stays at [`super::records::MAX_MESSAGE_BYTES`] because the
/// codec is also reachable from non-streaming entry points (tests,
/// file-based inputs) where the RFC's per-message bound is the right
/// cap.
pub const NTS_KE_READ_BUDGET: usize = 16_384;

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
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
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
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
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
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
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
///
/// `Debug` is implemented manually below to redact every field
/// that carries authentication material:
///
/// - `c2s_key` / `s2c_key` — raw AEAD exporter bytes.
///   `Zeroizing<Vec<u8>>`'s derived `Debug` delegates to
///   `Vec<u8>`'s `Debug` and would print the raw key bytes
///   verbatim.
/// - `cookies` — RFC 8915 §6 NTS cookies. The cookies are
///   server-encrypted blobs that authorise the client to request
///   AEAD-protected NTPv4 samples; an attacker who recovers them
///   can mint requests on the client's behalf without performing
///   a fresh KE handshake. Treated with the same redaction
///   discipline as the keys themselves.
///
/// Without the manual impl, anything that formats a `KeOutcome`
/// with `{:?}` (assertion-failure messages, panic payloads,
/// accidental log lines) would leak live key material and active
/// cookies. The non-secret fields (`ntpv4_host`, `ntpv4_port`,
/// `aead_id`, `warnings`, `phase_timings`, `trust_backend`) pass
/// through verbatim. The redaction pattern matches `SivKey` and
/// `Aes128GcmSivKey` in `aead.rs`, where manual `Debug` impls
/// render the wrapped fixed-size key arrays as `<redacted>`.
#[derive(Clone)]
pub struct KeOutcome {
    /// Server's chosen NTPv4 host (defaults to `request.host` when omitted).
    pub ntpv4_host: String,
    /// Server's chosen NTPv4 port (defaults to 123 when omitted).
    pub ntpv4_port: u16,
    /// AEAD algorithm IANA ID the server selected.
    pub aead_id: u16,
    /// Client-to-server AEAD key exported from the TLS session
    /// (RFC 8915 §5.1 EXPORTER label `EXPORTER-network-time-security`,
    /// context `0x0000 || aead_id || c2s_marker`). Wrapped in
    /// [`Zeroizing`] so the raw key bytes are wiped from RAM on
    /// `Drop` rather than lingering in the freed allocation; the
    /// wrapper transparently `Deref`s to `Vec<u8>` so existing
    /// callers (`AeadKey::from_keying_material(outcome.aead_id,
    /// &outcome.c2s_key)` in `crate::api::nts::establish_session`)
    /// continue to compile unchanged. Defends against memory-
    /// scraping attacks (cold-boot, swap inspection, post-process-
    /// crash core dumps); on mobile this matters because long-lived
    /// foreground processes get paged to disk under memory pressure.
    pub c2s_key: Zeroizing<Vec<u8>>,
    /// Server-to-client AEAD key exported from the TLS session.
    /// Same [`Zeroizing`] wrapper and rationale as `c2s_key`.
    pub s2c_key: Zeroizing<Vec<u8>>,
    /// Initial cookie pool delivered with the response.
    pub cookies: Vec<Vec<u8>>,
    /// Non-fatal warning codes (RFC 8915 §4.1.4 record type 3).
    /// Carried as the typed [`WarningCode`] so a future named-variant
    /// promotion (the IANA registry is empty as of RFC 8915) can land
    /// without changing every consumer's match shape; today every
    /// observed code rides through `WarningCode::Unknown(u16)` and the
    /// raw value is recoverable via `WarningCode::as_u16` / the
    /// `Display` rendering (bd nts-zqn).
    pub warnings: Vec<WarningCode>,
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

impl std::fmt::Debug for KeOutcome {
    /// Manual `Debug` that redacts both the `Zeroizing<Vec<u8>>`
    /// exporter keys and the `cookies` pool. Each redacted field
    /// renders as `<redacted; N {bytes,cookies}>` so the on-wire
    /// length stays observable for diagnostics without leaking the
    /// underlying material. Non-secret fields (`ntpv4_host`,
    /// `ntpv4_port`, `aead_id`, `warnings`, `phase_timings`,
    /// `trust_backend`) pass through verbatim. See the type-level
    /// rustdoc on [`KeOutcome`] for the threat model.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("KeOutcome")
            .field("ntpv4_host", &self.ntpv4_host)
            .field("ntpv4_port", &self.ntpv4_port)
            .field("aead_id", &self.aead_id)
            .field(
                "c2s_key",
                &format_args!("<redacted; {} bytes>", self.c2s_key.len()),
            )
            .field(
                "s2c_key",
                &format_args!("<redacted; {} bytes>", self.s2c_key.len()),
            )
            .field(
                "cookies",
                &format_args!("<redacted; {} cookies>", self.cookies.len()),
            )
            .field("warnings", &self.warnings)
            .field("phase_timings", &self.phase_timings)
            .field("trust_backend", &self.trust_backend)
            .finish()
    }
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
    /// Server returned an Error record (RFC 8915 §4.1.3 record type 2).
    /// The payload is the typed [`ErrorCode`] so the three IANA-
    /// registered codes (`UnrecognizedCriticalRecord`, `BadRequest`,
    /// `InternalServerError`) can be pattern-matched at the call site
    /// without re-parsing the raw `u16`; out-of-registry codes ride
    /// through `ErrorCode::Unknown(u16)` so the diagnostic preserves
    /// the server's choice (bd nts-zqn).
    ServerError(ErrorCode),
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
    /// RFC 8915 §4.1.2 — the NTS Next Protocol Negotiation record
    /// MUST appear exactly once in a server response. ntpd-rs
    /// rejects duplicates on the request side
    /// (`ntp-proto/src/nts/messages.rs::test_request_basic_reject_multiple`,
    /// v1.7.2); the same threat shape applies on the response side:
    /// silently picking the first-seen value (which `find_map`
    /// would do) would mask the violation and could let an on-path
    /// tamper inject a record the client would later honour.
    DuplicateNextProtocol,
    /// RFC 8915 §4.1.5 — the AEAD Algorithm Negotiation record
    /// MUST appear exactly once. Same rationale as
    /// `DuplicateNextProtocol`: silently taking the first-seen
    /// AEAD id would let a duplicate record (server bug or
    /// on-path tamper) downgrade the client to an algorithm it
    /// would otherwise reject.
    DuplicateAeadAlgorithm,
    /// Streaming-read accumulator in [`read_to_end_capped`] would
    /// exceed [`NTS_KE_READ_BUDGET`] if the next chunk were appended.
    /// `received` is the post-append length the offending read would
    /// have produced; `cap` is the budget that was tripped. Distinct
    /// from `Codec(CodecError::MessageTooLarge)` (which fires at the
    /// 64 KiB RFC ceiling, an order of magnitude higher) so callers
    /// can tell a streaming-layer DoS guard from a parser-level
    /// rejection of a genuinely oversized but valid-shaped message.
    /// Distinct from `PhaseTimeout(KeRecordIo)` so callers can tell
    /// server misbehaviour (sending too much) from network latency
    /// (sending too slowly).
    ResponseTooLarge {
        received: usize,
        cap: usize,
    },
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
    #[must_use]
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
            Self::DuplicateNextProtocol => f.write_str(
                "response contains more than one Next Protocol record (RFC 8915 §4.1.2)",
            ),
            Self::DuplicateAeadAlgorithm => f.write_str(
                "response contains more than one AEAD Algorithm record (RFC 8915 §4.1.5)",
            ),
            Self::ResponseTooLarge { received, cap } => write!(
                f,
                "NTS-KE response exceeded {cap}-byte streaming budget \
                 (next read would have produced {received} bytes)",
            ),
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

/// AEAD algorithms `establish_session` offers to the server in the
/// NTS-KE handshake, in order of preference.
///
/// **Cross-surface invariant** (pinned by
/// [`tests::offered_aead_ids_are_supported_end_to_end`]): every
/// entry here must satisfy
///
/// 1. [`aead_key_len`] returns `Some(n)` for the ID, AND
/// 2. `AeadKey::from_keying_material` (in `crate::nts::aead`)
///    constructs successfully when handed `n` bytes of keying
///    material.
///
/// A drift between this list and either of those two surfaces would
/// let `validate_response` accept a server-picked AEAD whose key the
/// downstream constructor cannot build. The actual surfacing path is
/// `establish_session` (in `rust/src/api/nts.rs`), which calls
/// `AeadKey::from_keying_material` after the KE handshake completes
/// and `map_err`s a constructor failure into
/// `NtsError::Internal("KE produced unusable C2S/S2C key: …")` —
/// confusing for the caller because the handshake itself succeeded.
/// The correct surfacing for a server-picked AEAD outside the
/// supported set is `KeError::UnsupportedAead(id)`, which the bd
/// invariant tests below pin.
///
/// `establish_session` (in `rust/src/api/nts.rs`) reads from this
/// constant rather than re-listing the IDs inline so that adding or
/// removing an offered AEAD is a single-site edit that the
/// invariant test catches at CI time if it leaves the three surfaces
/// out of step.
pub(crate) const OFFERED_AEAD_IDS: &[u16] = &[
    aead::AES_SIV_CMAC_256,
    aead::AES_128_GCM_SIV,
];

/// AEAD key length in octets per RFC 8915 §5.1 (SIV-CMAC family) and
/// RFC 8452 §4 (GCM-SIV).
///
/// Currently entries match exactly the IDs we both *offer* in the KE
/// handshake (see [`OFFERED_AEAD_IDS`]) and can *construct* in the
/// AEAD layer (`AeadKey::from_keying_material` in
/// `crate::nts::aead`). The 384- and 512-bit SIV-CMAC variants
/// (IANA IDs 16 and 17) are deliberately absent: although they are
/// valid IANA registry values and used by [`exporter_context`] for
/// context-string round-trips, the AEAD constructor does not
/// implement them, so listing them here would let `validate_response`
/// accept an offered AEAD that derivation immediately fails on. Any
/// future expansion must update all three surfaces
/// (`OFFERED_AEAD_IDS`, this table, and the AEAD constructor)
/// together; the invariant tests in this module fail otherwise.
fn aead_key_len(id: u16) -> Option<usize> {
    match id {
        aead::AES_SIV_CMAC_256 => Some(32),
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
    [0x00, 0x00, aead_be[0], aead_be[1], u8::from(s2c)]
}

/// Build the client request blob: NextProtocol(NTPv4), AeadAlgorithm(prefs), EOM.
///
/// All three records are critical (RFC 8915 §4.1.2 mandates NextProtocol
/// and §4.1.5 mandates AEAD Algorithm Negotiation as critical; we mark
/// EOM critical to match every reference implementation).
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
// `pub(crate)` so the `__internal_fuzz` re-export module in `lib.rs`
// (gated by the `__internal-fuzz` Cargo feature) can wrap this
// function for the cargo-fuzz harness in `rust/fuzz/`. The harness exposes
// only a thin shim that discards the `KeOutcomePartial` payload
// (which stays private), so widening from `fn` to `pub(crate)` does
// not enlarge the cross-module API surface for ordinary builds.
pub(crate) fn validate_response(
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
    // RFC 8915 §4.1.2 / §4.1.5: the NextProtocol and AEAD Algorithm
    // records MUST appear exactly once in a server response. Detect
    // duplicates before the `find_map` walks below — those would
    // otherwise silently take the first occurrence and mask the
    // violation, allowing a duplicate record (server bug or on-path
    // tamper) to seed a downgrade or other shape attack the typed
    // `Duplicate*` variants make visible to the caller.
    let mut np_seen = 0usize;
    let mut aead_seen = 0usize;
    for r in records {
        match &r.kind {
            RecordKind::NextProtocol(_) => np_seen += 1,
            RecordKind::AeadAlgorithm(_) => aead_seen += 1,
            _ => {}
        }
    }
    if np_seen > 1 {
        return Err(KeError::DuplicateNextProtocol);
    }
    if aead_seen > 1 {
        return Err(KeError::DuplicateAeadAlgorithm);
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

// `pub(crate)` so the `__internal_fuzz` validate_response shim in
// `lib.rs` can reference this in its return type. The fields stay
// private (no `pub` on any field) — only the type-name visibility
// changes, not the data exposure. The shim discards the value via
// `.map(|_| ())` so the harness never observes the contents.
#[derive(Debug)]
pub(crate) struct KeOutcomePartial {
    ntpv4_host: String,
    ntpv4_port: u16,
    aead_id: u16,
    cookies: Vec<Vec<u8>>,
    warnings: Vec<WarningCode>,
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
    match build_with_native_verifier_android(trust_mode) {
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
fn build_with_native_verifier_android(
    trust_mode: KeTrustMode,
) -> Result<
    (
        ClientConfig,
        Arc<crate::nts::hybrid_verifier::HybridVerifier>,
    ),
    rustls::Error,
> {
    use crate::nts::hybrid_verifier::HybridVerifier;
    let hybrid = Arc::new(HybridVerifier::new(trust_mode));
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
#[expect(
    clippy::too_many_lines,
    reason = "linear handshake driver: deadline construction, TLS config build, \
              TCP connect with deadline-threaded socket-timeout refresh, ALPN \
              selection, request-write/flush with deadline refresh, \
              read-to-end with budget-capped streaming, response parse, \
              `validate_response`, twice-called `export_keying_material` with \
              `Zeroizing` wrap, and `KeOutcome` assembly all need to live in a \
              single body so the deadline-threading and Zeroizing-wrap \
              invariants are visible at the call site rather than scattered \
              across helpers"
)]
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
    let attribute =
        |error: KeError| -> KeFailure { KeFailure::with_backend(error, Some(resolve_backend())) };

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

    let records = parse_message(&response)
        .map_err(KeError::from)
        .map_err(attribute)?;
    let partial =
        validate_response(&req.host, &req.aead_algorithms, &records).map_err(attribute)?;

    let key_len = aead_key_len(partial.aead_id).expect("validated above");
    let c2s_ctx = exporter_context(partial.aead_id, false);
    let s2c_ctx = exporter_context(partial.aead_id, true);
    // Wrap exporter outputs in `Zeroizing` immediately on receipt
    // from `export_keying_material` so the secret bytes are wiped
    // on `Drop` even if a downstream `?` short-circuits before the
    // `KeOutcome` is constructed. Without the wrap, an early return
    // between this point and the final `Ok(KeOutcome { ... })`
    // would leak the raw `Vec<u8>` allocation back to the heap with
    // the bytes still intact.
    let c2s_key = Zeroizing::new(
        conn.export_keying_material(vec![0u8; key_len], EXPORTER_LABEL, Some(&c2s_ctx))
            .map_err(KeError::from)
            .map_err(attribute)?,
    );
    let s2c_key = Zeroizing::new(
        conn.export_keying_material(vec![0u8; key_len], EXPORTER_LABEL, Some(&s2c_ctx))
            .map_err(KeError::from)
            .map_err(attribute)?,
    );

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
///
/// The accumulator is capped at [`NTS_KE_READ_BUDGET`] (16 KiB), an
/// order of magnitude below the codec's
/// [`super::records::MAX_MESSAGE_BYTES`] ceiling (64 KiB). A read
/// that would push the post-append length past the budget short-
/// circuits with [`KeError::ResponseTooLarge`] before the bytes are
/// appended, so a malicious or buggy server cannot force the per-
/// handshake heap allocation past 16 KiB regardless of how many
/// chunks it sends. The budget decision is factored into
/// [`next_chunk_within_budget`] for unit-test access without a TLS
/// stream.
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
                next_chunk_within_budget(buf.len(), n, NTS_KE_READ_BUDGET)?;
                buf.extend_from_slice(&chunk[..n]);
            }
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {}
            Err(e) => return Err(phase_io_to_ke(e, KeTimeoutPhase::KeRecordIo)),
        }
    }
}

/// Pure cap-budget decision extracted from [`read_to_end_capped`] so
/// the streaming-budget guard can be exercised by a unit test without
/// standing up a TLS stream. Returns `Ok(())` if appending `n` more
/// bytes to a buffer of length `buf_len` would keep the total at or
/// below `cap`; returns [`KeError::ResponseTooLarge`] otherwise, with
/// `received` set to the would-be post-append length so the caller
/// (and the operator looking at logs) can see how far over the budget
/// the offending read pushed the accumulator.
fn next_chunk_within_budget(buf_len: usize, n: usize, cap: usize) -> Result<(), KeError> {
    let received = buf_len + n;
    if received > cap {
        Err(KeError::ResponseTooLarge { received, cap })
    } else {
        Ok(())
    }
}

// Compile-time pin that the trust/timeout enums implement `Hash`.
// See the matching pin in `super::records` for rationale, including
// the `_`-prefix-vs-`#[expect]` choice for the const name.
const _ASSERT_HASH_DERIVES: fn() = || {
    fn requires_hash<T: std::hash::Hash>() {}
    requires_hash::<KeTrustMode>();
    requires_hash::<KeTrustBackend>();
    requires_hash::<KeTimeoutPhase>();
};

#[cfg(test)]
mod tests;

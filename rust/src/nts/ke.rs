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
    /// elapsed; the `From<KeError> for NtsError` mapping in
    /// `api/nts.rs` translates that to `NtsError::Timeout` rather than
    /// `NtsError::Network`. Re-applied between phases (post-connect,
    /// before each write/flush, and once per iteration of the chunked
    /// read loop) so a slow trickle from the server cannot extend the
    /// total wall-clock cost past `req.timeout`.
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
}

#[derive(Debug)]
pub enum KeError {
    Io(std::io::Error),
    Tls(rustls::Error),
    InvalidServerName,
    Codec(CodecError),
    /// Server returned an Error record (RFC 8915 §4.1.5 record type 2).
    ServerError(u16),
    /// A critical record we don't recognize was received (RFC 8915 §4.1.4).
    UnknownCritical(u16),
    MissingNextProtocol,
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

impl std::fmt::Display for KeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Io(e) => write!(f, "I/O error: {e}"),
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
///   AAR classes). See [`crate::nts::hybrid_verifier`].
/// - **Other platforms**: bare `rustls_platform_verifier::Verifier`,
///   constructed directly rather than via `ConfigVerifierExt` because
///   that helper hard-codes `with_safe_default_protocol_versions()`
///   which would re-admit TLS 1.2 if the `tls12` feature is on.
/// - **Hard fallback**: a static webpki-roots config, used only when
///   the verifier above fails to construct (the platform path is the
///   source of truth for the runtime trust decision).
fn build_tls_config() -> Result<Arc<ClientConfig>, KeError> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let mut cfg = match build_with_native_verifier() {
        Ok(c) => c,
        Err(_) => build_with_webpki_roots()?,
    };
    cfg.alpn_protocols = vec![ALPN_NTSKE.to_vec()];
    Ok(Arc::new(cfg))
}

#[cfg(target_os = "android")]
fn build_with_native_verifier() -> Result<ClientConfig, rustls::Error> {
    use crate::nts::hybrid_verifier::HybridVerifier;
    Ok(
        ClientConfig::builder_with_protocol_versions(TLS_PROTOCOL_VERSIONS)
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(HybridVerifier::new()))
            .with_no_client_auth(),
    )
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
/// the prior un-bounded behaviour for callers that opt out of timeout
/// enforcement entirely.
pub fn perform_handshake(req: &KeRequest) -> Result<KeOutcome, KeError> {
    if req.aead_algorithms.is_empty() {
        return Err(KeError::MissingAead);
    }
    let cfg = build_tls_config()?;
    let server_name = ServerName::try_from(req.host.as_str())
        .map_err(|_| KeError::InvalidServerName)?
        .to_owned();
    let mut conn = ClientConnection::new(cfg, server_name)?;

    let deadline = req.timeout.map(Deadline::new);
    let mut tcp = connect_with_deadline_using(
        req.host.as_str(),
        req.port,
        deadline,
        req.dns_concurrency_cap,
        system_lookup,
    )?;
    if let Some(d) = deadline.as_ref() {
        d.apply_to(&tcp)?;
    }

    let request = build_request(&req.aead_algorithms);
    let response = {
        let mut stream = Stream::new(&mut conn, &mut tcp);
        if let Some(d) = deadline.as_ref() {
            d.apply_to(stream.sock)?;
        }
        stream.write_all(&request)?;
        if let Some(d) = deadline.as_ref() {
            d.apply_to(stream.sock)?;
        }
        stream.flush()?;
        read_to_end_capped(&mut stream, deadline.as_ref())?
    };

    let records = parse_message(&response)?;
    let partial = validate_response(&req.host, &req.aead_algorithms, &records)?;

    let key_len = aead_key_len(partial.aead_id).expect("validated above");
    let c2s_ctx = exporter_context(partial.aead_id, false);
    let s2c_ctx = exporter_context(partial.aead_id, true);
    let c2s_key =
        conn.export_keying_material(vec![0u8; key_len], EXPORTER_LABEL, Some(&c2s_ctx))?;
    let s2c_key =
        conn.export_keying_material(vec![0u8; key_len], EXPORTER_LABEL, Some(&s2c_ctx))?;

    conn.send_close_notify();
    let _ = Stream::new(&mut conn, &mut tcp).flush();

    Ok(KeOutcome {
        ntpv4_host: partial.ntpv4_host,
        ntpv4_port: partial.ntpv4_port,
        aead_id: partial.aead_id,
        c2s_key,
        s2c_key,
        cookies: partial.cookies,
        warnings: partial.warnings,
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
fn connect_with_timeout(
    host: &str,
    port: u16,
    timeout: Option<Duration>,
) -> Result<TcpStream, KeError> {
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
fn connect_with_timeout_using<F>(
    host: &str,
    port: u16,
    timeout: Option<Duration>,
    dns_concurrency_cap: usize,
    lookup: F,
) -> Result<TcpStream, KeError>
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
fn connect_with_deadline_using<F>(
    host: &str,
    port: u16,
    deadline: Option<Deadline>,
    dns_concurrency_cap: usize,
    lookup: F,
) -> Result<TcpStream, KeError>
where
    F: FnOnce(&str, u16) -> std::io::Result<Vec<SocketAddr>> + Send + 'static,
{
    let Some(deadline) = deadline else {
        return Ok(TcpStream::connect((host, port))?);
    };
    let initial = deadline.remaining();
    if initial.is_zero() {
        return Err(KeError::Io(std::io::Error::new(
            std::io::ErrorKind::TimedOut,
            "NTS-KE deadline elapsed before DNS lookup",
        )));
    }
    // Bound the resolver by the live remaining budget rather than the
    // caller's original duration. A stalled getaddrinfo would otherwise
    // consume the entire budget before the first connect attempt could
    // even start.
    let addrs = resolve_with_global(host, port, initial, dns_concurrency_cap, lookup)?;
    let mut last_err: Option<std::io::Error> = None;
    for addr in addrs {
        let remaining = deadline.remaining();
        if remaining.is_zero() {
            return Err(KeError::Io(std::io::Error::new(
                std::io::ErrorKind::TimedOut,
                "connect timed out",
            )));
        }
        match TcpStream::connect_timeout(&addr, remaining) {
            Ok(s) => return Ok(s),
            Err(e) => last_err = Some(e),
        }
    }
    Err(KeError::Io(last_err.unwrap_or_else(|| {
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
/// the I/O timeout the caller configured.
///
/// When `deadline` is `Some`, the loop refreshes the underlying
/// `TcpStream`'s read/write timeouts before every `stream.read` call so
/// the budget shrinks per-iteration. Without this refresh,
/// `set_read_timeout` would re-arm a fresh `remaining` window for every
/// chunk and a slow trickle from the server could extend the total
/// wall-clock cost past the caller's `req.timeout`. A deadline already
/// expired before the next read is surfaced as `KeError::Io` with
/// `ErrorKind::TimedOut`.
fn read_to_end_capped(
    stream: &mut Stream<'_, ClientConnection, TcpStream>,
    deadline: Option<&Deadline>,
) -> Result<Vec<u8>, KeError> {
    let mut buf = Vec::with_capacity(4096);
    let mut chunk = [0u8; 4096];
    loop {
        if let Some(d) = deadline {
            d.apply_to(stream.sock)?;
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
            Err(e) => return Err(KeError::Io(e)),
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
        let cfg = build_tls_config().expect("config builds");
        assert_eq!(cfg.alpn_protocols, vec![ALPN_NTSKE.to_vec()]);
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
    /// itself fires, the resulting `io::Error` must carry
    /// `ErrorKind::TimedOut` so the `From<KeError> for NtsError`
    /// mapping in `api/nts.rs` produces `NtsError::Timeout` rather
    /// than `NtsError::Network`.
    #[test]
    fn connect_with_timeout_respects_budget_for_unroutable_ip() {
        let budget = Duration::from_millis(500);
        let started = Instant::now();
        let result = connect_with_timeout("192.0.2.1", 4460, Some(budget));
        let elapsed = started.elapsed();

        let err = result.expect_err("connecting to 192.0.2.1:4460 must fail");
        let KeError::Io(io) = err else {
            panic!("expected KeError::Io, got {err:?}");
        };

        // The cap is generous enough to absorb scheduling jitter on slow
        // CI runners while still being orders of magnitude tighter than
        // the OS-default connect timeout this code path replaces.
        let cap = Duration::from_secs(5);
        assert!(
            elapsed < cap,
            "connect took {elapsed:?} (> {cap:?}); OS-default connect \
             timeout is leaking through (io kind = {:?}, msg = {io})",
            io.kind(),
        );

        // When the deadline elapsed (rather than the OS rejecting
        // immediately), the kind must be TimedOut so downstream error
        // mapping produces NtsError::Timeout.
        if elapsed >= budget {
            assert_eq!(
                io.kind(),
                std::io::ErrorKind::TimedOut,
                "deadline elapsed after {elapsed:?} but io kind was \
                 {:?} ({io}); would surface as NtsError::Network",
                io.kind(),
            );
        }
    }

    /// Slow-DNS regression guard for [`connect_with_timeout`]. Injects a
    /// resolver that blocks past the budget and asserts the call returns
    /// a `KeError::Io` with `ErrorKind::TimedOut` well inside the cap.
    /// Pinning the kind here is what the `From<KeError> for NtsError`
    /// mapping in `api/nts.rs` relies on to surface stalled
    /// `getaddrinfo` as `NtsError::Timeout` rather than as a generic
    /// network error. Companion to `dns::tests::slow_resolver_*` and
    /// `api::nts::tests::bind_connected_udp_surfaces_slow_dns_*`; see
    /// `nts-6ka` for the full set of injection points.
    #[test]
    fn connect_with_timeout_surfaces_slow_dns_as_timed_out() {
        let budget = Duration::from_millis(50);
        let started = Instant::now();
        // Generous cap so this test stays isolated from any other
        // test in the suite that holds slots in the global resolver
        // pool. The test is pinning the slow-DNS → TimedOut mapping,
        // not the cap-exhaustion path (which has dedicated coverage in
        // `dns::tests::cap_reached_returns_would_block`).
        let result =
            connect_with_timeout_using("ignored.invalid", 0, Some(budget), 64, |_host, _port| {
                std::thread::sleep(Duration::from_secs(2));
                Ok(vec![SocketAddr::from(([127, 0, 0, 1], 0))])
            });
        let elapsed = started.elapsed();

        let err = result.expect_err("slow resolver must trip the deadline");
        let KeError::Io(io) = err else {
            panic!("expected KeError::Io, got {err:?}");
        };
        assert_eq!(
            io.kind(),
            std::io::ErrorKind::TimedOut,
            "slow-DNS path must surface as TimedOut, got {io:?}",
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

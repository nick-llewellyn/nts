//! NTS-KE handshake driver (RFC 8915 §4).
//!
//! Synchronous, single-threaded, no async runtime. The handshake is a
//! TCP connect → TLS 1.3 handshake (ALPN `ntske/1`) → exchange of two
//! short record blobs → TLS exporter call → close. The whole thing
//! finishes in well under a second on a healthy network and integrates
//! cleanly into the FRB v2 worker pool as a plain `pub fn`.

use std::io::{Read, Write};
use std::net::TcpStream;
use std::sync::Arc;
use std::time::Duration;

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
pub fn perform_handshake(req: &KeRequest) -> Result<KeOutcome, KeError> {
    if req.aead_algorithms.is_empty() {
        return Err(KeError::MissingAead);
    }
    let cfg = build_tls_config()?;
    let server_name = ServerName::try_from(req.host.as_str())
        .map_err(|_| KeError::InvalidServerName)?
        .to_owned();
    let mut conn = ClientConnection::new(cfg, server_name)?;

    let mut tcp = TcpStream::connect((req.host.as_str(), req.port))?;
    if let Some(t) = req.timeout {
        tcp.set_read_timeout(Some(t))?;
        tcp.set_write_timeout(Some(t))?;
    }

    let request = build_request(&req.aead_algorithms);
    let response = {
        let mut stream = Stream::new(&mut conn, &mut tcp);
        stream.write_all(&request)?;
        stream.flush()?;
        read_to_end_capped(&mut stream)?
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

/// Read until the peer closes the TLS stream or the cap is reached.
///
/// Servers terminate the NTS-KE message with a record-level End-of-Message
/// followed by a TLS `close_notify`; rustls surfaces that as a clean EOF on
/// the next read. A `WouldBlock` from the underlying TCP socket is mapped to
/// the I/O timeout the caller configured.
fn read_to_end_capped<S: Read>(stream: &mut S) -> Result<Vec<u8>, KeError> {
    let mut buf = Vec::with_capacity(4096);
    let mut chunk = [0u8; 4096];
    loop {
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

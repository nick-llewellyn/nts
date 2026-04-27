//! NTPv4 wire codec with NTS extension fields (RFC 5905, RFC 7822, RFC 8915 §5).
//!
//! The codec is symmetric: `build_client_request` produces an authenticated
//! NTPv4 packet using the C2S key from NTS-KE, and `parse_server_response`
//! verifies the corresponding S2C-authenticated reply and recovers any fresh
//! NTS cookies the server included in the encrypted extension fields.
//!
//! All randomness (Unique Identifier, Authenticator Nonce) is supplied by the
//! caller; this module is free of `getrandom`/`rand` dependencies and stays
//! deterministic for unit tests.

use super::aead::{AeadError, AeadKey, TAG_LEN};

/// Length of the fixed NTPv4 header preceding any extensions (RFC 5905 §7.3).
pub const HEADER_LEN: usize = 48;

/// RFC 7822 §7.5 minimum extension-field length (header + padded body).
pub const EXT_MIN_TOTAL: usize = 16;

/// RFC 5905 §7.3 extension-field header length (Field Type + Length).
pub const EXT_HEADER_LEN: usize = 4;

/// IANA "NTPv4 Extension Field Types" registry (RFC 8915 §7.3-§7.4).
pub mod ext_type {
    pub const UNIQUE_IDENTIFIER: u16 = 0x0104;
    pub const NTS_COOKIE: u16 = 0x0204;
    pub const NTS_COOKIE_PLACEHOLDER: u16 = 0x0304;
    pub const NTS_AUTHENTICATOR: u16 = 0x0404;
}

/// `LI(2) | VN(3) | Mode(3)` — see RFC 5905 §7.3.
pub mod mode {
    pub const CLIENT: u8 = 3;
    pub const SERVER: u8 = 4;
}

/// RFC 5905 — current NTP version and the only one NTS targets.
pub const VERSION_4: u8 = 4;

/// `LI=0, VN=4, Mode=3` for an unsynchronized client request (`0x23`).
pub const LI_VN_MODE_CLIENT: u8 = (VERSION_4 << 3) | mode::CLIENT;

/// Leap Indicator value `11` — server clock is unsynchronized / in an alarm
/// condition (RFC 5905 §7.3). A reply carrying this LI conveys no usable
/// time and must be rejected before it reaches the caller.
pub const LI_UNSYNCHRONIZED: u8 = 3;

/// Stratum value reserved for Kiss-o'-Death packets (RFC 5905 §7.4). When the
/// stratum field is `0`, `reference_id` carries a 4-octet ASCII kiss code
/// (e.g. `RATE`, `DENY`, `RSTR`, `NTSN`) describing why the server is
/// refusing service.
pub const STRATUM_KISS_OF_DEATH: u8 = 0;

/// First stratum value RFC 5905 §7.3 marks as "unsynchronized" (`16`) or
/// "reserved" (`17`–`255`). A reply carrying any of these conveys no usable
/// time regardless of the Leap Indicator and must be rejected.
pub const STRATUM_UNSYNCHRONIZED_FLOOR: u8 = 16;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NtpHeader {
    pub li_vn_mode: u8,
    pub stratum: u8,
    pub poll: i8,
    pub precision: i8,
    pub root_delay: u32,
    pub root_dispersion: u32,
    pub reference_id: [u8; 4],
    pub reference_timestamp: u64,
    pub origin_timestamp: u64,
    pub receive_timestamp: u64,
    pub transmit_timestamp: u64,
}

impl NtpHeader {
    /// Build a zeroed client-request header carrying just the transmit timestamp.
    pub fn client_request(transmit_timestamp: u64) -> Self {
        Self {
            li_vn_mode: LI_VN_MODE_CLIENT,
            stratum: 0,
            poll: 0,
            precision: 0,
            root_delay: 0,
            root_dispersion: 0,
            reference_id: [0; 4],
            reference_timestamp: 0,
            origin_timestamp: 0,
            receive_timestamp: 0,
            transmit_timestamp,
        }
    }

    pub fn version(&self) -> u8 {
        (self.li_vn_mode >> 3) & 0x07
    }

    pub fn mode(&self) -> u8 {
        self.li_vn_mode & 0x07
    }

    /// Two-bit Leap Indicator field (RFC 5905 §7.3). Value `3` means the
    /// server's clock is unsynchronized; values `0`–`2` describe known
    /// upcoming leap-second adjustments.
    pub fn leap(&self) -> u8 {
        (self.li_vn_mode >> 6) & 0x03
    }

    pub fn to_bytes(&self) -> [u8; HEADER_LEN] {
        let mut b = [0u8; HEADER_LEN];
        b[0] = self.li_vn_mode;
        b[1] = self.stratum;
        b[2] = self.poll as u8;
        b[3] = self.precision as u8;
        b[4..8].copy_from_slice(&self.root_delay.to_be_bytes());
        b[8..12].copy_from_slice(&self.root_dispersion.to_be_bytes());
        b[12..16].copy_from_slice(&self.reference_id);
        b[16..24].copy_from_slice(&self.reference_timestamp.to_be_bytes());
        b[24..32].copy_from_slice(&self.origin_timestamp.to_be_bytes());
        b[32..40].copy_from_slice(&self.receive_timestamp.to_be_bytes());
        b[40..48].copy_from_slice(&self.transmit_timestamp.to_be_bytes());
        b
    }

    pub fn from_bytes(b: &[u8; HEADER_LEN]) -> Self {
        Self {
            li_vn_mode: b[0],
            stratum: b[1],
            poll: b[2] as i8,
            precision: b[3] as i8,
            root_delay: u32::from_be_bytes([b[4], b[5], b[6], b[7]]),
            root_dispersion: u32::from_be_bytes([b[8], b[9], b[10], b[11]]),
            reference_id: [b[12], b[13], b[14], b[15]],
            reference_timestamp: u64::from_be_bytes(b[16..24].try_into().unwrap()),
            origin_timestamp: u64::from_be_bytes(b[24..32].try_into().unwrap()),
            receive_timestamp: u64::from_be_bytes(b[32..40].try_into().unwrap()),
            transmit_timestamp: u64::from_be_bytes(b[40..48].try_into().unwrap()),
        }
    }
}

#[derive(Debug)]
pub enum NtpError {
    PacketTooShort,
    TruncatedExtension,
    InvalidExtensionLength,
    UnexpectedMode { actual: u8 },
    UnexpectedVersion { actual: u8 },
    MissingUniqueIdentifier,
    UniqueIdentifierMismatch,
    MissingAuthenticator,
    AuthenticatorNotLast,
    MalformedAuthenticator,
    EmptyNonce,
    /// Server's `origin_timestamp` did not echo the client's `transmit_timestamp`.
    /// Defense-in-depth replay guard layered on top of the AEAD (RFC 5905 §8).
    OriginTimestampMismatch { expected: u64, actual: u64 },
    /// Server-attested "no usable time" signal: either Leap Indicator
    /// `11` (alarm condition, RFC 5905 §7.3) or a stratum at or above
    /// [`STRATUM_UNSYNCHRONIZED_FLOOR`] (`16` = unsynchronized,
    /// `17`–`255` reserved). Both conditions collapse into this
    /// variant because they carry identical semantics for the caller:
    /// the packet may be AEAD-authentic but the sample must be
    /// dropped rather than fed to the clock discipline.
    Unsynchronized,
    /// Server returned a Kiss-o'-Death packet (RFC 5905 §7.4): stratum `0`
    /// with a 4-octet ASCII kiss code in `reference_id`. Common codes are
    /// `RATE` (rate-limited), `DENY` (access denied), `RSTR` (restricted),
    /// and the NTS-specific `NTSN` (cookie not recognised, RFC 8915 §5.7).
    KissOfDeath(String),
    Aead(AeadError),
}

impl std::fmt::Display for NtpError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::PacketTooShort => f.write_str("NTP packet shorter than 48-byte header"),
            Self::TruncatedExtension => f.write_str("extension field truncated"),
            Self::InvalidExtensionLength => f.write_str("extension field length invalid"),
            Self::UnexpectedMode { actual } => write!(f, "unexpected NTP mode {actual}"),
            Self::UnexpectedVersion { actual } => write!(f, "unexpected NTP version {actual}"),
            Self::MissingUniqueIdentifier => f.write_str("response lacks Unique Identifier"),
            Self::UniqueIdentifierMismatch => f.write_str("Unique Identifier did not echo request"),
            Self::MissingAuthenticator => f.write_str("response lacks Authenticator extension"),
            Self::AuthenticatorNotLast => f.write_str("Authenticator must be last extension"),
            Self::MalformedAuthenticator => f.write_str("Authenticator body malformed"),
            Self::EmptyNonce => f.write_str("nonce must be non-empty"),
            Self::OriginTimestampMismatch { expected, actual } => write!(
                f,
                "origin timestamp {actual:#018x} did not echo client transmit {expected:#018x}",
            ),
            Self::Unsynchronized => {
                f.write_str("server reports unsynchronized clock (LI=3 or stratum >= 16)")
            }
            Self::KissOfDeath(code) => write!(f, "kiss-o'-death: {code}"),
            Self::Aead(e) => write!(f, "AEAD: {e}"),
        }
    }
}

impl std::error::Error for NtpError {}

impl From<AeadError> for NtpError {
    fn from(e: AeadError) -> Self {
        Self::Aead(e)
    }
}

/// Encode a single extension field: `field_type || total_len || body || zero-pad`.
///
/// `total_len` is the on-wire length including the 4-byte header. The output
/// satisfies RFC 7822 §7.5 (multiple of 4 octets, ≥ 16 octets).
pub fn encode_extension(field_type: u16, body: &[u8]) -> Vec<u8> {
    let raw_total = EXT_HEADER_LEN + body.len();
    let aligned = raw_total.div_ceil(4) * 4;
    let total = aligned.max(EXT_MIN_TOTAL);
    let mut out = Vec::with_capacity(total);
    out.extend_from_slice(&field_type.to_be_bytes());
    out.extend_from_slice(&(total as u16).to_be_bytes());
    out.extend_from_slice(body);
    out.resize(total, 0);
    out
}

/// A single decoded extension field. `body` includes any zero padding bytes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RawExt {
    pub field_type: u16,
    pub body: Vec<u8>,
}

/// Parse a sequence of NTPv4 extension fields starting at `bytes[0]`.
///
/// Each header is validated (`length` must be a multiple of 4, ≥ 16, and within
/// remaining bytes). The decoded `body` includes whatever padding was on the
/// wire — the caller decides how to interpret it per extension type.
pub fn parse_extensions(bytes: &[u8]) -> Result<Vec<RawExt>, NtpError> {
    let mut out = Vec::new();
    let mut pos = 0usize;
    while pos < bytes.len() {
        if bytes.len() - pos < EXT_HEADER_LEN {
            return Err(NtpError::TruncatedExtension);
        }
        let ft = u16::from_be_bytes([bytes[pos], bytes[pos + 1]]);
        let len = u16::from_be_bytes([bytes[pos + 2], bytes[pos + 3]]) as usize;
        if len < EXT_MIN_TOTAL || !len.is_multiple_of(4) || pos + len > bytes.len() {
            return Err(NtpError::InvalidExtensionLength);
        }
        let body = bytes[pos + EXT_HEADER_LEN..pos + len].to_vec();
        out.push(RawExt { field_type: ft, body });
        pos += len;
    }
    Ok(out)
}

/// Encode an NTS Authenticator extension body (RFC 8915 §5.6).
///
/// Layout: `nonce_len (2) || ct_len (2) || nonce || nonce_pad || ciphertext ||
/// ct_pad || additional_pad`. All padded sections align on a 4-byte boundary.
pub fn encode_authenticator_body(
    nonce: &[u8],
    ciphertext: &[u8],
    additional_padding: usize,
) -> Result<Vec<u8>, NtpError> {
    if nonce.is_empty() {
        return Err(NtpError::EmptyNonce);
    }
    let nonce_padded = nonce.len().div_ceil(4) * 4;
    let ct_padded = ciphertext.len().div_ceil(4) * 4;
    let extra_padded = additional_padding.div_ceil(4) * 4;
    let total = 4 + nonce_padded + ct_padded + extra_padded;
    let mut out = Vec::with_capacity(total);
    out.extend_from_slice(&(nonce.len() as u16).to_be_bytes());
    out.extend_from_slice(&(ciphertext.len() as u16).to_be_bytes());
    out.extend_from_slice(nonce);
    out.resize(4 + nonce_padded, 0);
    out.extend_from_slice(ciphertext);
    out.resize(4 + nonce_padded + ct_padded, 0);
    out.resize(total, 0);
    Ok(out)
}

/// Decoded NTS Authenticator body — borrows nonce and ciphertext from `body`.
#[derive(Debug, Clone)]
pub struct AuthenticatorBody<'a> {
    pub nonce: &'a [u8],
    pub ciphertext: &'a [u8],
}

/// Parse an NTS Authenticator body. Validates the four-byte length prefix and
/// confirms the announced sizes fit within the extension's body.
pub fn parse_authenticator_body(body: &[u8]) -> Result<AuthenticatorBody<'_>, NtpError> {
    if body.len() < 4 {
        return Err(NtpError::MalformedAuthenticator);
    }
    let nonce_len = u16::from_be_bytes([body[0], body[1]]) as usize;
    let ct_len = u16::from_be_bytes([body[2], body[3]]) as usize;
    if nonce_len == 0 {
        return Err(NtpError::EmptyNonce);
    }
    let nonce_padded = nonce_len.div_ceil(4) * 4;
    let ct_padded = ct_len.div_ceil(4) * 4;
    let consumed = 4 + nonce_padded + ct_padded;
    if consumed > body.len() {
        return Err(NtpError::MalformedAuthenticator);
    }
    let nonce = &body[4..4 + nonce_len];
    let ct_start = 4 + nonce_padded;
    let ciphertext = &body[ct_start..ct_start + ct_len];
    Ok(AuthenticatorBody { nonce, ciphertext })
}


/// Inputs for [`build_client_request`]. All randomness is supplied by the
/// caller; the api layer threads the OS RNG through in phase 3.
#[derive(Debug, Clone)]
pub struct ClientRequest {
    /// Per-packet identifier (RFC 8915 §5.3); 32 octets is the canonical size.
    pub unique_id: Vec<u8>,
    /// One cookie value spent for this packet (RFC 8915 §5.4).
    pub cookie: Vec<u8>,
    /// Number of NTS Cookie Placeholder fields requesting extra cookies in the reply.
    pub placeholder_count: usize,
    /// SIV nonce; `RECOMMENDED_NONCE_LEN` octets matches the high-level Aead trait.
    pub nonce: Vec<u8>,
    /// Client transmit timestamp (NTP 64-bit short format).
    pub transmit_timestamp: u64,
}

/// Build a fully-authenticated NTPv4 client request packet.
///
/// Returns the on-wire packet bytes. The caller MUST retain `unique_id` to
/// match the server's reply and the AEAD machinery validates that the entire
/// packet body (header + extensions before the Authenticator) is authenticated.
///
/// `c2s_key` selects the AEAD algorithm: SIV-CMAC-256 emits a 16-byte
/// authenticator tag (empty plaintext, RFC 8915 §5.6); GCM-SIV emits a
/// 16-byte tag too (the GCM-SIV tag length, RFC 8452).
pub fn build_client_request(req: &ClientRequest, c2s_key: &AeadKey) -> Result<Vec<u8>, NtpError> {
    if req.unique_id.is_empty() {
        return Err(NtpError::MissingUniqueIdentifier);
    }
    if req.nonce.is_empty() {
        return Err(NtpError::EmptyNonce);
    }
    let header = NtpHeader::client_request(req.transmit_timestamp);
    let mut packet = Vec::with_capacity(HEADER_LEN + 256);
    packet.extend_from_slice(&header.to_bytes());
    packet.extend_from_slice(&encode_extension(ext_type::UNIQUE_IDENTIFIER, &req.unique_id));
    packet.extend_from_slice(&encode_extension(ext_type::NTS_COOKIE, &req.cookie));
    let placeholder_body = vec![0u8; req.cookie.len()];
    for _ in 0..req.placeholder_count {
        packet.extend_from_slice(&encode_extension(
            ext_type::NTS_COOKIE_PLACEHOLDER,
            &placeholder_body,
        ));
    }
    let aad: &[u8] = &packet;
    let sealed = c2s_key.seal_packet(aad, &req.nonce, &[])?;
    debug_assert_eq!(sealed.len(), TAG_LEN);
    let auth_body = encode_authenticator_body(&req.nonce, &sealed, 0)?;
    packet.extend_from_slice(&encode_extension(ext_type::NTS_AUTHENTICATOR, &auth_body));
    Ok(packet)
}

/// Successfully verified server reply.
#[derive(Debug, Clone)]
pub struct ServerResponse {
    pub header: NtpHeader,
    pub unique_id: Vec<u8>,
    /// Fresh NTS cookies recovered from the encrypted extension fields.
    pub fresh_cookies: Vec<Vec<u8>>,
}

/// Parse and authenticate a server reply against the request's `expected_uid`
/// and `expected_origin_timestamp`.
///
/// On success returns the timestamps along with any fresh cookies the server
/// shipped inside the Authenticator's encrypted plaintext. AEAD failures map
/// to [`NtpError::Aead`]; unique-id and origin-timestamp mismatches are
/// reported separately so the caller can distinguish replay/splice attempts
/// from tampered packets.
///
/// The origin-timestamp check is layered on top of the AEAD per RFC 5905 §8:
/// the AEAD already covers the header, so a mismatch here implies the server
/// itself signed a stale or otherwise wrong reply (e.g. a replay where the
/// adversary recovered the S2C key from another session).
pub fn parse_server_response(
    bytes: &[u8],
    expected_uid: &[u8],
    expected_origin_timestamp: u64,
    s2c_key: &AeadKey,
) -> Result<ServerResponse, NtpError> {
    if bytes.len() < HEADER_LEN {
        return Err(NtpError::PacketTooShort);
    }
    let header_bytes: &[u8; HEADER_LEN] =
        bytes[..HEADER_LEN].try_into().expect("checked above");
    let header = NtpHeader::from_bytes(header_bytes);
    if header.version() != VERSION_4 {
        return Err(NtpError::UnexpectedVersion { actual: header.version() });
    }
    if header.mode() != mode::SERVER {
        return Err(NtpError::UnexpectedMode { actual: header.mode() });
    }

    let extensions = parse_extensions(&bytes[HEADER_LEN..])?;
    let auth_idx = extensions
        .iter()
        .position(|ext| ext.field_type == ext_type::NTS_AUTHENTICATOR)
        .ok_or(NtpError::MissingAuthenticator)?;
    if auth_idx + 1 != extensions.len() {
        return Err(NtpError::AuthenticatorNotLast);
    }

    let unique_id = extensions
        .iter()
        .find(|ext| ext.field_type == ext_type::UNIQUE_IDENTIFIER)
        .ok_or(NtpError::MissingUniqueIdentifier)?
        .body
        .clone();
    if unique_id != expected_uid {
        return Err(NtpError::UniqueIdentifierMismatch);
    }

    let auth_body = parse_authenticator_body(&extensions[auth_idx].body)?;
    let aad_end = HEADER_LEN
        + extensions[..auth_idx]
            .iter()
            .map(|ext| EXT_HEADER_LEN + ext.body.len())
            .sum::<usize>();
    let aad = &bytes[..aad_end];
    let plaintext = s2c_key.open_packet(aad, auth_body.nonce, auth_body.ciphertext)?;

    if header.origin_timestamp != expected_origin_timestamp {
        return Err(NtpError::OriginTimestampMismatch {
            expected: expected_origin_timestamp,
            actual: header.origin_timestamp,
        });
    }

    // Reject Stratum = 0 (Kiss-o'-Death) and Leap Indicator = 3 (alarm /
    // unsynchronized) only after the AEAD has cleared. RFC 8915 §5.7 is
    // explicit: "NTS clients MUST verify the AEAD authenticator on KoD
    // packets before acting on them." Otherwise an off-path attacker
    // could spoof a `DENY` or unsync state and trick the client into
    // discarding a healthy server. Both checks read header fields that
    // are part of the AAD, so by this point they are server-attested.
    //
    // Order matters: KoD packets routinely ship with LI=3 because a
    // server that is refusing service has no synchronised time to
    // advertise (RFC 5905 §7.4). Checking stratum first preserves the
    // 4-octet kiss code (`RATE`, `DENY`, `RSTR`, `NTSN`, …) for
    // diagnostics and back-off logic; the inverse order would collapse
    // every authenticated KoD into the generic `Unsynchronized` arm
    // and silently drop that information.
    if header.stratum == STRATUM_KISS_OF_DEATH {
        // RFC 5905 §7.4: kiss codes are 4 ASCII octets carried verbatim
        // in `reference_id`. `from_utf8_lossy` keeps the standard codes
        // intact while preserving diagnostic value if a server ships
        // non-printable bytes.
        let code = String::from_utf8_lossy(&header.reference_id).into_owned();
        return Err(NtpError::KissOfDeath(code));
    }
    // Anything from stratum 16 upward is server-attested "no usable
    // time": RFC 5905 §7.3 reserves `16` for explicit unsynchronized
    // state and `17`–`255` for future use. Folded into the same arm
    // as LI=3 because both signals carry identical semantics for the
    // caller (drop the sample; do not feed an offset to the clock
    // discipline). The stratum check is paired with the LI check
    // rather than the KoD arm so that an authenticated `RATE`/`DENY`
    // at stratum 0 still surfaces with its kiss code intact.
    if header.leap() == LI_UNSYNCHRONIZED || header.stratum >= STRATUM_UNSYNCHRONIZED_FLOOR {
        return Err(NtpError::Unsynchronized);
    }

    let encrypted_exts = parse_extensions(&plaintext)?;
    let fresh_cookies = encrypted_exts
        .into_iter()
        .filter(|ext| ext.field_type == ext_type::NTS_COOKIE)
        .map(|ext| ext.body)
        .collect();

    Ok(ServerResponse { header, unique_id, fresh_cookies })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::nts::aead::{AeadKey, NONCE_LEN_GCM_SIV, RECOMMENDED_NONCE_LEN};

    const C2S: [u8; 32] = [0x11; 32];
    const S2C: [u8; 32] = [0x22; 32];
    const UID: [u8; 32] = [0x33; 32];
    const NONCE: [u8; RECOMMENDED_NONCE_LEN] = [0x44; RECOMMENDED_NONCE_LEN];
    const COOKIE: &[u8] = &[0x55; 64];
    /// Canned client `transmit_timestamp` mirrored back as the server's
    /// `origin_timestamp` in [`craft_response`].
    const CLIENT_TX: u64 = 0xDEAD_BEEF_CAFE_F00D;

    fn fresh_keys() -> (AeadKey, AeadKey) {
        (
            AeadKey::from_keying_material(15, &C2S).unwrap(),
            AeadKey::from_keying_material(15, &S2C).unwrap(),
        )
    }

    fn sample_request() -> ClientRequest {
        ClientRequest {
            unique_id: UID.to_vec(),
            cookie: COOKIE.to_vec(),
            placeholder_count: 0,
            nonce: NONCE.to_vec(),
            transmit_timestamp: CLIENT_TX,
        }
    }

    /// Assemble a synthetic server reply mirroring what an honest NTS server
    /// would send: header(mode=server) + UID + NewCookie extensions wrapped in
    /// an Authenticator extension sealed with the S2C key. Works for any
    /// AEAD by sizing the wire nonce from `s2c.nonce_len()`.
    fn craft_response(uid: &[u8], fresh_cookies: &[&[u8]], s2c: &AeadKey) -> Vec<u8> {
        craft_response_with(uid, fresh_cookies, s2c, |_| {})
    }

    /// Same as [`craft_response`] but lets the test mutate the header
    /// after the canonical fields are populated and *before* the AEAD
    /// seals it. Required to exercise post-AEAD validation paths
    /// (Stratum-0 KoD, LI=3 alarm) under a wire-correct, authentic
    /// packet — anything that mutates the header *after* sealing would
    /// trip the AAD check and surface as an `Aead` error instead.
    fn craft_response_with(
        uid: &[u8],
        fresh_cookies: &[&[u8]],
        s2c: &AeadKey,
        tweak: impl FnOnce(&mut NtpHeader),
    ) -> Vec<u8> {
        let mut header = NtpHeader::client_request(0xCAFE_BABE_1234_5678);
        header.li_vn_mode = (VERSION_4 << 3) | mode::SERVER;
        header.stratum = 1;
        header.receive_timestamp = 0xCAFE_BABE_1234_0000;
        header.transmit_timestamp = 0xCAFE_BABE_1234_5678;
        header.origin_timestamp = CLIENT_TX;
        tweak(&mut header);
        let mut packet = Vec::new();
        packet.extend_from_slice(&header.to_bytes());
        packet.extend_from_slice(&encode_extension(ext_type::UNIQUE_IDENTIFIER, uid));
        let mut plaintext = Vec::new();
        for c in fresh_cookies {
            plaintext.extend_from_slice(&encode_extension(ext_type::NTS_COOKIE, c));
        }
        let nonce = vec![0x66u8; s2c.nonce_len()];
        let sealed = s2c.seal_packet(&packet, &nonce, &plaintext).unwrap();
        let auth_body = encode_authenticator_body(&nonce, &sealed, 0).unwrap();
        packet.extend_from_slice(&encode_extension(ext_type::NTS_AUTHENTICATOR, &auth_body));
        packet
    }

    #[test]
    fn header_round_trips() {
        let h = NtpHeader {
            li_vn_mode: 0x24,
            stratum: 2,
            poll: 6,
            precision: -20,
            root_delay: 0x0001_2345,
            root_dispersion: 0x0000_ABCD,
            reference_id: *b"GPS\0",
            reference_timestamp: 1,
            origin_timestamp: 2,
            receive_timestamp: 3,
            transmit_timestamp: 4,
        };
        let bytes = h.to_bytes();
        assert_eq!(NtpHeader::from_bytes(&bytes), h);
    }

    #[test]
    fn client_header_has_canonical_li_vn_mode() {
        let h = NtpHeader::client_request(123);
        assert_eq!(h.li_vn_mode, 0x23);
        assert_eq!(h.version(), 4);
        assert_eq!(h.mode(), mode::CLIENT);
    }

    #[test]
    fn encode_extension_meets_rfc_7822_minimum() {
        let bytes = encode_extension(0x0104, &[1, 2, 3, 4]);
        assert_eq!(bytes.len(), EXT_MIN_TOTAL);
        assert_eq!(&bytes[..2], &[0x01, 0x04]);
        assert_eq!(&bytes[2..4], &[0x00, 0x10]);
        assert_eq!(&bytes[4..8], &[1, 2, 3, 4]);
        assert_eq!(&bytes[8..], &[0; 8]);
    }

    #[test]
    fn encode_extension_aligns_to_four_bytes() {
        let body: Vec<u8> = (0..21).collect();
        let bytes = encode_extension(0x0204, &body);
        assert_eq!(bytes.len() % 4, 0);
        assert_eq!(bytes.len(), 28);
        assert_eq!(u16::from_be_bytes([bytes[2], bytes[3]]) as usize, 28);
    }

    #[test]
    fn parse_extensions_rejects_unaligned_length() {
        let mut bytes = vec![0x01, 0x04, 0x00, 0x11];
        bytes.extend_from_slice(&[0u8; 13]);
        match parse_extensions(&bytes) {
            Err(NtpError::InvalidExtensionLength) => {}
            other => panic!("expected InvalidExtensionLength, got {other:?}"),
        }
    }

    #[test]
    fn parse_extensions_rejects_below_minimum() {
        let bytes = vec![0x01, 0x04, 0x00, 0x0C, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8];
        match parse_extensions(&bytes) {
            Err(NtpError::InvalidExtensionLength) => {}
            other => panic!("expected InvalidExtensionLength, got {other:?}"),
        }
    }

    #[test]
    fn parse_extensions_rejects_overflow() {
        let bytes = vec![0x01, 0x04, 0x00, 0x18, 0u8, 0u8, 0u8, 0u8];
        match parse_extensions(&bytes) {
            Err(NtpError::InvalidExtensionLength) => {}
            other => panic!("expected InvalidExtensionLength, got {other:?}"),
        }
    }

    #[test]
    fn authenticator_body_round_trips() {
        let nonce = [0x77u8; 16];
        let ct = [0x88u8; 32];
        let body = encode_authenticator_body(&nonce, &ct, 4).unwrap();
        assert_eq!(body.len() % 4, 0);
        let parsed = parse_authenticator_body(&body).unwrap();
        assert_eq!(parsed.nonce, nonce);
        assert_eq!(parsed.ciphertext, ct);
    }

    #[test]
    fn build_request_emits_well_formed_packet() {
        let (c2s, _) = fresh_keys();
        let req = sample_request();
        let packet = build_client_request(&req, &c2s).unwrap();
        assert!(packet.len() > HEADER_LEN);
        assert_eq!(packet[0], LI_VN_MODE_CLIENT);
        let exts = parse_extensions(&packet[HEADER_LEN..]).unwrap();
        assert_eq!(exts.len(), 3);
        assert_eq!(exts[0].field_type, ext_type::UNIQUE_IDENTIFIER);
        assert_eq!(exts[1].field_type, ext_type::NTS_COOKIE);
        assert_eq!(exts[2].field_type, ext_type::NTS_AUTHENTICATOR);
        assert_eq!(exts[0].body, UID);
        assert_eq!(exts[1].body, COOKIE);
    }

    #[test]
    fn build_request_includes_placeholders() {
        let (c2s, _) = fresh_keys();
        let mut req = sample_request();
        req.placeholder_count = 4;
        let packet = build_client_request(&req, &c2s).unwrap();
        let exts = parse_extensions(&packet[HEADER_LEN..]).unwrap();
        // 1 UID + 1 Cookie + 4 Placeholder + 1 Authenticator = 7
        assert_eq!(exts.len(), 7);
        for ext in &exts[2..6] {
            assert_eq!(ext.field_type, ext_type::NTS_COOKIE_PLACEHOLDER);
            assert_eq!(ext.body.len(), COOKIE.len());
        }
    }

    #[test]
    fn parse_response_recovers_fresh_cookies() {
        let (_, s2c) = fresh_keys();
        let cookies: &[&[u8]] = &[&[0xAA; 64], &[0xBB; 64], &[0xCC; 64]];
        let packet = craft_response(&UID, cookies, &s2c);
        let parsed = parse_server_response(&packet, &UID, CLIENT_TX, &s2c).unwrap();
        assert_eq!(parsed.unique_id, UID);
        assert_eq!(parsed.fresh_cookies.len(), 3);
        assert_eq!(parsed.fresh_cookies[0], cookies[0]);
        assert_eq!(parsed.fresh_cookies[2], cookies[2]);
        assert_eq!(parsed.header.mode(), mode::SERVER);
        assert_eq!(parsed.header.origin_timestamp, CLIENT_TX);
    }

    #[test]
    fn parse_response_rejects_tampered_authenticator() {
        let (_, s2c) = fresh_keys();
        let mut packet = craft_response(&UID, &[&[0xAA; 64]], &s2c);
        // Flip the last ciphertext byte (well past the nonce).
        let last = packet.len() - 1;
        packet[last] ^= 0x01;
        match parse_server_response(&packet, &UID, CLIENT_TX, &s2c) {
            Err(NtpError::Aead(_)) => {}
            other => panic!("expected Aead error, got {other:?}"),
        }
    }

    #[test]
    fn parse_response_rejects_tampered_aad() {
        let (_, s2c) = fresh_keys();
        let mut packet = craft_response(&UID, &[&[0xAA; 64]], &s2c);
        // Flip a byte in the NTP header (covered by the AEAD's AD).
        packet[8] ^= 0x80;
        match parse_server_response(&packet, &UID, CLIENT_TX, &s2c) {
            Err(NtpError::Aead(_)) => {}
            other => panic!("expected Aead error from AAD tamper, got {other:?}"),
        }
    }

    #[test]
    fn parse_response_rejects_wrong_unique_id() {
        let (_, s2c) = fresh_keys();
        let other_uid = [0x99u8; 32];
        let packet = craft_response(&other_uid, &[&[0xAA; 64]], &s2c);
        match parse_server_response(&packet, &UID, CLIENT_TX, &s2c) {
            Err(NtpError::UniqueIdentifierMismatch) => {}
            other => panic!("expected UniqueIdentifierMismatch, got {other:?}"),
        }
    }

    #[test]
    fn parse_response_rejects_client_mode_packet() {
        let (_, s2c) = fresh_keys();
        let mut packet = craft_response(&UID, &[&[0xAA; 64]], &s2c);
        packet[0] = (VERSION_4 << 3) | mode::CLIENT;
        match parse_server_response(&packet, &UID, CLIENT_TX, &s2c) {
            Err(NtpError::UnexpectedMode { actual }) if actual == mode::CLIENT => {}
            other => panic!("expected UnexpectedMode, got {other:?}"),
        }
    }

    #[test]
    fn parse_response_rejects_extension_after_authenticator() {
        let (_, s2c) = fresh_keys();
        let mut packet = craft_response(&UID, &[&[0xAA; 64]], &s2c);
        // Append a stray Unique Identifier extension after the Authenticator.
        packet.extend_from_slice(&encode_extension(ext_type::UNIQUE_IDENTIFIER, &[0xEE; 32]));
        match parse_server_response(&packet, &UID, CLIENT_TX, &s2c) {
            Err(NtpError::AuthenticatorNotLast) => {}
            other => panic!("expected AuthenticatorNotLast, got {other:?}"),
        }
    }

    #[test]
    fn parse_response_rejects_short_packet() {
        let (_, s2c) = fresh_keys();
        match parse_server_response(&[0u8; 8], &UID, CLIENT_TX, &s2c) {
            Err(NtpError::PacketTooShort) => {}
            other => panic!("expected PacketTooShort, got {other:?}"),
        }
    }

    #[test]
    fn parse_response_rejects_missing_authenticator() {
        let (_, s2c) = fresh_keys();
        let mut header = NtpHeader::client_request(0);
        header.li_vn_mode = (VERSION_4 << 3) | mode::SERVER;
        let mut packet = header.to_bytes().to_vec();
        packet.extend_from_slice(&encode_extension(ext_type::UNIQUE_IDENTIFIER, &UID));
        match parse_server_response(&packet, &UID, CLIENT_TX, &s2c) {
            Err(NtpError::MissingAuthenticator) => {}
            other => panic!("expected MissingAuthenticator, got {other:?}"),
        }
    }

    #[test]
    fn parse_response_rejects_mismatched_origin_timestamp() {
        let (_, s2c) = fresh_keys();
        let packet = craft_response(&UID, &[&[0xAA; 64]], &s2c);
        // Same well-formed, AEAD-valid packet, but the caller expected a
        // different transmit timestamp than the server echoed back. This is
        // the replay/splice scenario the new check guards against.
        let stale_expected = CLIENT_TX ^ 0x0000_0000_0001_0000;
        match parse_server_response(&packet, &UID, stale_expected, &s2c) {
            Err(NtpError::OriginTimestampMismatch { expected, actual }) => {
                assert_eq!(expected, stale_expected);
                assert_eq!(actual, CLIENT_TX);
            }
            other => panic!("expected OriginTimestampMismatch, got {other:?}"),
        }
    }

    /// End-to-end round trip under AES-128-GCM-SIV (AEAD ID 30): the same
    /// `build_client_request` / `parse_server_response` callers, just with a
    /// different `AeadKey` variant, must produce a packet that decrypts
    /// cleanly and yields the fresh cookies the synthetic server embedded.
    #[test]
    fn build_and_parse_round_trip_under_aes_128_gcm_siv() {
        // 16-byte keys (RFC 8452 §4 / IANA AEAD ID 30); deliberately distinct
        // from the SIV-CMAC `C2S` / `S2C` constants above.
        let c2s = AeadKey::from_keying_material(30, &[0x77; 16]).unwrap();
        let s2c = AeadKey::from_keying_material(30, &[0x88; 16]).unwrap();
        assert_eq!(c2s.algorithm_id(), 30);
        assert_eq!(s2c.nonce_len(), NONCE_LEN_GCM_SIV);

        // GCM-SIV requires a 12-byte wire nonce — the request struct carries
        // whatever the caller produced, so substitute a 12-byte one here.
        let req = ClientRequest {
            unique_id: UID.to_vec(),
            cookie: COOKIE.to_vec(),
            placeholder_count: 0,
            nonce: vec![0x44; NONCE_LEN_GCM_SIV],
            transmit_timestamp: CLIENT_TX,
        };
        let packet = build_client_request(&req, &c2s).unwrap();
        let exts = parse_extensions(&packet[HEADER_LEN..]).unwrap();
        assert_eq!(exts.last().unwrap().field_type, ext_type::NTS_AUTHENTICATOR);

        let cookies: &[&[u8]] = &[&[0xAA; 64], &[0xBB; 64]];
        let response = craft_response(&UID, cookies, &s2c);
        let parsed = parse_server_response(&response, &UID, CLIENT_TX, &s2c).unwrap();
        assert_eq!(parsed.fresh_cookies.len(), 2);
        assert_eq!(parsed.fresh_cookies[0], cookies[0]);
    }

    /// Cross-algorithm key confusion must fail closed: a packet sealed under
    /// SIV-CMAC must not open under GCM-SIV (and vice-versa) even when the
    /// raw key bytes happen to share a prefix.
    #[test]
    fn parse_response_rejects_cross_algorithm_key() {
        let (_, s2c_siv) = fresh_keys();
        let s2c_gcm = AeadKey::from_keying_material(30, &S2C[..16]).unwrap();
        let packet = craft_response(&UID, &[&[0xAA; 64]], &s2c_siv);
        match parse_server_response(&packet, &UID, CLIENT_TX, &s2c_gcm) {
            Err(NtpError::Aead(_)) => {}
            other => panic!("expected Aead failure on algorithm mismatch, got {other:?}"),
        }
    }

    /// Sanity-check the bit-shifting in `NtpHeader::leap()` so the
    /// downstream LI=3 rejection has a stable foundation. Each LI value
    /// (`00`, `01`, `10`, `11`) must round-trip through the standard
    /// `LL VVV MMM` packing with VN=4 and Mode=server.
    #[test]
    fn leap_indicator_extracts_two_high_bits() {
        for li in 0u8..=3 {
            let li_vn_mode = (li << 6) | (VERSION_4 << 3) | mode::SERVER;
            let mut h = NtpHeader::client_request(0);
            h.li_vn_mode = li_vn_mode;
            assert_eq!(h.leap(), li, "leap() failed to recover LI={li:#b}");
            assert_eq!(h.version(), VERSION_4);
            assert_eq!(h.mode(), mode::SERVER);
        }
    }

    /// LI=3 (alarm / unsynchronized) on an otherwise wire-correct,
    /// AEAD-authentic reply must short-circuit to `Unsynchronized`
    /// before any `NtsTimeSample` could be constructed. The mutation
    /// happens *before* sealing so the AAD covers the bad LI; this
    /// proves the post-AEAD ordering of the new check.
    #[test]
    fn parse_response_rejects_unsynchronized_alarm() {
        let (_, s2c) = fresh_keys();
        let packet = craft_response_with(&UID, &[&[0xAA; 64]], &s2c, |h| {
            // LL=11, VVV=100 (v4), MMM=100 (server) → 0xE4.
            h.li_vn_mode = (LI_UNSYNCHRONIZED << 6) | (VERSION_4 << 3) | mode::SERVER;
        });
        match parse_server_response(&packet, &UID, CLIENT_TX, &s2c) {
            Err(NtpError::Unsynchronized) => {}
            other => panic!("expected Unsynchronized, got {other:?}"),
        }
    }

    /// Stratum 16 is RFC 5905 §7.3's explicit "unsynchronized" marker;
    /// `17`–`255` are reserved. An authenticated reply carrying any
    /// such value conveys no usable time and must surface as
    /// `Unsynchronized` even when the Leap Indicator is clean (LI=0).
    /// The mutation happens pre-seal so the AAD covers the stratum
    /// byte; this pins the post-AEAD ordering of the new check
    /// against off-path stratum spoofing.
    #[test]
    fn parse_response_rejects_invalid_high_stratum() {
        let (_, s2c) = fresh_keys();
        let packet = craft_response_with(&UID, &[&[0xAA; 64]], &s2c, |h| {
            h.stratum = STRATUM_UNSYNCHRONIZED_FLOOR;
            // Leave LI=0 so the rejection is attributable purely to
            // the stratum ceiling, not a bleed-through from the
            // sibling LI=3 check.
            assert_eq!(h.leap(), 0, "test setup must keep LI clean");
        });
        match parse_server_response(&packet, &UID, CLIENT_TX, &s2c) {
            Err(NtpError::Unsynchronized) => {}
            other => panic!("expected Unsynchronized for stratum=16, got {other:?}"),
        }
    }

    /// Stratum-0 reply with the well-known `RATE` kiss code (RFC 5905
    /// §7.4) must surface as `KissOfDeath("RATE")`. Mutated pre-seal
    /// so the AEAD authenticates the kiss state; verifies the
    /// reference-id-to-ASCII conversion preserves standard codes
    /// byte-for-byte.
    #[test]
    fn parse_response_rejects_kiss_of_death_with_ascii_code() {
        let (_, s2c) = fresh_keys();
        let packet = craft_response_with(&UID, &[&[0xAA; 64]], &s2c, |h| {
            h.stratum = STRATUM_KISS_OF_DEATH;
            h.reference_id = *b"RATE";
        });
        match parse_server_response(&packet, &UID, CLIENT_TX, &s2c) {
            Err(NtpError::KissOfDeath(code)) => assert_eq!(code, "RATE"),
            other => panic!("expected KissOfDeath(\"RATE\"), got {other:?}"),
        }
    }

    /// Defensive: a malformed Stratum-0 reply whose `reference_id`
    /// carries non-printable bytes must still be classified as KoD
    /// rather than silently slipping through. `from_utf8_lossy`
    /// substitutes the Unicode replacement character (U+FFFD) for
    /// any invalid sequence; the test only requires the variant to
    /// be `KissOfDeath` so the diagnostic is preserved without
    /// pinning the exact lossy representation.
    #[test]
    fn parse_response_rejects_kiss_of_death_with_non_ascii_refid() {
        let (_, s2c) = fresh_keys();
        let packet = craft_response_with(&UID, &[&[0xAA; 64]], &s2c, |h| {
            h.stratum = STRATUM_KISS_OF_DEATH;
            h.reference_id = [0xFF, 0xFE, 0xFD, 0xFC];
        });
        match parse_server_response(&packet, &UID, CLIENT_TX, &s2c) {
            Err(NtpError::KissOfDeath(_)) => {}
            other => panic!("expected KissOfDeath, got {other:?}"),
        }
    }

    /// Off-path spoofing guard: a Stratum-0 packet whose header is
    /// mutated *after* sealing (i.e., not authenticated) must be
    /// rejected as an AEAD failure, not as KoD. This pins the
    /// post-AEAD ordering of the new check; flipping it would let an
    /// active adversary forge KoD states without holding the S2C key.
    #[test]
    fn parse_response_rejects_post_seal_kod_tamper_as_aead_failure() {
        let (_, s2c) = fresh_keys();
        let mut packet = craft_response(&UID, &[&[0xAA; 64]], &s2c);
        packet[1] = STRATUM_KISS_OF_DEATH; // stratum is byte 1 of the header
        packet[12..16].copy_from_slice(b"DENY");
        match parse_server_response(&packet, &UID, CLIENT_TX, &s2c) {
            Err(NtpError::Aead(_)) => {}
            other => panic!("expected Aead failure on post-seal tamper, got {other:?}"),
        }
    }

    /// Precedence pin: a real-world KoD reply almost always carries
    /// LI=3 alongside Stratum=0, because a server that is refusing to
    /// serve has no synchronised time to advertise (RFC 5905 §7.4).
    /// The classification must surface as `KissOfDeath` so the kiss
    /// code (`NTSN`, `RATE`, `DENY`, …) reaches the caller; collapsing
    /// it to the generic `Unsynchronized` arm would silently discard
    /// the back-off signal that distinguishes "rotate cookies" from
    /// "rate-limited" from "permission denied".
    #[test]
    fn parse_response_prefers_kod_over_unsynchronized_when_both_set() {
        let (_, s2c) = fresh_keys();
        let packet = craft_response_with(&UID, &[&[0xAA; 64]], &s2c, |h| {
            h.li_vn_mode = (LI_UNSYNCHRONIZED << 6) | (VERSION_4 << 3) | mode::SERVER;
            h.stratum = STRATUM_KISS_OF_DEATH;
            // `NTSN` is the NTS-specific kiss code (RFC 8915 §5.7) the
            // client uses as the trigger to re-handshake. Pinning it
            // here documents the precise back-off path that depends on
            // the kiss code surviving the parse.
            h.reference_id = *b"NTSN";
        });
        match parse_server_response(&packet, &UID, CLIENT_TX, &s2c) {
            Err(NtpError::KissOfDeath(code)) => assert_eq!(code, "NTSN"),
            other => panic!("expected KissOfDeath(\"NTSN\"), got {other:?}"),
        }
    }
}


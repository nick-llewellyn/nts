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
    #[must_use]
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

    #[must_use]
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
    UnexpectedMode {
        actual: u8,
    },
    UnexpectedVersion {
        actual: u8,
    },
    MissingUniqueIdentifier,
    UniqueIdentifierMismatch,
    /// Response carried more than one Unique Identifier extension in
    /// the AAD (i.e. before the Authenticator). RFC 8915 §5.3 says
    /// "the Unique Identifier extension field" (singular) appears in
    /// every NTS-protected NTP packet; a packet with two distinct
    /// UIDs in the cleartext-but-authenticated portion is malformed
    /// and must be rejected outright rather than implicitly resolving
    /// to "the first one". An attacker who could splice a second UID
    /// extension into a valid response (and re-seal the AAD via a
    /// compromised server, or via an off-path replay against a future
    /// in-flight request whose UID happens to match) would otherwise
    /// be able to confuse downstream UID-correlation logic into
    /// associating the response with the wrong outstanding request.
    /// Rejecting at the parser keeps the "one UID per packet"
    /// invariant load-bearing for every caller.
    DuplicateUniqueIdentifier,
    MissingAuthenticator,
    AuthenticatorNotLast,
    MalformedAuthenticator,
    EmptyNonce,
    /// Server's `origin_timestamp` did not echo the client's `transmit_timestamp`.
    /// Defense-in-depth replay guard layered on top of the AEAD (RFC 5905 §8).
    OriginTimestampMismatch {
        expected: u64,
        actual: u64,
    },
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
    /// RFC 8915 §5.7 NTSN Kiss-o'-Death response with a matching Unique
    /// Identifier. A standards-compliant server that cannot validate the
    /// cookie SHOULD respond with stratum `0` and `reference_id` =
    /// `NTSN`, and that response MUST NOT carry an Authenticator or
    /// Encrypted Extension Fields — the server has no usable session
    /// keys to AEAD-sign with. The matching UID echoed from the request
    /// is the only authenticity signal available; an off-path attacker
    /// who could observe one wire packet and forge a UID-matching NTSN
    /// can at worst force one extra KE handshake before the next
    /// legitimate response heals the session.
    ///
    /// Surfaced as a dedicated variant (rather than collapsing into the
    /// AEAD-authenticated `KissOfDeath` arm) so the `nts_query` caller
    /// can evict the now-stale cached session without trusting an
    /// unauthenticated header for any other purpose.
    StaleCookie,
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
            Self::DuplicateUniqueIdentifier => {
                f.write_str("response carries more than one Unique Identifier extension")
            }
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
            Self::StaleCookie => f.write_str(
                "server reports stale cookie (RFC 8915 §5.7 unauthenticated NTSN with matching UID)",
            ),
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
        out.push(RawExt {
            field_type: ft,
            body,
        });
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
    packet.extend_from_slice(&encode_extension(
        ext_type::UNIQUE_IDENTIFIER,
        &req.unique_id,
    ));
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
    let header_bytes: &[u8; HEADER_LEN] = bytes[..HEADER_LEN].try_into().expect("checked above");
    let header = NtpHeader::from_bytes(header_bytes);
    if header.version() != VERSION_4 {
        return Err(NtpError::UnexpectedVersion {
            actual: header.version(),
        });
    }
    if header.mode() != mode::SERVER {
        return Err(NtpError::UnexpectedMode {
            actual: header.mode(),
        });
    }

    let extensions = parse_extensions(&bytes[HEADER_LEN..])?;
    let auth_idx = match extensions
        .iter()
        .position(|ext| ext.field_type == ext_type::NTS_AUTHENTICATOR)
    {
        Some(idx) => idx,
        None => {
            // RFC 8915 §5.7: a server that cannot validate the cookie
            // SHOULD respond with a stratum-0 NTSN Kiss-o'-Death, and
            // that response MUST NOT include an Authenticator or
            // Encrypted Extension Fields — the server has no usable
            // session keys to AEAD-sign with. The matching Unique
            // Identifier echoed from the request is the only
            // authenticity signal we have; without it we cannot
            // distinguish a server NAK from an off-path attacker
            // forging a "your cookie is stale" prod, so a non-matching
            // (or absent) UID falls through to the standard
            // `MissingAuthenticator` rejection.
            //
            // This check is deliberately scoped to the no-Authenticator
            // path: an authenticated stratum-0 reply (whether NTSN or
            // any other kiss code) still flows through the AEAD verify
            // below and surfaces as `KissOfDeath`, preserving the
            // post-AEAD ordering pinned by
            // `parse_response_rejects_post_seal_kod_tamper_as_aead_failure`.
            if header.stratum == STRATUM_KISS_OF_DEATH
                && header.reference_id == *b"NTSN"
                && extensions.iter().any(|ext| {
                    ext.field_type == ext_type::UNIQUE_IDENTIFIER && ext.body == expected_uid
                })
            {
                return Err(NtpError::StaleCookie);
            }
            return Err(NtpError::MissingAuthenticator);
        }
    };
    if auth_idx + 1 != extensions.len() {
        return Err(NtpError::AuthenticatorNotLast);
    }

    // RFC 8915 §5.3 mandates "the" Unique Identifier extension
    // (singular). Count UID extensions in the AAD (everything before
    // the Authenticator) and reject outright if more than one is
    // present, rather than implicitly resolving to the first match
    // and ignoring any extras: a packet with two distinct UIDs in
    // the AAD is malformed, and accepting "the first" would let an
    // attacker who could splice in a second UID extension confuse
    // downstream UID-correlation logic into associating the response
    // with the wrong outstanding request.
    let uid_count = extensions[..auth_idx]
        .iter()
        .filter(|ext| ext.field_type == ext_type::UNIQUE_IDENTIFIER)
        .count();
    if uid_count > 1 {
        return Err(NtpError::DuplicateUniqueIdentifier);
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

    Ok(ServerResponse {
        header,
        unique_id,
        fresh_cookies,
    })
}

#[cfg(test)]
mod tests;

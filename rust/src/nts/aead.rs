//! AEAD wrappers for NTS-protected NTPv4 (RFC 8915 §5.6).
//!
//! Two algorithms ship today:
//!  * AES-SIV-CMAC-256 (IANA AEAD ID 15, RFC 5297) — the RFC 8915 mandatory
//!    baseline. Multi-AD, deterministic IV; the wire "nonce" is folded into
//!    the AD vector and the 16-byte synthetic IV is prepended to the ciphertext.
//!  * AES-128-GCM-SIV  (IANA AEAD ID 30, RFC 8452) — nonce-misuse-resistant
//!    GCM variant with native hardware acceleration on every shipping ARM and
//!    x86-64 part. 12-byte real nonce, 16-byte tag appended to ciphertext.
//!
//! Both fit cleanly into the RFC 8915 §5.6 Authenticator wire layout
//! (`nonce_len || ciphertext_len || nonce || ciphertext`); the [`AeadKey`]
//! enum dispatches to the right implementation while [`build_client_request`]
//! and [`parse_server_response`] in `nts::ntp` stay algorithm-agnostic.

use aes_gcm_siv::aead::Aead as _;
use aes_gcm_siv::Aes128GcmSiv;
use aes_gcm_siv::Nonce;
use aes_siv::aead::generic_array::GenericArray;
use aes_siv::siv::Aes128Siv;
use aes_siv::KeyInit;

/// AES-SIV-CMAC-256 key length (RFC 8915 §5.1, AEAD ID 15).
pub const KEY_LEN: usize = 32;

/// AES-128-GCM-SIV key length (RFC 8452 §4, IANA AEAD ID 30).
pub const KEY_LEN_GCM_SIV: usize = 16;

/// AES-128-GCM-SIV nonce length (RFC 8452 §4 fixes this at 96 bits).
pub const NONCE_LEN_GCM_SIV: usize = 12;

/// SIV synthetic-IV / tag length (RFC 5297 §2.6).
pub const TAG_LEN: usize = 16;

/// Recommended nonce length for the Authenticator extension when SIV-CMAC is
/// in use (RFC 8915 §5.7 requires "at least one octet"; 16 octets matches the
/// high-level Aead trait and what every reference implementation emits).
pub const RECOMMENDED_NONCE_LEN: usize = 16;

#[derive(Debug)]
pub enum AeadError {
    InvalidKeyLength { actual: usize, expected: usize },
    InvalidNonceLength { actual: usize, expected: usize },
    /// Caller asked [`AeadKey::from_keying_material`] for an IANA AEAD ID
    /// the crate does not implement. In normal flow this is unreachable
    /// — `nts::ke::validate_response` already rejects unsupported IDs
    /// via `KeError::UnsupportedAead` before the exporter material is
    /// ever sliced into a key — so this variant is a defence-in-depth
    /// guard that surfaces the offending ID for diagnostics rather than
    /// the previous `InvalidKeyLength { expected: 0 }` sentinel.
    UnsupportedAlgorithm(u16),
    SealFailed,
    OpenFailed,
}

impl std::fmt::Display for AeadError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidKeyLength { actual, expected } => {
                write!(f, "AEAD expects a {expected}-byte key, got {actual}")
            }
            Self::InvalidNonceLength { actual, expected } => {
                write!(f, "AEAD expects a {expected}-byte nonce, got {actual}")
            }
            Self::UnsupportedAlgorithm(id) => {
                write!(f, "unsupported AEAD algorithm id {id}")
            }
            Self::SealFailed => f.write_str("AEAD seal failed"),
            Self::OpenFailed => f.write_str("AEAD open failed (tag mismatch)"),
        }
    }
}

impl std::error::Error for AeadError {}

/// AES-SIV-CMAC-256 key material wrapped to enforce length once on construction.
#[derive(Clone)]
pub struct SivKey {
    bytes: [u8; KEY_LEN],
}

impl SivKey {
    pub fn from_slice(material: &[u8]) -> Result<Self, AeadError> {
        if material.len() != KEY_LEN {
            return Err(AeadError::InvalidKeyLength {
                actual: material.len(),
                expected: KEY_LEN,
            });
        }
        let mut bytes = [0u8; KEY_LEN];
        bytes.copy_from_slice(material);
        Ok(Self { bytes })
    }

    fn cipher(&self) -> Aes128Siv {
        Aes128Siv::new(GenericArray::from_slice(&self.bytes))
    }
}

impl std::fmt::Debug for SivKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SivKey").field("bytes", &"<redacted>").finish()
    }
}

/// AES-128-GCM-SIV key material wrapped to enforce length once on construction.
#[derive(Clone)]
pub struct Aes128GcmSivKey {
    bytes: [u8; KEY_LEN_GCM_SIV],
}

impl Aes128GcmSivKey {
    pub fn from_slice(material: &[u8]) -> Result<Self, AeadError> {
        if material.len() != KEY_LEN_GCM_SIV {
            return Err(AeadError::InvalidKeyLength {
                actual: material.len(),
                expected: KEY_LEN_GCM_SIV,
            });
        }
        let mut bytes = [0u8; KEY_LEN_GCM_SIV];
        bytes.copy_from_slice(material);
        Ok(Self { bytes })
    }

    fn cipher(&self) -> Aes128GcmSiv {
        Aes128GcmSiv::new(GenericArray::from_slice(&self.bytes))
    }
}

impl std::fmt::Debug for Aes128GcmSivKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Aes128GcmSivKey")
            .field("bytes", &"<redacted>")
            .finish()
    }
}

/// Seal `plaintext` with the given AD components, returning `synthetic_iv || ciphertext`.
///
/// The SIV is prepended (RFC 5297 §2.6); for an empty plaintext the output is
/// exactly `TAG_LEN` octets and serves as a pure authenticator.
pub fn siv_seal(key: &SivKey, ad: &[&[u8]], plaintext: &[u8]) -> Result<Vec<u8>, AeadError> {
    key.cipher()
        .encrypt(ad, plaintext)
        .map_err(|_| AeadError::SealFailed)
}

/// Open `synthetic_iv || ciphertext` with the given AD components.
///
/// Returns the original plaintext on success or `AeadError::OpenFailed` on
/// any tag mismatch, malformed input, or AD substitution.
pub fn siv_open(key: &SivKey, ad: &[&[u8]], sealed: &[u8]) -> Result<Vec<u8>, AeadError> {
    key.cipher()
        .decrypt(ad, sealed)
        .map_err(|_| AeadError::OpenFailed)
}

/// Algorithm-agnostic AEAD key for the NTS Authenticator extension.
///
/// Wraps the per-algorithm key types and exposes a single entry point —
/// [`seal_packet`](Self::seal_packet) / [`open_packet`](Self::open_packet) —
/// so the wire-format code in `nts::ntp` is parametric over the negotiated
/// algorithm. The two arms differ in how the wire nonce is consumed: SIV-CMAC
/// folds it into the AD vector (deterministic IV); GCM-SIV uses it as a real
/// 96-bit nonce.
#[derive(Clone, Debug)]
pub enum AeadKey {
    SivCmac256(SivKey),
    Aes128GcmSiv(Aes128GcmSivKey),
}

impl AeadKey {
    /// IANA AEAD ID this key targets.
    pub fn algorithm_id(&self) -> u16 {
        match self {
            Self::SivCmac256(_) => 15,
            Self::Aes128GcmSiv(_) => 30,
        }
    }

    /// Recommended wire-nonce length for the negotiated algorithm.
    ///
    /// SIV-CMAC tolerates any non-empty length; GCM-SIV requires exactly 12
    /// bytes (RFC 8452 §4). Callers generating fresh nonces should use this
    /// to size their RNG read.
    pub fn nonce_len(&self) -> usize {
        match self {
            Self::SivCmac256(_) => RECOMMENDED_NONCE_LEN,
            Self::Aes128GcmSiv(_) => NONCE_LEN_GCM_SIV,
        }
    }

    /// Build an `AeadKey` from raw exporter material based on the AEAD ID.
    ///
    /// Unknown IDs surface as [`AeadError::UnsupportedAlgorithm`] (rather
    /// than the legacy `InvalidKeyLength { expected: 0 }` sentinel) so
    /// callers can distinguish "wrong-sized key for a known algorithm"
    /// from "this crate has never heard of that algorithm".
    pub fn from_keying_material(aead_id: u16, material: &[u8]) -> Result<Self, AeadError> {
        match aead_id {
            15 => SivKey::from_slice(material).map(Self::SivCmac256),
            30 => Aes128GcmSivKey::from_slice(material).map(Self::Aes128GcmSiv),
            other => Err(AeadError::UnsupportedAlgorithm(other)),
        }
    }

    /// Encrypt `plaintext` for the Authenticator extension. `packet_aad` is
    /// the NTPv4 header plus all extensions preceding the Authenticator;
    /// `nonce` is the wire nonce field. Returns the bytes that go into the
    /// Authenticator's `ciphertext` field.
    pub fn seal_packet(
        &self,
        packet_aad: &[u8],
        nonce: &[u8],
        plaintext: &[u8],
    ) -> Result<Vec<u8>, AeadError> {
        match self {
            Self::SivCmac256(k) => siv_seal(k, &[packet_aad, nonce], plaintext),
            Self::Aes128GcmSiv(k) => {
                if nonce.len() != NONCE_LEN_GCM_SIV {
                    return Err(AeadError::InvalidNonceLength {
                        actual: nonce.len(),
                        expected: NONCE_LEN_GCM_SIV,
                    });
                }
                k.cipher()
                    .encrypt(
                        Nonce::from_slice(nonce),
                        aes_gcm_siv::aead::Payload {
                            msg: plaintext,
                            aad: packet_aad,
                        },
                    )
                    .map_err(|_| AeadError::SealFailed)
            }
        }
    }

    /// Decrypt the Authenticator's `ciphertext` field. Mirrors
    /// [`seal_packet`](Self::seal_packet).
    pub fn open_packet(
        &self,
        packet_aad: &[u8],
        nonce: &[u8],
        sealed: &[u8],
    ) -> Result<Vec<u8>, AeadError> {
        match self {
            Self::SivCmac256(k) => siv_open(k, &[packet_aad, nonce], sealed),
            Self::Aes128GcmSiv(k) => {
                if nonce.len() != NONCE_LEN_GCM_SIV {
                    return Err(AeadError::InvalidNonceLength {
                        actual: nonce.len(),
                        expected: NONCE_LEN_GCM_SIV,
                    });
                }
                k.cipher()
                    .decrypt(
                        Nonce::from_slice(nonce),
                        aes_gcm_siv::aead::Payload {
                            msg: sealed,
                            aad: packet_aad,
                        },
                    )
                    .map_err(|_| AeadError::OpenFailed)
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// RFC 5297 §A.1 deterministic-mode vector (single AD, plaintext `11..ee`).
    /// Cross-checked against `aes-siv` 0.7's `aes128cmacsiv` test fixture.
    #[test]
    fn rfc_5297_a1_deterministic_vector() {
        let key_bytes = hex(
            "fffefdfcfbfaf9f8f7f6f5f4f3f2f1f0\
             f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff",
        );
        let ad = hex("101112131415161718191a1b1c1d1e1f2021222324252627");
        let plaintext = hex("112233445566778899aabbccddee");
        let expected =
            hex("85632d07c6e8f37f950acd320a2ecc9340c02b9690c4dc04daef7f6afe5c");

        let key = SivKey::from_slice(&key_bytes).unwrap();
        let sealed = siv_seal(&key, &[&ad], &plaintext).unwrap();
        assert_eq!(sealed, expected);

        let opened = siv_open(&key, &[&ad], &sealed).unwrap();
        assert_eq!(opened, plaintext);
    }

    /// RFC 5297 §A.2 nonce-based vector (three AD components, longer plaintext).
    #[test]
    fn rfc_5297_a2_nonce_based_vector() {
        let key_bytes = hex(
            "7f7e7d7c7b7a79787776757473727170\
             404142434445464748494a4b4c4d4e4f",
        );
        let ad1 = hex(
            "00112233445566778899aabbccddeeffdeaddadadeaddada\
             ffeeddccbbaa99887766554433221100",
        );
        let ad2 = hex("102030405060708090a0");
        let nonce = hex("09f911029d74e35bd84156c5635688c0");
        let plaintext = hex(
            "7468697320697320736f6d6520706c61\
             696e7465787420746f20656e63727970\
             74207573696e6720534956\
             2d414553",
        );
        let expected = hex(
            "7bdb6e3b432667eb06f4d14bff2fbd0fcb900f2fddbe404326601965c889bf17\
             dba77ceb094fa663b7a3f748ba8af829ea64ad544a272e9c485b62a3fd5c0d",
        );

        let key = SivKey::from_slice(&key_bytes).unwrap();
        let sealed = siv_seal(&key, &[&ad1, &ad2, &nonce], &plaintext).unwrap();
        assert_eq!(sealed, expected);
        let opened = siv_open(&key, &[&ad1, &ad2, &nonce], &sealed).unwrap();
        assert_eq!(opened, plaintext);
    }

    #[test]
    fn empty_plaintext_yields_pure_tag() {
        let key = SivKey::from_slice(&[0u8; KEY_LEN]).unwrap();
        let sealed = siv_seal(&key, &[b"ad", b"nonce"], b"").unwrap();
        assert_eq!(sealed.len(), TAG_LEN);
        let opened = siv_open(&key, &[b"ad", b"nonce"], &sealed).unwrap();
        assert!(opened.is_empty());
    }

    #[test]
    fn tampered_tag_rejects() {
        let key = SivKey::from_slice(&[0xAB; KEY_LEN]).unwrap();
        let mut sealed = siv_seal(&key, &[b"ad", b"nonce"], b"data").unwrap();
        sealed[0] ^= 0x01;
        match siv_open(&key, &[b"ad", b"nonce"], &sealed) {
            Err(AeadError::OpenFailed) => {}
            other => panic!("expected OpenFailed, got {other:?}"),
        }
    }

    #[test]
    fn ad_substitution_rejects() {
        let key = SivKey::from_slice(&[0xCD; KEY_LEN]).unwrap();
        let sealed = siv_seal(&key, &[b"ad-original", b"nonce"], b"payload").unwrap();
        match siv_open(&key, &[b"ad-substituted", b"nonce"], &sealed) {
            Err(AeadError::OpenFailed) => {}
            other => panic!("expected OpenFailed, got {other:?}"),
        }
    }

    #[test]
    fn rejects_short_key() {
        match SivKey::from_slice(&[0u8; 16]) {
            Err(AeadError::InvalidKeyLength { actual: 16, expected: KEY_LEN }) => {}
            other => panic!("expected InvalidKeyLength(16, {KEY_LEN}), got {other:?}"),
        }
    }

    #[test]
    fn debug_does_not_leak_key_material() {
        let key = SivKey::from_slice(&[0x55; KEY_LEN]).unwrap();
        let rendered = format!("{key:?}");
        assert!(!rendered.contains("55"));
        assert!(rendered.contains("redacted"));
    }

    #[test]
    fn aes_128_gcm_siv_round_trips_via_aead_key() {
        let key = AeadKey::from_keying_material(30, &[0xA5; KEY_LEN_GCM_SIV]).unwrap();
        assert_eq!(key.algorithm_id(), 30);
        assert_eq!(key.nonce_len(), NONCE_LEN_GCM_SIV);
        let nonce = [0x11u8; NONCE_LEN_GCM_SIV];
        let aad = b"ntp header || extensions";
        let plaintext = b"new-cookie payload bytes";
        let sealed = key.seal_packet(aad, &nonce, plaintext).unwrap();
        // GCM-SIV emits ciphertext || tag; tag is 16 bytes.
        assert_eq!(sealed.len(), plaintext.len() + 16);
        let opened = key.open_packet(aad, &nonce, &sealed).unwrap();
        assert_eq!(opened, plaintext);
    }

    #[test]
    fn aead_key_rejects_wrong_gcm_siv_nonce_len() {
        let key = AeadKey::from_keying_material(30, &[0u8; KEY_LEN_GCM_SIV]).unwrap();
        // SIV-CMAC tolerates any non-empty nonce length, but GCM-SIV must be 12.
        match key.seal_packet(b"ad", &[0u8; 16], b"x") {
            Err(AeadError::InvalidNonceLength { actual: 16, expected: 12 }) => {}
            other => panic!("expected InvalidNonceLength, got {other:?}"),
        }
    }

    #[test]
    fn aead_key_siv_dispatches_to_multi_ad() {
        // Equivalence proof: AeadKey::SivCmac256(...).seal_packet(aad, nonce, pt)
        // is byte-identical to siv_seal(key, &[aad, nonce], pt). This is the
        // wire-format invariant the ntp.rs callers depend on.
        let raw = SivKey::from_slice(&[0x77; KEY_LEN]).unwrap();
        let wrapped = AeadKey::SivCmac256(raw.clone());
        let aad = b"header-bytes";
        let nonce = [0x88u8; RECOMMENDED_NONCE_LEN];
        let pt = b"payload";
        let direct = siv_seal(&raw, &[aad, &nonce], pt).unwrap();
        let via_enum = wrapped.seal_packet(aad, &nonce, pt).unwrap();
        assert_eq!(direct, via_enum);
    }

    /// Unknown IANA AEAD IDs must surface via the dedicated
    /// `UnsupportedAlgorithm` variant carrying the offending id, not via
    /// the legacy `InvalidKeyLength { expected: 0 }` sentinel that
    /// callers had to special-case to recover the semantic.
    #[test]
    fn aead_key_rejects_unknown_algorithm() {
        match AeadKey::from_keying_material(0xFFFF, &[0u8; 32]) {
            Err(AeadError::UnsupportedAlgorithm(0xFFFF)) => {}
            other => panic!("expected UnsupportedAlgorithm(0xFFFF), got {other:?}"),
        }
    }

    /// `InvalidKeyLength` must remain reserved for genuine length
    /// mismatches against a known algorithm — i.e. SIV-CMAC-256 expects
    /// 32 octets but we hand it 16. This is the regression guard that
    /// keeps the new `UnsupportedAlgorithm` arm from quietly swallowing
    /// the length-validation path when a future refactor reorders the
    /// match in `from_keying_material`.
    #[test]
    fn aead_key_known_id_short_material_is_invalid_key_length() {
        match AeadKey::from_keying_material(15, &[0u8; 16]) {
            Err(AeadError::InvalidKeyLength {
                actual: 16,
                expected: KEY_LEN,
            }) => {}
            other => panic!("expected InvalidKeyLength for short SIV key, got {other:?}"),
        }
    }

    #[test]
    fn gcm_siv_debug_does_not_leak_key_material() {
        let key = Aes128GcmSivKey::from_slice(&[0x66; KEY_LEN_GCM_SIV]).unwrap();
        let rendered = format!("{key:?}");
        assert!(!rendered.contains("66"));
        assert!(rendered.contains("redacted"));
    }

    fn hex(s: &str) -> Vec<u8> {
        let cleaned: String = s.chars().filter(|c| !c.is_whitespace()).collect();
        assert!(cleaned.len().is_multiple_of(2), "odd-length hex string");
        (0..cleaned.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&cleaned[i..i + 2], 16).expect("valid hex"))
            .collect()
    }
}

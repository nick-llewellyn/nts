//! Shared test-only helpers for the `nts/` modules. Gated `#[cfg(test)]`
//! at the module declaration in `nts/mod.rs` so the contents are
//! compiled out of release builds; `pub(crate)` visibility lets sibling
//! test modules in `ke.rs`, `ntp.rs`, and `records.rs` reach them
//! without per-file private re-exports.
//!
//! De-duplicates the `rec` helper that previously appeared verbatim in
//! `records.rs::tests` and `ke.rs::tests`. The `craft_*` and
//! `fresh_keys` / `sample_request` helpers lifted from
//! `ntp.rs::tests` are kept here as the natural home for future shared
//! test infrastructure (e.g. `IdentityAead` from bd nts-fa3) even
//! though no cross-file caller exists today — the lift is the
//! load-bearing structural change the ticket specifies, not a current
//! de-duplication win.
//!
//! Ticket: bd nts-wzg.

use zeroize::Zeroizing;

use crate::nts::aead::{AeadKey, RECOMMENDED_NONCE_LEN};
use crate::nts::ntp::{
    encode_authenticator_body, encode_extension, ext_type, mode, ClientRequest, NtpHeader,
    STRATUM_KISS_OF_DEATH, VERSION_4,
};
use crate::nts::records::{Record, RecordKind};

const C2S: [u8; 32] = [0x11; 32];
/// Canned server-to-client AEAD key bytes. `pub(crate)` so the
/// alternate-AEAD tests in `ntp.rs::tests` can re-derive a
/// cross-algorithm key from the same bytes (e.g. `&S2C[..16]` for
/// `AES_128_GCM_SIV`'s 16-octet key length) without duplicating the
/// constant.
pub(crate) const S2C: [u8; 32] = [0x22; 32];
/// Canned client unique-id; mirrored back as the server's UID extension
/// by [`craft_response_with`]. `pub(crate)` so individual test cases
/// that compare against it can import it alongside the helper.
pub(crate) const UID: [u8; 32] = [0x33; 32];
const NONCE: [u8; RECOMMENDED_NONCE_LEN] = [0x44; RECOMMENDED_NONCE_LEN];
/// Canned cookie payload; `pub(crate)` so tests that build their own
/// `ClientRequest` (rather than going through [`sample_request`]) can
/// share the same value.
pub(crate) const COOKIE: &[u8] = &[0x55; 64];
/// Canned client `transmit_timestamp` mirrored back as the server's
/// `origin_timestamp` in [`craft_response_with`]. `pub(crate)` so tests
/// that drive `parse_server_response` directly can reference the same
/// value the helper builds against.
pub(crate) const CLIENT_TX: u64 = 0xDEAD_BEEF_CAFE_F00D;

/// Build a [`Record`] with the given critical bit and kind. Replaces
/// the `fn rec` helpers that previously lived verbatim in
/// `records.rs::tests` and `ke.rs::tests`; both now `use
/// crate::nts::test_helpers::rec`.
pub(crate) fn rec(critical: bool, kind: RecordKind) -> Record {
    Record::new(critical, kind)
}

/// Construct the canonical `(c2s, s2c)` AEAD key pair used by every
/// crafted-response test. Bytes are fixed so output is deterministic;
/// the IANA AEAD ID `15` is `AES_SIV_CMAC_256` per RFC 8915 §5.1.
pub(crate) fn fresh_keys() -> (AeadKey, AeadKey) {
    (
        AeadKey::from_keying_material(15, &C2S).unwrap(),
        AeadKey::from_keying_material(15, &S2C).unwrap(),
    )
}

/// Canonical [`ClientRequest`] populated with the canned constants
/// above. Used by tests that drive `build_client_request_packet` and
/// related encoders without needing per-test fixture boilerplate.
pub(crate) fn sample_request() -> ClientRequest {
    ClientRequest {
        unique_id: UID.to_vec(),
        cookie: Zeroizing::new(COOKIE.to_vec()),
        placeholder_count: 0,
        nonce: NONCE.to_vec(),
        transmit_timestamp: CLIENT_TX,
    }
}

/// Assemble a synthetic server reply mirroring what an honest NTS
/// server would send: header(mode=server) + UID + NewCookie extensions
/// wrapped in an Authenticator extension sealed with the S2C key. Works
/// for any AEAD by sizing the wire nonce from `s2c.nonce_len()`.
pub(crate) fn craft_response(uid: &[u8], fresh_cookies: &[&[u8]], s2c: &AeadKey) -> Vec<u8> {
    craft_response_with(uid, fresh_cookies, s2c, &[], |_| {})
}

/// Same as [`craft_response`] but lets the test inject arbitrary
/// cleartext extensions before the Authenticator (`aad_extras`)
/// and/or mutate the header after the canonical fields are populated
/// and *before* the AEAD seals it (`tweak`).
///
/// `aad_extras`: each `(field_type, body)` pair is encoded as a wire
/// extension and inserted between the canonical UID extension and the
/// Authenticator. Bodies are borrowed (`&[u8]`) so callers can pass
/// fixed-size byte arrays / existing slices without allocating a fresh
/// `Vec` per entry. The Authenticator's AAD covers the header plus
/// every extension before the Authenticator (computed by
/// `parse_server_response` as `bytes[..aad_end]`, where `aad_end` sums
/// the wire lengths of every extension at indices `..auth_idx`), so
/// these extras are AAD-only — authenticated against tampering but
/// **not** AEAD-encrypted. Used by
/// `parse_response_only_returns_cookies_from_decrypted_body` to pin
/// the RFC 8915 §5.5 source-of-cookies invariant: even a well-formed
/// `NTS_COOKIE` extension placed in the AAD slot must be ignored by
/// the cookie-extraction sweep, which is scoped to the AEAD-decrypted
/// body only.
///
/// `tweak`: required to exercise post-AEAD validation paths (Stratum-0
/// KoD, LI=3 alarm) under a wire-correct, authentic packet — anything
/// that mutates the header *after* sealing would trip the AAD check
/// and surface as an `Aead` error instead.
pub(crate) fn craft_response_with(
    uid: &[u8],
    fresh_cookies: &[&[u8]],
    s2c: &AeadKey,
    aad_extras: &[(u16, &[u8])],
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
    for (field_type, body) in aad_extras {
        packet.extend_from_slice(&encode_extension(*field_type, body));
    }
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

/// Synthesize an unauthenticated NTSN-shaped reply (RFC 8915 §5.7) for
/// the cookie-eviction tests. Header has Stratum=0, reference id =
/// `NTSN`, mode=server, optionally followed by an exact Unique
/// Identifier echoed back (or any caller-supplied substitute for the
/// negative tests), and explicitly NO Authenticator or Encrypted
/// Extension Fields. The server has no usable session keys to
/// AEAD-sign with, which is the whole reason §5.7 exists.
pub(crate) fn craft_unauthenticated_ntsn(uid_extension: Option<&[u8]>) -> Vec<u8> {
    let mut header = NtpHeader::client_request(0);
    header.li_vn_mode = (VERSION_4 << 3) | mode::SERVER;
    header.stratum = STRATUM_KISS_OF_DEATH;
    header.reference_id = *b"NTSN";
    let mut packet = header.to_bytes().to_vec();
    if let Some(uid) = uid_extension {
        packet.extend_from_slice(&encode_extension(ext_type::UNIQUE_IDENTIFIER, uid));
    }
    packet
}

//! libFuzzer harness for `parse_server_response` from
//! `rust/src/nts/ntp.rs`, reached through the
//! `nts_rust::__internal_fuzz::parse_server_response` re-export.
//!
//! This is the end-to-end receive entry for the fully
//! attacker-controlled UDP path: an off-path attacker can deliver
//! arbitrary bytes to the client's ephemeral port, so everything the
//! function does *before* the AEAD verifies is reachable by an
//! unauthenticated adversary — header length/version/mode checks, the
//! `parse_extensions` sweep, the unauthenticated-NTSN (stale-cookie)
//! arm, the duplicate-UID rejection, `parse_authenticator_body`, and
//! the AAD-offset summation. A panic in any of those arms is a
//! remote-DoS bug.
//!
//! AEAD choice — deliberately a *real* key, not `IdentityAead`: the
//! threat model here is the off-path attacker, who cannot forge AEAD
//! tags either, so a fixed AES-SIV-CMAC-256 key models the exposed
//! surface exactly. `IdentityAead` is `#[cfg(test)]`, is a separate
//! type from the concrete `&AeadKey` parameter, and plumbing it in
//! would mean extending the `AeadKey` algorithm-dispatch enum with a
//! fuzz-only variant — which `AeadKey::from_keying_material`'s docs
//! pin as intentionally not extended. The post-AEAD surface this
//! forgoes is small and covered elsewhere: `parse_extensions` on the
//! decrypted plaintext is the sibling `parse_extensions` target's
//! whole input space, and the remaining post-AEAD arms are simple
//! field checks pinned by unit tests.
//!
//! Property under test: `parse_server_response` must never panic,
//! abort, over-read, or unboundedly allocate on arbitrary bytes.
//! `Ok(ServerResponse)` and every typed `NtpError` arm are acceptable
//! outcomes and discarded.
//!
//! Fixed inputs for the non-packet arguments — the values mirror the
//! parent crate's `nts::test_helpers` constants so seeds crafted with
//! those helpers authenticate here:
//!
//! - `expected_uid = [0x33; 32]` (`test_helpers::UID`)
//! - `expected_origin_timestamp = 0xDEAD_BEEF_CAFE_F00D`
//!   (`test_helpers::CLIENT_TX`)
//! - `s2c_key` = AES-SIV-CMAC-256 from keying material `[0x22; 32]`
//!   (`test_helpers::S2C`; IANA AEAD ID 15, the production default)
//!
//! Seed corpus (`corpus/parse_server_response/`, committed):
//!
//! - `canonical-authenticated-response` (192 bytes): a full
//!   `craft_response`-shaped reply sealed under the key above with one
//!   64-byte cookie — parses fully `Ok`, giving the fuzzer coverage of
//!   every arm up to and including the AEAD pass and cookie sweep.
//! - `ntsn-kod-unauthenticated` (84 bytes): stratum-0 `NTSN` reply
//!   with the matching UID and no Authenticator — drives the RFC 8915
//!   §5.7 stale-cookie arm.
//! - `truncated-header` (4 bytes): drives the `PacketTooShort` arm.
//!
//! Provenance: bd nts-i8mz / NTS-60 (2026-07-02 security review, M1).

#![no_main]

use std::sync::LazyLock;

use libfuzzer_sys::fuzz_target;
use nts_rust::__internal_fuzz::{parse_server_response, AeadKey};

/// Mirrors `nts::test_helpers::UID`.
const EXPECTED_UID: [u8; 32] = [0x33; 32];
/// Mirrors `nts::test_helpers::CLIENT_TX`.
const EXPECTED_ORIGIN_TIMESTAMP: u64 = 0xDEAD_BEEF_CAFE_F00D;

/// Fixed S2C key (AES-SIV-CMAC-256 over `test_helpers::S2C` bytes),
/// constructed once — key derivation is deterministic and per-run
/// state-free, so rebuilding it per input would only burn exec/s.
static S2C_KEY: LazyLock<AeadKey> =
    LazyLock::new(|| AeadKey::from_keying_material(15, &[0x22; 32]).expect("valid keying material"));

fuzz_target!(|data: &[u8]| {
    // Discard the `Result`. The only failure mode the harness cares
    // about is a panic / abort / sanitizer trip inside the parser;
    // both `Ok` and `Err(NtpError::*)` are valid outcomes.
    let _ = parse_server_response(data, &EXPECTED_UID, EXPECTED_ORIGIN_TIMESTAMP, &S2C_KEY);
});

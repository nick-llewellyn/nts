//! libFuzzer harness for `parse_authenticator_body` from
//! `rust/src/nts/ntp.rs`, reached through the
//! `nts_rust::__internal_fuzz::parse_authenticator_body` re-export.
//!
//! The Authenticator body carries its own length arithmetic —
//! `nonce_len` / `ct_len` big-endian prefixes, `div_ceil(4) * 4`
//! padding, and the `body[4..4 + nonce_len]` /
//! `body[ct_start..ct_start + ct_len]` slice bounds — independent of
//! the outer `parse_extensions` framing. That arithmetic sits on the
//! fully attacker-controlled UDP path (an off-path attacker can send
//! arbitrary bytes to the client's ephemeral port), so it gets a
//! dedicated harness rather than relying on the end-to-end
//! `parse_server_response` target, where reaching the Authenticator
//! parse requires the fuzzer to first satisfy header/UID framing.
//!
//! Property under test: `parse_authenticator_body` must never panic,
//! abort, or over-read when fed arbitrary bytes. `Ok(AuthenticatorBody)`
//! and every typed `NtpError` arm (`MalformedAuthenticator`,
//! `EmptyNonce`) are acceptable outcomes and discarded.
//!
//! Seed corpus (`corpus/parse_authenticator_body/`, committed):
//!
//! - `canonical-body` (52 bytes): `nonce_len=16`, `ct_len=32`, both
//!   already 4-aligned — the happy path.
//! - `unaligned-nonce-len` (20 bytes): `nonce_len=11`, `ct_len=4` —
//!   drives the `div_ceil` padding arms with a non-aligned nonce.
//! - `oversized-announced-lengths` (8 bytes): `nonce_len=255`,
//!   `ct_len=255` against a 4-byte tail — drives the
//!   `consumed > body.len()` rejection.
//!
//! Provenance: bd nts-i8mz / NTS-60 (2026-07-02 security review, M1).

#![no_main]

use libfuzzer_sys::fuzz_target;
use nts_rust::__internal_fuzz::parse_authenticator_body;

fuzz_target!(|data: &[u8]| {
    // Discard the `Result`. The only failure mode the harness cares
    // about is a panic / abort / sanitizer trip inside the parser;
    // both `Ok` and `Err(NtpError::*)` are valid outcomes.
    let _ = parse_authenticator_body(data);
});

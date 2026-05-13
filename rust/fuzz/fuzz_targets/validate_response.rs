//! libFuzzer harness for `validate_response` from `rust/src/nts/ke.rs`,
//! reached through the `nts_rust::__fuzzing::validate_response`
//! shim. The shim discards the success-payload `KeOutcomePartial`
//! (which stays private to the `nts::ke` module) and surfaces
//! `Result<(), KeError>` — the harness only asserts the call does
//! not panic.
//!
//! `validate_response` is one logical layer above `parse_message`:
//! it consumes a parsed `Vec<Record>` and applies the RFC 8915 §4
//! semantic-shape rules (NextProtocol record present + critical;
//! AeadAlgorithm in the offered set; cookie list non-empty;
//! Server-record / Port-record overrides; no Error or unknown-
//! critical record bailing the negotiation). A panic in any of
//! those arms is a remote-DoS bug — the bytes have passed TLS
//! authentication but originate at the NTS-KE server (a malicious
//! operator or compromised CA could control them).
//!
//! Property under test: `validate_response` must never panic,
//! abort, or unboundedly allocate when fed an arbitrary
//! `parse_message`-accepted record list. Both `Ok(())` and
//! `Err(KeError::*)` are acceptable outcomes; the harness
//! discards the `Result`.
//!
//! Input shape: the harness pipes the fuzzer's bytes through
//! `parse_message` first and only invokes `validate_response` on
//! successful parses. This keeps the fuzzer focused on the
//! semantic-validation surface; the byte-level framing surface is
//! exercised by the sibling `parse_message` harness (PR #49).
//!
//! Fixed inputs for the non-record arguments:
//!
//! - `request_host = "time.example.com"` — only material in the
//!   Server-record-override path; using a stable value keeps that
//!   surface reachable without making it the only thing the fuzzer
//!   explores.
//! - `offered_aead = &[AES_SIV_CMAC_256]` — the production default.
//!   Drives the unsupported-AEAD arm whenever the parsed records
//!   advertise anything other than `AES_SIV_CMAC_256`.
//!
//! Seed corpus (`corpus/validate_response/`, committed): the same
//! three files as `parse_message` (PR #49) — the
//! `canonical-full-message` happy-path drives the validator's
//! accept arms; the `minimal-eom-only` and `truncated-header`
//! drive the early-rejection arms. Future minimised crashes get
//! promoted into this corpus.
//!
//! Provenance: bd nts-e8v (final follow-up to bd nts-y6y).

#![no_main]

use libfuzzer_sys::fuzz_target;
use nts_rust::__fuzzing::{parse_message, validate_response, AES_SIV_CMAC_256};

fuzz_target!(|data: &[u8]| {
    if let Ok(records) = parse_message(data) {
        let _ = validate_response("time.example.com", &[AES_SIV_CMAC_256], &records);
    }
});

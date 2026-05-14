//! libFuzzer harness for `parse_message` from `rust/src/nts/records.rs`,
//! reached through the `nts_rust::__internal_fuzz::parse_message`
//! re-export. The `nts` module is `pub(crate)` in ordinary builds;
//! the `__internal-fuzz` Cargo feature (declared in `rust/Cargo.toml`
//! and enabled by `rust/fuzz/Cargo.toml`'s `nts_rust` dependency line)
//! re-exports the parser so this harness can target it without
//! widening the parent crate's public API.
//!
//! Property under test: `parse_message` must never panic, abort,
//! over-read, or unboundedly allocate when fed arbitrary bytes. The
//! happy path returns `Ok(Vec<Record>)`; every malformed input must
//! fall into a typed `CodecError` arm (`TruncatedHeader`,
//! `BodyOverflow`, `OddU16Array`, `BodyLengthMismatch`,
//! `InvalidUtf8`, `MissingTerminator`, `NonEmptyEndOfMessage`,
//! `MessageTooLarge`). Both outcomes are acceptable and discarded
//! — the harness asserts only the absence of panics / sanitizer
//! trips, which libfuzzer detects directly.
//!
//! `parse_message` is the second of three attacker-facing parsers
//! identified in bd nts-y6y. The bytes parsed here have passed TLS
//! authentication but originate at the NTS-KE server (a malicious
//! operator or a compromised CA could control them). The PR #40
//! 16 KiB read cap bounds total throughput; this harness exercises
//! the per-record decode path itself.
//!
//! Seed corpus (`corpus/parse_message/`, committed):
//!
//! - `minimal-eom-only` (4 bytes): the smallest possible valid
//!   message — a single critical EndOfMessage record. Gives the
//!   fuzzer a near-zero-cost happy-path anchor to start mutating.
//! - `canonical-full-message` (152 bytes): mirrors the
//!   `round_trip_full_message` test fixture in `records.rs`. Covers
//!   every record kind in `RecordKind` (NextProtocol, AeadAlgorithm,
//!   NewCookie, Server, Port, Warning, EndOfMessage) plus both
//!   critical-bit settings.
//! - `truncated-header` (3 bytes): an EOM header missing its final
//!   byte. Pins the `bytes.len() - cursor < 4` arm in
//!   `parse_message`'s loop preamble.
//!
//! Provenance: bd nts-og0 (follow-up to bd nts-y6y).

#![no_main]

use libfuzzer_sys::fuzz_target;
use nts_rust::__internal_fuzz::parse_message;

fuzz_target!(|data: &[u8]| {
    // Discard the `Result`. The only failure mode the harness cares
    // about is a panic / abort / sanitizer trip inside the parser;
    // both `Ok` (well-formed message) and `Err(CodecError::*)`
    // (typed rejection) are valid outcomes.
    let _ = parse_message(data);
});

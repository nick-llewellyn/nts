//! libFuzzer harness for `parse_extensions` from `rust/src/nts/ntp.rs`,
//! reached through the `nts_rust::__internal_fuzz::parse_extensions`
//! re-export. The `nts` module is `pub(crate)` in ordinary builds;
//! the `__internal-fuzz` Cargo feature (declared in `rust/Cargo.toml`
//! and enabled by `rust/fuzz/Cargo.toml`'s `nts_rust` dependency line)
//! re-exports the parser so this harness can target it without
//! widening the parent crate's public API.
//!
//! Property under test: `parse_extensions` must never panic, abort,
//! over-read, or unboundedly allocate when fed arbitrary bytes. The
//! happy path returns `Ok(Vec<RawExt>)`; every malformed input must
//! fall into a typed `NtpError` arm (`TruncatedExtension`,
//! `InvalidExtensionLength`, etc.). Both outcomes are acceptable and
//! discarded — the harness asserts only the absence of panics /
//! sanitizer trips, which libfuzzer detects directly.
//!
//! Seed corpus (`corpus/parse_extensions/`, committed):
//!
//! - `ntpd-rs-truncated-extension-header` (2 bytes): truncated EF
//!   header from `ntpd-rs ntp-proto/src/packet/mod.rs::test_undersized_ef`
//!   (v1.7.2). Pins the `bytes.len() - pos < EXT_HEADER_LEN` arm.
//! - `ntpd-rs-undersized-nonce` (29 bytes): EF whose nonce-length
//!   declares more bytes than remain in the EF body.
//! - `ntpd-rs-undersized-encryption-ef` (32 bytes): encrypted EF
//!   whose inner padding / nonce arithmetic underflows.
//!
//! All three are minimised reproducers from upstream `ntpd-rs`,
//! ported into the parent crate's static regression suite by PR #45
//! (bd nts-1qb) and re-extracted here as on-disk seed inputs so the
//! coverage-guided fuzzer starts from the corners that previously
//! crashed comparable parsers. The byte sequences themselves are the
//! load-bearing fixtures and must not be edited.
//!
//! Provenance: bd nts-y6y.

#![no_main]

use libfuzzer_sys::fuzz_target;
use nts_rust::__internal_fuzz::parse_extensions;

fuzz_target!(|data: &[u8]| {
    // Discard the `Result`. The only failure mode the harness cares
    // about is a panic / abort / sanitizer trip inside the parser;
    // both `Ok` (well-formed input) and `Err(NtpError::*)` (typed
    // rejection) are valid outcomes.
    let _ = parse_extensions(data);
});

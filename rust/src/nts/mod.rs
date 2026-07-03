// NTS (RFC 8915) protocol layer.
//
// Modules in this directory implement the protocol pieces in isolation so
// each can be unit-tested without touching sockets:
//
// - `records` — sans-IO codec for NTS-KE records (RFC 8915 §4).
// - `ke`      — synchronous NTS-KE handshake driver (rustls + std::net).
// - `aead`    — AES-SIV-CMAC-256 wrapper (RFC 5297, RFC 8915 §5.6).
// - `ntp`     — NTPv4 packet codec with NTS extension fields (RFC 8915 §5).
// - `cookies` — per-host LRU cookie store fed by KE responses and NTP replies.
//
// Phase 1 landed `records` + `ke`.
// Phase 2 added `aead` + `ntp` + `cookies` alongside.
// Phase 3 wires the whole stack through `crate::api::nts`.
//
// `dead_code` stays allowed crate-locally because the API surface only
// consumes a subset of the protocol primitives (e.g. `records::aead::*` IDs
// that aren't currently negotiated, helper accessors on `CookieJar` reserved
// for diagnostics). Removing it would force noisy `#[allow]` per-symbol.

#![allow(dead_code)]

pub mod aead;
pub mod cookies;
pub mod dns;
pub mod ke;
pub mod ntp;
pub mod records;
pub mod trust_state;

// Shared test-only helpers (rec record-builder, fresh_keys, sample_request,
// craft_response{,_with}, craft_unauthenticated_ntsn). Gated so the
// contents are compiled out of release builds: `test` for the unit-test
// consumers, `__internal-fuzz` so `crate::__internal_fuzz` can re-export
// the canned constants (`UID`, `CLIENT_TX`, `S2C`) to the fuzz harnesses
// in `rust/fuzz/` — keeping the harness fixed inputs pinned to the same
// source of truth the committed authenticated seeds were crafted with
// (bd nts-jzh1 / NTS-67). See bd nts-wzg for the original lift.
#[cfg(any(test, feature = "__internal-fuzz"))]
pub(crate) mod test_helpers;

// `HybridVerifier` runs on Android in production (it salvages NTS-KE
// handshakes against servers whose Let's Encrypt R12 leaves omit the
// OCSP responder URL — the platform `PKIXRevocationChecker` rejects
// those as `Revoked` even though they're valid). The module is
// compiled on every platform so its `KeTrustMode`-gating contract
// can be unit-tested in the host-platform CI run; only the
// Android-only `build_with_native_verifier_android` call site in
// `ke.rs` actually instantiates one in production.
pub mod hybrid_verifier;

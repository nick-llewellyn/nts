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
// Phase 1 (`trusted_time-6a6`) landed `records` + `ke`.
// Phase 2 (`trusted_time-rp1`) added `aead` + `ntp` + `cookies` alongside.
// Phase 3 (`trusted_time-4lb`) wires the whole stack through `crate::api::nts`.
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

// Android-only: see `hybrid_verifier::HybridVerifier`. Salvages NTS-KE
// handshakes against servers whose Let's Encrypt R12 leaves omit the
// OCSP responder URL — the platform `PKIXRevocationChecker` rejects
// those as `Revoked` even though they're valid.
#[cfg(target_os = "android")]
pub mod hybrid_verifier;

# Architecture

Internal layering of the `nts` package. This document is for contributors
and integrators who want to understand how the Dart surface, the FFI
bridge, and the Rust crate fit together. Day-to-day API users only need
the [README](README.md).

## Layering

The Dart side is intentionally thin. All cryptographic work lives in a
Rust crate that implements the protocol directly across `records.rs`
(NTS-KE wire format), `ke.rs` (TLS 1.3 + ALPN handshake driver),
`aead.rs` (SIV-CMAC / GCM-SIV authenticators), `ntp.rs` (AEAD-protected
NTPv4 packets), `cookies.rs` (cookie jar), and `hybrid_verifier.rs`
(Android trust-store fallback). It is bridged to Dart through
`flutter_rust_bridge` and bundled via the stable Native Assets API
(`hook/build.dart`), so no manual `cargo` invocation is required from
consumers.

```
Dart  : ntsQuery() / ntsWarmCookies()
        └─ FRB stub
Rust  : nts_query()
        ├─ NTS-KE handshake (rustls, TLS 1.3, ALPN ntske/1, port 4460)
        ├─ AEAD-protected NTPv4 over UDP/123 (AES-SIV-CMAC-256)
        └─ Cookie store (RAM, optional persisted blob)
```

## Repository layout

| Path | Role |
|------|------|
| `lib/nts.dart` | Public Dart API; re-exports the FRB-generated surface. |
| `lib/src/ffi/` | Generated `flutter_rust_bridge` bindings — do not edit by hand. |
| `rust/src/api/` | Rust entry points exposed through FRB (`nts.rs`, `simple.rs`). |
| `rust/src/` | Protocol implementation (records, KE driver, AEAD, NTP, cookies). |
| `hook/build.dart` | Native Assets build hook; invokes `cargo build` for the active target. |
| `tool/check_bindings.dart` | CI drift check for generated bindings. |
| `example/` | Showcase apps (Flutter GUI + Dart CLI) and `example/main.dart`. |

See [DEVELOPMENT.md](DEVELOPMENT.md) for the toolchain, codegen, and
verbose-logging workflows.

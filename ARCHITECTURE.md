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
NTPv4 packets), `cookies.rs` (cookie jar), `dns.rs` (bounded resolver
shared by the KE TCP and NTPv4 UDP paths), and `hybrid_verifier.rs`
(Android trust-store fallback). It is bridged to Dart through
`flutter_rust_bridge` and bundled via the stable Native Assets API
(`hook/build.dart`), so no manual `cargo` invocation is required from
consumers.

```
Dart  : ntsQuery() / ntsWarmCookies()
        └─ FRB stub  (timeoutMs, dnsConcurrencyCap)
Rust  : nts_query()
        ├─ Bounded DNS resolver (timeout-respecting, configurable cap, default 4)
        ├─ NTS-KE handshake (rustls, TLS 1.3, ALPN ntske/1, port 4460)
        ├─ AEAD-protected NTPv4 over UDP/123 (AES-SIV-CMAC-256)
        └─ Cookie store (RAM, optional persisted blob)
```

## Timeout budget and bounded DNS

`timeoutMs` is treated as a single wall-clock budget anchored at the
start of each `nts_query` invocation, not as a per-phase timer. Two
private newtypes carry the resulting deadline through the blocking
I/O paths:

- `nts::ke::Deadline` (TCP) wraps an `Instant` and exposes
  `remaining()` plus `apply_to(&TcpStream)`. `perform_handshake`
  builds one `Deadline` at the top of the call and threads it through
  DNS resolution, TCP connect, post-connect socket-timeout setup,
  pre-write/pre-flush refreshes, and the read loop. The KE-side
  reader (`read_to_end_capped`) refreshes the underlying socket's
  read/write timeouts on every iteration so a server that drip-feeds
  the NTS-KE response cannot stretch the read phase past the global
  deadline.
- `api::nts::UdpDeadline` mirrors the helper for `UdpSocket` with a
  `remaining_or_timeout()` accessor that short-circuits to
  `NtsError::Timeout` once the budget is exhausted (rather than
  feeding `Duration::ZERO` into `set_read_timeout`, which is `EINVAL`
  on some platforms). `bind_connected_udp_using` anchors one
  `UdpDeadline` and threads it through DNS resolution and the UDP
  socket-timeout setup so the downstream `socket.send` / `socket.recv`
  in `nts_query` trip no later than the global deadline.

`nts::dns` provides the resolver shared by both paths. It offloads
`getaddrinfo` to a detached worker and bounds the wait via
`mpsc::Receiver::recv_timeout`, returning `io::ErrorKind::TimedOut`
once the remaining budget is exhausted. A global atomic counter caps
in-flight resolver workers; cap exhaustion surfaces as
`io::ErrorKind::WouldBlock` from the resolver entry point and is
mapped to `NtsError::Timeout` at both KE and UDP call sites. The
detached-worker pattern intentionally leaks the OS thread on timeout
because `getaddrinfo` is not cancellable on any major libc — the cap
bounds the steady-state cost under pathological conditions.

The cap is **configurable per call** via the `dnsConcurrencyCap` FFI
parameter on `ntsQuery` / `ntsWarmCookies`. Passing `0` selects the
built-in default of **4**, sized for mobile (worst case ~512 KB-1 MB
of pthread stack per leaked worker on iOS/Android). Server-side
callers that legitimately need higher fan-out can pass a larger cap
per invocation. Because the threshold compares against a single
process-wide counter, two concurrent callers passing different caps
share the same in-flight pool: the effective ceiling at any moment is
whichever caller is currently being admitted, not a private quota.
Saturation in either path returns `NtsError::Timeout` so callers see a
single uniform "would-block / try-later" signal rather than having to
distinguish DNS-pool exhaustion from a true `getaddrinfo` stall.

## Repository layout

| Path | Role |
|------|------|
| `lib/nts.dart` | Public Dart API; re-exports the FRB-generated surface. |
| `lib/src/ffi/` | Generated `flutter_rust_bridge` bindings — do not edit by hand. |
| `rust/src/api/` | Rust entry points exposed through FRB (`nts.rs`, `simple.rs`). |
| `rust/src/nts/` | Protocol implementation (records, KE driver, AEAD, NTP, cookies, bounded DNS). |
| `hook/build.dart` | Native Assets build hook; invokes `cargo build` for the active target. |
| `tool/check_bindings.dart` | CI drift check for generated bindings. |
| `example/` | Showcase apps (Flutter GUI + Dart CLI) and `example/main.dart`. |

See [DEVELOPMENT.md](DEVELOPMENT.md) for the toolchain, codegen, and
verbose-logging workflows.

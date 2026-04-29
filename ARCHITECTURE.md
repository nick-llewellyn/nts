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
per invocation. Because admission is gated against a single
process-wide counter, every admitted worker counts toward every
caller's threshold. Each call's admission is decided by comparing the
live pool size against that call's own cap, with no awareness of which
caller's workers already occupy the pool. A small-cap caller can
therefore be refused when the pool is filled by a larger-cap caller,
even though it has used none of its own headroom; the reverse cannot
happen, since a small-cap caller's workers are themselves bounded by
the small cap. Saturation in either path returns `NtsError::Timeout`
so callers see a single uniform "would-block / try-later" signal
rather than having to distinguish DNS-pool exhaustion from a true
`getaddrinfo` stall.

The synchronous `ntsDnsPoolStats()` entry point exposes four
process-wide counters from the resolver pool — `inFlight`,
`highWaterMark`, `recovered`, and `refused` — so operators can
distinguish, *outside* the hot-path error contract, the three failure
modes that all collapse onto `NtsError::Timeout`. The snapshot is
backed by relaxed-atomic loads (cheap enough to call from a UI poll
loop) and does not reset cumulative counters; windowed measurements
are obtained by snapshotting at `t0` and `t1` and subtracting.
`recovered` climbing alongside a non-zero `inFlight` is the signature
of "libc is timing out internally as expected"; flat `recovered` with
`inFlight == cap` and `refused` climbing is the saturation signature
operators should alert on (the system resolver is wedged and raising
the cap would only push more threads into the same wedge).

## Public API stability layer

`lib/nts.dart` is the package's stable public contract. It is a thin,
hand-written file that re-exports a wrapper layer in
`lib/src/api/nts.dart` plus the bridge bootstrap (`RustLib`). The
underlying FRB-generated bindings in `lib/src/ffi/` are an internal
implementation detail.

The wrapper exists to absorb an asymmetry in `flutter_rust_bridge` v2
codegen: every Rust `pub fn` argument is emitted as a `required` named
parameter on the Dart side, with no support for optional / defaulted
parameters. Without an intermediate layer, every internal Rust-side
signature change — even a strict superset like adding a new optional
knob — would propagate as a source-level break for every consumer
(see the 1.2.0 release notes for the concrete `dnsConcurrencyCap`
episode that motivated the refactor). The wrapper interprets the FRB
contract on behalf of the consumer and exposes idiomatic Dart
signatures with named optional parameters and defaults
(`kDefaultTimeoutMs`, `kDefaultDnsConcurrencyCap`); future Rust-side
additions land as new optional arguments with package defaults that
preserve the pre-existing behaviour, so they no longer require a
SemVer event.

The deprecation policy for future Rust-side removals is symmetric:
when an underlying Rust parameter is dropped, the corresponding Dart
parameter survives in the wrapper as a deprecated no-op for at least
one minor release before being removed at the next major bump. This
gives consumers a window to migrate without a breaking change.

The split between `lib/src/api/` (hand-written, stable) and
`lib/src/ffi/` (generated, regenerable) also pins the contract for
contributors: Rust signature changes that don't appear in
`lib/src/api/` are by definition non-public and free to land at any
release type.

## Repository layout

| Path | Role |
|------|------|
| `lib/nts.dart` | Public Dart API; explicit re-export of the stability-layer wrapper plus `RustLib`. |
| `lib/src/api/` | Hand-written Dart wrapper around the FFI surface. The package's stable contract; carries the consumer-facing dartdoc. |
| `lib/src/ffi/` | Generated `flutter_rust_bridge` bindings — do not edit by hand. Internal implementation detail. |
| `rust/src/api/` | Rust entry points exposed through FRB (`nts.rs`, `simple.rs`). |
| `rust/src/nts/` | Protocol implementation (records, KE driver, AEAD, NTP, cookies, bounded DNS). |
| `hook/build.dart` | Native Assets build hook; invokes `cargo build` for the active target. |
| `tool/check_bindings.dart` | CI drift check for generated bindings. |
| `example/` | Showcase apps (Flutter GUI + Dart CLI) and `example/main.dart`. |

See [DEVELOPMENT.md](DEVELOPMENT.md) for the toolchain, codegen, and
verbose-logging workflows.

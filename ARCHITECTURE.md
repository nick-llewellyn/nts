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

## Why the Rust core: RFC 8915 §4.3 and the TLS exporter gap

The package has a Rust core because RFC 8915 §4.3 mandates that the
C2S and S2C AEAD keys be derived from the live TLS 1.3 session via
the keying-material exporter (RFC 5705, profiled for TLS 1.3 by
RFC 8446 §7.5), and `dart:io.SecureSocket` does not expose that
exporter to Dart code. This is not a performance preference or a
historical artefact: a pure-Dart implementation on top of `dart:io`
cannot produce keys that an RFC-conformant NTPv4-NTS server will
accept. The constraint shapes every other layering decision in the
project, so it is recorded here adjacent to the rest of the
architectural reasoning rather than deferred to a sibling document.

The seven load-bearing observations:

1. **RFC 8915 §5.1 fixes the exporter inputs.** C2S and S2C keys
   are produced by calling the TLS 1.3 keying-material exporter
   with label `"EXPORTER-network-time-security"` and a five-octet
   context `[0x00, 0x00, aead_hi, aead_lo, direction]` where
   `direction` is `0x00` for C2S and `0x01` for S2C. The output
   length is determined by the negotiated AEAD (32 octets for
   AES-SIV-CMAC-256). Our derivation is pinned by
   `rust/src/nts/ke.rs::EXPORTER_LABEL` and the
   `exporter_context(aead_id, s2c)` helper, with the
   `exporter_context_matches_rfc_8915` regression test asserting
   the byte layout against worked examples for the supported IANA
   AEAD IDs.

2. **The exporter is the only legitimate source of these keys.**
   TLS 1.3's `exporter_master_secret` (RFC 8446 §7.5) is derived
   inside the TLS state machine from the handshake transcript and
   never appears on the wire. Reproducing the exporter output
   without access to that secret is a TLS-1.3 break, not an
   engineering shortcut. The threat model RFC 8915 §3 invokes —
   that passive observers cannot mint authenticated NTPv4 packets —
   collapses if the keys come from anywhere else.

3. **`dart:io.SecureSocket` does not surface the exporter.** The
   underlying TLS implementations all support it: BoringSSL's
   `SSL_export_keying_material` (Android NDK / Linux / Windows),
   the JVM's `SSLSession.exportKeyingMaterial` (JDK 12+,
   accessible from Conscrypt-backed Android sockets), and Apple's
   `sec_protocol_metadata_create_secret` (Network framework). None
   of the three is exposed through Dart's `SecureSocket` /
   `RawSecureSocket` API; as of this writing no shipped Dart SDK
   has a `SecureSocket.exportKeyingMaterial(...)` method. This is
   a `dart:io` API gap, not a platform-TLS limitation.

4. **`package:cryptography` cannot bridge the gap.** It supplies
   pure-Dart AEAD / KDF / hash primitives but does not implement
   TLS, has no concept of a TLS session, and cannot reach into
   `dart:io`'s underlying TLS state to retrieve exporter bytes.
   Once exporter output exists it could in principle perform the
   AEAD work above the protocol layer, but the keys must come
   from the TLS session first.

5. **`rustls::ClientConnection::export_keying_material` is the
   first-class entry point.** `rustls` exposes RFC 5705 directly
   on the live connection. After `validate_response` accepts the
   server's NTS-KE record list, `perform_handshake`
   (`rust/src/nts/ke.rs`) calls the exporter twice — once per
   direction — and wraps both results in `Zeroizing<Vec<u8>>` on
   receipt so an early `?` between the call and the final
   `KeOutcome` cannot leak secret bytes back to the heap with
   their contents intact:

   ```rust
   let c2s_key = Zeroizing::new(
       conn.export_keying_material(vec![0u8; key_len], EXPORTER_LABEL, Some(&c2s_ctx))
           .map_err(KeError::from)
           .map_err(attribute)?,
   );
   let s2c_key = Zeroizing::new(
       conn.export_keying_material(vec![0u8; key_len], EXPORTER_LABEL, Some(&s2c_ctx))
           .map_err(KeError::from)
           .map_err(attribute)?,
   );
   ```

   The two `Vec<u8>` outputs cross the FFI boundary into
   `rust/src/api/nts.rs::establish_session`, which converts them
   to in-process `AeadKey` handles and discards the raw
   allocations.

6. **The three non-options.**
   - **Pure-Dart NTS on `dart:io`.** Cannot derive RFC-compliant
     keys; conformant servers will reject every authenticated
     NTPv4 packet, and a server that accepts non-exporter keys
     offers no cryptographic guarantee in the first place. Not
     NTS in any meaningful sense.
   - **Pure-Dart TLS 1.3.** Possible in principle, an order of
     magnitude more work than the rest of the package combined,
     and carries adversarial-review obligations (Bleichenbacher,
     Lucky-13, padding-oracle, timing-side-channel) that a small
     maintainer team cannot reasonably meet.
   - **Wait for `dart:io` to expose the exporter.** The right
     long-term answer; no shipped timeline; would still require
     every supported Dart SDK version to land it before the Rust
     core could be removed.

7. **Where this draws the Rust-vs-Dart boundary.** The Rust crate
   covers TLS 1.3, the exporter, and everything below. The
   protocol layers *above* the exporter — the NTS-KE record codec
   (`rust/src/nts/records.rs`), the AEAD-protected NTPv4 wire
   format (`rust/src/nts/ntp.rs`), the cookie jar
   (`rust/src/nts/cookies.rs`), KoD handling, and replay
   protection — are in Rust today because they live next to the
   layer that *has* to be Rust. If `dart:io` ever exposes the
   exporter, the layers above it could in principle be ported to
   Dart on top of `package:cryptography`, shrinking the Rust
   surface to just the TLS + exporter shim. Until then, the
   architecture is shaped by the API surface available, not by a
   Rust preference.

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

## Phase attribution and timings

The shared deadline accounts for *when* a budget elapses but not for
*which step inside the call* consumed it. `NtsError::Timeout` and
`NtsTimeSample` close that gap by carrying a per-phase tag on the
failure side and a microsecond-resolution wall-clock breakdown on the
success side, so a caller diagnosing a slow or refused query can
distinguish DNS saturation from a slow record exchange without
inspecting free-form diagnostic strings.

`TimeoutPhase` is the failure-side surface. It tags the
single-payload `NtsError::Timeout(TimeoutPhase)` with one of
`DnsSaturation`, `DnsTimeout`, `Connect`, `Tls`, `KeRecordIo`, or
`Ntp`. The two `Dns*` variants intentionally split the bounded
resolver pool's two refusal modes — `DnsSaturation` is the
`io::ErrorKind::WouldBlock` path published by `try_acquire_slot`
(cap reached, no worker dispatched) and points operators at
raising `dns_concurrency_cap`, whereas `DnsTimeout` is the
`recv_timeout` shape (worker dispatched, resolver slow) and points
operators at lengthening `timeout_ms` or replacing the recursive
resolver. `Connect`, `Tls`, and `KeRecordIo` correspond one-for-one
with the three blocking phases inside `perform_handshake` — the
per-address `connect_timeout` loop, the rustls `Stream::write_all` /
`flush` window (which in TLS 1.3 contains the
ClientHello/ServerHello/Finished round-trip), and the chunked record
read loop. `Ntp` is added at the `api/nts.rs` layer for the
AEAD-NTPv4 UDP `send` / `recv` round-trip; the KE pipeline never
reaches it. Mapping to a phase happens at the I/O boundary inside
`nts::ke` (via `dns_error_to_ke`, `connect_error_to_ke`, and
`phase_io_to_ke`) and the `From<KeError> for NtsError` conversion,
so deeper callers do not need to know about the taxonomy.

`PhaseTimings` is the success-side surface, exposed on
`NtsTimeSample::phase_timings` and `NtsWarmCookiesOutcome::phase_timings`.
Four `i64` microsecond fields cover the pre-NTP phases —
`dns_micros`, `connect_micros`, `tls_handshake_micros`,
`ke_record_io_micros`. The UDP send/recv phase has no field of its
own because the existing `NtsTimeSample::round_trip_micros` already
covers it; publishing the same fact twice would be a documentation
hazard, so the doc on `round_trip_micros` calls out that it *is*
the UDP-phase wall-clock cost. `dns_micros` is summed across both
the KE-host lookup (when a handshake runs) and the NTPv4-host
lookup, because callers diagnosing slow DNS care about the
host-level cost regardless of which leg consumed it. Phases that
did not run in this call are reported as `0` rather than absent —
e.g. on a cache-hit query (no KE handshake), `connect_micros`,
`tls_handshake_micros`, and `ke_record_io_micros` are all zero and
`dns_micros` reflects only the UDP-path lookup.

A caller who wants the same "preNtp" view earlier integrators
constructed from a Dart-side `Stopwatch` can sum the four
`PhaseTimings` fields; the per-call total wall-clock is that sum
plus `round_trip_micros`. The breakdown does not need to add up
exactly to the externally-observed wall-clock — `Instant::elapsed`
boundaries are sampled inline with the phases they bracket and a
few microseconds of inter-phase bookkeeping fall outside any
field — but the discrepancy is bounded by call-site overhead, not
by hidden I/O.

## Session ownership and the `NtsClient` handle

Per-host session state — the negotiated AEAD keys, NTPv4 destination,
and cookie jar handed back by an NTS-KE handshake — lives in a
`SessionTable` keyed by `host:port`. The table is the only persistent
state the bridge maintains; everything else is derived from it on
demand.

Two ways to own a `SessionTable`:

1. **Process-wide default.** The top-level convenience entry points
   (`nts_query` / `nts_warm_cookies` on the Rust side, `ntsQuery` /
   `ntsWarmCookies` on the Dart side) delegate to a singleton
   `NtsClient` initialised lazily via `OnceLock`, whose `SessionTable`
   is shared by every caller in the process. This is the historical
   shape (1.x / 2.x) and remains the recommended default for apps
   with one steady set of NTS servers.
2. **Owned `NtsClient`.** Construct an explicit `NtsClient` (Rust:
   `NtsClient::new()`; Dart: `NtsClient()`) to mint a fresh client
   whose `SessionTable` is empty and shares no state with the default
   client or with any other `NtsClient`. The handle exposes the same
   `query` / `warm_cookies` operations plus `invalidate(spec)`
   (drops one cached session, returns `bool`) and `clear()` (drops
   every cached session).

Use cases for the per-instance shape:

- Test isolation, so one test's cached sessions cannot bleed into
  another's. Pre-3.1, the only escape was a fresh process.
- Diagnostics tools that want to force a fresh NTS-KE handshake on
  demand (`invalidate(spec)` followed by the next `query` / `warm`
  triggers a re-handshake).
- Apps that want a clear scope-bounded lifetime for cached
  sessions, e.g. discarding the cache between work batches via
  `clear()` rather than letting it grow unboundedly across the
  process lifetime.

Internally, the per-client and process-wide-default code paths
share their bodies through internal `*_inner` helpers parameterised
on `&SessionTable`, so a behaviour change to the cache layer
applies to both surfaces without duplication. The `SessionTable`
itself is `pub(crate)` and FRB-ignored — Dart only ever sees
`NtsClient`.

## Singleflight: collapsing concurrent cold queries

Each `SessionTable` carries a per-key singleflight registry
(`inflight: Mutex<HashMap<String, Arc<HandshakeSlot>>>`) alongside
the session map. The registry guarantees that concurrent
`SessionTable::checkout` calls against the same `host:port` collapse
onto exactly one in-flight `establish_session` call rather than
each running their own duplicate KE handshake.

The role-election loop in `checkout_with` runs three phases per
iteration:

1. **Cache hit (`map` lock briefly).** If the table holds a session
   for `host:port` with at least one cookie remaining, pop a cookie
   and return immediately. The `map` lock is dropped before any
   singleflight bookkeeping so a slow leader on another key cannot
   serialise unrelated cache hits behind itself.
2. **Leader-or-waiter election (`inflight` lock briefly).** Insert
   a fresh `Arc<HandshakeSlot>` keyed by `host:port` to become the
   leader; on a colliding key, clone the existing slot and become a
   waiter. The `map` and `inflight` mutexes are deliberately *not*
   held simultaneously to avoid lock-order discipline.
3. **Lock-free body.** The leader runs `establish_session` with no
   locks held, then re-takes `map` to install the session, then
   re-takes `inflight` (via the `LeaderGuard` RAII handle) to
   remove the slot and signal waiters. Waiters park on the slot's
   `Condvar` bounded by their own per-call wall-clock budget; on
   wake they loop back to phase 1 and pop a cookie of their own.

Three invariants make the loop converge:

- **Bounded cookie pool.** A successful KE handshake delivers
  `~POOL_SIZE` cookies (typically 8 per RFC 8915 §6); if `N > POOL_SIZE`
  waiters wake against a freshly installed session, `N - POOL_SIZE`
  fall through to phase 2 and elect a new leader for the next
  handshake. Worst case is `ceil(N / POOL_SIZE)` handshake rounds,
  not infinite.
- **Refuse-to-install-empty.** A handshake that delivers zero
  cookies returns `NtsError::NoCookies` immediately to the leader
  *and* propagates the same error to every waiter — never installs
  a useless session that would force the next round of leaders to
  loop on the same outcome.
- **Per-call deadline.** Waiters anchor their deadline at
  `started + timeout` where `started` is captured at the top of
  the calling `checkout_with`; a leader that runs longer than a
  given waiter's caller-budget cannot stretch that waiter's
  wall-clock past its caller's contract. Such a waiter surfaces
  `NtsError::Timeout(TimeoutPhase::KeRecordIo)` (the most accurate
  single bucket for "stuck waiting on a KE handshake we did not
  run ourselves") and returns immediately.

Three things explicitly *not* coalesced:

- **`nts_warm_cookies`** runs its own `establish_session` outside
  the singleflight loop. Its documented contract is "force a fresh
  handshake" and silently coalescing it with an unrelated query's
  handshake would defeat that intent. A concurrent
  `nts_warm_cookies` + `ntsQuery` against the same host therefore
  still races the install, same as pre-3.2; the singleflight does
  not make that race worse.
- **Concurrent queries against different `host:port` keys** keep
  running fully in parallel. The singleflight registry keys off
  `session_key(spec)`, so two distinct keys each elect their own
  leader; the existing "don't serialise unrelated hosts" property
  from pre-3.2 is preserved.
- **Per-`NtsClient` scoping** is preserved end-to-end. The
  singleflight registry lives on `SessionTable`, not globally, so
  two `NtsClient` instances never share leader-election state with
  each other or with the process-wide default client.

`LeaderGuard` is the RAII safety net: even when the leader's
`establish_session` panics or the leader returns early without an
explicit `complete`, the guard's `Drop` removes the inflight slot
and signals waiters with `NtsError::Internal("singleflight leader
aborted before publishing a result")` so they unpark immediately
rather than blocking against a stale slot until their per-call
deadline elapses.

## Trust-anchor diagnostics

TLS chain validation runs against one of three anchor sources, and
the resolution is reported on two axes: per-handshake on the public
DTOs, and process-globally via a snapshot accessor.

The three resolutions (`TrustBackend`):

- **`platform`** — `rustls-platform-verifier` ran against the OS
  trust store (system roots plus user / MDM-installed roots). The
  source of truth for enterprise-managed devices and the only way
  to honour pinned corporate CAs.
- **`platformWithHybridFallback`** — Android-only. The platform
  verifier ran first and rejected the chain, but the rejection
  matched a curated platform-failure shape (e.g. missing-OCSP-AIA
  chains such as Let's Encrypt R12, R8-stripped AAR classes). The
  `webpki-roots` static bundle was then consulted and accepted
  the chain. The decision is made inside `HybridVerifier`
  (`rust/src/nts/hybrid_verifier.rs`); the curated failure shapes
  are documented at the call site there. Indicates the platform
  verifier's view was rejected and the static bundle was
  authoritative for this chain.
- **`webpkiRoots`** — `build_with_native_verifier` failed at
  TLS-config construction time and the static bundle authenticated
  the chain end-to-end. Loses visibility into MDM / user-installed
  roots; works against the major public NTS providers but not
  against corporate TLS-inspection appliances.

The two trust-mode policies (`TrustMode`, set at `NtsClient`
construction):

- **`platformWithFallback`** (default) — pre-3.0 behaviour. If
  `build_with_native_verifier` fails at TLS-config construction,
  fall back silently to the `webpki-roots` static bundle and
  surface the resolution as `TrustBackend::webpkiRoots` on the
  next handshake. No new error variant is reachable.
- **`platformOnly`** — refuses the silent fallback. If
  `build_with_native_verifier` fails at TLS-config construction,
  the handshake is aborted with `NtsError::TrustBackendUnavailable`
  carrying the underlying `rustls::Error` text. Appropriate when
  a pinned corporate CA or MDM-installed root is the load-bearing
  trust anchor and a silent downgrade to the public-CA bundle
  would defeat the deployment intent. The Android hybrid-fallback
  path inside `HybridVerifier` is **not** affected by `TrustMode`:
  it is a per-chain, per-failure-shape decision made after the
  platform verifier returns, not a build-time fallback.

Per-handshake reporting:

- `NtsTimeSample.trustBackend` and `NtsWarmCookiesOutcome.trustBackend`
  carry the resolution that authenticated this handshake's chain.
- On the cached-session fast path the field reflects the
  *original* handshake's resolution (cached on the underlying
  `Session`), so callers always see a concrete per-query
  attribution rather than a placeholder for cached queries.
  `nts_warm_cookies` always runs a fresh handshake, so its
  outcome's value is always the just-completed resolution.

Process-global snapshot (`nts_trust_status() -> NtsTrustStatus`):

- `defaultClientBackend` — the trust backend the *default
  singleton* `NtsClient` last observed. `null` until that client
  performs its first handshake. Caller-minted `NtsClient`
  instances are intentionally not reflected here; the snapshot is
  for callers using the top-level convenience functions.
- `androidPlatformInitSucceeded` — `true` once
  `Java_com_nllewellyn_nts_PlatformInit_nativeInit` has been
  invoked at least once and reported success. `false` on every
  other platform (no JNI bootstrap step exists). A `false` value
  on Android implies subsequent handshakes will run against the
  static bundle regardless of `TrustMode`.
- `androidHybridFallbackCount` — cumulative count of TLS chains
  the Android `HybridVerifier` has accepted via the `webpki-roots`
  fallback path since process start. Always zero on non-Android
  platforms. Non-zero on Android indicates at least one chain
  arrived whose only platform-side failure was a curated
  fallback-eligible shape.

State tracking lives in `rust/src/nts/trust_state.rs` behind
`Relaxed` atomics. The snapshot is intended for human / dashboard
consumption, not for cross-thread happens-before ordering
decisions; reads are wait-free.

## Public API stability layer

`lib/nts.dart` is the package's stable public contract. It is a thin,
hand-written file that re-exports a wrapper layer in
`lib/src/api/nts.dart` plus the bridge bootstrap (`RustLib`). The
underlying FRB-generated bindings in `lib/src/ffi/` are an internal
implementation detail.

The wrapper has three jobs:

1. **Function signatures** — `flutter_rust_bridge` v2 codegen emits
   every Rust `pub fn` argument as a `required` named parameter on
   the Dart side, with no support for optional / defaulted
   parameters. Without an intermediate layer, every internal
   Rust-side signature change — even a strict superset like adding a
   new optional knob — would propagate as a source-level break for
   every consumer (see the 1.2.0 release notes for the concrete
   `dnsConcurrencyCap` episode that motivated the refactor). The
   wrapper exposes idiomatic Dart signatures with named optional
   parameters and defaults (`kDefaultTimeoutMs`,
   `kDefaultDnsConcurrencyCap`); future Rust-side additions land as
   new optional arguments with package defaults that preserve
   pre-existing behaviour.
2. **DTOs** — `lib/src/api/models.dart` hand-writes the public DTOs
   (`NtsServerSpec`, `NtsTimeSample`, `NtsWarmCookiesOutcome`,
   `NtsDnsPoolStats`, `PhaseTimings`) with plain Dart `int` fields
   instead of FRB's `PlatformInt64` wrapper. The wrapper converts
   from the FFI shapes at the call boundary. A Rust-side struct
   field rename or reorder no longer becomes a Dart source break for
   downstream callers; it surfaces as a compile error in the
   conversion layer instead.
3. **Errors** — `lib/src/api/errors.dart` hand-writes `NtsError` as a
   Dart 3 `sealed class implements Exception` with eight final
   variant subclasses (`NtsErrorInvalidSpec`, `NtsErrorNetwork`, …)
   and the `TimeoutPhase` enum. The wrapper catches the FFI-side
   `NtsError` and rethrows the public twin via an exhaustive
   conversion `switch`, so the FFI's freezed-generated shape is
   contained at the boundary. The pre-3.0 underscore-prefixed
   variant names (`NtsError_InvalidSpec`, …) survive as
   `@Deprecated` typedef aliases for one release; they are scheduled
   for removal at 4.0.

The deprecation policy for future Rust-side removals is symmetric:
when an underlying Rust parameter or field is dropped, its public
Dart counterpart survives in the wrapper as a deprecated no-op for
at least one minor release before being removed at the next major
bump. This gives consumers a window to migrate without a breaking
change.

The split between `lib/src/api/` (hand-written, stable) and
`lib/src/ffi/` (generated, regenerable) also pins the contract for
contributors: Rust signature changes that don't surface in
`lib/src/api/` are by definition non-public and free to land at any
release type.

## Repository layout

| Path | Role |
|------|------|
| `lib/nts.dart` | Public Dart API; explicit re-export of the stability-layer wrapper plus `RustLib`. |
| `lib/src/api/nts.dart` | Hand-written wrapper functions plus the FFI↔public conversion layer. Carries the consumer-facing dartdoc on the entry points. |
| `lib/src/api/models.dart` | Hand-written public DTOs (`NtsServerSpec`, `NtsTimeSample`, `NtsWarmCookiesOutcome`, `NtsDnsPoolStats`, `PhaseTimings`). |
| `lib/src/api/errors.dart` | Hand-written public `NtsError` sealed class plus `TimeoutPhase`; deprecated underscore-prefixed typedef aliases for the pre-3.0 variant names live at the bottom. |
| `lib/src/ffi/` | Generated `flutter_rust_bridge` bindings — do not edit by hand. Internal implementation detail. |
| `rust/src/api/` | Rust entry points exposed through FRB (`nts.rs`, `simple.rs`). |
| `rust/src/nts/` | Protocol implementation (records, KE driver, AEAD, NTP, cookies, bounded DNS). |
| `hook/build.dart` | Native Assets build hook; invokes `cargo build` for the active target. |
| `tool/check_bindings.dart` | CI drift check for generated bindings. |
| `example/` | Showcase apps (Flutter GUI + Dart CLI) and `example/main.dart`. |

See [DEVELOPMENT.md](DEVELOPMENT.md) for the toolchain, codegen, and
verbose-logging workflows.

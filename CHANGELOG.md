# Changelog

## 1.3.1

Documentation-only patch on the 1.3.0 observability surface. No code,
FFI, or runtime behaviour changes; the Rust crate `nts_rust` is
unchanged at `0.2.2`.

### `NtsDnsPoolStats` — acknowledge `inFlight > highWaterMark` transient

- Tighten the dartdoc on `ntsDnsPoolStats` (`lib/src/api/nts.dart`)
  and the mirrored Rust docstring on `NtsDnsPoolStats` plus its
  `high_water_mark` field (`rust/src/api/nts.rs`). The 1.3.0 wording
  ("Monotonically non-decreasing for the lifetime of the process",
  "racy by construction… never logically impossible") invited the
  strict reading that `highWaterMark >= inFlight` holds at every
  observation point. It does not: `try_acquire_slot` performs the
  `fetch_add` on `in_flight` and the `fetch_max` on `high_water_mark`
  as two independent atomic operations, so a concurrent
  `pool_snapshot()` can observe `inFlight = prev + 1` and
  `highWaterMark = prev` for the few-nanosecond window between them.
  The replacement wording calls this transient out by name and
  restates the actual guarantee — per-counter monotonicity across
  consecutive snapshots, not a cross-counter invariant within a
  single snapshot.
- Rationale for documenting rather than patching `snapshot_of` to
  return `max(in_flight, high_water_mark)`: the two `Relaxed` loads
  in the snapshot path are not atomic together, so a derived `max()`
  suppresses one common observation but does not produce a coherent
  point-in-time view; closing the race in the increment path
  requires a CAS loop on a packed `(in_flight, hwm)` tuple, which is
  not justified by an observable-only-via-snapshot diagnostic
  counter; and the three operator-facing failure-mode signatures
  (healthy / cap-bound / libc wedge — see the rest of the dartdoc)
  reason about per-counter trajectories across consecutive
  snapshots, not single-snapshot cross-counter invariants. The
  transient does not degrade their diagnostic value.
- The generated FFI dartdoc in `lib/src/ffi/api/nts.dart` is
  regenerated from the Rust source and tracks the new wording. No
  other diff in the FRB-generated layer.

## 1.3.0

Public-API stability layer, bounded DNS resolver pool observability,
and a documentation correction in the Rust core. Strictly additive on
the Dart surface: existing call sites (including
`test/ffi_smoke_test.dart` and the example app, GUI, and CLI) keep
their current arguments and continue to compile. The Rust crate
`nts_rust` is unchanged at `0.2.2`.

### Public API stability layer (`lib/src/api/nts.dart`, new)

- Introduce a hand-written wrapper in `lib/src/api/nts.dart` that
  becomes the package's stable public surface. The wrapper exposes
  `ntsQuery` and `ntsWarmCookies` with idiomatic Dart optional named
  parameters (`timeoutMs`, `dnsConcurrencyCap`) and package defaults
  (`kDefaultTimeoutMs = 5000`, `kDefaultDnsConcurrencyCap = 0`),
  forwarding to the FRB-generated bindings for the actual FFI call.
  `await ntsQuery(spec: spec)` (no other arguments) now compiles and
  produces the same behaviour as 1.2.0's
  `ntsQuery(spec: spec, timeoutMs: 5000, dnsConcurrencyCap: 0)`.
- Rewrite `lib/nts.dart` as an explicit re-export of the wrapper plus
  the bridge bootstrap (`RustLib`). The blanket re-export of
  `lib/src/ffi/api/nts.dart` (and the `greet` toolchain helper from
  `lib/src/ffi/api/simple.dart`) is removed; the FFI surface is now an
  internal implementation detail. Consumers' call sites are unchanged
  because the wrapper exposes the same names with compatible
  signatures.
- Motivation: `flutter_rust_bridge` v2 codegen emits every Rust `pub
  fn` argument as a `required` named parameter on the Dart side, with
  no FRB attribute today that maps it to an optional Dart parameter
  with a default. Absorbing that asymmetry in a hand-written layer
  decouples the public contract from the FFI contract — internal Rust
  signature evolution (extra knobs, struct field churn, lint-pin
  regen) no longer propagates as breaking call-site edits for every
  downstream consumer. The 1.2.0 release was the concrete episode
  that motivated this: adding `dnsConcurrencyCap` was a strict
  superset of the previous behaviour but broke source compatibility
  for every caller because the new parameter landed as `required`.
- The deprecation policy for future Rust-side removals is symmetric:
  parameters dropped from the Rust core survive in the wrapper as
  deprecated no-ops for at least one minor release before being
  removed at the next major. Documented in `ARCHITECTURE.md`'s new
  "Public API stability layer" section.

### Bounded DNS resolver pool observability

- Add `ntsDnsPoolStats()` (synchronous; no future / isolate hop)
  returning a process-wide snapshot of the bounded resolver pool with
  four counters: `inFlight` (live workers currently pinned in the
  system resolver), `highWaterMark` (peak `inFlight` since process
  start, monotonic), `recovered` (cumulative completed workers that
  released their slot), and `refused` (cumulative admission attempts
  rejected because the cap was reached). The function is marked
  `#[frb(sync)]` on the Rust side so reading four atomics does not pay
  the FRB future-marshalling overhead.
- The new struct `NtsDnsPoolStats` lands as part of the wrapper
  layer's public surface alongside `NtsServerSpec` / `NtsTimeSample`.
- Saturation surfaces unchanged on the hot path as `NtsError.timeout`
  (the error contract stays collapsed); the new counters are the
  side-channel that lets operators distinguish a healthy
  oscillating-below-the-cap resolver from a true libc-level wedge.
  The diagnostic shape is documented in dartdoc on
  `ntsDnsPoolStats()` and in `ARCHITECTURE.md`'s "Timeout budget and
  bounded DNS" section.
- Internal refactor in `rust/src/nts/dns.rs`: the previous lone
  `IN_FLIGHT_DNS_LOOKUPS: AtomicUsize` is replaced by a `PoolStats`
  bundle (in-flight + high-water + recovered + refused atomics), so
  `try_acquire_slot` / `SlotGuard::drop` keep the four counters in
  lockstep and the test seam parameterises a per-test bundle the same
  way the previous lone counter was parameterised. The existing
  `resolve_with_global` / `resolve_with_timeout` signatures are
  unchanged; only the internal `resolve_with` seam picks up the new
  type. Memory-ordering rationale for each counter (`Relaxed` for
  cumulative tallies, `AcqRel` for in-flight, `AcqRel` for the HWM
  `fetch_max`) is documented inline.
- Three new Rust unit tests in `nts::dns::tests`:
  - `recovered_increments_on_worker_completion` — the cumulative
    counter bumps exactly once per slot release, after the worker
    returns from the resolver, alongside the in-flight drain.
  - `refused_increments_on_cap_exhaustion` — companion to
    `cap_reached_returns_would_block`; pins the counter delta on
    rejected admissions.
  - `high_water_mark_tracks_concurrent_admissions` — admits N
    workers behind a `Barrier`, asserts the mark catches up to N
    while the slots overlap, then releases and asserts the mark
    stays at N (monotonic, not pinned to the live in-flight count).
- New wrapper-level smoke test (`test/api_smoke_test.dart`) verifies
  `ntsDnsPoolStats()` is a synchronous getter returning an
  `NtsDnsPoolStats` and that the FFI struct's fields are forwarded
  through the wrapper verbatim.

### Documentation

- `rust/src/nts/cookies.rs`: rewrite the `DEFAULT_CAPACITY` doc
  comment. The previous wording claimed the "initial NTS-KE response
  always delivers exactly 8" cookies, which is not mandated by the
  protocol — RFC 8915 §4 leaves the count returned by any given
  server to server policy. The replacement cites RFC 8915 §6 (the
  client-side cap of 8 unused cookies) and notes that the value
  matches what several public deployments (Cloudflare) are observed
  to deliver, with a §4 reference for the server-policy framing. No
  code change; this aligns the internal docs with the
  `example/`-side framing already shipped in 1.1.2 / 1.2.0.
- `README.md`: rewrite the "API summary" table to show the wrapper
  signatures with `=` defaults (`timeoutMs = kDefaultTimeoutMs`,
  `dnsConcurrencyCap = kDefaultDnsConcurrencyCap`), add rows for the
  two `kDefault*` constants, and add a paragraph linking to the new
  ARCHITECTURE.md section. The `dnsConcurrencyCap` prose is updated
  to mention that omitting the parameter (or passing `0`) inherits
  the built-in default.
- `ARCHITECTURE.md`: add a new "Public API stability layer" section
  describing the wrapper, the FRB asymmetry it absorbs, the
  deprecation policy, and the contract split between
  `lib/src/api/` (hand-written, stable) and `lib/src/ffi/`
  (generated, regenerable). Update the repository layout table to
  list the new wrapper directory.

### Examples

- `example/main.dart`: simplify the warm-then-burst flow to use the
  new wrapper defaults (`await ntsWarmCookies(spec: spec)` and `await
  ntsQuery(spec: spec)` instead of threading explicit `timeoutMs:
  5000, dnsConcurrencyCap: 0` through every call). Comment in Phase
  1 documents that the defaults are sourced from `kDefaultTimeoutMs`
  / `kDefaultDnsConcurrencyCap`. `example/example.md`'s fenced
  block stays byte-for-byte identical to `example/main.dart`
  (5310 bytes).
- The Flutter GUI controller (`example/lib/src/state/nts_controller.dart`)
  and the CLI (`example/bin/nts_cli.dart`) continue to thread their
  own configured values explicitly. They are not migrated to the
  defaults pattern in this release; the wrapper accepts both call
  styles.

### Tests

- `test/api_smoke_test.dart` (new): wrapper-level smoke test that
  pins the package defaults (`kDefaultTimeoutMs == 5000`,
  `kDefaultDnsConcurrencyCap == 0`), asserts the wrapper applies
  them when the optional parameters are omitted, verifies that
  explicit overrides (including the `0` sentinel) are forwarded
  verbatim to the FRB layer, and exercises the synchronous
  `ntsDnsPoolStats()` plumbing. Seven test cases.
- `test/ffi_smoke_test.dart`: rewrite the import block. `greet` and
  the FRB-layer `ntsQuery` / `ntsWarmCookies` are now imported
  directly from `package:nts/src/ffi/...` rather than the public
  barrel, so the test continues to exercise the FFI contract
  unchanged while the public barrel stops re-exporting them. The
  five existing test cases are unmodified and still pass.

### Generated bindings

- `lib/src/ffi/api/nts.dart`, `lib/src/ffi/frb_generated.dart`,
  `lib/src/ffi/frb_generated.io.dart`,
  `lib/src/ffi/frb_generated.web.dart`, and
  `rust/src/frb_generated.rs` regenerated via
  `flutter_rust_bridge_codegen generate` (pinned at 2.12.0) to pick
  up the new `NtsDnsPoolStats` struct and the `nts_dns_pool_stats`
  entry point. No drift detected by `tool/check_bindings.dart` after
  the regen + lint-suppression patches.

### Verification

- `fvm flutter analyze`: clean (no issues).
- `fvm flutter test test/api_smoke_test.dart test/ffi_smoke_test.dart`:
  12 / 12 pass.
- `fvm flutter test` (example/): 31 / 31 pass.
- `cargo fmt --check` (in `rust/`): clean.
- `cargo clippy --tests --all-targets -- -D warnings` (in `rust/`):
  clean.
- `cargo test` (in `rust/`): 112 / 112 pass, 3 ignored (live-network).
- `example/main.dart` ↔ `example/example.md` fenced-block
  byte-for-byte parity: 5310 bytes.

## 1.2.0

Reliability and timeout-budget hardening across the Rust core. The public
Dart surface (`ntsQuery`, `ntsWarmCookies`, `NtsServerSpec`,
`NtsTimeSample`, `NtsError`) gains one new optional knob —
`dnsConcurrencyCap` — for tuning the bounded DNS resolver per call;
existing call sites that omit it continue to compile because the
codegen marks the parameter required (pass `0` to inherit the default).
Consumer-visible behaviour also improves on the timeout-fidelity and
DNS-stall paths. Rust crate `nts_rust` is bumped from `0.2.1` to
`0.2.2`; the bindings (`lib/src/ffi/`) are regenerated to reflect the
new parameter.

### Bounded DNS resolution (`rust/src/nts/dns.rs`, new module)

- Replace the unbounded `ToSocketAddrs` lookup that previously fronted
  both NTS-KE TCP connect and the NTPv4 UDP bind with a thread-pool
  resolver that offloads `getaddrinfo` to a detached worker and bounds
  the wait via a `mpsc::Receiver::recv_timeout`. A stalled name server
  no longer holds the calling thread past the caller's `timeoutMs`
  budget; the resolver returns `io::ErrorKind::TimedOut` once the
  remaining budget is exhausted, which the `api::nts` and `nts::ke`
  call sites collapse to `NtsError::Timeout`.
- Add a global atomic concurrency cap on in-flight resolver workers to
  protect the host environment from a runaway burst of `ntsQuery` calls
  against a blackholed DNS server. The cap is **configurable per call**
  via the `dnsConcurrencyCap` parameter on `ntsQuery` /
  `ntsWarmCookies`; passing `0` selects the built-in default of **4**,
  sized for mobile (worst-case ~512 KB-1 MB of pthread stack per leaked
  worker on iOS/Android, capping the steady-state leak from a
  blackholed resolver to ~4 MB instead of unbounded growth).
  Server-side callers that legitimately need higher fan-out can pass a
  larger cap per invocation. Cap exhaustion surfaces as
  `io::ErrorKind::WouldBlock` from the resolver entry point and is
  mapped to `NtsError::Timeout` at both KE and UDP call sites so the
  Dart-side switch arm is reached without introducing a new variant.
- Because the threshold compares against a single process-wide counter,
  two concurrent callers passing different caps share the same
  in-flight pool: the effective ceiling at any moment is set by
  whichever caller is currently being admitted, not a private quota.
- The detached-worker pattern intentionally leaks the OS thread on
  timeout rather than aborting it: `getaddrinfo` is not cancellable on
  any major libc, so attempting to interrupt the worker would corrupt
  the resolver state. The slot cap bounds the steady-state cost of
  this leak under pathological conditions.

### NTS-KE handshake (`rust/src/nts/ke.rs`)

- Introduce a private `Deadline` newtype that anchors a single
  `Instant` at the top of `perform_handshake` and exposes
  `remaining()` (saturating) plus `apply_to(&TcpStream)` (refreshes
  socket read/write timeouts; returns `io::ErrorKind::TimedOut` if the
  budget is exhausted). Replaces the previous pattern where every
  blocking phase — DNS lookup, TCP connect, TLS handshake, NTS-KE
  record I/O — was independently armed with the caller's full
  `timeoutMs`, allowing the total wall-clock cost to overshoot the
  budget by up to ~3x.
- `connect_with_deadline_using<F>` becomes the new core path;
  `connect_with_timeout_using` is retained as a thin
  `Option<Duration> → Option<Deadline>` wrapper that preserves the
  slow-DNS test seam. `perform_handshake` threads one `Deadline`
  through DNS resolution, TCP connect, post-connect socket-timeout
  setup, pre-write/pre-flush refreshes, and the read loop.
- `read_to_end_capped` now takes `Stream<'_, ClientConnection,
  TcpStream>` plus `Option<&Deadline>` and refreshes the underlying
  socket's read/write timeouts on every loop iteration, so a server
  that drip-feeds the NTS-KE response cannot stretch the read phase
  past the global deadline.
- New regression tests:
  - `deadline_remaining_saturates_at_zero_after_expiry`,
  - `deadline_apply_to_returns_timed_out_when_expired`,
  - `deadline_apply_to_sets_socket_timeouts_within_remaining_budget`,
  - `connect_with_deadline_respects_external_deadline_for_unroutable_ip`,
  - `connect_with_timeout_surfaces_slow_dns_as_timed_out`.

### UDP query path (`rust/src/api/nts.rs`)

- Mirror the KE-side helper with a private `UdpDeadline` newtype for
  `UdpSocket`. Surface: `new(Duration)`, `remaining()` (saturating),
  and `remaining_or_timeout() -> Result<Duration, NtsError>` which
  short-circuits to `NtsError::Timeout` once the budget is exhausted
  rather than feeding `Duration::ZERO` into `set_read_timeout` (which
  is `EINVAL` on some platforms).
- `bind_connected_udp_using` rewritten to anchor one `UdpDeadline`,
  invoke `remaining_or_timeout()?` before `resolve_with_global` so the
  resolver receives the live remaining budget rather than the original
  `timeoutMs`, and again before `set_read_timeout`/`set_write_timeout`
  so the UDP socket inherits the *remaining* budget. The downstream
  `socket.send` / `socket.recv` in `nts_query` therefore trip no later
  than the global deadline, even when the KE phase has consumed most
  of it.
- `UdpDeadline` is intentionally a separate type from the KE-side
  `Deadline` because `apply_to` would otherwise need to be
  socket-type-generic; the duplicated surface is ~20 lines.
- New regression tests:
  - `udp_deadline_remaining_or_timeout_after_expiry`,
  - `bind_connected_udp_socket_timeouts_reflect_remaining_budget`,
  - `bind_connected_udp_surfaces_slow_dns_as_timeout`.

### Documentation

- The dartdoc on `ntsQuery` (regenerated into
  `lib/src/ffi/api/nts.dart` from the Rust docstring on
  `crate::api::nts::nts_query`) now states that `timeout_ms` "bounds
  the DNS lookup that precedes each phase so a stalled `getaddrinfo`
  cannot stretch the wall-clock cost past the caller's budget" rather
  than the previous wording which described the timeout as
  per-phase.

### Housekeeping

- Apply `cargo fmt` (pinned toolchain `1.92.0`) across `api/mod.rs`,
  `ios_init.rs`, `lib.rs`, `nts/aead.rs`, `nts/cookies.rs`,
  `nts/ntp.rs`, and `nts/records.rs` to reconcile drift accumulated
  since the 1.1.0 cycle. Behaviour is unchanged.
- `.gitignore`: add `.DS_Store` so macOS Finder metadata stops
  appearing in `git status`.
- `rust/src/nts/mod.rs`: declare the new `dns` module.

### Verification

- `cargo test --manifest-path rust/Cargo.toml`: 108 passed, 0 failed,
  3 ignored (live-network).
- `cargo clippy --manifest-path rust/Cargo.toml --tests --all-targets
  -- -D warnings`: clean.
- `cargo fmt --manifest-path rust/Cargo.toml --check`: clean.
- `dart analyze`: clean.
- `flutter test test/ffi_smoke_test.dart`: 5 / 5 pass.

## 1.1.2

Example-app polish and RFC 8915 §4 compliance in the consumer demo. No
changes to the published Dart surface (`ntsQuery`, `ntsWarmCookies`,
`NtsServerSpec`, `NtsTimeSample`, `NtsError`), the Rust crate
(`nts_rust` stays at `0.2.1`), the FFI bindings, or the Native Assets
build hook. The diff is confined to `example/`, `README.md`, and
`example/GUI_GUIDE.md`.

### Example app (`example/`)

- `example/lib/src/widgets/log_view.dart`: fix an auto-scroll
  "stickiness" race condition. The scroll-to-bottom side-effect ran in
  a `WidgetsBinding.instance.addPostFrameCallback`, so by the time the
  callback evaluated whether the user had been near the bottom the
  layout had already been extended by the freshly-appended entry and
  the threshold check fired against `maxScrollExtent` measured *after*
  the append. The decision is now taken synchronously in the signal
  effect against the pre-append layout, while the animated jump still
  runs post-frame against the resolved target. The 32 px stickiness
  threshold and 120 ms animation duration are unchanged.
- `example/main.dart`, `example/example.md`, `README.md`,
  `example/GUI_GUIDE.md`: drop the hardcoded `const _burstSize = 8`
  assumption from the warm-then-burst sample. RFC 8915 §4 leaves the
  cookie-pool size to server policy — the NTS-KE handshake does not
  let a client request a specific count — so the burst loop now runs
  `for (var i = 0; i < warmed; i++)` against the actual count returned
  by `ntsWarmCookies`. Prose in `README.md` and `example/GUI_GUIDE.md`
  is rewritten to cite the RFC and the live-log `recovered N fresh
  cookie(s)` report rather than the previous "(typically 8)" /
  "Eight matches" framing. `example/main.dart` and the fenced block in
  `example/example.md` remain byte-for-byte identical at 5172 bytes.
- `example/lib/src/widgets/log_view.dart`: trim ~20 px of trailing
  whitespace below the newest log entry. After the stickiness fix made
  the layout settle visibly, two compounding sources of dead space at
  the bottom of the log card became apparent: `_spansFor` appended
  `\n` to *every* entry (including the last), leaving a phantom blank
  line; and `SingleChildScrollView` used symmetric
  `EdgeInsets.all(12)`, stacking 12 px of bottom inset on top of that
  phantom line. The fix drops the trailing newline from the message
  span, inserts a `TextSpan(text: '\n')` separator *between* entries
  at the build site (so adjacent entries still render on their own
  lines, and selection-copy still yields one entry per line), and
  tightens the bottom padding to `EdgeInsets.fromLTRB(12, 12, 12, 8)`.
  Total trailing gutter below the newest entry: ~28 px → ~8 px.

### Packaging

- `screenshots/gui_showcase.png` (820,984 bytes) → `gui_showcase.webp`
  (183,230 bytes, −78%) via `cwebp -lossless -z 9 -m 6`. Output is
  pixel-identical to the source PNG (lossless ARGB, dimensions
  preserved at 1766×2062, alpha intact). `pubspec.yaml`'s
  `screenshots:` entry now points at the `.webp` path. pub.dev's
  screenshot pipeline is WebP-native via pana's `webpinfo` validator,
  so this also skips the server-side `cwebp` round-trip. Tarball
  footprint drops from 835 KB to ~213 KB.

### Verification

- `fvm flutter analyze` (root + `example/`): no issues.
- `fvm dart analyze` (root): no issues.
- `fvm flutter test` (`example/`): 31 / 31 pass.
- `example/main.dart` ↔ `example/example.md` fenced-block byte-for-byte
  parity holds at 5172 bytes.
- `webpinfo screenshots/gui_showcase.webp`: VP8L, 1766×2062, alpha=1.

## 1.1.1

Maintenance release. The public Dart surface (`ntsQuery`, `ntsWarmCookies`,
`NtsServerSpec`, `NtsTimeSample`, `NtsError`) is unchanged.

- Bump the `native_toolchain_rust` build-hook dependency floor from
  `^1.0.3` to `^1.0.4` to pick up upstream fixes shipped in the
  `native_toolchain_rust` 1.0.4 release (pub.dev, 2026-04-27). The
  package has no runtime impact; it runs only inside `hook/build.dart`
  during the Native Assets compile of the bundled Rust crate.
- Refresh `pubspec.lock` and `rust/Cargo.lock` to keep the resolved
  dependency graph aligned with the new floor.
- Patch-bump the internal Rust crate `nts_rust` from `0.2.0` to `0.2.1`
  so the crate version moves in lockstep with the Dart package release.
  The bindings (`lib/src/ffi/`) and Native Assets bridge are unaffected;
  no behavioural changes ship in the Rust core.
- README, example, and dartdoc updates from the previous release stay
  in place; this release adds no new user-facing documentation.

## 1.1.0

Protocol-compliance and reliability hardening across the Rust core. The
public Dart surface (`ntsQuery`, `ntsWarmCookies`, `NtsServerSpec`,
`NtsTimeSample`, `NtsError`) is unchanged; consumer-visible behaviour
improves on the timeout, cookie-cache, and error-classification paths.
Rust crate `nts_rust` is bumped from `0.1.0` to `0.2.0` to mark the
internal protocol-validation tightening; the bindings (`lib/src/ffi/`)
and Native Assets bridge are unaffected.

### NTS-KE handshake (`rust/src/nts/ke.rs`)

- Replace the OS-default TCP connect with a deadline-aware connection
  loop that honours the caller's `timeoutMs`. Earlier releases passed
  the budget only to the read/write side of the socket and let
  `TcpStream::connect` block on the platform default (typically 75 s
  on macOS / 21 s on Linux), which made `ntsQuery(..., timeoutMs: 5000)`
  hang for the full kernel default when the KE endpoint blackholed
  SYNs. The new loop iterates the resolved address list, computes the
  per-attempt deadline from the remaining budget, and surfaces a
  `KeError::Io(ErrorKind::TimedOut)` on the *first* exhausted attempt
  rather than the last. Mapped through `From<KeError> for NtsError` to
  `NtsError.timeout` so the Dart-side switch arm is reached.
- Regression test
  `connect_with_timeout_respects_budget_for_unroutable_ip` exercises
  the deadline against `192.0.2.1` (RFC 5737 TEST-NET-1) and asserts
  the call returns within 1.5× the configured budget.

### Cookie management (`rust/src/api/nts.rs`)

- Introduce a monotonically-increasing `generation: u64` on `Session`
  and propagate it into `QueryContext::session_generation` so each
  in-flight NTPv4 query carries the identity of the handshake that
  produced its cookies. `Session::deposit_cookies` now gates the
  cookie-jar update on a matching generation: cookies extracted from
  a response signed under generation N are silently dropped if the
  session has been re-handshaked to generation N+1 between dispatch
  and receipt. This closes a cross-session poisoning window where a
  late response from a stale session could install cookies bound to
  retired keys, causing the next `ntsQuery` to dispatch
  unauthenticatable cookies and fail the AEAD seal.
- The generation counter is also incremented on every successful
  `Session::rehandshake`, so the stale-cookie filter applies
  symmetrically to both concurrent-query races and explicit
  `ntsWarmCookies` invocations during an in-flight query.

### NTPv4 header validation (`rust/src/nts/ntp.rs`)

- Add `STRATUM_UNSYNCHRONIZED_FLOOR = 16` and reject any post-AEAD
  reply with `stratum >= 16` as `NtpError::Unsynchronized`. RFC 5905
  reserves stratum 16 as the "unsynchronized" sentinel and 17–255 as
  reserved; previous versions only filtered LI=3, so a server in the
  alarm condition could surface a wall-clock offset to the discipline
  loop if it left LI=0.
- Reorder the validation so the Stratum-0 short-circuit (Kiss-o'-Death)
  runs *before* the LI=3 / stratum-ceiling check. Real-world KoD
  packets routinely arrive with LI=3 because the server has no
  synchronised time to advertise; the previous ordering swallowed the
  4-octet kiss code (`RATE`, `DENY`, `RSTR`, `NTSN`, …) into a generic
  `Unsynchronized` error and stripped the diagnostic the caller needs
  to choose a back-off strategy.
- Validation remains positioned *after* AEAD `open()` and the
  origin-timestamp check. `stratum` and the leap indicator are part
  of the NTP AAD, so by this point the server has signed the value;
  off-path attackers cannot forge KoD or stratum-16 to disrupt the
  client. The post-AEAD ordering is pinned by the
  `*_after_seal_*_tamper_as_aead_failure` test family.
- New regression tests:
  - `parse_response_prefers_kod_over_unsynchronized_when_both_set`
    pins the new precedence (Stratum 0 + LI=3 ⇒ `KissOfDeath`).
  - `parse_response_rejects_invalid_high_stratum` pins the new
    stratum-ceiling check (stratum 16 + LI=0 ⇒ `Unsynchronized`).
- Broaden the `Display` arm and rustdoc on `NtpError::Unsynchronized`
  to `"server reports unsynchronized clock (LI=3 or stratum >= 16)"`
  so the diagnostic accurately reflects both triggers; the message
  passes through `NtsError::NtpProtocol(..)` to the Dart side
  unchanged.

### Housekeeping

- `rust/src/nts/records.rs`: replace `body.len() % 2 != 0` with
  `!body.len().is_multiple_of(2)` in `decode_u16_array` to satisfy
  the `clippy::manual_is_multiple_of` lint (warn-by-default in
  clippy 1.92, surfaced once `cargo clippy --all-targets -- -D
  warnings` was added to the release gate). Behaviour is unchanged.

### Verification

- `cargo test --lib`: 95 passed, 0 failed, 3 ignored (live-network).
- `cargo clippy --tests --all-targets -- -D warnings`: clean across
  the workspace.

## 1.0.7

Documentation and published-tarball hygiene. No changes to the published
Dart surface, the Rust crate, or the Native Assets bridge.

- `example/lib/src/state/nts_controller.dart`: prepend a 46-line dartdoc
  block to `runQuery` that documents the NTS-KE cold-start cost
  (TCP + TLS 1.3 + KE handshake + first NTPv4 exchange ≈ 4 RTTs end to
  end, no session-ticket resumption), the steady-state path (cached
  session keys, in-band cookie pool replenishment, ~1 RTT), and the
  attribution boundary (the latency is RFC 8915 protocol overhead, not
  `RustLib.init()`, the Native Assets pipeline, or per-call FFI cost).
  Includes a production note pointing at `example/main.dart`'s
  `ntsWarmCookies()` warm-then-query pattern as the canonical way to
  amortize the cold-start cost; the GUI deliberately does not follow it
  so that the protocol observation tool surfaces the unmasked latency.

- Repository-wide documentation refactor (7 files: `pubspec.yaml`,
  `analysis_options.yaml`, `DEVELOPMENT.md`, `README.md`,
  `example/.pubignore`, `example/README.md`, `tool/check_bindings.dart`)
  to replace meta-commentary about pub.dev scorecards, `pana` rubrics,
  and tag-drop heuristics with objective technical justifications. The
  platform allow-list now reads as RFC 8915's raw TCP/UDP requirement
  plus rustls+ring's lack of a wasm32 target; the FRB pin is justified
  by the silent-memory-corruption risk of a wire-format mismatch; the
  analyzer-exclude removal is justified by lockstep with the consumer's
  analyzer view; the `// ignore_for_file:` directives in `lib/src/ffi/**`
  are justified by `public_member_api_docs` being enabled and the FFI
  surface not being excluded. The IANA AEAD-registry reference in
  `example/GUI_GUIDE.md` is preserved as a legitimate protocol citation.

- `.pubignore` (new, root): introduce a root `.pubignore` that mirrors
  the root `.gitignore` patterns (per dart.dev/go/pubignore, a
  directory's `.pubignore` replaces its `.gitignore` for publish
  purposes) and additionally excludes consumer-irrelevant files:
  `AGENTS.md`, `CLAUDE.md` (AI-agent guidance), `ARCHITECTURE.md`,
  `DEVELOPMENT.md` (self-identified contributor-only documentation),
  `analysis_options.yaml` (consumer analyzers read the consumer's own
  config), `flutter_rust_bridge.yaml` (FRB codegen config; bindings ship
  pre-generated), `tool/` (CI drift check for FRB regeneration), and
  `test/` (internal FFI smoke test, not a public-API verifier).

- `example/.pubignore`: add `analysis_options.yaml` and `test/` to the
  example's exclusion list for the same reasons as the root. The
  canonical consumer entry point remains `example/main.dart`.

- Net effect verified via `dart pub publish --dry-run`: the published
  tarball drops from 840 KB (1.0.6) to 824 KB, twelve maintainer-only
  files are stripped, and the warning/hint output is unchanged. No
  source files in `lib/`, `rust/`, or `hook/` are touched, so the
  binding drift gate and Native Assets build hook are unaffected.

## 1.0.6

Binding regen consequent on the 1.0.5 analyzer-exclude removal. No
changes to the published Dart surface, the Rust crate, or the Native
Assets bridge.

- `lib/src/ffi/frb_generated.dart`: regenerate against the current
  `analysis_options.yaml`. Removing the `analyzer.exclude:
  [lib/src/ffi/**]` block in 1.0.5 (`nts-2cq`) had a side effect that
  the bindings CI job did not surface until the next commit that
  re-triggered the job: `flutter_rust_bridge_codegen` runs an
  analyzer-aware fix-up over the Dart it emits before exiting, that
  pass was a no-op while the FFI files were excluded, and with the
  exclude gone the pass applies `prefer_final_locals` and
  `prefer_const_constructors` to the synthesized dispatcher
  boilerplate. The committed file (last regenerated in 1.0.2,
  `0349077`) was therefore stale relative to the codegen's
  deterministic output. The regen is purely cosmetic — `var` locals
  inside `dco_decode_nts_error` / `sse_decode_*` become `final`, and
  the two nullary `NtsError` variants gain `const` prefixes — and
  produces no wire-format or public-API change. The file-level
  `// ignore_for_file:` directives managed by
  `tool/check_bindings.dart` still suppress both rules so future
  codegen output that emits a non-final local or non-const
  constructor remains acceptable to pana without re-failing the
  drift gate.

## 1.0.5

Example clarity and pub.dev metadata fidelity. No changes to the
published Dart surface, the Rust crate, or the Native Assets bridge.

- `example/main.dart`: switch the minimal sample from a single
  `ntsQuery()` call to a warm-then-query flow that calls
  `ntsWarmCookies()` first and then `ntsQuery()`. The original
  one-call form lumped the NTS-KE handshake into the same latency
  budget as the NTPv4 exchange and never made the cookie pool
  visible; the new form mirrors the production access pattern,
  surfaces the `cookies_remaining` counter on `NtsTimeSample`, and
  gives readers a self-contained reference for both stages of the
  protocol. `example/example.md` is regenerated as a byte-for-byte
  fenced mirror so the pub.dev Example tab tracks the runnable
  sample. The exhaustive `NtsError` switch and the `RustLib.init()`
  bootstrap order are unchanged.

- `example/example.md`: drop the developer-facing meta-commentary
  about the rendering quirk that motivated the file's existence
  (`pana` priority list, the `example/main.dart` shadowing dance from
  1.0.3 / 1.0.4). The fenced sample is the consumer-visible artefact;
  the rendering history is recorded in this changelog and in the
  `nts-9td` commit message, not in the file pub.dev publishes.

- `analysis_options.yaml`: remove the
  `analyzer.exclude: [lib/src/ffi/**]` block so local
  `dart analyze` / `flutter analyze` runs see the same surface
  pana sees on pub.dev. The FRB-generated files in `lib/src/ffi/`
  carry file-level `// ignore_for_file:` directives (managed by
  `tool/check_bindings.dart` and landed in 1.0.2) for the rules they
  cannot satisfy, which pana respects but `analyzer.exclude` does not
  — keeping both meant local CI was strictly more permissive than the
  pub.dev scorecard. With the exclude removed, lint drift between
  the two environments is impossible.

- `pubspec.yaml`: add a top-level `platforms:` allow-list with
  `android`, `ios`, `macos`, `linux`, `windows`. Earlier releases
  shipped without this block, which let pana award the `web` and
  `wasm` platform tags on the strength of the Dart surface compiling
  cleanly under `dart2js` / `dart2wasm` — but actual runtime use of
  any nts API on Web cannot work, because RFC 8915 needs raw TCP for
  NTS-KE on `:4460` and raw UDP for NTPv4 on `:123` (neither of which
  browsers expose to web pages), and the `rustls` + `ring` +
  `rustls-platform-verifier` stack does not target
  `wasm32-unknown-unknown`. Declaring the supported platforms
  explicitly drops both incorrect tags from the next pana rescore so
  the pub.dev scorecard reflects the package's true platform surface.

## 1.0.4

pub.dev Example tab fix (take two). No runtime changes.

- Add `example/example.md` containing the minimal NTS-KE sample as a
  fenced ```dart block plus a pointer to the Flutter GUI showcase at
  `example/lib/main.dart`. The 1.0.3 rename of the minimal sample to
  `example/main.dart` did not unblock the Example tab: empirical check
  on the published version-pinned URL still rendered
  `example/lib/main.dart`. The bracket notation
  `example[/lib]/main.dart` in dart.dev's package-layout doc is
  shorthand for two **separate** slots in pana's selection list, with
  the `lib/` form ranked **higher** than the bare form. The actual
  list lives in
  [`pana/lib/src/maintenance.dart`](https://github.com/dart-lang/pana/blob/master/lib/src/maintenance.dart):

  1. `example/README.md`
  2. **`example/example.md`** ← new in 1.0.4, secures the slot
  3. `example/lib/main.dart` (GUI showcase, no longer rendered)
  4. `example/bin/main.dart`
  5. `example/main.dart` (1.0.3 rename target, also no longer rendered)

  Slot 2 beats slot 3, so the new `example/example.md` finally wins
  over `example/lib/main.dart`. The minimal sample at
  `example/main.dart` stays in the archive as the runnable Flutter
  target; the `.md` is just a syntactic mirror so pub.dev picks it.

- No changes to the published Dart surface, the Rust crate, or the
  Native Assets bridge. The two new lines in `pubspec.yaml` and
  `CHANGELOG.md` are the only metadata edits.

## 1.0.3

pub.dev Example tab fix. No runtime changes.

- Rename `example/example.dart` to `example/main.dart` so pub.dev's
  Example tab renders the intended minimal single-call sample. pub.dev
  picks the rendered file from a hardcoded priority list documented
  at <https://dart.dev/tools/pub/package-layout#examples>; the previous
  layout placed the minimal sample at priority 5
  (`example[/lib]/example.dart`) where it was shadowed by the Flutter
  GUI showcase at priority 2 (`example/lib/main.dart`). The bare
  `example/main.dart` slot also sits at priority 2 but wins over the
  `lib/` variant, so the rename promotes the minimal sample without
  removing the GUI showcase from the published tarball.
- Update `example/README.md` to spell the GUI entry point explicitly
  as `flutter run -t lib/main.dart` (or `-t example/lib/main.dart`
  from the repo root) so contributors don't accidentally launch the
  new top-level `example/main.dart` as the Flutter target.
- Update root `README.md` and `ARCHITECTURE.md` to reference the new
  path. The 1.0.1 changelog entry that introduced
  `example/example.dart` is left unchanged for historical accuracy.

## 1.0.2

Static-analysis score recovery. No runtime changes.

- Suppress pana-only lints across the FRB-generated bindings via the
  `// ignore_for_file:` directive of each file, applied as a post-codegen
  patch step in `tool/check_bindings.dart`. pana's static-analysis run
  uses a stricter ruleset than `flutter_lints` and surfaced 117+ INFO
  lints against the synthesized freezed wrappers (`NtsError`),
  auto-generated default constructors (`NtsServerSpec`, `NtsTimeSample`),
  and dispatcher boilerplate that FRB cannot back with Rust docstrings,
  costing 10 pub points. Patched files and rules:
  - `lib/src/ffi/api/nts.dart`: `public_member_api_docs`.
  - `lib/src/ffi/frb_generated.dart`: `public_member_api_docs`,
    `prefer_final_locals`, `prefer_const_constructors`.
  - `lib/src/ffi/frb_generated.io.dart`: `public_member_api_docs`.
  - `lib/src/ffi/frb_generated.web.dart`: `public_member_api_docs`.
  Local `pana 0.23.12` now reports 160 / 160 against the working tree.

## 1.0.1

Documentation and pub.dev metadata polish. No runtime changes.

- Restructure README around a What → Why → How flow and offload the
  Rust toolchain, build hooks, and crate breakdown into new
  `ARCHITECTURE.md` and `DEVELOPMENT.md` reference documents.
- Add a self-contained `example/example.dart` for pub.dev's Example
  tab.
- Resolve two `dartdoc` unresolved-reference warnings in
  `lib/src/ffi/api/nts.dart` by replacing Rust intra-doc link syntax
  with literal values in the upstream Rust docstrings and regenerating
  the bindings.
- Trim the package description to fit pana's 180-char ceiling, add
  five pub.dev topics (`ntp`, `time`, `networking`, `security`,
  `cryptography`), and register `screenshots/gui_showcase.png` as the
  package listing screenshot.
- Expand the inline comment on the `flutter_rust_bridge: 2.12.0` pin
  to document the wire-format rationale and the accepted pana
  warning.

## 1.0.0

Initial stable release.

### Protocol

- Network Time Security (RFC 8915) client implementing the full NTS-KE
  handshake (TLS 1.3, ALPN `ntske/1`, port 4460) followed by
  AEAD-protected NTPv4 (RFC 5905) over UDP/123.
- AEAD algorithms: AES-SIV-CMAC-256 (IANA ID 15, default) and
  AES-128-GCM-SIV (IANA ID 16), negotiated during NTS-KE.
- Cookie management: in-memory cookie jar with automatic refresh via
  `ntsWarmCookies()` when the pool is exhausted.

### API

- `ntsQuery({required NtsServerSpec spec, required int timeoutMs})`
  returns `Future<NtsTimeSample>` with server transmit time, round-trip
  duration, stratum, negotiated AEAD ID, and fresh cookie count.
- `ntsWarmCookies({required NtsServerSpec spec, required int timeoutMs})`
  forces a fresh handshake and reports the number of cookies received.
- `NtsError` sealed class with eight typed variants
  (`invalidSpec`, `network`, `keProtocol`, `ntpProtocol`,
  `authentication`, `timeout`, `noCookies`, `internal`) for exhaustive
  pattern matching.

### Implementation

- Cryptographic core implemented in Rust (`rustls` for TLS 1.3,
  `aes-siv` / `aes-gcm` for AEAD, `ring` for primitives).
- Bridged to Dart via `flutter_rust_bridge` 2.12.0 (pinned exactly to
  match the Rust crate's wire format).
- Bundled through the stable Native Assets API (`hook/build.dart` +
  `native_toolchain_rust`); no manual `cargo` invocation required from
  consumers.

### Platform support

Android, iOS, macOS, Linux, Windows. Web is not supported (no UDP
socket primitive in the browser).

### Build

- Default release builds use the `log-strip` Cargo feature, eliding
  `info!` / `debug!` / `trace!` format strings at compile time;
  `warn!` and `error!` survive for diagnostics.
- The `verbose_logs` user-define in `pubspec.yaml` opts into a debug
  build with full logging (including `rustls` protocol traces) for
  development.

### Tooling

- `tool/check_bindings.dart` regenerates FRB bindings and fails CI if
  the committed Dart bindings or `rust/src/frb_generated.rs` drift
  from the generator output.
- CI matrix exercises both the declared SDK floor (Flutter 3.38.10 /
  Dart 3.10.9) and the pinned development version (Flutter 3.41.7 /
  Dart 3.11.5).

### Requirements

- Dart `^3.10.0`, Flutter `>=3.38.0`. The lower bound matches the
  `hooks` package (`>=1.0.3`) requirement.
- Native Assets API (stable since Flutter 3.24).

# Monotonic Time in `package:nts`

This document is the technical deep-dive behind the sleep-aware
monotonic clock introduced in
[PR #231](https://github.com/nick-llewellyn/nts/pull/231) (NTS-90,
first shipping in v7.0). It explains why the package moved away from
system-clock-dependent timing, which platform primitives back the new
clock, and how developers building custom NTS logic can share the
package's monotonic timeline.

## Why not the system clock?

A time-synchronization package has an unusual constraint: it cannot
trust the very clock it exists to correct. Metering timeouts or
measuring network delays with `DateTime.now()` (or any other
wall-clock read) couples those measurements to a clock that can move
underneath them:

- **NTP slews and steps.** The OS time daemon continuously adjusts
  the system clock. A step during an in-flight operation makes an
  elapsed-time measurement wrong by the step size — in either
  direction.
- **Manual adjustments.** A user (or MDM policy, or timezone-fix
  script) can set the clock at any moment. A timeout anchored to
  wall-clock time can fire immediately or never.
- **The bootstrapping problem.** On first launch after a dead
  battery, the system clock may be off by months. The package must
  produce correct measurements *before* the device's clock is fixed.

The standard answer is a monotonic clock — a counter that only moves
forward, at a steady rate, regardless of what the system clock does.
Dart's `Stopwatch` and Rust's `std::time::Instant` both provide one.
But on every supported platform they read the *suspend-frozen*
variant (`CLOCK_MONOTONIC` on Linux/Android, `mach_absolute_time` on
Apple platforms, QPC on Windows): the counter stops while the device
is in deep sleep. For a mobile time-sync package that breaks two
things:

1. A synchronized-clock projection (`NtsSyncedTime.utcNow`) silently
   falls behind real UTC by however long the device slept.
2. An in-flight `getTime` budget stalls during suspend instead of
   expiring, so a call that should have failed fast resumes as if no
   time had passed.

The fix is the *suspend-inclusive* monotonic source each platform
also provides — the "boottime" clock family.

## Platform sources

`rust/src/nts/boottime.rs` exposes one function, `boottime_micros()`,
compiled per-platform via `cfg` gates:

| Platform | Syscall / API | Crate | Notes |
|---|---|---|---|
| Android / Linux | `clock_gettime(CLOCK_BOOTTIME)` | [`libc`](https://github.com/rust-lang/libc) | Counts across suspend since Linux 2.6.39. |
| iOS / macOS | `mach_continuous_time` | [`mach2`](https://github.com/nicowillis/mach2) | Scaled to microseconds by the cached `mach_timebase_info`; `libc`'s mach time bindings are deprecated, hence the dedicated crate. |
| Windows | `QueryInterruptTimePrecise` | [`windows-sys`](https://github.com/microsoft/windows-rs) | Interrupt time includes sleep/hibernation; 100 ns units; available since Windows 10. |
| Other targets | `Instant` elapsed since a process anchor | — | Best-effort fallback: monotonic but suspend-frozen. |

All three crates are platform-gated dependencies of the Rust core and
carry license attributions in the [`NOTICE`](../NOTICE) file
(`windows-sys` — Windows only; `libc` — Android and Linux only;
`mach2` — iOS and macOS only).

The reading crosses the FFI bridge as `ntsBoottimeMicros()`, a
synchronous call (`#[frb(sync)]`) returning `i64` — a single clock
read is cheap enough that async isolate-hop overhead would dominate
it, and `i64` maps to a plain Dart `int` rather than `BigInt`.

### Epoch semantics

The epoch is arbitrary (per-boot on the native sources). Only
differences between two readings from the same process are
meaningful. Never persist a raw reading and reinterpret it later: a
reboot resets the native epoch, so a stored reading from a previous
boot session is meaningless. This is why `NtsSyncedTime` deliberately
has no `toJson`/`fromJson` — no safe restore across launches is
possible.

## The Dart-side `Stopwatch` replacement: `MonotonicClock`

`MonotonicClock` (`lib/src/api/clock.dart`, exported from
`package:nts/nts.dart`) is the public Dart wrapper. It behaves like a
`Stopwatch` that keeps counting through deep sleep, and is immune to
NTP slews, NTP steps, and manual system-clock adjustments by
construction — it never reads the wall clock at all.

Each instance resolves its time source exactly once, at
construction. Constructing an instance — or first accessing
`MonotonicClock.instance` — before `NtsRustLib.init()` (or
`NtsRustLib.initMock()`) has completed throws a `StateError` naming
the missing init call; a production build can never silently degrade
to a clock that freezes during device sleep. After init, the
resolution discriminates structurally on the installed API: a real
bridge (the generated FFI implementation that `NtsRustLib.init()`
installs) gets a direct dispatch to `ntsBoottimeMicros()` with no
probe and no catch, so any failure of the clock read propagates
loudly rather than being masked. Only in mock mode — an API that is
not the generated implementation, i.e. `NtsRustLib.initMock()` or a
hand-supplied API passed to `init()` — does a single probe call run,
and a throw (an API that does not stub the boottime call)
permanently selects a plain `Stopwatch` fallback. Because the source
never changes for the instance's lifetime, readings from one
instance are always mutually comparable and never mix epochs.

The shared `MonotonicClock.instance` singleton is the same timeline
the package uses internally, so consumer code reading it stays on
one consistent clock with the package. It is per-isolate (like all
Dart statics); do not compare raw readings across isolates.

## Where the package uses it

### `NtsSyncedTime.utcNow` — the projection

`ntsGetTime` returns an `NtsSyncedTime` anchored at
`MonotonicClock.instance.nowMicros()`. Every subsequent `utcNow`
read projects the authenticated server time forward by the monotonic
time elapsed since the anchor. The projection is therefore unaffected
by anything that happens to the system clock after the sync, and it
stays correct across suspend/resume — the anchor delta includes the
time the device spent asleep.

### The `getTime` wall-clock budget

`ntsGetTime`'s total budget (handshake plus the whole query burst) is
metered by one sleep-aware clock read taken before the first
dispatch; every underlying call receives only the remaining balance.
Because the budget keeps depleting across device suspend, a mid-call
sleep surfaces promptly as a timeout on resume rather than as a call
that silently overshoots its budget by the length of the nap.

### The bridge admission gate

Calls queued behind the bridge concurrency cap have their queue wait
charged against their own `timeout` using the same clock, so the
budget forwarded to the Rust pipeline is the honest remainder — and a
budget that expires while queued fails with
`TimeoutPhase.bridgeSaturation` without ever crossing the FFI
boundary.

## Reliability inside the Rust core

The Rust pipeline was already monotonic before PR #231 — and stays
so. Two mechanisms matter:

### Accurate RTT measurement

`ntsQuery`'s `roundTripMicros` is measured in Rust as
`Instant::now()` captured immediately before the UDP `send` and
elapsed immediately after the matching `recv`. Because `Instant` is
monotonic, the measurement cannot be corrupted by an NTP slew or
clock step landing mid-round-trip — which matters doubly here,
because RTT is not just a diagnostic: it is the plausibility ceiling
for the RFC 5905 peer delay that drives `ntsGetTime`'s burst
selection (and the fallback delay when the peer delay is
implausible), and `delay / 2` is the symmetric-path compensation
applied to the final offset (RFC 5905 §8). A wall-clock-contaminated
RTT would corrupt the synchronized time itself.

### NTS-KE handshake deadlines

The whole NTS-KE handshake — DNS lookup, per-address TCP connect
attempts, the TLS handshake, and the chunked record-exchange read
loop — runs under a single shrinking deadline: a `Deadline` newtype
anchored once at `Instant::now() + timeout` at the top of the
handshake. Each phase consults `remaining()` (saturating at zero)
before issuing any blocking syscall, and socket-level read/write
timeouts are re-armed between phases so a slow trickle from the
server cannot stretch the total wall-clock cost past the caller's
budget. The same pattern (`UdpDeadline`) covers the UDP setup and
the final `recv`.

Anchoring these deadlines to a monotonic source is what makes
timeouts *neither premature nor delayed*: a backwards clock step
cannot grant a handshake extra time, and a forwards step cannot fire
a timeout early on a healthy connection. Budget exhaustion surfaces
as a phase-attributed `NtsError.timeout` (`TimeoutPhase.dnsTimeout`,
`connect`, `tls`, `keRecordIo`, `ntp`, …) rather than as an opaque
failure.

### The layering, end to end

```
Dart caller
  └─ MonotonicClock.instance          (CLOCK_BOOTTIME family, via FFI;
     meters getTime budget + queue     StateError pre-init)
     wait, anchors NtsSyncedTime
        └─ FFI: remaining budget crosses as a plain ms int
             └─ Rust: Deadline / UdpDeadline (std::time::Instant)
                meter DNS, TCP, TLS, KE record I/O, UDP send/recv;
                RTT measured with the same Instant
```

The Dart layer uses the *suspend-inclusive* clock because its budgets
span long-lived app states (a phone can sleep mid-`getTime`). The
Rust layer keeps `Instant` because its deadlines live inside one
blocking network call, where suspend simply pauses the thread along
with the clock — and every phase re-checks the Dart-metered remainder
it was handed.

## Developer integration

Developers building custom NTS logic on the manual primitives
(`ntsQuery` / `ntsWarmCookies` / `NtsClient`) can share the package's
exact monotonic timeline instead of maintaining a parallel
`Stopwatch`.

### Use `MonotonicClock` (recommended)

The supported surface is the exported `MonotonicClock`:

```dart
import 'package:nts/nts.dart';

final clock = MonotonicClock.instance;
const server = NtsServerSpec(host: 'time.cloudflare.com', port: 4460);

// Meter a protocol-level budget across several primitive calls.
const budget = Duration(seconds: 4);
final start = clock.nowMicros();

await ntsWarmCookies(spec: server, timeout: budget);

final remaining = budget - clock.elapsedSince(start);
if (remaining > Duration.zero) {
  final result = await ntsQuery(spec: server, timeout: remaining);
  // result.roundTripMicros was measured monotonically in Rust.
}
```

Because `MonotonicClock.instance` is the same instance the package
reads internally (for `NtsSyncedTime.utcNow`, the `getTime` budget,
and bridge-gate queue accounting), measurements taken this way are
directly comparable with the package's own timing behaviour — no
cross-clock skew.

Rules to respect:

- **Initialize the bridge first.** Constructing an instance — or
  first accessing `MonotonicClock.instance` — before
  `NtsRustLib.init()` throws a `StateError`. (The lazy static is not
  poisoned by the throw: the first access after init resolves
  normally.)
- **Compare readings from one instance only.** Epochs differ between
  instances, isolates, processes, and boots.
- **Never persist raw readings.** They are meaningless after a
  reboot.

### The raw FFI primitive

`MonotonicClock` wraps a lower-level call in the generated FFI layer
(`lib/src/ffi/api/nts.dart`): `ntsBoottimeMicros()`, a synchronous
bridge function returning the raw microsecond reading as an `int`.
The FFI layer is an internal surface — it is not exported from
`package:nts/nts.dart`, its signatures follow the Rust core, and it
throws `StateError` when called before `NtsRustLib.init()`. Prefer
`MonotonicClock`, which locks the source once so readings never mix
epochs; reach for the FFI call only if you are already importing the
FFI layer for other reasons (e.g. a custom mock harness) and can
accept its stability terms.

## Related reading

- [`ARCHITECTURE.md`](../ARCHITECTURE.md) — "Sleep-aware monotonic
  clock" section: module-level notes on `boottime.rs` and the FRB
  plumbing.
- [`README.md`](../README.md) — "Manual control (advanced
  primitives)": the burst-filter-compensate recipe the RTT
  measurement feeds.
- [`NOTICE`](../NOTICE) — license attribution for `windows-sys`,
  `libc`, and `mach2`.
- [RFC 5905 §8](https://datatracker.ietf.org/doc/html/rfc5905) — the
  symmetric-path delay compensation that consumes the RTT.
- [RFC 8915](https://datatracker.ietf.org/doc/html/rfc8915) — Network
  Time Security.

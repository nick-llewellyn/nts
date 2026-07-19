# nts

[![CI](https://github.com/nick-llewellyn/nts/actions/workflows/ci.yml/badge.svg)](https://github.com/nick-llewellyn/nts/actions/workflows/ci.yml)
[![Fuzzing Status](https://github.com/nick-llewellyn/nts/actions/workflows/fuzz.yml/badge.svg)](https://github.com/nick-llewellyn/nts/actions/workflows/fuzz.yml)
[![CodeQL](https://github.com/nick-llewellyn/nts/actions/workflows/codeql.yml/badge.svg)](https://github.com/nick-llewellyn/nts/actions/workflows/codeql.yml)
[![Cargo Audit](https://github.com/nick-llewellyn/nts/actions/workflows/audit.yml/badge.svg)](https://github.com/nick-llewellyn/nts/actions/workflows/audit.yml)
[![Dependabot](https://img.shields.io/badge/dependabot-enabled-blue.svg?logo=dependabot&logoColor=white)](https://github.com/nick-llewellyn/nts/network/updates)
[![codecov](https://codecov.io/gh/nick-llewellyn/nts/graph/badge.svg)](https://codecov.io/gh/nick-llewellyn/nts)
[![Quality Gate Status](https://sonarcloud.io/api/project_badges/measure?project=nick-llewellyn_nts&metric=alert_status)](https://sonarcloud.io/dashboard?id=nick-llewellyn_nts)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/nick-llewellyn/nts/badge)](https://scorecard.dev/viewer/?uri=github.com/nick-llewellyn/nts)
[![Pub Version](https://img.shields.io/pub/v/nts.svg)](https://pub.dev/packages/nts)
[![MIT License](https://img.shields.io/badge/license-MIT-purple.svg)](https://opensource.org/licenses/MIT)

---

Tamper-proof time synchronization for Dart and Flutter.

## Why NTS?

Most apps trust whatever time their device reports, and that time
ultimately comes from plain NTP — an unauthenticated protocol that any
attacker on the network path can forge or replay. Shifting a client's
clock breaks anything anchored to it: TLS certificate validity, JWT
expiry, TOTP codes, OAuth refresh windows, license checks, audit logs.

[Network Time Security (NTS)](https://datatracker.ietf.org/doc/html/rfc8915)
fixes this by authenticating the time server with TLS and
cryptographically signing every time response. A forged or modified
reply is rejected; a hijacked NTP server is detected. The result is a
clock you can trust as much as you trust the operator's TLS
certificate, rather than as much as you trust the network between you
and an anonymous UDP listener.

This package gives Dart and Flutter apps a single async call
(`ntsGetTime`) that returns an authenticated, sleep-aware
monotonic-anchored UTC clock, with the protocol details delegated to a bundled native
implementation. Lower-level primitives remain available for callers
who need manual control. See [ARCHITECTURE.md](ARCHITECTURE.md) for
the underlying RFC 8915 layering and cryptographic specifics.

## Getting Started

### Prerequisites

- **Flutter ≥ 3.38.0** (Dart ≥ 3.10). The package depends on the
  Flutter SDK and ships a Flutter plugin module on Android, so it
  must be consumed from a Flutter app — `dart pub add nts` from a
  pure-Dart project will not resolve.
- **`rustup` on your `PATH`.** The protocol core ships as Rust
  source and is compiled on your machine by the Flutter Native
  Assets build hook the first time you run `flutter run` /
  `flutter build`. The hook reads `rust/rust-toolchain.toml` via
  rustup, which automatically installs the pinned toolchain
  (currently Rust 1.97.1) and the cross-compile target for the
  platform being built. No manual `cargo` invocation, dylib
  copying, or build configuration is needed — but without rustup
  installed the build fails at the hook step.

  New to Rust? Installing rustup is a one-time step; see the
  [official install page](https://rustup.rs/) (or the longer-form
  [rust-lang.org guide](https://www.rust-lang.org/tools/install)):

  - **macOS / Linux:** run the `curl … | sh` one-liner from
    [rustup.rs](https://rustup.rs/), or `brew install rustup` on
    Homebrew.
  - **Windows:** download and run `rustup-init.exe` from
    [rustup.rs](https://rustup.rs/). It will prompt you to install
    the Visual Studio C++ Build Tools if they are missing —
    accept, as the MSVC linker is required to build the crate.

  Restart your terminal (or IDE) afterwards so the updated `PATH`
  is picked up, and verify with `rustup --version`.

  The same mechanism covers toolchain *upgrades*: when a release of
  this package bumps the pin in `rust/rust-toolchain.toml`, the next
  `flutter run` / `flutter build` auto-downloads the new version —
  no `rustup update` or other manual step is needed. The superseded
  toolchain stays on disk; reclaim the space with
  `rustup toolchain uninstall <old-version>` if you like.

### Install

```bash
flutter pub add nts
```

### Platform support

Supported on **Android, iOS, macOS, Linux, and Windows**. On every
platform, integration is `flutter pub add nts` plus one
`await NtsRustLib.init()` during application startup before the
first `ntsGetTime` / `ntsQuery` / `ntsWarmCookies` call — no
per-platform bootstrap code. See "Initialization has two layers"
below for the rationale.

On Android the native bootstrap is automatic via the bundled
`NtsPlugin` on the default Flutter/Gradle setup. The one exception:
hosts that opt in to `RepositoriesMode.FAIL_ON_PROJECT_REPOS` in
`settings.gradle.kts` (not the `flutter create` default) reject the
plugin's project-level Maven injection and must declare the on-disk
`rustls-platform-verifier-android` repository themselves; the
rationale comment in this package's `android/build.gradle.kts`
documents the full recipe.

Web and WebAssembly are unsupported: NTS-KE needs a raw TCP socket
on `:4460` and NTPv4 needs a raw UDP socket on `:123`, neither of
which is reachable from a browser tab.

### Quick start

For most applications, `ntsGetTime` is the whole integration: one
call that performs the NTS-KE handshake, takes a burst of up to 8
authenticated samples under a single 8-second total budget, picks
the lowest-RTT sample, applies the standard `roundTrip / 2`
compensation, and returns a synchronized clock.

```dart
import 'package:nts/nts.dart';

Future<void> main() async {
  // 1. Initialize the FRB bridge exactly once, before anything else
  //    in this package. This loads the bundled Rust binary that does
  //    the actual NTS-KE handshake and AEAD-NTP exchange and wires
  //    the Dart-side dispatch table. Required on every platform.
  await NtsRustLib.init();

  // 2. Pick an RFC 8915 NTS-KE endpoint. Port 4460 is the IANA default.
  const spec = NtsServerSpec(host: 'time.cloudflare.com', port: 4460);

  // 3. Synchronize. Handshake + 8-sample burst + lowest-RTT selection
  //    + RTT/2 compensation, all automatic under one 8-second total
  //    budget.
  final synced = await ntsGetTime(spec: spec);

  // 4. Read the clock. `utcNow` projects the authenticated instant
  //    forward on a sleep-aware monotonic anchor (keeps counting
  //    through device deep sleep), so it stays correct even if the
  //    user or OS steps the system clock after the sync.
  print('authenticated utc = ${synced.utcNow}');
  print('winning sample rtt = ${synced.roundTripMicros}µs '
      '(${synced.samplesUsed} samples used)');
}
```

Keep the returned `NtsSyncedTime` and read `utcNow` on demand rather
than re-querying per read; `elapsedSinceSync` reports the age of the
sync so you can decide when a refresh is worth it. Local oscillator
drift accumulates roughly a millisecond per minute-to-hour of age
depending on hardware.

`ntsGetTime`'s tuning is deliberately fixed (8-sample burst, one
8-second total budget, package-default concurrency caps): a
zero-decision
call sized to serve phones and desktops alike. If you need different
numbers, compose the primitives yourself — see
[Manual control](#manual-control-advanced-primitives) below.

**Initialization has two layers.** Get them straight before deciding
what your host code needs to do.

1. **Native platform bootstrap** (Android only, automatic). On Android
   the bundled `NtsPlugin` captures the `JavaVM` + application
   `Context` that `rustls-platform-verifier` needs to reach the system
   `X509TrustManager`. It runs from `GeneratedPluginRegistrant` before
   Dart `main()` executes, so adding `nts` to your `pubspec.yaml` is
   enough — there is no `MainActivity` shim, JNI symbol, or
   `app/build.gradle.kts` Maven entry to maintain on the default
   Flutter/Gradle setup. (The `FAIL_ON_PROJECT_REPOS` exception
   described under "Platform support" above is the one deviation
   from this.) iOS, macOS, Linux, and Windows have no equivalent
   step. Hosts that bypass the standard Flutter
   activity lifecycle (custom embeddings, isolates spawned ahead of
   plugin registration, integration tests driving the dylib directly)
   can call `com.nllewellyn.nts.PlatformInit.init(context)` from
   Kotlin directly; see the KDoc on that class.

2. **Dart/FRB initialization** (`await NtsRustLib.init()`, every
   platform, manual). This loads the bundled Rust dylib through the
   Native Assets pipeline and wires the
   [`flutter_rust_bridge`](https://pub.dev/packages/flutter_rust_bridge)
   v2 dispatch table on the calling isolate. The Android plugin does
   *not* subsume this step: `NtsRustLib.init()` mutates Dart isolate
   state, and the plugin runs on the Android platform thread before
   the Dart isolate exists. Calling `ntsGetTime`, `ntsQuery`, or
   `ntsWarmCookies` before `NtsRustLib.init()` resolves raises an
   error. In a Flutter
   app, do it right after `WidgetsFlutterBinding.ensureInitialized()`
   in `main()`; subsequent invocations are no-ops, so it is safe to
   call from a shared bootstrap path.

A complete, runnable version with exhaustive `NtsError` handling
lives in [`example/main.dart`](example/main.dart). For valid hostnames
to plug into `NtsServerSpec`, see the community-maintained
[NTS server list](https://github.com/jauderho/nts-servers).

### Upgrading

Migration notes for breaking releases live in
[CHANGELOG.md](CHANGELOG.md) under the relevant version header — in
particular the `1.4.0` Android bootstrap rework (JNI symbol rename
plus auto-init plugin) for anyone arriving from `1.3.x`.

## Manual control (advanced primitives)

`ntsGetTime` is the packaged implementation of the standard
NTP-hygiene recipe. When its fixed tuning does not fit — a different
burst size, a tighter or looser budget, handshake timing decoupled
from sampling, custom filtering — the same protocol primitives it is
built from are public:

- **`ntsQuery`** — one authenticated NTPv4 round-trip. Returns the
  raw protocol output (`NtsTimeSample`): the server's transmit
  timestamp plus the locally measured RTT. The first call handshakes
  implicitly; later calls reuse the cached session. Exposes the
  `timeout`, `dnsConcurrencyCap`, and `bridgeConcurrencyCap` knobs
  that `ntsGetTime` fixes internally.
- **`ntsWarmCookies`** — force a fresh NTS-KE handshake without
  sampling, e.g. to front-load the TLS cost at app startup or on a
  known-good network window. The returned
  `NtsWarmCookiesOutcome.freshCookies` reports how many single-use
  cookies the server delivered (RFC 8915 §4 leaves the pool size to
  server policy), which bounds how many `ntsQuery` calls can follow
  before the next implicit handshake.
- **`NtsClient`** — an owned client with its own session table and
  trust policy, for callers who need isolation from the default
  singleton or non-default `TrustMode`s. Carries per-client `query`
  / `warmCookies` / `getTime` twins plus `invalidate` / `clear`
  session management. See
  [Security considerations](#security-considerations) below.

A hand-rolled synchronized clock adds two layers on top of raw
samples — the same two `ntsGetTime` automates:

1. **Burst sampling.** A single NTPv4 reply carries whatever jitter
   the network and the server's queueing happened to introduce on
   that one packet. Calling `ntsWarmCookies` once and then `ntsQuery`
   several times in quick succession — one query per delivered
   cookie — produces a small distribution you can reason about
   statistically. Pick the sample with the smallest
   `roundTripMicros`; on a low-RTT path the symmetric-path assumption
   below holds tightest, so that sample carries the smallest residual
   offset error. More sophisticated callers can median-filter, score by
   `serverStratum`, or run Marzullo's algorithm across multiple servers.

2. **Symmetric-path delay compensation.** `utcUnixMicros` is the moment
   the server stamped the reply, not the moment it landed locally. The
   reply then spent roughly half the round-trip travelling back to the
   client, so the server's clock at the moment of arrival is best
   approximated as `utcUnixMicros + roundTripMicros / 2`. This is the
   standard NTP correction (RFC 5905 §8); it assumes the outbound and
   return paths are symmetric, which is why filtering on the lowest-RTT
   sample matters — short paths are more likely to be symmetric.

The `offset` between local and server time is then
`(utcUnixMicros + roundTripMicros / 2) - localUnixMicrosAtReceive`,
sampled at the moment `await ntsQuery(...)` returns. Persist that offset
and apply it on top of the device's monotonic clock rather than calling
`ntsQuery` on every read; a few-second jitter floor on cellular
networks makes per-call queries strictly worse than one well-filtered
offset reused across many reads. (`ntsGetTime` does exactly this,
returning the projection as `NtsSyncedTime.utcNow`.)

Below `ntsGetTime`, the package stops at protocol primitives by
design: the right filter (lowest-RTT, median, Marzullo across
multiple servers, weighted by stratum), the right resampling cadence,
and the right way to project the offset onto `DateTime.now()` are all
workload specific. The
[`example/main.dart`](example/main.dart) snippet shows the minimum
burst-filter-compensate flow described above built from the
primitives.

## Monotonic Time & Measurement Accuracy

A time-synchronization package cannot trust the clock it exists to
correct, so `package:nts` never meters a timeout or measures a
network delay against the system clock. All internal timing runs on
monotonic sources:

- **Sleep-aware on the Dart side.** Budgets and projections read the
  suspend-inclusive "boottime" clock family through the Rust core
  (`CLOCK_BOOTTIME` on Android/Linux, `mach_continuous_time` on
  iOS/macOS, `QueryInterruptTimePrecise` on Windows), exposed
  publicly as `MonotonicClock`. Unlike Dart's `Stopwatch`, readings
  keep advancing while the device is in deep sleep, so the
  `NtsSyncedTime.utcNow` projection stays correct across
  suspend/resume and an in-flight `getTime` budget expires on
  schedule instead of stalling.
- **Monotonic deadlines in the Rust core.** The NTS-KE handshake
  (DNS, TCP connect, TLS, record exchange) and the UDP exchange run
  under single shrinking `Instant`-anchored deadlines, so timeouts
  fire neither prematurely nor late regardless of NTP slews, clock
  steps, or manual adjustments mid-call.
- **Trustworthy RTT.** `roundTripMicros` is measured monotonically
  around the UDP round-trip, which matters because the lowest-RTT
  sample drives `ntsGetTime`'s burst selection and `rtt / 2` is the
  delay compensation applied to the final offset — a contaminated
  RTT would corrupt the synchronized time itself.

For the platform syscall mappings, epoch semantics, the
bridge-initialization requirement, and how to synchronize your own
protocol-level timeouts with the package's clock, see
[docs/MONOTONIC_TIME.md](docs/MONOTONIC_TIME.md).

## Security considerations

The package handles authentication and replay protection on its own
side of the wire (RFC 8915 NTS over TLS 1.3, AEAD on every NTPv4
exchange, single-use cookies, UID and origin-timestamp echo checks,
strict `TrustMode.platformOnly` available for callers who want the
platform CA store with no static-bundle downgrade). What it does
*not* do — and structurally cannot do, because the whole point of
the API is "take a caller-supplied host and connect to it" — is
constrain *which* hosts a caller is allowed to reach.

If your app accepts hostnames from untrusted input (e.g. a user-
entered NTS server URL, a remotely-fetched server list, a deep-link
parameter) and passes them through to `ntsQuery` / `ntsWarmCookies`
/ `NtsClient`, treat those call sites as a server-side-request-
forgery (SSRF) surface and apply the validation your threat model
requires *before* dispatching into this library. Reasonable
controls include:

- **Allowlist** — pin the set of acceptable hosts at the
  application layer (e.g. against a curated catalog like the one
  the [Flutter showcase](example/lib/src/data/) ships). Most
  consumer-facing apps that need authenticated time can ship with a
  fixed allowlist and never resolve attacker-controlled hostnames
  at all.
- **Reject private-range resolution** — if you do accept arbitrary
  hostnames, resolve them yourself first, refuse the call if the
  resolved address falls in an RFC 1918 / RFC 4193 / loopback /
  link-local range, and only then pass the (resolved, validated)
  hostname through. This is a textbook SSRF mitigation; this
  library cannot apply it on your behalf because legitimate
  on-premise deployments routinely point at RFC 1918 hostnames
  (a stratum-1 GPS receiver on a corporate VLAN) and the library
  has no way to tell those apart from a callsite that's being
  exploited.
- **Constrain the port** — the wrapper rejects ports outside
  `1..65535` as `NtsError.invalidSpec`, but every value inside that
  range is reachable. If your threat model requires it, gate the
  port at the application layer before the call.

The bounded DNS worker pool (`kDefaultDnsConcurrencyCap = 4`, see
the [API summary](#api-summary) section) bounds the *amplification*
exposure of a saturated hostname-resolution path, but does not gate
*destinations* — that gate is the caller's responsibility.

### Trust-anchor selection

The default `TrustMode.platformWithFallback` consults the platform
trust store, which is the right choice for the broadest
connectivity: it honours corporate CAs, MDM-installed roots, and
user-added certificates, so the client works out of the box on
managed devices and private networks.

The security trade-off is that platform-managed stores on corporate
or MDM-managed devices often include an inspection CA installed by
policy. An appliance holding a certificate signed by that CA can
complete a man-in-the-middle NTS-KE handshake and derive the same
AEAD keying material the client derives. Because NTS authenticates
time responses using those keys, a middlebox with a platform-trusted
cert can forge NTPv4 replies that the client accepts as authentic.

If your threat model requires end-to-end integrity against TLS
inspection, construct the client explicitly with
`TrustMode.bundledOnly`:

```dart
import 'package:nts/nts.dart';

Future<void> main() async {
  await NtsRustLib.init(); // must complete before using NtsClient
  final client = NtsClient(trustMode: TrustMode.bundledOnly);
  final sample = await client.query(
    spec: const NtsServerSpec(host: 'time.cloudflare.com', port: 4460),
    bridgeConcurrencyCap: 4, // built-in default, shown for visibility
  );
}
```

`bundledOnly` limits trust anchors to the library's static
`webpki-roots` bundle. An inspection appliance cannot present a
certificate this client will accept, because the bundle contains
only public CAs and no CA injected via MDM or policy. The
trade-off is that `bundledOnly` will reject certificates from
private or enterprise CAs, so it is unsuitable for NTS servers
that present private-CA-issued certificates. For those deployments,
use `TrustMode.custom` with the relevant root bundle supplied via
`customRoots`. See the `TrustMode` API documentation and
[ARCHITECTURE.md](ARCHITECTURE.md#trust-anchor-diagnostics) for the
full decision matrix.

### Reaching multiple trust domains

A single client applies one trust policy to *every* host it
queries — the `TrustMode` is fixed at construction and immutable
per client. You cannot route different per-host trust policies
through one client. A `TrustMode.custom` client built around a
private CA accepts only certificates that chain to that CA, so it
rejects `time.cloudflare.com`; a `bundledOnly` client trusts only
the public `webpki-roots` bundle, so it rejects a server
presenting a private-CA certificate. (A platform-mode client is
the awkward middle case: whether it accepts a private-CA server
depends on whether that CA is installed in the OS trust store, so
it does not give a clean, predictable boundary either way.)

When an app must enforce distinct boundaries for distinct hosts —
say an internal NTS server behind a private CA *and* public
servers — mint one client per trust domain and route each query to
the matching client:

```dart
import 'dart:io';
import 'package:nts/nts.dart';

Future<void> main() async {
  await NtsRustLib.init(); // must complete before using NtsClient

  // Trusts only the private CA, so it authenticates only the
  // internal server; public hosts are rejected.
  final privateRoots = File('/etc/nts/internal-ca.pem').readAsBytesSync();
  final internalClient = NtsClient(
    trustMode: TrustMode.custom,
    customRoots: privateRoots,
  );

  // Trusts only the public webpki-roots bundle, so an MDM-injected
  // root or the private CA above cannot authenticate these hosts.
  final publicClient = NtsClient(trustMode: TrustMode.bundledOnly);

  // Both clients share one isolate-wide bridge admission gate, so the
  // explicit `bridgeConcurrencyCap` (the built-in default of 4) bounds
  // their combined worker occupancy, not each client's separately.
  final internal = await internalClient.query(
    spec: const NtsServerSpec(host: 'ntp.internal.example', port: 4460),
    bridgeConcurrencyCap: 4,
  );
  final external = await publicClient.query(
    spec: const NtsServerSpec(host: 'time.cloudflare.com', port: 4460),
    bridgeConcurrencyCap: 4,
  );
}
```

Per-client scoping is the security point, not just an ergonomic
convenience: it keeps the private CA trusted *only* for the internal
server. Merging both anchor sets into one client would let the
private CA authenticate a public hostname (and vice-versa), widening
every server's trusted-issuer set to the union — the exact exposure
the per-client boundary exists to prevent. Each client also owns its
own session table, so cookies and AEAD keys never cross the domain
boundary.

### Non-Flutter Dart callers must pass `externalLibrary` explicitly

The automatic library resolution described under
[Prerequisites](#prerequisites) is a Flutter-specific feature: the
Native Assets build hook only runs inside `flutter run` /
`flutter build`, where it compiles the Rust crate and hands
`NtsRustLib.init()` a controlled absolute path to the resulting
dynamic library.

Pure Dart environments — a `dart run` CLI such as the bundled
[`example/bin/nts_cli.dart`](example/bin/nts_cli.dart), a
server-side script, an integration-test harness — never trigger
that hook. Nothing compiles the crate for you (build it with
`cargo build --release` in `rust/`), and nothing supplies a load
path: without one, the FRB-generated default loader falls back to
resolving the *relative* directory `rust/target/release/` against
the current working directory.

That fallback is a security problem, not just a convenience gap.
Calling `await NtsRustLib.init()` with no `externalLibrary:`
argument from a working directory an attacker can influence is a
library-hijack surface: a malicious
`rust/target/release/libnts_rust.dylib` (or `.so` / `.dll`) dropped
there yields arbitrary code execution under the calling process's
privileges — before any of this package's TLS / NTS code is even
reached.

Outside Flutter, therefore, always resolve an absolute path to the
compiled library (`.so` on Linux, `.dylib` on macOS, `.dll` on
Windows) from a trusted source — a packaged install location, an
environment variable owned by the deploying operator, a
command-line argument — and pass it through the `externalLibrary`
parameter:

```dart
import 'package:nts/nts.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;

await NtsRustLib.init(
  externalLibrary: ExternalLibrary.open('/absolute/path/to/libnts_rust.dylib'),
);
```

Flutter callers can keep using the bare `await NtsRustLib.init()`
form: the Native Assets pipeline supplies the load path before the
relative fallback can fire.

## API summary

| Symbol | Purpose |
|--------|---------|
| `NtsRustLib.init()` | Load the native dylib and wire the FRB v2 dispatch table on the calling isolate. Await once before any other call, on every platform. (Android-side `rustls-platform-verifier` JNI bootstrap is handled separately by the bundled `NtsPlugin` before `main()`; see "Initialization has two layers" above.) |
| `ntsGetTime({required spec, verificationTime})` | **Recommended entry point.** One-call convenience: fresh handshake + serial burst of up to `min(8, freshCookies)` queries, lowest-RTT selection, `roundTrip / 2` compensation. Returns `NtsSyncedTime`. Succeeds when at least one burst sample lands. Tuning is fixed and internal: an 8-sample burst and one 8-second **total** budget shared across the handshake and every query; deployments needing different numbers compose `ntsWarmCookies` + `ntsQuery` directly. The deprecated `verificationTimeMs` `int` parameter remains accepted for one release. |
| `ntsQuery({required spec, timeout = kDefaultTimeout, dnsConcurrencyCap = kDefaultDnsConcurrencyCap, bridgeConcurrencyCap = kDefaultBridgeConcurrencyCap, verificationTime})` | Advanced primitive: one authenticated NTPv4 exchange. Returns `NtsTimeSample`. `verificationTime` (optional `DateTime`, interpreted as UTC, not before the epoch) pins TLS certificate validity-window checks to a fixed instant instead of the system clock — useful for cold-start clock-skew rescue. The deprecated `timeoutMs` / `verificationTimeMs` `int` parameters remain accepted for one release. |
| `ntsWarmCookies({required spec, timeout = kDefaultTimeout, dnsConcurrencyCap = kDefaultDnsConcurrencyCap, bridgeConcurrencyCap = kDefaultBridgeConcurrencyCap, verificationTime})` | Advanced primitive: force a fresh NTS-KE handshake. Returns `NtsWarmCookiesOutcome`. `verificationTime` carries the same clock-skew-rescue semantics as on `ntsQuery`. Same one-release deprecation of the `*Ms` parameters. |
| `ntsDnsPoolStats()` | Synchronous snapshot of the bounded DNS resolver pool counters (`inFlight`, `highWaterMark`, `recovered`, `refused`). See ARCHITECTURE.md for the saturation signature. |
| `ntsTrustStatus()` | Synchronous snapshot (`NtsTrustStatus`) of the process-global trust-anchor diagnostic state. Seven observables: `defaultClientBackend` (most-recently resolved backend for the default singleton; `null` until the first singleton handshake runs), four cumulative counters partitioning the singleton's resolution history by backend (`defaultBackendPlatformCount`, `defaultBackendHybridCount`, `defaultBackendWebpkiCount`, `defaultBackendCustomCount`), `androidPlatformInitSucceeded` (static JNI bootstrap flag), and `androidHybridFallbackCount` (Android-only). Platform-irrelevant fields report sentinel values (`null` / `false` / `0`). Cheap enough for a UI poll loop. |
| `NtsClient({trustMode = TrustMode.platformWithFallback, customRoots})` | Owned client with its own per-host session table — cookies, AEAD keys, and KE sessions are isolated from the default singleton and from other clients. Methods: `query` / `warmCookies` / `getTime` (per-client equivalents of the top-level functions, same parameters including `verificationTime`), `invalidate(spec)` (drop one cached session) / `clear()` (drop all), and the `trustMode` getter. `customRoots` is required (and only valid) when `trustMode` is `TrustMode.custom`. |
| `kDefaultTimeout` | Package default for `timeout` (`Duration(milliseconds: 5000)`). |
| `kDefaultTimeoutMs` | Deprecated `int` twin of `kDefaultTimeout` (5000); slated for removal with the deprecated `timeoutMs` parameters. |
| `kDefaultDnsConcurrencyCap` | Package default for `dnsConcurrencyCap` (`4`, sized for mobile pthread-stack budgets — see the constant's dartdoc). |
| `kDefaultBridgeConcurrencyCap` | Package default for `bridgeConcurrencyCap` (`4`, sized to the smallest common mobile FRB worker pool — see the constant's dartdoc). |
| `NtsServerSpec(host, port)` | NTS-KE endpoint (port 4460 by default). |
| `NtsSyncedTime` | Synchronized clock returned by `getTime`: `utcUnixMicros` (compensated best sample at the anchor), `roundTripMicros` (winning sample), `samplesUsed`, `trustBackend`, `utcNow` (sleep-aware monotonic projection immune to system clock changes and device suspend), `elapsedSinceSync`. Identity semantics — a live clock, not a value-type DTO. |
| `MonotonicClock` | General-purpose sleep-aware monotonic time source: readings keep advancing across device deep sleep, unlike `Stopwatch` (`CLOCK_BOOTTIME` on Android/Linux, `mach_continuous_time` on iOS/macOS, `QueryInterruptTimePrecise` on Windows). The shared `MonotonicClock.instance` singleton is the same timeline the package uses internally; constructing an instance (or first accessing `MonotonicClock.instance`) before `NtsRustLib.init()` / `NtsRustLib.initMock()` throws a `StateError`. `nowMicros()`, `elapsedSince(startMicros)`. |
| `NtsTimeSample` | `utcUnixMicros`, `roundTripMicros`, `serverStratum`, `aeadId`, `freshCookies`, `phaseTimings`, `trustBackend`. `roundTripMicros` is the UDP-phase wall-clock cost; the four pre-NTP phases live on `phaseTimings`; `trustBackend` records which trust-anchor backend the post-handshake TLS verification chose. |
| `NtsWarmCookiesOutcome` | `freshCookies`, `phaseTimings`, `trustBackend`. The UDP phase does not run on this path, so only KE-pipeline timings are populated; `trustBackend` carries the same per-handshake attribution as on `NtsTimeSample`. |
| `PhaseTimings` | `dnsMicros`, `connectMicros`, `tlsHandshakeMicros`, `keRecordIoMicros`. Microsecond-resolution wall-clock breakdown of the four pre-NTP phases of an `ntsQuery` / `ntsWarmCookies` call. Phases that did not run report `0`. See ARCHITECTURE.md's "Phase attribution and timings" section. |
| `TimeoutPhase` | `bridgeSaturation`, `dnsSaturation`, `dnsTimeout`, `connect`, `tls`, `keRecordIo`, `ntp`. Carried as the payload of `NtsError.timeout` so callers can attribute a budget exhaustion to a specific phase without parsing diagnostic strings. `bridgeSaturation` is Dart-authored (budget elapsed while queued at the bridge admission gate, before any FFI dispatch) and always carries a `null` `trustBackend`. |
| `NtsDnsPoolStats` | `inFlight`, `highWaterMark`, `recovered`, `refused`. Process-wide pool counters; relaxed-atomic snapshot. |
| `NtsTrustStatus` | `defaultClientBackend`, `defaultBackendPlatformCount`, `defaultBackendHybridCount`, `defaultBackendWebpkiCount`, `defaultBackendCustomCount`, `androidPlatformInitSucceeded`, `androidHybridFallbackCount`. Returned by `ntsTrustStatus()`; the four `defaultBackend*Count` fields partition the default singleton's resolution history by backend. Per-counter monotonic across consecutive snapshots. |
| `TrustMode` | `platformWithFallback` (default; build-time fallback to the `webpki-roots` static bundle on `build_with_native_verifier` failure), `platformOnly` (refuses the build-time silent fallback; `build_with_native_verifier` failure surfaces as `NtsError.trustBackendUnavailable`), `bundledOnly` (validates only against the bundled `webpki-roots` static set — no platform-store consultation, eliminating TLS-inspection exposure at the cost of rejecting private/enterprise-CA certificates), `custom` (validates only against caller-supplied roots passed as `customRoots` on the `NtsClient` constructor, PEM or DER). Caller-selected at `NtsClient` construction; immutable for the life of the client. See the per-variant dartdoc for the Android `HybridVerifier`'s separate per-chain interaction. |
| `TrustBackend` | `platform` (OS trust store via `rustls-platform-verifier`), `platformWithHybridFallback` (Android-only — platform verifier's view was overridden by the `webpki-roots` fallback for a curated platform-failure shape such as Let's Encrypt R12 missing-OCSP-AIA chains), `webpkiRoots` (build-time fallback to the static bundle; loses visibility into MDM / user-installed roots), `custom` (caller-supplied custom root certificates authenticated the chain). Carried per-handshake on `NtsTimeSample.trustBackend` / `NtsWarmCookiesOutcome.trustBackend`, also exposed process-globally via `NtsTrustStatus.defaultClientBackend`. |
| `NtsError` | Sealed class: `invalidSpec`, `network`, `keProtocol`, `ntpProtocol`, `authentication`, `timeout(TimeoutPhase)`, `noCookies`, `trustBackendUnavailable`, `internal`. |

`ntsGetTime`, `ntsQuery`, and `ntsWarmCookies` ship as a hand-written
wrapper around the bundled FFI surface; consumers can omit `timeout`,
`dnsConcurrencyCap`, `bridgeConcurrencyCap`, and `verificationTime`
to inherit the package defaults, and future internal-only Rust
signature changes do not propagate as breaking call-site edits. See
[ARCHITECTURE.md](ARCHITECTURE.md)'s "Public API
stability layer" section for the contract.

Three tuning parameters deserve a short orientation here; the full
mechanics live in [ARCHITECTURE.md](ARCHITECTURE.md) ("Timeout
budget and bounded DNS", "Bridge admission gate") and in each
constant's dartdoc.

- **`timeout`** is a single wall-clock budget anchored at the
  start of the call: DNS, TCP connect, TLS handshake, KE record
  I/O, and the UDP exchange all draw from one shrinking deadline,
  so no phase can stretch the total cost past the caller's budget.
  Exhaustion at any phase surfaces as `NtsError.timeout` carrying
  the `TimeoutPhase` that ran out; use a `switch` expression on
  `NtsError` for exhaustive failure handling. The FFI boundary is
  millisecond-resolution: a sub-millisecond `timeout` component is
  rounded up to the next whole millisecond, and sub-millisecond
  `verificationTime` precision is truncated to whole milliseconds
  since the epoch — microseconds do not round-trip through either
  parameter.
- **`dnsConcurrencyCap`** (default **4**) bounds in-flight
  `getaddrinfo` worker threads process-wide. `getaddrinfo` is
  non-cancellable, so a stalled lookup is detached rather than
  killed; the cap bounds thread-stack accumulation when a resolver
  blackholes traffic. Values must lie in `1..4294967295` (`0` is
  rejected as `NtsError.invalidSpec`); saturation surfaces as
  `NtsError.timeout`.
- **`bridgeConcurrencyCap`** (default **4**) bounds how many of
  this package's calls occupy `flutter_rust_bridge` worker threads
  at once. Excess calls queue on the Dart side holding no worker;
  queue wait is charged against `timeout`, and a budget that
  expires while queued fails with `TimeoutPhase.bridgeSaturation`
  without ever dispatching. Same validation range as the DNS cap;
  the gate is isolate-local, while the DNS counter is process-wide.

The two caps compose rather than conflict: with the bridge cap at or
below the DNS cap (the defaults are both **4**), live calls alone
can never saturate the DNS pool. For high distinct-host fan-out,
raise both caps together; ARCHITECTURE.md covers the mixed-cap
admission semantics and the skewed-cap trade-offs.

## Running the examples

Everything above covers integrating `nts` as a library dependency in
your own app. The repository additionally ships runnable reference
surfaces under [`example/`](example/), in increasing order of
complexity:

- **[`example/main.dart`](example/main.dart)** — the minimal
  single-file usage snippet: one authenticated NTPv4 query plus an
  exhaustive `NtsError` switch. Start here.
- **Flutter GUI** (`example/lib/`) — visual showcase with a server
  catalog, favourites, region filtering, and a unified live log:

  ```bash
  cd example
  flutter run -d macos -t lib/main.dart
  ```

  The GUI drives the real Rust bridge by default and falls back to
  an in-memory mock (with an explanatory banner) if the dylib cannot
  be loaded; pass `--dart-define=NTS_BRIDGE=mock` to opt into the
  mock explicitly. See the [GUI User Manual](example/GUI_GUIDE.md)
  for navigation, the **NTS Query** / **Warm Cookies** actions, and
  how to read the status banners.
- **Dart CLI** (`example/bin/nts_cli.dart`) — scriptable companion
  for batched probing, cron jobs, and CI smoke checks. See the
  [CLI User Manual](example/CLI_GUIDE.md) for the positional host
  arguments and the `--port` / `--timeout` / `--warm` / `--mock` /
  `--json` / `--exit-on-error` flags.

All surfaces share the same Rust-backed bridge and the same
formatting helpers; see the [example README](example/README.md) for
the internal wiring.

## Technical reference

For internals, contribution workflow, and operational tuning:

- **[ARCHITECTURE.md](ARCHITECTURE.md)** — Dart ↔ FRB ↔ Rust layering,
  module-by-module breakdown of the Rust crate, and the repository
  layout.
- **[DEVELOPMENT.md](DEVELOPMENT.md)** — Rust toolchain, regenerating
  FRB bindings, the `check_bindings.dart` drift gate, running Rust /
  Dart tests, and the `verbose_logs` Native Assets user-define for
  enabling `rustls` trace output.
- **[RFC 8915](https://datatracker.ietf.org/doc/html/rfc8915)** —
  Official IETF specification for Network Time Security.

## Contact

Maintainer: Nicholas Llewellyn — `nllewelln@gmail.com`. For bugs and
feature requests, prefer
[GitHub issues](https://github.com/nick-llewellyn/nts/issues); for
private security reports, see [`SECURITY.md`](SECURITY.md).

## License

MIT. See [`LICENSE`](LICENSE).

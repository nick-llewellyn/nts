# nts

[![CI](https://github.com/nick-llewellyn/nts/actions/workflows/ci.yml/badge.svg)](https://github.com/nick-llewellyn/nts/actions/workflows/ci.yml)
[![Fuzzing Status](https://github.com/nick-llewellyn/nts/actions/workflows/fuzz.yml/badge.svg)](https://github.com/nick-llewellyn/nts/actions/workflows/fuzz.yml)
[![CodeQL](https://github.com/nick-llewellyn/nts/actions/workflows/codeql.yml/badge.svg)](https://github.com/nick-llewellyn/nts/actions/workflows/codeql.yml)
[![Cargo Audit](https://github.com/nick-llewellyn/nts/actions/workflows/audit.yml/badge.svg)](https://github.com/nick-llewellyn/nts/actions/workflows/audit.yml)
[![Dependabot](https://img.shields.io/badge/dependabot-enabled-blue.svg?logo=dependabot&logoColor=white)](https://github.com/nick-llewellyn/nts/network/updates)
[![codecov](https://codecov.io/gh/nick-llewellyn/nts/graph/badge.svg)](https://codecov.io/gh/nick-llewellyn/nts)
[![Quality Gate Status](https://sonarcloud.io/api/project_badges/measure?project=nick-llewellyn_nts&metric=alert_status)](https://sonarcloud.io/dashboard?id=nick-llewellyn_nts)
[![Socket](https://img.shields.io/badge/socket-monitored-C93CD7?logo=socket&logoColor=white)](https://socket.dev)
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

This package gives Dart and Flutter apps a single async call that
returns an authenticated UTC sample, with the protocol details
delegated to a bundled native implementation. See
[ARCHITECTURE.md](ARCHITECTURE.md) for the underlying RFC 8915 layering
and cryptographic specifics.

## Getting Started

### Install

```bash
flutter pub add nts
```

The package depends on the Flutter SDK and ships a Flutter plugin
module on Android (since `1.4.0`), so it must be consumed from a
Flutter app — `dart pub add nts` from a pure-Dart project will not
resolve.

### Platform support

| Platform | Native bootstrap | Consumer action |
|---|---|---|
| Android | Auto via bundled `NtsPlugin` (since `1.4.0`) | None beyond `flutter pub add nts` on the default Flutter/Gradle setup. See the `FAIL_ON_PROJECT_REPOS` note below. |
| iOS | None required | None. |
| macOS | None required | None. |
| Linux | None required | None. |
| Windows | None required | None. |

The Android row assumes the standard Flutter/Gradle setup. Hosts that opt
in to `dependencyResolutionManagement.repositoriesMode =
RepositoriesMode.FAIL_ON_PROJECT_REPOS` in `settings.gradle.kts` (uncommon
for Flutter apps; not the `flutter create` default) reject the
project-level Maven injection the plugin performs from
`android/build.gradle.kts`, and must declare the on-disk
`rustls-platform-verifier-android` repository themselves under
`dependencyResolutionManagement.repositories` in `settings.gradle.kts`.
The file path is the one printed by `cargo metadata --format-version 1
--manifest-path <pub-cache>/nts-X.Y.Z/rust/Cargo.toml` and is stable for
the lifetime of the resolved Cargo workspace; the rationale comment in
`android/build.gradle.kts` documents the same constraint.

Every platform additionally requires `await NtsRustLib.init()` once
during application startup before the first `ntsQuery` /
`ntsWarmCookies` call; see "Initialization has two layers" below
for the rationale. Web and WebAssembly are unsupported: NTS-KE
needs a raw TCP socket on `:4460` and NTPv4 needs a raw UDP
socket on `:123`, neither of which is reachable from a browser
tab, and the underlying `rustls` + `ring` stack has no
`wasm32-unknown-unknown` target.

### Use

```dart
import 'package:nts/nts.dart';

Future<void> main() async {
  // 1. Initialize the FRB bridge exactly once, before anything else
  //    in this package. This loads the bundled Rust binary that does
  //    the actual NTS-KE handshake and AEAD-NTP exchange and wires
  //    the Dart-side dispatch table. Required on every platform.
  await NtsRustLib.init();

  // 2. Pick an RFC 8915 NTS-KE endpoint. Port 4460 is the IANA default.
  final spec = NtsServerSpec(host: 'time.cloudflare.com', port: 4460);

  // 3. Query. The first call handshakes; later calls reuse cached keys.
  //    The returned sample is the raw protocol output: a server
  //    transmit timestamp plus the measured round-trip time. Production
  //    callers should burst, filter, and apply RTT/2 compensation; see
  //    "Production Considerations" below for the why.
  final sample = await ntsQuery(spec: spec, timeoutMs: 5000);

  final utc = DateTime.fromMicrosecondsSinceEpoch(
    sample.utcUnixMicros,
    isUtc: true,
  );
  print('utc=$utc  rtt=${sample.roundTripMicros}µs');
}
```

**Initialization has two layers.** Get them straight before deciding
what your host code needs to do.

1. **Native platform bootstrap** (Android only, automatic). On Android
   the bundled `NtsPlugin` captures the `JavaVM` + application
   `Context` that `rustls-platform-verifier` needs to reach the system
   `X509TrustManager`. It runs from `GeneratedPluginRegistrant` before
   Dart `main()` executes, so adding `nts` to your `pubspec.yaml` is
   enough — there is no `MainActivity` shim, JNI symbol, or
   `app/build.gradle.kts` Maven entry to maintain on the default
   Flutter/Gradle setup. (Hosts that enable
   `dependencyResolutionManagement.repositoriesMode =
   FAIL_ON_PROJECT_REPOS` in `settings.gradle.kts` are an exception:
   that mode rejects the project-level Maven injection the plugin
   does from its own `build.gradle.kts`, so those hosts must declare
   the on-disk `rustls-platform-verifier-android` repository under
   `dependencyResolutionManagement.repositories` themselves. See the
   "Platform support" callout above.) iOS, macOS, Linux, and Windows
   have no equivalent step. Hosts that bypass the standard Flutter
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
   the Dart isolate exists. Calling `ntsQuery` or `ntsWarmCookies`
   before `NtsRustLib.init()` resolves raises an error. In a Flutter
   app, do it right after `WidgetsFlutterBinding.ensureInitialized()`
   in `main()`; subsequent invocations are no-ops, so it is safe to
   call from a shared bootstrap path.

A complete, runnable version that demonstrates the recommended
warm-burst-filter-compensate flow with exhaustive `NtsError` handling
lives in [`example/main.dart`](example/main.dart). For valid hostnames
to plug into `NtsServerSpec`, see the community-maintained
[NTS server list](https://github.com/jauderho/nts-servers).

### Upgrading from `1.3.x`

`1.4.0` is a breaking-ABI release for the bundled Rust crate
(`nts_rust 0.3.0`). The JNI symbol exported from
`rust/src/android_init.rs` moved from
`Java_com_nts_example_RustlsBootstrap_nativeInit` to
`Java_com_nllewellyn_nts_PlatformInit_nativeInit`, and the auto-init
plugin contributes the Android Maven repository, AAR dependency, and
ProGuard / R8 keep rules itself. Hosts that hand-rolled the `1.3.x`
bootstrap (an in-app `RustlsBootstrap.kt`-style JNI shim, a
`MainActivity.onCreate` call into it, an `app/build.gradle.kts` Maven
block, and matching keep rules) should drop that scaffolding when
they bump `nts`; an unmodified shim's `external fun nativeInit` no
longer resolves against the dylib's exports, so the first invocation
crashes the host app with `UnsatisfiedLinkError`. In the documented
`1.3.x` integration shape that bootstrap call runs from
`MainActivity.onCreate` before `super.onCreate(...)`, so the failure
fires at process start — well before any TLS handshake is attempted.
See [CHANGELOG.md](CHANGELOG.md) under `1.4.0` → "Migrating from
`1.3.x`" for the exhaustive deletion checklist and the
`com.nllewellyn.nts.PlatformInit.init(context)` escape hatch for
custom embeddings.

## Production Considerations

`ntsQuery` exposes the RFC 8915 protocol primitives — a single
authenticated round-trip with the server's transmit timestamp and the
locally measured RTT — not a finished synchronized clock. A single raw
sample is sufficient for an authenticated "what time does this server
claim it is right now?" probe, but anything that anchors application
logic to wall-clock time should add two cheap layers on top:

1. **Burst sampling.** A single NTPv4 reply carries whatever jitter the
   network and the server's queueing happened to introduce on that one
   packet. Calling `ntsWarmCookies` once and then `ntsQuery` several
   times in quick succession — one query per cookie the server
   delivered, since RFC 8915 §4 leaves the pool size to server policy
   and the returned `NtsWarmCookiesOutcome.freshCookies` reports the
   actual count — produces a small distribution you can reason about
   statistically. Pick the sample
   with the smallest
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
offset reused across many reads.

The package stops at protocol primitives by design: the right filter
(lowest-RTT, median, Marzullo across multiple servers, weighted by
stratum), the right resampling cadence, and the right way to project
the offset onto `DateTime.now()` are all workload specific. The
[`example/main.dart`](example/main.dart) snippet shows the minimum
burst-filter-compensate flow described above.

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
the [Production Considerations](#production-considerations)
section) bounds the *amplification* exposure of a saturated
hostname-resolution path, but does not gate *destinations* — that
gate is the caller's responsibility.

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

### Non-Flutter Dart callers must pass `externalLibrary` explicitly

The FRB-generated default loader
(`NtsRustLib.kDefaultExternalLibraryLoaderConfig`) advertises
`rust/target/release/` as the `ioDirectory` for the bundled dylib.
Inside a Flutter host the Native Assets pipeline supplies a
controlled absolute load path before that default ever runs, so the
relative directory is unreachable. Outside Flutter — a `dart run`
CLI, a Dart server runtime, an integration-test harness, anything
else that imports `package:nts` directly — the relative directory
*is* what the loader resolves against the current working
directory.

A non-Flutter call site that does `await NtsRustLib.init()` (no
`externalLibrary:` argument) while running from a working directory
an attacker can influence is therefore a library-hijack surface:
dropping a malicious `rust/target/release/libnts_rust.dylib` (or
`.so` / `.dll`) into that directory yields arbitrary code execution
under the calling process's privileges. The hijack is independent
of NTS itself — `NtsRustLib.init()` runs before any of this package's
TLS / NTS code is reached — but the package is the vehicle.

The mitigation is the pattern the bundled
[`example/bin/nts_cli.dart`](example/bin/nts_cli.dart) already
uses: resolve an absolute path to the dylib yourself (or accept one
on the command line) and pass it through explicitly:

```dart
import 'package:nts/nts.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart'
    show ExternalLibrary;

await NtsRustLib.init(
  externalLibrary: ExternalLibrary.open('/absolute/path/to/libnts_rust.dylib'),
);
```

The absolute path should come from a trusted source (a packaged
install location, an environment variable owned by the deploying
operator, etc.) — not from a relative lookup against the working
directory. Flutter callers can keep using the bare
`await NtsRustLib.init()` form: Native Assets supplies the load path
before the relative fallback can fire.

## API summary

| Symbol | Purpose |
|--------|---------|
| `NtsRustLib.init()` | Load the native dylib and wire the FRB v2 dispatch table on the calling isolate. Await once before any other call, on every platform. (Android-side `rustls-platform-verifier` JNI bootstrap is handled separately by the bundled `NtsPlugin` before `main()`; see "Initialization has two layers" above.) |
| `ntsQuery({required spec, timeoutMs = kDefaultTimeoutMs, dnsConcurrencyCap = kDefaultDnsConcurrencyCap})` | One authenticated NTPv4 exchange. Returns `NtsTimeSample`. |
| `ntsWarmCookies({required spec, timeoutMs = kDefaultTimeoutMs, dnsConcurrencyCap = kDefaultDnsConcurrencyCap})` | Force a fresh NTS-KE handshake. Returns `NtsWarmCookiesOutcome`. |
| `ntsDnsPoolStats()` | Synchronous snapshot of the bounded DNS resolver pool counters (`inFlight`, `highWaterMark`, `recovered`, `refused`). See ARCHITECTURE.md for the saturation signature. |
| `ntsTrustStatus()` | Synchronous snapshot of the process-global trust-anchor diagnostic state. Returns the default singleton's most-recent backend, the Android JNI bootstrap success flag, and the cumulative Android hybrid-fallback acceptance count. Cheap enough for a UI poll loop. |
| `kDefaultTimeoutMs` | Package default for `timeoutMs` (5000). |
| `kDefaultDnsConcurrencyCap` | Package default for `dnsConcurrencyCap` (`4`, sized for mobile pthread-stack budgets — see the constant's dartdoc). |
| `NtsServerSpec(host, port)` | NTS-KE endpoint (port 4460 by default). |
| `NtsTimeSample` | `utcUnixMicros`, `roundTripMicros`, `serverStratum`, `aeadId`, `freshCookies`, `phaseTimings`, `trustBackend`. `roundTripMicros` is the UDP-phase wall-clock cost; the four pre-NTP phases live on `phaseTimings`; `trustBackend` records which trust-anchor backend the post-handshake TLS verification chose. |
| `NtsWarmCookiesOutcome` | `freshCookies`, `phaseTimings`, `trustBackend`. The UDP phase does not run on this path, so only KE-pipeline timings are populated; `trustBackend` carries the same per-handshake attribution as on `NtsTimeSample`. |
| `PhaseTimings` | `dnsMicros`, `connectMicros`, `tlsHandshakeMicros`, `keRecordIoMicros`. Microsecond-resolution wall-clock breakdown of the four pre-NTP phases of an `ntsQuery` / `ntsWarmCookies` call. Phases that did not run report `0`. See ARCHITECTURE.md's "Phase attribution and timings" section. |
| `TimeoutPhase` | `dnsSaturation`, `dnsTimeout`, `connect`, `tls`, `keRecordIo`, `ntp`. Carried as the payload of `NtsError.timeout` so callers can attribute a budget exhaustion to a specific phase without parsing diagnostic strings. |
| `NtsDnsPoolStats` | `inFlight`, `highWaterMark`, `recovered`, `refused`. Process-wide pool counters; relaxed-atomic snapshot. |
| `NtsTrustStatus` | `defaultClientBackend`, `androidPlatformInitSucceeded`, `androidHybridFallbackCount`. Returned by `ntsTrustStatus()`; per-counter monotonic across consecutive snapshots. |
| `TrustMode` | `platformWithFallback` (default; build-time fallback to the `webpki-roots` static bundle on `build_with_native_verifier` failure), `platformOnly` (refuses the build-time silent fallback; `build_with_native_verifier` failure surfaces as `NtsError.trustBackendUnavailable`). Caller-selected at `NtsClient` construction; immutable for the life of the client. See the per-variant dartdoc for the Android `HybridVerifier`'s separate per-chain interaction. |
| `TrustBackend` | `platform` (OS trust store via `rustls-platform-verifier`), `platformWithHybridFallback` (Android-only — platform verifier's view was overridden by the `webpki-roots` fallback for a curated platform-failure shape such as Let's Encrypt R12 missing-OCSP-AIA chains), `webpkiRoots` (build-time fallback to the static bundle; loses visibility into MDM / user-installed roots). Carried per-handshake on `NtsTimeSample.trustBackend` / `NtsWarmCookiesOutcome.trustBackend`, also exposed process-globally via `NtsTrustStatus.defaultClientBackend`. |
| `NtsError` | Sealed class: `invalidSpec`, `network`, `keProtocol`, `ntpProtocol`, `authentication`, `timeout(TimeoutPhase)`, `noCookies`, `trustBackendUnavailable`, `internal`. |

`ntsQuery` and `ntsWarmCookies` ship as a hand-written wrapper around
the bundled FFI surface; consumers can omit `timeoutMs` and
`dnsConcurrencyCap` to inherit the package defaults, and future
internal-only Rust signature changes do not propagate as breaking call-
site edits. See [ARCHITECTURE.md](ARCHITECTURE.md)'s "Public API
stability layer" section for the contract.

`timeoutMs` is a global wall-clock budget anchored at the start of
each call: it bounds DNS resolution, the NTS-KE TCP connect plus TLS
handshake plus record I/O, and the AEAD-NTPv4 UDP exchange as a single
shrinking deadline rather than rearming each phase independently. A
stalled `getaddrinfo` therefore cannot stretch the total cost past the
caller's budget, and the UDP recv inherits whatever portion of the
budget the KE leg did not consume. Use a `switch` expression on
`NtsError` for exhaustive failure handling; budget exhaustion at any
phase surfaces as `NtsError.timeout`.

`dnsConcurrencyCap` is a per-call ceiling on the number of in-flight
`getaddrinfo` worker threads the package will spawn process-wide. The
resolver is bounded by design — `getaddrinfo` is non-cancellable, so a
stalled lookup is detached and finishes in the background; this cap is
the primary defense against thread-stack accumulation when a recursive
resolver blackholes traffic. Omit the parameter (or pass
`kDefaultDnsConcurrencyCap`) to inherit the built-in default of **4**,
sized for the worst case on iOS / Android (~512 KB-1 MB of committed
pthread stack per leaked worker). Server-side callers that
legitimately need higher fan-out can override per call (`32`, `64`,
etc.); values must lie in `1..4294967295`, with literal `0` rejected
as `NtsError.invalidSpec` rather than silently substituting the
default the way the pre-4.0.0 wrapper did. The cap is compared
against the *global* counter, so two concurrent callers passing
different values share the same in-flight pool: the effective ceiling
at any moment is whichever caller is currently being admitted.
Saturation surfaces as `NtsError.timeout`.

## Demos & Examples

The repository ships three reference surfaces, in increasing order of
complexity:

- **[`example/main.dart`](example/main.dart)** — the minimal
  single-file usage snippet: one authenticated NTPv4 query plus an
  exhaustive `NtsError` switch. Start here.
- **Flutter GUI** (`example/lib/`) — visual showcase with a server
  catalog, favourites, region filtering, and a unified live log. See
  the [GUI User Manual](example/GUI_GUIDE.md) for navigation, the
  **NTS Query** / **Warm Cookies** actions, and how to read the
  status banners.
- **Dart CLI** (`example/bin/nts_cli.dart`) — scriptable companion
  for batched probing, cron jobs, and CI smoke checks. See the
  [CLI User Manual](example/CLI_GUIDE.md) for the positional host
  arguments and the `--port` / `--timeout` / `--warm` / `--mock` /
  `--json` / `--exit-on-error` flags.

Both showcase surfaces share the same Rust-backed bridge and the same
formatting helpers; see the [example README](example/README.md) for the
internal wiring.

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

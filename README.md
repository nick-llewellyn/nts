# nts

[![CI](https://github.com/nick-llewellyn/nts/actions/workflows/ci.yml/badge.svg)](https://github.com/nick-llewellyn/nts/actions/workflows/ci.yml)
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

(Pure-Dart projects can use `dart pub add nts`; the package itself
depends on the Flutter SDK because it ships through the Native Assets
pipeline.)

### Use

```dart
import 'package:nts/nts.dart';

Future<void> main() async {
  // 1. Initialize the native bridge exactly once, before anything else
  //    in this package. This loads the bundled Rust binary that does
  //    the actual NTS-KE handshake and AEAD-NTP exchange.
  await RustLib.init();

  // 2. Pick an RFC 8915 NTS-KE endpoint. Port 4460 is the IANA default.
  final spec = NtsServerSpec(host: 'time.cloudflare.com', port: 4460);

  // 3. Query. The first call handshakes; later calls reuse cached keys.
  //    The returned sample is the raw protocol output: a server
  //    transmit timestamp plus the measured round-trip time. Production
  //    callers should burst, filter, and apply RTT/2 compensation; see
  //    "Production Considerations" below for the why.
  final sample = await ntsQuery(spec: spec, timeoutMs: 5000);

  final utc = DateTime.fromMicrosecondsSinceEpoch(
    sample.utcUnixMicros.toInt(),
    isUtc: true,
  );
  print('utc=$utc  rtt=${sample.roundTripMicros}µs');
}
```

**Why the order matters.** `RustLib.init()` loads the bundled native
binary and wires the call table the rest of the API uses. Calling
`ntsQuery` before `init` completes raises an error because the bridge
isn't ready. In a Flutter app, do it right after
`WidgetsFlutterBinding.ensureInitialized()` in `main()`; subsequent
calls to `init` are no-ops, so it's safe to invoke from a shared
bootstrap path.

A complete, runnable version that demonstrates the recommended
warm-burst-filter-compensate flow with exhaustive `NtsError` handling
lives in [`example/main.dart`](example/main.dart). For valid hostnames
to plug into `NtsServerSpec`, see the community-maintained
[NTS server list](https://github.com/jauderho/nts-servers).

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
   and `ntsWarmCookies` returns the actual count — produces a small
   distribution you can reason about statistically. Pick the sample
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

## API summary

| Symbol | Purpose |
|--------|---------|
| `RustLib.init()` | Load the native bridge. Await once before any other call. |
| `ntsQuery({spec, timeoutMs, dnsConcurrencyCap})` | One authenticated NTPv4 exchange. Returns `NtsTimeSample`. |
| `ntsWarmCookies({spec, timeoutMs, dnsConcurrencyCap})` | Force a fresh NTS-KE handshake; returns cookie count. |
| `NtsServerSpec(host, port)` | NTS-KE endpoint (port 4460 by default). |
| `NtsTimeSample` | `utcUnixMicros`, `roundTripMicros`, `serverStratum`, `aeadId`, `freshCookies`. |
| `NtsError` | Sealed class: `invalidSpec`, `network`, `keProtocol`, `ntpProtocol`, `authentication`, `timeout`, `noCookies`, `internal`. |

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
resolver blackholes traffic. Pass `0` to inherit the built-in default
of **4**, sized for the worst case on iOS / Android (~512 KB-1 MB of
committed pthread stack per leaked worker). Server-side callers that
legitimately need higher fan-out can override per call (`32`, `64`,
etc.). The cap is compared against the *global* counter, so two
concurrent callers passing different values share the same in-flight
pool: the effective ceiling at any moment is whichever caller is
currently being admitted. Saturation surfaces as `NtsError.timeout`.

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

## License

MIT. See [`LICENSE`](LICENSE).

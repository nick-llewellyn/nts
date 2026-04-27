# nts

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

A complete, runnable version with exhaustive `NtsError` handling lives
in [`example/example.dart`](example/example.dart). For valid hostnames
to plug into `NtsServerSpec`, see the community-maintained
[NTS server list](https://github.com/jauderho/nts-servers).

## API summary

| Symbol | Purpose |
|--------|---------|
| `RustLib.init()` | Load the native bridge. Await once before any other call. |
| `ntsQuery({spec, timeoutMs})` | One authenticated NTPv4 exchange. Returns `NtsTimeSample`. |
| `ntsWarmCookies({spec, timeoutMs})` | Force a fresh NTS-KE handshake; returns cookie count. |
| `NtsServerSpec(host, port)` | NTS-KE endpoint (port 4460 by default). |
| `NtsTimeSample` | `utcUnixMicros`, `roundTripMicros`, `serverStratum`, `aeadId`, `freshCookies`. |
| `NtsError` | Sealed class: `invalidSpec`, `network`, `keProtocol`, `ntpProtocol`, `authentication`, `timeout`, `noCookies`, `internal`. |

`timeoutMs` is applied independently to the KE handshake and the UDP
recv leg. Use a `switch` expression on `NtsError` for exhaustive
failure handling.

## Demos & Examples

The repository ships three reference surfaces, in increasing order of
complexity:

- **[`example/example.dart`](example/example.dart)** — the minimal
  single-file snippet shown on the pub.dev "Example" tab. Start here.
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

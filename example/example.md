# nts — minimal usage snippet

The smallest end-to-end use of `package:nts`: one authenticated NTPv4
exchange against `time.cloudflare.com` over RFC 8915 NTS-KE, with an
exhaustive switch on every `NtsError` variant.

The same code ships as a runnable Flutter target at
[`example/main.dart`](main.dart).

```dart
// Minimal `package:nts` usage example — a warm-then-query flow against
// `time.cloudflare.com` over RFC 8915. Phase 1 fills the per-host cookie
// jar with a fresh NTS-KE handshake; phase 2 spends one of those cookies
// on an authenticated NTPv4 exchange.
//
// Run from a Flutter target (`flutter run -t example/main.dart`)
// so the Native Assets pipeline bundles the Rust dylib. Plain
// `dart run` does not invoke build hooks; see `example/bin/nts_cli.dart`
// for the explicit `ExternalLibrary.open` loader pattern needed there.

// ignore_for_file: avoid_print

import 'package:nts/nts.dart';

Future<void> main() async {
  // Bridge bootstrap. Resolves the bundled `libnts_rust.{dylib|so|dll}`
  // through the stable Native Assets API and wires the FRB dispatch
  // table. Must be awaited exactly once before any nts* entry point;
  // subsequent calls are no-ops.
  await RustLib.init();

  // RFC 8915 NTS-KE endpoint. Port 4460 is the IANA-assigned default;
  // any host listed at <https://github.com/jauderho/nts-servers> works.
  const spec = NtsServerSpec(host: 'time.cloudflare.com', port: 4460);

  try {
    // Phase 1 — warm the cookie jar. Forces a fresh TLS 1.3 NTS-KE
    // handshake against `spec`, ingests the delivered cookie pool, and
    // returns how many cookies the server handed out (typically 8).
    // Replaces any cached session for that `spec`, so subsequent
    // `ntsQuery` calls skip the KE leg until the jar drains. Useful at
    // startup or whenever the NTS-KE cost should be amortized away from
    // a time-critical path.
    final warmed = await ntsWarmCookies(spec: spec, timeoutMs: 5000);
    print('warmed   = $warmed cookies');

    // Phase 2 — spend one cookie on an authenticated NTPv4 exchange.
    // The session warmed above covers the AEAD keys and the NTPv4
    // destination, so steady-state cost is one UDP round-trip. The
    // 5-second timeout applies independently to the KE leg (a no-op
    // here because the jar is full) and the UDP recv leg.
    final sample = await ntsQuery(spec: spec, timeoutMs: 5000);

    final utc = DateTime.fromMicrosecondsSinceEpoch(
      sample.utcUnixMicros.toInt(),
      isUtc: true,
    );
    final rttMs = sample.roundTripMicros.toInt() / 1000.0;

    print('utc      = ${utc.toIso8601String()}');
    print('rtt      = ${rttMs.toStringAsFixed(2)} ms');
    print('stratum  = ${sample.serverStratum}');
    print('aead-id  = ${sample.aeadId}');
    print('cookies  = ${sample.freshCookies}');
  } on NtsError catch (err) {
    // `NtsError` is a `freezed` sealed class — exhaustive switch
    // expressions catch new variants at compile time if the package
    // ever grows them. Both `ntsWarmCookies` and `ntsQuery` surface
    // failures through this same hierarchy.
    final detail = switch (err) {
      NtsError_InvalidSpec(:final field0) => 'invalid spec: $field0',
      NtsError_Network(:final field0) => 'network: $field0',
      NtsError_KeProtocol(:final field0) => 'NTS-KE: $field0',
      NtsError_NtpProtocol(:final field0) => 'NTP: $field0',
      NtsError_Authentication(:final field0) => 'AEAD auth: $field0',
      NtsError_Timeout() => 'timeout',
      NtsError_NoCookies() => 'no cookies returned',
      NtsError_Internal(:final field0) => 'internal: $field0',
    };
    print('nts call failed: $detail');
  }
}
```

## Want the GUI?

The full Flutter showcase lives at
[`example/lib/main.dart`](lib/main.dart) and is invoked with an
explicit target:

```sh
# from the example directory
flutter run -t lib/main.dart

# from the repo root
flutter run -t example/lib/main.dart
```

See [`example/README.md`](README.md) for the three entry points
(snippet, GUI, CLI) and the bridge-mode toggles.

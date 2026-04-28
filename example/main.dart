// Minimal `package:nts` usage example — a warm-then-burst flow against
// `time.cloudflare.com` over RFC 8915. Phase 1 fills the per-host cookie
// jar with a fresh NTS-KE handshake; phase 2 spends every cookie the
// server delivered on authenticated NTPv4 exchanges, picks the
// lowest-RTT reply, and applies the standard symmetric-path delay
// correction to recover the server's clock at the moment the chosen
// reply arrived.
//
// `ntsQuery` returns the raw protocol primitives — server transmit
// timestamp plus measured round-trip time — not a finished synchronized
// clock. The burst-and-pick pattern below is the minimum a production
// caller needs on top to get a stable offset; see `README.md`'s
// "Production Considerations" section for the full rationale.
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
    // returns how many cookies the server handed out. RFC 8915 §4
    // leaves that count to server policy, so the burst below is sized
    // off this return value rather than any fixed constant. Replaces
    // any cached session for that `spec`, so subsequent `ntsQuery`
    // calls skip the KE leg until the jar drains. Useful at startup or
    // whenever the NTS-KE cost should be amortized away from a
    // time-critical path.
    final warmed = await ntsWarmCookies(
      spec: spec,
      timeoutMs: 5000,
      dnsConcurrencyCap: 0,
    );
    print('warmed   = $warmed cookies');

    // Phase 2 — spend the warmed cookies on authenticated NTPv4
    // exchanges. Each `ntsQuery` reuses the warmed AEAD keys, so the
    // steady-state cost is one UDP round-trip per call. Collect every
    // sample so we can score them against each other below.
    final samples = <NtsTimeSample>[];
    for (var i = 0; i < warmed; i++) {
      samples.add(
        await ntsQuery(spec: spec, timeoutMs: 5000, dnsConcurrencyCap: 0),
      );
    }

    // Pick the sample with the smallest measured round-trip. NTP's
    // symmetric-path assumption is most accurate when the path is
    // shortest, so the lowest-RTT reply yields the smallest residual
    // offset error after compensation. This is the basic statistical
    // filter every production NTP/NTS client implements; more
    // sophisticated callers can also weight by stratum or run Marzullo's
    // algorithm across multiple servers.
    final best = samples.reduce(
      (a, b) => a.roundTripMicros <= b.roundTripMicros ? a : b,
    );

    // Apply the standard symmetric-path correction: assume the one-way
    // delay is half the round-trip, so the server's clock at the moment
    // its reply landed locally is `utc_unix_micros + rtt / 2`. The
    // package returns the raw server transmit timestamp on purpose;
    // applying this offset is the caller's responsibility because the
    // "right" filter (median, lowest-RTT, Marzullo, …) is workload
    // specific.
    final adjustedMicros =
        best.utcUnixMicros.toInt() + (best.roundTripMicros.toInt() ~/ 2);
    final adjustedUtc = DateTime.fromMicrosecondsSinceEpoch(
      adjustedMicros,
      isUtc: true,
    );
    final rttMs = best.roundTripMicros.toInt() / 1000.0;

    print('samples  = ${samples.length}');
    print('best-rtt = ${rttMs.toStringAsFixed(2)} ms');
    print('utc      = ${adjustedUtc.toIso8601String()}  (RTT/2-compensated)');
    print('stratum  = ${best.serverStratum}');
    print('aead-id  = ${best.aeadId}');
    print('cookies  = ${best.freshCookies}');
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

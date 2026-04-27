// Minimal `package:nts` usage example — one authenticated NTPv4
// exchange against `time.cloudflare.com` over RFC 8915.
//
// Run from a Flutter target (`flutter run -t example/example.dart`)
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
    // First call performs the full TLS 1.3 NTS-KE handshake, then the
    // AEAD-protected NTPv4 query. Subsequent calls against the same
    // `spec` reuse the cached keys and spend a stored cookie, so
    // steady-state cost is one UDP round-trip. The 5-second timeout
    // applies independently to the KE leg and the UDP recv leg.
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
    // ever grows them.
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
    print('nts query failed: $detail');
  }
}

// Hand-written public DTOs for `package:nts`.
//
// These types form half of the package's stable public contract. The
// other half is `lib/src/api/errors.dart` (`NtsError` sealed class plus
// variants); the wrapper functions in `lib/src/api/nts.dart` accept and
// return only these hand-written types and convert across the
// FRB-generated boundary internally.
//
// Hand-rolling these types -- instead of re-exporting the generated
// equivalents from `lib/src/ffi/api/nts.dart` -- pins the package's
// SemVer surface: a Rust-side struct field rename, reorder, or type
// change no longer becomes a Dart source break for downstream callers.
// In particular, the integer fields here are plain `int` rather than
// `flutter_rust_bridge`'s `PlatformInt64` wrapper. See
// `ARCHITECTURE.md`'s "Public API stability layer" section for the
// rationale.

/// Address of an NTS-KE endpoint.
class NtsServerSpec {
  /// Hostname for TLS SNI and certificate validation.
  final String host;

  /// TCP port; pass `4460` (the IANA-assigned NTS-KE default,
  /// RFC 8915 §6) unless the deployment overrides it.
  final int port;

  /// Construct a spec for `host:port`.
  const NtsServerSpec({required this.host, required this.port});

  @override
  int get hashCode => Object.hash(host, port);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is NtsServerSpec && host == other.host && port == other.port);

  @override
  String toString() => 'NtsServerSpec(host: $host, port: $port)';
}

/// Microsecond-resolution wall-clock breakdown of a successful
/// `ntsQuery` or `ntsWarmCookies` call, surfaced on the `phaseTimings`
/// field of [NtsTimeSample] / [NtsWarmCookiesOutcome].
///
/// The four fields cover the KE-pipeline phases. The UDP send/recv
/// phase has no field of its own; `roundTripMicros` on [NtsTimeSample]
/// already covers it. Callers who want a "preNtp" wall-clock view can
/// sum the four fields here; the per-call total wall-clock is that sum
/// plus `roundTripMicros`.
///
/// Phases that did not run are reported as `0` rather than absent --
/// e.g. on a cache-hit query (no KE handshake), [connectMicros],
/// [tlsHandshakeMicros], and [keRecordIoMicros] are all `0` and
/// [dnsMicros] reflects only the UDP-path lookup of the NTPv4 host. On
/// a fresh-session query both KE-path and UDP-path DNS lookups run;
/// their costs are summed into a single [dnsMicros] value so callers
/// do not have to reason about which leg contributed.
class PhaseTimings {
  /// Sum of wall-clock microseconds spent in the bounded DNS resolver
  /// across both the KE-host lookup (when a handshake runs) and the
  /// NTPv4-host lookup. See `ARCHITECTURE.md`'s "Timeout budget and
  /// bounded DNS" section for the resolver semantics.
  final int dnsMicros;

  /// Wall-clock microseconds spent in the per-address
  /// `TcpStream::connect_timeout` loop during the KE handshake.
  /// `0` on cache-hit queries.
  final int connectMicros;

  /// Wall-clock microseconds spent on the rustls handshake during the
  /// KE pipeline (ClientHello/ServerHello/Finished round-trip plus the
  /// initial NTS-KE request write in TLS 1.3). `0` on cache-hit queries.
  final int tlsHandshakeMicros;

  /// Wall-clock microseconds spent in the chunked record-read loop
  /// reading the server's NTS-KE response. `0` on cache-hit queries.
  final int keRecordIoMicros;

  /// Construct a phase-timings snapshot. All four fields are required;
  /// pass `0` for phases that did not run on the call being described.
  const PhaseTimings({
    required this.dnsMicros,
    required this.connectMicros,
    required this.tlsHandshakeMicros,
    required this.keRecordIoMicros,
  });

  @override
  int get hashCode => Object.hash(
    dnsMicros,
    connectMicros,
    tlsHandshakeMicros,
    keRecordIoMicros,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PhaseTimings &&
          dnsMicros == other.dnsMicros &&
          connectMicros == other.connectMicros &&
          tlsHandshakeMicros == other.tlsHandshakeMicros &&
          keRecordIoMicros == other.keRecordIoMicros);

  @override
  String toString() =>
      'PhaseTimings(dnsMicros: $dnsMicros, connectMicros: $connectMicros, '
      'tlsHandshakeMicros: $tlsHandshakeMicros, '
      'keRecordIoMicros: $keRecordIoMicros)';
}

/// Successful authenticated NTPv4 sample.
///
/// This is the raw output of one protocol exchange, not a synchronized
/// clock. See `ntsQuery` for the recommended burst-and-RTT-compensation
/// pattern callers should layer on top.
class NtsTimeSample {
  /// Server transmit time as microseconds since the Unix epoch, taken
  /// directly from the NTPv4 reply. No correction for the one-way
  /// network delay between the server and this caller is applied; add
  /// `roundTripMicros / 2` to estimate the server's clock at the
  /// moment the reply arrived.
  final int utcUnixMicros;

  /// Wall-clock microseconds elapsed between the AEAD-NTPv4 UDP send
  /// and the matching recv. This *is* the UDP-phase wall-clock cost --
  /// there is no separate `udpSendRecvMicros` in [PhaseTimings] because
  /// that would publish the same fact in two fields.
  final int roundTripMicros;

  /// NTP stratum reported by the server (RFC 5905 §7.3).
  final int serverStratum;

  /// AEAD algorithm IANA ID negotiated during NTS-KE.
  final int aeadId;

  /// Number of fresh cookies recovered from the encrypted reply.
  final int freshCookies;

  /// Microsecond-resolution wall-clock breakdown of the pre-NTP
  /// phases of this call. Combined with [roundTripMicros] it accounts
  /// for the entire wall-clock cost of `ntsQuery`.
  final PhaseTimings phaseTimings;

  /// Construct a sample. Intended for the wrapper-layer conversion
  /// boundary and for test fixtures; production code receives instances
  /// from `ntsQuery`.
  const NtsTimeSample({
    required this.utcUnixMicros,
    required this.roundTripMicros,
    required this.serverStratum,
    required this.aeadId,
    required this.freshCookies,
    required this.phaseTimings,
  });

  @override
  int get hashCode => Object.hash(
    utcUnixMicros,
    roundTripMicros,
    serverStratum,
    aeadId,
    freshCookies,
    phaseTimings,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is NtsTimeSample &&
          utcUnixMicros == other.utcUnixMicros &&
          roundTripMicros == other.roundTripMicros &&
          serverStratum == other.serverStratum &&
          aeadId == other.aeadId &&
          freshCookies == other.freshCookies &&
          phaseTimings == other.phaseTimings);

  @override
  String toString() =>
      'NtsTimeSample(utcUnixMicros: $utcUnixMicros, '
      'roundTripMicros: $roundTripMicros, '
      'serverStratum: $serverStratum, aeadId: $aeadId, '
      'freshCookies: $freshCookies, phaseTimings: $phaseTimings)';
}

/// Successful outcome of `ntsWarmCookies`.
///
/// Pairs the cookie count with the per-phase wall-clock breakdown of
/// the handshake that produced them, mirroring [NtsTimeSample]'s
/// phase-attribution view for the handshake-only path callers use to
/// refill an empty cookie pool.
class NtsWarmCookiesOutcome {
  /// Number of fresh cookies the server delivered with the KE response.
  final int freshCookies;

  /// Microsecond-resolution wall-clock breakdown of the handshake that
  /// produced the cookies. The UDP NTP exchange is not part of this
  /// call, so [PhaseTimings.dnsMicros] reflects only the KE-host lookup.
  final PhaseTimings phaseTimings;

  /// Construct an outcome. Intended for the wrapper-layer conversion
  /// boundary and for test fixtures.
  const NtsWarmCookiesOutcome({
    required this.freshCookies,
    required this.phaseTimings,
  });

  @override
  int get hashCode => Object.hash(freshCookies, phaseTimings);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is NtsWarmCookiesOutcome &&
          freshCookies == other.freshCookies &&
          phaseTimings == other.phaseTimings);

  @override
  String toString() =>
      'NtsWarmCookiesOutcome(freshCookies: $freshCookies, '
      'phaseTimings: $phaseTimings)';
}

/// Snapshot of the bounded DNS resolver pool counters.
///
/// All counters are process-wide and include workers spawned by every
/// concurrent caller, including those that passed a different
/// `dnsConcurrencyCap` (the underlying pool is shared by design -- see
/// the `nts::dns` module docs for the global-counter rationale). The
/// snapshot is racy by construction: each counter is read with an
/// independent atomic Relaxed load, so combinations across counters
/// can be slightly stale -- e.g. [inFlight] lagging [recovered] by one
/// bump, or `inFlight > highWaterMark` for the few-nanosecond window
/// between a worker's admission `fetch_add` on `in_flight` and the
/// subsequent `fetch_max` on `high_water_mark`. The actual guarantee is
/// per-counter monotonicity in each counter's natural direction
/// (cumulative counters and [highWaterMark] never decrease across
/// consecutive snapshots; every loaded value is one the counter
/// actually held at some real moment), not a cross-counter invariant
/// within a single snapshot. The snapshot does not reset cumulative
/// counters; callers that want windowed measurements snapshot at `t0`
/// and `t1` and subtract.
///
/// Operators can use the four counters to distinguish three failure
/// modes that all collapse onto `NtsError.timeout` in the hot-path
/// error contract:
///
/// - **Healthy resolver, occasional bursts** -- [inFlight] oscillates
///   below the cap, [highWaterMark] plateaus a few steps above steady
///   state, [recovered] climbs in lockstep with traffic, [refused]
///   stays flat.
/// - **Cap-bound deployment** -- [refused] is climbing; raising the
///   `dnsConcurrencyCap` argument on `ntsQuery` / `ntsWarmCookies`
///   would lower the timeout error rate.
/// - **libc-level resolver wedge** -- [inFlight] is pinned at the cap,
///   [recovered] is flat, [refused] is climbing. The system resolver
///   is not making progress; raising the cap would only push more
///   threads into the same wedge.
class NtsDnsPoolStats {
  /// Live count of resolver workers currently pinned in the system
  /// resolver. The next admission decision will compare its `cap`
  /// argument against this number.
  final int inFlight;

  /// Largest value [inFlight] has reached since process start.
  /// Non-decreasing across consecutive snapshots, but not a
  /// cross-counter invariant within a single snapshot: see the
  /// class-level note on the transient window where
  /// `inFlight > highWaterMark` between a worker's admission
  /// increment and the subsequent `fetch_max`.
  final int highWaterMark;

  /// Cumulative count of detached workers that have completed and
  /// released their slot since process start. `BigInt` because the
  /// counter grows monotonically over a process lifetime and a 32-bit
  /// wraparound would be visible on long-running CLI / server builds
  /// with a saturated resolver.
  final BigInt recovered;

  /// Cumulative count of admission attempts that were refused because
  /// the cap was reached since process start. The expected delta when
  /// the resolver is healthy is zero.
  final BigInt refused;

  /// Construct a snapshot. Intended for the wrapper-layer conversion
  /// boundary and for test fixtures.
  const NtsDnsPoolStats({
    required this.inFlight,
    required this.highWaterMark,
    required this.recovered,
    required this.refused,
  });

  @override
  int get hashCode => Object.hash(inFlight, highWaterMark, recovered, refused);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is NtsDnsPoolStats &&
          inFlight == other.inFlight &&
          highWaterMark == other.highWaterMark &&
          recovered == other.recovered &&
          refused == other.refused);

  @override
  String toString() =>
      'NtsDnsPoolStats(inFlight: $inFlight, highWaterMark: $highWaterMark, '
      'recovered: $recovered, refused: $refused)';
}

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

  /// Trust-anchor backend that authenticated this query's TLS chain.
  /// On the fresh-KE path reflects the just-completed handshake's
  /// resolution; on the steady-state cached-session path reflects the
  /// *original* handshake's value (cached on the underlying session),
  /// so callers always see a concrete per-query attribution rather
  /// than a placeholder for cached queries. New in 3.0.0; mirrors the
  /// per-query observable pattern established by [phaseTimings].
  final TrustBackend trustBackend;

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
    required this.trustBackend,
  });

  @override
  int get hashCode => Object.hash(
    utcUnixMicros,
    roundTripMicros,
    serverStratum,
    aeadId,
    freshCookies,
    phaseTimings,
    trustBackend,
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
          phaseTimings == other.phaseTimings &&
          trustBackend == other.trustBackend);

  @override
  String toString() =>
      'NtsTimeSample(utcUnixMicros: $utcUnixMicros, '
      'roundTripMicros: $roundTripMicros, '
      'serverStratum: $serverStratum, aeadId: $aeadId, '
      'freshCookies: $freshCookies, phaseTimings: $phaseTimings, '
      'trustBackend: ${trustBackend.name})';
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

  /// Trust-anchor backend that authenticated this handshake's TLS
  /// chain. `ntsWarmCookies` always runs a fresh KE handshake (no
  /// cached-session short-circuit), so the value is always the
  /// just-completed handshake's resolution. New in 3.0.0.
  final TrustBackend trustBackend;

  /// Construct an outcome. Intended for the wrapper-layer conversion
  /// boundary and for test fixtures.
  const NtsWarmCookiesOutcome({
    required this.freshCookies,
    required this.phaseTimings,
    required this.trustBackend,
  });

  @override
  int get hashCode => Object.hash(freshCookies, phaseTimings, trustBackend);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is NtsWarmCookiesOutcome &&
          freshCookies == other.freshCookies &&
          phaseTimings == other.phaseTimings &&
          trustBackend == other.trustBackend);

  @override
  String toString() =>
      'NtsWarmCookiesOutcome(freshCookies: $freshCookies, '
      'phaseTimings: $phaseTimings, trustBackend: ${trustBackend.name})';
}

/// Trust-anchor backend that authenticated a TLS chain, or that a
/// process-global resolution attempt landed on.
///
/// Carried per-handshake on [NtsTimeSample] / [NtsWarmCookiesOutcome]
/// and process-globally on [NtsTrustStatus]. See `ARCHITECTURE.md`'s
/// "Trust-anchor diagnostics" section for the operational shape.
enum TrustBackend {
  /// `rustls-platform-verifier` ran against the OS trust store
  /// (system roots plus any user / MDM-installed roots). Source of
  /// truth for enterprise-managed devices and the only way to honour
  /// pinned corporate CAs.
  platform,

  /// Android-only: the platform verifier ran first, but its result
  /// was overridden by the `webpki-roots` fallback inside the
  /// hybrid verifier for one of the curated platform-failure shapes
  /// (missing-OCSP-AIA chains such as Let's Encrypt R12, R8-stripped
  /// AAR classes). Indicates the platform verifier's view was
  /// rejected and the static bundle was authoritative for this chain.
  platformWithHybridFallback,

  /// `build_with_native_verifier` failed at TLS-config construction
  /// time and the static `webpki-roots` bundle authenticated the
  /// chain end-to-end. Loses visibility into MDM / user-installed
  /// roots; works against the major public NTS providers but not
  /// against corporate TLS-inspection appliances. See
  /// [TrustMode.platformOnly] for the opt-in that surfaces this
  /// path as `NtsErrorTrustBackendUnavailable` instead.
  webpkiRoots,

  /// Caller-supplied custom root certificates authenticated this chain.
  custom,
}

/// Caller-selected policy for which trust-anchor backend an
/// [NtsClient] is willing to run against. Set immutably at client
/// construction and applied to every handshake the client initiates.
///
/// The default singleton client used by the top-level convenience
/// functions ([ntsQuery], [ntsWarmCookies]) is constructed with
/// [TrustMode.platformWithFallback] and never changes, so existing
/// callers see no behaviour change.
///
/// ## Security trade-offs
///
/// NTS derives its per-session AEAD integrity from TLS
/// keying-material exporters: the NTS-KE handshake exports session
/// keys that are used to authenticate every NTPv4 cookie and time
/// response. Those keys are only as strong as the TLS session that
/// produced them.
///
/// In environments that perform TLS inspection — corporate
/// middleboxes or MDM-managed devices that inject a CA into the
/// platform trust store — an inspection appliance holding a cert
/// signed by that injected root can complete a man-in-the-middle
/// TLS handshake and export the same keying material. The client
/// then accepts forged NTP responses as authenticated.
/// [TrustMode.platformOnly] always consults the platform store and
/// is therefore exposed to this threat whenever the handshake runs.
/// [TrustMode.platformWithFallback] is exposed only when the
/// platform backend is successfully constructed (the resolved
/// [TrustBackend] for that handshake is [TrustBackend.platform]); if
/// `build_with_native_verifier` fails at TLS-config construction
/// and the client falls back to the bundled `webpki-roots` set, the
/// platform store is not consulted on that handshake and the
/// inspection-CA exposure does not apply.
///
/// High-security callers who must preserve end-to-end integrity
/// against TLS inspection should use [TrustMode.bundledOnly], which
/// limits trust anchors to the library's static `webpki-roots`
/// bundle and refuses any certificate signed by a root outside
/// that set:
///
/// ```dart
/// Future<void> main() async {
///   await NtsRustLib.init(); // must complete before using NtsClient
///   final client = NtsClient(trustMode: TrustMode.bundledOnly);
///   final sample = await client.query(
///     spec: const NtsServerSpec(host: 'time.cloudflare.com', port: 4460),
///   );
/// }
/// ```
///
/// The trade-off is connectivity: `bundledOnly` does not honour
/// pinned corporate CAs or MDM-installed roots, so it will fail
/// against NTS servers that present certificates from a private or
/// enterprise CA. For those deployments use [TrustMode.custom]
/// with the relevant PEM or DER root bundle instead.
///
/// ## Reaching multiple trust domains
///
/// The policy is fixed per client and applies to every host that
/// client queries, so one [NtsClient] cannot apply different
/// per-host trust policies: a [TrustMode.custom] client scoped to a
/// private CA rejects public servers, and a [TrustMode.bundledOnly]
/// client rejects a private-CA certificate. (A platform-mode client
/// is less clear-cut — it accepts a private-CA server only when that
/// CA is installed in the OS trust store.) To enforce distinct trust
/// boundaries for distinct hosts from one app — for example an
/// internal server behind a private CA alongside public servers — do
/// not widen a single client's anchor set. Construct one [NtsClient]
/// per trust domain and route each query to the client whose
/// [TrustMode] matches, which keeps each CA trusted only for the
/// hosts it should authenticate. See the "Reaching multiple trust
/// domains" section of the README for a worked two-client example.
enum TrustMode {
  /// Consults the platform trust store first; if
  /// `build_with_native_verifier` fails at TLS-config construction,
  /// silently falls back to the bundled `webpki-roots` static set.
  /// Default behaviour preserved across all releases prior to 3.0.0.
  ///
  /// **Security note:** Platform-managed trust stores on corporate
  /// or MDM-managed devices routinely include inspection CA
  /// certificates. If one is present, a TLS-inspection appliance
  /// can complete a man-in-the-middle NTS-KE handshake and produce
  /// forged NTPv4 replies that this client will accept as
  /// authenticated. Use [TrustMode.bundledOnly] to eliminate this
  /// exposure when end-to-end integrity is a hard requirement.
  platformWithFallback,

  /// Refuses every silent fallback to the `webpki-roots` static
  /// bundle. Use when a pinned corporate CA or an MDM-installed
  /// root is the load-bearing trust anchor and a silent downgrade
  /// to a static bundle would defeat the deployment's
  /// TLS-inspection posture.
  ///
  /// Two distinct surfaces are gated:
  ///
  /// 1. **Build-time** (3.0.0): `build_with_native_verifier`
  ///    failure surfaces as [NtsErrorTrustBackendUnavailable]
  ///    rather than downgrading to the static bundle.
  /// 2. **Per-chain** on Android (4.0.0, BREAKING): the
  ///    platform-side `HybridVerifier` no longer retries against
  ///    `webpki-roots` for the two curated fallback-eligible
  ///    failure shapes (missing-OCSP-AIA chains such as Let's
  ///    Encrypt R12, and R8-stripped
  ///    `org.rustls.platformverifier.*` JNI failures). Both arms
  ///    now propagate the platform verifier's error verbatim. As a
  ///    result, a `platformOnly` Android caller will *never*
  ///    observe [TrustBackend.platformWithHybridFallback]; that
  ///    backend is reachable only via [TrustMode.platformWithFallback]
  ///    (the historic default), where both fallback arms continue
  ///    to fire as in 3.0.x.
  ///
  /// **Security note:** `platformOnly` still consults the platform
  /// trust store and is therefore exposed to TLS-inspection
  /// appliances in the same way as [TrustMode.platformWithFallback].
  /// The distinction is operational — it prevents a silent
  /// downgrade to bundled roots — not a defence against inspection.
  /// Use [TrustMode.bundledOnly] if the goal is to eliminate
  /// platform-store exposure entirely.
  platformOnly,

  /// Validates exclusively against the bundled `webpki-roots`
  /// static set. No platform-store consultation and no silent
  /// fallback.
  ///
  /// Because the anchor set is fixed at library build time and
  /// does not include any CA the platform or an MDM profile may
  /// have installed, a TLS-inspection appliance cannot present a
  /// certificate this client will accept. The AEAD keying material
  /// is therefore derived from a TLS session that only a server
  /// holding a `webpki-roots`-chained private key can participate
  /// in, preserving end-to-end integrity against middlebox
  /// inspection.
  ///
  /// The trade-off is that `bundledOnly` rejects certificates from
  /// private or enterprise CAs, including those used by on-premise
  /// NTS servers. For those deployments use [TrustMode.custom].
  bundledOnly,

  /// Validates exclusively against caller-supplied root
  /// certificates (PEM or DER), passed as `customRoots` on the
  /// [NtsClient] constructor. No platform-store or bundled-roots
  /// consultation.
  ///
  /// Appropriate for on-premise or private-CA deployments where
  /// neither the platform store nor `webpki-roots` contains the
  /// issuing root. Like [TrustMode.bundledOnly], the anchor set is
  /// fully caller-controlled, so a TLS-inspection appliance
  /// without the matching private key cannot intercept the
  /// exchange.
  custom,
}

/// Process-global trust-anchor diagnostic snapshot returned by
/// `ntsTrustStatus()`.
///
/// The fields combine one overwrite-on-store event marker (which
/// backend the default singleton client *most recently* resolved
/// to), four cumulative counters that partition the singleton's
/// resolution history by backend, a static flag indicating whether
/// the Android JNI bootstrap succeeded, and one Android-only
/// fallback counter. Fields not relevant to the current platform
/// are reported with the documented sentinel value (`null` /
/// `false` / `0`) rather than omitted, so the snapshot has the
/// same shape on every host.
class NtsTrustStatus {
  /// Backend the default singleton client most recently resolved to
  /// at handshake time. `null` when no handshake has run yet against
  /// the singleton (process just started, or all queries so far went
  /// through caller-minted [NtsClient] instances). This is an
  /// overwrite-on-store event marker, not a steady-state signal:
  /// prefer the three `defaultBackend*Count` fields below for
  /// dashboard panels that need trend visibility across the
  /// singleton's resolution history. Custom-client callers should
  /// read the per-handshake [NtsTimeSample.trustBackend] /
  /// [NtsWarmCookiesOutcome.trustBackend] for accurate per-client
  /// attribution.
  final TrustBackend? defaultClientBackend;

  /// Cumulative count of default-singleton handshakes that resolved
  /// to [TrustBackend.platform] since process start. Bumped in
  /// lock-step with each `platform` store on [defaultClientBackend].
  /// Never reset; weakly monotonic across consecutive snapshots,
  /// with the same per-counter monotonicity contract as
  /// [androidHybridFallbackCount].
  final BigInt defaultBackendPlatformCount;

  /// Cumulative count of default-singleton handshakes that resolved
  /// to [TrustBackend.platformWithHybridFallback] since process
  /// start. Always zero on non-Android platforms (the
  /// platform-verifier-with-`webpki-roots`-fallback path only
  /// exists on Android). Same monotonicity contract as
  /// [defaultBackendPlatformCount].
  final BigInt defaultBackendHybridCount;

  /// Cumulative count of default-singleton handshakes that resolved
  /// to [TrustBackend.webpkiRoots] since process start. Bumped every
  /// time platform-verifier configuration failed at build time on a
  /// [TrustMode.platformWithFallback] singleton. Same monotonicity
  /// contract as [defaultBackendPlatformCount].
  final BigInt defaultBackendWebpkiCount;

  /// Cumulative count of default-singleton handshakes that resolved
  /// to [TrustBackend.custom] since process start. Same monotonicity
  /// contract as [defaultBackendPlatformCount].
  final BigInt defaultBackendCustomCount;

  /// On Android: `true` iff the JNI bootstrap has reported success
  /// at least once. `false` on every other platform (no JNI
  /// bootstrap step exists). A `false` value on Android implies the
  /// process is currently running against the `webpki-roots` static
  /// bundle for any subsequent handshake, regardless of the caller's
  /// [TrustMode].
  final bool androidPlatformInitSucceeded;

  /// Cumulative count of TLS chains the Android hybrid verifier has
  /// accepted via the `webpki-roots` fallback path since process
  /// start. Always zero on non-Android platforms (no hybrid verifier
  /// exists). Non-zero on Android indicates at least one chain
  /// arrived whose only platform-side failure was a curated
  /// fallback-eligible shape.
  final BigInt androidHybridFallbackCount;

  /// Construct a snapshot. Intended for the wrapper-layer conversion
  /// boundary and for test fixtures.
  const NtsTrustStatus({
    required this.defaultClientBackend,
    required this.defaultBackendPlatformCount,
    required this.defaultBackendHybridCount,
    required this.defaultBackendWebpkiCount,
    required this.defaultBackendCustomCount,
    required this.androidPlatformInitSucceeded,
    required this.androidHybridFallbackCount,
  });

  @override
  int get hashCode => Object.hash(
    defaultClientBackend,
    defaultBackendPlatformCount,
    defaultBackendHybridCount,
    defaultBackendWebpkiCount,
    defaultBackendCustomCount,
    androidPlatformInitSucceeded,
    androidHybridFallbackCount,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is NtsTrustStatus &&
          defaultClientBackend == other.defaultClientBackend &&
          defaultBackendPlatformCount == other.defaultBackendPlatformCount &&
          defaultBackendHybridCount == other.defaultBackendHybridCount &&
          defaultBackendWebpkiCount == other.defaultBackendWebpkiCount &&
          defaultBackendCustomCount == other.defaultBackendCustomCount &&
          androidPlatformInitSucceeded == other.androidPlatformInitSucceeded &&
          androidHybridFallbackCount == other.androidHybridFallbackCount);

  @override
  String toString() =>
      'NtsTrustStatus(defaultClientBackend: '
      '${defaultClientBackend?.name ?? "null"}, '
      'defaultBackendPlatformCount: $defaultBackendPlatformCount, '
      'defaultBackendHybridCount: $defaultBackendHybridCount, '
      'defaultBackendWebpkiCount: $defaultBackendWebpkiCount, '
      'defaultBackendCustomCount: $defaultBackendCustomCount, '
      'androidPlatformInitSucceeded: $androidPlatformInitSucceeded, '
      'androidHybridFallbackCount: $androidHybridFallbackCount)';
}

/// Tuning preset consumed by `ntsGetTime` / `NtsClient.getTime`.
///
/// Bundles the four knobs the high-level convenience path exposes so
/// callers pick an environment-shaped preset instead of reasoning
/// about burst sizing and concurrency caps individually. The three
/// presets ([mobile], [desktop], [embedded]) cover the common cases;
/// construct an explicit [NtsProfile] when none fits.
///
/// Unlike the per-call `timeoutMs` on `ntsQuery` / `ntsWarmCookies`,
/// [timeoutMs] here is a **total** wall-clock budget spanning the
/// entire `getTime` call: the cookie-warming handshake and every
/// burst query draw down one shared deadline, so the call's overall
/// wall-clock cost is bounded by this single number regardless of
/// how many burst samples run.
class NtsProfile {
  /// Upper bound on the number of burst `ntsQuery` samples taken
  /// after the warming handshake. The effective burst size is
  /// `min(maxBurst, freshCookies)` where `freshCookies` is the cookie
  /// count the handshake delivered — each query spends one cookie, so
  /// the burst never exhausts the pool it just filled.
  final int maxBurst;

  /// Total wall-clock budget for the whole `getTime` call in
  /// milliseconds, shared across the warming handshake and every
  /// burst query as one shrinking deadline.
  final int timeoutMs;

  /// Per-call ceiling on in-flight DNS resolver workers, forwarded
  /// to each underlying call. Same semantics as the
  /// `dnsConcurrencyCap` parameter on `ntsQuery`.
  final int dnsConcurrencyCap;

  /// Per-call ceiling on concurrently dispatched bridge calls,
  /// forwarded to each underlying call. Same semantics as the
  /// `bridgeConcurrencyCap` parameter on `ntsQuery`.
  ///
  /// A single `getTime` call never contends with itself: its burst
  /// runs serially **by design** so each sample observes an
  /// uncluttered network path (concurrent same-server samples would
  /// share transient queue spikes and blunt the lowest-RTT
  /// selection). The cap instead governs the legitimate parallelism
  /// *across* calls — e.g. concurrent `getTime` calls against
  /// distinct servers for redundancy or server selection, or other
  /// wrapper calls from the same isolate — all of which contend for
  /// the shared bridge admission gate documented on `ntsQuery`.
  final int bridgeConcurrencyCap;

  /// Construct a custom profile. Prefer the named presets unless the
  /// deployment needs different numbers.
  const NtsProfile({
    required this.maxBurst,
    required this.timeoutMs,
    required this.dnsConcurrencyCap,
    required this.bridgeConcurrencyCap,
  });

  /// Preset for phones and tablets: modest burst, package-default
  /// concurrency caps (sized for 4-logical-CPU devices), 5 s total
  /// budget. The default profile when `getTime` is called without
  /// an explicit one.
  static const NtsProfile mobile = NtsProfile(
    maxBurst: 3,
    timeoutMs: 5000,
    dnsConcurrencyCap: 4,
    bridgeConcurrencyCap: 4,
  );

  /// Preset for desktop / server hosts: larger burst for tighter
  /// RTT selection and raised concurrency caps to match the wider
  /// worker pools those hosts run.
  static const NtsProfile desktop = NtsProfile(
    maxBurst: 5,
    timeoutMs: 5000,
    dnsConcurrencyCap: 8,
    bridgeConcurrencyCap: 8,
  );

  /// Preset for constrained embedded targets: minimal burst, halved
  /// concurrency caps, and a doubled total budget to tolerate the
  /// slow first-boot networks such devices often sit on.
  static const NtsProfile embedded = NtsProfile(
    maxBurst: 2,
    timeoutMs: 10000,
    dnsConcurrencyCap: 2,
    bridgeConcurrencyCap: 2,
  );

  @override
  int get hashCode =>
      Object.hash(maxBurst, timeoutMs, dnsConcurrencyCap, bridgeConcurrencyCap);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is NtsProfile &&
          maxBurst == other.maxBurst &&
          timeoutMs == other.timeoutMs &&
          dnsConcurrencyCap == other.dnsConcurrencyCap &&
          bridgeConcurrencyCap == other.bridgeConcurrencyCap);

  @override
  String toString() =>
      'NtsProfile(maxBurst: $maxBurst, timeoutMs: $timeoutMs, '
      'dnsConcurrencyCap: $dnsConcurrencyCap, '
      'bridgeConcurrencyCap: $bridgeConcurrencyCap)';
}

/// Synchronized clock produced by `ntsGetTime` / `NtsClient.getTime`.
///
/// Wraps the burst's lowest-RTT sample — already compensated for the
/// one-way network delay (`utc + roundTrip / 2`) — and anchors it to
/// a process-local monotonic [Stopwatch] started at construction.
/// [utcNow] projects the authenticated instant forward using that
/// monotonic elapsed time, so the projection is immune to system
/// clock steps, slew, and user adjustment after the sync.
///
/// The projection does **not** correct for local oscillator drift:
/// a typical crystal drifts on the order of tens of parts per
/// million, so the projected time accumulates roughly a millisecond
/// of error per minute-to-hour of wall-clock age depending on
/// hardware. Re-run `getTime` when tighter bounds are needed;
/// [elapsedSinceSync] exposes the age so callers can decide when.
///
/// Unlike the value-type DTOs in this library, [NtsSyncedTime] is a
/// live clock with identity semantics: two instances are never equal
/// even when constructed from identical samples, because each anchors
/// its own stopwatch.
class NtsSyncedTime {
  /// One-way-delay-compensated server UTC as microseconds since the
  /// Unix epoch, valid at the instant this object was constructed
  /// (the monotonic anchor). Use [utcNow] for the projected current
  /// time rather than reading this directly.
  final int utcUnixMicros;

  /// Round-trip time of the winning (lowest-RTT) burst sample, in
  /// microseconds. Bounds the sample's worst-case one-way-delay
  /// error: the true instant lies within `± roundTripMicros / 2` of
  /// the compensated value.
  final int roundTripMicros;

  /// Number of burst samples that completed successfully and entered
  /// the lowest-RTT selection. At least `1` (a `getTime` call with
  /// zero successful samples throws instead of returning).
  final int samplesUsed;

  /// Trust-anchor backend that authenticated the winning sample's
  /// TLS chain. Same per-handshake attribution semantics as
  /// [NtsTimeSample.trustBackend].
  final TrustBackend trustBackend;

  final Stopwatch _anchor;

  /// Construct a synchronized clock anchored at the current instant.
  ///
  /// [utcUnixMicros] must be the compensated UTC valid *now*: the
  /// internal monotonic stopwatch starts inside this constructor.
  /// Intended for the wrapper layer and for test fixtures; production
  /// code receives instances from `ntsGetTime`.
  NtsSyncedTime({
    required this.utcUnixMicros,
    required this.roundTripMicros,
    required this.samplesUsed,
    required this.trustBackend,
  }) : _anchor = Stopwatch()..start();

  /// Current authenticated UTC time, projected from the anchor via
  /// the monotonic stopwatch. Unaffected by system clock changes
  /// after the sync; subject to local oscillator drift as described
  /// on the class doc.
  DateTime get utcNow => DateTime.fromMicrosecondsSinceEpoch(
    utcUnixMicros + _anchor.elapsedMicroseconds,
    isUtc: true,
  );

  /// Monotonic wall-clock time elapsed since the anchor instant.
  /// Use to decide when the projection has aged enough to warrant a
  /// fresh `getTime` call.
  Duration get elapsedSinceSync => _anchor.elapsed;

  @override
  String toString() =>
      'NtsSyncedTime(utcUnixMicros: $utcUnixMicros, '
      'roundTripMicros: $roundTripMicros, '
      'samplesUsed: $samplesUsed, trustBackend: ${trustBackend.name}, '
      'elapsedSinceSync: $elapsedSinceSync)';
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

# Changelog

Entries for `1.4.0` and earlier live in
[CHANGELOG_ARCHIVE.md](https://github.com/nick-llewellyn/nts/blob/main/CHANGELOG_ARCHIVE.md),
which is kept in the repository but excluded from the published
tarball.


## 9.2

### Added

- `NtsBridge` (`lib/src/api/bridge.dart`, exported from
  `lib/nts.dart`) — a safe, idempotent lifecycle wrapper over the
  FRB-generated entrypoint, and the recommended bootstrap from now on:
  - `NtsBridge.ensureInitialized({externalLibrary, handler,
    forceSameCodegenVersion})` initialises the bridge if it is not
    already initialised and completes once it is. Safe to call
    repeatedly and from more than one code path, which
    `NtsRustLib.init()` is not — that throws a `StateError` on every
    call after the first, and there is no de-init. It is also safe
    *concurrently*: FRB's `initImpl` assigns its state only after
    awaiting the external library load, so the guard a consumer would
    otherwise write by hand (`if (!initialized) await init()`) races —
    two callers both observe `false`, both enter, and the second
    throws. `NtsBridge` latches on the in-flight future instead. An
    initialisation performed directly (including
    `NtsRustLib.initMock()`) is recognised rather than fought.
    Arguments configure the first initialisation only.
  - `NtsBridge.state` reports `NtsBridgeState.uninitialized`, `.mock`,
    or `.native`. This is the discrimination consumers previously had
    to reach into FRB's `@internal` `instance` / `api` members to
    obtain — `MonotonicClock` and the example CLI loader both did, each
    with an `invalid_use_of_internal_member` ignore, and both now
    switch on the enum instead.
  - `NtsBridge.dispose()` releases the bridge's Dart-side resources, or
    does nothing when it was never initialised. `NtsRustLib.dispose()`
    throws in that case. Disposal is not de-initialisation: `state` is
    unchanged afterwards.
- `CONTRIBUTING.md` — the GitHub-surfaced entry point for third-party
  contributors. Covers prerequisites, the one-time
  `git config core.hooksPath tool/hooks` opt-in, the branch and pull
  request loop, the quality gates, the code conventions, and the
  changelog and release-only versioning policy. It also states
  explicitly that the maintainer's issue-tracking services (Beads,
  Dolt, Linear) are not contributor prerequisites: `.beads/` is inert
  without `bd` installed, and no hook or CI job invokes any of the
  three. SonarCloud does run as a CI step, but it skips itself when
  `SONAR_TOKEN` is absent, as it always is on fork pull requests, and
  it is not a required check. `DEVELOPMENT.md` remains authoritative
  for the toolchain and CI detail.

### Changed

- The documentation no longer claims that bridge initialisation is a
  no-op after the first call. `NtsRustLib.init()` throws a `StateError`
  instead, so the claim was wrong everywhere it appeared, and the
  README went further and drew an operational conclusion from it
  ("safe to call from a shared bootstrap path") that described
  precisely the usage that throws. The library dartdoc in
  `lib/nts.dart`, the README's two-layer initialisation section, quick
  start, platform support, non-Flutter loader guidance and API summary,
  `example/main.dart`, `example/example.md`, and `ARCHITECTURE.md` now
  document `NtsBridge.ensureInitialized()` as the bootstrap and
  describe `NtsRustLib.init()` accurately as the single-shot raw
  entrypoint. (The `no-op` wording in
  `android/.../PlatformInit.kt` is correct and unchanged — that
  bootstrap really is idempotent.)
- The pull request template no longer asks every contributor to bump
  `pubspec.yaml` `version:` following semver. That instruction
  contradicted the release-only bumping policy, under which version
  fields move only in a dedicated release commit. The checklist item
  now asks for the field to be left untouched, with an explicit
  carve-out so a release PR can tick the same box truthfully.
- The pull request template illustrates the issue-reference
  convention with a placeholder (`NTS-<num>`) rather than a real,
  long-closed issue identifier, so the example cannot be pasted
  through into a pull request that has nothing to do with it.
- `AGENTS.md` and `CLAUDE.md` now say which of their sections are
  maintainer workflow. Both open with a short note on who the file is
  for, and every section covering the maintainer's issue tracking
  (Beads, DoltHub, Linear, the assignee convention) carries a
  `Maintainer-only` marker naming the tooling it presumes. The
  contributor-relevant material — pull request workflow, branch
  protection, shell conventions, the doc-snippet validator, versioning,
  and the zeroization policy — is deliberately unmarked.


## 9.1.0

### Added

- Copilot code review now follows a review protocol tracked in the
  repository. A `code-review` agent skill
  (`.github/skills/code-review/`) carries the protocol, the
  architecture-specific checks, and a mandatory summary-comment
  format; `.github/copilot-instructions.md` holds the repository-wide
  guidance, and `.github/instructions/` adds path-specific guidance for
  `**/*.dart` and `rust/**/*.rs`. MCP server availability is a
  repository-settings concern rather than a tracked file, and is
  documented in `DEVELOPMENT.md`.

  The checks are grounded in the surfaces where this repository's
  defects actually appear: generated-binding drift across the FRB
  boundary, hand-maintained lists mirroring the sealed `NtsError`
  hierarchy that the analyzer cannot see, the two distinct
  `TrustMode` fallback paths in `ke.rs` and `hybrid_verifier.rs`, the
  zeroization rules, and release-only version bumping. The protocol
  also instructs the reviewer to report every finding rather than
  suppressing low-confidence ones — on PR #292 four suppressed
  comments were all valid and two were substantive. Repository
  tooling only; no package or example change. (NTS-149)

- The example CLI (`example/bin/nts_cli.dart`) can now select a
  trust-anchor policy and assert the backend the call resolved.
  `--trust-mode` takes `platform-with-fallback`
  (default), `platform-only`, `bundled-only`, or `custom`;
  `--custom-roots <path>` supplies the PEM bundle or DER certificate
  the `custom` mode requires; `--require-trust-backend` asserts that
  every call resolved a named `TrustBackend`, reporting
  `TrustBackendMismatch` instead of success when it did not and
  counting that as a failure for `--exit-on-error`. The assertion
  reads the attribution off failures too, so a mismatch replaces
  either a success or an attributed failure: a call that resolved the
  wrong anchor set and only then lost the NTP leg reports the mismatch
  rather than the timeout it surfaced as.

  This is a backend-*resolution* assertion, not evidence that a chain
  was verified. Rust attaches the initial backend once
  `build_tls_config` returns, which is before any DNS, connect, or TLS
  I/O, so a DNS or connect failure on an attributed variant carries
  one too and an unreachable host can be reported as mismatching. That
  is the intended scope — the policy under test is which anchor set
  the call was configured to trust. The one value not fixed at
  config-build time is Android's `platformWithHybridFallback`, which
  replaces the initial `platform` only after the webpki-roots fallback
  verifier accepted a chain during TLS verification, so that
  attribution does evidence a verified chain. Four variants
  (`invalidSpec`, `trustBackendUnavailable`, `internal`,
  `abiMismatch`) have no attribution field, so they keep their own
  error type even when raised downstream of config-build.

  Previously every run went through the top-level `ntsQuery` /
  `ntsWarmCookies` and therefore the process-wide default client, whose
  mode is fixed at `TrustMode.platformWithFallback` — the most
  permissive policy the package offers — so the tool could neither
  probe under a stricter policy nor detect a silent `webpki-roots`
  fallback. A non-default mode now mints one call-scoped `NtsClient`
  for the batch and disposes it after the fan-out; the default path is
  unchanged and constructs no client. Under `--json`, `trust_mode` and
  `required_trust_backend` are emitted only when their flag was passed,
  so a flagless run's records are unchanged. Example app only; no
  package API change. (NTS-146)

- The two catalog tools (`example/bin/nts_health.dart`,
  `example/bin/nts_manifest.dart`) accept the same `--trust-mode`,
  `--custom-roots`, and `--require-trust-backend` flags, so a whole
  server list can be vetted under a stricter trust policy rather than
  only the hostnames passed to `nts_cli`. The flags live on the shared
  `addCommonProbeOptions` block, so both tools gain them together.

  A non-default policy mints one call-scoped `NtsClient` for the whole
  catalog and disposes it after the probe wave; the default path
  constructs no client and keeps routing through the top-level
  functions, so a flagless run is unchanged. `--require-trust-backend`
  is asserted on the NTS-KE warm *and* on every sample's own
  attribution, since a query re-handshakes once the warmed cookie pool
  is spent or its session was evicted, and on the attribution carried
  by a *failed* call, which is what a wrong-backend re-handshake that
  then fails looks like; the first mismatch abandons the
  rest of the host's run and is classified as a severe
  `TrustBackendMismatch` KE-stage failure, which makes the host
  `nonConforming` and therefore a drop candidate for
  `--fail-on-drops` and an exclusion from the generated manifest.

  All three CLIs validate the `--trust-mode` / `--custom-roots`
  pairing during argument parsing rather than leaving it to the
  `NtsClient` constructor. The constructor runs after `initBridge`, so
  on a machine with no loadable dylib an invalid pairing previously
  exited with the bridge-load code instead of the usage code both
  README exit-code tables document.

  The `--custom-roots` buffer is wiped in place once the client has
  copied it. The package zeroises only the copy it makes at the FFI
  boundary and documents the caller's list as read-but-never-retained,
  so wiping the caller-side bytes is the caller's job — and the buffer
  was otherwise reachable for the rest of the run. Because the roots are
  read early (so an unreadable path is an argument error rather than a
  trust-policy one), several terminations sit between that read and the
  wipe: the remaining flag validation, `nts_manifest`'s `--per-region`
  check, the catalog load, and every `initBridge` failure. `exit`
  terminates the VM without unwinding, so a `finally` cannot cover them;
  the buffer is instead registered on read and cleared at each of those
  sites, with the client construction keeping a `finally` for the
  success and non-`NtsError` paths. `loadAndProbeCatalog` re-registers
  on entry, since its argument object is publicly constructible and can
  therefore carry roots the parser never saw.
  Example app only; no package API change. (NTS-147)

- RFC 8452 known-answer vectors for AEAD ID 30 (the §8 worked example
  and a §C.1 case with a multi-block AAD), driven through
  `seal_packet` / `open_packet`, plus an open-path counterpart to the
  existing GCM-SIV nonce-length rejection test.

- The example package's hand-built list of `NtsError` samples
  (`example/test/nts_format_test.dart`) is now guarded by a
  `_NtsErrorKind` enum and an exhaustive `_variantKind` switch. Dart
  has no reflection over sealed subtypes, so the list is written out by
  hand and had no way to notice a new variant; every property asserted
  over "every `NtsError` shape" was therefore only as complete as that
  list. Adding a variant to the sealed type is now a `dart analyze`
  error in the switch, and omitting its sample from the list fails a
  test. The tag, severity, `timeoutPhaseName`, and `errorTrustBackend`
  assertions are driven off the same pivot rather than hand-enumerated
  — two of those lists had already drifted, missing `abiMismatch` and
  `trustBackendUnavailable`. Example tests only; no package or example
  behaviour change. (NTS-148)

### Security

- `aes-gcm-siv` is now pinned to 0.12 with its `zeroize` feature
  requested explicitly. 0.11 depended on `zeroize` unconditionally;
  0.12 made it an optional feature that is absent from `default`, so
  this crate's `default-features = false` build would otherwise have
  silently stopped wiping the derived POLYVAL and AES subkeys and the
  per-message counter block that `AesGcmSiv` allocates on the stack
  per operation. The resolved `zeroize` remains 1.9, above the ≥ 1.8
  floor the project's zeroization policy requires.

### Changed

- The example health prober (`example/lib/src/health/probe.dart`) now
  reports each sample's clock offset from `NtsTimeSample.offsetMicros`
  — the RFC 5905 §8 offset θ computed natively from the four NTP
  exchange timestamps — instead of deriving one as
  `utcUnixMicros + roundTripMicros / 2 − DateTime.now()`. That
  derivation carried two error terms θ does not, pulling in opposite
  directions: half the round trip includes the server's own processing
  time between recv and send, which overstates the offset, while the
  local reading was taken on the Dart event loop — after the FFI
  return and worker-thread handoff — and is subtracted, so scheduling
  lag understates it. Neither cancels the other, and their sum is a
  function of load rather than of the remote clock. Against a machine
  measured at +83 ms by `sntp`, the catalog tools were reporting
  +90–100 ms. θ has been on `NtsTimeSample` since 7.1; the prober
  predated it.

  θ is only meaningful if the local clock was not stepped between the
  T1 and T4, and unlike `ntsGetTime` — which reports θ as a
  statistic — this module feeds it into a verdict that decides whether
  a host stays in the catalog. Samples are therefore screened on the
  peer delay: a value that is not a positive duration cannot be a real
  delay, so θ is suppressed rather than trusted.
  `ProbeOk.offsetMicros` is now nullable to carry that, suppressed
  samples are excluded from the median instead of counting as a zero
  offset that would mask a real skew, and a host with no usable sample
  is not flagged on an offset it never observed — it reports a
  `clock offset unavailable (no corroborated sample)` note. The CSV
  report gains a trailing `note` column, and the text report renders
  the note in the non-standard section as well as the healthy one, so
  that explanation reaches every output format and every bucket a host
  with a suppressed offset can land in.

  The upper bound is tolerant rather than strict, since a forward step
  adds to the peer delay instead of subtracting and would otherwise
  slip past a lower bound alone. The bound `ntsGetTime` applies
  (`peerDelayMicros <= roundTripMicros`) does not hold on this client:
  T1 is captured before the request packet is built and the UDP socket
  bound, while `roundTripMicros` starts at the send, so the peer delay
  legitimately includes a pre-send interval the round trip excludes.
  Measured across the bundled catalog it exceeds the round trip by
  1–9% on every healthy server, so asserting that bound would suppress
  every real sample; the prober admits up to
  `roundTripMicros + phaseTimings.dnsMicros + 5 ms` instead. That
  allowance is additive rather than a multiple of the round trip
  because the pre-send interval includes the NTPv4-host DNS lookup,
  whose latency is unrelated to the round trip — a ratio-derived
  ceiling would reject a healthy sample from a nearby server behind a
  slow resolver. It is measured from the sample rather than derived
  from the verdict threshold: on a sample that ran no handshake
  `dnsMicros` is that lookup alone, and the remaining 5 ms covers the
  packet build and the bind, which do no I/O. A threshold-derived
  allowance would have bounded the undetected step at the threshold and
  so the undetected corruption of θ at half of it, which is enough to
  move a host whose true offset is non-zero across the verdict line.
  The lookup term is claimed only where it is attributable: the burst
  runs against a pre-warmed pool, but an exhausted pool or an evicted
  session makes a sample re-handshake, and `dnsMicros` then also
  carries a KE-host lookup that completed before T1. Such a sample is
  allowed the flat 5 ms only.

  A second screen corroborates θ across the burst: a surviving sample's
  θ is kept only if some other surviving sample agrees with it to
  within half the sum of the two samples' round trips. Asymmetry is the
  honest source of disagreement and displaces a sample's θ by at most
  half its own round trip, so that sum bounds what an honest pair can
  differ by, while a step of S displaces one sample's θ by S/2 and so
  escapes the window once S exceeds the sum. The window is per pair
  rather than one figure for the burst: a retransmit or a queued reply
  makes one sample far slower than its neighbours, and a burst-wide
  minimum would suppress such a pair over jitter neither is at fault
  for — which is not the safe direction to err, since a host left with
  no surviving θ is judged without the clock check at all. The scale is
  drawn from `roundTripMicros` rather than the peer delay because the
  round trip is measured on a monotonic clock, so no step can widen the
  window in either direction, and because it excludes the pre-send
  interval, which is not a property of the path. This is what rejects a
  step small enough to pass the per-sample bound but large enough to
  move the median across the threshold. Neither screen proves the clock
  was steady: a step that disturbs neither the peer delay beyond the
  setup cost nor the burst's agreement is not detected.
  Example app only; no package change. (NTS-152)

- **Docs:** `NtsTimeSample.offsetMicros` described θ's vulnerable
  window as spanning the UDP send and recv. It actually opens at T1,
  which precedes the packet build and the socket bind, so a step
  during that setup corrupts θ too — and the same early T1 biases θ
  upward by half the setup interval even on a steady clock
  (sub-millisecond to a few milliseconds, from the 1–9% measurement
  above). The rustdoc, generated bindings, and wrapper dartdoc now
  say so and point at NTS-153. Documentation only; no behaviour
  change.

- **Docs:** `NtsTimeSample.peerDelayMicros` documented δ as always
  `<= roundTripMicros` on a steadily-running clock, and a value
  outside `(0, roundTripMicros]` as a clock-step signal. The upper
  half of that is false on this client for the capture-point reason
  above — δ measured above the round trip on every healthy sample
  across the bundled catalog — so the `(0, roundTripMicros]` window
  `ntsGetTime` applies is a selection policy rather than a verdict on
  the sample: it takes the `roundTripMicros` branch in practice rather
  than distinguishing stepped samples, and only its lower bound is
  diagnostic. That the round trip wins is an empirical result, not an
  identity: δ = setup + roundTrip − serverProcessing, so δ clears the
  ceiling only while the pre-send setup cost outweighs the server's
  T3−T2, which held across every catalog server measured.
  A non-positive δ is also no longer attributed to a *local* step
  specifically: it witnesses an implausible timestamp exchange, which
  a server clock stepped between T2 and T3, or inconsistent server
  stamps, produce just as well. The tolerant upper bound the field
  recommends to consumers now points at `phaseTimings.dnsMicros` as
  the measurable part of the pre-send interval. The field's rustdoc,
  the generated bindings, and the wrapper dartdoc now say so, and
  point at NTS-153 for aligning the capture points. `README.md`,
  `ARCHITECTURE.md`, and `example/GUI_GUIDE.md` carried the same
  superseded claim — each described `ntsGetTime` as selecting the peer
  delay — and now all three lead with the round-trip branch taken in
  practice, scoped to the catalog measurement, citing the window as
  the condition rather than as a plausibility judgement. The remaining
  API-doc sites that still called an in-window δ "plausible"
  (`nts_query` and `NtsTimeSample::utc_unix_micros` in the rustdoc and
  their generated and wrapper counterparts, plus `NtsSyncedTime`) now
  use the same selection-window framing, so the public API surface no
  longer contradicts the prose. Documentation only; no behaviour
  change.

- The AES-128-GCM-SIV path (AEAD ID 30) migrated to the `aes-gcm-siv`
  0.12 API. The crate moved to the RustCrypto `hybrid-array` traits
  line, so `KeyInit` now comes from `aes_gcm_siv` rather than
  `aes_siv`, and the deprecated `Array::from_slice` constructors are
  replaced by the infallible `&[u8; 16]` conversion for the key and a
  `TryFrom` conversion for the nonce. The nonce conversion subsumes
  the hand-written length check in `seal_packet` / `open_packet`,
  which now maps its failure to the same `InvalidNonceLength` error —
  no behavioural change on either path. `aes-siv` (AEAD IDs 15 and
  17) is still on the older `generic-array` line because its 0.8
  release is release-candidate only, so `cargo deny`'s
  `multiple-versions` gate carries version-pinned skips for the eight
  duplicated RustCrypto crates. Six of them expire when `aes-siv` 0.8
  ships; `block-buffer` and `crypto-common` are additionally held by
  `flutter_rust_bridge_macros -> md-5 -> digest 0.10` and will remain
  needed until that chain also moves.

## 9.0.0

### Breaking

- The cumulative counters on `NtsDnsPoolStats` and `NtsTrustStatus`
  changed from `BigInt` to `int`: `recovered`, `refused`,
  `spawnFailed`, `defaultBackendPlatformCount`,
  `defaultBackendHybridCount`, `defaultBackendWebpkiCount`,
  `defaultBackendCustomCount`, and `androidHybridFallbackCount`.

  These were the last `BigInt` fields on the public surface. They
  were `BigInt` only because the Rust structs behind the bridge
  declared them `u64`, which FRB binds to `BigInt`; the stated
  rationale on the fields — that a 32-bit wraparound would be visible
  on long-running builds — justifies the 64-bit *backing* store, not
  the `BigInt` *binding*. The backing counters remain `AtomicU64`;
  only the bridge-facing struct fields are redeclared as `i64`, which
  FRB binds as `PlatformInt64` and the conversion layer narrows to a
  plain `int`. This matches what `PhaseTimings` and
  `ntsBoottimeMicros` already did, and removes the split inside
  `NtsDnsPoolStats`, whose `inFlight` / `highWaterMark` were already
  plain `int`.

  `u64` → `i64` is range-narrowing, so the overflow policy is
  explicit: the projection saturates at `i64::MAX` rather than
  wrapping, keeping the published sequence non-decreasing. The clamp
  is unreachable in practice — a counter bumped once per DNS lookup
  or per handshake would need 2^63 events to reach it. Web remains
  unsupported (NTS-KE needs a raw TCP socket), so the 53-bit
  JavaScript integer limit is not a consideration.

  Migration: drop `BigInt.from(...)` at construction sites and
  compare against plain integer literals. `stats.refused >
  BigInt.zero` becomes `stats.refused > 0`. Both DTOs are now
  `const`-constructible with literal counters. The wire layout is
  unchanged — the counters still cross the boundary as 8 bytes each —
  so no native rebuild is required beyond the regenerated bindings.

### Security

- NTS cookies are now capped at 512 octets and client NTP requests at
  1200 octets. RFC 8915 deliberately leaves the cookie opaque and
  unbounded (§4.1.6, §5.4) because only the issuing server needs to
  interpret it; deployed servers issue roughly 100 octets. The client
  previously accepted whatever a KE server sent, bounded only by the
  overall KE message budget. That mattered beyond the one allocation
  because `build_client_request` sizes each cookie placeholder to the
  cookie it is standing in for, so a single oversized cookie inflated
  *every subsequent* NTP request by roughly twice its length — a
  KE-side input silently driving UDP datagram growth on the query path,
  past the point of IP fragmentation and into MTU black-holing.

  Oversized cookies are rejected at two points, with deliberately
  different policies. During KE record decoding the whole message
  fails with the new `CodecError::CookieTooLarge`, checked before the
  body is copied, so the handshake stays atomic — a partial harvest
  would silently degrade the pool. In an AEAD-authenticated NTP
  response the oversized entries are *filtered* instead: the time
  sample is sound, and discarding it would trade a real
  synchronisation for cookies the client is free to ignore.
  Conforming cookies in the same packet are still deposited, the drop
  count is reported on `ServerResponse::oversized_cookies_dropped`,
  and a `nts::ntp` warning is logged so the slower-than-expected pool
  refill is observable rather than silent.

  `build_client_request` also projects the full on-wire packet size —
  header, unique identifier, cookie, placeholders, and authenticator,
  each padded to the 4-octet extension alignment — and refuses with
  the new `NtpError::PacketTooLarge` before allocating. The cookie cap
  alone does not bound the packet, because `placeholder_count` is
  caller-supplied and each placeholder is sized to the cookie. The
  1200-octet limit is the RFC 8200 §5 minimum MTU less headers, with
  margin for tunnel encapsulation. The projection doubles as the
  allocation hint, replacing a fixed guess. (NTS-125)

- The per-client session table is now bounded, so cached AEAD keys and
  cookie jars are no longer retained for the life of the process.
  `SessionTable` previously held every `host:port` it had ever
  handshaken with until an explicit `invalidate` / `clear` or a rekey
  signal for that exact key — a caller that rotated through many
  servers, or that derived host strings from untrusted input,
  accumulated key material without limit and had only manual `clear()`
  as a remedy.

  Two bounds now apply. A hard ceiling of 64 entries evicts the
  least-recently-used session to make room for a new host, ranked by a
  per-session stamp that each successful cookie draw refreshes so an
  actively-used session is never the victim; re-handshaking a host
  already cached replaces it in place and evicts nothing.
  Independently, any session idle for 24 hours is dropped. That stamp
  is a `BootInstant` rather than an `Instant`, so idle time keeps
  accruing across device suspend — under `Instant` a table populated
  before a long sleep would hold its keys for the sleep duration on
  top of the TTL, which is exactly the backgrounded-app case the TTL
  exists to cover.

  Both bounds are swept whenever a session is installed, and the TTL
  is additionally checked when a cached session is drawn from. The
  second check is what makes the TTL bind for a process that goes
  quiet and then queries the same host again: that path installs
  nothing, so without it the stale session would be served and its
  stamp refreshed, and the entry would never age out.

  Eviction drops the `Session`, releasing its `ZeroizeOnDrop` AEAD
  keys and its cookie jar, so the bound is on secret retention and not
  merely on memory. `invalidate(spec)` and `clear()` are unchanged and
  remain the eager controls for callers that need a session gone at a
  specific moment. No public API changes; the bounds are internal
  policy. (NTS-124)

### Added

- `NtsClient.dispose()` releases the client's native handle — and with
  it the session table, its cached AEAD keys, and its cookie jars — at
  a moment the caller chooses, instead of leaving it to the GC
  finalizer. The method existed internally (only `ntsGetTime`'s
  call-scoped client used it) and is now public.

  Optional, not required: the finalizer remains the backstop, so a
  client that is simply dropped is still reclaimed. What was missing
  was any way to make the timing deterministic — a client scoped to a
  work batch, a screen, or a test could pin native state well past the
  point the app considered it dead, and an app minting many
  short-lived clients had no lever at all short of GC pressure.

  Distinct from `clear()`, which empties the session table and leaves
  the client usable; `dispose()` ends the client. Idempotent, and safe
  to call with a `query` / `warmCookies` / `getTime` already executing
  on the native side: such a call took its own reference to the native
  object when its arguments were encoded, and runs to completion. A
  call still queued at the bridge admission gate has not encoded its
  arguments yet, so it is refused once admitted, as is any method
  called *after* `dispose()`; the refusal is an FRB `FrbException`
  rather than an `NtsError`, since the failure is in the handle rather
  than in the protocol. (NTS-114)

- `TimeoutPhase.dnsSpawnFailed` distinguishes "the OS refused to create
  a DNS worker thread" from the pool-cap refusal already reported as
  `TimeoutPhase.dnsSaturation`. Additive enum growth: `switch`
  statements over `TimeoutPhase` that were previously exhaustive will
  now need a case for it (or a `default`).

- `NtsDnsPoolStats.spawnFailed` counts those refusals, disjoint from
  both `refused` (admission blocked by the cap) and `recovered` (a
  detached worker that actually ran). The pair `refused` vs
  `spawnFailed` is what makes the cap-vs-ceiling distinction observable
  without parsing error strings, since both refusals surface as
  `WouldBlock` internally. Callers constructing `NtsDnsPoolStats`
  directly — test fixtures, chiefly — must pass the new required
  field.

- `NtsTimeSample.keWarnings` and `NtsWarmCookiesOutcome.keWarnings`
  expose the non-fatal NTS-KE warning codes a server sent with the
  handshake (RFC 8915 §4.1.4 record type 3) as `List<int>` raw code
  values, in the order received. Previously the KE layer parsed these
  records but discarded them, so a server signalling a warning was
  indistinguishable from one that sent none. Empty for every server
  observed in practice — the IANA NTS-KE warning registry has no
  assignments as of RFC 8915 — so a non-empty list means the peer sent
  a code this client version cannot interpret. Codes are surfaced, not
  acted on: nothing here fails a query, since by definition a warning
  did not stop the handshake. A non-empty list is also logged once per
  handshake at `warn` on target `nts::ke`.

  A warning describes the *handshake*, so on `NtsTimeSample` the value
  follows the session across cached-session queries rather than
  resetting to empty like `phaseTimings` — matching how `trustBackend`
  already behaves. A caller polling in steady state therefore cannot
  miss codes by having started after the cookie pool went warm. On
  `NtsWarmCookiesOutcome` there is no cached-path nuance, since that
  call always runs a fresh handshake; a singleflight waiter that
  collapsed onto a concurrent leader reports the leader's codes, as
  `freshCookies` and `trustBackend` already do.

  Additive and source-compatible: both fields default to `const []`,
  so existing constructor calls and `NtsTimeSample` fixtures compile
  unchanged. Callers that destructure exhaustively or compare DTOs
  against hand-built expected values will observe the new field in
  `==`, `hashCode`, and `toString`. (NTS-127)

- New advisory CI workflow `.github/workflows/cross-platform.yml` runs
  the Rust live probes and the `test/live/` Dart suite on both
  `ubuntu-latest` and `windows-latest`, weekly (Mondays 07:00 UTC) and
  on manual dispatch. It adds the first CI coverage of the
  Windows-conditional `windows-sys` arm behind `nts::boottime`, and the
  first CI run of the Dart live suite on any platform. The workflow is
  not a required status check: its steps depend on public NTS server
  reachability, so a red run is a signal to triage rather than a merge
  blocker. Repository infrastructure only — no packaged code changed.
  (NTS-12)

- The `dependency-review` job now carries an `allow-dependencies-licenses`
  carve-out for build-time GitHub Actions, separating them from the
  NTS-72 SPDX `allow-licenses` list. That list is a distribution policy
  governing what may be linked into the published package or the
  `nts_rust` cdylib, which is why it is kept in lockstep with
  `[licenses].allow` in `rust/deny.toml`; actions are a different
  population, executed on an ephemeral runner and never conveyed to a
  user. Exemptions are named per-action rather than per-licence so a
  future copyleft action must be added deliberately. One entry today:
  `Swatinem/rust-cache` (LGPL-3.0), already used by `ci.yml` and
  `fuzz.yml` and surfaced only because the new workflow above
  introduced it "newly" from the diff's perspective. Repository
  infrastructure only — no packaged code changed, and the distribution
  policy is unchanged. (NTS-12)

### Fixed

- NTS-KE handshakes against servers that clear the Critical bit on the
  AEAD Algorithm record now succeed instead of failing with
  `NtsError.keProtocol`. RFC 8915 §4.1.5 states that the Critical bit
  on this record *MAY* be set — it is the deliberate exception to the
  *MUST* imposed on EndOfMessage (§4.1.1), Next Protocol (§4.1.2),
  Error (§4.1.3), and Warning (§4.1.4). The parser enforced the bit by
  false symmetry with the Next Protocol check, making every conforming
  server that clears it permanently unreachable; members of the public
  `ntp.br` pool do exactly this, and because `gps.ntp.br` resolves to
  two addresses that disagree, the failure presented as intermittent.

  A cleared bit is now recorded at `debug` level under the `nts::ke`
  log target and the handshake continues, matching the treatment
  already given to unknown non-critical records (§4.1.4). No downgrade
  surface is introduced: the record is carried inside the TLS channel,
  so an on-path attacker can alter neither the bit nor the algorithm
  identifier, and the returned identifier is still validated against
  the client's offered list. The Critical-bit requirement on the Next
  Protocol record is unchanged — §4.1.2 genuinely says *MUST*.
  (NTS-138)

- The Dart-side copy of `customRoots` is now wiped after the FFI
  handoff instead of being left readable until the GC runs. The
  `NtsClient` constructor copies the caller's `List<int>` into the
  `Uint8List` the FFI encoder requires; the Rust side holds its
  equivalent in a `Zeroizing<Vec<u8>>` (`CustomRootsBytes`), so the
  intermediate Dart copy was the weaker end of that story for
  deployments where the anchor set itself is confidential. The copy is
  overwritten with zeros in a `finally`, so it is cleared on the
  throwing path too — the case where the bytes would otherwise be both
  unreachable and unwipeable.

  Bounded, not total, and the constructor dartdoc now says so. Two
  copies stay outside the package's reach: the caller's own list, which
  is theirs to manage and is never mutated, and the FRB serializer
  buffer the encoder writes into, which is upstream-owned — the same
  class of residue the Rust-side `CustomRootsBytes` docs already record
  for the PEM parse path.

- The ABI-mismatch conversion no longer rewrites a bare
  `ArgumentError` as `NtsError.abiMismatch`. The wrapper widens its
  catch around the FFI call to convert codec decode failures — bytes
  the generated codec cannot read against the layout it was built for
  — into an error naming the rebuild. The predicate matched
  `ArgumentError` alongside `RangeError` and `UnimplementedError`,
  which is the widest of the three: it swept in throws that have
  nothing to do with the wire layout, answering an unrelated
  diagnostic with "rebuild the native library from the Rust sources"
  and sending the reader somewhere the fault is not.

  Driving the real generated `sse_decode_*` functions over malformed
  buffers shows every drift shape they produce is a `RangeError` (a
  short buffer, or a fieldless-enum index past the end of `values`) or
  an `UnimplementedError` (an unrecognised variant tag). No shape
  yields a bare `ArgumentError`, so matching it bought no coverage.
  The predicate is now those two shapes; `RangeError` remains matched
  in its own right rather than via its `ArgumentError` supertype.
  Anything else thrown from inside the call — a bare `ArgumentError`,
  a `FormatException`, the `StateError` FRB raises for a missed
  `NtsRustLib.init()` — reaches the caller unchanged. The
  codec-driven tests now assert membership in exactly those two
  shapes, so a decoder that started throwing something else fails the
  suite rather than quietly relying on a broader catch.

- A system clock reading before the Unix epoch no longer produces an
  all-zero NTP transmit timestamp. On a device whose RTC has reset to
  1970-or-earlier, `SystemTime::now().duration_since(UNIX_EPOCH)` fails
  and the conversion returned `0`, so every query on that device sent
  an identical T1. The server echoes T1 back as `origin_timestamp`, and
  the client checks the echo — a constant makes that check pass for any
  captured response, not just the one it was sent for, weakening it as
  an anti-spoof signal precisely on the devices whose clocks are least
  trustworthy.

  The pre-epoch branch now derives a non-zero, microsecond-resolution
  value from the sleep-aware boot clock, so successive queries differ.
  The boot clock is packed into the NTP64 wire format rather than being
  offset onto any epoch, so a reader interpreting it as a timestamp
  lands in the 1900s. That is deliberate: it is a uniqueness and echo
  token rather than a time, and an implausible year keeps it from being
  read as a genuine clock value in a packet capture. The offset computed
  from such an exchange remains meaningless, exactly as it was when the
  value was zero: T1 and T4 sit in the 1900s while T2 and T3 carry real
  server time. Peer-delay, by contrast, becomes sound — T1 and T4 come
  from the same fallback source, so T4−T1 is a true elapsed duration
  where previously it was zero. The emitted sample time still comes from
  the server's T3, and round-trip time is still measured locally.

- DNS worker-thread spawn failure is no longer misreported as a network
  error. When the bounded resolver pool granted a slot but the OS then
  refused to create the `nts-dns` worker thread, the `io::Error` from
  `thread::Builder::spawn` escaped through the same path as a genuine
  lookup failure. Because the two mapping sites keyed only off
  `ErrorKind`, an `ENOMEM` refusal (`ErrorKind::OutOfMemory`) surfaced
  as `NtsError.network` with the message `DNS lookup failed for
  host:port: …`, pointing operators at the network or the server when
  the actual cause was a process-local thread or memory ceiling. An
  `EAGAIN` refusal (`ErrorKind::WouldBlock`) was silently conflated with
  cap saturation instead.

  Spawn refusal now reports as the new `TimeoutPhase.dnsSpawnFailed`
  (see Added). It is kept distinct from `dnsSaturation` because the
  remediations are opposed: saturation means the cap is the binding
  constraint and raising `dnsConcurrencyCap` helps, whereas a spawn
  refusal means admission already succeeded, so raising the cap would
  admit more work the process cannot service.

- The DNS pool's `recovered` counter no longer credits workers that
  never started. `thread::Builder::spawn` takes ownership of the closure
  and drops it when the spawn fails, so the `SlotGuard` moved into the
  closure ran its `Drop` on that path — incrementing the counter that
  `ARCHITECTURE.md` designates as the "libc is wedged" signal for a
  thread that never ran, and blunting exactly the signal operators are
  told to alert on. The slot now travels to the worker as a
  `Drop`-free `PendingSlot` and is re-armed there, leaving the
  spawn-failure branch to release the slot explicitly.

- A call queued behind the bridge admission gate now surfaces its
  timeout after a device suspend instead of parking past it. Queue wait
  was already charged on the sleep-aware monotonic clock, so the budget
  crossing the FFI boundary stayed honest, but cancellation of a
  still-queued waiter was a `Timer` armed for the full timeout. `Timer`
  runs on the event loop's suspend-frozen clock, so a device that slept
  through the budget resumed with the timer still owing its whole
  remaining slice — the waiter kept parking for an outcome already
  decided, and only unparked once a slot happened to free or the frozen
  timer eventually caught up.

  Deadlines are now absolute readings on the same sleep-aware clock,
  swept by one queue-wide timer rather than one full-length timer per
  waiter. Each arming is capped at 250 ms, so a resume re-evaluates
  every deadline against the boot clock within one slice; the cap never
  delays a nearer deadline, which is every deadline while awake, and
  the sweeper is only armed while the queue is non-empty. Expiry now
  happens in the same single-pass compaction that performs admission,
  so the existing O(n) cost under a mass-timeout burst is unchanged and
  a freed slot goes to a waiter that can still use it rather than to
  one the dispatch-side residual check would reject again. No public
  API changes. (NTS-111)

- KE responses that redirect the NTP phase are now validated before
  any post-handshake I/O. `validate_response` in `nts::ke` took the
  NTPv4 Server and Port records raw: an empty Server body reached the
  resolver as an empty host, and `Port(0)` reached the UDP socket as an
  unroutable destination. Both surfaced as an opaque `Network` failure
  or timeout well after the handshake had succeeded, even though the
  same host/port shape is rejected up front when it arrives from the
  caller via `NtsServerSpec`. A KE peer that completes TLS — a buggy
  server, or one whose certificate an attacker holds — could therefore
  steer the client into failing I/O rather than being refused as a
  protocol violation. Both now fail the handshake with new `KeError`
  variants `EmptyServer` / `ZeroPort`, surfacing to callers as
  `NtsError::KeProtocol` with a stable RFC-citing message. Only the
  *redirected* values are checked: an absent Server record still falls
  back to the already-validated request host, and an absent Port record
  to `DEFAULT_NTPV4_PORT` (123). (NTS-123)

- Duplicate NTPv4 Server and Port records in a KE response are now
  rejected. `validate_response` already refused duplicate NextProtocol
  and AEAD Algorithm records, but Server and Port still resolved via a
  first-match `find_map` — so an ambiguous response silently pinned one
  endpoint with no signal that the response was malformed, the same
  pre-hardening pattern deliberately removed for the other two records.
  New `KeError::DuplicateServer` / `DuplicatePort` variants are raised
  from the existing duplicate-detection loop, ahead of the walks that
  would otherwise mask the violation. (NTS-128)

- Per-call timeout budgets now keep elapsing while the device is
  asleep. The KE handshake deadline (`nts::ke::Deadline`), the UDP
  setup deadline (`api::nts::UdpDeadline`), the singleflight
  leader/waiter budgets in `checkout_with` and `warm_cookies_with`, the
  `HandshakeSlot` condvar waiter, and the call-wide anchor in
  `nts_query` were all anchored on `std::time::Instant`, which is
  suspend-frozen on every platform this package targets
  (`CLOCK_MONOTONIC` / `mach_absolute_time` / QPC). A mobile call with
  `timeoutMs: 5000` that suspended mid-handshake resumed after wake
  with most of its original budget still nominally unspent, while wall
  clock had already blown past the caller's limit — and the Dart layer,
  which charges residual against a sleep-aware clock, disagreed with
  the native side about how much budget was left. All six now anchor on
  the new `nts::boottime::BootInstant`, an `Instant`-shaped wrapper
  around the existing suspend-inclusive `boottime_micros` reading
  (`CLOCK_BOOTTIME` / `mach_continuous_time` /
  `QueryInterruptTimePrecise`). The condvar waiter additionally
  re-reads the boot clock on every wake, because `wait_timeout` is
  itself suspend-frozen and would otherwise under-count a suspend that
  spanned a park. Short in-call measurements — the per-phase durations
  reported in `NtsDiagnostics` and the RTT bracket around a single
  `send`/`recv` — deliberately stay on `Instant`. (NTS-122)

- `SeenUidCache` entries now age across device suspend. The replay
  guard's 5-minute TTL stamped `Instant` readings, so a cache populated
  before a long sleep retained its Unique Identifiers for the sleep
  duration plus the TTL rather than the TTL alone. The behaviour was
  conservative for replay detection (the window stayed open longer than
  documented) and bounded by the existing `SEEN_UID_CAP` ceiling, but
  it pinned memory across suspend and put the cache on a different
  clock from the budgets above. Timestamps are now `BootInstant`.
  (NTS-129, landed with NTS-122 so the clock abstraction was reviewed
  against both a deadline consumer and a TTL consumer at once)

- The Dart wrapper now rejects a `verificationTime` above the year-9999
  ceiling before dispatch. `_validateRanges` checked only for negatives,
  so a far-future instant crossed the FFI boundary and came back with a
  Rust-authored `invalidSpec` message from
  `validate_verification_time_ms`. The Dart side now mirrors
  `MAX_VERIFICATION_TIME_MS` (`253402300799000`, 9999-12-31T23:59:59Z)
  and authors its own message, restoring the front-loaded single error
  surface the port, timeout, and concurrency caps already use. The
  ceiling is inclusive on both sides. (NTS-107)

- A blank `NtsServerSpec.host` is now rejected on the Dart boundary.
  Only `port` was range-checked; an empty host was left to Rust's
  `validate`, costing an FFI hop for a Rust-authored message, and
  `NtsClient.invalidate` soft-failed such a spec as `false` rather than
  failing closed. `_validateSpec` now rejects `host.trim().isEmpty` with
  a wrapper-authored `NtsError.invalidSpec` across the four async
  wrappers, `getTime`, and `invalidate`. Whitespace-only hosts are
  rejected rather than normalised, since the session key is `host:port`
  verbatim. (NTS-108)

- `getTime` no longer inflates an already-spent budget to dispatch the
  handshake. The warm phase clamped its share of the shared 8-second
  budget up to 1ms when the balance had fallen below the `timeout >= 1ms`
  floor the lower-level wrappers enforce, so a call whose budget was
  gone still ran a full KE handshake — extending the documented total
  budget, and, when that handshake succeeded, replacing the cached
  session for `spec` (the process-wide one on the default-client path)
  on a call that should never have reached protocol work. The balance
  is now checked before dispatch and a spent one fails immediately with
  the same synthetic `NtsError.timeout(phase: TimeoutPhase.ntp)` the
  post-handshake exhaustion path already used, dispatching nothing. The
  1ms floor is now a single `_kMinDispatchBudget` constant shared with
  the burst loop, which already broke on the same threshold. Only
  reachable when a device suspend lands between the budget starting and
  the handshake dispatching — the budget is metered on a sleep-aware
  clock, which is what makes that window observable at all. (NTS-110)

- The `ntsGetTime` dartdoc now describes the budget it actually
  enforces. It documented the 8-second total as plain wall-clock and
  listed only post-handshake exhaustion under its failure modes,
  omitting that the budget is sleep-aware (so a suspended call resumes
  with the suspended interval already charged), that a spent balance is
  refused rather than rounded up, and that an exhausted call therefore
  leaves the cached session untouched. `NtsClient.getTime`, which
  delegates to the same helper and defers to that dartdoc for its
  contract, gains a matching one-line pointer. Documentation only.
  (NTS-119)

- The example app's iOS deployment target is raised from `13.0` to
  `14.0` across all three build configurations, meeting the floor
  declared by `file_picker`. Example app only; no package API change.

### Changed

- The example app's `NtsController` now calls `NtsClient.dispose()` on
  the client it supersedes when a trust-mode flip or a custom-roots
  change re-mints one, and gains its own `dispose()` that cancels the
  two signal subscriptions and releases the final client. `main.dart`
  owns the controller from a `StatefulWidget` so that teardown has a
  place to run. The controller previously dropped every superseded
  client for the GC finalizer to reclaim — the exact pattern
  `dispose()` was added in 9.0 to replace — leaving the native session
  table, cached AEAD keys and cookie jars pinned well past the point
  the app considered the client dead. The three action methods gain an
  `on FrbException` arm ahead of their catch-all: a call already
  executing natively is unaffected by a `dispose()`, but one still
  queued at the bridge admission gate is refused, as are the later legs
  of `getTime`'s warm-then-burst sequence. Those are logged as warnings
  against the superseded client; a bridge failure against the *active*
  client stays an error. Example app only; no package API change.
  (NTS-143)

- The example CLI (`example/bin/nts_cli.dart`) now reports the DNS pool
  counters, snapshotting `ntsDnsPoolStats()` either side of the query
  run so the cumulative fields read as a per-run delta. `refused`
  (admission blocked by `dnsConcurrencyCap`) and `spawnFailed` (the OS
  refused the worker thread) are the pair 9.0 added to make that
  distinction observable, and the CLI was the reference consumer with
  no way to show it. Human mode gets a two-line trailing block; `--json`
  gets a `{"event":"dns_pool_stats"}` NDJSON record. Example app only;
  no package API change. (NTS-144)

- The example app's log renderings now surface `keWarnings`. The text
  form appends a trailing `ke-warnings=[1,4097]` token to the
  continuation row only when the list is non-empty — the IANA registry
  has no assignments as of RFC 8915, so every server observed in
  practice sends none and an always-present `ke-warnings=[]` would be
  pure noise. The JSON payloads carry `ke_warnings` unconditionally,
  empty list included, so a machine consumer can index the key without
  a presence branch. Both surfaces route through `nts_format`, so the
  GUI log view and the CLI pick it up without a per-caller change.
  Example app only; no package API change. (NTS-142)

- The internal cookie store is now a single FIFO queue rather than a
  map keyed by host. Its only owner, a cached session, is 1:1 with a
  negotiated `host:port`, so the key duplicated a value the session
  already held and every call site passed `session.ntpv4_host` to get
  it back. What the key did add was a way to get it wrong: the KE
  endpoint and the NTPv4 host diverge whenever a KE response carries a
  Server record (RFC 8915 §4.1.7), so a deposit filed under one and a
  draw made under the other would strand the cookies behind a second
  key and present an empty jar — no type error, no panic, just a
  session that re-handshakes on every query. Removing the key makes
  that mismatch unrepresentable. Internal only; no public API or
  observable behaviour changes. (NTS-130)

- The internal cookie store's capacity is now a `NonZeroUsize` rather
  than a `usize` validated by a runtime assertion. A zero capacity is
  degenerate rather than merely invalid — every insertion would evict
  what it had just stored, so the jar would read as permanently empty
  and each query would report having no cookies. The old constructor
  caught that with an `assert!`, which turns a caller's mistake into a
  process abort at the moment the jar is built. Encoding the bound in
  the parameter type rejects it at the call site instead, and removes
  the only panic on the path. Internal only; no public API or
  observable behaviour changes. (NTS-132)

- The host attribution in the NTS-KE warning log moved out of
  `establish_session` into a small named helper. The warnings come
  from the KE peer, but a KE response carrying a Server record
  (RFC 8915 §4.1.7) redirects the NTP phase to a different machine
  that emitted nothing — so labelling the warning with the redirect
  target names the wrong host. That misattribution was previously
  caught only by review; the helper makes it directly testable
  without a log-capture harness. Record-level coverage was also added
  for `validate_response`, pinning that Warning records reach the
  caller in wire order and that the redirect host stays distinct from
  the KE host. Internal only; the emitted log line, the public API,
  and all observable behaviour are unchanged. (NTS-133)

- The bounded DNS resolver's worker-spawn step is now injectable via an
  internal `resolve_with_spawner`, so the spawn-failure branch has
  direct test coverage. That branch normalises both libc shapes
  (`EAGAIN`, `ENOMEM`) to `WouldBlock` and tags the message with a
  stable prefix, which is the only thing distinguishing a refused spawn
  from a saturated pool at the two mapping sites that classify the
  error. The prefix contract was previously pinned only against a
  hand-built error, so a refactor that dropped or reformatted it would
  have silently regressed the reported phase back to DNS saturation
  with no test failure. The new test drives the real branch and follows
  the resulting error through to its phase tag, exercising producer and
  consumer together. The production path still resolves to a single
  monomorphised call to the real thread builder. Internal only; no
  public API or observable behaviour changes. (NTS-134)

- **Breaking (error type):** the `trustMode` / `customRoots` pair
  validation now throws `NtsError.invalidSpec` instead of
  `ArgumentError`. Both violations — a non-null `customRoots` without
  `TrustMode.custom`, and `TrustMode.custom` without non-empty roots —
  previously escaped the documented "single structured failure type"
  contract, so a caller with only an `on NtsError catch` arm missed them
  on the async `ntsGetTime` path. The checks move to
  `_validateTrustPolicy` in `nts_validation.dart` so the `NtsClient`
  factory and every entry point routing through it share one
  implementation. Messages are unchanged; only the thrown type differs.
  Callers catching `ArgumentError` for these two cases must switch to
  `NtsError` (or `NtsErrorInvalidSpec`). (NTS-109)

- `ntsGetTime` and `NtsClient.getTime` now share one preamble and one
  closure binding. Both previously repeated the same three-step
  verification-instant conversion, validation, and re-wrap, then bound a
  structurally identical `warm` / `query` closure pair forwarding five
  arguments apiece — the only difference between the two blocks being
  whether the closures called the top-level functions or the client
  methods. Both now delegate to a shared `_getTimeFor` helper that
  selects the endpoint pair by tear-off and binds the arguments once, so
  the forwarded arguments cannot drift between the two surfaces. The
  burst-orchestration engine is unchanged, as is the `ntsGetTime` branch
  that runs a non-default trust policy against a private, call-scoped
  client. Internal only — both public signatures and all observable
  behaviour, including the promise that validation failures arrive as a
  rejected future rather than a synchronous throw, are unchanged.
  (NTS-77)

- Rust intra-doc links in the generated Dart bindings are now rewritten
  into Dart form. FRB copies `rust/src/api/nts.rs` doc comments verbatim
  into `lib/src/ffi/api/nts.dart`, so the Dart mirror documented Dart
  APIs using Rust paths: 59 links across the file used `::`, Rust
  casing, or `Self`, none of which name anything on the Dart side, so
  every one rendered as a dead reference. A new post-codegen pass in
  `tool/check_bindings.dart` resolves each path against a symbol table
  *derived from the generated Dart* rather than from a casing rule,
  because FRB treats the shapes differently — a plain enum variant
  becomes a lowerCamelCase value, a freezed sealed-class variant a named
  factory, a `#[frb(sync)]` `new` the unnamed constructor, a free
  function a camelCase top-level. A uniform lowercasing rule would emit
  confidently wrong targets for three of those. References to items FRB
  excludes from the bindings are downgraded to inline code, matching
  what the Rust source already does by hand for crate-internal names,
  and anything that resolves to nothing fails the check with the
  originating `rust/src/api/*.rs` line rather than passing through
  Rust-shaped. The Rust source is untouched, so Rust readers keep
  working intra-doc links. Documentation only. (NTS-135)

- `MonotonicClock` no longer names a generated class when deciding
  whether the installed bridge API is the real FFI dispatch
  implementation. The gate tested `api is NtsRustLibApiImpl`, an
  identifier derived from `dart_entrypoint_class_name` in
  `flutter_rust_bridge.yaml`; renaming the entrypoint broke the file
  loudly, but a codegen template change that reshaped the class
  hierarchy could have left it compiling while selecting the opposite
  arm — silently demoting a real bridge to the suspend-frozen
  `Stopwatch` fallback that v7.0.0 removed for production builds. The
  test is now against `BaseApiImpl`, hand-written flutter_rust_bridge
  runtime code that every generated implementation extends, and
  `test/api_smoke_test.dart` pins both arms of the relationship so an
  FRB upgrade that broke it fails a test instead. Internal only; no
  public API or observable behaviour changes. (NTS-115)

- Three dartdoc clarifications on the public API, no code change.
  `NtsSyncedTime.errorBoundMicros` now states outright that it is a
  snapshot bounding the *anchor* instant and stays fixed while
  `utcNow` keeps projecting, so it is not the current maximum error;
  it sketches how to age it with a caller-supplied drift rate, and
  `utcNow` cross-links back to it. `PhaseTimings` now says its fields
  are monotonic elapsed durations measured inside the native call
  rather than calendar timestamps or sleep-inclusive spans, and points
  suspend-inclusive budgeting at `MonotonicClock` / the `getTime`
  budget — summing phases stays sound for in-call accounting, but no
  addend counts suspend, so the sum cannot yield one.
  `NtsClient.invalidate` now distinguishes "no entry was cached" from
  "the spec is invalid": the `false` return reports only the former, an
  invalid spec throws, and nothing is checked against the network in
  either direction.
  (NTS-116, NTS-118, NTS-120)

### Documentation

- `dart run tool/check_bindings.dart` is now documented as the
  canonical way to regenerate the FRB bindings. The docs previously
  gave `flutter_rust_bridge_codegen generate` as the regeneration
  step, which emits the unpatched form and so reverts the five
  post-codegen patch passes the script applies — lint suppression,
  the three diagnostic-message rewrites on the SSE and DCO codec
  catch-all arms, and the Rust-to-Dart intra-doc link rewriting. The
  result fails the drift gate, and the gate's own error message
  pointed back at the command that caused it, so a contributor
  following it verbatim stayed red. That message now names the script
  and says why bare codegen is not a substitute, `DEVELOPMENT.md`
  tabulates all five passes rather than only the lint-suppression
  one, and the remaining references across the PR template, the FRB
  config, `.gitignore`, `pubspec.yaml`, `rust/src/lib.rs`, and the
  ABI-mismatch error text were updated to match. Tooling and docs
  only — no behavioural change. (NTS-136)

- Release notes for `1.4.0` and earlier moved to a new
  `CHANGELOG_ARCHIVE.md`, which is tracked in git but excluded from
  the published tarball. `CHANGELOG.md` had reached 221 KB — the
  largest file in the package and 39% of its uncompressed payload —
  and pub.dev renders the whole of it on the package page. `2.0.0`
  onwards stays in `CHANGELOG.md` (157 KB); the archive carries the
  rest, is linked from the top of `CHANGELOG.md` and from the
  README's "Upgrading" section, and is covered by the doc-snippet
  validator on the same terms as `CHANGELOG.md`. No entries were
  edited or dropped. (NTS-137)


## 8.0.0

### Breaking

- `NtsError` gains an `abiMismatch` variant. The class is `sealed`, so
  any exhaustive `switch` over it must add an arm; a `switch` with a
  `default` or wildcard is unaffected. Nothing else about the existing
  nine variants changed.

- Removed the deprecated millisecond-valued parameters and the constant
  aliasing them, deprecated since 5.2 in favour of the `Duration` /
  `DateTime` spellings. Gone: the `kDefaultTimeoutMs` constant; the
  `timeoutMs` parameter on `ntsQuery`, `ntsWarmCookies`,
  `NtsClient.query`, and `NtsClient.warmCookies`; and the
  `verificationTimeMs` parameter on those four plus `ntsGetTime` and
  `NtsClient.getTime`. Migration is mechanical:
  `timeoutMs: n` becomes `timeout: Duration(milliseconds: n)`,
  `verificationTimeMs: n` becomes
  `verificationTime: DateTime.fromMillisecondsSinceEpoch(n, isUtc: true)`,
  and `kDefaultTimeoutMs` becomes `kDefaultTimeout.inMilliseconds`.
  The `NtsError.invalidSpec` failures raised when a caller supplied
  both spellings of a parameter are gone with them — the conflict is
  no longer representable. (NTS-99)

### Added

- Failures that originate in the FFI *decode* path are now converted to
  `NtsError.abiMismatch` instead of escaping as raw Dart errors. A
  native library built from Rust sources that disagree with these
  bindings dispatches successfully and only fails on the way back,
  inside the generated codec — and because those failures are bare
  `Error`s rather than `NtsError`s, they bypassed the wrapper's
  conversion arm entirely. The result was a `RangeError (byteOffset)`
  naming neither the cause nor the fix. All four asynchronous entry
  points and all five synchronous ones (`ntsDnsPoolStats`,
  `ntsTrustStatus`, `NtsClient.trustMode`, `NtsClient.invalidate`,
  `NtsClient.clear`) now surface a typed error whose message names the
  rebuild (`cargo build --release` in `rust/`, plus
  `flutter_rust_bridge_codegen generate` if the Rust API changed).
  Three decode-failure shapes are attributed to a layout disagreement:
  `RangeError`, `UnimplementedError` (an enum discriminant the
  generated `switch` has no arm for), and `ArgumentError`. `StateError`
  is deliberately excluded — it signals a missed `NtsRustLib.init()`,
  a bootstrap ordering mistake with its own remediation, and continues
  to reach callers unconverted as the entry points' dartdoc promises.
  This complements the CLI loader warning below, which catches the
  common case ahead of the call but cannot fire for a library loaded
  from outside a crate tree, a prebuilt binary shipped without sources,
  or one built for another architecture. (NTS-98)

  The three attributed shapes are no longer taken on faith. Alongside
  the mock-driven tests that prove each entry point is wrapped, a
  second set drives the real generated `sse_decode_*` functions over
  hand-built buffers that disagree with the layout they were generated
  for — a short struct, an unknown enum tag, an out-of-range fieldless
  enum index, a nonsense length prefix — and feeds whatever they throw
  back through the wrapper. Building a genuinely mismatched native
  library in CI is not practical, so the buffers stand in for one. One
  case is pinned as deliberately *not* converted: a `String` whose
  length prefix is honest but whose bytes are not valid UTF-8 throws
  `FormatException`, which reaches callers unchanged. (NTS-101)

### Fixed

- The example package's CLI tools (`nts_cli`, `nts_health`,
  `nts_manifest`) now warn when the native library they load predates
  the Rust sources it was built from. These tools run under plain
  `dart run`, outside the Native Assets pipeline, so nothing kept the
  dylib in step with `rust/src/**`: `autoLocateDylib` resolved the
  build path by existence alone and opened whatever file was there. A
  library built before a subsequent Rust change was loaded silently
  against newer bindings, and the resulting ABI mismatch surfaced as
  an untyped `RangeError (byteOffset)` on every host — including
  known-good ones — with nothing pointing at the real cause. The
  loader now compares the library's mtime against `rust/src/**` and
  `rust/Cargo.toml`, and prints a stderr warning naming `cargo build
  --release` and the crate directory the library came from (derived
  from its path, so a `--library <path>` pointing at another crate is
  named correctly) when it is older. The check stays silent unless
  both `Cargo.toml` and `src/` sit at the derived crate root, so a
  library outside a crate tree is not reported. The run proceeds, since
  the mismatch is not certain. Maintainer/contributor-facing only:
  `rust/target/` is gitignored and pubignored, and package consumers
  build through `hook/build.dart`, whose cargo invocation tracks
  freshness itself. Note the check is one-directional — checking out an
  *older* Rust revision leaves a newer library that is equally wrong
  but indistinguishable by mtime. (NTS-97)

### Changed

- Refreshed both Rust lockfiles ahead of the major, moving 36 packages
  to their latest compatible versions — `tokio` 1.52.3 to 1.53.1,
  `regex` 1.12.3 to 1.13.1, `cc` 1.2.63 to 1.4.0, `memchr` 2.8.1 to
  2.8.3, `webpki-root-certs` 1.0.7 to 1.0.9, plus `anyhow`, `bytes`,
  and the `futures` and `wasm-bindgen` families. Two packages
  (`wasip2`, `wit-bindgen`) drop out of the fuzz lockfile, no longer
  reachable once `jobserver` moved from `getrandom` 0.3 to 0.4. No
  manifest constraint moved; `rust/Cargo.toml` is untouched. Three
  crates are deliberately held back, each pinning rather than loosening
  the gate that rejected the update, per the guidance in the
  `dependency-review` job's own comment block:

  - `thiserror` stays at 2.0.18 in both lockfiles. 2.0.19 switches
    `thiserror-impl` to `syn 3.0.3` while the rest of the graph is on
    `syn 2.0.119`, tripping `multiple-versions = "deny"` in
    `rust/deny.toml`. (NTS-102)
  - `tokio` stays at 1.52.3 in `rust/fuzz/Cargo.lock` only; the
    production lockfile carries 1.53.1. `rustc 1.99.0-nightly` ICEs in
    `rustc_codegen_ssa` compiling 1.53.1 under the sanitizer flag set
    `cargo-fuzz` passes. Stable compiles the same version cleanly, so
    only the fuzz jobs are affected, and the fuzz harness never ships.
    (NTS-103)
  - `rustc-demangle` stays at 0.1.27 in both lockfiles. 0.1.28 declares
    the legacy slash form `MIT/Apache-2.0` rather than the SPDX
    expression `MIT OR Apache-2.0`; `dependency-review` cannot parse it
    and synthesizes a `LicenseRef-bad-*` placeholder that can never
    match the allow-list. The license terms are unchanged and
    acceptable — this is a metadata-format defect upstream.
    `cargo deny` normalizes the slash form and stays green either way.
    (NTS-104)

  `generic-array` also stays at 0.14.7, constrained transitively by the
  RustCrypto AEAD stack rather than by anything this crate declares.


## 7.1.0

### Fixed

- Fixed the example package's `nts_format_test.dart` failing with
  `Bad state: MonotonicClock requires the nts bridge`: the
  `formatGetTimeSuccess` fixture constructs `NtsSyncedTime`, whose
  constructor captures a monotonic anchor from
  `MonotonicClock.instance`, but the test never initialized the mock
  bridge. The test now calls `NtsRustLib.initMock` in `setUpAll`. CI
  additionally runs `flutter test` for the example package (it was
  previously only analyzed), so example-test regressions fail the
  build. (NTS-95)

### Added

- New RFC 5905 §8 clock-filter fields on `NtsTimeSample`, computed in
  the native worker from the four on-wire timestamps (T1 client
  transmit, T2 server receive, T3 server transmit, T4 client
  receive — T4 is now captured immediately after the UDP recv):
  `offsetMicros` (true clock offset θ = ((T2−T1)+(T3−T4))/2, which
  cancels symmetric network delay and excludes server processing
  time, unlike the `roundTrip / 2` approximation), `peerDelayMicros`
  (peer delay δ = (T4−T1)−(T3−T2), the round trip minus server
  processing time), `rootDelayMicros` / `rootDispersionMicros` (the
  reply header's 16.16 fixed-point root metrics converted to
  microseconds — root delay is decoded as *signed* per RFC 5905, with
  negative on-wire values clamped to `0` since a negative delay is
  not physically meaningful), and `serverPrecision` (log₂-seconds
  clock precision
  from the reply header). All five Dart constructor parameters are
  optional and default to `0`, so existing hand-built fixtures and
  mocks keep compiling unchanged; a zero `peerDelayMicros` is treated
  as "not available" by the plausibility check below. (NTS-78)
- New RFC 5905 statistics on `NtsSyncedTime`: `offsetMicros` (the
  winning sample's θ), `jitterMicros` (sample jitter ψ — the RMS of
  the offset differences between the winning sample and every other
  burst sample, RFC 5905 §10; `0` for a single-sample burst), and
  `errorBoundMicros` (worst-case error at the anchor instant,
  following the root-distance recipe: half the winning sample's
  network delay + half the server's root delay + the server's root
  dispersion + the sample jitter). The constructor parameters are
  optional: the statistics default to `0` and the error bound falls
  back to the pre-7.1 `roundTripMicros ~/ 2` worst case. (NTS-78)
- New `NtsTimeSample.recvBoottimeMicros` field: a sleep-aware
  monotonic reading (same clock source and epoch as
  `ntsBoottimeMicros` / `MonotonicClock`) taken inside the native
  worker immediately after the AEAD-NTPv4 UDP recv returned — the
  wire-level receipt instant of the sample, before any FFI-return,
  worker-thread handoff, or Dart event-loop latency. Subtracting it
  from a later `MonotonicClock` reading in the same process yields
  the scheduling lag since receipt. The epoch is arbitrary
  (per-boot): never persist the value or compare it across boots,
  devices, or processes. The public Dart constructor parameter is
  optional and defaults to `0` (an epoch-implausible sentinel that
  triggers the anchor-lag fallback below), so existing hand-built
  fixtures and mocks keep compiling unchanged. (NTS-94)

### Changed

- `ntsGetTime` / `NtsClient.getTime` now select the winning burst
  sample by lowest network delay — the RFC 5905 peer delay δ when it
  is plausible (within `(0, roundTripMicros]`), falling back to the
  locally measured round trip when it is not (pre-7.1-shaped
  fixtures, or a local clock step mid-exchange) — and compensate the
  one-way delay with that same value (`utc + delay / 2` instead of
  `utc + roundTrip / 2`). On real servers δ excludes server
  processing time, so the compensated instant no longer counts the
  server's receive-to-transmit gap as network transit. (NTS-78)
- `ntsGetTime` / `NtsClient.getTime` now anchor the constructed
  `NtsSyncedTime` on the winning sample's wire-level receipt stamp
  instead of a post-`await` Dart-side observation, removing the
  FFI-return / event-loop scheduling latency that previously made
  the compensated UTC lag true time by that (unmeasured) delta.
  Samples whose stamp fails an epoch-plausibility window (hand-built
  fixtures, mock-mode fallback clocks) fall back to the previous
  post-`await` approximation. (NTS-94)

## 7.0.0

### Added

- New public `MonotonicClock` class (exported from `package:nts/nts.dart`):
  a sleep-aware monotonic time source whose readings keep advancing
  while the device is in deep sleep, unlike `Stopwatch`. Reads
  `CLOCK_BOOTTIME` on Android/Linux, `mach_continuous_time` on
  iOS/macOS, and `QueryInterruptTimePrecise` on Windows through a new
  synchronous bridge call (`ntsBoottimeMicros`). Each instance
  resolves its source once at construction, so readings from one
  instance never mix epochs; construction before bridge init throws
  (see the breaking `NtsSyncedTime` entry below for the exact
  contract). The shared `MonotonicClock.instance` is the same
  timeline the package now uses internally. (NTS-90)

### Changed

- **Breaking:** constructing an `NtsSyncedTime` before the bridge is
  initialized now throws a `StateError` (naming `NtsRustLib.init()`
  as the fix). In 6.0.0 the constructor anchored on a plain
  `Stopwatch` and worked without the bridge; it now captures its
  anchor from `MonotonicClock.instance`, which — like direct
  `MonotonicClock` construction — fails fast when neither
  `NtsRustLib.init()` nor `NtsRustLib.initMock()` has run. A
  production build can therefore never silently degrade to a clock
  that freezes during device sleep. The `Stopwatch` fallback exists
  only for mock mode (`NtsRustLib.initMock()`, or a hand-supplied API
  passed to `NtsRustLib.init(api: ...)`, when the API does not stub
  `crateApiNtsNtsBoottimeMicros`) and is gated structurally:
  a real bridge (the generated FFI implementation installed by
  `NtsRustLib.init()`) dispatches the clock read directly with no
  probe and no catch, so any failure propagates instead of silently
  switching the instance to a suspend-frozen source. Migration:
  `await NtsRustLib.init()` (or `NtsRustLib.initMock(...)` in tests)
  before touching `MonotonicClock`, `NtsSyncedTime`, or `ntsGetTime`;
  downstream mocks should stub `crateApiNtsNtsBoottimeMicros` to keep
  the sleep-aware source in tests. The throwing lazy static is not
  poisoned: the first `MonotonicClock.instance` access after init
  resolves normally. (NTS-93)

- `NtsSyncedTime.utcNow` / `elapsedSinceSync`, the `getTime` total
  timeout budget, and the bridge admission gate's queue-wait metering
  now run on the sleep-aware `MonotonicClock.instance` timeline
  instead of per-call `Stopwatch`es. A device that sleeps mid-session
  no longer silently freezes the projected clock or stalls an
  in-flight budget: `utcNow` stays correct across suspend/resume, and
  a budget that elapses during sleep surfaces as `timeout(ntp)` on
  resume. Pure-Dart tests keep working through
  `NtsRustLib.initMock()`, which retains the `Stopwatch` fallback for
  mocks that do not stub the boottime call (see the breaking entry
  above). (NTS-90)

- The top-level `ntsGetTime` now accepts optional `trustMode` and
  `customRoots` parameters, so a one-call synchronized clock can run
  under a non-default trust-anchor policy without hand-constructing
  an `NtsClient`. The default (`TrustMode.platformWithFallback`, no
  custom roots) keeps the existing process-wide singleton path
  byte-for-byte unchanged; any other policy routes the whole
  warm+burst flow through a private call-scoped client whose native
  handle is disposed before the call returns. This is sound on this
  path specifically because `ntsGetTime` always forces a fresh
  handshake and spends only the cookies that handshake minted — no
  cache-reuse window exists in which a session established under a
  different policy could be served. Pair validation matches the
  `NtsClient` constructor (`customRoots` requires `TrustMode.custom`
  and vice versa, rejected with `ArgumentError` before any FFI
  dispatch). `ntsQuery` / `ntsWarmCookies` are deliberately
  unchanged: their value is the warm session cache, and a per-call
  policy there requires session-table re-keying tracked separately.
  (NTS-89)

## 6.0.0

### Breaking changes

- Removed the eight deprecated underscore-prefixed typedef aliases
  for the pre-3.0 `NtsError` variant names (`NtsError_InvalidSpec`,
  `NtsError_Network`, `NtsError_KeProtocol`, `NtsError_NtpProtocol`,
  `NtsError_Authentication`, `NtsError_Timeout`, `NtsError_NoCookies`,
  `NtsError_Internal`) and the `@Deprecated` `field0` getter aliases
  on the variant subclasses. Both surfaces had been deprecated since
  3.0.0; removal was scheduled for 4.0.0, deferred, and missed again
  at 5.0.0. Migration is mechanical: drop the underscore
  (`NtsError_X` → `NtsErrorX`) and switch `field0` reads /
  `:final field0` pattern matches to the named field (`message` on
  every string-payload variant, `phase` on `NtsErrorTimeout`).
  (NTS-87)

## 5.2.4

### Added

- Added a one-call high-level convenience API: top-level `ntsGetTime`
  and per-client `NtsClient.getTime`. Both compose the existing
  wrappers — a fresh `warmCookies` handshake followed by a serial
  burst of up to `min(8, freshCookies)` `query` calls — pick the
  lowest-RTT sample, apply the standard symmetric-path compensation
  (`utc + roundTrip / 2`), and return the result as a new
  `NtsSyncedTime` anchored to a process-local monotonic `Stopwatch`
  (`utcNow` projects the authenticated instant forward, immune to
  system clock steps; `roundTripMicros`, `samplesUsed`,
  `trustBackend`, and `elapsedSinceSync` expose the diagnostics).
  Tuning is fixed and internal — one configuration sized to serve
  phones and desktops alike: an 8-sample burst, one total 8-second
  wall-clock budget shared across the handshake and every burst query
  as a single shrinking deadline, and the package-default concurrency
  caps forwarded to every underlying call. Deployments needing
  different numbers compose `ntsWarmCookies` + `ntsQuery` directly.
  Error posture is best-effort across the burst: individual query
  failures are tolerated when at least one sample lands; an all-fail
  burst rethrows the last query error, a zero-cookie handshake
  surfaces `NtsError.noCookies`, and a budget exhausted before the
  first query surfaces `NtsError.timeout(phase: ntp)`. Validation
  front-loads the same range checks as `ntsQuery` before any FFI
  dispatch. Dart-only wrapper layer; zero FFI/bridge changes. The
  example app's GUI gains a matching **Get Time** action button
  alongside NTS Query / Warm Cookies, with a `formatGetTimeSuccess`
  log rendering that reports the burst size, projected UTC, and
  `± RTT/2` error bound.
  (NTS-76, NTS-80)
- Added `.github/workflows/advisory.yml` with two scheduled,
  non-blocking documentation-hygiene jobs (weekly, Wednesday 05:00
  UTC): a `typos` spell check over the whole tree (configured via the
  new `_typos.toml`, whose suppressions are all verified false
  positives — the `allo-isolate` crate name, hyphenated `mis-*` prose
  prefixes, bead IDs, base64/PEM test fixtures, `PNGs`, and
  Xcode-generated `*.pbxproj`/`*.xib`/`*.storyboard` files) and a
  `lychee` link check over all Markdown (configured via the new
  `lychee.toml`, which excludes build-artifact paths and the
  auth-gated Dependabot dashboard URL, retries transient failures,
  and accepts 429s). Both jobs stay off the required-checks list; the
  workflow also runs on PRs that touch itself or its config files so
  changes to the checks are exercised before merge. Both runs verified
  clean locally against typos v1.48.0 and lychee v0.24.2. (NTS-74)
- Defined explicit Codecov status checks in `.codecov.yml`, replacing
  the default "auto" targets: project statuses for the merged report
  (88%) and per-flag `dart` (94%) / `rust` (86%) baselines, each with a
  1% threshold, plus a patch status (75%, 5% threshold) for PR-diff
  coverage. Targets are calibrated ~1pt under the observed baselines
  (dart 95.43%, rust 87.30%, overall 88.92%). All statuses start
  `informational: true` — they report to GitHub without blocking —
  and will be promoted to blocking once stable, per the same
  advisory-first convention as new CI jobs. Flag statuses set
  `flag_coverage_not_uploaded_behavior: include` so carried-forward
  sessions are evaluated when a PR skips one coverage leg. Config-only;
  no workflow changes. (NTS-73)
- Added `rust/deny.toml` and a `cargo-deny` CI job (bans, licenses,
  sources) to `.github/workflows/ci.yml`, plus the shared narrow SPDX
  license allow-list wired into the `dependency-review` job's
  `allow-licenses` input. The allow-list is exactly the set of licenses
  the current dependency tree needs (MIT, Apache-2.0,
  Apache-2.0 WITH LLVM-exception, ISC, BSD-3-Clause, Zlib, 0BSD,
  Unlicense, Unicode-3.0, CDLA-Permissive-2.0); any new license
  reaching the tree fails CI and becomes a deliberate PR decision made
  by extending `[licenses].allow` in `rust/deny.toml` and the
  `allow-licenses` input together. The `bans` check denies duplicate
  crate versions (two known duplicates — `getrandom` 0.2.x and
  `windows-sys` 0.52 — are version-pinned skips that expire naturally),
  and `sources` restricts all crates to crates.io. The `advisories`
  check is deliberately not run: RustSec coverage already comes from
  the daily cargo-audit job in `audit.yml`. CI-only; the new job stays
  off the required-checks list initially. (NTS-72)

### Changed

- Migrated the public time-handling API to idiomatic Dart types: the
  six async entry points (`ntsQuery`, `ntsWarmCookies`, `ntsGetTime`,
  and their `NtsClient` twins) now take `Duration timeout`
  (default `kDefaultTimeout`, a new exported constant equal to
  `Duration(milliseconds: 5000)`) and `DateTime? verificationTime`
  (interpreted as UTC via `toUtc()`; must not be before the Unix
  epoch). The former `int` parameters — `timeoutMs`,
  `verificationTimeMs` — and the `kDefaultTimeoutMs` constant remain
  fully functional but are `@Deprecated`, slated for removal in a
  future major release. Passing both spellings of the same knob is
  rejected as `NtsError.invalidSpec` when the conflict is detectable
  (`verificationTime` + `verificationTimeMs` always; `timeout` +
  `timeoutMs` when `timeout` differs from the default). Behaviour is
  unchanged for un-migrated callers. Internally the wall-clock budget
  now flows as `Duration` end-to-end and converts to the FFI's
  millisecond integer only at the dispatch boundary, using a ceiling
  so a live sub-millisecond remainder is never rounded down to a dead
  budget (the forwarded value may exceed the true remainder by
  <1 ms). Validation messages name both the new and deprecated
  parameters, and the timeout message states the 1 ms floor. The
  example app (GUI controller, `nts_cli`, health probes) migrated to
  the `Duration` API; the CLI `--timeout` flag stays milliseconds
  with a single conversion point. Dart-only wrapper change; zero
  FFI/bridge changes. (NTS-81)

### Documentation

- Restructured the README around the high-level convenience API: the
  "Use" section became a "Quick start" leading with `ntsGetTime` and
  the `NtsSyncedTime.utcNow` monotonic projection, and the
  "Production Considerations" section became "Manual control
  (advanced primitives)", presenting `ntsQuery` / `ntsWarmCookies` /
  `NtsClient` as the composition surface for callers who need
  non-default burst sizes, budgets, or handshake timing. The API
  summary table now lists `ntsGetTime` first as the recommended
  entry point. Cross-references in `example/example.md` and
  `example/main.dart` updated to the renamed section. Docs-only; no
  behavioural change. (NTS-85)
- Documented the millisecond resolution of the FFI boundary on the
  typed time parameters (`ntsQuery` dartdoc and the README tuning
  notes): a sub-millisecond `timeout` component is rounded **up** to
  the next whole millisecond, and sub-millisecond `verificationTime`
  precision is **truncated** to whole milliseconds since the epoch —
  microseconds do not round-trip through either parameter. Docs-only;
  no behavioural change. (NTS-84)

### Security

- Bumped `anyhow` from `1.0.102` to `1.0.103` to clear **RUSTSEC-2026-0190**
  (Scorecard code-scanning alert #79): an unsoundness in
  `anyhow::Error::downcast_mut()` where, after context is added via
  `Error::context`, the returned `&mut T` is derived from a borrow chain that
  includes a shared reference, so writing through it is a Stacked Borrows
  violation (undefined behaviour). `anyhow` is a purely transitive dependency
  here (via `flutter_rust_bridge` → `allo-isolate`); no `Cargo.toml` in this
  repo declares it. `allo-isolate`'s own caret constraint already permits the
  patched release, so the fix is a `Cargo.lock`-only bump — applied to both
  `rust/Cargo.lock` and `rust/fuzz/Cargo.lock` — with no manifest or source
  change. (NTS-71)


## 5.2.3

### Added

- Added two cargo-fuzz targets covering the unauthenticated UDP parse
  surface (`rust/fuzz/fuzz_targets/`): `parse_authenticator_body`
  drives the Authenticator body's length arithmetic (`nonce_len` /
  `ct_len` prefixes, `div_ceil` padding, slice bounds) directly, and
  `parse_server_response` drives the full receive entry end-to-end
  under a fixed real AES-SIV-CMAC-256 key — modelling the off-path
  attacker, who cannot forge AEAD tags, so every pre-AEAD arm (header
  checks, extension sweep, unauthenticated-NTSN, duplicate-UID,
  Authenticator parse, AAD-offset arithmetic) is fuzzed exactly as
  exposed. `IdentityAead` was deliberately not plumbed in: it is
  `#[cfg(test)]`-only and would require extending the `AeadKey`
  dispatch enum, which its docs pin as intentionally not extended.
  Both targets ship committed seed corpora (including a fully
  authenticated canonical reply that parses `Ok` under the harness
  key) and are wired into the nightly `.github/workflows/fuzz.yml`
  matrix, which now runs five targets. Enabled by re-exporting
  `parse_authenticator_body`, `parse_server_response`, and `AeadKey`
  through the `__internal-fuzz`-gated `__internal_fuzz` module; no
  production API change. (NTS-60)

- Added a `matrix-parity` job to the nightly fuzz workflow
  (`.github/workflows/fuzz.yml`) that diffs `cargo fuzz list` against
  the workflow's `matrix.target` list and fails on any mismatch in
  either direction. The requirement that every `[[bin]]` in
  `rust/fuzz/Cargo.toml` is mirrored in the matrix was previously
  comment-enforced only — a drifted entry manifested as a silently
  un-fuzzed target with no red signal. The job shares the workflow's
  triggers, so the PR paths filter covers both drift sources (a new
  fuzz target under `rust/fuzz/**`, or a matrix edit to the workflow
  file). CI-only; no runtime change. (NTS-68)

- Added a Dart-side **bridge admission gate** bounding how many of the
  package's blocking bridge calls occupy `flutter_rust_bridge` worker
  threads at once. Each in-flight `ntsQuery` / `ntsWarmCookies` /
  `NtsClient.query` / `NtsClient.warmCookies` call pins one FRB worker
  (a fixed pool of one thread per logical CPU) for up to `timeoutMs`,
  so an unbounded distinct-host fan-out could previously exhaust the
  pool and stall unrelated bridge calls — a hazard 5.2.2 documented
  but did not enforce. The four wrappers now accept a
  `bridgeConcurrencyCap` parameter (default
  `kDefaultBridgeConcurrencyCap = 4`, validated `1..4294967295` for
  symmetry with `dnsConcurrencyCap` even though the value never
  crosses the FFI boundary) enforced by one FIFO gate per isolate
  (gate state is Dart-side and isolate-local; the FRB worker pool it
  bounds is shared process-wide): calls beyond the cap queue on the
  Dart side holding no worker
  thread, queue wait is charged against `timeoutMs` (only the
  remainder crosses the FFI boundary; uncontended calls forward the
  budget verbatim), and a budget that expires while queued fails with
  `NtsError.timeout` carrying the new `TimeoutPhase.bridgeSaturation`
  value — Dart-authored, fired before any FFI dispatch, so its
  `trustBackend` is always `null`. Mixed-cap bursts get the same
  asymmetric admission semantics as the Rust-side DNS resolver pool,
  with one FIFO refinement: a queued call is only overtaken by a
  later call whose larger cap admits it while the queued call's own
  cap does not. **Behavioural change for existing callers:** a
  more-than-4-distinct-host burst now runs 4-at-a-time instead of
  pool-width-at-a-time, and the tail of a burst against slow servers
  can surface `bridgeSaturation` where it previously competed for
  pool threads. **Source-compat note:** exhaustive `switch`es over
  `TimeoutPhase` gain a new case. The example catalog tools raise the
  cap to their `-c` fan-out (mirroring the existing DNS-cap sizing)
  so probe measurements stay self-saturation-free. (NTS-69)

- Added two catalog CLIs to the example app alongside `nts_cli`:
  `nts_health` probes every server in the bundled catalog with a
  bounded fan-out and renders a per-server health report (text or
  JSON), and `nts_manifest` distils those probe results into a
  reliable-server manifest, with a committed snapshot at
  `example/assets/reliable-servers.json`. Both tools share one
  argument parser (`example/lib/src/cli/catalog_tool_args.dart`) and
  one probe engine (`example/lib/src/health/probe.dart`). Probes that
  fast-fail with `TimeoutPhase.dnsSaturation` are bucketed as a
  local-saturation verdict rather than a server failure, so an
  over-aggressive local fan-out cannot masquerade as server
  unreliability; the renderers and aggregation logic are covered by
  dedicated tests. Example-only; no package API change.
  (NTS-58, NTS-59)

- Exposed the Rust-side DNS resolver pool cap across the example
  surfaces. The three catalog CLIs (`nts_cli`, `nts_health`,
  `nts_manifest`) gain a `--dns-cap` flag: by default both
  concurrency caps are auto-sized to the host fan-out
  (`-c`/`--concurrency`) so probe runs stay self-saturation-free,
  and an explicit `--dns-cap` overrides the auto-sizing — a value
  below the fan-out deliberately re-exposes the
  `TimeoutPhase.dnsSaturation` fast-fail for testing. The GUI
  controller (`example/lib/src/state/nts_controller.dart`) now
  passes `dnsConcurrencyCap` (package default
  `kDefaultDnsConcurrencyCap = 4`) explicitly at its `ntsQuery` /
  `ntsWarmCookies` call sites, mirroring the existing
  `bridgeConcurrencyCap` threading. Example-only; no package API
  change — the parameter itself has been public since 1.3.0.

### Changed

- Bumped the pinned Rust toolchain (`rust/rust-toolchain.toml`) from
  1.96.1 to 1.97.1. The point release carries the fix for an LLVM
  miscompilation (rust-lang/rust#159035) present since at least
  Rust 1.87 — relevant to the cryptographic core, so tracked
  promptly. No binding regeneration was required: `dart run
  tool/check_bindings.dart` under the new pin reports the FRB
  bindings in sync (the `Eq`-derive internal names echoed in the
  generated ignore-list header are unchanged between 1.96 and
  1.97), and `cargo fmt --check` / `cargo clippy -D warnings` /
  `cargo test` all pass with no new lints. MSRV declared in
  `rust/Cargo.toml` and mirrored in `rust/clippy.toml` stays at
  1.87 (1.97 stabilizes nothing the crate adopts). The pin
  references in `README.md`, `DEVELOPMENT.md`, and
  `example/README.md` are aligned with the new version, and the
  docs now spell out the upgrade path for consumers and
  contributors: none — rustup resolves `rust-toolchain.toml` on
  the next `flutter run` / `flutter build` (or any `cargo`
  invocation inside `rust/`) and auto-installs a bumped pin, so no
  `rustup update` or other manual step is required. (NTS-79)

- Bumped the pinned Rust toolchain (`rust/rust-toolchain.toml`) from
  1.92.0 to 1.96.1 and landed the clippy fixes deferred to this bump
  in the same change: the `empty_enum` lint key in `rust/Cargo.toml`
  is renamed to its 1.95+ spelling `empty_enums`, and two
  `clippy::map_unwrap_or` sites are rewritten (`is_ok_and` in
  `nts/ke.rs`, `map_or` in `api/nts/tests.rs`). The FRB bindings were
  regenerated under the new pin to absorb a comment-only drift in the
  generated ignore-list header (`lib/src/ffi/api/nts.dart`): rustc
  renamed the `Eq`-derive internal method
  `assert_receiver_is_total_eq` to `assert_fields_are_eq` between
  1.92 and 1.96, and `flutter_rust_bridge_codegen` echoes those names
  — required to keep the `rust-bridge-sync` CI gate green. No
  functional change; MSRV declared in `rust/Cargo.toml` is
  unaffected. (NTS-51)

- The `parse_server_response` fuzz harness now consumes the canned
  fixture constants (`UID`, `CLIENT_TX`, `S2C`) as re-exports through
  the `__internal-fuzz`-gated `__internal_fuzz` module instead of
  hardcoding mirrors of `nts::test_helpers`. Previously, a change to
  the helper constants would silently de-authenticate the committed
  `canonical-authenticated-response` seed — pre-AEAD arms would still
  fuzz but post-AEAD coverage would vanish with no red signal. With
  the re-exports, a helper change either propagates to the harness or
  fails to compile. `test_helpers` is now additionally compiled under
  the `__internal-fuzz` feature (still compiled out of release
  builds); no production API change. (NTS-67)

- Tightened the PR-time `dependency-review` CI gate from
  `fail-on-severity: high` to `moderate`, so moderate-severity
  advisories on newly-introduced dependencies now block the merge
  instead of passing silently. The `high` setting was always framed as
  a starting floor; with the daily `audit.yml` cargo-audit job in place
  as a second net, the tighter PR-time floor costs nothing extra. Per
  the established policy, if the gate fires on a transitive bump the
  fix is to pin the offending dependency, not loosen the gate.
  CI-only; no runtime change. (NTS-62)

### Documentation

- Documented FRB worker-pool occupancy of the blocking bridge calls.
  `ntsQuery` / `ntsWarmCookies` (and the `NtsClient` equivalents) are
  `async` on the Dart side, but each in-flight call pins one
  `flutter_rust_bridge` worker thread for its full blocking duration —
  up to `timeoutMs` — and the default pool holds one thread per
  logical CPU, so an unbounded burst of cold queries against many
  distinct hosts can occupy every worker and stall unrelated bridge
  calls. Same-host storms are already collapsed onto one handshake by
  the Rust-side per-key singleflight. Added a worker-pool-occupancy
  note with a bounded fan-out recommendation to the `ntsQuery`
  dartdoc, cross-referenced from `ntsWarmCookies` and
  `NtsClient.query` / `NtsClient.warmCookies`, plus a matching
  module-doc note in `rust/src/api/nts.rs`. Comment-only; no
  behaviour change. (NTS-64)

- Documented the `nts_health` catalog CLI in `example/README.md` —
  prerequisites, usage, flag reference, and how its verdicts relate
  to the probe outcomes. (NTS-58)

- Realigned the root documentation set (`README.md`,
  `ARCHITECTURE.md`, `DEVELOPMENT.md`) and the example docs
  (`example/README.md`, `example/GUI_GUIDE.md`,
  `example/CLI_GUIDE.md`) with the Native Assets build flow and the
  1.96.1 toolchain pin. The build-hook path is documented once —
  `hook/build.dart` resolves the toolchain through rustup from the
  `rust/rust-toolchain.toml` pin, auto-installing it plus the
  platform's cross-compile target on first use — and the example
  docs cross-reference the root anchors (`#prerequisites`,
  `#timeout-budget-and-bounded-dns`, `#rust-log-verbosity`) instead
  of restating them. The root README's "Use" snippet now passes
  `dnsConcurrencyCap` alongside `bridgeConcurrencyCap` so both
  resource bounds are demonstrated, the `NTS_BRIDGE=mock` fallback
  and `verbose_logs` user-define descriptions match the technical
  detail in `DEVELOPMENT.md`, and the CLI usage blocks in
  `example/README.md` / `example/CLI_GUIDE.md` are verified against
  the live `--help` output of the tools. Documentation-only; no
  behaviour change.

### Fixed

- The FRB drift gate (`tool/check_bindings.dart`, run locally and by
  CI's `Verify FRB bindings are in sync` job) now fails when codegen
  *creates* a generated file the repo does not yet track. The gate
  previously relied on `git diff --exit-code`, which reports only
  tracked-file changes, so a brand-new FRB-emitted module was caught
  only indirectly (via the tracked dispatcher's import-list change). A
  `git status --porcelain --untracked-files=all` check scoped to the
  watched paths (`lib/src/ffi/`, `rust/src/frb_generated.rs`) now fails
  the gate outright with a dedicated diagnostic naming each untracked
  file. Complements the existing orphaned-module check, which covers
  the removal direction. Tooling-only; no runtime change. (NTS-63)

### Security

- Closed the last plain-bytes cookie transit: fresh NTS cookies recovered
  from the encrypted NTPv4 reply are now wrapped in `Zeroizing<Vec<u8>>` at
  the parse site (`ServerResponse::fresh_cookies`), carried through
  `SessionTable::deposit_cookies`, and moved into the `CookieJar` without
  unwrapping. Previously the transit collection held naked `Vec<u8>` values
  until the jar boundary, so the deposit-side discard paths (stale session
  generation, evicted session) freed cookie bytes without wiping them.
  The AEAD-decrypted extension body inside `parse_server_response` is also
  `Zeroizing`-wrapped now, as is every encrypted-extension body copied out
  of it (cookie or not), so the decrypted plaintext and its non-cookie
  discards are wiped on drop as well.
  `ServerResponse` also gains a manual redacted `Debug`
  (`<redacted; N cookies>`) matching the existing `ClientRequest` /
  `CookieJar` discipline, plus a compile-time type pin and a Debug-redaction
  regression test. Internal type change only — no public API or FRB binding
  change. (NTS-61)

## 5.2.2

### Documentation

- Fixed three broken intra-doc links in the
  `From<std::io::Error> for NtsError` doc block in `rust/src/api/nts.rs`.
  The block linked to crate-private items (`KeTimeoutPhase`,
  `KeError::PhaseTimeout`, `bind_connected_udp_using`) from a public-API
  doc context, which `rustdoc -D warnings` rejects as
  `private_intra_doc_links`. Demoted the
  three references to plain code spans (matching how the same items are
  already cited elsewhere in the file); the two resolvable links on the
  block (`nts_query`, `TimeoutPhase::Ntp`) are unchanged. Comment-only; no
  behaviour change. (NTS-49)

- Documented `CookieJar`'s concurrency contract on the struct's rustdoc. The
  type auto-derives `Send + Sync` (all its fields are `Send + Sync`), so the
  marker traits alone do not warn callers off concurrent use; the real
  constraint is the absence of interior mutability — every mutator takes
  `&mut self`, so a jar shared across threads must be externally synchronised.
  `SessionTable` already owns every jar inside its `Mutex<HashMap<…>>`; the new
  note closes the gap for any future caller that reaches for `CookieJar`
  directly. Comment-only; no behaviour change. (NTS-42)

- Documented the multi-client trust-routing pattern for apps that must reach
  servers in more than one trust domain (e.g. a private-CA internal server
  alongside public servers). Added a "Reaching multiple trust domains"
  section to `README.md` with a worked two-client example, and a matching
  cross-reference in the `TrustMode` API documentation. Reinforces that
  `TrustMode` is fixed per client and that minting one client per trust
  domain keeps each CA scoped to the hosts it should authenticate rather
  than widening every server's trusted-issuer set to the union. (NTS-48)

- Documented the asymmetric starvation behaviour of `dnsConcurrencyCap` on
  the Dart-side public API. The cap is a per-call ceiling, but admission is
  gated against a single process-wide in-flight counter, so a low-cap caller
  can be refused immediately (`NtsError.timeout` /
  `TimeoutPhase.dnsSaturation`) when the pool is already filled by a
  higher-cap caller's workers, even though it has started no lookups of its
  own; the reverse cannot happen. Added a concrete mixed-cap example to the
  `ntsQuery` dartdoc, inherited by `ntsWarmCookies` and `NtsClient.query` /
  `NtsClient.warmCookies` through their existing cross-references.
  Comment-only; no behaviour change. (NTS-44)

### Fixed

- Singleflight waiters now attribute a timeout to the phase the leader
  was actually in (DNS, Connect, TLS, or KE record I/O) instead of a
  blanket `KeRecordIo`. The leader publishes its live phase to its
  singleflight slot via an advisory `Relaxed` atomic (`PhaseReporter`)
  at each handshake boundary; a waiter whose per-call deadline expires
  reads it and emits the matching `TimeoutPhase`, so a leader and its
  parked waiters now report the same phase for the same slow operation
  rather than telling two different stories. Reuses the existing
  `TimeoutPhase` variants — no public API or FRB binding change.
  (NTS-43)

### Security

- Investigated a code-level mitigation for the relative-`ioDirectory`
  library-hijack surface that the README's "Non-Flutter Dart callers must
  pass `externalLibrary` explicitly" subsection documents. The
  `flutter_rust_bridge`-generated `kDefaultExternalLibraryLoaderConfig`
  pins `ioDirectory: 'rust/target/release/'`, which FRB's loader resolves
  against the process working directory, so a bare `NtsRustLib.init()`
  outside a Flutter host loads whatever native library has been planted
  there. Findings against the pinned FRB `2.12.0`: (1)
  `flutter_rust_bridge_codegen generate` exposes only
  `--default-external-library-loader-web-prefix` and `--wasm-bindgen-name`
  — there is no codegen knob to suppress the relative fallback, require an
  absolute path, or detect a non-Flutter context; (2) the generated file
  is marked do-not-edit and is overwritten on every regen, so editing
  `ioDirectory` by hand is not durable; (3) the closest upstream thread,
  `fzyzcjy/flutter_rust_bridge#2168`, tracks adding a YAML `ioDirectory`
  override but is path-correctness-motivated (it proposes `cargo metadata`
  auto-detection), not a refuse-relative security mode. A runtime
  mitigation does exist — build an `ExternalLibraryLoaderConfig` with
  `ioDirectory: null`, load it via the public `loadExternalLibrary`, and
  pass the resulting library to `NtsRustLib.init(externalLibrary: lib)` —
  but that is a package-owned behaviour change beyond this investigation's
  scope and is filed as a follow-up. Outcome: the documentation mitigation
  remains the supported guidance and NTS-11 converts to an upstream-watch
  tracker against `fzyzcjy/flutter_rust_bridge#2168`. No code or behaviour
  change. (NTS-11)

- Hardened the per-request nonce contract at the NTPv4 codec boundary.
  `build_client_request` and the `ClientRequest::nonce` field now document
  that the nonce MUST be CSPRNG-sourced and unique per request under a given
  C2S key — the non-empty check is a floor, not the full contract, because
  the codec is RNG-free and stateless by design. Added a regression test
  that drives the production randomness funnel and asserts the on-wire
  Authenticator nonce is distinct across 100 consecutive requests, mirroring
  the existing Unique Identifier test. No behaviour change. (NTS-41)

- Added a short-lived in-memory replay guard over accepted-response Unique
  Identifiers as a defense-in-depth layer above the AEAD. The post-AEAD
  replay protection previously rested entirely on two stateless echo checks
  — the response must echo the request's Unique Identifier (RFC 8915 §5.3)
  and its `origin_timestamp` must echo the request's `transmit_timestamp`
  (RFC 5905 §8) — whose replay resistance assumes a unique UID per request
  without enforcing it. Each `NtsClient`'s session table now remembers the
  UIDs of responses it has accepted for a bounded window (5 minutes, capped
  at 4096 entries with FIFO eviction) and rejects a response whose UID was
  already accepted with `NtsError.ntpProtocol`, before its now-stale cookies
  are deposited. The AEAD remains the primary guarantee; the cache only
  closes the residual UID-reuse gap (e.g. a CSPRNG failure or caller bug
  reusing a UID together with a transmit timestamp). Behaviour change on the
  replayed-UID path only — the happy path mints a fresh CSPRNG UID per
  request and never trips the guard. (NTS-40)

- Hardened the `verificationTimeMs` clock-skew override with a defensive
  upper bound. Values above `9999-12-31T23:59:59Z`
  (`253_402_300_799_000` epoch ms) are now rejected with
  `NtsError.invalidSpec` rather than being fed into the
  `Duration::from_millis` conversion that pins the TLS certificate
  validity-window check. The override was already validated as
  non-negative; this closes the matching open-ended upper bound on a
  security-relevant time path. (NTS-39)

## 5.2.1

### Fixed

- Completed the API-summary table in `README.md`, adding the missing `NtsClient`
  row, `TrustMode` / `TrustBackend` enum variants, and the four missing
  `defaultBackend*Count` telemetry counters.
- Corrected the `ntsTrustStatus()` dartdoc observable count (six -> seven) and
  added the missing description for `defaultBackendCustomCount`.
- Fixed stale references to "three" atomic loads and counters in the
  `ntsTrustStatus()` documentation to match the current implementation.

## 5.2.0

### Added

- Added `verificationTimeMs` to `ntsQuery`, `ntsWarmCookies`, and the
  corresponding `NtsClient` methods. This optional clock-skew override
  substitutes a caller-supplied timestamp for the TLS verifier's "current
  time" when checking certificate validity windows, which can rescue
  cold-start scenarios where a badly-skewed device clock would otherwise
  deadlock on the initial handshake.

### Changed

- Upgraded `hooks` from `^1.0.3` to `^2.0.2` (no API changes to
  `hook/build.dart`; the 2.0.0 breaking change affects packages that
  implement `ProtocolExtension`, which this hook does not).
- Upgraded `build_runner` from `^2.14.1` to `^2.15.0`.
- Dependency resolution updates: `native_toolchain_rust` 1.0.4+0
  (direct dependency) plus transitive `code_assets` 1.2.1, `build`
  4.0.6, `built_value` 8.12.6, `json_annotation` 4.12.0, `source_gen`
  4.2.3, `vm_service` 15.2.0.

## 5.1.0

### Added

- `TrustMode.bundledOnly` validates exclusively against the
  bundled `webpki-roots` set. No platform-store consultation, no
  silent fallback. Allows consumers to enforce strict validation
  against the library's static bundle, preventing platform-level
  CA compromises or middlebox/decryption proxies from intercepting
  the exchange.
- `TrustMode.custom` alongside `customRoots` list of bytes (PEM
  or DER format) to trust only caller-supplied root certificates.
  Allows consumers to authenticate TLS connections in private
  environments or using custom/enterprise CAs without relying on
  the global platform store or other clients.
- Plumbed a fourth trust telemetry counter (`custom`) to trace
  custom-roots handshakes.
- Validates constructor parameters of `NtsClient` synchronously.

### Fixed

- Adapted the Android JNI bootstrap (`rust/src/android_init.rs`)
  to the `jni` 0.22 `Env` / `EnvUnowned` split and the
  `jboolean` → `bool` change. `rustls-platform-verifier` 0.7's
  `init_with_env` requires `&mut Env`, so the unowned
  native-method handle is upgraded to an owned `Env` via
  `EnvUnowned::with_env` and `init_with_env` is called inside the
  closure returning `bool`. Init failure maps to `Ok(false)`
  inside the closure so a failed bootstrap stays non-fatal (no
  Java exception) and downgrades to the `webpki-roots` fallback,
  preserving the prior contract. The shim is
  `#[cfg(target_os = "android")]` and host CI runners never
  compiled it, so this break shipped in v5.0.0 undetected; a new
  `aarch64-linux-android` `cargo check` step in the rust CI job
  now guards it. (#145, closes #143, NTS-30)
- Removed misleading `(PlatformOnly mode)` prefix from the
  `KeError::TrustBackendUnavailable` `Display` implementation. The
  variant is shared between platform-verifier failures and
  custom-roots failures, so the prefix was inaccurate for the latter.
  `PlatformOnly`-specific context is now embedded inside the message
  string at the two call sites that produce it (nts-o88).

### Security

- Gated verbose snippet-body output in the doc-snippet validator
  (`tool/check_doc_snippets.dart`) behind `--print-snippets` /
  `SNIPPET_VALIDATOR_VERBOSE=1`. On analysis failure the tool no longer
  echoes the verbatim wrapped snippet bodies into the retained CI log by
  default — only the doc file, snippet index, and analyzer diagnostics are
  printed. The opt-in path additionally runs a best-effort redaction pass
  over obvious secret-shaped tokens (key/value assignments, `Bearer`
  tokens, AWS access-key IDs, PEM private-key blocks). (nts-mf7)
- Hardened `TrustMode::Custom` roots handling: caller-supplied root
  certificate bytes are now stored as `Arc<Zeroizing<Vec<u8>>>`. The
  bytes are wiped from RAM when the final `Arc` clone is dropped (the
  clone chain is internal to the KE / query pipeline; see the
  `CustomRootsBytes` rustdoc). The `zeroize` ≥ 1.8 `Vec` impl wipes
  both the initialised length and the spare capacity at drop, so the
  wrapper is capacity-leak free without a manual `shrink_to_fit`. See
  `AGENTS.md` → "Security: Zeroization" for the project-wide
  convention.
- Removed unmaintained `rustls-pemfile` crate (RustSec RUSTSEC-2025-0134).
  PEM certificate parsing in `build_with_custom_roots` now uses
  `CertificateDer::pem_slice_iter` from `rustls-pki-types` (already a
  transitive dependency), which is the migration path recommended by the
  advisory. No new dependencies introduced; `rustls-pemfile` is no longer
  present in `Cargo.lock`.
- Documented and tightened the custom-roots parsing pipeline scope
  (`build_with_custom_roots`, `rust/src/nts/ke.rs`). The
  `CustomRootsBytes` wrapper guarantees the **input** buffer is
  wiped on final-clone drop; the rustdoc and `AGENTS.md` →
  "Security: Zeroization" → "Custom roots parsing pipeline" now
  state the exact scope (input buffer wiped; DER path no longer
  allocates an intermediate copy because `CertificateDer::from_slice`
  borrows out of the `Zeroizing` backing buffer; PEM path's
  upstream-owned per-cert `Vec<u8>` is dropped per loop iteration
  but not zeroised — full closure requires an upstream
  rustls/rustls-pki-types API change tracked as `nts-xdo`). The
  refactor also eliminates the previous `bytes.to_vec()` copy on
  the DER path and bounds the residual liveness window of PEM
  per-cert buffers to a single iteration. (nts-r3s)
- Implemented manual `Debug` for `TrustMode` and internal
  `CustomRootsBytes` to redact sensitive certificate bytes from logs,
  rendering as `<REDACTED: N bytes>`. (nts-8wp)
- Escaped upstream RustSec advisory fields before interpolating them
  into the `cargo audit` sticky PR comment table. A stray `|` in an
  advisory title would have broken the table layout; in the worst
  case a crafted advisory record could inject formatting that
  confused reviewers. The jq script now escapes `|` to `\|` and
  collapses CR/LF/Tab to a single space for every field that
  originates from `cargo audit --json` (package name, version,
  advisory id, URL, title). URL validation is out of scope; the
  RustSec database is treated as trusted upstream. (nts-mat)

### Documentation

- Expanded `TrustMode` API documentation to detail the security
  trade-offs of each variant — in particular the exposure of
  `platformWithFallback` to TLS-inspection appliances that
  inject a corporate CA into the platform store, which can
  undermine the AEAD-integrity guarantee NTS derives from TLS
  keying material. High-security callers are now guided toward
  `NtsClient(trustMode: TrustMode.bundledOnly)` in the API doc,
  `README.md` Security Considerations section, and the
  `ARCHITECTURE.md` trust-anchor reference.

### Packaging

- `.pubignore` now also excludes `sonar-project.properties`, the
  maintainer-only SonarCloud/SonarQube project configuration. It
  joins the maintainer configs already excluded
  (`analysis_options.yaml`, `dart_test.yaml`,
  `flutter_rust_bridge.yaml`); package consumers never run
  SonarCloud against the published tarball, so the file is pure
  noise on the published surface. Sub-1 KB, so no archive-size
  impact.

### Internal

- Custom-roots bundle is now held behind `Arc<[u8]>` inside the internal
  `KeTrustMode` and stored on `NtsClient` in that internal form, so the per-
  `query` / per-`warmCookies` and per-handshake `.clone()` calls that thread
  the trust-mode through the cookie-cache and KE-handshake layers are O(1)
  atomic refcount bumps rather than full-bundle copies. The public
  `TrustMode.custom` + `customRoots: List<int>?` consumer API is
  unchanged; the internal FRB-generated Dart bindings were updated to
  decode the `Custom` variant's payload (`Uint8List field0`) via the
  SSE codec.
- `tool/check_bindings.dart` now post-processes the FRB-generated
  `rust/src/frb_generated.rs` and `lib/src/ffi/frb_generated.dart` to
  replace the empty diagnostic arms FRB 2.12 emits as the defensive
  `#[non_exhaustive]` catch-all in its generated codec impls
  (`unimplemented!("")` in the Rust SSE codec, `UnimplementedError('')`
  in the Dart SSE codec, `Exception("unreachable")` in the Dart DCO
  codec) with diagnostic-bearing forms that include the unexpected
  wire-format tag value. Runtime semantics are unchanged (the arms
  remain unreachable for exhaustive enums in practice), but any
  unexpected panic in generated codec code is now greppable back to its
  FRB origin and identifies which tag triggered it.
- `build_with_custom_roots` now accepts PEM bundles whose first
  `-----BEGIN CERTIFICATE-----` marker is preceded by an attribute
  preamble (`Bag Attributes` / `subject=` / `issuer=` lines that
  `openssl pkcs7 -print_certs` and PKCS12 exports routinely emit)
  rather than misclassifying those buffers as DER. Detection now
  fires when the UTF-8 view of the input contains the BEGIN marker
  anywhere, not only at the first non-whitespace byte; raw DER
  input continues to take the DER branch since it is not valid
  UTF-8.
- `build_tls_config_inner` (Android and non-Android) now `match`es
  `KeTrustMode` exhaustively in the fallback branch instead of an
  `if trust_mode == KeTrustMode::PlatformOnly { … } else { … }`
  shape. Adding a future `KeTrustMode` variant will now force a
  compile-time decision at this site rather than silently
  inheriting the `PlatformWithFallback` arm.
- Added `example/**` to the `dart` path filter in
  `.github/workflows/ci.yml` so example-only diffs run the
  `Analyze example app` step and a broken example turns the
  `Dart tests gate` red. Closes the gating gap exposed by
  #142 / #145, where an example-only change could merge without
  the gate reflecting `flutter analyze` breakage. (NTS-32, #147)

## 5.0.0

### Breaking changes

- The FRB bridge entrypoint class is renamed from `RustLib` to
  `NtsRustLib`, with `RustLibApi` / `RustLibApiImpl` / `RustLibWire`
  becoming `NtsRustLibApi` / `NtsRustLibApiImpl` / `NtsRustLibWire`.
  Replace `await RustLib.init()` with `await NtsRustLib.init()` (and
  the same for `RustLib.initMock`). The rename lets consumers depend
  on multiple `flutter_rust_bridge`-backed packages without
  `import ... as prefix` aliasing.


### Packaging

- `.pubignore` now excludes the test-only Rust modules
  (`rust/src/**/tests.rs` and `rust/src/**/test_helpers.rs`) that
  surfaced in the 4.0.0 published archive after PRs #61, #63, and
  #64 extracted them from inline `#[cfg(test)] mod tests { … }`
  blocks into sibling files. The sibling files are referenced via
  `#[cfg(test)] mod tests;` / `#[cfg(test)] pub(crate) mod test_helpers;`
  in their parent modules, so the `#[cfg(test)]`
  attribute removes the module reference before file lookup and
  consumer-side `cargo build --release` driven by Native Assets
  never compiles or even parses them. Inline `#[cfg(test)]`
  blocks inside files like `rust/src/nts/cookies.rs` /
  `dns.rs` / `aead.rs` stay in place because those parent files
  are required by release builds; only the inner `tests` mod is
  cfg-gated. These optimizations shave ~243 KB uncompressed
  (~60 KB compressed) from the Rust tree, partially offsetting the
  addition of high-quality screenshots for pub.dev; the final
  published tarball is approximately 783 KB. No consumer-visible
  behaviour change; surfaces a post-4.0.0 archive-sanity-check
  observation.

### Security

- Added **GitHub CodeQL** advanced workflow for static security
  analysis of the Rust core. The workflow is synchronized with the
  pinned toolchain in `rust/rust-toolchain.toml` and includes
  mirrored exclusions for fuzzing targets in both the workflow
  filters and the CodeQL configuration. Findings are surfaced
  to the Security tab. (PR #87, bead `nts-wat`)

### Maintenance

- Added **GitHub Dependabot** configuration to track updates for Dart
  (`pub`), Rust (`cargo`), and GitHub Actions. Excluded
  `flutter_rust_bridge` from automated updates to maintain
  coordinated pinning across the Dart/Rust boundary. (bead `nts-tqp`)

## 4.0.0

This major release consolidates the post-3.0 work that landed on
`main` between the 3.0 cut and this tag. It is a **major version
bump** because several of the items below break the public Dart or
Rust API surface, and one (the strict per-chain `PlatformOnly`
semantics on Android) is a deliberate behaviour change for a
caller-opted-in mode.

The headline shape changes:

1. **`NtsError` surface uniformity** — the three remaining
   single-payload `NtsError` variants (`invalidSpec`,
   `trustBackendUnavailable`, `internal`) move from positional to
   named-parameter constructors so every `String`-payloaded
   variant binds to the same name (`message`) and every variant
   with a non-`trustBackend` payload is constructed with named
   arguments. The five `network` / `keProtocol` / `ntpProtocol` /
   `authentication` / `timeout` variants already moved in 3.0.0;
   this completes the sweep.

2. **Wrapper-side integer-range validation** — the four async
   wrapper entry points and `NtsClient.invalidate` now reject
   out-of-range `port` / `timeoutMs` / `dnsConcurrencyCap`
   arguments as `NtsError.invalidSpec` before any FFI dispatch,
   closing the gap where a `RangeError` thrown by the FRB encoder
   used to escape the wrapper's "single error surface" contract.
   `kDefaultDnsConcurrencyCap` is bumped from the `0` sentinel to
   the actual numeric default (`4`) so consumers reading the
   constant see what the package actually applies.

3. **Strict per-chain `TrustMode::PlatformOnly` on Android** — the
   Android-side `HybridVerifier` no longer silently retries
   against the `webpki-roots` static bundle for the two curated
   fallback-eligible failure shapes (`Revoked` from
   missing-OCSP-AIA chains; `General("failed to call native
   verifier: …")` from R8-stripped JNI glue) when the caller is
   running under `TrustMode::PlatformOnly`. The platform
   verifier's error propagates verbatim. `PlatformWithFallback`
   (the historic default) is unchanged.

4. **NTS-KE streaming-read budget hardened to 16 KiB** — the
   streaming layer in `rust/src/nts/ke.rs::read_to_end_capped`
   now refuses to accumulate more than 16 KiB per handshake (down
   from the 64 KiB codec ceiling), closing a memory-pressure
   vector where a malicious or buggy server could force ~64 KiB
   of heap allocation per failed handshake. The codec-layer
   ceiling at 64 KiB stays in place as the RFC 8915 §4.1.4 upper
   bound for valid messages.

5. **MSRV pinned at Rust 1.87** — the actual functional floor
   (transitive `security-framework 3.7.0` requires edition2024
   plus `usize::is_multiple_of` from 1.87) is now declared in
   `rust/Cargo.toml` and matched in `rust/clippy.toml` so
   downstream consumers see an accurate `rust-version` without
   over-constraining their toolchain pin.

The `nts_rust` crate is bumped from `0.4.0` to `0.5.0` to reflect
items 3, 4, and 5 (the on-the-wire NTS-KE / NTPv4 framing is
unchanged; the crate bump tracks the Rust-side API shape change
in `KeError` and the new streaming-read budget). The Dart-facing
FRB surface gains no new public types; the surface changes are
the constructor reshape in item 1 and the new rejected-input
paths in item 2.

Internal-only improvements that ride along: `nts_warm_cookies`
now collapses concurrent forced refreshes through the same
singleflight `inflight` registry that `nts_query` already used,
the example app is reorganised across two tabs ("Client" / "Log")
with a compacted `ActionPanel` and a new single-entry
`LatestResultPanel` summary card to eliminate `RenderFlex`
overflows on landscape phones / tablets, the
`formatTrustBackend` helper renames the
`platformWithHybridFallback` rendering to `webpki-fallback` to
match the authentication mechanism, and the Trust-status panel
drops the singleton-snapshot row that was structurally destined
to remain at sentinel values during every demo run.

Seven hygiene fixes from two rounds of external code review of
the release branch land on top — six code-level fixes documented
in the `### Security` subsection below, and one docs-level fix
(README "Security considerations") in the `### Documentation`
subsection. The six code-level fixes:

1. cookie bytes zeroize on every `CookieJar` *in-jar* eviction
   path — capacity-overflow eviction in `put`, authentication-
   failure clears in `clear_host`, and a new `impl Drop for
   CookieJar` (matching the discipline already applied to AEAD
   key material). Together with item 6 below this closes both
   in-jar and post-take residual surfaces;
2. `CookieJar`'s `Debug` impl renders per-host counts only
   (matching the redacted `Debug` on `KeOutcome`);
3. `perform_handshake` verifies that the post-handshake
   negotiated ALPN matches `ntske/1` (the value
   `build_tls_config` already advertised; RFC 8915 §4 requires
   it), via a new `KeError::AlpnMismatch` variant;
4. every `.lock().expect(…)` site in `api::nts` now routes
   through a private `lock_recover` helper that recovers from
   poisoning instead of panicking, so a single panic on any
   thread holding one of the module's mutexes cannot turn into
   a permanent crash-on-use mode for the client across the FRB
   boundary;
5. `KeOutcomePartial`'s `Debug` impl renders cookies as a count
   only, mirroring the discipline already applied to
   `KeOutcome`;
6. spent cookies zeroize end-to-end through the
   `CookieJar::take` → `QueryContext.cookie` →
   `ClientRequest.cookie` → outbound packet pipeline via
   `Zeroizing<Vec<u8>>` wrapping at every intermediate holder
   — the popped cookie is *not* wiped at jar-pop time
   (`build_client_request` has not yet serialised it onto the
   wire) but does wipe on drop of the `Zeroizing` wrapper once
   the in-flight NTPv4 exchange completes. `ClientRequest` also
   gains a manual redacted `Debug` that prints the cookie field
   as `<redacted; N bytes>`.

Plus the docs-level fix (`### Documentation` subsection below):
README "Security considerations" calls out the SSRF / internal-
network-reachability surface inherent in a caller-supplied-host
network library.

All seven are internal-only — no public Dart-facing surface
change; see the `### Security` subsection below for the full
per-finding writeup.

### Changed — example app

- The home page is now split across two tabs ("Client" / "Log")
  driven by a `DefaultTabController`. The Client tab carries the
  server list, action panel, trust-status row, and a new
  single-entry "Latest result" summary card; the Log tab gives the
  live-log card a full viewport height. The previous single-Column
  layout squeezed `_LogHeader` past its intrinsic minimum on
  landscape phones / tablets and triggered `RenderFlex` overflow
  warnings; the tabbed layout removes the squeeze without changing
  any underlying widget contracts. (`nts-a3o`)
- The action panel's `TrustMode` selector is now a compact
  `DropdownButton<TrustMode>` inlined alongside the "NTS Query" and
  "Warm Cookies" buttons inside a single `Wrap`. On landscape
  viewports everything fits on one row (~64dp tall vs. the previous
  ~132dp two-row layout); on narrow phone widths the `Wrap` rolls
  the dropdown onto a second line. The set of selectable trust
  modes (`platformWithFallback`, `platformOnly`) and the
  controller-side cookie-pool-drop semantics on flip are unchanged.
  (`nts-a3o`)
- The "Favourites only" filter chip is now labelled "Favourites".
  Same behaviour, shorter text — widens the available space in the
  filter row's `Region` dropdown on narrow viewports. (`nts-a3o`)
- New `LatestResultPanel` widget on the Client tab surfaces the
  most recent `NtsLogEntry` in a single-entry summary card,
  rendered byte-for-byte identically to its sibling row on the Log
  tab via the hoisted `buildLogEntrySpans` helper. Bounded to four
  visible lines via the `maxLines` parameter on
  `SelectableText.rich`. (`nts-a3o`)

- The `formatTrustBackend` helper now renders
  `TrustBackend.platformWithHybridFallback` as `webpki-fallback`
  (was `platform+hybrid-fallback`). This is the variant where the
  platform verifier rejected the chain and the `webpki-roots`
  bundle overrode that verdict for one of the curated
  fallback-eligible shapes (missing-OCSP-AIA chains such as
  Let's Encrypt R12, R8-stripped AAR classes). The prior label
  read like "platform plus a possible hybrid fallback" without
  saying which actually authenticated. The new single-token form
  pairs naturally with the existing `webpki-roots` label for the
  end-to-end-webpki variant (per-chain override vs. end-to-end
  use) and stays safe for `awk` / `grep` pipelines against the
  `bin/nts_cli.dart` stdout, which threads the same helper. The
  underlying `TrustBackend` enum values are unchanged; only the
  human-readable label inside `example/lib/src/state/nts_format.dart`
  changed. (`nts-t3p`)

- The "Trust status" panel now surfaces only the last-handshake row.
  The "Singleton snapshot" row that read the process-wide
  `ntsTrustStatus()` and its three `defaultBackend*Count` cumulative
  counters has been removed. Those counters are gated on the
  `is_default` flag of the underlying `NtsClient` (only the top-level
  `ntsQuery` / `ntsWarmCookies` route through the default singleton);
  the example app always dispatches through a caller-minted client,
  so the row was structurally destined to remain at its sentinel
  `null` / 0 values during every demo run, which read as a bug to
  users investigating the panel. The package's public
  `ntsTrustStatus()` API is unchanged. (`nts-otu`)

- Removed (example app, internal): `NtsController.refreshTrustStatus`,
  `AppState.trustStatus`, `formatTrustStatus()` in
  `lib/src/state/nts_format.dart`, and the covering
  `group('formatTrustStatus', …)` block in `nts_format_test.dart`.
  All were dead after the singleton-snapshot row was removed.

### Changed — `NtsError` variant constructors

- **BREAKING** — the three previously single-positional `NtsError`
  variants now use named-parameter constructors:
  - `NtsError.invalidSpec(String x)` →
    `NtsError.invalidSpec(message: x)`
  - `NtsError.trustBackendUnavailable(String x)` →
    `NtsError.trustBackendUnavailable(message: x)`
  - `NtsError.internal(String x)` →
    `NtsError.internal(message: x)`

  Same shape change `3.0.0` made for the other five variants;
  applied here for surface uniformity. The pre-4.0 single-positional
  shape survives as a `@Deprecated` `field0` getter on each variant
  subclass so 2.x and 3.0.x callers that *read* the payload (in
  pattern-match destructurings or direct field reads) keep
  compiling under a deprecation warning, but all *construction*
  sites must move to the named form. `toString()` output is
  unchanged: `NtsError.invalidSpec(message)` /
  `NtsError.trustBackendUnavailable(message)` /
  `NtsError.internal(message)` render exactly as in 3.0.x.
- The five 3.0.0 named-parameter variants (`network`, `keProtocol`,
  `ntpProtocol`, `authentication`, `timeout`) are unchanged in
  4.0.0; their `field0` getters retain their existing deprecation.

### Changed — wrapper now validates integer ranges before FFI dispatch

- **BREAKING (additive)** — the four wrapper entry points (`ntsQuery`,
  `ntsWarmCookies`, `NtsClient.query`, `NtsClient.warmCookies`) now
  validate `spec.port`, `timeoutMs`, and `dnsConcurrencyCap` against
  the FFI encoding range before dispatching into the FRB layer:
  - `port`: rejected unless in `1..65535`. Mirrors the existing
    Rust-side `port must be non-zero` spec validator with a
    wrapper-authored message produced before any FFI dispatch
    rather than a Rust-authored one returned after a futile FFI
    hop.
  - `timeoutMs`: rejected unless in `1..4294967295` (i.e. the `u32`
    encoding range, with `0` no longer treated as a sentinel for
    "inherit the Rust-side default").
  - `dnsConcurrencyCap`: rejected unless in `1..4294967295` on the
    same terms.

  Out-of-range values cause the returned `Future` to complete with
  `NtsError.invalidSpec` (the four wrapper entry points are `async`,
  so the error materialises on `await` rather than as a synchronous
  throw at the call site) instead of escaping as `RangeError` from
  the FRB encoder. This closes the contract gap where the wrapper's
  `try { … } on ffi.NtsError catch { … }` previously could not catch
  encoder-side range errors, and is the change the wrapper's
  "throws an `NtsError` on every failure path" dartdoc has always
  claimed.

  Strictly additive for callers who already passed in-range values:
  no behavioural change. Callers who passed literal `0` for
  `timeoutMs` or `dnsConcurrencyCap` to ride the pre-4.0 sentinel
  now see `NtsError.invalidSpec` on `await` and must switch to the
  named constants — see the migration section below.

- **BREAKING (additive)** — `NtsClient.invalidate` now applies the
  same `port ∈ 1..65535` validation as the four async wrappers
  above. The pre-4.0 sync sister bypassed `_validateRanges` and
  forwarded `spec.port` directly into the FRB `u16` encoder, so
  out-of-range ports (negative, or `>65535`) escaped the documented
  `NtsError`-only contract as `RangeError` from the FFI bridge.
  Out-of-range ports now throw `NtsError.invalidSpec`
  *synchronously* (the call returns `bool`, so the throw site is
  the call expression itself, not an `await`). `clear()` and the
  `trustMode` getter take no spec and are unchanged. Callers who
  passed literal `port: 0` to `invalidate` to "trivially return
  false" now see `NtsError.invalidSpec` synchronously and should
  pass a real port instead — the previous behaviour was a quirk of
  the unvalidated path, not a documented contract.

### Changed — `kDefaultDnsConcurrencyCap` exposes the actual numeric default

- **BREAKING (constant-value change)** — `kDefaultDnsConcurrencyCap`
  changes from `0` (the pre-4.0 sentinel that delegated to the
  Rust-side `DEFAULT_MAX_INFLIGHT_DNS_LOOKUPS`) to `4` (the actual
  numeric value the Rust side substituted). Callers who omit the
  parameter or who reference the constant by name see no behavioural
  change — they get the same `4` they got in 3.0.x. Callers who
  embedded the literal `0` in their code (typically because they
  followed older docs that described `0` as the package default) now
  trip the new range validator above.

### Changed — `TrustMode::PlatformOnly` is now strict at the per-chain level on Android

- **BREAKING (Android-only)** — `TrustMode::PlatformOnly` /
  `TrustMode.platformOnly` now refuses *every* silent fallback to
  the `webpki-roots` static bundle, including the per-chain hybrid
  fallback that the Android `HybridVerifier` performed in 3.0.x for
  two curated failure shapes:
  - `CertificateError::Revoked` (typical when a chain like Let's
    Encrypt R12 omits the OCSP responder URL in the AIA extension —
    the platform `PKIXRevocationChecker` hard-fails such chains as
    `Revoked`).
  - `Error::General("failed to call native verifier: …")`
    (typical when R8 / ProGuard dead-code-eliminates the AAR's
    `org.rustls.platformverifier.*` glue in a release build that
    forgot the keep rules).

  In 3.0.x both arms silently retried against `webpki-roots`
  regardless of `TrustMode`, and the only signal a `PlatformOnly`
  caller had that the static bundle had been consulted was a
  post-hoc `KeOutcome::trust_backend == PlatformWithHybridFallback`
  on the resulting sample. As of 4.0.0 the `HybridVerifier` is
  constructed with the `KeTrustMode` and gates both arms on
  `PlatformWithFallback`; in `PlatformOnly` mode the platform
  verifier's error propagates verbatim and `webpki-roots` is never
  consulted.

  - **Migration**: callers who *want* the safety net should switch
    to (or stay on) `TrustMode::PlatformWithFallback` (the historic
    default for both `NtsClient::new()` and the top-level
    convenience functions), where both arms continue to fire as in
    3.0.x.
  - **Migration**: callers who already used `PlatformOnly` to enforce
    a corporate-CA / MDM-pin posture see their stated intent honoured
    in full and can drop any post-hoc `trust_backend !=
    PlatformWithHybridFallback` defensive checks they had layered
    on top of the per-sample outcome.
  - **Default `NtsClient` is unaffected**. `NtsClient::new()` is
    `PlatformWithFallback`, so the default behaviour matches 3.0.x
    and there is no opt-out behaviour change for callers who never
    constructed a `PlatformOnly` client.

  The pre-4.0 dartdoc on `TrustMode::PlatformOnly` framed the
  per-chain limitation as inherent ("`PlatformOnly` therefore means
  'no silent build-time downgrade', not 'the public-CA bundle is
  unreachable'"). The strict semantics this release ships replace
  that disclaimer with the contract Android callers actually want.

  Resolves the bd-tracked finding `nts-2lh`.

### Changed — NTS-KE streaming read budget capped at 16 KiB

- **BREAKING (Rust-side error variant)** — `KeError::MessageTooLarge`
  is replaced by `KeError::ResponseTooLarge { received, cap }`.
  The new variant surfaces the would-be post-append accumulator
  length so an operator inspecting a handshake failure can see
  how far over the streaming budget the offending read pushed the
  accumulator. The variant is internal to `KeError`; the
  `From<KeError> for NtsError` mapping already routes unmatched
  variants through `NtsError::KeProtocol { message, .. }`, so the
  new shape surfaces to Dart callers with the diagnostic preserved
  verbatim and **no change to the public Dart-facing surface**.
- **Behaviour change** — the streaming layer in
  `rust/src/nts/ke.rs::read_to_end_capped` now caps the read
  accumulator at the new `NTS_KE_READ_BUDGET = 16_384` (16 KiB)
  rather than at the 64 KiB codec ceiling. A malicious or buggy
  NTS-KE server can no longer force ~64 KiB of heap allocation
  per failed handshake; 64 KiB × N concurrent handshakes was a
  memory-pressure vector on memory-constrained mobile processes.
  Comparable Rust NTS implementations cap at 4 KiB
  (`ntpd-rs::ntp-proto::nts::messages::MAX_MESSAGE_SIZE`); the
  16 KiB pick leaves ample slack for an NTS-KE server that ships
  an unusually large but otherwise valid response (multiple
  cookies, server-name overrides) without re-exposing the
  original 64 KiB vector.
- The cap decision is factored out of the streaming read loop
  into a pure helper `next_chunk_within_budget(buf_len, n, cap)`
  so the streaming-budget guard can be exercised by unit tests
  without standing up a TLS stream. Three regression tests pin
  the change: the strict inequality between streaming budget and
  codec ceiling, the exact-fit / overshoot boundary, and a
  chunk-stride simulation that drives a 100 KB body through the
  same 4 KiB chunks the live read loop uses.
- The 64 KiB codec ceiling (`MAX_MESSAGE_BYTES` in
  `rust/src/nts/records.rs`) is unchanged — it stays in place as
  the RFC 8915 §4.1.4 upper bound for valid messages, reachable
  from non-streaming entry points like tests and file-based
  inputs.

  Resolves the bd-tracked finding `nts-dsi`.

### Changed — MSRV pinned at Rust 1.87

- **BREAKING (toolchain)** — `rust/Cargo.toml` now declares
  `rust-version = "1.87"`. The actual functional floor is set by
  the transitive `security-framework 3.7.0` (pulled in by
  `rustls-platform-verifier`, which requires edition2024) plus
  `usize::is_multiple_of` (stable in 1.87, used in `nts::ntp` and
  `nts::records` for the extension-field length validators). The
  active toolchain pin in `rust-toolchain.toml` is higher
  (currently 1.92.0); the matching `msrv` entry in
  `rust/clippy.toml` keeps clippy's msrv-aware suggestions
  accurate.
- Consumers building the crate as a Rust dependency need at
  minimum a 1.87 toolchain. Flutter consumers using the package
  via the standard build flow are unaffected because the bundled
  toolchain pin already exceeds 1.87.

### Changed — `nts_warm_cookies` collapses concurrent forced refreshes via singleflight

- **No behaviour change for the dartdoc'd contract** —
  `nts_warm_cookies` (Dart: `ntsWarmCookies`) and
  `NtsClient::warm_cookies` (Dart: `NtsClient.warmCookies`) still
  "force a fresh handshake," still return `NtsWarmCookiesOutcome
  { freshCookies, phaseTimings, trustBackend }`, and still install
  the freshly-handshaken session under the spec's `host:port` key.
  The public Rust and Dart signatures are unchanged.

- **Internal behaviour change** — the implementation now routes
  through `SessionTable::warm_cookies`, which shares the
  singleflight `inflight` registry with the cache-aware
  `SessionTable::checkout` machinery used by `nts_query`. Pre-4.0
  `nts_warm_cookies` called `establish_session` directly, so N
  concurrent `nts_warm_cookies` calls against the same `host:port`
  produced N parallel KE handshakes. As of 4.0.0:
  - N concurrent `nts_warm_cookies` against the same `host:port`
    collapse onto exactly one KE handshake. The first arrival
    becomes the singleflight leader, runs the handshake without
    holding any lock, installs its session, and publishes its
    harvested cookie count + resolved `trustBackend` on the
    singleflight slot; concurrent callers park on the same slot
    bounded by their own per-call `timeout_ms` budget and, on
    success, return those values verbatim from the slot payload
    (no cache re-read).
  - Waiters report `phaseTimings` with every field at `0` (same
    convention `nts_query` already uses for cache-hit and
    waiter-wake paths) because they did not perform KE work
    themselves. Only the leader observes its own handshake's phase
    timings.
  - `nts_warm_cookies` and `nts_query` share the singleflight key
    space, so a concurrent warm + query against the same `host:port`
    *also* collapses onto one handshake; whichever caller arrives
    first becomes the leader and the other observes its result.
  - **`freshCookies` contract pinned**: the singleflight slot now
    publishes the leader's *harvested* cookie count alongside the
    `Ok` signal, so a `nts_warm_cookies` waiter surfaces the value
    the server delivered with the KE response even when the leader
    happens to be a `nts_query` caller that pops one cookie out of
    the freshly installed jar before the warm waiter wakes.
    Previously the waiter snapshot-read `cookies_remaining()` from
    the cache and could report `delivered - 1`, contradicting the
    documented `NtsWarmCookiesOutcome.fresh_cookies` /
    `NtsTimeSample.freshCookies` dartdoc ("Number of fresh cookies
    the server delivered with the KE response").
  - Operationally relevant for UI bindings that hook
    `ntsWarmCookies` to a button: rapid taps no longer fan out to
    parallel KE handshakes, which avoids both wasted bandwidth and
    server-side per-IP rate-limit triggers (e.g. NTSN-style KoD on
    the NTPv4 leg, or per-IP throttling on the KE port).
  - Failure-fan-out semantic preserved: when the leader's handshake
    fails, every waiter receives a cloned `NtsError` with the same
    variant and payload, so waiters do not silently retry against a
    server that just rejected the leader.

### Security

Six code-level hygiene fixes raised by two rounds of external
code review of the release branch land here; the seventh review
finding (README "Security considerations" / SSRF surface
call-out) is docs-only and lives in the `### Documentation`
subsection below. None changes the public Dart-facing surface
(no `NtsError` variant added at the Dart layer; the new internal
`KeError::AlpnMismatch` flows through the existing catch-all
mapping to `NtsError.keProtocol`). All six are belt-and-braces
in the same direction the package already takes — AEAD keys
already zeroize on drop and `KeOutcome` already has a redacted
`Debug` impl; these extend the same discipline end-to-end
across cookies, add a spec-correctness guard on the TLS
handshake, and turn the Rust API layer's `.lock().expect(…)`
sites into recoverable operations so a single panic can no
longer permanently crash an `NtsClient` across the FRB boundary.

- **Cookie bytes are now zeroized on every *in-jar* eviction
  path.** The per-host FIFO store in `rust/src/nts/cookies.rs`
  previously held cookies as plain `Vec<u8>` and dropped them
  with `pop_front` / `VecDeque::clear` on overflow eviction,
  `clear_host`, and `Drop`. None of those paths wiped the
  backing allocation, so a process-memory scrape after eviction
  could in principle recover the cookie bytes. Cookies are NTS
  authentication material (RFC 8915 §6: "use at most once" /
  "keep at most 8 unused per server"), so the discipline
  already applied to AEAD key material in
  `rust/src/nts/aead.rs` (via `ZeroizeOnDrop`) now extends to
  the cookie store: capacity-overflow eviction in
  `CookieJar::put`, authentication-failure clears in
  `CookieJar::clear_host`, and a new `impl Drop for CookieJar`
  all call `Vec::zeroize` before the backing allocation is
  released. The `take` path is *not* wiped at jar-pop time —
  that path hands the cookie to the in-flight NTPv4 exchange
  that has yet to spend it, so wiping at the pop site would
  defeat the consumer. The complementary fix below in the
  end-to-end-cookie-zeroize entry extends the discipline
  across the take path itself: the popped cookie now rides
  inside a `Zeroizing<Vec<u8>>` wrapper from the jar boundary
  to the wire and wipes on drop once `build_client_request`
  has serialised the bytes into the outbound packet, so both
  the in-jar and post-take paths are covered.

- **`CookieJar`'s `Debug` impl no longer prints cookie bytes.**
  The struct's previous `#[derive(Debug, Clone)]` rendered the
  full per-host `Vec<Vec<u8>>` on any `{:?}` formatting site.
  Cookies are authentication material; an accidental panic
  backtrace, log macro, or diagnostic format could leak them.
  `Debug` is now hand-rolled to print per-host *counts only*,
  mirroring the redacted `Debug` already applied to `KeOutcome`.
  Internal change; no public-API impact.

- **NTS-KE now verifies the negotiated TLS ALPN matches
  `ntske/1`.** `build_tls_config` already advertised
  `alpn_protocols = [b"ntske/1"]` per RFC 8915 §4, but
  `perform_handshake` did not call `ClientConnection::alpn_protocol()`
  after the handshake completed. A TLS 1.3 server that completed
  the handshake without honouring our ALPN selection (either
  omitting the ALPN extension entirely or selecting a different
  protocol) would have its payload flow into `read_to_end_capped`
  and surface as a less-specific NTS-KE record-parse error.
  After this release, the post-handshake guard explicitly checks
  `alpn_protocol() == Some(b"ntske/1")` and returns a new
  `KeError::AlpnMismatch { negotiated: Option<Vec<u8>> }`
  otherwise (distinct from `rustls::Error::NoApplicationProtocol`,
  which fires *during* the handshake when ALPN is mutually
  required by the server). The new variant surfaces to Dart via
  the catch-all `From<KeError> for NtsError` mapping as
  `NtsError.keProtocol`; no Dart-side surface change. Three
  regression tests pin the helper at the variant level (accept
  `Some(b"ntske/1")`, reject `None`, reject `Some(b"h2")`,
  preserve `Some(empty)` as distinct from `None`).

- **`api::nts` mutex sites now recover from poisoning instead of
  panicking.** Every `Mutex::lock` call in `rust/src/api/nts.rs`
  (the `SessionTable.map` and `SessionTable.inflight` caches,
  and the per-key `HandshakeSlot.result` singleflight slot) used
  to call `.expect("…")` on the returned `LockResult`. If any
  thread panicked while holding one of those locks the mutex
  became poisoned and every subsequent FRB-boundary call from
  any thread would deterministically panic too — turning one
  recoverable failure into a permanent "this `NtsClient` is dead
  forever" mode across the Dart bridge. A new private
  `lock_recover(&mutex)` helper returns the inner guard via
  `PoisonError::into_inner` regardless of the poison flag, and
  every `.lock().expect(…)` site has been swept to use it. The
  caches and singleflight registry are tolerant of mid-update
  panics by construction (caches: at worst a stale entry that
  the next eviction reaps; singleflight: `LeaderGuard::drop`
  already publishes an `Internal` error to waiters on the
  leader-aborted path), so unpoisoned access is safe. Two
  regression tests pin the recovery semantics: one asserts a
  poisoned-then-recovered mutex returns the inner value, and
  one asserts mutations through `lock_recover` survive across
  recovery while plain `Mutex::lock` still reports the poison
  flag (recovery is opt-in per call site, not a global unpoison).

- **`KeOutcomePartial`'s `Debug` impl no longer prints cookie
  bytes.** The internal partial-outcome struct returned by
  `validate_response` previously had `#[derive(Debug)]` over a
  `cookies: Vec<Vec<u8>>` field. Although `pub(crate)` so the
  type does not surface beyond this crate, any `{:?}` site
  reached during a refactor (panic backtrace, `dbg!`, internal
  error-formatting chain that ever touches the partial outcome)
  would leak the cookies the post-handshake `KeOutcome` already
  redacts. `Debug` is now hand-rolled to render `cookies` as
  `<redacted; N cookies>` — same shape as the `KeOutcome`
  manual impl. A regression test mirrors the existing
  `ke_outcome_debug_redacts_exporter_keys_and_cookies` shape,
  pinning the marker count and the absence of cookie byte
  tokens in the rendered output.

- **Spent cookies are now zeroized end-to-end through the
  `CookieJar` → outbound packet pipeline.** The 4.0.0 first
  security pass added zeroization to the `CookieJar` eviction
  paths (`put` overflow, `clear_host`, `Drop`), but the "happy
  path" `take` returned a plain `Vec<u8>` that then moved
  through `QueryContext.cookie: Vec<u8>` → `ClientRequest.cookie:
  Vec<u8>` → `build_client_request` → outbound packet, with no
  intermediate allocation wiped after the packet was built and
  sent. `CookieJar::take` now returns `Option<Zeroizing<Vec<u8>>>`
  so the spent bytes ride inside the same `Zeroizing` wrapper
  from the jar boundary all the way to the wire; `QueryContext.cookie`
  and `ClientRequest.cookie` were both retyped to
  `Zeroizing<Vec<u8>>` (same shape as `KeOutcome.c2s_key` /
  `s2c_key` already use), so each intermediate holder wipes the
  cookie bytes on `Drop`. `ClientRequest` additionally drops its
  `#[derive(Debug, Clone)]` for a manual `Debug` impl that
  redacts the cookie field as `<redacted; N bytes>` — closing
  the cookie-Debug-leak path one step further along the
  pipeline. Two regression tests pin the change: a compile-time
  `assert_zeroizing_vec` helper accepts only
  `&Zeroizing<Vec<u8>>` on `QueryContext.cookie` and
  `ClientRequest.cookie`, and a runtime test asserts
  `format!("{req:?}")` does not surface cookie byte tokens for a
  sentinel-payloaded `ClientRequest`.

### Documentation

- README's "API summary" table now includes:
  - The `trustBackend` field on `NtsTimeSample` and
    `NtsWarmCookiesOutcome` (added in 3.0.0 but missing from the
    table).
  - The `trustBackendUnavailable` variant on `NtsError` (likewise).
  - A row for `ntsTrustStatus()` and a row for the `NtsTrustStatus`
    DTO it returns (the entire trust-diagnostic surface was absent
    from the table).
- The dartdoc on `kDefaultTimeoutMs` and `kDefaultDnsConcurrencyCap`
  no longer points at `0` as a way to inherit the Rust-side default.
  The two constants now state their actual numeric values (5000 and
  4) and the operational rationale for each.
- The dartdoc on the synchronous diagnostics `ntsDnsPoolStats()` and
  `ntsTrustStatus()` now states the `RustLib.init()` precondition
  explicitly. Both calls dispatch through the FRB v2 dispatch table
  even though they return synchronously, so a missed initialization
  fails with a low-level FRB error rather than a structured
  `NtsError`. The note is crosslinked to README's "Initialization
  has two layers" section so the Android JNI bootstrap context is
  one click away.
- The same `RustLib.init()` precondition note now also lives on the
  three `NtsClient` synchronous methods that share the same FRB
  dispatch path (`NtsClient.invalidate`, `NtsClient.clear`, and the
  `NtsClient.trustMode` getter). Closes the residual scope of the
  earlier sweep, which had only touched the two top-level
  diagnostics functions.
- README's "API summary" table gains rows for the two trust-related
  enums (`TrustMode` and `TrustBackend`) that the prior table sweep
  scoped out. Consumers reading the table can now resolve the
  `trustBackend` field on `NtsTimeSample` / `NtsWarmCookiesOutcome`
  and the `defaultClientBackend` field on `NtsTrustStatus` to a
  concrete enum without leaving the README.
- New `## Security considerations` section in `README.md` between
  `Production Considerations` and the `API summary`. Documents the
  inherent SSRF surface a "take a caller-supplied hostname, do
  DNS / TCP / UDP against it" library carries — the package
  cannot constrain *which* hosts a caller is allowed to reach,
  so call sites that accept hostnames from untrusted input must
  apply allowlists / private-range rejection / port gating
  themselves. Cross-links the bounded DNS pool to make the
  "amplification is bounded, destination is not" distinction
  explicit. Surfaces a recommendation raised by an external
  code review of the release branch.
- Android `PlatformInit.kt` log messages and KDoc no longer claim
  unconditional fallback to `webpki-roots` when `System.loadLibrary`
  or `nativeInit` fails. With the 4.0.0 strict per-chain
  `TrustMode.platformOnly` semantics in place, that fallback only
  applies to `TrustMode.platformWithFallback` callers; `platformOnly`
  callers see the same failure surface as
  `NtsError.trustBackendUnavailable` at handshake time. The
  `UnsatisfiedLinkError` log, the `nativeInit`-returned-false log,
  and the `init` KDoc all now name both branches. Surfaces a
  platform-glue review observation against the release branch.
- iOS `os_log` subsystem renamed from `com.nts.example` to
  `com.nllewellyn.nts`. The previous string read as a placeholder
  that escaped from an early draft and its docstring falsely
  claimed it tracked the host application's reverse-DNS bundle
  convention. The new identifier is library-owned (a stable handle
  consumers can pin Console.app filters against across `nts`
  versions) and matches the Android plugin package
  (`com.nllewellyn.nts.PlatformInit`) so the same filter string
  works on both platforms. Updated sites: `rust/src/ios_init.rs`
  (`SUBSYSTEM` constant + module-level docstring),
  `rust/src/api/simple.rs` (`init_app` docstring),
  `rust/Cargo.toml` (Console.app filter comment),
  `example/pubspec.yaml` (verbose-logs guidance comment), and
  `DEVELOPMENT.md` (verbose-logs section). Hosts that had pinned
  a Console.app filter against the previous string need to update
  it to `com.nllewellyn.nts`; this is the only externally visible
  consequence and is documented here so users investigating a
  silent filter break after the 4.0.0 upgrade find it.
- README's `## Security considerations` section gains a
  `### Non-Flutter Dart callers must pass externalLibrary
  explicitly` subsection. Documents the relative-`ioDirectory`
  library-hijack surface in
  `RustLib.kDefaultExternalLibraryLoaderConfig`
  (`ioDirectory: 'rust/target/release/'`): inside a Flutter host
  the Native Assets pipeline supplies a controlled absolute load
  path before that default ever runs, but a non-Flutter Dart
  caller (`dart run` CLI, Dart server runtime, integration-test
  harness) that calls `RustLib.init()` without an `externalLibrary`
  argument while running from an attacker-influenced working
  directory will load whatever `rust/target/release/libnts_rust.*`
  has been planted there. The bundled
  `example/bin/nts_cli.dart` already follows the recommended
  pattern (auto-locate to an absolute path, then
  `ExternalLibrary.open(resolved)`) and the new subsection
  cross-references it. The hijack is independent of NTS itself —
  `RustLib.init()` resolves before any TLS / NTS code runs — but
  the package is the vehicle, so the documentation surface is the
  appropriate mitigation layer. Surfaces a platform-glue review
  observation against the release branch.

### Migration from 3.0.x

#### Move positional construction calls to the named form

Three constructors changed shape; the migration is one named
parameter per call site:

```dart
// 3.0.x
const NtsError.invalidSpec('host is empty')
const NtsError.trustBackendUnavailable('platform CA bundle missing')
const NtsError.internal('unreachable')

// 4.0.0
const NtsError.invalidSpec(message: 'host is empty')
const NtsError.trustBackendUnavailable(message: 'platform CA bundle missing')
const NtsError.internal(message: 'unreachable')
```

The analyzer reports a "missing required argument" plus an
"extra positional argument" diagnostic pair at every old-shape
call site, so the diff is mechanical and each affected line is
flagged exactly.

#### Rename payload binders in pattern destructurings

If your code pattern-matches with `:final field0`, switch to
`:final message` to follow the descriptive name. The old binder
keeps working because `field0` survives as a `@Deprecated` getter
alias, so this is optional, not required:

```dart
// Both compile in 4.0.0; the new form drops the deprecation
// warning and matches the binder name used by every other
// `String`-payloaded variant in the same switch.
final detail = switch (err) {
  // ... existing arms unchanged ...
  NtsErrorInvalidSpec(:final message) => 'invalid spec: $message',
  NtsErrorTrustBackendUnavailable(:final message) =>
      'trust backend unavailable: $message',
  NtsErrorInternal(:final message) => 'internal: $message',
};
```

#### Replace literal `0` for `timeoutMs` / `dnsConcurrencyCap`

The wrapper now rejects literal `0` for either `u32` argument with
`NtsError.invalidSpec`. The migration is one of two equivalent
moves per call site, depending on whether you care about explicit
documentation of intent:

```dart
// 3.0.x
await ntsQuery(
  spec: spec,
  timeoutMs: 0,            // deprecated sentinel: "use the package default"
  dnsConcurrencyCap: 0,    // same
);

// 4.0.0 — option A: omit, inherit the constant default
await ntsQuery(spec: spec);

// 4.0.0 — option B: name the constant explicitly
await ntsQuery(
  spec: spec,
  timeoutMs: kDefaultTimeoutMs,
  dnsConcurrencyCap: kDefaultDnsConcurrencyCap,
);
```

The two new constants resolve to `5000` and `4` respectively; both
match the values the Rust side previously substituted when it saw
`0`, so neither option changes runtime behaviour — only the visible
failure mode for code that *meant* something else by `0`.

### Out of scope

- The deprecated `NtsError_*` underscore-prefixed typedefs (e.g.
  `NtsError_InvalidSpec`) and the `@Deprecated` `field0` getter
  aliases on every variant survive into 4.0.0. They remain the
  read-side back-compat for 2.x / 3.0.x callers and were
  originally slated for removal in this same 4.0.0 sweep, but
  the named-constructor migration (item 1 in the framing above),
  the strict-`PlatformOnly` behaviour change (item 3), and the
  16 KiB streaming budget (item 4) are already the load-bearing
  breaking changes for this release. Folding the typedef +
  getter removal in would not change the migration surface for
  any caller who hadn't already updated for those items, so the
  cleanup defers to a follow-up release. The existing
  deprecation warnings stay in place.

## 3.0.0

The first release after `2.0.0` consolidates four chunks of work
that landed on `main` between the 2.x line and the 3.0 cut:

1. **Trust-anchor backend diagnostics + strict `platformOnly` mode**
   — every `ntsQuery` / `ntsWarmCookies` result now reports which
   trust-anchor backend authenticated its TLS chain, and callers
   can opt into refusing the silent downgrade from the platform
   store to the static `webpki-roots` bundle.
2. **Per-host singleflight on the cache-layer checkout path** —
   concurrent cold queries against the same `host:port` collapse
   onto a single in-flight NTS-KE handshake instead of each
   running their own duplicate one. Internal to `SessionTable`;
   no API change.
3. **Owned `NtsClient` session handle** — an explicit, owned
   client whose per-host session table can be scoped to a caller,
   cleared on demand, and isolated from other callers. The
   top-level `ntsQuery` / `ntsWarmCookies` continue to delegate
   to a process-wide default `NtsClient`, so existing
   single-cache callers see no change.
4. **Hand-written public DTOs and sealed `NtsError`** — the
   public surface is no longer a re-export of the FRB-generated
   bindings. A Rust-side struct rename or reorder is no longer
   a SemVer event for any of the public DTO types.

This is a **major version bump** because chunks 1 and 4 each
break the public Dart API: chunk 4 renames the `NtsError_*`
variant subclasses from the underscore-prefixed freezed convention
to idiomatic PascalCase (with deprecated typedef aliases for the
old names) and re-types the microsecond fields from `PlatformInt64`
to plain Dart `int`; chunk 1 adds an `NtsErrorTrustBackendUnavailable`
variant to the sealed `NtsError` class which breaks exhaustiveness
for Dart 3 `switch` consumers. Chunks 2 and 3 are purely additive
on their own.

The Rust crate (`nts_rust`) version is at `0.4.0`, unchanged
across these chunks; the on-the-wire NTS-KE / NTPv4 framing was
not modified by any of them. The Dart-facing FRB surface *did*
grow new types and fields (`TrustMode`, `TrustBackend`,
`NtsTrustStatus`, `ntsTrustStatus()`, and a `trustBackend` field
on `NtsTimeSample` / `NtsWarmCookiesOutcome`) — those additions
are the source of the major bump, not a network-protocol change.

### Migration from 2.0.0

#### Rename pre-3.0 freezed-style variant subclasses

Drop the underscore from `NtsError_*` variant subclasses in
`switch` arms and `is` checks: `NtsError_InvalidSpec` →
`NtsErrorInvalidSpec`, etc. The factory-constructor syntax
(`const NtsError.invalidSpec('x')`, `const NtsError.timeout(TimeoutPhase.ntp)`,
…) is unchanged. Deprecated typedef aliases let the old names
keep compiling with a deprecation warning until the next major
bump removes them, so the migration can be done at the
consumer's pace anywhere across the 3.x line.

#### Drop `.toInt()` and `PlatformInt64Util.from(...)` in DTO sites

Microsecond fields on `NtsTimeSample` (`utcUnixMicros`,
`roundTripMicros`) and `PhaseTimings` (`dnsMicros`, …,
`keRecordIoMicros`) are now plain `int` rather than FRB's
`PlatformInt64`. Drop `.toInt()` calls on field reads and replace
`PlatformInt64Util.from(N)` with `N` in test fixtures and mocks
that build these types directly.

#### Add an arm for the new sealed-class variant

Any exhaustive `switch (err) { … }` over an `NtsError` value must
add an arm for the new `NtsErrorTrustBackendUnavailable` variant:

```dart
// As written for 3.0.x; the `field0` getters were removed in 6.0.0
// in favour of the named `message` / `phase` fields.
final detail = switch (err) {
  // ... existing arms unchanged ...
  NtsErrorNoCookies() => 'no cookies returned',
  NtsErrorTrustBackendUnavailable(:final field0) =>
      'trust backend unavailable: $field0',
  NtsErrorInternal(:final field0) => 'internal: $field0',
};
```

Callers that only catch `NtsError` (or `Exception`) and do not
destructure variants need no changes. Default-singleton callers
of `ntsQuery` / `ntsWarmCookies` continue to get the pre-3.0
hybrid trust-anchor behaviour (platform verifier first,
`webpki-roots` fallback on construction failure) and will never
see the new variant; it is reachable only when a custom
`NtsClient` is constructed with `trustMode: TrustMode.platformOnly`.

#### Switch any `on FrbException` clauses to `on NtsError`

`NtsError` now implements Dart's marker `Exception` interface
instead of FRB's internal `FrbException`. Catching with
`try { ... } on NtsError catch (err)` is unchanged; catching with
`try { ... } on FrbException catch (err)` no longer binds an
`NtsError` and will need to switch to the `NtsError` clause.

#### Drop FFI re-exports from `package:nts/nts.dart`

The FFI DTOs, functions, and `NtsError` family are no longer
re-exported from `package:nts/nts.dart`. The bridge bootstrap
(`RustLib`) remains re-exported because callers still need it
to call `await RustLib.init()` (and `RustLib.initMock` in tests);
that one symbol is the intentional exception, scoped to the
bootstrap. Code that imported other FFI types or functions
through the public barrel must either move to the public surface
(`package:nts/nts.dart`) or, for internal-mock use cases that
build `RustLibApi` instances, import from `package:nts/src/ffi/...`
directly with the existing `// ignore_for_file: implementation_imports`
pattern. The example's `MockNtsApi` (`example/lib/src/mock_api.dart`)
shows the intended shape.

### Added — public DTOs and sealed `NtsError`

- All public DTOs (`NtsServerSpec`, `NtsTimeSample`,
  `NtsWarmCookiesOutcome`, `NtsDnsPoolStats`, `PhaseTimings`) are now
  hand-written in `lib/src/api/models.dart`. Microsecond fields are
  typed as plain `int` rather than `PlatformInt64`.
- `NtsError` is a Dart 3 `sealed class` hand-written in
  `lib/src/api/errors.dart` instead of the FRB-generated freezed
  sealed class. Variant subclasses use idiomatic Dart PascalCase
  (`NtsErrorInvalidSpec` etc.). Pre-3.0 `NtsError_*` names survive
  as `@Deprecated` typedef aliases and will be removed at the next
  major bump.
- `lib/src/api/nts.dart` wraps every FFI call in a try/catch that
  converts the FFI `NtsError` to the public variant. Conversions
  are exhaustive `switch` expressions; a future Rust-side variant
  addition surfaces as a compile error in the conversion layer
  rather than as a silently-dropped variant at the consumer.

### Added — `NtsClient` handle

- `NtsClient` in `lib/src/api/nts.dart`. Construct with `NtsClient()`
  to mint a fresh client whose session table starts empty and never
  shares state with another `NtsClient` or with the process-wide
  default. The handle exposes:
  - `Future<NtsTimeSample> query({...})` — per-client equivalent of
    the top-level `ntsQuery`.
  - `Future<NtsWarmCookiesOutcome> warmCookies({...})` — per-client
    equivalent of the top-level `ntsWarmCookies`.
  - `bool invalidate(NtsServerSpec spec)` — drops the cached session
    for `spec`'s `host:port`, returns `true` if an entry was removed.
    Synchronous; backed by one mutex acquisition + `HashMap::remove`
    on the Rust side.
  - `void clear()` — drops every cached session in this client's
    table. Synchronous.
- Rust: `pub struct NtsClient` in `rust/src/api/nts.rs` with the same
  five operations (`new`, `query`, `warm_cookies`, `invalidate`,
  `clear`). Rust callers can construct an explicit `NtsClient` for
  the same reasons; the existing top-level `nts_query` and
  `nts_warm_cookies` free functions delegate to a process-wide
  default `NtsClient` via `default_nts_client()`.
- The Rust per-host cache layer is now an instance of a private
  `SessionTable` struct (was a free `sessions()` accessor over a
  `OnceLock<Mutex<HashMap<…>>>`). `nts_query` and `nts_warm_cookies`
  share their bodies with `NtsClient::query` and
  `NtsClient::warm_cookies` through internal `*_inner` helpers
  parameterised on `&SessionTable`, so the per-instance and
  process-wide-default code paths are bit-identical except for
  which table the cookies and keys live in.
- When to construct an explicit `NtsClient`: test isolation (so one
  test's cached sessions cannot bleed into another's); diagnostics
  tools that want to force a fresh NTS-KE handshake on demand
  without restarting the process; apps that want a clear scope-bounded
  lifetime for cached sessions, e.g. discarding the cache between
  work batches. If your app already uses one steady set of NTS
  servers and you have no need for the lifecycle methods, keep
  calling the top-level `ntsQuery` / `ntsWarmCookies` — the
  singleton convenience is the recommended default.

### Added — per-host singleflight

- Per-key singleflight in `SessionTable::checkout` (Rust internal):
  - The first concurrent checkout against a given `host:port`
    becomes the *leader* and runs `establish_session` without
    holding any lock.
  - Concurrent checkouts against the same key become *waiters*: they
    park on a per-key slot until the leader publishes a result,
    bounded by their own per-call `timeoutMs` budget so a slow
    leader cannot stretch a follower's wall-clock past its caller's
    budget.
  - On leader success the waiters re-take the cookie jar of the
    freshly installed session; if more waiters wake than the new
    pool has cookies, the extras simply re-enter the role-election
    loop and elect a new leader for the next handshake. Each
    successful handshake delivers ~8 cookies (RFC 8915 default), so
    the loop converges in `ceil(waiters / pool_size)` handshake
    rounds in the worst case, never spinning indefinitely.
  - On leader failure each waiter receives a *cloned* `NtsError`
    matching the leader's variant and payload — waiters do not
    silently retry (which would amplify load against a server that
    just rejected the leader's handshake) and do not see
    `NtsError::Internal` (which would mask the real failure shape).
  - Leader-path RAII cleanup (`LeaderGuard`) ensures the inflight
    slot is removed even when the leader panics or returns early
    without explicit completion; in that case waiters unpark on a
    sentinel `NtsError::Internal` rather than blocking against the
    stale slot until their per-call deadline elapses.
- The visible-from-Dart effect is faster cold-start and lower
  rate-limit pressure on the upstream server when a UI fires
  several queries against the same time source in parallel.
- Per-call timing semantics are unchanged: the leader reports its
  own KE phase timings; waiters report zero phase timings (same
  as cache hits — "no handshake ran in this thread"), matching the
  existing convention.
- The singleflight is keyed by `session_key(spec)` (i.e.
  `host:port`), so concurrent queries against *different* hosts
  continue to run their handshakes fully in parallel.
- The singleflight registry lives on `SessionTable`, so two
  `NtsClient` instances never collide with each other's
  leader-election state, and the process-wide default client's
  singleflight is independent of any bespoke `NtsClient` a caller
  mints.
- `nts_warm_cookies` does *not* participate in the singleflight.
  It always runs its own `establish_session`, matching its
  documented "force a fresh handshake" contract — a manual refresh
  gesture should not be silently coalesced with an unrelated
  `ntsQuery`'s handshake.

### Added — trust-anchor diagnostics + strict mode

- `TrustMode` enum on the public DTO surface (in `lib/src/api/models.dart`):
  - `TrustMode.platformWithFallback` — the pre-3.0 default behaviour:
    platform verifier first, `webpki-roots` static-bundle fallback if
    `build_with_native_verifier` fails at TLS-config construction time.
  - `TrustMode.platformOnly` — strict mode: refuse the fallback and
    surface `NtsError.trustBackendUnavailable(diagnostic)` if the
    platform verifier cannot be constructed. Use when a pinned
    corporate CA or MDM-installed root is the load-bearing trust
    anchor and a silent downgrade to the static bundle would defeat
    the deployment's TLS-inspection posture.
- `TrustBackend` enum on the public DTO surface:
  - `TrustBackend.platform` — `rustls-platform-verifier` validated
    the chain against the OS trust store (system + user/MDM roots).
  - `TrustBackend.platformWithHybridFallback` — Android-only: the
    hybrid verifier overrode a platform-side failure with the
    `webpki-roots` bundle for one of the curated fallback-eligible
    failure shapes (e.g. missing-OCSP-AIA chains such as Let's
    Encrypt R12, R8-stripped AAR classes).
  - `TrustBackend.webpkiRoots` — `build_with_native_verifier` failed
    at TLS-config construction time and the static `webpki-roots`
    bundle authenticated the chain end-to-end.
- `NtsTimeSample.trustBackend` and `NtsWarmCookiesOutcome.trustBackend`
  fields. Per-handshake attribution carried on every successful
  result. On the steady-state cached-session `ntsQuery` path
  (no fresh KE handshake) the value reflects the *original*
  handshake's resolution, cached on the underlying session, so
  callers always see a concrete attribution rather than a
  placeholder for cached queries.
- `NtsClient` constructor now accepts an optional
  `trustMode: TrustMode` named parameter; defaults to
  `TrustMode.platformWithFallback` so existing call sites are
  source-compatible. The choice is immutable for the life of the
  client. Read it back via the new `NtsClient.trustMode` getter
  (synchronous; backed by a one-byte read on the Rust side).
- Top-level `ntsTrustStatus()` function returning an
  `NtsTrustStatus` snapshot. Synchronous (no future / isolate hop):
  backed by three atomic-relaxed loads, cheap enough to call from
  a UI poll loop or a pre-flight "can I even validate against the
  platform store?" check. The snapshot exposes:
  - `defaultClientBackend: TrustBackend?` — backend the *default
    singleton* `NtsClient` (used by `ntsQuery` / `ntsWarmCookies`)
    most recently resolved to. `null` when no handshake has yet run
    against the singleton in this process. Custom-client callers
    should read `NtsTimeSample.trustBackend` /
    `NtsWarmCookiesOutcome.trustBackend` for accurate per-client
    attribution.
  - `androidPlatformInitSucceeded: bool` — `true` iff the Android
    JNI bootstrap (`PlatformInit.nativeInit`) reported success at
    least once. `false` on every other platform (no JNI bootstrap
    step exists). A `false` value on Android implies subsequent
    handshakes will be running against `webpki-roots` regardless
    of the caller's `TrustMode`.
  - `androidHybridFallbackCount: BigInt` — cumulative count of TLS
    chains the Android hybrid verifier has accepted via the
    `webpki-roots` fallback path since process start. Always zero
    on non-Android platforms.
- `NtsError.trustBackendUnavailable(String diagnostic)` variant
  (sealed class member: `NtsErrorTrustBackendUnavailable`). Surfaces
  only on the strict-mode `TrustMode.platformOnly` path; the
  payload carries the underlying `build_with_native_verifier`
  construction-failure diagnostic.
- Per-handshake `trustBackend: TrustBackend?` attribution is now
  carried on every error variant whose precondition is "the TLS
  handshake reached `build_tls_config` time": `NtsError.network`,
  `NtsError.keProtocol`, `NtsError.ntpProtocol`,
  `NtsError.authentication`, `NtsError.timeout`, and
  `NtsError.noCookies`. Populated whenever the failure fired after
  the backend was resolved — which, given that `perform_handshake`
  calls `build_tls_config` before any DNS, connect, or TLS I/O
  begins, covers every current failure site: KE-leg
  `dnsSaturation` / `dnsTimeout` / pre-bind `connect` / `tls` /
  `keRecordIo` failures (all attributed via the per-call
  `attribute` closure in `perform_handshake`), every
  post-checkout UDP leg's bind / send / recv / recv-arm failure,
  the cache-hit `NoCookies` short-circuits, and Android's
  per-instance `HybridVerifier` upgrade to
  `TrustBackend.platformWithHybridFallback` when the fallback
  counter incremented during the TLS write/flush window. The
  field is typed as nullable because the Rust `KeFailure` wrapper
  attaches `None` for failures that fire before `build_tls_config`
  returns `Ok`, but no current `perform_handshake` path produces
  such a failure on the variants listed above. Variants whose
  precondition rules out a backend (`invalidSpec`,
  `trustBackendUnavailable`, `internal`) do not carry the field
  at all. Closes the diagnostic gap where a server-side
  post-handshake failure (e.g. an NTS-KE record parse error
  against an Android hybrid-fallback chain) lost the fallback
  attribution and exported as `[backend=null]`.

### Changed — trust-anchor diagnostics + strict mode

- The `webpki-roots` static-bundle fallback inside `build_tls_config`
  is now gated by the caller's `TrustMode`. Pre-3.0 it always ran
  on platform-verifier construction failure; in 3.0+ it runs only
  when the client was constructed with `TrustMode.platformWithFallback`
  (the default), and is replaced by an `NtsError.trustBackendUnavailable`
  return when the client was constructed with `TrustMode.platformOnly`.
- The Android `HybridVerifier` now reports back to the per-handshake
  trust-state tracker on every `webpki-roots` fallback decision so
  the per-query `trustBackend` field can distinguish
  `TrustBackend.platform` from `TrustBackend.platformWithHybridFallback`.
  No behavioural change to the verification logic itself.
- The Android JNI bootstrap (`Java_com_nllewellyn_nts_PlatformInit_nativeInit`)
  now latches a process-global "platform init succeeded" flag on
  every successful `rustls_platform_verifier::android::init_with_env`
  call. Used by `ntsTrustStatus()` to report
  `androidPlatformInitSucceeded`; idempotent (the flag only ever
  flips false → true).
- **BREAKING** — sealed `NtsError` variants whose payload grew the
  `trustBackend` field (`network`, `keProtocol`, `ntpProtocol`,
  `authentication`, `timeout`, `noCookies`) now use named-parameter
  constructors (`NtsError.network(message: ..., trustBackend: ...)`
  rather than `NtsError.network(...)`). The pre-3.0 single positional
  payload survives as a `@Deprecated` `field0` getter on each
  variant subclass so 2.x consumers keep compiling under a
  deprecation warning, but all *construction* sites must move to
  the named form. `toString()` preserves the pre-3.0 format
  (`NtsError.network(message)`) when `trustBackend` is `null` and
  appends `, backend: <name>` otherwise, so existing equality /
  string assertions for backend-less variants do not need to
  change. `invalidSpec`, `trustBackendUnavailable`, and `internal`
  retain their pre-3.0 single-positional shape (no behavioural
  change there).

### Added — wrapper observability instrumentation

Three operator-facing `log::info!` emit sites at NTS protocol
milestones, wired through the existing `log` → `tracing` →
`tracing-oslog` (iOS) / `android_logger` (Android) pipeline so
they reach Console.app (iOS) and `logcat` (Android) without
further consumer wiring:

- `nts::ke` target — fires once per successful NTS-KE handshake
  with `host`, `aead_id`, `cookies`, `ntp_host`, `ntp_port`, and
  `trust_backend`. `ntp_host` / `ntp_port` are emitted as
  separate `key=value` pairs rather than `host:port` so an IPv6
  literal in the NTPv4 server address does not mangle the
  address-vs-port boundary for log scrapers.
- `nts::query` target — fires once per successful `ntsQuery`
  call with `host`, `stratum`, `aead_id`, `fresh_cookies`,
  `rtt_us`, and `trust_backend`.
- `nts::warm` target — fires once per successful
  `ntsWarmCookies` call with `host`, `cookies_in_jar`, and
  `trust_backend`.

All three are stripped at compile time in release builds via the
default-on `log-strip` Cargo feature
(`log/release_max_level_warn`), so they cost zero string-table
bytes and zero runtime overhead in production. To enable them
during local on-device verification, flip
`hooks.user_defines.nts.verbose_logs` to `true` in
`example/pubspec.yaml` and rebuild after a `flutter clean` (see
the `pubspec.yaml` comment block for the exact procedure).

### Changed — Authentication / KeProtocol routing documentation

Documents the cross-variant routing that was previously only
captured on the example app's `describeError` helper:
AEAD-algorithm *negotiation* failures during NTS-KE — a server
picking an AEAD identifier this client does not implement —
surface as `NtsError.keProtocol`, not `NtsError.authentication`.
The `Authentication` variant is reserved for
cryptographic-verification failures of the AEAD primitive itself
on a fully negotiated algorithm (tag mismatch, malformed AEAD
input). A monitoring rule wired to "tag mismatch" alarms must
therefore key on `Authentication` only.

The routing note now lives on three sources of truth:

- `NtsError.authentication` factory dartdoc in
  `lib/src/api/errors.dart`.
- `NtsError::Authentication` rustdoc in `rust/src/api/nts.rs`
  (mirrors into the FFI binding `lib/src/ffi/api/nts.dart` via
  codegen).
- The pre-existing `describeError` dartdoc in
  `example/lib/src/state/nts_format.dart` is corrected to name
  the actual primary route
  (`KeError::UnsupportedAead` → `From<KeError> for NtsError`
  catch-all) plus the defence-in-depth path
  (`AeadError::UnsupportedAlgorithm` → explicit arm of
  `From<AeadError> for NtsError`); the previous prose cited a
  non-existent `From<AeadError> for KeError` impl.

No code-path or behaviour change; `Authentication` and
`KeProtocol` continue to route exactly as they did in 2.0.0. The
fix is purely documentary, scoped to the three doc surfaces
above.

### Out of scope

- `nts_warm_cookies` does *not* participate in the singleflight in
  this release. A concurrent `nts_warm_cookies` + `ntsQuery` against
  the same host therefore still races the install (same race as
  pre-3.0; the singleflight does not make it worse). If real call
  patterns surface a need to coalesce warm-cookies traffic, a
  follow-up can extend the singleflight to span both flows.
- Cache-eviction policy (LRU / max-size / TTL) and per-host
  singleflight metrics remain follow-ups under their own tickets.
- The strict trust mode does not implement certificate or public-key
  pinning; it only refuses the `webpki-roots` downgrade. Callers
  who want to pin a specific root or leaf should layer that check
  on top of the platform-verifier path themselves (no public hook
  for it exists in 3.0).
- The per-handshake `trustBackend` field is reported on the public
  DTOs but not yet on the JSON output of the example CLI's `--json`
  mode. A follow-up can add it once the JSON contract is reviewed.
- `NtsError.trustBackendUnavailable` is reachable only via
  `TrustMode.platformOnly`; default-singleton callers continue to
  see the pre-3.0 fallback behaviour and will never observe this
  variant.

## 2.0.0

Adds first-class phase attribution to the public NTS surface so callers
diagnosing a slow or refused query can distinguish DNS saturation, a
slow `getaddrinfo`, a stalled TCP connect, a slow TLS handshake, a
trickled NTS-KE record exchange, and a slow UDP NTP round-trip without
inspecting free-form diagnostic strings or bolting a Dart-side
`Stopwatch` around `ntsQuery`. The Rust crate `nts_rust` is bumped to
`0.4.0` to reflect a breaking change in the public NTS API surface;
the Dart package is bumped to `2.0.0` for the matching breaking change
in the FFI signatures and the `NtsError::Timeout` payload.

### Breaking changes

- `NtsError::Timeout` now carries a `TimeoutPhase` payload identifying
  which phase of the call hit the budget. Existing pattern matches on
  `NtsError::Timeout` (Rust) or `NtsError_Timeout()` (Dart) need to
  bind the new field; pre-2.0 consumers that ignored the variant data
  with `()` will not compile against this release.
- `nts_warm_cookies` now returns `NtsWarmCookiesOutcome { fresh_cookies,
  phase_timings }` instead of a bare `u32` (Rust) / `int` (Dart). The
  cookie count is still available via `outcome.fresh_cookies`; the new
  `phase_timings` field exposes the same per-phase wall-clock breakdown
  as `NtsTimeSample.phase_timings`.
- `NtsTimeSample` gains a required `phase_timings: PhaseTimings` field.
  Constructors that named every existing field will need to supply the
  new field; the Dart-side equivalent applies to any test fixture or
  mock that builds an `NtsTimeSample` by hand.

### Phase attribution and timings

- New `TimeoutPhase` enum tags `NtsError::Timeout`. Variants
  `DnsSaturation` (resolver pool full, raise `dns_concurrency_cap`),
  `DnsTimeout` (resolver slow, lengthen `timeout_ms` or replace the
  recursive resolver), `Connect`, `Tls`, `KeRecordIo`, and `Ntp` cover
  every blocking phase of `nts_query` / `nts_warm_cookies`.
- New `PhaseTimings` struct exposes microsecond-resolution wall-clock
  costs for the four pre-NTP phases (`dns_micros`, `connect_micros`,
  `tls_handshake_micros`, `ke_record_io_micros`); the existing
  `NtsTimeSample::round_trip_micros` is the UDP-phase equivalent and
  is intentionally not duplicated. `dns_micros` is summed across the
  KE-host and NTPv4-host lookups; phases that did not run in this call
  are reported as `0` rather than absent. See the new "Phase
  attribution and timings" section in `ARCHITECTURE.md` for the full
  diagnostic shape.
- `nts_query` instruments the KE pipeline (DNS, connect, TLS, KE
  record I/O) inside `perform_handshake` and threads the timings out
  through a refactored `KeOutcome.phase_timings`; the UDP-path DNS
  cost is captured in `bind_connected_udp_using` and folded into the
  same `dns_micros` field on the returned sample.
- `nts_warm_cookies` exposes the same KE-phase breakdown via
  `NtsWarmCookiesOutcome.phase_timings`. The UDP NTP exchange does not
  run on this path, so the `Ntp` phase is implicitly zero.
- `nts_query` now anchors a single call-wide wall-clock at the top of
  the call and subtracts the time consumed by the KE phases before
  arming the UDP-setup deadline. Restores the documented "single
  global wall-clock budget" contract on `timeout_ms`; previously a
  cold query whose KE phases consumed most of `timeout_ms` would
  re-anchor a fresh `timeout_ms`-long window for the UDP leg, letting
  the total wall-clock reach roughly 2x the caller's budget before
  surfacing as `Timeout(Ntp)`. A budget that was already exhausted by
  the KE phases now short-circuits with `Timeout(Ntp)` immediately
  rather than entering the UDP-setup leg at all.

### Tooling: orphan detection in the FRB drift check (no runtime impact)

- `tool/check_bindings.dart` now runs `_checkForOrphanedApiModules`
  after codegen + lint patches + format and before the trailing
  `git diff` drift check. The check walks `lib/src/ffi/api/*.dart`
  (skipping `*.freezed.dart` and `*.g.dart` companions, which are
  emitted from `part` directives in the primary file rather than
  referenced from the dispatcher) and flags any primary module file
  the regenerated `lib/src/ffi/frb_generated.dart` does not import.
  Closes the FRB stale-module footgun: when the last `pub` item is
  removed from a `rust/src/api/<module>.rs`, FRB drops the wire
  impls from `frb_generated.{rs,dart}` but leaves the previously
  emitted `lib/src/ffi/api/<module>.dart` on disk. The stale module
  then references symbols that no longer exist in the dispatcher
  and surfaces as an opaque "symbol not found in `RustLibApi`"
  build break under `flutter analyze` / `flutter test` rather than
  at codegen time. The dispatcher's `import 'api/<basename>.dart';`
  line set is the authoritative "still contributing" stand-in: FRB
  writes one such import for every Rust source under `rust/src/api/`
  that contributed at least one FRB-visible item on the most recent
  codegen run, so running the check after codegen guarantees the
  import set is current regardless of what is committed.
- Detection is read-only on purpose. Auto-deleting risks papering
  over a removal that wasn't intended; the diagnostic instructs
  the developer to remove the orphan (and any `*.freezed.dart` /
  `*.g.dart` companions) explicitly. The orphan list is sorted
  before printing so the diagnostic renders deterministically
  across filesystems with different `Directory.listSync` iteration
  orders (APFS, ext4, etc. differ). Local invocation produces
  `error: ` prefixed lines; CI invocation under `GITHUB_ACTIONS=true`
  emits the same body with `::error::` so the `rust-bridge-sync`
  job surfaces it as a workflow annotation. Exit code is `1` on
  the orphan path, failing the job explicitly on the orphan
  diagnostic rather than implicitly via trailing drift. Header
  comment in `tool/check_bindings.dart` is rewritten to document
  the orphan check and its rationale.

### Coverage artefact ignore at any depth

- `.gitignore` gains an unanchored `coverage/` entry. `flutter test
  --coverage` writes `coverage/lcov.info` at the package root, and
  `cargo tarpaulin --output-dir coverage` (configured in
  `rust/tarpaulin.toml`) writes `rust/coverage/lcov.info`. Both are
  local artefacts: each CI run regenerates them and uploads to
  Codecov directly from `.github/workflows/ci.yml`, so the in-tree
  copies are never consumed by anything downstream. The unanchored
  pattern catches both paths above; `example/coverage/` was already
  covered by `example/.gitignore:34`, so no duplication.


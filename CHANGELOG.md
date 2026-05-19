# Changelog

## Unreleased

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
  cfg-gated. Net effect on the published archive: ~243 KB
  uncompressed / ~60 KB compressed shaved (~11 % of the 4.0.0
  archive size), restoring the pre-extraction footprint. No
  consumer-visible behaviour change; surfaces a post-4.0.0
  archive-sanity-check observation.

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

## 1.4.0

Converts `nts` from a pure Dart package using the Native Assets pipeline
into a full Flutter plugin so that downstream consumers can use the
package on Android without having to replicate the Rust ↔ Kotlin JNI
bootstrap, the `rustls-platform-verifier-android` Maven repository
discovery, or the R8 keep-rule contract by hand. No Dart API surface
change (public exports unchanged; only dartdoc was updated to document
the two-layer initialization model) and no FRB pin movement; the Rust
crate `nts_rust` is bumped to `0.3.0` to reflect a breaking JNI ABI
change. Dart package version bumped to `1.4.0` (minor).

### Auto-initialised Android `rustls-platform-verifier` bootstrap

- New plugin module under the package root at `android/`. It ships:
  - `com.nllewellyn.nts.NtsPlugin` — a `FlutterPlugin` that calls
    `PlatformInit.init(applicationContext)` from `onAttachedToEngine`.
    `GeneratedPluginRegistrant.registerWith` runs that hook before
    Dart `main()` in any host using `FlutterActivity`,
    `FlutterFragmentActivity`, or the Flutter add-to-app
    `FlutterEngine` lifecycle, so the `rustls-platform-verifier`
    panic (`Expect rustls-platform-verifier to be initialized…`) is
    no longer reachable through the standard integration path.
  - `com.nllewellyn.nts.PlatformInit` — the matched JNI Kotlin
    counterpart for the Rust symbol exported from
    `rust/src/android_init.rs`. Also exposes a public
    `static init(Context)` for hosts that bypass
    `GeneratedPluginRegistrant` (rare; mainly bespoke add-to-app
    embeddings or tests that drive the dylib directly).
  - `consumer-rules.pro` — ProGuard / R8 keep rules covering both the
    `rustls-platform-verifier` companion AAR
    (`org.rustls.platformverifier.**`) and our own JNI shim
    (`com.nllewellyn.nts.PlatformInit`). Auto-merged into the host
    app's shrinker config; consumers do not have to copy keep rules.
  - `build.gradle.kts` — discovers the on-disk Maven repository
    bundled inside the `rustls-platform-verifier-android` cargo crate
    via `cargo metadata`, so the AAR resolves regardless of whether
    `nts` is installed from a path dependency, the pub cache, or a
    monorepo, on hosts that use the default Flutter/Gradle repository
    setup. Replaces the brittle `../../rust/Cargo.toml` traversal that
    previously lived in `example/android/app/build.gradle.kts` and
    only worked from the example tree. Hosts that enable
    `dependencyResolutionManagement.repositoriesMode =
    FAIL_ON_PROJECT_REPOS` in `settings.gradle.kts` are the documented
    exception: that mode rejects the project-level Maven injection
    the plugin performs through `rootProject.allprojects { ... }`, so
    those hosts must declare the on-disk repository themselves under
    `dependencyResolutionManagement.repositories` in
    `settings.gradle.kts`. The cargo-metadata path is stable and can
    be reused verbatim; the rationale comment in
    `android/build.gradle.kts` carries the full constraint.

  Native code (`libnts_rust.so`) continues to be delivered by the
  Native Assets pipeline (`hook/build.dart`); the plugin module ships
  no `jniLibs/` and does no Cargo wiring of its own. Platforms other
  than Android are untouched: iOS / macOS / Linux / Windows remain
  pure Native-Assets packages with no accompanying plugin module.

### Stable JNI symbol under reverse-DNS namespace (BREAKING ABI)

- The JNI entry point exported from `rust/src/android_init.rs` is
  renamed from
  `Java_com_nts_example_RustlsBootstrap_nativeInit` to
  `Java_com_nllewellyn_nts_PlatformInit_nativeInit`. The previous
  symbol was mangled for the example app's package name, which is
  not a contract any downstream consumer can reasonably satisfy
  (renaming the symbol locally would diverge from upstream releases
  on every pull). The new FQDN is under the maintainer's reverse-DNS
  namespace and is documented as the stable public ABI.
  - **Impact**: any host application that previously hand-rolled a
    matching `com.nts.example.RustlsBootstrap` Kotlin class plus
    keep rules (i.e. only the example app shipped in this
    repository, given the `1.3.x` contract was effectively
    unconsumable) must drop that class. The plugin's auto-init
    replaces the manual wiring; `flutter pub upgrade` plus
    `flutter clean` is sufficient.

### Migrating from `1.3.x`

- Out-of-tree consumers that hand-rolled the `1.3.x` Android contract
  must drop the manual scaffolding when bumping to `1.4.0`. The JNI
  symbol moved to the maintainer's reverse-DNS namespace
  (`Java_com_nllewellyn_nts_PlatformInit_nativeInit`), so the legacy
  `external fun nativeInit` declaration on a host-app shim no longer
  resolves against the dylib's exports. `System.loadLibrary("nts_rust")`
  still succeeds (the library itself loads), but the first invocation
  of the unbound declaration throws
  `UnsatisfiedLinkError: No implementation found for void
  com.<host>.RustlsBootstrap.nativeInit(android.content.Context)`. In
  the documented `1.3.x` integration shape that fires from
  `MainActivity.onCreate` before `super.onCreate(...)`, so the host
  app crashes at process start, well before any TLS handshake is
  attempted. The plugin contributes equivalent functionality; one
  round of `flutter pub upgrade` + `flutter clean` is sufficient once
  the items below are removed.
- **Host-app `RustlsBootstrap.kt`** (or any equivalent class whose
  FQDN was used to mangle the `Java_*_nativeInit` symbol exported
  from `rust/src/android_init.rs`). Delete the file. The plugin
  ships `com.nllewellyn.nts.PlatformInit` as the new stable
  counterpart; nothing in the host app needs to know its name.
- **`MainActivity.onCreate` shim** that called
  `RustlsBootstrap.init(this)` ahead of `super.onCreate(...)`.
  Revert `MainActivity` to a no-body `FlutterActivity`. The
  plugin's `onAttachedToEngine` runs from
  `GeneratedPluginRegistrant` before Dart `main()` executes, so
  any code path that reached the bootstrap before reaches it now
  without the manual call.
- **`app/build.gradle.kts`** entries that wired up the
  `rustls-platform-verifier-android` Maven repository: the
  `findRustlsPlatformVerifierMaven()` helper (or whichever shape
  it took locally), the `repositories { maven { url = uri(...) }
  metadataSources { artifact() } }` block, and the
  `implementation("rustls:rustls-platform-verifier:0.1.1@aar")`
  dependency. All three are contributed by the plugin's own
  `android/build.gradle.kts`. Leaving them in place resolves the
  AAR twice; harmless at runtime but it wastes Gradle resolution
  time and pins the consumer to a version the plugin will move
  out from under them.
- **`proguard-rules.pro`** keep rules covering
  `org.rustls.platformverifier.**` and the host-app's own
  `RustlsBootstrap` JNI class. Both are now in the plugin's
  `consumer-rules.pro` and auto-merged into the host's R8 config.
  The `RustlsBootstrap`-flavoured rule is doubly stale because the
  symbol name has changed; an unmodified rule keeps a class that
  no longer exists and produces no shrinker warning either way.
- **`settings.gradle.kts`** does not change. The
  `dev.flutter.flutter-plugin-loader` block is the standard
  Flutter wiring that picks up the new plugin module
  automatically; no manual `include`, `pluginManagement`, or
  Maven entry is required.
- **Custom embeddings.** Hosts that legitimately bypass
  `GeneratedPluginRegistrant` — bespoke add-to-app integrations,
  integration tests driving the dylib directly, isolates spawned
  ahead of plugin registration — should call
  `com.nllewellyn.nts.PlatformInit.init(context)` from Kotlin in
  place of the deleted `RustlsBootstrap.init(...)`. The signature
  and idempotency contract are identical; only the FQDN moves.
- **Hosts that did not hand-roll the `1.3.x` Android contract**
  have nothing to do beyond `flutter pub upgrade` + `flutter
  clean`. The previous JNI symbol was mangled for the example
  app's package name and could not be satisfied without forking
  the Rust crate, so the realistic pre-`1.4.0` integration path
  for any out-of-tree consumer was a vendored copy of this
  repository with the symbol renamed locally — that fork should
  be retired in favour of the published `1.4.0` plugin and the
  stable `com.nllewellyn.nts.PlatformInit` symbol.

### Non-Android upgrade path

iOS, macOS, Linux, and Windows consumers are unaffected by the
migration steps above. The `android/` plugin module and the
`flutter: plugin: platforms: android:` key in `pubspec.yaml` are
scoped exclusively to Android — the Flutter tool generates no
plugin registration on other targets, no `ios/` / `macos/` /
`linux/` / `windows/` plugin module exists to compile or link,
and the Native Assets pipeline that delivers
`libnts_rust.{so,dylib,dll}` is unchanged. The public Dart API
exported from `lib/nts.dart` is unchanged, and
`await RustLib.init()` remains the only initialization step.
The upgrade is a single-line `pubspec.yaml` bump.

The on-platform TLS validators are also unchanged: every
non-Android target continues to use `rustls-platform-verifier`
0.5 directly, which talks to the Security framework on
iOS/macOS, the system trust store on Linux, and the Win32
`Crypt*` APIs on Windows without any host-side initialization
step. None of these paths require JVM-style bootstrap, which is
why the "Native platform bootstrap" layer documented in the
README is Android-only.

### Example app simplified to a vanilla `FlutterActivity`

- `example/android/app/src/main/kotlin/com/nts/example/RustlsBootstrap.kt`
  removed. Its responsibilities are now split between the plugin's
  `NtsPlugin` (registration-time auto-init) and `PlatformInit`
  (manual fallback).
- `example/android/app/src/main/kotlin/com/nts/example/MainActivity.kt`
  reverted to a no-body `FlutterActivity`. The Android trust-store
  bootstrap happens before `super.onCreate()` runs.
- `example/android/app/build.gradle.kts` no longer carries the
  `findRustlsPlatformVerifierMaven()` helper, the
  `rustls:rustls-platform-verifier:0.1.1@aar` `implementation` dep,
  or the local Maven repository declaration. All three now live in
  the plugin's own `android/build.gradle.kts`.
- `example/android/app/proguard-rules.pro` reduced to a stub
  comment. The keep rules previously declared here are merged in
  from the plugin's `consumer-rules.pro`.

### Internal documentation refresh

- `rust/src/lib.rs`, `rust/src/android_init.rs`, and
  `rust/src/nts/hybrid_verifier.rs` updated to reference the new
  Kotlin FQDN and the plugin's `consumer-rules.pro` rather than the
  decommissioned `RustlsBootstrap.kt` in the example app. The
  `hybrid_verifier` warn-level fallback message that fires when R8
  has stripped `org.rustls.platformverifier.*` now points operators
  at the plugin's keep-rule file.

## 1.3.2

Repo-policy and CI-hygiene cleanup, plus a single Rust-side
runtime fix that closes a multi-hour recovery stall observed in
downstream consumers when an NTS server rotates its master key
out from under our cookie pool. No public Dart API change
(`lib/nts.dart` is byte-identical) and no FRB pin movement; the
Rust crate `nts_rust` is bumped to `0.2.3` to reflect the
behavioural change in `nts_query`. Dart package version bumped
to `1.3.2` (patch).

### Fail-fast eviction of stale NTS sessions on rekey signals

- `nts_query` (`rust/src/api/nts.rs`) now evicts the cached
  `Session` for the spec on either of the two on-wire signals
  that indicate the server has rotated keys out from under our
  cookie pool. The next `checkout` for that host finds no entry
  and performs a fresh NTS-KE handshake instead of draining the
  remaining cookies through identical failures plus the caller's
  per-source exponential backoff.
  - **AEAD authentication failure** — local C2S seal in
    `build_client_request` or remote S2C verify in
    `parse_server_response` returns `NtpError::Aead`. The cached
    keys are out of step with the server's current master key.
  - **RFC 8915 §5.7 NTSN Kiss-of-Death with matching UID** — a
    standards-compliant server that cannot validate the cookie
    SHOULD respond with stratum 0 + `reference_id`=`NTSN`, and
    that response MUST NOT carry an Authenticator (the server
    has no usable session keys to AEAD-sign with). The
    AEAD-only eviction path missed this shape entirely:
    `parse_server_response` rejected it as
    `MissingAuthenticator` so the cached session survived and
    the same dead-pool draining symptom recurred. The new
    `NtpError::StaleCookie` arm classifies the matching-UID
    NTSN distinctly and routes it through the same
    generation-guarded eviction.
- The eviction is gated on a generation snapshot captured at
  `checkout` time, symmetric to the guard already present in
  `deposit_cookies`. If a concurrent `nts_warm_cookies` (or
  another `checkout` that triggered its own re-handshake)
  installed a fresh session under the same key while this query
  was on the wire, the in-flight failure belongs to the old keys
  and the new session survives untouched. Without the guard a
  single transient signal would force every concurrent caller
  for the same host through a redundant re-handshake.
- Off-path-attacker scope of the NTSN path: the matching-UID
  check is the only authenticity signal available (no AEAD), so
  an attacker who can observe one wire packet and forge a
  UID-matching NTSN can at worst force one extra KE handshake
  before the next legitimate response heals the session. A
  non-matching (or absent) UID falls through to
  `MissingAuthenticator` and leaves the cached session intact;
  unauthenticated non-NTSN kiss codes (`RATE`, `DENY`, …) do
  the same so a server that AEAD-signs them (the standards
  path) still surfaces with its kiss code, while a stripped
  forgery cannot trigger an eviction.
- AEAD-error mapping verified end-to-end: `From<AeadError>` routes
  `OpenFailed` (tag mismatch — the dominant master-key-rotation
  signal), `SealFailed`, `InvalidKeyLength`, and
  `InvalidNonceLength` to `NtsError::Authentication` (eviction);
  `UnsupportedAlgorithm` is only reachable from the KE path and
  routes to `KeProtocol` (no eviction).
  `From<NtpError>::Aead(_)` routes the same way; wire-format,
  Kiss-of-Death, and `Unsynchronized` arms route to `NtpProtocol`
  (no eviction — those are transient or server-attested signals,
  not key-state failures); the new `StaleCookie` arm routes to
  `NtpProtocol` for the Dart-facing taxonomy, with eviction
  applied pre-conversion inside the `evict_on_rekey_signal`
  closure so the public `NtsError` enum stays
  byte-identical.
- Healthy-path cost is unchanged: the trigger is a `map_err`
  closure that only acquires the `sessions()` mutex inside the
  `Aead`/`StaleCookie` arms, so success returns are
  byte-identical to the pre-fix behaviour.
- Coverage: seven new tests pin the behaviour. In
  `rust/src/api/nts.rs::tests`: (i) matching-generation eviction
  drops the entry, jar and keys with it; (ii) stale-generation
  eviction is a no-op when a concurrent re-handshake has advanced
  the cached session; (iii) eviction is a quiet no-op when the
  entry is already absent; (iv) end-to-end via a loopback faux
  server, an AEAD tag mismatch evicts the session; (v) end-to-end,
  a non-AEAD protocol failure preserves it; (vi) end-to-end, a
  matching-UID NTSN KoD evicts; (vii) end-to-end, a wrong-UID NTSN
  preserves. In `rust/src/nts/ntp.rs::tests`: four new parser-level
  tests cover matching-UID NTSN → `StaleCookie`, wrong-UID NTSN →
  `MissingAuthenticator`, UID-less NTSN → `MissingAuthenticator`,
  and unauthenticated non-NTSN kiss codes →
  `MissingAuthenticator`.
- The FRB-generated `lib/src/ffi/api/nts.dart` regains
  `evict_session` in the alphabetised "ignored because not `pub`"
  comment line; no bindings code changes (the helper is
  intentionally crate-private).

### Branch-protection enforcement (repo policy, no runtime impact)

- Toggle `enforce_admins: true` on the `main` branch protection rule
  so the six required status checks (the four pre-existing CI gates
  plus the two new `Hooks *` checks added in this PR), linear-history
  requirement, and PR-only merge policy are binding for the maintainer
  account. The
  previous configuration (`enforce_admins: false`) made the rule
  advisory for repo admins, which left a direct `git push origin main`
  unblocked for the most likely violator.
- Add repo-tracked git hooks under `tool/hooks/` (POSIX shell, no
  runtime dependency beyond `git`) that refuse direct work on
  `main`/`master`: `pre-commit` blocks plain commits,
  `pre-merge-commit` blocks merge commits (which bypass
  `pre-commit`), and `pre-push` blocks any push whose destination
  ref is `refs/heads/main`/`refs/heads/master` regardless of the
  source branch. Activated per clone with `git config
  core.hooksPath tool/hooks`; without that activation layer 1
  contributes nothing. Two commit-time bypasses remain, both
  caught at push time by `pre-push` and the GitHub-side rule:
  (a) rebases that rewrite local `main` (each replayed commit
  runs in detached HEAD, so `pre-commit` falls through), and
  (b) fast-forward merges (`git merge feature/foo` while `main`
  has no diverging commits advances the ref without creating a
  commit, so `pre-merge-commit` does not fire).
- Document the enforcement model in `AGENTS.md`'s new "Branch
  Protection" section and `DEVELOPMENT.md`'s "Local hook setup"
  subsection. The model has two enforcement layers (local hooks
  for fast-fail, GitHub branch protection at the remote) plus CI
  as the upstream of the status checks the protection rule
  consumes. The branch protection rule itself does the merge
  gating: the rule refuses direct pushes from non-admin
  contributors, and `enforce_admins: true` extends that refusal
  to admin/owner accounts (closing the maintainer-bypass path);
  `required_status_checks` refuses the PR merge until the listed
  contexts pass. CI is not a separate enforcement layer, just
  the source of the signals the rule reads. Public Dart/Rust API
  unchanged.
- CI gains two narrowly-scoped sibling jobs in
  `.github/workflows/ci.yml` plus a `tool/hooks/**` path
  classification on the existing `dorny/paths-filter` step, so a
  PR that touches only the enforcement scripts still gets
  validated rather than skipping every heavy job and merging
  unverified. Both jobs are added to `required_status_checks` on
  `main`, raising the required-context count from four to six:
    - `Hooks shell-syntax check` runs `sh -n` plus presence and
      exec-bit verification on each tracked hook (the explicit
      list fails closed if a hook is deleted, renamed, or
      chmod-stripped, where a glob would silently pass).
    - `Hooks behaviour check` runs `tool/hooks/test_hooks.sh`,
      a new POSIX-shell test that provisions a throwaway repo
      via `mktemp -d`, points `core.hooksPath` at `tool/hooks/`,
      stages real commits and real merges, and invokes
      `pre-push` directly with synthetic refs/SHAs on stdin
      (git's documented pre-push contract: read updates from
      stdin, exit non-zero to abort). Asserts on exit codes
      plus stderr content. Catches the regression shape `sh -n`
      cannot — a script that parses but no longer enforces
      policy at runtime — and carries an explicit assertion
      sentinel for the unquoted-heredoc class of bug where
      `set -u` aborts the hook before the recovery recipe can
      print.
  No other CI behaviour changes: the `build`, `rust`, and
  `rust-bridge-sync` filters and gates are byte-identical.

### Coverage exclusion alignment

- Reconcile the four loci that determine the coverage denominator so
  local artifacts, CI flags, and the Codecov dashboard agree.
  `.codecov.yml` now ignores `lib/src/ffi/api/nts.dart` (FRB-generated
  single-expression forwarders of the form
  `ntsQuery(...) => RustLib.instance.api.crateApiNtsNtsQuery(...)` —
  reachable from the smoke tests but low-signal for authored-code
  coverage; the FFI dispatch they delegate into lives in
  `frb_generated*.dart` and is what `RustLib.initMock()` substitutes)
  and `rust/src/api/simple.rs` (holds only the `#[frb(init)]`
  lifecycle hook `init_app`, fired on dylib load and unreachable
  from `cargo test --lib`). `rust/tarpaulin.toml` (new) carries the
  same Rust exclusion set so a local `cargo tarpaulin` reproduces
  CI numbers without per-invocation `--exclude-files` flags.
  `.github/workflows/ci.yml` adds the matching
  `--exclude-files 'src/api/simple.rs'` and the comment block above
  the step now enumerates all four filtered Rust files (previously
  named only two). `DEVELOPMENT.md`'s "Coverage exclusion policy"
  subsection is refreshed to match.

### `greet` smoke-test stub removal

- Delete the `greet` function from `rust/src/api/simple.rs` (left
  over from the FRB scaffold; never re-exported through
  `lib/nts.dart`, so internal-only by the package's own public-API
  stability statement) and refresh the file header to document its
  remaining role as the lifecycle-hook host.
  `lib/src/ffi/api/simple.dart` is removed; FRB does not auto-clean
  stale module files when a Rust `api/` module loses its last `pub`
  item (a follow-up extends `tool/check_bindings.dart` to flag
  this footgun). The
  `crateApiSimpleGreet` overrides in `example/lib/src/mock_api.dart`,
  `test/api_smoke_test.dart`, and `test/ffi_smoke_test.dart` are
  removed in the same commit; the FRB-generated layer
  (`lib/src/ffi/frb_generated.{dart,io.dart,web.dart}`,
  `rust/src/frb_generated.rs`) is regenerated via
  `flutter_rust_bridge_codegen 2.12.0` and committed clean against
  the drift gate.

### CI: Flutter `stable` channel migration

- Switch the Flutter SDK reference from the pinned `3.41.7` release
  to the `stable` channel across the five loci that named it:
  `.fvmrc` (`"flutter": "stable"`), `.github/workflows/ci.yml`
  (matrix entry renamed `3.41.7` → `stable`), `pubspec.yaml`,
  `DEVELOPMENT.md`, and `.github/pull_request_template.md`. The
  pinned-semver references are rewritten to describe the channel
  rather than a specific version. The compatibility-floor matrix
  leg (`3.38.10`, the lowest Flutter satisfying `flutter: ^3.38.0`
  in `pubspec.yaml`) is unchanged so the floor remains pinned.
- `subosito/flutter-action` receives `flutter-version: any` for the
  `stable` leg (the action's documented channel-latest sentinel,
  since the action does not accept channel names as
  `flutter-version` values); the format / coverage / Codecov
  upload gates are retargeted from `matrix.flutter == '3.41.7'`
  to `matrix.flutter == 'stable'`. `rust-bridge-sync` drops its
  `flutter-version` pin and points the FVM symlink at
  `$HOME/fvm/versions/stable` to match `.fvmrc`.
- Branch-protection continuity is preserved: the matrix-leg job
  names (`Format / analyze / Dart tests (Flutter ${{ matrix.flutter }})`)
  are *not* required status checks. The `Dart tests gate`
  aggregator job (`needs: [changes, build]`, `if: always()`) is
  the entry on `main`'s `required_status_checks` list and rolls
  up the matrix outcome under a name that does not move with the
  channel rename, so the rule continues to gate merges without
  any branch-protection edit. The five other required contexts
  (`Detect changed paths`, `Verify FRB bindings are in sync`,
  `Rust build + tests + coverage`, `Hooks shell-syntax check`,
  `Hooks behaviour check`) are also untouched by this rename.
- The historical `3.41.7` mention inside the `## 1.0.0` release
  entry below is intentionally left in place — it is a
  published-release entry and pub.dev archives the changelog at
  publish time.

## 1.3.1

Documentation-only patch on the 1.3.0 observability surface. No code,
FFI, or runtime behaviour changes; the Rust crate `nts_rust` is
unchanged at `0.2.2`.

### `NtsDnsPoolStats` — acknowledge `inFlight > highWaterMark` transient

- Tighten the dartdoc on `ntsDnsPoolStats` (`lib/src/api/nts.dart`)
  and the mirrored Rust docstring on `NtsDnsPoolStats` plus its
  `high_water_mark` field (`rust/src/api/nts.rs`). The 1.3.0 wording
  ("Monotonically non-decreasing for the lifetime of the process",
  "racy by construction… never logically impossible") invited the
  strict reading that `highWaterMark >= inFlight` holds at every
  observation point. It does not: `try_acquire_slot` performs the
  `fetch_add` on `in_flight` and the `fetch_max` on `high_water_mark`
  as two independent atomic operations, so a concurrent
  `pool_snapshot()` can observe `inFlight = prev + 1` and
  `highWaterMark = prev` for the few-nanosecond window between them.
  The replacement wording calls this transient out by name and
  restates the actual guarantee — per-counter monotonicity across
  consecutive snapshots, not a cross-counter invariant within a
  single snapshot.
- Rationale for documenting rather than patching `snapshot_of` to
  return `max(in_flight, high_water_mark)`: the two `Relaxed` loads
  in the snapshot path are not atomic together, so a derived `max()`
  suppresses one common observation but does not produce a coherent
  point-in-time view; closing the race in the increment path
  requires a CAS loop on a packed `(in_flight, hwm)` tuple, which is
  not justified by an observable-only-via-snapshot diagnostic
  counter; and the three operator-facing failure-mode signatures
  (healthy / cap-bound / libc wedge — see the rest of the dartdoc)
  reason about per-counter trajectories across consecutive
  snapshots, not single-snapshot cross-counter invariants. The
  transient does not degrade their diagnostic value.
- The generated FFI dartdoc in `lib/src/ffi/api/nts.dart` is
  regenerated from the Rust source and tracks the new wording. No
  other diff in the FRB-generated layer.

### Documentation

- Clarify shared-pool semantics for mixed-cap callers in the
  `rust/src/nts/dns.rs` module header and the "Timeout budget and
  bounded DNS" section of `ARCHITECTURE.md`. The 1.2.0 wording —
  "the effective ceiling at any moment is set by whichever caller is
  currently being admitted" — invited a stateful reading in which the
  most recently admitted caller's cap somehow governs subsequent
  admissions. The actual mechanic is purely local: every admitted
  worker counts toward every caller's threshold, and each admission
  decision compares the live pool size against *that call's* own cap.
  The replacement wording names the asymmetric starvation behaviour
  explicitly (a small-cap caller can be refused when the pool is
  filled by a large-cap caller; the reverse cannot happen) so it is
  discoverable by a future ctrl-F search for "starvation" or
  "fairness". The published 1.2.0 changelog entry is intentionally
  not retroactively edited (pub.dev archives the changelog at publish
  time).

## 1.3.0

Public-API stability layer, bounded DNS resolver pool observability,
and a documentation correction in the Rust core. Strictly additive on
the Dart surface: existing call sites (including
`test/ffi_smoke_test.dart` and the example app, GUI, and CLI) keep
their current arguments and continue to compile. The Rust crate
`nts_rust` is unchanged at `0.2.2`.

### Public API stability layer (`lib/src/api/nts.dart`, new)

- Introduce a hand-written wrapper in `lib/src/api/nts.dart` that
  becomes the package's stable public surface. The wrapper exposes
  `ntsQuery` and `ntsWarmCookies` with idiomatic Dart optional named
  parameters (`timeoutMs`, `dnsConcurrencyCap`) and package defaults
  (`kDefaultTimeoutMs = 5000`, `kDefaultDnsConcurrencyCap = 0`),
  forwarding to the FRB-generated bindings for the actual FFI call.
  `await ntsQuery(spec: spec)` (no other arguments) now compiles and
  produces the same behaviour as 1.2.0's
  `ntsQuery(spec: spec, timeoutMs: 5000, dnsConcurrencyCap: 0)`.
- Rewrite `lib/nts.dart` as an explicit re-export of the wrapper plus
  the bridge bootstrap (`RustLib`). The blanket re-export of
  `lib/src/ffi/api/nts.dart` (and the `greet` toolchain helper from
  `lib/src/ffi/api/simple.dart`) is removed; the FFI surface is now an
  internal implementation detail. Consumers' call sites are unchanged
  because the wrapper exposes the same names with compatible
  signatures.
- Motivation: `flutter_rust_bridge` v2 codegen emits every Rust `pub
  fn` argument as a `required` named parameter on the Dart side, with
  no FRB attribute today that maps it to an optional Dart parameter
  with a default. Absorbing that asymmetry in a hand-written layer
  decouples the public contract from the FFI contract — internal Rust
  signature evolution (extra knobs, struct field churn, lint-pin
  regen) no longer propagates as breaking call-site edits for every
  downstream consumer. The 1.2.0 release was the concrete episode
  that motivated this: adding `dnsConcurrencyCap` was a strict
  superset of the previous behaviour but broke source compatibility
  for every caller because the new parameter landed as `required`.
- The deprecation policy for future Rust-side removals is symmetric:
  parameters dropped from the Rust core survive in the wrapper as
  deprecated no-ops for at least one minor release before being
  removed at the next major. Documented in `ARCHITECTURE.md`'s new
  "Public API stability layer" section.

### Bounded DNS resolver pool observability

- Add `ntsDnsPoolStats()` (synchronous; no future / isolate hop)
  returning a process-wide snapshot of the bounded resolver pool with
  four counters: `inFlight` (live workers currently pinned in the
  system resolver), `highWaterMark` (peak `inFlight` since process
  start, monotonic), `recovered` (cumulative completed workers that
  released their slot), and `refused` (cumulative admission attempts
  rejected because the cap was reached). The function is marked
  `#[frb(sync)]` on the Rust side so reading four atomics does not pay
  the FRB future-marshalling overhead.
- The new struct `NtsDnsPoolStats` lands as part of the wrapper
  layer's public surface alongside `NtsServerSpec` / `NtsTimeSample`.
- Saturation surfaces unchanged on the hot path as `NtsError.timeout`
  (the error contract stays collapsed); the new counters are the
  side-channel that lets operators distinguish a healthy
  oscillating-below-the-cap resolver from a true libc-level wedge.
  The diagnostic shape is documented in dartdoc on
  `ntsDnsPoolStats()` and in `ARCHITECTURE.md`'s "Timeout budget and
  bounded DNS" section.
- Internal refactor in `rust/src/nts/dns.rs`: the previous lone
  `IN_FLIGHT_DNS_LOOKUPS: AtomicUsize` is replaced by a `PoolStats`
  bundle (in-flight + high-water + recovered + refused atomics), so
  `try_acquire_slot` / `SlotGuard::drop` keep the four counters in
  lockstep and the test seam parameterises a per-test bundle the same
  way the previous lone counter was parameterised. The existing
  `resolve_with_global` / `resolve_with_timeout` signatures are
  unchanged; only the internal `resolve_with` seam picks up the new
  type. Memory-ordering rationale for each counter (`Relaxed` for
  cumulative tallies, `AcqRel` for in-flight, `AcqRel` for the HWM
  `fetch_max`) is documented inline.
- Three new Rust unit tests in `nts::dns::tests`:
  - `recovered_increments_on_worker_completion` — the cumulative
    counter bumps exactly once per slot release, after the worker
    returns from the resolver, alongside the in-flight drain.
  - `refused_increments_on_cap_exhaustion` — companion to
    `cap_reached_returns_would_block`; pins the counter delta on
    rejected admissions.
  - `high_water_mark_tracks_concurrent_admissions` — admits N
    workers behind a `Barrier`, asserts the mark catches up to N
    while the slots overlap, then releases and asserts the mark
    stays at N (monotonic, not pinned to the live in-flight count).
- New wrapper-level smoke test (`test/api_smoke_test.dart`) verifies
  `ntsDnsPoolStats()` is a synchronous getter returning an
  `NtsDnsPoolStats` and that the FFI struct's fields are forwarded
  through the wrapper verbatim.

### Documentation

- `rust/src/nts/cookies.rs`: rewrite the `DEFAULT_CAPACITY` doc
  comment. The previous wording claimed the "initial NTS-KE response
  always delivers exactly 8" cookies, which is not mandated by the
  protocol — RFC 8915 §4 leaves the count returned by any given
  server to server policy. The replacement cites RFC 8915 §6 (the
  client-side cap of 8 unused cookies) and notes that the value
  matches what several public deployments (Cloudflare) are observed
  to deliver, with a §4 reference for the server-policy framing. No
  code change; this aligns the internal docs with the
  `example/`-side framing already shipped in 1.1.2 / 1.2.0.
- `README.md`: rewrite the "API summary" table to show the wrapper
  signatures with `=` defaults (`timeoutMs = kDefaultTimeoutMs`,
  `dnsConcurrencyCap = kDefaultDnsConcurrencyCap`), add rows for the
  two `kDefault*` constants, and add a paragraph linking to the new
  ARCHITECTURE.md section. The `dnsConcurrencyCap` prose is updated
  to mention that omitting the parameter (or passing `0`) inherits
  the built-in default.
- `ARCHITECTURE.md`: add a new "Public API stability layer" section
  describing the wrapper, the FRB asymmetry it absorbs, the
  deprecation policy, and the contract split between
  `lib/src/api/` (hand-written, stable) and `lib/src/ffi/`
  (generated, regenerable). Update the repository layout table to
  list the new wrapper directory.

### Examples

- `example/main.dart`: simplify the warm-then-burst flow to use the
  new wrapper defaults (`await ntsWarmCookies(spec: spec)` and `await
  ntsQuery(spec: spec)` instead of threading explicit `timeoutMs:
  5000, dnsConcurrencyCap: 0` through every call). Comment in Phase
  1 documents that the defaults are sourced from `kDefaultTimeoutMs`
  / `kDefaultDnsConcurrencyCap`. `example/example.md`'s fenced
  block stays byte-for-byte identical to `example/main.dart`
  (5310 bytes).
- The Flutter GUI controller (`example/lib/src/state/nts_controller.dart`)
  and the CLI (`example/bin/nts_cli.dart`) continue to thread their
  own configured values explicitly. They are not migrated to the
  defaults pattern in this release; the wrapper accepts both call
  styles.

### Tests

- `test/api_smoke_test.dart` (new): wrapper-level smoke test that
  pins the package defaults (`kDefaultTimeoutMs == 5000`,
  `kDefaultDnsConcurrencyCap == 0`), asserts the wrapper applies
  them when the optional parameters are omitted, verifies that
  explicit overrides (including the `0` sentinel) are forwarded
  verbatim to the FRB layer, and exercises the synchronous
  `ntsDnsPoolStats()` plumbing. Seven test cases.
- `test/ffi_smoke_test.dart`: rewrite the import block. `greet` and
  the FRB-layer `ntsQuery` / `ntsWarmCookies` are now imported
  directly from `package:nts/src/ffi/...` rather than the public
  barrel, so the test continues to exercise the FFI contract
  unchanged while the public barrel stops re-exporting them. The
  five existing test cases are unmodified and still pass.

### Generated bindings

- `lib/src/ffi/api/nts.dart`, `lib/src/ffi/frb_generated.dart`,
  `lib/src/ffi/frb_generated.io.dart`,
  `lib/src/ffi/frb_generated.web.dart`, and
  `rust/src/frb_generated.rs` regenerated via
  `flutter_rust_bridge_codegen generate` (pinned at 2.12.0) to pick
  up the new `NtsDnsPoolStats` struct and the `nts_dns_pool_stats`
  entry point. No drift detected by `tool/check_bindings.dart` after
  the regen + lint-suppression patches.

### Verification

- `fvm flutter analyze`: clean (no issues).
- `fvm flutter test test/api_smoke_test.dart test/ffi_smoke_test.dart`:
  12 / 12 pass.
- `fvm flutter test` (example/): 31 / 31 pass.
- `cargo fmt --check` (in `rust/`): clean.
- `cargo clippy --tests --all-targets -- -D warnings` (in `rust/`):
  clean.
- `cargo test` (in `rust/`): 112 / 112 pass, 3 ignored (live-network).
- `example/main.dart` ↔ `example/example.md` fenced-block
  byte-for-byte parity: 5310 bytes.

## 1.2.0

Reliability and timeout-budget hardening across the Rust core. The public
Dart surface (`ntsQuery`, `ntsWarmCookies`, `NtsServerSpec`,
`NtsTimeSample`, `NtsError`) gains one new optional knob —
`dnsConcurrencyCap` — for tuning the bounded DNS resolver per call;
existing call sites that omit it continue to compile because the
codegen marks the parameter required (pass `0` to inherit the default).
Consumer-visible behaviour also improves on the timeout-fidelity and
DNS-stall paths. Rust crate `nts_rust` is bumped from `0.2.1` to
`0.2.2`; the bindings (`lib/src/ffi/`) are regenerated to reflect the
new parameter.

### Bounded DNS resolution (`rust/src/nts/dns.rs`, new module)

- Replace the unbounded `ToSocketAddrs` lookup that previously fronted
  both NTS-KE TCP connect and the NTPv4 UDP bind with a thread-pool
  resolver that offloads `getaddrinfo` to a detached worker and bounds
  the wait via a `mpsc::Receiver::recv_timeout`. A stalled name server
  no longer holds the calling thread past the caller's `timeoutMs`
  budget; the resolver returns `io::ErrorKind::TimedOut` once the
  remaining budget is exhausted, which the `api::nts` and `nts::ke`
  call sites collapse to `NtsError::Timeout`.
- Add a global atomic concurrency cap on in-flight resolver workers to
  protect the host environment from a runaway burst of `ntsQuery` calls
  against a blackholed DNS server. The cap is **configurable per call**
  via the `dnsConcurrencyCap` parameter on `ntsQuery` /
  `ntsWarmCookies`; passing `0` selects the built-in default of **4**,
  sized for mobile (worst-case ~512 KB-1 MB of pthread stack per leaked
  worker on iOS/Android, capping the steady-state leak from a
  blackholed resolver to ~4 MB instead of unbounded growth).
  Server-side callers that legitimately need higher fan-out can pass a
  larger cap per invocation. Cap exhaustion surfaces as
  `io::ErrorKind::WouldBlock` from the resolver entry point and is
  mapped to `NtsError::Timeout` at both KE and UDP call sites so the
  Dart-side switch arm is reached without introducing a new variant.
- Because the threshold compares against a single process-wide counter,
  two concurrent callers passing different caps share the same
  in-flight pool: the effective ceiling at any moment is set by
  whichever caller is currently being admitted, not a private quota.
- The detached-worker pattern intentionally leaks the OS thread on
  timeout rather than aborting it: `getaddrinfo` is not cancellable on
  any major libc, so attempting to interrupt the worker would corrupt
  the resolver state. The slot cap bounds the steady-state cost of
  this leak under pathological conditions.

### NTS-KE handshake (`rust/src/nts/ke.rs`)

- Introduce a private `Deadline` newtype that anchors a single
  `Instant` at the top of `perform_handshake` and exposes
  `remaining()` (saturating) plus `apply_to(&TcpStream)` (refreshes
  socket read/write timeouts; returns `io::ErrorKind::TimedOut` if the
  budget is exhausted). Replaces the previous pattern where every
  blocking phase — DNS lookup, TCP connect, TLS handshake, NTS-KE
  record I/O — was independently armed with the caller's full
  `timeoutMs`, allowing the total wall-clock cost to overshoot the
  budget by up to ~3x.
- `connect_with_deadline_using<F>` becomes the new core path;
  `connect_with_timeout_using` is retained as a thin
  `Option<Duration> → Option<Deadline>` wrapper that preserves the
  slow-DNS test seam. `perform_handshake` threads one `Deadline`
  through DNS resolution, TCP connect, post-connect socket-timeout
  setup, pre-write/pre-flush refreshes, and the read loop.
- `read_to_end_capped` now takes `Stream<'_, ClientConnection,
  TcpStream>` plus `Option<&Deadline>` and refreshes the underlying
  socket's read/write timeouts on every loop iteration, so a server
  that drip-feeds the NTS-KE response cannot stretch the read phase
  past the global deadline.
- New regression tests:
  - `deadline_remaining_saturates_at_zero_after_expiry`,
  - `deadline_apply_to_returns_timed_out_when_expired`,
  - `deadline_apply_to_sets_socket_timeouts_within_remaining_budget`,
  - `connect_with_deadline_respects_external_deadline_for_unroutable_ip`,
  - `connect_with_timeout_surfaces_slow_dns_as_timed_out`.

### UDP query path (`rust/src/api/nts.rs`)

- Mirror the KE-side helper with a private `UdpDeadline` newtype for
  `UdpSocket`. Surface: `new(Duration)`, `remaining()` (saturating),
  and `remaining_or_timeout() -> Result<Duration, NtsError>` which
  short-circuits to `NtsError::Timeout` once the budget is exhausted
  rather than feeding `Duration::ZERO` into `set_read_timeout` (which
  is `EINVAL` on some platforms).
- `bind_connected_udp_using` rewritten to anchor one `UdpDeadline`,
  invoke `remaining_or_timeout()?` before `resolve_with_global` so the
  resolver receives the live remaining budget rather than the original
  `timeoutMs`, and again before `set_read_timeout`/`set_write_timeout`
  so the UDP socket inherits the *remaining* budget. The downstream
  `socket.send` / `socket.recv` in `nts_query` therefore trip no later
  than the global deadline, even when the KE phase has consumed most
  of it.
- `UdpDeadline` is intentionally a separate type from the KE-side
  `Deadline` because `apply_to` would otherwise need to be
  socket-type-generic; the duplicated surface is ~20 lines.
- New regression tests:
  - `udp_deadline_remaining_or_timeout_after_expiry`,
  - `bind_connected_udp_socket_timeouts_reflect_remaining_budget`,
  - `bind_connected_udp_surfaces_slow_dns_as_timeout`.

### Documentation

- The dartdoc on `ntsQuery` (regenerated into
  `lib/src/ffi/api/nts.dart` from the Rust docstring on
  `crate::api::nts::nts_query`) now states that `timeout_ms` "bounds
  the DNS lookup that precedes each phase so a stalled `getaddrinfo`
  cannot stretch the wall-clock cost past the caller's budget" rather
  than the previous wording which described the timeout as
  per-phase.

### Housekeeping

- Apply `cargo fmt` (pinned toolchain `1.92.0`) across `api/mod.rs`,
  `ios_init.rs`, `lib.rs`, `nts/aead.rs`, `nts/cookies.rs`,
  `nts/ntp.rs`, and `nts/records.rs` to reconcile drift accumulated
  since the 1.1.0 cycle. Behaviour is unchanged.
- `.gitignore`: add `.DS_Store` so macOS Finder metadata stops
  appearing in `git status`.
- `rust/src/nts/mod.rs`: declare the new `dns` module.

### Verification

- `cargo test --manifest-path rust/Cargo.toml`: 108 passed, 0 failed,
  3 ignored (live-network).
- `cargo clippy --manifest-path rust/Cargo.toml --tests --all-targets
  -- -D warnings`: clean.
- `cargo fmt --manifest-path rust/Cargo.toml --check`: clean.
- `dart analyze`: clean.
- `flutter test test/ffi_smoke_test.dart`: 5 / 5 pass.

## 1.1.2

Example-app polish and RFC 8915 §4 compliance in the consumer demo. No
changes to the published Dart surface (`ntsQuery`, `ntsWarmCookies`,
`NtsServerSpec`, `NtsTimeSample`, `NtsError`), the Rust crate
(`nts_rust` stays at `0.2.1`), the FFI bindings, or the Native Assets
build hook. The diff is confined to `example/`, `README.md`, and
`example/GUI_GUIDE.md`.

### Example app (`example/`)

- `example/lib/src/widgets/log_view.dart`: fix an auto-scroll
  "stickiness" race condition. The scroll-to-bottom side-effect ran in
  a `WidgetsBinding.instance.addPostFrameCallback`, so by the time the
  callback evaluated whether the user had been near the bottom the
  layout had already been extended by the freshly-appended entry and
  the threshold check fired against `maxScrollExtent` measured *after*
  the append. The decision is now taken synchronously in the signal
  effect against the pre-append layout, while the animated jump still
  runs post-frame against the resolved target. The 32 px stickiness
  threshold and 120 ms animation duration are unchanged.
- `example/main.dart`, `example/example.md`, `README.md`,
  `example/GUI_GUIDE.md`: drop the hardcoded `const _burstSize = 8`
  assumption from the warm-then-burst sample. RFC 8915 §4 leaves the
  cookie-pool size to server policy — the NTS-KE handshake does not
  let a client request a specific count — so the burst loop now runs
  `for (var i = 0; i < warmed; i++)` against the actual count returned
  by `ntsWarmCookies`. Prose in `README.md` and `example/GUI_GUIDE.md`
  is rewritten to cite the RFC and the live-log `recovered N fresh
  cookie(s)` report rather than the previous "(typically 8)" /
  "Eight matches" framing. `example/main.dart` and the fenced block in
  `example/example.md` remain byte-for-byte identical at 5172 bytes.
- `example/lib/src/widgets/log_view.dart`: trim ~20 px of trailing
  whitespace below the newest log entry. After the stickiness fix made
  the layout settle visibly, two compounding sources of dead space at
  the bottom of the log card became apparent: `_spansFor` appended
  `\n` to *every* entry (including the last), leaving a phantom blank
  line; and `SingleChildScrollView` used symmetric
  `EdgeInsets.all(12)`, stacking 12 px of bottom inset on top of that
  phantom line. The fix drops the trailing newline from the message
  span, inserts a `TextSpan(text: '\n')` separator *between* entries
  at the build site (so adjacent entries still render on their own
  lines, and selection-copy still yields one entry per line), and
  tightens the bottom padding to `EdgeInsets.fromLTRB(12, 12, 12, 8)`.
  Total trailing gutter below the newest entry: ~28 px → ~8 px.

### Packaging

- `screenshots/gui_showcase.png` (820,984 bytes) → `gui_showcase.webp`
  (183,230 bytes, −78%) via `cwebp -lossless -z 9 -m 6`. Output is
  pixel-identical to the source PNG (lossless ARGB, dimensions
  preserved at 1766×2062, alpha intact). `pubspec.yaml`'s
  `screenshots:` entry now points at the `.webp` path. pub.dev's
  screenshot pipeline is WebP-native via pana's `webpinfo` validator,
  so this also skips the server-side `cwebp` round-trip. Tarball
  footprint drops from 835 KB to ~213 KB.

### Verification

- `fvm flutter analyze` (root + `example/`): no issues.
- `fvm dart analyze` (root): no issues.
- `fvm flutter test` (`example/`): 31 / 31 pass.
- `example/main.dart` ↔ `example/example.md` fenced-block byte-for-byte
  parity holds at 5172 bytes.
- `webpinfo screenshots/gui_showcase.webp`: VP8L, 1766×2062, alpha=1.

## 1.1.1

Maintenance release. The public Dart surface (`ntsQuery`, `ntsWarmCookies`,
`NtsServerSpec`, `NtsTimeSample`, `NtsError`) is unchanged.

- Bump the `native_toolchain_rust` build-hook dependency floor from
  `^1.0.3` to `^1.0.4` to pick up upstream fixes shipped in the
  `native_toolchain_rust` 1.0.4 release (pub.dev, 2026-04-27). The
  package has no runtime impact; it runs only inside `hook/build.dart`
  during the Native Assets compile of the bundled Rust crate.
- Refresh `pubspec.lock` and `rust/Cargo.lock` to keep the resolved
  dependency graph aligned with the new floor.
- Patch-bump the internal Rust crate `nts_rust` from `0.2.0` to `0.2.1`
  so the crate version moves in lockstep with the Dart package release.
  The bindings (`lib/src/ffi/`) and Native Assets bridge are unaffected;
  no behavioural changes ship in the Rust core.
- README, example, and dartdoc updates from the previous release stay
  in place; this release adds no new user-facing documentation.

## 1.1.0

Protocol-compliance and reliability hardening across the Rust core. The
public Dart surface (`ntsQuery`, `ntsWarmCookies`, `NtsServerSpec`,
`NtsTimeSample`, `NtsError`) is unchanged; consumer-visible behaviour
improves on the timeout, cookie-cache, and error-classification paths.
Rust crate `nts_rust` is bumped from `0.1.0` to `0.2.0` to mark the
internal protocol-validation tightening; the bindings (`lib/src/ffi/`)
and Native Assets bridge are unaffected.

### NTS-KE handshake (`rust/src/nts/ke.rs`)

- Replace the OS-default TCP connect with a deadline-aware connection
  loop that honours the caller's `timeoutMs`. Earlier releases passed
  the budget only to the read/write side of the socket and let
  `TcpStream::connect` block on the platform default (typically 75 s
  on macOS / 21 s on Linux), which made `ntsQuery(..., timeoutMs: 5000)`
  hang for the full kernel default when the KE endpoint blackholed
  SYNs. The new loop iterates the resolved address list, computes the
  per-attempt deadline from the remaining budget, and surfaces a
  `KeError::Io(ErrorKind::TimedOut)` on the *first* exhausted attempt
  rather than the last. Mapped through `From<KeError> for NtsError` to
  `NtsError.timeout` so the Dart-side switch arm is reached.
- Regression test
  `connect_with_timeout_respects_budget_for_unroutable_ip` exercises
  the deadline against `192.0.2.1` (RFC 5737 TEST-NET-1) and asserts
  the call returns within 1.5× the configured budget.

### Cookie management (`rust/src/api/nts.rs`)

- Introduce a monotonically-increasing `generation: u64` on `Session`
  and propagate it into `QueryContext::session_generation` so each
  in-flight NTPv4 query carries the identity of the handshake that
  produced its cookies. `Session::deposit_cookies` now gates the
  cookie-jar update on a matching generation: cookies extracted from
  a response signed under generation N are silently dropped if the
  session has been re-handshaked to generation N+1 between dispatch
  and receipt. This closes a cross-session poisoning window where a
  late response from a stale session could install cookies bound to
  retired keys, causing the next `ntsQuery` to dispatch
  unauthenticatable cookies and fail the AEAD seal.
- The generation counter is also incremented on every successful
  `Session::rehandshake`, so the stale-cookie filter applies
  symmetrically to both concurrent-query races and explicit
  `ntsWarmCookies` invocations during an in-flight query.

### NTPv4 header validation (`rust/src/nts/ntp.rs`)

- Add `STRATUM_UNSYNCHRONIZED_FLOOR = 16` and reject any post-AEAD
  reply with `stratum >= 16` as `NtpError::Unsynchronized`. RFC 5905
  reserves stratum 16 as the "unsynchronized" sentinel and 17–255 as
  reserved; previous versions only filtered LI=3, so a server in the
  alarm condition could surface a wall-clock offset to the discipline
  loop if it left LI=0.
- Reorder the validation so the Stratum-0 short-circuit (Kiss-o'-Death)
  runs *before* the LI=3 / stratum-ceiling check. Real-world KoD
  packets routinely arrive with LI=3 because the server has no
  synchronised time to advertise; the previous ordering swallowed the
  4-octet kiss code (`RATE`, `DENY`, `RSTR`, `NTSN`, …) into a generic
  `Unsynchronized` error and stripped the diagnostic the caller needs
  to choose a back-off strategy.
- Validation remains positioned *after* AEAD `open()` and the
  origin-timestamp check. `stratum` and the leap indicator are part
  of the NTP AAD, so by this point the server has signed the value;
  off-path attackers cannot forge KoD or stratum-16 to disrupt the
  client. The post-AEAD ordering is pinned by the
  `*_after_seal_*_tamper_as_aead_failure` test family.
- New regression tests:
  - `parse_response_prefers_kod_over_unsynchronized_when_both_set`
    pins the new precedence (Stratum 0 + LI=3 ⇒ `KissOfDeath`).
  - `parse_response_rejects_invalid_high_stratum` pins the new
    stratum-ceiling check (stratum 16 + LI=0 ⇒ `Unsynchronized`).
- Broaden the `Display` arm and rustdoc on `NtpError::Unsynchronized`
  to `"server reports unsynchronized clock (LI=3 or stratum >= 16)"`
  so the diagnostic accurately reflects both triggers; the message
  passes through `NtsError::NtpProtocol(..)` to the Dart side
  unchanged.

### Housekeeping

- `rust/src/nts/records.rs`: replace `body.len() % 2 != 0` with
  `!body.len().is_multiple_of(2)` in `decode_u16_array` to satisfy
  the `clippy::manual_is_multiple_of` lint (warn-by-default in
  clippy 1.92, surfaced once `cargo clippy --all-targets -- -D
  warnings` was added to the release gate). Behaviour is unchanged.

### Verification

- `cargo test --lib`: 95 passed, 0 failed, 3 ignored (live-network).
- `cargo clippy --tests --all-targets -- -D warnings`: clean across
  the workspace.

## 1.0.7

Documentation and published-tarball hygiene. No changes to the published
Dart surface, the Rust crate, or the Native Assets bridge.

- `example/lib/src/state/nts_controller.dart`: prepend a 46-line dartdoc
  block to `runQuery` that documents the NTS-KE cold-start cost
  (TCP + TLS 1.3 + KE handshake + first NTPv4 exchange ≈ 4 RTTs end to
  end, no session-ticket resumption), the steady-state path (cached
  session keys, in-band cookie pool replenishment, ~1 RTT), and the
  attribution boundary (the latency is RFC 8915 protocol overhead, not
  `RustLib.init()`, the Native Assets pipeline, or per-call FFI cost).
  Includes a production note pointing at `example/main.dart`'s
  `ntsWarmCookies()` warm-then-query pattern as the canonical way to
  amortize the cold-start cost; the GUI deliberately does not follow it
  so that the protocol observation tool surfaces the unmasked latency.

- Repository-wide documentation refactor (7 files: `pubspec.yaml`,
  `analysis_options.yaml`, `DEVELOPMENT.md`, `README.md`,
  `example/.pubignore`, `example/README.md`, `tool/check_bindings.dart`)
  to replace meta-commentary about pub.dev scorecards, `pana` rubrics,
  and tag-drop heuristics with objective technical justifications. The
  platform allow-list now reads as RFC 8915's raw TCP/UDP requirement
  plus rustls+ring's lack of a wasm32 target; the FRB pin is justified
  by the silent-memory-corruption risk of a wire-format mismatch; the
  analyzer-exclude removal is justified by lockstep with the consumer's
  analyzer view; the `// ignore_for_file:` directives in `lib/src/ffi/**`
  are justified by `public_member_api_docs` being enabled and the FFI
  surface not being excluded. The IANA AEAD-registry reference in
  `example/GUI_GUIDE.md` is preserved as a legitimate protocol citation.

- `.pubignore` (new, root): introduce a root `.pubignore` that mirrors
  the root `.gitignore` patterns (per dart.dev/go/pubignore, a
  directory's `.pubignore` replaces its `.gitignore` for publish
  purposes) and additionally excludes consumer-irrelevant files:
  `AGENTS.md`, `CLAUDE.md` (AI-agent guidance), `ARCHITECTURE.md`,
  `DEVELOPMENT.md` (self-identified contributor-only documentation),
  `analysis_options.yaml` (consumer analyzers read the consumer's own
  config), `flutter_rust_bridge.yaml` (FRB codegen config; bindings ship
  pre-generated), `tool/` (CI drift check for FRB regeneration), and
  `test/` (internal FFI smoke test, not a public-API verifier).

- `example/.pubignore`: add `analysis_options.yaml` and `test/` to the
  example's exclusion list for the same reasons as the root. The
  canonical consumer entry point remains `example/main.dart`.

- Net effect verified via `dart pub publish --dry-run`: the published
  tarball drops from 840 KB (1.0.6) to 824 KB, twelve maintainer-only
  files are stripped, and the warning/hint output is unchanged. No
  source files in `lib/`, `rust/`, or `hook/` are touched, so the
  binding drift gate and Native Assets build hook are unaffected.

## 1.0.6

Binding regen consequent on the 1.0.5 analyzer-exclude removal. No
changes to the published Dart surface, the Rust crate, or the Native
Assets bridge.

- `lib/src/ffi/frb_generated.dart`: regenerate against the current
  `analysis_options.yaml`. Removing the `analyzer.exclude:
  [lib/src/ffi/**]` block in 1.0.5 had a side effect that
  the bindings CI job did not surface until the next commit that
  re-triggered the job: `flutter_rust_bridge_codegen` runs an
  analyzer-aware fix-up over the Dart it emits before exiting, that
  pass was a no-op while the FFI files were excluded, and with the
  exclude gone the pass applies `prefer_final_locals` and
  `prefer_const_constructors` to the synthesized dispatcher
  boilerplate. The committed file (last regenerated in 1.0.2,
  `0349077`) was therefore stale relative to the codegen's
  deterministic output. The regen is purely cosmetic — `var` locals
  inside `dco_decode_nts_error` / `sse_decode_*` become `final`, and
  the two nullary `NtsError` variants gain `const` prefixes — and
  produces no wire-format or public-API change. The file-level
  `// ignore_for_file:` directives managed by
  `tool/check_bindings.dart` still suppress both rules so future
  codegen output that emits a non-final local or non-const
  constructor remains acceptable to pana without re-failing the
  drift gate.

## 1.0.5

Example clarity and pub.dev metadata fidelity. No changes to the
published Dart surface, the Rust crate, or the Native Assets bridge.

- `example/main.dart`: switch the minimal sample from a single
  `ntsQuery()` call to a warm-then-query flow that calls
  `ntsWarmCookies()` first and then `ntsQuery()`. The original
  one-call form lumped the NTS-KE handshake into the same latency
  budget as the NTPv4 exchange and never made the cookie pool
  visible; the new form mirrors the production access pattern,
  surfaces the `cookies_remaining` counter on `NtsTimeSample`, and
  gives readers a self-contained reference for both stages of the
  protocol. `example/example.md` is regenerated as a byte-for-byte
  fenced mirror so the pub.dev Example tab tracks the runnable
  sample. The exhaustive `NtsError` switch and the `RustLib.init()`
  bootstrap order are unchanged.

- `example/example.md`: drop the developer-facing meta-commentary
  about the rendering quirk that motivated the file's existence
  (`pana` priority list, the `example/main.dart` shadowing dance from
  1.0.3 / 1.0.4). The fenced sample is the consumer-visible artefact;
  the rendering history is recorded in this changelog, not in the
  file pub.dev publishes.

- `analysis_options.yaml`: remove the
  `analyzer.exclude: [lib/src/ffi/**]` block so local
  `dart analyze` / `flutter analyze` runs see the same surface
  pana sees on pub.dev. The FRB-generated files in `lib/src/ffi/`
  carry file-level `// ignore_for_file:` directives (managed by
  `tool/check_bindings.dart` and landed in 1.0.2) for the rules they
  cannot satisfy, which pana respects but `analyzer.exclude` does not
  — keeping both meant local CI was strictly more permissive than the
  pub.dev scorecard. With the exclude removed, lint drift between
  the two environments is impossible.

- `pubspec.yaml`: add a top-level `platforms:` allow-list with
  `android`, `ios`, `macos`, `linux`, `windows`. Earlier releases
  shipped without this block, which let pana award the `web` and
  `wasm` platform tags on the strength of the Dart surface compiling
  cleanly under `dart2js` / `dart2wasm` — but actual runtime use of
  any nts API on Web cannot work, because RFC 8915 needs raw TCP for
  NTS-KE on `:4460` and raw UDP for NTPv4 on `:123` (neither of which
  browsers expose to web pages), and the `rustls` + `ring` +
  `rustls-platform-verifier` stack does not target
  `wasm32-unknown-unknown`. Declaring the supported platforms
  explicitly drops both incorrect tags from the next pana rescore so
  the pub.dev scorecard reflects the package's true platform surface.

## 1.0.4

pub.dev Example tab fix (take two). No runtime changes.

- Add `example/example.md` containing the minimal NTS-KE sample as a
  fenced ```dart block plus a pointer to the Flutter GUI showcase at
  `example/lib/main.dart`. The 1.0.3 rename of the minimal sample to
  `example/main.dart` did not unblock the Example tab: empirical check
  on the published version-pinned URL still rendered
  `example/lib/main.dart`. The bracket notation
  `example[/lib]/main.dart` in dart.dev's package-layout doc is
  shorthand for two **separate** slots in pana's selection list, with
  the `lib/` form ranked **higher** than the bare form. The actual
  list lives in
  [`pana/lib/src/maintenance.dart`](https://github.com/dart-lang/pana/blob/master/lib/src/maintenance.dart):

  1. `example/README.md`
  2. **`example/example.md`** ← new in 1.0.4, secures the slot
  3. `example/lib/main.dart` (GUI showcase, no longer rendered)
  4. `example/bin/main.dart`
  5. `example/main.dart` (1.0.3 rename target, also no longer rendered)

  Slot 2 beats slot 3, so the new `example/example.md` finally wins
  over `example/lib/main.dart`. The minimal sample at
  `example/main.dart` stays in the archive as the runnable Flutter
  target; the `.md` is just a syntactic mirror so pub.dev picks it.

- No changes to the published Dart surface, the Rust crate, or the
  Native Assets bridge. The two new lines in `pubspec.yaml` and
  `CHANGELOG.md` are the only metadata edits.

## 1.0.3

pub.dev Example tab fix. No runtime changes.

- Rename `example/example.dart` to `example/main.dart` so pub.dev's
  Example tab renders the intended minimal single-call sample. pub.dev
  picks the rendered file from a hardcoded priority list documented
  at <https://dart.dev/tools/pub/package-layout#examples>; the previous
  layout placed the minimal sample at priority 5
  (`example[/lib]/example.dart`) where it was shadowed by the Flutter
  GUI showcase at priority 2 (`example/lib/main.dart`). The bare
  `example/main.dart` slot also sits at priority 2 but wins over the
  `lib/` variant, so the rename promotes the minimal sample without
  removing the GUI showcase from the published tarball.
- Update `example/README.md` to spell the GUI entry point explicitly
  as `flutter run -t lib/main.dart` (or `-t example/lib/main.dart`
  from the repo root) so contributors don't accidentally launch the
  new top-level `example/main.dart` as the Flutter target.
- Update root `README.md` and `ARCHITECTURE.md` to reference the new
  path. The 1.0.1 changelog entry that introduced
  `example/example.dart` is left unchanged for historical accuracy.

## 1.0.2

Static-analysis score recovery. No runtime changes.

- Suppress pana-only lints across the FRB-generated bindings via the
  `// ignore_for_file:` directive of each file, applied as a post-codegen
  patch step in `tool/check_bindings.dart`. pana's static-analysis run
  uses a stricter ruleset than `flutter_lints` and surfaced 117+ INFO
  lints against the synthesized freezed wrappers (`NtsError`),
  auto-generated default constructors (`NtsServerSpec`, `NtsTimeSample`),
  and dispatcher boilerplate that FRB cannot back with Rust docstrings,
  costing 10 pub points. Patched files and rules:
  - `lib/src/ffi/api/nts.dart`: `public_member_api_docs`.
  - `lib/src/ffi/frb_generated.dart`: `public_member_api_docs`,
    `prefer_final_locals`, `prefer_const_constructors`.
  - `lib/src/ffi/frb_generated.io.dart`: `public_member_api_docs`.
  - `lib/src/ffi/frb_generated.web.dart`: `public_member_api_docs`.
  Local `pana 0.23.12` now reports 160 / 160 against the working tree.

## 1.0.1

Documentation and pub.dev metadata polish. No runtime changes.

- Restructure README around a What → Why → How flow and offload the
  Rust toolchain, build hooks, and crate breakdown into new
  `ARCHITECTURE.md` and `DEVELOPMENT.md` reference documents.
- Add a self-contained `example/example.dart` for pub.dev's Example
  tab.
- Resolve two `dartdoc` unresolved-reference warnings in
  `lib/src/ffi/api/nts.dart` by replacing Rust intra-doc link syntax
  with literal values in the upstream Rust docstrings and regenerating
  the bindings.
- Trim the package description to fit pana's 180-char ceiling, add
  five pub.dev topics (`ntp`, `time`, `networking`, `security`,
  `cryptography`), and register `screenshots/gui_showcase.png` as the
  package listing screenshot.
- Expand the inline comment on the `flutter_rust_bridge: 2.12.0` pin
  to document the wire-format rationale and the accepted pana
  warning.

## 1.0.0

Initial stable release.

### Protocol

- Network Time Security (RFC 8915) client implementing the full NTS-KE
  handshake (TLS 1.3, ALPN `ntske/1`, port 4460) followed by
  AEAD-protected NTPv4 (RFC 5905) over UDP/123.
- AEAD algorithms: AES-SIV-CMAC-256 (IANA ID 15, default) and
  AES-128-GCM-SIV (IANA ID 16), negotiated during NTS-KE.
- Cookie management: in-memory cookie jar with automatic refresh via
  `ntsWarmCookies()` when the pool is exhausted.

### API

- `ntsQuery({required NtsServerSpec spec, required int timeoutMs})`
  returns `Future<NtsTimeSample>` with server transmit time, round-trip
  duration, stratum, negotiated AEAD ID, and fresh cookie count.
- `ntsWarmCookies({required NtsServerSpec spec, required int timeoutMs})`
  forces a fresh handshake and reports the number of cookies received.
- `NtsError` sealed class with eight typed variants
  (`invalidSpec`, `network`, `keProtocol`, `ntpProtocol`,
  `authentication`, `timeout`, `noCookies`, `internal`) for exhaustive
  pattern matching.

### Implementation

- Cryptographic core implemented in Rust (`rustls` for TLS 1.3,
  `aes-siv` / `aes-gcm` for AEAD, `ring` for primitives).
- Bridged to Dart via `flutter_rust_bridge` 2.12.0 (pinned exactly to
  match the Rust crate's wire format).
- Bundled through the stable Native Assets API (`hook/build.dart` +
  `native_toolchain_rust`); no manual `cargo` invocation required from
  consumers.

### Platform support

Android, iOS, macOS, Linux, Windows. Web is not supported (no UDP
socket primitive in the browser).

### Build

- Default release builds use the `log-strip` Cargo feature, eliding
  `info!` / `debug!` / `trace!` format strings at compile time;
  `warn!` and `error!` survive for diagnostics.
- The `verbose_logs` user-define in `pubspec.yaml` opts into a debug
  build with full logging (including `rustls` protocol traces) for
  development.

### Tooling

- `tool/check_bindings.dart` regenerates FRB bindings and fails CI if
  the committed Dart bindings or `rust/src/frb_generated.rs` drift
  from the generator output.
- CI matrix exercises both the declared SDK floor (Flutter 3.38.10 /
  Dart 3.10.9) and the pinned development version (Flutter 3.41.7 /
  Dart 3.11.5).

### Requirements

- Dart `^3.10.0`, Flutter `>=3.38.0`. The lower bound matches the
  `hooks` package (`>=1.0.3`) requirement.
- Native Assets API (stable since Flutter 3.24).

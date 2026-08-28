# Changelog

Entries for `5.2.4` and earlier live in
[CHANGELOG_ARCHIVE.md](https://github.com/nick-llewellyn/nts/blob/main/CHANGELOG_ARCHIVE.md),
which is kept in the repository but excluded from the published
tarball.


## 9.3.0

### Changed

- Bump the exact `flutter_rust_bridge` pin from `2.12.0` to `2.13.0` in
  both `pubspec.yaml` and `rust/Cargo.toml`, and regenerate
  `lib/src/ffi/**` and `rust/src/frb_generated.rs` against
  `flutter_rust_bridge_codegen 2.13.0`
  ([#320](https://github.com/nick-llewellyn/nts/issues/320)). Apps on
  `flutter_rust_bridge: ^2.13.0` could not resolve against the old pin.
  The pin stays exact — the Dart codegen output and the Rust runtime
  crate share a wire format whose stability across minors upstream does
  not guarantee, and a mismatch corrupts memory silently rather than
  failing loudly.
- `NtsBridge.dispose()` is now a de-initialization. `flutter_rust_bridge`
  2.13.0 clears the entrypoint's state before disposing it, where 2.12.0
  disposed in place and kept it. So `NtsBridge.state` reads
  `NtsBridgeState.uninitialized` after a disposal rather than being
  unchanged. `NtsBridge.dispose()` now drops its own initialization
  latch to match: without that, a later
  `NtsBridge.ensureInitialized()` would hand back the latched completed
  future and report success over a bridge holding nothing. Callers that
  dispose and then re-initialize get a genuine second attempt; callers
  that never dispose are unaffected. (The wrapper's early return for an
  uninitialized bridge is unchanged and predates this. Under 2.12.0 it
  shielded callers from the `StateError` the raw `NtsRustLib.dispose()`
  threw in that case; 2.13.0 made that raw call a no-op when nothing is
  installed, so the two now agree.) The dartdoc also now states that
  disposing while an `ensureInitialized()` is in flight is unsupported,
  and names the two windows in which it misbehaves.
- The raw `NtsRustLib.dispose()` is a de-initialization too, and
  `NtsBridge.ensureInitialized()` now recovers from one. The entrypoint
  is exported, so a caller can clear its state without going through
  `NtsBridge.dispose()` — harmless under 2.12.0, where disposal kept the
  state, but under 2.13.0 it strands the wrapper's latch over a bridge
  holding nothing. The stale latch is detected and discarded, so the
  next call runs a fresh attempt. Disposal *during* an unawaited
  `ensureInitialized()` remains unsupported, as it is for
  `NtsBridge.dispose()`.

### Internal

- The generated bindings pick up two upstream codegen changes, both
  cosmetic: the `Result::<_, ()>::Ok(...)` construction is now written
  `Ok::<_, ()>(...)` with the return qualified as
  `std::result::Result::Ok`, and `frb_generated.rs` carries a new
  `mismatched_lifetime_syntaxes` allow. `rustContentHash` is unchanged
  as well, but that is not evidence of wire-format stability: codegen
  derives it from the sorted bridged function names and nothing else,
  so it guards against a Dart/Rust function-set mismatch rather than
  against a signature, codec, or runtime-behaviour change.
- `native_toolchain_rust` stays at `^1.0.4`. From 1.0.5 onward it
  requires `hooks ^2.1.0`, which pulls `record_use ^1.0.0` and therefore
  `meta ^1.19.0`; the Flutter SDK pins `meta` exactly, and neither the
  oldest supported Flutter (3.38.0, `meta` 1.17.0) nor current stable
  (3.44.6, `meta` 1.18.0) satisfies that, so the bump makes version
  solving fail outright. The pubspec records the constraint inline.
- `rust/fuzz/Cargo.lock` moved to 2.13.0 alongside the main workspace
  lock. The fuzz workspace is standalone and depends on `nts_rust` by
  path, so the new exact constraint would have failed the nightly
  `--locked` fuzz build against the stale 2.12.0 resolution.
- Two CI gates needed adjusting for the bump. The `rust-bridge-sync`
  codegen install now passes `--force`: its cache key is
  version-scoped, but `Swatinem/rust-cache` restores `~/.cargo/bin`
  wholesale and can put the previous pin's binary back first, so cargo
  refused with "binary already exists in destination" on the first run
  after a bump. And `dependency-review` gained a
  `pkg:pub/flutter_rust_bridge` carve-out — the motivation is not a
  licence exception, since the package is MIT and already allowed, but
  pub.dev publishes the field as the lowercase non-SPDX string `mit`,
  which the action cannot validate and so fails closed on.
  `allow-dependencies-licenses` is package-scoped, though, so the entry
  drops FRB from licence evaluation entirely and any licence a future
  release declares would pass unexamined; the workflow comment records
  that blind spot and requires a manual re-check on each pin bump. The
  duplicate-casing entries in that list also went away: purl matching
  became case-insensitive in v4.9.0, which the pinned v5.0.0 includes.
- `DEVELOPMENT.md`'s CI job inventory said `ci.yml` defines eight jobs
  when it defines eleven, and the table below it had no rows for
  `doc-snippets` or `cargo-deny`. Count corrected, both rows written,
  and the doc-only skip list in the lead-in prose extended to
  `cargo-deny` and `android-kgp-gate`.
- Add two rules to the versioning policy in `AGENTS.md`. A runtime
  behaviour change to a public Dart API — existing callers still
  compile and still resolve, but observe a different return value,
  post-condition, error, or lifecycle outcome — now requires a major
  bump, and neither "an upstream dependency forced it" nor a narrow
  affected surface is an exemption. Shipping one as a minor is still
  permitted but becomes an explicit deviation: reasoned in the release
  PR, described by blast radius in the changelog, and recorded in an
  issue. A tightened dependency constraint that only breaks resolution
  is excluded — it fails at solve time before any code runs. This
  release's `dispose()` change is named in the policy as the founding
  case for the deviation, since cutting `10.0.0` here would strand
  every consumer on a `^9` constraint behind the resolution bug this
  release exists to fix. The reviewer-facing mirrors in
  `.github/copilot-instructions.md` and
  `.github/skills/code-review/architecture.md` carry the check too, so
  it applies on release PRs rather than living only in the policy
  document.
- Bump the pinned Rust toolchain in `rust/rust-toolchain.toml` from
  `1.97.1` to `1.98.0` (released 2026-08-20). The FRB bindings are
  in sync under the new pin with no regeneration needed, and the MSRV
  in `rust/Cargo.toml` is unchanged. `clippy::from_iter_instead_of_collect`
  was dropped from the lint table in `rust/Cargo.toml` — 1.98.0 removes
  the lint upstream, and leaving the key emits a
  `renamed_and_removed_lints` warning that `-D warnings` promotes to a
  hard error. Allowing that lint instead would silence the same
  diagnostic for every future rename, so the stale key was removed
  rather than muted. Nothing replaces it — the retained
  `format_collect` flags
  `map(format!(..)).collect::<String>()`, not the explicit
  `FromIterator::from_iter(..)` calls the removed lint checked. The
  crate has no such call sites, so the removal costs no coverage here.
- Cap the example app's `share_plus` constraint at `>=13.1.0 <13.2.0`.
  From `13.2.0` the plugin's Android build script configures
  `KotlinAndroidProjectExtension` unconditionally and skips applying the
  Kotlin Gradle Plugin whenever AGP is 9 or newer, so it depends on
  Flutter's Built-in Kotlin to register that extension. The example pins
  AGP `9.2.1`, and Built-in Kotlin only arrived in Flutter `3.44`, but
  `share_plus` still declares `flutter: '>=3.38.1'` — so pub resolves it
  on the example's `3.38.x` floor and Gradle then fails to configure
  with `Extension of type 'KotlinAndroidProjectExtension' does not
  exist`. CI never saw it: the `3.38.10` matrix leg runs only `pub get`,
  `analyze`, and `test`, and `android-kgp-gate` configures the `:nts`
  module standalone without a Flutter SDK. The cost of the cap is that
  the Built-in Kotlin deprecation warning returns for `share_plus` on
  current stable; keeping the floor buildable takes priority, and the
  cap lifts once the floor reaches `3.44` — or sooner, if `share_plus`
  corrects its declared `environment.flutter` so the incompatibility
  becomes solver-visible rather than a Gradle-time failure.
  `shared_preferences_android` needed no cap — it raised its own floor
  to `3.44` in `2.4.24`, so pub correctly holds it at `2.4.23` on the
  old SDK and takes `2.4.27` on stable, which clears its half of the
  warning. Example app only; no package API change.
- Accept the Flutter 3.47 analyzer migration in `analysis_options.yaml`
  and `example/analysis_options.yaml`
  ([#328](https://github.com/nick-llewellyn/nts/pull/328)). Flutter
  3.47's `pub get` inserts an `analyzer.exclude` block covering `build/`
  and every platform directory, and re-applies it unconditionally on
  every run — declining it leaves a permanently dirty working tree for
  anyone who runs `pub get` before `analyze`. Once accepted it is
  idempotent. No `.dart` files live under any excluded path in either
  package, so the analyzed file set is unchanged and both packages still
  report no issues. The generated blocks are repositioned so they do not
  split the `include:` comment from `include:` in the example, or sit
  directly beneath the root file's note about what is deliberately *not*
  excluded.
- Accept the Flutter 3.47 Xcode project regeneration in the example app
  ([#329](https://github.com/nick-llewellyn/nts/pull/329)). Building
  the example on a physical iOS device or on macOS under 3.47.1 raises
  `IPHONEOS_DEPLOYMENT_TARGET` from 14.0 to 15.0 and
  `MACOSX_DEPLOYMENT_TARGET` from 10.15 to 12.0 across all three build
  configurations, and adds the standard `Pods/Pods.xcodeproj` reference
  to the iOS workspace. The new floors are Flutter 3.47's own minimums,
  so declining them leaves the tree dirty after every Apple-platform
  build, and the generated (gitignored) `example/macos/Podfile` already
  carried the 12.0 floor, so the `.pbxproj` files were the stale side of
  the inconsistency. Example-only: the package ships no podspec — Apple
  support goes through Native Assets — so nothing in the published
  package declares or inherits these floors.
- Declare `lib.name` explicitly in `rust/Cargo.toml`
  ([#330](https://github.com/nick-llewellyn/nts/pull/330)).
  `native_toolchain_rust` 1.0.6 reads `lib.name` from the manifest and,
  when it is absent, logs the failed lookup at SEVERE with a full stack
  trace before falling back to `package.name`; the fallback itself logs
  at FINE and is invisible, so every native-assets build printed one
  `type 'Null' is not a subtype of type 'String'` trace per target
  triple — six on an Android build — for a non-event. Cargo already
  defaulted the library name to `package.name`, so the declared value is
  identical and the emitted artefacts are unchanged: verified by
  rebuilding the example with the hook cache cleared, which emits the
  same `libnts_rust.so` for all three Android ABIs and the same
  `nts_rust.framework` on macOS.
- Raise the example app's Kotlin Gradle Plugin floor from 2.2.20 to
  2.3.20 ([#331](https://github.com/nick-llewellyn/nts/pull/331)).
  Flutter's `DependencyVersionChecker` pins `errorKGPVersion` at 2.2.20
  and `warnKGPVersion` at 2.3.20, so the example sat exactly on the
  error floor and every Android build printed "Flutter support for your
  project's Kotlin version (2.2.20) will soon be dropped". 2.3.20 clears
  the warning and stays within Flutter's documented compatibility range
  for AGP 9.2.1. Example-only: the published package pins no KGP
  version — `android/build.gradle.kts` resolves whatever the host app
  puts on the classpath. `tool/test_android_kgp_gate.sh` reads the
  version off `example/android/settings.gradle.kts`, so the CI gate
  matrix follows without a second edit; all eight assertions still pass.
- Move release notes for `5.2.4` and earlier into
  `CHANGELOG_ARCHIVE.md`, leaving `6.0.0` onwards in `CHANGELOG.md`.
  The published changelog had grown back to 212 KB — pub.dev renders
  the whole of it on the package page, and it was again the largest
  file in the tarball. The cut halves it to 108 KB. This is the second
  pass of the same exercise the `9.0.0` release performed at the
  `1.4.0` boundary; the archive is tracked in git and excluded from
  the tarball via `.pubignore`, so nothing is deleted — the entries
  only move. `6.0.0` is the boundary because it is the oldest release
  whose breaking change (the removal of the pre-3.0 `NtsError` typedef
  aliases) a consumer on a supported constraint could still be
  migrating past. The preambles in both files, the README's
  "Upgrading" section, and the `.pubignore` rationale comment record
  the new cutoff, and both files stay covered by the doc-snippet
  validator on the same terms as before.

### Documentation

- Add a "Version compatibility" section to `README.md` recording why
  the `flutter_rust_bridge` dependency is an exact pin — the generated
  Dart and the Rust runtime crate share a wire format that upstream
  does not guarantee across minors, and a mismatch corrupts memory
  silently rather than failing loudly — plus the version mapping
  (`nts` 9.3.x requires `2.13.0`; 9.2.x and earlier require `2.12.0`)
  and the guidance to match the constraint rather than reach for
  `dependency_overrides`.
- Reference the pull requests that carried the Flutter 3.47 toolchain
  work rather than the internal tracker issues
  ([#334](https://github.com/nick-llewellyn/nts/pull/334)). A
  `linear.app` link requires workspace membership, so on the pub.dev
  package page it named the work without letting anyone read it. The
  convention is now recorded in `AGENTS.md` and summarised in
  `CONTRIBUTING.md`: consumer-facing prose cites the public GitHub
  pull request or issue, linked in full because pub.dev renders the
  changelog outside the context that auto-links a bare `#N`.

## 9.2.1

### Fixed

- The plugin's Android module gated application of the standalone
  Kotlin Gradle Plugin on `android.builtInKotlin` alone, which is not a
  free variable once `android.newDsl=true`
  ([#316](https://github.com/nick-llewellyn/nts/issues/316), follow-up
  to [#313](https://github.com/nick-llewellyn/nts/issues/313)). Under
  the new DSL, AGP does not register the legacy
  `com.android.build.gradle.BaseExtension`, and KGP casts the `android`
  extension to exactly that type as it applies itself — so a host with
  `android.newDsl=true` and `android.builtInKotlin=false` got a
  `ClassCastException` pointing at this package's build script. AGP only
  warns about that combination, so the cast failure was the first hard
  signal. `android.newDsl` is now read alongside
  `android.builtInKotlin`, and the unsupported pairing is rejected up
  front with a message naming both properties and the fix. The example
  app's `android/app/build.gradle.kts` carries the same gate.

### Internal

- `tool/test_android_kgp_gate.sh` configures the plugin's Android module
  standalone — no app project, no Flutter Gradle Plugin — across the
  `android.newDsl` / `android.builtInKotlin` matrix, asserting both the
  configuration outcome and whether the standalone Kotlin plugin ended
  up applied. The example app cannot cover the `newDsl=true` legs: its
  `:app` project fails to configure under the new DSL because the
  Flutter Gradle Plugin resolves the legacy `BaseExtension` with a
  non-null assertion (flutter/flutter#180137), so isolating the module
  is what makes those legs testable ahead of that upstream work. Wired
  into CI as the `android-kgp-gate` job behind a new `android` path
  filter (`android/**`, `example/android/**`, and the harness itself).

## 9.2.0

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
    Arguments configure the attempt a call actually starts; a call that
    joins a latched attempt, or finds the bridge already initialised,
    ignores them.
  - `NtsBridge.state` reports `NtsBridgeState.uninitialized`, `.mock`,
    or `.native`. This is the discrimination consumers previously had
    to reach into FRB's `@internal` `instance` / `api` members to
    obtain — `MonotonicClock` and the example CLI loader both did, each
    with an `invalid_use_of_internal_member` ignore, and both now
    switch on the enum instead. The mock/native split is structural, on
    `api is BaseApiImpl`, not on the initialisation route: a
    hand-written double reads as `.mock` however it was installed, and
    the generated implementation reads as `.native` even when supplied
    to `initMock()`.
  - Public member dartdocs that stated the initialisation requirement
    as `NtsRustLib.init()` now name `NtsBridge.ensureInitialized()`
    (`NtsClient` and its synchronous members, `ntsDnsPoolStats`,
    `ntsTrustStats`, the `TrustMode` example). `NtsRustLib.init()` is
    still exported and still described where the underlying step is the
    point.
  - `NtsBridge.dispose()` releases the bridge's Dart-side resources, or
    does nothing when it was never initialised. `NtsRustLib.dispose()`
    throws in that case. Disposal is not de-initialisation: `state` is
    unchanged afterwards.
  - A failed `ensureInitialized` attempt retains its latch — replaying
    the error to every later caller — only when the attempt itself took
    ownership of the entrypoint, which it can only ever do by
    installing the generated API. A `.mock` observed after the failure
    can only have come from an independent `NtsRustLib.initMock()`,
    which is an initialisation that *succeeded*; the latch is dropped
    in that case so a later caller completes over the usable mock
    instead of failing on a stale native-load error.
  - `ensureInitialized`'s dartdoc states that driving the raw
    entrypoint *concurrently* with it is unsupported in either
    direction, and why neither case is detectable. A concurrent
    `NtsRustLib.init()`: FRB installs the entrypoint state before
    awaiting its Rust initializers, so the wrapper can see `.native`
    and complete while the direct call is still running, and a failure
    it then suffers is invisible; FRB exposes no way to await someone
    else's attempt. A concurrent `NtsRustLib.initMock()` supplying the
    *generated* implementation: that also reads as `.native`, hence is
    indistinguishable from state the wrapper installed itself, so a
    failure of the wrapper's own attempt would be replayed over a
    bridge that is in fact usable. (A hand-written double is not
    affected — it reads `.mock`, which is attributable to someone
    else.) The dartdoc also records the one case a *completed* direct
    call leaves behind: an `init()` that threw from its Rust
    initializers leaves the entrypoint installed and permanently
    unusable, and `ensureInitialized` reports success over it, because
    FRB records nothing about the failure and the attempt was never
    latched. That error is the direct caller's to keep.
  - The live suite (`test/live/nts_live_test.dart`) bootstraps through
    `ensureInitialized()` rather than `NtsRustLib.init()`, and asserts a
    repeat call completes with `state == .native`. That covers the
    fresh-success branch, which no mock-only test can reach: it needs a
    real library whose Rust initializers actually run. The mock-only
    suite covers the already-installed and failed-load branches.
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

- **Behavioural: `offsetMicros` and `peerDelayMicros` read lower than
  on 9.1 for the same exchange.** T1, the RFC 5905 client transmit
  timestamp, is now stamped immediately before the C2S AEAD seal that
  builds the request packet, after the UDP socket is bound and
  connected. It previously preceded both the packet build and the
  bind, while `roundTripMicros` was anchored at the `send` that
  follows the bind, so the two intervals had different start points:
  the peer delay δ = (T4−T1)−(T3−T2) carried the bind and the
  NTPv4-host DNS lookup that the round trip excluded, and θ carried
  half of that interval as apparent offset. Measured against the
  bundled server catalog, δ ran 1–9% *above* `roundTripMicros` on
  every healthy sample — enough that the `(0, roundTripMicros]`
  selection window `ntsGetTime` applies rejected δ in practice and the
  `roundTripMicros` fallback was the branch always taken. δ and the
  round trip now share an anchor, separated only by the request build
  and seal and the
  socket write-timeout re-arm that bounds the send against the call's
  remaining budget — the build and seal memcpy-scale over a packet of a
  few hundred bytes, the re-arm a single
  non-blocking syscall, neither waiting on I/O; the window admits δ on
  healthy samples under ordinary scheduling. It is not reserved solely for implausible exchanges: the
  worker can still be preempted between T1 and the send, so a loaded
  host can select the fallback on a healthy sample. That selection
  excludes a real bias rather than discarding a clean measurement —
  any interval `p` between T1 and the send adds `p` to δ and `p/2` to
  `offsetMicros`, the same arithmetic that made the pre-9.2 ordering a
  bias, and the fallback keeps the `p` out of the delay the
  compensation halves. It does not undo the `p/2` in θ. Callers
  that recorded absolute `offsetMicros` or `peerDelayMicros` values
  from 9.1 or earlier should expect a small downward shift, and any
  consumer that widened its own δ upper bound to accommodate the setup
  interval — as the example health prober did — can tighten it to an
  allowance measured on its own targets. `ntsGetTime`'s synchronized
  UTC is unaffected in direction: it compensates by half the selected
  delay either way, but now selects the tighter of the two estimates.
- The example health prober's per-sample θ gate
  (`example/lib/src/health/probe.dart`) tightened accordingly: the
  allowance over `roundTripMicros` is now a flat 5 ms ceiling covering
  the whole pre-send interval — building and sealing the request packet,
  and the socket
  write-timeout re-arm, neither of which blocks on I/O. It previously
  added the sample's own
  `phaseTimings.dnsMicros`, gated on an inference about whether the
  query had re-handshaked (since that field sums both lookups a query
  can make and only the NTPv4-host one fell inside the pre-send
  interval). No lookup falls between T1 and the send now, so both the
  DNS term and the inference are gone.

### Fixed

- Android hosts on AGP 9 / Kotlin 2.2+ toolchains failed to compile
  `android/build.gradle.kts` (the plugin's Android module) with a
  script-compilation error rather than a warning
  ([#313](https://github.com/nick-llewellyn/nts/issues/313)). Three
  deprecations landed as hard errors: the classic `android { ... }`
  extension-function accessor is deprecated once
  `android.newDsl=true`, the AGP 9 default; `kotlinOptions { jvmTarget
  = ... }` had its deprecation level raised to `ERROR` in Kotlin
  2.2.0; and `AndroidSourceDirectorySet.srcDirs(...)` is deprecated in
  favor of the `directories` mutable set. The module now applies
  `org.jetbrains.kotlin.android` only when built-in Kotlin is not in
  effect. Gating on the resolved AGP major version alone is not
  sufficient, since AGP 9 still supports `android.builtInKotlin=false`
  (and this package's Flutter 3.38 floor has no fallback that applies
  KGP on that compatibility path), so the effective
  `android.builtInKotlin` Gradle property is checked too. The module
  also configures the `android` extension via
  `configure<LibraryExtension> { ... }`, moves `jvmTarget` to
  `kotlin.compilerOptions` behind a
  `plugins.withId("org.jetbrains.kotlin.android")` guard, and adds to
  `java.directories` instead of calling `srcDirs(...)`. Verified
  against both AGP 8.11.1 (the example app's previous pin, unaffected)
  and AGP 9.2.1 with `android.builtInKotlin=false` (Flutter 3.44's
  current forced default). The `android.newDsl=true` /
  `android.builtInKotlin=true` combination was verified for the plugin's
  Android module in isolation, not end to end through an app build: no
  Flutter app can configure under `android.newDsl=true` today, because
  the Flutter Gradle Plugin itself resolves the legacy `BaseExtension`
  with a non-null assertion (flutter/flutter#180137). The example app's own
  `android/app/build.gradle.kts` follows the same pattern, and its AGP
  pin moved to 9.2.1 with the Gradle wrapper on 9.7.1.
- The UDP socket's write timeout is now re-armed against the call-wide
  deadline immediately before the `send`, matching the re-arm the
  `recv` already had. The bind-time value is anchored at bind
  completion, and the T1 stamp and the C2S seal now sit between that
  anchor and the `send`; the seal does no I/O, but the worker can be
  preempted across it, so the bind-time value was stale by an
  unbounded amount. A blocking `send` could therefore run for the full
  bind-time budget on top of the time already spent, overshooting the
  single wall-clock budget `timeout` documents. An already-lapsed
  budget now fails with `NtsError.timeout(TimeoutPhase.ntp)` instead of
  putting a packet on the wire the caller has stopped waiting for.
- The AES-SIV-CMAC paths (AEAD IDs 15 and 17) migrated to the
  `aes-siv` 0.8 API, completing the move of both SIV families onto the
  RustCrypto `hybrid-array` traits line. The crate dropped its
  `aead::generic_array` re-export, so `SivKey::cipher` and
  `SivKey512::cipher` construct the key array via the infallible
  `&[u8; N]` conversion instead of `GenericArray::from_slice`, and the
  `aes_gcm_siv::KeyInit` import is no longer needed now that
  `aes_siv::KeyInit` is the same trait. The dependency also gains an
  explicit `zeroize` feature: 0.7 wiped `Siv::encryption_key` in
  `Drop` unconditionally, 0.8 gates that wipe behind an optional
  dependency absent from `default`, so a `default-features = false`
  build that carried the old feature list forward would have dropped
  the wipe of the key copy each `cipher()` call makes — silently, with
  nothing failing to flag it. A new compile-time assertion pins
  `Aes128Siv` and `Aes256Siv` as `ZeroizeOnDrop` so removing the
  feature again fails to build. With that in place there is no
  behavioural change: key handling, the zeroization derives, and the
  wire format are untouched. With `aes-siv` off the old line, the
  `multiple-versions` gate in `cargo deny` sheds six version-pinned skips
  (`aead`, `aes`, `cipher`, `cpufeatures`, `ctr`, `inout`); the
  remaining duplicates — `block-buffer`, `crypto-common`, and now
  `digest` — are held by `flutter_rust_bridge_macros -> md-5 ->
  digest 0.10` and expire when that chain moves.
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
  entrypoint. The `NtsSyncedTime` class and constructor dartdoc in
  `lib/src/api/models.dart` state their initialisation prerequisite the
  same way, keeping `NtsRustLib.initMock()` as the test alternative.
  (The `no-op` wording in
  `android/.../PlatformInit.kt` is correct and unchanged — that
  bootstrap really is idempotent.)
- The README's non-Flutter loader guidance no longer describes a later
  `ensureInitialized()` call passing a different library as a "no-op",
  and both it and the `ensureInitialized` dartdoc now warn that
  *ignored* is not *unloaded*. `ExternalLibrary.open` maps the library
  synchronously inside its own constructor, so the argument's load-time
  initializers have already run by the time `ensureInitialized` is
  entered and can decide to discard it. The library-hijack surface the
  section exists to describe is closed by nominating one call site as
  the initialization owner and constructing the library only there, not
  by a later call being ignored, and the guidance says so. It also says
  what `NtsBridge.state` is not: a way to tell whether a call will be
  the one that initializes. The getter rules out a *completed*
  initialization only — a latched attempt still awaiting its library
  load has installed no entrypoint state, so `state` reads
  `uninitialized` for that whole window.
- The CI matrix's old-SDK leg is no longer documented as exercising the
  declared SDK floor. It runs Flutter 3.38.10, which is ten patches
  above the `flutter: '>=3.38.0'` constraint and is not the oldest
  release satisfying it — earlier 3.38.x patches do not build native
  dependencies through the Native Assets build hook reliably, so a leg
  pinned to the literal floor would fail for reasons unrelated to this
  package's sources. The pin is deliberate and unchanged; what moved is
  the claim attached to it in `ci.yml`, `pubspec.yaml`,
  `DEVELOPMENT.md` (both the bullet and the workflow table), and the
  pull request template, all of which described 3.38.10 as the declared
  floor. The declared floor is a dependency-resolution bound, not a
  build-verified one, and the comments now say which is which.
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
- The example CLI loader rejects a bridge of the wrong kind in both
  directions rather than only one. `mockBridgeDisposition` becomes
  `bridgeDisposition(state, useMock:)`, and a native run that finds an
  installed mock now exits with the same diagnostic shape as a `--mock`
  run that finds an installed native bridge. Previously that direction
  fell through to `NtsBridge.ensureInitialized()`, which completes for
  any installed state, so the run reported success and then dispatched
  every call to `MockNtsApi`. Example app only; no package API change.
- The example app's GUI bootstrap installs its fallback mock only when
  the failed `ensureInitialized()` left the bridge uninitialized. A
  Rust-initializer failure leaves it `native` but half-built, and the
  unconditional `initMock` threw a second `StateError` over the top of
  the real error, so the banner never rendered. Example app only; no
  package API change.
- That other arm now aborts to a `Bridge unavailable` screen rather
  than proceeding into the normal UI. No mock can stand in for a
  half-built entrypoint, so bootstrap carries a `bridgeUsable` flag and
  `main()` short-circuits on it: no `AppState`, no `NtsController`, and
  so no `NtsClient` minted over a bridge every call would throw
  through. Previously the arm fell through, and the UI then misreported
  itself — the corner banner reads `mock fallback` off any non-null
  load error, and `AppState.bridgeLoadError` was documented as implying
  one had been installed. `AppState` gains a `mockFallback` flag that
  says whether it actually was, the corner banner is driven off that
  rather than off the error, and `bridgeLoadError` is described as what
  it is: a bootstrap diagnostic that a catalog failure also populates.
  A `shell diagnostics` group covers the resulting three-way split
  through the public `NtsExampleApp`: no diagnostic renders neither
  banner, a diagnostic without a fallback renders the error banner
  alone, and a fallback renders both. The middle case is the one the
  old condition got wrong, and it fails against it. The dead-end screen
  is public as `BridgeUnavailableApp` so a fourth case can pump it
  directly; `main()`'s branch into it cannot be driven from a test,
  since reaching it needs a real half-built entrypoint. Example app
  only; no package API change.
- That arm now returns from bootstrap immediately, via a
  `_Boot.bridgeUnavailable` variant, instead of setting a flag and
  falling through the remaining steps. Loading the server catalog and
  hydrating `SharedPreferences` for a UI that will never be built was
  wasted at best, and at worst lost the bridge error: the catalog arm
  prefixes rather than replaces, but an uncaught `FavoritesStore.load()`
  failure propagated out of bootstrap and `BridgeUnavailableApp` never
  rendered. `_Boot.favorites` is now nullable, non-null exactly when
  `bridgeUsable` is true. Example app only; no package API change.
- The example CLI loader awaits `NtsBridge.ensureInitialized()` on the
  native *reuse* arm rather than returning immediately. A retained
  initialisation failure lives on the wrapper's latch, so returning
  there converted an installed-but-half-built bridge into apparent
  success; awaiting it surfaces the original error and exits 70 like
  every other load failure. Mock reuse still returns directly — a mock
  is usable the moment `initMock()` returns, and routing it through the
  wrapper would latch a completed future over state the wrapper never
  installed. Example app only; no package API change.
- The example app moves from `file_picker` `^12.0.0-beta.7` to the
  `^12.0.0` stable release. `FilePicker.pickFiles()` now returns
  `List<PlatformFile>` rather than a nullable result object, so
  `CustomRootsPanel._pickFile` calls the single-file
  `FilePicker.pickFile()` instead, which returns `PlatformFile?` and
  matches what the panel wants. The macOS generated plugin registrant
  follows the plugin's split into federated packages
  (`file_picker` → `file_picker_darwin`). Example app only; no package
  API change.
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

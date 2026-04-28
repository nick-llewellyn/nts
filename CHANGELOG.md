# Changelog

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
  [lib/src/ffi/**]` block in 1.0.5 (`nts-2cq`) had a side effect that
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
  the rendering history is recorded in this changelog and in the
  `nts-9td` commit message, not in the file pub.dev publishes.

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

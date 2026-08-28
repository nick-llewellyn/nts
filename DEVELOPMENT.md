# Development

Toolchain, codegen, and logging workflows for contributors to the `nts`
package. API consumers do not need any of this — `flutter pub add nts`
plus the [Getting Started](README.md#getting-started) snippet is the
full integration path. See [ARCHITECTURE.md](ARCHITECTURE.md) for the
layering this document operates on.

## Toolchain

Contributor setup is the consumer setup — rustup plus Flutter, per
the README's [Prerequisites](README.md#prerequisites) — with nothing
else mandatory. The load-bearing facts:

- **Rust is pinned to 1.98.0** by `rust/rust-toolchain.toml`. Both
  the Native Assets hook (`hook/build.dart`) and any `cargo`
  invocation from inside `rust/` resolve the pin through rustup,
  which auto-installs the toolchain and cross-compile targets on
  first use — never install or select a toolchain manually. The pin
  is distinct from two neighbouring version numbers: the MSRV in
  `rust/Cargo.toml` (`rust-version = "1.87"`, the floor the crate
  promises to compile on) and the nightly toolchain used only by
  cargo-fuzz (see [Fuzzing the Rust
  parsers](#fuzzing-the-rust-parsers-cargo-fuzz)). Toolchain bumps
  follow the upgrade checklist in `rust-toolchain.toml`'s comments
  and land as their own PR. When a bump lands on `main`, nothing
  manual is needed after pulling: rustup resolves
  `rust-toolchain.toml` on the next hook build or `cargo`
  invocation inside `rust/` and auto-installs the new pin, exactly
  as on first use — `rustup update` is not part of the flow.
  Optionally reclaim disk from the superseded pin with
  `rustup toolchain uninstall <old-version>`.
- **Flutter tracks the `stable` channel** (see `.fvmrc`); CI also
  runs an old-SDK leg (3.38.10) as a second matrix leg. That is
  above the declared `flutter: '>=3.38.0'` floor on purpose —
  earlier 3.38.x patches do not build native dependencies through
  the build hook reliably.
- **Native dylib for local testing:** most Dart-side work needs no
  manual build — the mock-mode suite runs without a dylib, and
  `flutter run` builds one via the hook. The one manual step is the
  opt-in live Dart suite, which needs
  `(cd rust && cargo build --release -p nts_rust)` first; see
  [Live Dart integration suite](#live-dart-integration-suite-testlive).

## Working with the Rust bridge

Five tools, distinct roles.

| Tool | Purpose | When to run |
|------|---------|-------------|
| `cargo` (in `rust/`) | Manage Rust deps, run unit tests | During Rust development |
| `tool/check_bindings.dart` | Regenerate, patch, and verify the Dart bindings | After any change to `rust/src/api/*.rs`, and before pushing it |
| `flutter_rust_bridge_codegen` | Underlying generator, invoked by the script above — not run directly | Never on its own; see [Regenerate bindings](#regenerate-bindings) |
| `hook/build.dart` (Native Assets) | Compile + bundle the dylib for Flutter | Automatically on `flutter build` |
| `tool/check_doc_snippets.dart` | Validate Dart code snippets in documentation | Before pushing changes that touch docs or public API |


### Regenerate bindings

Required after any change to `rust/src/api/*.rs`. This is the same
command as the drift gate — the script regenerates, patches, and
verifies in one pass:

```bash
dart run tool/check_bindings.dart
```

Commit the regenerated `lib/src/ffi/**` and `rust/src/frb_generated.rs`.
A second run should report `FRB bindings are in sync`; every patch pass
is idempotent, so re-running is safe.

> **Do not run `flutter_rust_bridge_codegen generate` directly.** Bare
> codegen emits unpatched output and therefore *reverts* the five
> post-codegen patch passes described below. The result fails the drift
> gate, and committing it would regress the generated bindings. The
> script invokes the generator itself, after checking that the
> generator version matches the exact `flutter_rust_bridge` pin in
> `pubspec.yaml` (currently `2.13.0`) and that `pubspec.yaml` and
> `rust/Cargo.toml` agree on it — codegen and runtime are
> version-locked.

### Verify bindings are in sync

The drift gate is the same command; there is no separate verify-only
mode:

```bash
dart run tool/check_bindings.dart
```

Mirrors CI's `Verify FRB bindings are in sync` job: regenerates
bindings, applies the post-codegen patches FRB cannot emit on its own
(see below), analyzes the patched output, runs `dart format` on it,
flags orphaned generated modules (see `_checkForOrphanedApiModules`),
then checks the watched paths two ways -- `git status --porcelain` for
generated files that exist on disk but are not yet tracked by git (a
bare `git diff` cannot see those), and `git diff --exit-code` for
changes to tracked files. Exits non-zero with the same error message CI
emits when `lib/src/ffi/` or `rust/src/frb_generated.rs` differ from
the committed state.

#### Post-codegen patches

FRB's output needs five mutations that the generator cannot emit
itself. All five run on every invocation of the script, and all five
are idempotent — re-running applies nothing new. This is why bare
codegen is not a substitute: it produces the unpatched form, which the
drift gate then rejects.

| Pass | Target | Purpose |
|------|--------|---------|
| `_lintIgnorePatches` (via `_addLintsToIgnoreForFile`) | `lib/src/ffi/**` | Appends lint names to each file's `// ignore_for_file:` directive. |
| `_patchFrbGeneratedUnimplementedMessages` | `rust/src/frb_generated.rs` | Gives the `unimplemented!("")` catch-all arms a diagnostic message. |
| `_patchDartFrbGeneratedUnimplementedMessages` | `lib/src/ffi/frb_generated.dart` | Same for the SSE codec's `UnimplementedError('')` arms, including the offending `$tag_`. |
| `_patchDartIntraDocLinks` | `lib/src/ffi/api/*.dart` | Rewrites Rust intra-doc links into their Dart equivalents; fails the run on an unresolvable link. |
| `_patchDartFrbGeneratedDcoUnreachableMessages` | `lib/src/ffi/frb_generated.dart` | Same for the DCO codec's `Exception('unreachable')` arms, including `${raw[0]}`. |

**Lint suppression.** `flutter_rust_bridge_codegen` does not propagate
Rust struct/enum docstrings to its synthesized freezed sealed class
wrappers and auto-generated default constructors. With
`public_member_api_docs` enabled in `analysis_options.yaml` and
`lib/src/ffi/**` left in the analyzed file set (so the published
surface stays in lockstep with what downstream consumers' analyzers
see), every undocumented public member in those positions fires the
lint -- ~120 hits in `lib/src/ffi/api/nts.dart` alone. Since the
underlying lints cannot be fixed at the Rust source, the script appends
the offending rule names to the file-level directive. If FRB ever emits
the missing docs natively, remove the corresponding entry from
`_lintIgnorePatches`.

**Diagnostic messages.** FRB emits empty-message panic and throw sites
for the defensive catch-all arms in its generated codecs. They are
unreachable for the exhaustive enums in `crate::api::*`, but an empty
message means a future wire-format mismatch fails with no context. The
three message patchers substitute a greppable form naming the codec and
the unexpected tag, without changing the runtime semantics.

**Intra-doc links.** Rustdoc paths like `[`CookieJar`]` carried through
from `rust/src/api/*.rs` have no meaning in Dart. The patcher resolves
each against a symbol table built across all generated modules and
rewrites it; an unresolvable link exits non-zero naming the originating
Rust line, so the docstring is fixed at source rather than shipping a
dead reference.

### Rust unit tests (no Flutter required)

```bash
cd rust && cargo test
```

### Smoke test the Dart bindings

```bash
flutter test
```

This runs the mock-mode suite (e.g. `test/ffi_smoke_test.dart`,
`test/api_smoke_test.dart`), which exercises the generated FRB API
contract without a native dylib or network. Live Dart→Rust→network
round-trips run from the example app (`example/`) and from the
opt-in Dart suite under `test/live/` (see [Live Dart integration
suite](#live-dart-integration-suite-testlive) below); the underlying
Rust crate ships live integration probes against `time.cloudflare.com`
that
run as part of `cargo test --lib` (un-gated from `#[ignore]` by
`nts-dbg` once GHA runners proved to have stable outbound
TCP/4460 + UDP/123 to Cloudflare). Network flake on those probes
is absorbed by `retry_on_transient` in
`rust/src/api/nts/tests.rs`, which retries up to three times with
500 / 1000 ms back-off. The helper signals on two channels: each
transient attempt emits a per-attempt stderr notice
(`<label>: transient failure on attempt N/3: <error>; retrying`),
and exhaustion after three transient failures panics with the full
transient-error trail (every transient error observed across the
three attempts, in attempt order). Rust's test harness captures
stderr on passing tests, so the per-attempt notices are visible
under exhaustion (a failing test) or when the developer passes
`-- --nocapture` to `cargo test`; CI's `cargo test --lib --locked`
invocation does not pass `--nocapture`, so on a green run the
notices stay captured. The exhaustion panic itself always surfaces
because the test harness reports the panic message regardless of
capture, which is what lets a sustained outage's three matching
errors versus a single bad sample followed by recovery flicker be
told apart from the failure message alone without re-running
locally. The `nts_query_live_ipv6_ptb` probe remains `#[ignore]`d
(also `nts::ke::tests::live_integration::ke_live_cloudflare`);
from `rust/`, a broad `cargo test -- --ignored` runs both
(`--ignored` is a libtest flag, not a cargo flag, so the `--`
separator is required), so target the IPv6 probe directly when
only that probe is wanted:

```bash
cd rust && cargo test -p nts_rust nts_query_live_ipv6_ptb -- --ignored --nocapture
```

GHA Linux runners have inconsistent IPv6 connectivity by Azure
region, which is the reason the IPv6 probe stays gated.

### Live Dart integration suite (`test/live/`)

`test/live/nts_live_test.dart` is the Dart-level analogue of the Rust
`ke_live_*` probes: it drives the public stability layer (`ntsQuery`,
`ntsWarmCookies`, and the per-instance `NtsClient`) against three real
public NTS-KE endpoints — `time.cloudflare.com`, `nts.netnod.se`, and
`ptbtime1.ptb.de`. The happy-path probe tolerates one endpoint being
down (passes when ≥ 2 of 3 succeed); the remaining sub-tests
(`ntsWarmCookies`, a fresh-instance round-trip, the
`TrustMode.platformOnly` backend assertion, cached-session reuse, and
an unreachable-host error-path check) are Cloudflare-only and must
pass. Transient `NtsErrorNetwork` / `NtsErrorTimeout` failures are
absorbed by the file's `_queryWithRetry` helper (3 attempts, 500/1000
ms back-off), mirroring the Rust `retry_on_transient`.

The suite is **opt-in** and never runs in the required `flutter test`
gate. Every test carries the `live` tag (via the file's
`@Tags(['live'])` library annotation), and the root `dart_test.yaml`
marks that tag `skip:` by default. A bare `flutter test` therefore
discovers the file but skips the whole suite at the suite level —
`NtsRustLib.init()` and every socket stay untouched, so the gate
remains hermetic with no CI-invocation change. (`flutter test`
honours this tag skip even though it ignores `dart_test.yaml`'s
`paths:` key, which is why path placement alone is insufficient.)

To run it, build the native release dylib so its FRB content-hash
matches the committed bindings, then opt in with `--run-skipped`:

```bash
(cd rust && cargo build --release -p nts_rust)
flutter test --run-skipped test/live/
```

`--run-skipped` is required: pointing `flutter test test/live/` at the
directory without it still skips, because the tag-skip config applies
regardless of the path selector.

### Cross-platform live probes (weekly, advisory)

`.github/workflows/cross-platform.yml` runs both live suites — the Rust
probes in `rust/src/api/nts/tests.rs` and the Dart suite above — on
`ubuntu-latest` and `windows-latest`, weekly (Mondays 07:00 UTC, offset
an hour from `fuzz.yml`'s daily 06:00 so the two do not start together)
plus `workflow_dispatch`. The offset is not a hard guarantee against
overlap — a fuzz run configured past an hour would still run into this
window — but the cron default is 60 s per target, so in practice fuzz
has long finished by 07:00. A `pull_request` trigger scoped to the
workflow file itself allows an edit to be validated before its first
scheduled run, mirroring `fuzz.yml`'s idiom.

The workflow is intentionally **not** in branch protection's required
status checks on `main`. Every step in it can go red because
Cloudflare, Netnod, or PTB is unreachable rather than because the tree
is broken, so a red run is a signal to triage, not a merge blocker.
`fail-fast: false` keeps a Windows-only break from hiding the Linux
result.

What the Windows leg uniquely covers: `rust/Cargo.toml` declares a
Windows-conditional `windows-sys` dependency backing the sleep-aware
monotonic clock in `nts::boottime`, and while
`x86_64-pc-windows-msvc` is listed in `rust/rust-toolchain.toml`,
nothing else in CI builds — let alone runs — that arm. The Dart live
suite, separately, has never run in CI on any platform because
`dart_test.yaml` skips the `live` tag by default. The Rust probes are
*not* new Linux coverage: the four Cloudflare probes in
`rust/src/api/nts/tests.rs` are plain `#[test]`, so `ci.yml`'s existing
`cargo test --lib --locked` already runs them on every Rust-touching
PR.

Two implementation constraints worth not re-breaking:

- **No `--ignored` on the cargo invocation.** The two `#[ignore]`d live
  tests should stay ignored: `nts_query_live_ipv6_ptb` because GHA
  runners have inconsistent IPv6 by Azure region (its semantics are
  "skip gracefully on network failure", not "retry then fail", so under
  `--ignored` it becomes a per-region coin-flip), and
  `ke_live_cloudflare` because it is a KE-only probe already subsumed by
  the four `api/nts` probes.
- **The release dylib must be built before the Dart step.**
  `NtsRustLib.init()` loads from `rust/target/release/` and `flutter
  test` does not run the Native Assets hook, so without the explicit
  `cargo build --release --locked` the Dart suite fails at load.

Reproduce a leg locally with the same commands the workflow runs:

```bash
(cd rust && cargo test --lib --locked -- --nocapture)
flutter pub get
(cd rust && cargo build --release --locked)
flutter test --run-skipped test/live/
```

Out of scope: macOS runners (the dev box's own platform, and GHA macOS
minutes are 10× Linux), coverage upload (network-dependent coverage
would make the Codecov dashboard drift with Cloudflare's uptime), and
promoting the workflow to a required check.

### Fuzzing the Rust parsers (cargo-fuzz)

The Rust crate ships a `cargo-fuzz` workspace under `rust/fuzz/` that
targets the parser surfaces directly exposed to attacker-controlled
network bytes (`parse_extensions`, `parse_message`,
`validate_response`, `parse_authenticator_body`, and
`parse_server_response`). The workspace is a
separate Cargo workspace so the parent `cargo test` / `cargo clippy`
invocations remain on stable toolchain — `libfuzzer-sys` itself
builds on stable, but `cargo fuzz {build,run}` enables sanitizer
coverage instrumentation (`-Zsanitizer`, etc.) that only the nightly
compiler accepts.

One-time setup:

```bash
rustup toolchain install nightly
cargo install cargo-fuzz
```

Run a target locally (5 minutes is a reasonable spot-check; longer for
overnight):

```bash
cd rust/fuzz
cargo +nightly fuzz run parse_extensions -- -max_total_time=300
```

Each target has a committed seed corpus under
`rust/fuzz/corpus/<target>/` (e.g. `parse_extensions/` contains three
minimised reproducers ported from `ntpd-rs`'s `should_not_crash` tests
— see PR #45 / bd nts-1qb; `parse_server_response/` contains a fully
authenticated canonical reply sealed under the harness's fixed key).
New crashes land in `rust/fuzz/artifacts/<target>/` (gitignored);
promote any minimised crash into the seed corpus or pin it as a
unit-test fixture in the parent crate's regression module.

The `nts_rust` crate exposes the parsers to the harness via the
`__internal-fuzz` Cargo feature (re-exports under
`nts_rust::__internal_fuzz::*`; the Cargo feature uses the
canonical hyphenated form per the `ntpd-rs` `__internal-` convention,
and the Rust module substitutes underscore because Rust identifiers
cannot contain hyphens). That feature must only ever be enabled by
fuzz / coverage crates that are themselves excluded from the
published artefact (see `.pubignore`). Never enable it from
`hook/build.dart` or the FRB codegen.

CI integration: `.github/workflows/fuzz.yml` runs each of the five
targets nightly (06:00 UTC) for a 60-second wall-clock budget per
target, in a per-target matrix so a crash on one target does not
short-circuit the others. Crash reproducers from a red run are
uploaded as `fuzz-crashes-<target>-<run-id>` artefacts with 30-day
retention. `workflow_dispatch` accepts a `max_total_time` input
override for ad-hoc longer runs. The workflow is intentionally NOT
in branch protection's required status checks on `main` — a red
nightly fuzz signal is an actionable finding to triage, not a
per-commit merge blocker. It is also a sibling workflow to
`ci.yml`, not a job within it, so the per-toolchain split is
clean: `ci.yml` stays on stable, `fuzz.yml` installs nightly.
The workflow's `matrix-parity` job mechanically enforces that the
`[[bin]]` targets in `rust/fuzz/Cargo.toml` and the workflow's
`matrix.target` list stay in lockstep: it diffs `cargo fuzz list`
against the matrix and fails on any mismatch, in either direction,
so a new fuzz target that is not mirrored into the matrix (or a
stale matrix entry) fails red instead of drifting silently.

## Rust log verbosity

The Rust crate is compiled in one of two configurations, selected by
the `verbose_logs` Native Assets user-define in the consuming app's
`pubspec.yaml`:

| `verbose_logs` | Cargo profile | `log-strip` feature | Visible log levels |
|----------------|---------------|---------------------|--------------------|
| `false` (default) | `--release` | active | `warn!` / `error!` only |
| `true` | debug | dropped (`--no-default-features`) | all (`trace!` upward, incl. `rustls`) |

The default produces a stripped binary: `release_max_level_warn` is
compiled in via the `log-strip` Cargo feature, eliding `info!` /
`debug!` / `trace!` call sites at compile time. On iOS / Android the
shipped binary is also obfuscated by IXGuard / DexGuard; the strip is
the load-bearing protection on **desktop and future web** targets,
where those obfuscators are not in play.

### Enabling verbose logs locally

To see `rustls` handshake traces and the crate's own `info!` / `debug!`
events on iOS Console.app (subsystem `com.nllewellyn.nts`) or
Android `logcat`, edit the example app's pubspec and rebuild:

```yaml
# example/pubspec.yaml
hooks:
  user_defines:
    nts:
      verbose_logs: true   # <- flip this
```

```bash
cd example
flutter clean              # drop the Native Assets hook cache
flutter run                # rebuilds rust/ without --release and
                           # without log-strip default features
```

Restore `verbose_logs: false` before committing or shipping. The
default-off posture means any pipeline that does not explicitly opt
in (CI, app-store builds, downstream embedders) still gets the
stripped release binary.

`hook/build.dart` is the authoritative wiring; the toggle is
deliberately a manual pubspec edit rather than a separate Flutter
flavor so the production-vs-developer split is visible at the call
site.

## Continuous integration

`.github/workflows/ci.yml` defines eleven jobs total. `changes` always
runs on push and PR; `build`, `rust`, `rust-bridge-sync`,
`cargo-deny`, and `android-kgp-gate` are job-gated and skip on
doc-only diffs (skipped jobs count as passing for branch
protection). `doc-snippets` is the inverse — it is the only job a
doc-only diff turns *on*. `build-gate` is an always-on aggregator that
collapses the `build` matrix into a single status-check name so
branch protection can require it cleanly even when matrix expansion
is suppressed by a skip. `hooks-syntax` and `hooks-behaviour` are
both gated on changes under `tool/hooks/` or `.github/workflows/`
(or a `workflow_dispatch` invocation, for branch-protection
drills) and skip otherwise; they cover separate regression shapes
(parse versus runtime) and run as parallel siblings rather than a
chain.
`dependency-review` is PR-only because it requires a base..head diff
that push events don't have:

| Job | Cost | Purpose |
|-----|------|---------|
| `changes` | ~5 s | Classifies the diff via `dorny/paths-filter`; outputs `rust`, `bindings`, `dart`, `ci`, `docs`, `hooks`, and `android` flags consumed by the gates below (`docs` gates `doc-snippets`; `hooks` gates the two hook jobs; `android` gates the KGP gate matrix). Always runs. |
| `build` | ~3–5 min × 2 | Dart format / analyze / `flutter test --coverage` on the oldest buildable SDK (3.38.10 — above the declared `>=3.38.0` floor; see the comment on the `build` job) and the latest `stable` channel (matches `.fvmrc`). Also resolves, analyzes, and tests the example app, then smoke-runs the three `example/bin/` CLI scripts under `dart run` with `--mock` — those are the package's only non-Flutter consumers, so running them through `dart` rather than `flutter` is what catches a `dart:ui` import leaking back into the library surface, and the step also pins `nts_cli`'s usage exit code at 64 so a failing script cannot pass by exiting 0. Gated on `dart`/`rust`/`bindings`/`ci` (skips on doc-only diffs). Stable-leg uploads `coverage/lcov.info` as a workflow artifact and to Codecov via OIDC. |
| `build-gate` | ~5 s | Single-name aggregator (`Dart tests gate`) over the `build` matrix. `needs: [changes, build]` + `if: always()` so it runs whether the matrix executed, was skipped, or failed. Passes when `needs.changes.result == 'success'` AND `needs.build.result` is `success` or `skipped`; fails otherwise. The `changes`-success precondition discriminates a legitimate doc-only matrix skip from a `changes`-failure cascade-skip — without it, a transient paths-filter failure would silently green-light branch protection. Required-status-check entry on `main` for the Dart side. |
| `rust` | ~7–10 min | `cargo build --locked` + `cargo test --lib --locked` + `cargo tarpaulin --lib` on Linux. Uploads `rust/coverage/lcov.info` as a workflow artifact and to Codecov via OIDC. Gated on `rust`/`ci`. |
| `rust-bridge-sync` | ~5–10 min | Runs `tool/check_bindings.dart` to assert the committed bindings match what the generator produces. Gated on `rust`/`bindings`/`ci`. |
| `doc-snippets` | ~1–2 min | Runs `tool/check_doc_snippets.dart`, which extracts fenced `dart` blocks from the Markdown docs, wraps fragments in a harness, and runs `dart analyze` over them. Deliberately light: it needs Flutter only to resolve package imports, so a doc-only diff is validated without the Rust toolchain + FRB codegen pipeline `rust-bridge-sync` requires. Gated on `docs`/`ci`/`workflow_dispatch`. Not a required status check on `main`. |
| `cargo-deny` | ~1 min | Rust supply-chain policy gate (NTS-72): the `bans`, `licenses`, and `sources` checks from `rust/deny.toml` against the full dependency tree. `advisories` is deliberately excluded — RustSec coverage comes from the daily `cargo-audit` job in `audit.yml`, and running both would mean two independently-drifting ignore lists for the same advisories. `[licenses].allow` is kept in lockstep with the `dependency-review` SPDX allow-list. Gated on `rust`/`ci`/`workflow_dispatch`. Not a required status check on `main` — advisory until it has demonstrated stability; promote deliberately via the branch-protection table above. |
| `dependency-review` | ~10 s | PR-only supply-chain gate via `actions/dependency-review-action`; fails on `moderate`-or-higher advisories across pubspec + Cargo.toml. Also enforces the NTS-72 SPDX `allow-licenses` list, kept in lockstep with `[licenses].allow` in `rust/deny.toml`. That list is a *distribution* policy — what may be linked into the published package or the `nts_rust` cdylib. Because this action also walks the workflow dependency graph (`pkg:githubactions/...`), which `cargo-deny` never sees, build-time actions are exempted individually via `allow-dependencies-licenses` rather than by widening `allow-licenses`: an action runs on an ephemeral runner and is never conveyed to a user, so its licence imposes no obligation on anything shipped. Currently one such entry, `Swatinem/rust-cache` (LGPL-3.0). The list carries one non-action entry too, `flutter_rust_bridge` — the motivation is not a licence exception, since the package is MIT and already allowed, but pub.dev publishes the field as the lowercase non-SPDX string `mit`, which the action cannot validate and so fails closed on. Note that `allow-dependencies-licenses` is package-scoped, not error-scoped: a listed package is dropped from licence evaluation entirely, so any licence a future FRB release declares would pass unexamined — re-verify by hand on each exact-pin bump. Adding to that carve-out is not a reason to touch `allow-licenses` or `deny.toml`. |
| `hooks-syntax` | ~5 s | POSIX-shell syntax (`sh -n`), presence, and exec-bit check for the repo-tracked git hooks under `tool/hooks/` (`pre-commit`, `pre-merge-commit`, `pre-push`). The validation step enumerates the required hooks explicitly rather than globbing — git treats missing or non-executable hook files as no-ops, so a glob would silently pass on a PR that deletes, renames, or chmod-strips a hook, and the explicit list fails closed for that shape. A second drift check then loops over `tool/hooks/*`, skips `test_hooks.sh`, and fails CI if any file matching a recognised git client-hook name (per `git help hooks`) is missing from `required_hooks`, so the list cannot silently fall behind when a new hook is added to the directory. Gated on `hooks`/`ci`/`workflow_dispatch`. Required-status-check entry on `main`. |
| `hooks-behaviour` | ~10 s | Runtime functional check that complements `hooks-syntax`. Runs `tool/hooks/test_hooks.sh`, which provisions a throwaway repo, points `core.hooksPath` at `tool/hooks/`, stages real commits and real merges, and invokes `pre-push` directly with synthetic refs/SHAs on stdin (git's documented pre-push contract: read updates from stdin, exit non-zero to abort — running an actual `git push` would also need a remote target without exercising any additional hook logic). Asserts on exit codes plus stderr content. Catches the regression shape `sh -n` cannot — a script that parses but no longer enforces policy at runtime — including the round-9 unquoted-heredoc bug where `set -u` aborted `pre-commit` before the recovery recipe printed (the recipe assertion is the explicit sentinel). Gated on `hooks`/`ci`/`workflow_dispatch`. Required-status-check entry on `main`. |
| `android-kgp-gate` | ~2–4 min | Runs `tool/test_android_kgp_gate.sh`, which configures the `:nts` Android module standalone (no app project, no Flutter Gradle Plugin) across the `android.newDsl` / `android.builtInKotlin` matrix and asserts both the configuration outcome and whether the standalone Kotlin Gradle Plugin ended up applied. The `newDsl=true` legs cannot be covered by the example app: `:app` fails to configure under the new DSL because the Flutter Gradle Plugin resolves the legacy `BaseExtension` with a non-null assertion (flutter/flutter#180137). Configuration only (`:nts:tasks`) — compiling would need the Flutter embedding the host app provides. Installs a JDK, a Rust toolchain (the module shells out to `cargo metadata` at configuration time), and Gradle — the example app's `gradlew` and wrapper jar are gitignored, so the version is parsed out of the tracked `gradle-wrapper.properties` and installed on PATH; the harness prefers the wrapper when a local Flutter build has materialised it. Gated on `android`/`ci`/`workflow_dispatch`. Required-status-check entry on `main`. |

The workflow declares a top-level `permissions: contents: read` token
baseline and grants `id-token: write` only to `build` and `rust` (the
two jobs that mint a Codecov OIDC JWT). Codecov uses tokenless OIDC
authentication (`use_oidc: true`, `codecov-action@v6`), so no shared
secret is required and uploads work on PRs from forks. A
`concurrency:` block cancels superseded PR runs while letting
post-merge runs on `main` always complete.

### Coverage outputs

| Source | File | Codecov flag | Local reproduction |
|--------|------|--------------|--------------------|
| Dart   | `coverage/lcov.info` | `dart` | `flutter test --coverage` |
| Rust   | `rust/coverage/lcov.info` | `rust` | `cd rust && cargo tarpaulin --lib --locked --skip-clean --out Lcov --output-dir coverage` |

Both files are also published as workflow artifacts
(`coverage-dart-lcov`, `coverage-rust-lcov`, 14-day retention) so
contributors without Codecov access can download the raw `lcov.info`
directly from the run.

### Coverage exclusion policy

Three layers can filter a file out of the coverage signal: inline
directives in the source, tool-level flags at the collection step,
and the centralized `.codecov.yml` `ignore:` block. The right layer
depends on who emits the file and which consumers (the local
`lcov.info` artifacts, IDE coverage gutters, the Codecov dashboard)
need to agree.

| Layer | Used for | Reach |
|-------|----------|-------|
| Inline directive (`// coverage:ignore-file`, tarpaulin attributes) | Generators that emit the directive themselves (Freezed: `*.freezed.dart`) | Local artifact + IDE + dashboard |
| Tool-level filter (`rust/tarpaulin.toml` `exclude_files`, `tarpaulin --exclude-files`) | FRB-generated Rust and platform init shims — the source can't carry a directive and the filter must propagate into the local lcov artifact | Local artifact + dashboard |
| Repo-level (`.codecov.yml` `ignore:`) | Same set as tool-level, plus FRB-generated Dart (where no equivalent CLI filter is wired up) | Dashboard only |

Concrete partitioning today:

- **Inline (generator-emitted):** `lib/src/ffi/api/nts.freezed.dart`
  carries `// coverage:ignore-file` from `freezed_generator`. Honour
  it; never duplicate it elsewhere.
- **Tool-level + repo-level (belt-and-braces):**
  `rust/src/frb_generated.rs`, `rust/src/android_init.rs`,
  `rust/src/ios_init.rs`, and `rust/src/api/simple.rs` (which holds
  only the `#[frb(init)]` lifecycle hook `init_app`, fired on dylib
  load and unreachable from `cargo test --lib`). Listed in
  `rust/tarpaulin.toml`'s `exclude_files` so local `cargo tarpaulin`
  matches CI, and in `.codecov.yml` `ignore:` so the dashboard agrees
  with the artifact.
- **Repo-level only:** `lib/src/ffi/frb_generated.dart`,
  `lib/src/ffi/frb_generated.io.dart`,
  `lib/src/ffi/frb_generated.web.dart`, and
  `lib/src/ffi/api/nts.dart`. All four are FRB-emitted Dart bindings,
  but the rationale for excluding them differs by file:
  - The three `frb_generated*.dart` files contain the
    `NtsRustLibApiImpl` class — the FFI dispatch that loads the dylib
    and marshals every `crateApi*` call across the bridge.
    `NtsRustLib.initMock()` substitutes the entire `NtsRustLibApi`
    instance via `instance.initMockImpl(api: api)`, so this impl
    class is never constructed in mock mode and its method bodies
    are genuinely unreachable from the test suite.
  - `lib/src/ffi/api/nts.dart` holds the public-facing forwarders
    (e.g.
    `ntsQuery(...) => NtsRustLib.instance.api.crateApiNtsNtsQuery(...)`).
    These bodies *are* reached when the smoke tests call `ntsQuery`
    / `ntsWarmCookies`; the mock intercepts at the
    `NtsRustLib.instance.api` level, one frame deeper. The exclusion
    is therefore on **low-signal grounds** — single-expression
    `=>` dispatchers that only forward arguments add line count
    without measuring authored logic — not on unreachability.

  No `flutter test --coverage` filter is wired (would require an
  extra `lcov --remove` step and `apt-get install lcov` on the
  runner); the Dart lcov artifact still contains all four files,
  but the dashboard does not.

When adding a new file that should be excluded, follow this
decision tree:

1. **Generated, and the generator can emit
   `// coverage:ignore-file` itself?** Configure the generator;
   do nothing else.
2. **Generated, but the generator cannot emit a directive
   (e.g. FRB)?** Add to `.codecov.yml` `ignore:`. If it is Rust,
   also add to `rust/tarpaulin.toml`'s `exclude_files` so the
   local artifact matches.
3. **Hand-written but globally untestable on the CI runner**
   (e.g. JNI / Obj-C++ init shims)? Same as case 2. Do not gate
   the module behind `#[cfg(target_os = "...")]` solely to remove
   it from coverage — that would also remove it from the Linux
   `cargo check` type-checking pass and let signature drift in.

The Rust-side duplication between `rust/tarpaulin.toml` and
`.codecov.yml` is intentional: tarpaulin filters the local artifact
so contributors running `cd rust && cargo tarpaulin` get the same
denominator as CI, and Codecov filters the dashboard so the
displayed percentage agrees with the artifact. The explicit
`--exclude-files` flags in `.github/workflows/ci.yml` are redundant
with `rust/tarpaulin.toml` (tarpaulin picks the file up
automatically) but kept as in-workflow documentation; the comment
block above the step calls out the synchronization requirement.

### Filter-driven gating

The Dart matrix, expensive Rust jobs, and Dart coverage upload are
skipped unless the diff actually requires them. Filters and gates:

| Filter | Watches | Gates |
|--------|---------|-------|
| `rust` | `rust/**`, `hook/**`, `flutter_rust_bridge.yaml`, `pubspec.yaml` | `build`, `rust`, `rust-bridge-sync`, `cargo-deny` |
| `bindings` | `lib/src/ffi/**`, `tool/check_bindings.dart` | `build`, `rust-bridge-sync` |
| `dart` | `lib/**`, `test/**`, `example/**`, `pubspec.yaml`, `analysis_options.yaml`, `sonar-project.properties` | `build` (whole job), Dart coverage upload step |
| `ci` | `.github/workflows/**` | `build`, `rust`, `rust-bridge-sync`, `hooks-syntax`, `hooks-behaviour`, `android-kgp-gate`, `doc-snippets`, `cargo-deny`, Dart coverage upload |
| `hooks` | `tool/hooks/**` | `hooks-syntax`, `hooks-behaviour` |
| `android` | `android/**`, `example/android/**`, `tool/test_android_kgp_gate.sh` | `android-kgp-gate` |
| `docs` | `**.md`, `tool/check_doc_snippets.dart` | `doc-snippets` |

`pubspec.yaml` lives in the `rust` filter because the
`flutter_rust_bridge: 2.13.0` exact pin sits there; bumping it must
trigger a full Rust + drift run. The `dart` filter additionally gates
the Codecov / artifact upload step inside `build`, on top of gating
whether the matrix runs at all — so a `rust`-only or `bindings`-only
diff still runs the Dart matrix (to catch FFI-surface drift visible
to Dart tests) but skips the upload (no Dart-relevant coverage delta
to publish). The `docs` filter is the one gate whose job is cheaper
than the ones it replaces: `doc-snippets` needs Flutter only to
resolve package imports, so a doc-only diff is validated without the
Rust toolchain + FRB codegen pipeline `rust-bridge-sync` requires.
`workflow_dispatch` (manual reruns from the Actions UI)
bypasses every gate so a forced run executes the full pipeline.

GitHub treats skipped jobs as passing for branch-protection purposes,
so the seven required checks (`Detect changed paths`, `Dart tests
gate`, `Verify FRB bindings are in sync`, `Rust build + tests +
coverage`, `Hooks shell-syntax check`, `Hooks behaviour check`,
`Android KGP gate matrix`) resolve green on doc-only diffs even though
`build`, `rust`, `rust-bridge-sync`, `hooks-syntax`,
`hooks-behaviour`, and `android-kgp-gate` all skip.

### Trigger-level skips

Two cheaper filters run before the workflow even queues:

- **`paths-ignore`** (`.github/workflows/ci.yml`): truly-irrelevant
  assets — `LICENSE`, `.gitignore`, `.beads/**`, `screenshots/**` —
  never trigger a workflow run. Markdown is **not** in this list:
  doc-only PRs need to trigger the workflow so required status
  checks resolve (the `build`, `rust`, `rust-bridge-sync`,
  `hooks-syntax`, `hooks-behaviour`, and `android-kgp-gate` jobs
  then skip via job-level `if:` and report green, since GitHub
  treats skipped jobs as passing for branch protection).
- **`[skip ci]` commit-message flag**: any commit whose message
  contains `[skip ci]`, `[ci skip]`, `[no ci]`, `[skip actions]`, or
  `[actions skip]` is bypassed by GitHub Actions. Prefer this only
  when `paths-ignore` doesn't cover the case (e.g. a single commit
  that touches both an ignored file and a non-ignored one but is
  known to be CI-irrelevant); never use it on PRs to `main`, since
  it would also bypass the required status checks.

### When to use each layer

| Change | Behaviour |
|--------|-----------|
| Doc-only edit (`README.md`, `ARCHITECTURE.md`, …) | Workflow runs; `build`, `rust`, `rust-bridge-sync`, `hooks-syntax`, `hooks-behaviour`, `android-kgp-gate`, and `cargo-deny` skip via `if:`. `doc-snippets` runs — it is the one job a doc-only diff gates *on*. Required checks report skipped → passing. Codecov inherits the parent's report via `.codecov.yml` carryforward flags. |
| Beads issue update (`.beads/**`) | Workflow doesn't run (`paths-ignore`). |
| Screenshot asset swap (`screenshots/**`) | Workflow doesn't run (`paths-ignore`). |
| Pure Dart edit outside `lib/src/ffi/` | `build` runs; `rust`, `rust-bridge-sync`, and `cargo-deny` skip. |
| Rust source change (`rust/src/**`) | All three runtime jobs run, plus `cargo-deny`. |
| Hand-edit of generated bindings | `build` and `rust-bridge-sync` run; `rust-bridge-sync` will fail with a drift error (regenerate via `dart run tool/check_bindings.dart` instead). |
| `pubspec.yaml` edit | All three runtime jobs run, plus `cargo-deny` (FRB pin sits there, in the `rust` filter). |
| Workflow file edit | All three runtime jobs plus `hooks-syntax`, `hooks-behaviour`, `android-kgp-gate`, `doc-snippets`, and `cargo-deny` run (validates the change end-to-end and re-asserts the hook-enforcement layer still parses *and* still enforces, since every gate trips on `ci`). |
| Hook script change (`tool/hooks/**`) | `hooks-syntax` and `hooks-behaviour` run; the runtime jobs skip. |
| Android Gradle change (`android/**`, `example/android/**`) | `android-kgp-gate` runs; an `example/**` diff also trips the `dart` filter, so `build` runs alongside it. |

## Contribution workflow

[CONTRIBUTING.md](CONTRIBUTING.md) is the short-form entry point for
third-party contributors; this section remains authoritative for the
detail it summarises.

Direct pushes to `main` are not permitted, and direct *commits* to
local `main` are blocked by the repo-tracked git hooks under
`tool/hooks/` once `core.hooksPath` has been activated for the
clone (see [Local hook setup](#local-hook-setup) below). On a
fresh checkout that has not run the opt-in, the local commit
itself is not blocked — the GitHub-side rule only refuses the
later push or PR merge, so the commit lands locally and has to be
reset out of the reflog before the workflow recovers.
Every change — including those authored by maintainers — lands
through a pull request that has cleared the CI gates above.
Required approvals are deliberately set to **zero**: the bar is
that CI is green, not that a second human signed off. Self-merging
your own PR is the expected default.

Primary maintainer: Nicholas Llewellyn (`nllewelln@gmail.com`).
**Maintainer-only**: when the primary maintainer authors commits or
files Beads issues from this repo, the local `git config user.email`
should be `nllewelln@gmail.com` (matching the global default) so
Beads issue `owner` fields stay consistent across new
issues. This is solo-maintainer hygiene, not a contributor policy
— third-party contributors should commit under their own identity;
attribution is not rewritten on merge.

### Required `main` branch protection settings

Configure these on GitHub at *Settings → Branches → Branch
protection rules → main*:

| Setting | Value | Why |
|---------|-------|-----|
| Require a pull request before merging | **on** | Forces every change through the CI pipeline and creates a reviewable diff. |
| Required number of approvals before merging | **0** | Solo-maintainer repo; CI is the gate, not a second pair of eyes. |
| Dismiss stale pull request approvals when new commits are pushed | **off** | No-op at 0 approvals; explicitly off so the setting is unambiguous. |
| Require status checks to pass before merging | **on** | Required checks: `Detect changed paths`, `Dart tests gate`, `Verify FRB bindings are in sync`, `Rust build + tests + coverage`, `Hooks shell-syntax check`, `Hooks behaviour check`, `Android KGP gate matrix`. Markdown is intentionally excluded from trigger-level `paths-ignore` so doc-only PRs trigger the workflow and the gated jobs all skip via `if:` (skipped → passing for branch protection). `Detect changed paths` is required directly so a `changes`-job failure (transient paths-filter error, network blip) surfaces as a hard fail rather than cascading into "skipped → passing" on every dependent gate. The `Dart tests gate` aggregator job resolves a matrix-skip naming quirk: when the `build` job is skipped via `if:`, GitHub collapses both Flutter-version matrix legs into one check using the unexpanded template name, so the per-leg names cannot be required directly; the aggregator reports one stable name regardless of expansion, and additionally requires `needs.changes.result == 'success'` for defense-in-depth so a `changes` failure cannot leak through as a skip. `Hooks shell-syntax check` and `Hooks behaviour check` are both required so the local-enforcement layer fails closed on two separate regression shapes — parse / presence / exec-bit (caught by the syntax job) and runtime policy logic (caught by the behaviour job, which is the only check that would catch a recurrence of the round-9 unquoted-heredoc bug). The surrounding `rust`/`dart`/`bindings` filters don't cover `tool/hooks/`, so without these two gates a hook regression could merge unnoticed. `Android KGP gate matrix` is required for the same fail-closed reason on the Android side: the `newDsl` / `builtInKotlin` gate in `android/build.gradle.kts` is only exercised by `tool/test_android_kgp_gate.sh`, which no other job runs, so a regression in that gate would otherwise merge unnoticed. Codecov keeps reporting on doc-only commits via `.codecov.yml` carryforward flags. |
| Require branches to be up to date before merging | **on** | Catches semantic conflicts CI would miss when `main` advances mid-PR. |
| Require conversation resolution before merging | **on** | Self-applied: forces the author to mark their own follow-ups as addressed. |
| Require linear history | **on** | Pairs with the squash-only merge policy below; matches the `vX.Y.Z` tag-driven release flow. |
| Allow force pushes | **off** | Protected refs should never rewrite history. |
| Allow deletions | **off** | `main` is the canonical ref. |
| Enforce all configured restrictions for administrators (`enforce_admins`) | **on** | Subjects the maintainer account to the rules configured above (required status checks, linear history, pull-request workflow). Without this, admins can bypass each of those rules with a single `git push` or web-UI merge, and the PR-only policy becomes advisory for the role most likely to violate it. Re-apply with `gh api -X POST /repos/<owner>/<repo>/branches/main/protection/enforce_admins`; toggle off with the matching `DELETE`. |

The following three settings live under *Settings → General → Pull
Requests* (repo-level, not branch-scoped) but are listed here because
they are part of the same merge-policy contract. They are also
mirrored on the GitHub API and can be re-applied with `gh api -X
PATCH /repos/<owner>/<repo> -F allow_squash_merge=true -F
allow_merge_commit=false -F allow_rebase_merge=false`.

| Setting | Value | Why |
|---------|-------|-----|
| Allow squash merging | **on** | The only permitted merge strategy; collapses every PR into a single commit on `main`, keeping history linear and `git log --oneline` readable. |
| Allow merge commits | **off** | Disabled to prevent the noisy two-parent commits that arise from the GitHub UI's default "Create a merge commit" button; conflicts with `Require linear history` above. |
| Allow rebase merging | **off** | Disabled because per-commit rebases bypass the squash policy and replay potentially unsquashed WIP commits onto `main`. |

`Required pull request reviews` with `Require review from Code
Owners` is left **off**: no `CODEOWNERS` file is committed, and
adding one would just re-introduce a blocking approval requirement
that contradicts the 0-approvals policy above.

### Local hook setup

The repo ships `pre-commit`, `pre-merge-commit`, and `pre-push`
hooks under `tool/hooks/` that refuse direct work on `main`/
`master`. They are tracked in-tree (not under `.git/hooks/`,
which git deliberately does not version) and require a one-time
opt-in per clone:

```bash
git config core.hooksPath tool/hooks
```

Verify with:

```bash
git config --get core.hooksPath   # MUST print 'tool/hooks'
```

The hooks are POSIX shell and depend only on `git` itself.

- `pre-commit` keys on the *current* branch (the value of
  `git symbolic-ref --short HEAD`) and refuses plain commits on
  `main`/`master`. It falls through to `exit 0` on detached HEAD
  so interactive rebases of feature-branch history and `git
  bisect` are unaffected; the consequence is that any rebase
  that *rewrites local `main`* (typically `git pull --rebase` on
  `main`, or `git rebase upstream/main` while checked out on
  `main`) replays each commit with HEAD detached and is **not**
  caught at commit time. Such a rebased `main` cannot reach the
  remote without tripping `pre-push` and layer 2, but the gap
  exists locally.
- `pre-merge-commit` exists because `git merge` does not fire
  `pre-commit`. It applies the same current-branch check and
  refuses any `git merge` performed while on `main`/`master`
  before the merge commit is recorded; the message it prints is
  scoped to merges (recovery via `git merge --abort` and a fresh
  branch) rather than reusing the plain-commit recipe. The hook
  fires only when git is about to record an actual merge commit:
  `git merge feature/foo` while local `main` has no commits
  beyond the merge base is a fast-forward (no commit recorded,
  no hook fired), so this is a second commit-time bypass alongside
  the rebase case above. Both bypasses are caught at push time by
  `pre-push` and layer 2.
- `pre-push` keys on the *destination* ref reported by `git` on
  stdin, so it refuses any push that updates `refs/heads/main` or
  `refs/heads/master` regardless of which local branch is being
  pushed — including `git push origin HEAD:main` from a feature
  branch.

All three hooks honour the standard `--no-verify` escape; pair
this layer with `enforce_admins: true` above so the bypass loses
its second line of defence.

The functional test suite for these hooks lives at
`tool/hooks/test_hooks.sh` and can be run locally without arguments
(it provisions a throwaway repo via `mktemp -d` and cleans up on
exit). CI runs the same script in the `hooks-behaviour` job. Use
it after any change to `tool/hooks/` to confirm the policy logic
still fires; `sh -n` syntax checking alone is not sufficient (the
round-9 unquoted-heredoc bug parsed cleanly but aborted the hook
with `m: unbound variable` under `set -u` before the recovery
recipe could print).

This layer exists because the remote layer can only act after the
commit already exists locally: GitHub branch protection rejects the
push when `refs/heads/main` is updated, and the required-check /
PR-only merge settings reject the merge when a PR is squashed on
GitHub. Either way, a plain or merge commit on local `main` is
recoverable but it consumes a `git reflog` window and reorders the
natural workflow; the commit-time hooks close that window for the
two common shapes (plain commit, merge commit). Rebases that
rewrite local `main` and fast-forward merges remain known
commit-time gaps and are caught downstream by `pre-push` plus the
remote layer.

### Local quality gates before opening a PR

Mirrors what CI runs; failing locally is faster than waiting for
the runner. The local Flutter SDK tracks the `stable` channel (see
`.fvmrc`).
The hook commands below mirror the `Hooks shell-syntax check` and
`Hooks behaviour check` CI jobs and are required for any change
under `tool/hooks/**` so a hook-only PR does not rely on CI as the
first signal.

Dart string literals use single quotes: `prefer_single_quotes` is
enabled in both `analysis_options.yaml` and
`example/analysis_options.yaml`, so `dart analyze` flags any
double-quoted literal (unless the string itself contains a single
quote). FRB-generated bindings comply automatically — the codegen
pipeline runs `dart fix` against the project's analysis options, so
the emitted Dart is already single-quoted (see the note in
`tool/check_bindings.dart`).

```bash
# Dart side
dart format --output=none --set-exit-if-changed .
dart analyze .
flutter test --coverage

# Example app (any Dart change touching the public surface)
(cd example && flutter pub get && flutter analyze && flutter test)

# Example CLI scripts (any change to example/bin/ or the public
# surface they consume); `dart`, not `flutter`, is the point
(cd example \
  && dart run bin/nts_cli.dart --mock nts.example.test \
  && dart run bin/nts_health.dart --mock assets/nts-sources.yml \
  && dart run bin/nts_manifest.dart --mock -o /tmp/nts-manifest.json \
       assets/nts-sources.yml)

# Rust side (any rust/** change)
(cd rust && cargo build --locked && cargo test --lib --locked)
(cd rust && cargo clippy --lib --tests --locked -- -D warnings)
(cd rust && cargo tarpaulin --lib --locked --skip-clean \
            --out Lcov --output-dir coverage)

# Rust dependency audit (any rust/Cargo.toml or rust/Cargo.lock change; mirrors CI)
(cd rust && cargo audit)

# FRB drift gate (any change to rust/src/api/** or lib/src/ffi/**)
dart run tool/check_bindings.dart

# Documentation snippet validation
dart run tool/check_doc_snippets.dart

# Hooks side (any change to tool/hooks/**); mirrors CI exactly
sh -n tool/hooks/pre-commit tool/hooks/pre-merge-commit tool/hooks/pre-push
sh tool/hooks/test_hooks.sh
```

Note: The local `cargo audit` command requires the `cargo-audit` tool to be installed on your machine (`cargo install cargo-audit --locked`).

The PR template (`.github/pull_request_template.md`) carries the
canonical checklist; tick the boxes you actually ran rather than
the full set.

### Copilot code review configuration

Copilot code review is configured from tracked files plus three
settings-side requirements (enumerated below). The tracked half:

| Path | Role |
|---|---|
| `.github/copilot-instructions.md` | Repository-wide review guidance. Applies to every review. |
| `.github/skills/code-review/SKILL.md` | The review protocol: reporting threshold, procedure, MCP usage. |
| `.github/skills/code-review/architecture.md` | Architecture-specific checks — FFI boundary, sealed `NtsError`, `TrustMode` fallback paths, zeroization, versioning. |
| `.github/skills/code-review/output-format.md` | The mandatory summary-comment format. |
| `.github/instructions/dart.instructions.md` | Applies to `**/*.dart`. |
| `.github/instructions/rust.instructions.md` | Applies to `rust/**/*.rs`. |

Two behaviours worth knowing:

- **Copilot reads these from the PR head branch, not the base
  branch.** A change to the review configuration is testable in the
  same PR that introduces it — request a review from `@copilot` on
  that PR and the new instructions apply immediately.
- **The skill directory name matters.** Copilot code review is more
  likely to load a skill whose directory has a review-focused name.
  Keep it `code-review`; renaming it makes the skill less likely to be
  picked up for review tasks.

The settings-side half is **not** a tracked file. MCP servers are
configured per repository under **Settings → Copilot → MCP servers**,
as a JSON object. The configuration is shared by Copilot code review
and Copilot cloud agent — there is no review-only server list.

That object holds only the servers added for this repository, and is
empty on a fresh one. The built-in GitHub and Playwright servers are
applied implicitly and do not appear in it, so there is nothing to
preserve when pasting a first entry.

Three requirements. The first two are stated as requirements rather
than as observed defaults, since GitHub's defaults are outside this
repository's control and may change:

1. **The built-in GitHub MCP server must stay enabled.** It is the
   server the review protocol depends on for CI check results and prior
   PR history. Nothing here needs Playwright.
2. **"Allow Copilot to use MCP tools when reviewing pull requests"
   must stay enabled**, under **Settings → Copilot → Code review**.
   Disabling it restricts MCP to the cloud agent, which would make the
   MCP-dependent checks in `SKILL.md` silently unavailable — the
   reviewer reports them as not-performed under `## Review Status`
   rather than failing loudly, so the loss is easy to miss.
3. **The `linear` MCP server must be added** to that JSON object, per
   the subsection below. `SKILL.md`'s acceptance-criteria check depends
   on it.

The first two are GitHub defaults at the time of writing, so a fresh
repository typically needs no action on them. Verify rather than
assume. The third is not a default and has to be added by hand.

#### Grounding the reviewer in Linear

`.github/skills/code-review/SKILL.md` instructs the reviewer to fetch
the `NTS-` issue named in the branch and check its acceptance criteria
against the diff, so this server is a prerequisite for that check
rather than an optional extra. Without it the lookup fails and the
reviewer falls back to the criteria the PR itself restates, reporting
the fallback under `## Review Status`.

The GitHub MCP server cannot read Linear, so Linear needs its own entry
in that JSON object. Copilot does not support remote MCP servers that
authenticate via OAuth, which is Linear's default, so the connection
has to go through the `mcp-remote` stdio bridge with a bearer token:

```jsonc
{
  "mcpServers": {
    "linear": {
      "type": "local",
      "command": "npx",
      "args": [
        "-y",
        "mcp-remote@0.1.38",
        "https://mcp.linear.app/mcp",
        "--header",
        "Authorization: Bearer $LINEAR_API_KEY"
      ],
      "env": { "LINEAR_API_KEY": "$COPILOT_MCP_LINEAR_API_KEY" },
      "tools": ["get_issue", "list_issues", "list_comments"]
    }
  }
}
```

The `-y` is not decoration. `mcp-remote` is not preinstalled on the
review runner, and `npx` prompts before fetching a package it does not
have. MCP startup is non-interactive, so without it the server can hang
at that prompt and never come up.

Two things this needs beyond the JSON:

- **An Agents secret** named `COPILOT_MCP_LINEAR_API_KEY` (the
  `COPILOT_MCP_` prefix is mandatory; the remainder is what `env`
  refers to). Use a **new, read-only** Linear API key, not the
  read-write `LINEAR_API_KEY` that `bd linear sync` uses. Copilot
  invokes configured tools autonomously without asking for approval,
  so a read-only key is what bounds the damage from a prompt-injected
  review.
- **An enumerated `tools` list.** Unlike VS Code, the repository
  configuration requires the key. `["*"]` grants the reviewer Linear's
  write tools as well, which the autonomy note above makes the wrong
  default.

No firewall allowlisting is needed, and this cuts against the intuition
that the egress has to be opened. Copilot's firewall — configured under
**Settings → Copilot → Internet access** — applies only to processes
the agent starts through its Bash tool, explicitly *not* to MCP
servers. So neither the `npx` fetch nor the connection to
`mcp.linear.app` is subject to it. The corollary is that adding an MCP
server widens the review's network reach past whatever the firewall
allows, which is the reason to keep `tools` enumerated and the key
read-only.

The standing cost is the bridge itself. `mcp-remote` is a third-party
npm shim fetched at review time into a session holding a Linear token,
which is a supply-chain surface on every review, outside the firewall
per the paragraph above. Keep the version pinned, as above, rather than
tracking `@latest`, and re-read the diff when moving the pin.

This is unrelated to the "Integrate cloud agent with Linear" feature in
GitHub's documentation, which delegates Linear issues *to* Copilot
rather than grounding a review in them.

To confirm which skill or MCP server a given review actually used,
check the attribution line at the bottom of each review comment, or
open the review session from the PR timeline and read the session logs.

Requesting a review:

```bash
gh api -X POST repos/<owner>/<repo>/pulls/<number>/requested_reviewers \
  -f 'reviewers[]=copilot-pull-request-reviewer[bot]'
```

`gh pr edit --add-reviewer` does not work for this. It resolves the
reviewer through GraphQL, which rejects the bot login with `Could not
resolve user`; the REST endpoint above accepts it. A `@copilot review`
issue comment is the other option, but it is unreliable — it silently
produced no review at least once.

## Lint suppression policy

The Rust crate runs the curated `[lints.clippy]` set declared in
`rust/Cargo.toml` (see the table introduced by bd nts-hdx). When a
lint fires on a real change, the resolution order is:

1. **Default — fix at the call site.** Clippy is calibrated on
   ntpd-rs's hardening surface; most findings are real and the
   suggestion in the diagnostic is usually the right answer.
2. **Local suppression — `#[expect(lint, reason = "...")]`.** Use
   when the lint is wrong for this specific call site. *Never*
   `#[allow(...)]` in hand-written code (the singleton on
   `mod frb_generated;` in `rust/src/lib.rs` is the documented
   carve-out for generated content; see "Generated-code
   carve-out" below).
3. **Crate-wide suppression — drop the lint from
   `[lints.clippy]`.** Use when the lint is wrong *everywhere* in
   this codebase (e.g. a server-daemon-shaped lint reaching a
   library client). Document the decision with an inline comment
   on the dropped line. Per-call-site `#[expect]` is preferred
   over crate-wide drop unless the lint is wrong everywhere.

### Why `#[expect]` and not `#[allow]`

`#[expect]` was stabilised in Rust 1.81 (see the [release
notes](https://blog.rust-lang.org/2024/09/05/Rust-1.81.0.html#new-expect-attribute)).
Unlike `#[allow]`, which silently suppresses a lint regardless of
whether the lint would actually fire, `#[expect]` *requires* the
lint to fire — if a later refactor resolves the underlying issue,
the compiler emits an `unfulfilled_lint_expectations` warning that
the suppression is now dead code. Stale suppressions are flagged
automatically; they do not silently outlive the condition that
justified them. The MSRV declared in `rust/Cargo.toml`
(`rust-version = "1.87"`) covers the `reason` field syntax.

### `reason = "..."` content

The `reason` field is required, not optional. It must answer two
questions for the next reviewer:

- **Why is the lint wrong *here*?** What property of the call site
  makes the lint's general-purpose check inapplicable?
- **What would change that?** What future edit would invalidate
  the reason and force the suppression to be reconsidered?

Examples of reasons that meet the bar (lifted from current
sites): "linear handshake driver: deadline-threading and
Zeroizing-wrap invariants are visible at the call site rather
than scattered across helpers"; "test-local: `budget` is the
locally-constructed 500 ms timeout from the prior assertion
block, well above the 50 ms slack subtrahend; underflow is
impossible by construction".

Avoid reasons of the shape "this is fine", "intentional", "see
comment" — they convey no information that a future reviewer can
act on.

### Reusable boilerplate

Wrap long `reason` strings with `\` line continuations so the
literal does not embed newlines and indentation spaces into the
diagnostic that downstream tooling consumes; existing `#[expect]`
sites under `rust/src/` follow this shape (see e.g.
`rust/src/api/nts.rs::From<NtpError> for NtsError`).

```rust
#[expect(
    clippy::too_many_lines,
    reason = "Test bodies are intentionally long to exercise the \
              full positive/negative input matrix; splitting would \
              obscure the relationship between cases."
)]
```

### Generated-code carve-out

`rust/src/lib.rs` carries a single `#[allow(...)]` on the
`mod frb_generated;` declaration. `frb_generated.rs` is
`flutter_rust_bridge_codegen` output and gets regenerated
wholesale by `dart run tool/check_bindings.dart` (which drives the
cargo-installed generator on `PATH`; see "Regenerate bindings"
above); lint findings against it are not actionable from this
repository.
The suppression is durable, not temporary, so `#[expect]`'s "fail
on resolution" semantics actively work against the maintainer
intent here — a regeneration that happens to satisfy a
previously-suppressed lint would emit
`unfulfilled_lint_expectations` warnings that nobody can fix
without re-adding the lint shape elsewhere.

This is the *only* `#[allow]` site in hand-written code. New
sites must use `#[expect]`; the PR template
(`.github/pull_request_template.md`) carries a checklist item
flagging `#[allow]` introductions for conversion.

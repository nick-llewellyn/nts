# Development

Toolchain, codegen, and logging workflows for contributors to the `nts`
package. API consumers do not need any of this — `flutter pub add nts`
plus the [Getting Started](README.md#getting-started) snippet is the
full integration path. See [ARCHITECTURE.md](ARCHITECTURE.md) for the
layering this document operates on.

## Working with the Rust bridge

Three tools, distinct roles.

| Tool | Purpose | When to run |
|------|---------|-------------|
| `cargo` (in `rust/`) | Manage Rust deps, run unit tests | During Rust development |
| `flutter_rust_bridge_codegen` | Regenerate Dart bindings | After any change to `rust/src/api/*.rs` |
| `tool/check_bindings.dart` | Verify committed bindings match the generator | Before pushing changes that touch `rust/src/api/*.rs` |
| `hook/build.dart` (Native Assets) | Compile + bundle the dylib for Flutter | Automatically on `flutter build` |

### Regenerate bindings

```bash
flutter_rust_bridge_codegen generate
```

Commit the regenerated `lib/src/ffi/**` and `rust/src/frb_generated.rs`.

### Verify bindings are in sync

```bash
dart run tool/check_bindings.dart
```

Mirrors CI's drift check: regenerates bindings, applies the lint-suppression
patches that FRB cannot emit on its own (see `_lintIgnorePatches` in the
script), runs `dart format` on the output, then `git diff --exit-code`
against the watched paths. Exits non-zero with the same error message CI
emits when `lib/src/ffi/` or `rust/src/frb_generated.rs` differ from the
committed state. The pinned codegen version is read from `pubspec.yaml`
so the script and CI stay in lockstep.

#### Post-codegen lint-suppression patches

`flutter_rust_bridge_codegen` does not propagate Rust struct/enum
docstrings to its synthesized freezed sealed class wrappers and
auto-generated default constructors. With `public_member_api_docs`
enabled in `analysis_options.yaml` and `lib/src/ffi/**` left in the
analyzed file set (so the published surface stays in lockstep with what
downstream consumers' analyzers see), every undocumented public member
in those positions fires the lint -- ~120 hits in
`lib/src/ffi/api/nts.dart` alone. Since the underlying lints cannot be
fixed at the Rust source, the script appends the offending rule names
to the file-level `// ignore_for_file:` directive after each codegen
run. The patch table lives in `_lintIgnorePatches` and is idempotent:
re-running adds nothing if the rule is already present. If FRB ever
emits the missing docs natively, remove the corresponding entry from
the table.

### Rust unit tests (no Flutter required)

```bash
cd rust && cargo test
```

### Smoke test the Dart bindings

```bash
flutter test
```

This runs `test/ffi_smoke_test.dart`, which exercises the generated
FRB API contract in mock mode. Live Dart→Rust→network round-trips
run from the example app (`example/`); the underlying Rust crate has
its own live integration probes gated behind `--ignored` (run with
`cargo test --ignored` in `rust/`).

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
events on iOS Console.app (subsystem `com.nts.example`) or
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

`.github/workflows/ci.yml` defines six jobs total. `changes` always
runs on push and PR; `build`, `rust`, and `rust-bridge-sync` are
job-gated and skip on doc-only diffs (skipped jobs count as passing
for branch protection). `build-gate` is an always-on aggregator that
collapses the `build` matrix into a single status-check name so
branch protection can require it cleanly even when matrix expansion
is suppressed by a skip. `dependency-review` is PR-only because it
requires a base..head diff that push events don't have:

| Job | Cost | Purpose |
|-----|------|---------|
| `changes` | ~5 s | Classifies the diff via `dorny/paths-filter`; outputs `rust`, `bindings`, `dart`, `ci`, and `docs` flags consumed by the gates below (`docs` is informational — no job gates on it). Always runs. |
| `build` | ~3–5 min × 2 | Dart format / analyze / `flutter test --coverage` on the SDK floor (3.38.10) and the pinned current (3.41.7). Gated on `dart`/`rust`/`bindings`/`ci` (skips on doc-only diffs). Pin-leg uploads `coverage/lcov.info` as a workflow artifact and to Codecov via OIDC. |
| `build-gate` | ~5 s | Single-name aggregator (`Dart tests gate`) over the `build` matrix. `needs: [changes, build]` + `if: always()` so it runs whether the matrix executed, was skipped, or failed. Passes when `needs.changes.result == 'success'` AND `needs.build.result` is `success` or `skipped`; fails otherwise. The `changes`-success precondition discriminates a legitimate doc-only matrix skip from a `changes`-failure cascade-skip — without it, a transient paths-filter failure would silently green-light branch protection. Required-status-check entry on `main` for the Dart side. |
| `rust` | ~7–10 min | `cargo build --locked` + `cargo test --lib --locked` + `cargo tarpaulin --lib` on Linux. Uploads `rust/coverage/lcov.info` as a workflow artifact and to Codecov via OIDC. Gated on `rust`/`ci`. |
| `rust-bridge-sync` | ~5–10 min | Runs `tool/check_bindings.dart` to assert the committed bindings match what the generator produces. Gated on `rust`/`bindings`/`ci`. |
| `dependency-review` | ~10 s | PR-only supply-chain gate via `actions/dependency-review-action`; fails on `high`-severity advisories across pubspec + Cargo.toml. |

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

### Filter-driven gating

The Dart matrix, expensive Rust jobs, and Dart coverage upload are
skipped unless the diff actually requires them. Filters and gates:

| Filter | Watches | Gates |
|--------|---------|-------|
| `rust` | `rust/**`, `hook/**`, `flutter_rust_bridge.yaml`, `pubspec.yaml` | `build`, `rust`, `rust-bridge-sync` |
| `bindings` | `lib/src/ffi/**`, `tool/check_bindings.dart` | `build`, `rust-bridge-sync` |
| `dart` | `lib/**`, `test/**`, `pubspec.yaml`, `analysis_options.yaml` | `build` (whole job), Dart coverage upload step |
| `ci` | `.github/workflows/**` | `build`, `rust`, `rust-bridge-sync`, Dart coverage upload |
| `docs` | `**.md` | informational only — no job consumes this output; surfaced so doc-only diffs are observable in workflow run summaries |

`pubspec.yaml` lives in the `rust` filter because the
`flutter_rust_bridge: 2.12.0` exact pin sits there; bumping it must
trigger a full Rust + drift run. The `dart` filter additionally gates
the Codecov / artifact upload step inside `build`, on top of gating
whether the matrix runs at all — so a `rust`-only or `bindings`-only
diff still runs the Dart matrix (to catch FFI-surface drift visible
to Dart tests) but skips the upload (no Dart-relevant coverage delta
to publish). `workflow_dispatch` (manual reruns from the Actions UI)
bypasses every gate so a forced run executes the full pipeline.

GitHub treats skipped jobs as passing for branch-protection purposes,
so the four required checks resolve green on doc-only diffs even
though `build`, `rust`, and `rust-bridge-sync` all skip.

### Trigger-level skips

Two cheaper filters run before the workflow even queues:

- **`paths-ignore`** (`.github/workflows/ci.yml`): truly-irrelevant
  assets — `LICENSE`, `.gitignore`, `.beads/**`, `screenshots/**` —
  never trigger a workflow run. Markdown is **not** in this list:
  doc-only PRs need to trigger the workflow so required status
  checks resolve (the `build`, `rust`, and `rust-bridge-sync` jobs
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
| Doc-only edit (`README.md`, `ARCHITECTURE.md`, …) | Workflow runs; `build`, `rust`, and `rust-bridge-sync` skip via `if:`. Required checks report skipped → passing. Codecov inherits the parent's report via `.codecov.yml` carryforward flags. |
| Beads issue update (`.beads/**`) | Workflow doesn't run (`paths-ignore`). |
| Screenshot asset swap (`screenshots/**`) | Workflow doesn't run (`paths-ignore`). |
| Pure Dart edit outside `lib/src/ffi/` | `build` runs; `rust` and `rust-bridge-sync` skip. |
| Rust source change (`rust/src/**`) | All three runtime jobs run. |
| Hand-edit of generated bindings | `build` and `rust-bridge-sync` run; `rust-bridge-sync` will fail with a drift error (regenerate via `flutter_rust_bridge_codegen generate` instead). |
| `pubspec.yaml` edit | All three runtime jobs run (FRB pin sits there). |
| Workflow file edit | All three runtime jobs run (validates the change end-to-end). |

## Contribution workflow

Direct pushes to `main` are not permitted. Every change — including
those authored by maintainers — lands through a pull request that
has cleared the CI gates above. Required approvals are deliberately
set to **zero**: the bar is that CI is green, not that a second
human signed off. Self-merging your own PR is the expected default.

Primary maintainer: Nicholas Llewellyn (`nllewelln@gmail.com`).
**Maintainer-only**: when the primary maintainer authors commits or
files Beads issues from this repo, the local `git config user.email`
should be `nllewelln@gmail.com` (matching the global default) so
`.beads/issues.jsonl` `owner` fields stay consistent across new
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
| Require status checks to pass before merging | **on** | Required checks: `Detect changed paths`, `Dart tests gate`, `Verify FRB bindings are in sync`, `Rust build + tests + coverage`. Markdown is intentionally excluded from trigger-level `paths-ignore` so doc-only PRs trigger the workflow and the gated jobs all skip via `if:` (skipped → passing for branch protection). `Detect changed paths` is required directly so a `changes`-job failure (transient paths-filter error, network blip) surfaces as a hard fail rather than cascading into "skipped → passing" on every dependent gate. The `Dart tests gate` aggregator job resolves a matrix-skip naming quirk: when the `build` job is skipped via `if:`, GitHub collapses both Flutter-version matrix legs into one check using the unexpanded template name, so the per-leg names cannot be required directly; the aggregator reports one stable name regardless of expansion, and additionally requires `needs.changes.result == 'success'` for defense-in-depth so a `changes` failure cannot leak through as a skip. Codecov keeps reporting on doc-only commits via `.codecov.yml` carryforward flags. |
| Require branches to be up to date before merging | **on** | Catches semantic conflicts CI would miss when `main` advances mid-PR. |
| Require conversation resolution before merging | **on** | Self-applied: forces the author to mark their own follow-ups as addressed. |
| Require linear history | **on** | Pairs with the squash-only merge policy below; matches the `vX.Y.Z` tag-driven release flow. |
| Allow force pushes | **off** | Protected refs should never rewrite history. |
| Allow deletions | **off** | `main` is the canonical ref. |

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

### Local quality gates before opening a PR

Mirrors what CI runs; failing locally is faster than waiting for
the runner. The pinned Flutter version is `3.41.7` (see `.fvmrc`).

```bash
# Dart side
dart format --output=none --set-exit-if-changed .
dart analyze .
flutter test --coverage

# Example app (any Dart change touching the public surface)
(cd example && flutter pub get && flutter analyze)

# Rust side (any rust/** change)
(cd rust && cargo build --locked && cargo test --lib --locked)
(cd rust && cargo tarpaulin --lib --locked --skip-clean \
            --out Lcov --output-dir coverage)

# FRB drift gate (any change to rust/src/api/** or lib/src/ffi/**)
dart run tool/check_bindings.dart
```

The PR template (`.github/pull_request_template.md`) carries the
canonical checklist; tick the boxes you actually ran rather than
the full set.

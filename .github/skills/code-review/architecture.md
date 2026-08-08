# NTS architecture: review checks

Targeted checks for the surfaces where this repository's real defects
live. Line numbers drift; treat them as pointers to the right function
and confirm against the current file before citing one in a comment.

## Layout

| Path | Contents |
|---|---|
| `lib/src/api/` | Public Dart API. `errors.dart` holds the sealed `NtsError` hierarchy. |
| `lib/src/ffi/` | **Generated** Dart FRB bindings. Never hand-edited. |
| `rust/src/frb_generated.rs` | **Generated** Rust FRB glue. Never hand-edited. |
| `rust/src/api/` | Rust side of the FFI boundary. Source of truth for both generated artefacts. |
| `rust/src/nts/` | Protocol implementation: `ke.rs` (key establishment), `ntp.rs`, `aead.rs`, `cookies.rs`, `records.rs`, `hybrid_verifier.rs`. |
| `example/` | Flutter example app, plus the CLI at `example/bin/nts_cli.dart`. Has its own `pubspec.yaml` and test suite. |
| `tool/` | Repo tooling, including `check_doc_snippets.dart` and the git hooks under `tool/hooks/`. |

## The FFI boundary

`lib/src/ffi/` and `rust/src/frb_generated.rs` are generated from
`rust/src/api/`. Regeneration goes through `dart run
tool/check_bindings.dart`, never bare `flutter_rust_bridge_codegen` —
the script also applies patches that give the generated catch-all arms
real diagnostic messages, and those patches are lost if codegen is run
directly. The CI job **"Verify FRB bindings are in sync"** regenerates
and diffs.

Check on any PR touching `rust/src/api/`:

- **Bindings regenerated.** A change to a signature, struct field, or
  enum variant in `rust/src/api/` with no corresponding change under
  `lib/src/ffi/` or in `rust/src/frb_generated.rs` means the bindings
  are stale. The CI check is authoritative — read it via MCP rather
  than inferring.
- **Both sides regenerated.** The Dart and Rust artefacts are usually
  produced together, so one updated without the other is worth
  checking — but it is not proof of a partial run. A codegen version or
  configuration change, or a change to the script's patch passes, can
  legitimately move one artefact only.
- **Generated files not hand-edited.** A diff in `lib/src/ffi/` or
  `rust/src/frb_generated.rs` with no `rust/src/api/` change is a
  candidate hand-edit, not a confirmed one. The authoritative test is
  whether regeneration reproduces the diff, which is what the CI check
  answers. Report Critical/Bug when that check fails; when it passes,
  a one-sided diff is explained and not a finding.
- **ABI mismatch stays mapped.** Decode failures crossing the boundary
  surface as `NtsErrorAbiMismatch`, not as a bare Dart `Error`. A new
  FFI call path that does not route decode failures into that variant
  leaks `RangeError` to callers.

An ABI change is a breaking change for consumers who built the native
library separately. Confirm the CHANGELOG says so.

## The sealed `NtsError` hierarchy

Defined in `lib/src/api/errors.dart` as a `sealed class` with ten
concrete variants: `InvalidSpec`, `Network`, `KeProtocol`,
`NtpProtocol`, `Authentication`, `Timeout`, `NoCookies`,
`TrustBackendUnavailable`, `Internal`, `AbiMismatch`.

Adding a variant is a **breaking change**. Any consumer with an
exhaustive `switch` over `NtsError` fails to compile. It requires a
major-version CHANGELOG entry documenting the new arm, matching how
`AbiMismatch` was introduced in 8.0.0.

Exhaustive switches the analyzer already protects:

- `example/lib/src/state/nts_controller.dart`
- `example/lib/src/state/nts_format.dart` — `describeError` and
  `errorTypeName`
- `example/main.dart`

Do not comment on missing arms in those; the compile error is the
report. The check that matters is the one the analyzer cannot make:

- **Hand-maintained lists mirroring the hierarchy.** Any list of
  variants, tags, or severities written out by hand can drift. It
  already did once — the tag-collision test in
  `example/test/nts_format_test.dart` omitted `AbiMismatch`.
  The guard pattern for `_allNtsErrors` in that file is two-sided:
  `_variantKind` is an exhaustive switch with no wildcard arm, so a new
  variant fails analysis, and a runtime test asserts the samples map
  onto `_NtsErrorKind.values` so an arm added without a sample fails
  too. That pattern arrives with PR #293 and is not in the tree until
  it merges, so treat it as the shape to follow rather than as
  something already present. A new hand-maintained list without an
  equivalent guard is a Test Coverage finding.
- **Wildcard arms.** A `_ =>` or `default:` in a switch over `NtsError`
  defeats the compile-time gate. It is occasionally correct; flag it
  and ask, rather than assuming either way.
- **Tag uniqueness.** `errorTypeName` must return a distinct string per
  variant. The namespace also contains `TrustBackendMismatch` and the
  CLI's synthetic `Unhandled` tag, which is not a sealed variant — a
  new variant colliding with either breaks log parsing silently.

## `TrustMode` and the two fallback paths

`TrustMode` selects the TLS trust anchor source for the NTS-KE
handshake. The Dart variants are `platformWithFallback` (the default),
`platformOnly`, `bundledOnly`, and `custom`
(`lib/src/api/models.dart`); the Rust `KeTrustMode` variants carry the
same names in PascalCase (`rust/src/nts/ke.rs`). Use these exact
identifiers — there is no `webpki` or `platform` mode.

**`platform-with-fallback` has two distinct fallback paths.** Conflating
them is the single most repeated documentation defect in this repo, and
it has already shipped once.

1. **Build-time fallback** — `rust/src/nts/ke.rs`, in the trust-mode
   match around line 1363. If *constructing* the platform verifier
   fails, `platformWithFallback` falls back to the bundled webpki
   roots for the whole connection. Under `platformOnly` the same
   failure is fatal and raises `TrustBackendUnavailable`.

2. **Per-chain fallback** — `rust/src/nts/hybrid_verifier.rs`, in
   `HybridVerifier::verify_server_cert`. The platform verifier is
   constructed and used, but an *individual chain* verdict falls back
   to webpki. Under `PlatformWithFallback` exactly two platform
   verdicts are retried, and no others:
   - `CertificateError::Revoked` — Let's Encrypt R12/R8 chains omit
     the OCSP responder URL, so the platform reports `Revoked` when it
     merely could not check. The certs are not revoked.
   - `Error::General` carrying the `rustls-platform-verifier`
     JNI-failure marker — R8 stripped the AAR classes on Android.

   Every other failure category (`Expired`, `UnknownIssuer`,
   `BadEncoding`, other `General` errors) propagates verbatim.
   Under `PlatformOnly` *neither* retry runs: `Revoked` propagates
   unchanged.

When a diff documents or describes fallback behaviour, verify which
path it means, and verify the claim by reading these two files even
when the PR does not touch them.

- Does prose that says "falls back" say *when*? Both paths, or one?
- Does it keep the per-chain retry set at exactly `Revoked` and the
  JNI marker? Text implying every failure retries is wrong, and so is
  text implying `Revoked` propagates under `PlatformWithFallback`.
- Does it distinguish `platformOnly` from `platformWithFallback` for
  both cases? That asymmetry is the whole point of the two modes, and
  the build-time case is where `TrustBackendUnavailable` comes from.

`TrustBackendUnavailable` is classified error-severity, not warning:
it means a caller-side configuration choice the runtime cannot honour,
and an operator should see it rather than read it as a transient blip.

## Secret handling and zeroization

`AGENTS.md` holds the full policy. The classes of bytes treated as
secret: AEAD key material (`rust/src/nts/aead.rs`), NTS cookies
(`cookies.rs`, `ntp.rs`, `rust/src/api/nts.rs`), TLS exporter output
(`ke.rs`), and user-supplied root certificate bytes.

Check on any diff touching those files:

- **`Zeroizing` wrapper.** Heap-allocated secret bytes are
  `Zeroizing<Vec<u8>>` or `Zeroizing<Box<[u8]>>`, wrapped at the parse
  site so discard paths wipe too, not only the success path.
- **Growth-free construction.** Secret vectors are built with
  `to_vec()`, `clone()`, or `vec![0u8; N]` — never `push`, `extend`,
  or `reserve`. Reallocation during growth leaves copies `Zeroize`
  cannot reach. A `push` loop building a secret is Critical/Bug.
- **No `shrink_to_fit` on a secret vector.** Redundant with
  `zeroize >= 1.8`, and it may itself reallocate and free a
  non-zeroised buffer.
- **`zeroize >= 1.8` pin intact.** Below 1.8, `Vec` spare capacity is
  not wiped. A downgrade silently reopens that surface.
- **Redacted `Debug`.** Secret-bearing types carry a manual `Debug`
  printing placeholders. A `#[derive(Debug)]` added to one of them, or
  a new secret type without a manual impl, leaks bytes into logs and
  panic messages. Critical/Bug.
- **Fixed-size arrays** are preferred where the length is static —
  no spare capacity, no reallocation history.

## Cross-cutting checks

Apply to every PR.

### Versioning

Release-only bumping. A feature, fix, or refactor PR must **not** touch
`version:` in `pubspec.yaml` or `version` in `rust/Cargo.toml`. Bumps
land in a dedicated release commit. A version bump in a feature PR is a
Documentation finding unless the description justifies it as a
dependency-resolution constraint.

The two versions are independent — a Dart-only release leaves the crate
version alone.

### CHANGELOG

Entries go under the **next intended release header** (e.g. `## 9.1`),
never under an `## Unreleased` heading. A behaviour change with no
CHANGELOG entry is a Documentation finding. A breaking change — new
`NtsError` variant, changed public signature, ABI change — needs an
entry that says so explicitly.

### Documentation and code agreement

Prose making a claim about runtime behaviour is verified against the
implementation, not against the diff. This is where the repo's
recurring defects appear: the CLI guide's fallback description, and
`README.md` help text drifting from the actual argument parsing in
`example/bin/nts_cli.dart`.

`dart` code fences in `README.md`, `CHANGELOG.md`, `ARCHITECTURE.md`,
and `example/example.md` are extracted and analyzed by
`tool/check_doc_snippets.dart` in CI. A snippet using an API the PR
changed will fail there.

### Public API documentation

Public Dart APIs carry dartdoc. New public members without it are a
Documentation finding. Where a member's behaviour differs by version,
the doc says which version introduced the change — the existing
`NtsError` variant docs are the model.

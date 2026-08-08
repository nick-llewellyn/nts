---
applyTo: "rust/**/*.rs"
description: Review and authoring guidance for the Rust NTS implementation, covering the FFI boundary, secret zeroization, and the TrustMode fallback paths.
---

# Rust review guidance

Full checks in
[`.github/skills/code-review/architecture.md`](../skills/code-review/architecture.md).
The points below are the ones that recur.

## FFI boundary (`rust/src/api/`)

Anything in `rust/src/api/` is the source for both generated artefacts:
the Dart bindings in `lib/src/ffi/` and the Rust glue in
`rust/src/frb_generated.rs`. A signature, struct field, or enum variant
change there requires regenerating them with `dart run
tool/check_bindings.dart` — not bare `flutter_rust_bridge_codegen`,
which drops the script's diagnostic-message patches. The "Verify FRB
bindings are in sync" CI check is authoritative.

An enum variant added or reordered in a type crossing the boundary is
an ABI change. Stale bindings decode it as garbage, which surfaces to
Dart as `NtsErrorAbiMismatch`. Flag ABI changes and confirm the
CHANGELOG records them as breaking.

## Secrets

AEAD keys (`nts/aead.rs`), cookies (`nts/cookies.rs`, `nts/ntp.rs`),
TLS exporter output (`nts/ke.rs`), and user-supplied root certificates
are secret. On any diff touching them:

- Heap-allocated secret bytes are `Zeroizing<Vec<u8>>` or
  `Zeroizing<Box<[u8]>>`, wrapped at the parse site so discard paths
  wipe too — not only the success path.
- Built without growth: `to_vec()`, `clone()`, `vec![0u8; N]`. Never
  `push`, `extend`, or `reserve` on a vector that becomes a secret;
  reallocation leaves copies `Zeroize` cannot reach.
- No `shrink_to_fit` on a secret vector. Redundant with
  `zeroize >= 1.8`, and it may itself reallocate and free a
  non-zeroised buffer.
- Prefer fixed-size arrays where the length is static — no spare
  capacity, no reallocation history.
- Manual redacted `Debug`, never `#[derive(Debug)]`. A derive on a
  secret-bearing type leaks bytes into logs and panic messages.
- The `zeroize >= 1.8` lower bound in `rust/Cargo.toml` stays. Below
  1.8, `Vec` spare capacity is not wiped.

Never place a secret value in a log line, panic message, or error
`Display` impl.

## TrustMode fallback

`platform-with-fallback` has **two** distinct fallback paths. Conflating
them is this repository's most repeated documentation defect.

1. **Build-time** — the trust-mode match in `nts/ke.rs`. If
   *constructing* the platform verifier fails, `platformWithFallback`
   falls back to bundled webpki roots for the whole connection.
   `platformOnly` treats the same failure as fatal and raises
   `TrustBackendUnavailable`.

2. **Per-chain** — `nts/hybrid_verifier.rs`. The platform verifier was
   built successfully, but an individual chain verdict falls back to
   webpki. A `Revoked` verdict is deliberately **not** retried:
   revocation is a positive assertion, and retrying against webpki
   would launder it.

Any change here needs the `Revoked` non-retry preserved, and any prose
describing fallback needs to say which path it means.

## Error mapping

Rust-side failures map onto specific `NtsError` variants. A new failure
mode must map to an existing variant or add one — and adding one is a
breaking change for Dart consumers with exhaustive switches. A failure
folded into `Internal` when a more specific variant fits loses
information the caller needs to decide whether to retry.

## Gates

```bash
cd rust
cargo fmt --check
cargo clippy --all-targets -- -D warnings
cargo test
```

Lint suppressions (`#[allow(...)]`) need a comment explaining why; see
the lint-suppression policy in `DEVELOPMENT.md`.

# nts

Authenticated Network Time Security (RFC 8915) for Dart and Flutter.
Performs the TLS 1.3 NTS-KE handshake against a key-exchange server,
then issues AEAD-protected NTPv4 time queries against the negotiated
NTP server. The cryptographic core is implemented in Rust (rustls,
AES-SIV-CMAC / AES-128-GCM-SIV) and bridged to Dart via
`flutter_rust_bridge`, bundled through the stable Native Assets API.

## User Documentation

The bundled showcase under `example/` ships with two task-focused
manuals aimed at end users rather than package integrators. They
describe the GUI and CLI surfaces without assuming any familiarity
with the underlying Rust bridge or the Native Assets pipeline:

- [GUI User Manual](example/GUI_GUIDE.md) — navigating the server
  catalog, searching / filtering / favouriting, driving the **NTS
  Query** and **Warm Cookies** actions, reading the live log, and
  interpreting the status banners.
- [CLI User Manual](example/CLI_GUIDE.md) — invoking
  `bin/nts_cli.dart`, the positional host arguments, the `--port` /
  `--timeout` / `--warm` / `--mock` / `--exit-on-error` / `--json`
  flags, and how to read the round-trip and AEAD fields in the
  terminal output.

For developer-facing notes on the example app's architecture, bridge
modes, and dylib loading, see the [example
README](example/README.md). The remainder of this file is the
package-level reference.

## Architecture

The Dart side is intentionally thin. All cryptographic work lives in a
Rust crate that implements the protocol directly across `records.rs`
(NTS-KE wire format), `ke.rs` (TLS 1.3 + ALPN handshake driver),
`aead.rs` (SIV-CMAC / GCM-SIV authenticators), `ntp.rs` (AEAD-protected
NTPv4 packets), `cookies.rs` (cookie jar), and `hybrid_verifier.rs`
(Android trust-store fallback). It is bridged to Dart through
`flutter_rust_bridge` and bundled via the stable Native Assets API
(`hook/build.dart`), so no manual `cargo` invocation is required from
consumers.

```
Dart  : ntsQuery() / ntsWarmCookies()
        └─ FRB stub
Rust  : nts_query()
        ├─ NTS-KE handshake (rustls, TLS 1.3, ALPN ntske/1, port 4460)
        ├─ AEAD-protected NTPv4 over UDP/123 (AES-SIV-CMAC-256)
        └─ Cookie store (RAM, optional persisted blob)
```

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

Mirrors CI's drift check: regenerates bindings, runs `dart format` on the
output, then `git diff --exit-code` against the watched paths. Exits non-zero
with the same error message CI emits when `lib/src/ffi/` or
`rust/src/frb_generated.rs` differ from the committed state. The pinned
codegen version is read from `pubspec.yaml` so the script and CI stay in
lockstep.

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

## License

MIT. See [`LICENSE`](LICENSE).

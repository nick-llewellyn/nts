# Changelog

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

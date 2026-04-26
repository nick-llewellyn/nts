# nts_example

Showcase surfaces for the [`nts`](../) RFC 8915 package. Two
front-ends share the same Rust-backed bridge and the same formatting
layer:

- a Flutter GUI (`lib/`) — the visual showcase, with a server catalog,
  favourites, region filtering, and a unified terminal-style live log;
- a Dart CLI (`bin/nts_cli.dart`) — a scriptable companion for batched
  probing, cron jobs, and CI smoke checks.

Both render identical multi-line output for `ntsQuery` results because
the format helpers live in `lib/src/state/nts_format.dart` and are
imported by the GUI controller and the CLI alike (see
[Shared formatting](#shared-formatting)).

## User Documentation

If you just want to use the app or the CLI rather than read about how
they're put together, two task-focused manuals strip the implementation
detail out and walk through the user-facing behaviour:

- [GUI User Manual](GUI_GUIDE.md) — navigating the server catalog,
  searching / filtering / favouriting, driving the **NTS Query** and
  **Warm Cookies** actions, reading the live log, and interpreting the
  status banners.
- [CLI User Manual](CLI_GUIDE.md) — invoking `bin/nts_cli.dart`, the
  positional host arguments, the `--port` / `--timeout` / `--warm` /
  `--mock` / `--json` / `--exit-on-error` flags, and how to read the
  round-trip and AEAD fields in the terminal output.

The remainder of this README is the developer-facing reference:
architecture, bridge modes, dylib loading, and toolchain notes.

## Default Server Catalog

The server list is loaded dynamically from the bundled YAML asset
`assets/nts-sources.yml` at startup — there is no hard-coded fallback
list anywhere in the Dart sources. Edit, replace, or extend that file
to change the catalog the GUI offers; if it fails to load or contains
zero usable rows, the app surfaces an empty-catalog state and the
action buttons stay disabled rather than silently reverting to a
preset.

A few representative entries from the bundled file, useful as
copy-paste targets when you're driving the CLI directly:

| Host                  | Port | Operator                              |
| --------------------- | ---- | ------------------------------------- |
| `time.cloudflare.com` | 4460 | Cloudflare, Inc.                      |
| `nts.netnod.se`       | 4460 | Netnod AB (Stockholm)                 |
| `ptbtime1.ptb.de`     | 4460 | Physikalisch-Technische Bundesanstalt |

All three speak NTS-KE on TCP/4460 and AEAD-NTP on UDP/123 with
`aead-aes-siv-cmac-256` (IANA AEAD id 15). Any other RFC 8915 host
can be added to the YAML (or, for the CLI, passed straight on the
command line) without code changes.

---

## Flutter GUI

### Architecture

```text
main.dart        → bootstrap (bridge init, catalog load, favourites hydrate)
                   ↓
src/state/       → AppState + NtsController + LogBuffer (signals-based)
                   ↓
src/widgets/     → ServerListView, ActionPanel, LogView, FilterBar
```

State is mediated through the `signals` package: the log buffer, the
filter chips, and the favourites set are all `Signal`s, so widgets
rebuild reactively without any manual `setState` plumbing. The
`NtsController` is re-entrant — concurrent `ntsQuery` / `ntsWarmCookies`
calls overlap freely and stream results into the log as they complete,
in completion order rather than dispatch order.

### Visual identity

The Material 3 theme is seeded from the indigo brand colour (`0xFF3F51B5`)
and explicitly pins the `AppBar` and the filled / elevated button
backgrounds to that raw seed so the brand colour reads as saturated
royal blue rather than the desaturated tonal variant M3 would otherwise
generate. Amber (`Colors.amber.shade400/600/800`) is reserved for the
favourite stars and `WARN`-level log entries — the two-temperature
palette is deliberate.

### Bridge modes

The Rust dylib is built and bundled automatically by the package's
Native Assets build hook (`../hook/build.dart`), which invokes `cargo
build --release` for the active target via `native_toolchain_rust`.
No manual `cargo build` is required when running through `flutter run`.

Default boot is the **real bridge** — `RustLib.init()` resolves
`libnts_rust` through the bundled native asset and the
buttons drive the actual RFC 8915 client against the chosen NTS-KE
server:

```bash
fvm flutter run -d macos
# or, for Linux / Android / iOS:
fvm flutter run -d linux
```

To exercise the UI without network or on a host whose target triple
isn't pinned in `rust/rust-toolchain.toml`, switch to the in-memory
fake via the `NTS_BRIDGE` dart-define:

```bash
fvm flutter run -d macos --dart-define=NTS_BRIDGE=mock
```

If `RustLib.init()` cannot locate the dylib (typically because the
build hook was skipped or the target isn't pinned), the app prints a
banner explaining what went wrong and silently falls back to the mock
so the rest of the UI stays usable.

### Tests

```bash
fvm flutter test
```

Covers the catalog loader, region filtering, the format helpers, and a
widget smoke test that boots the home page under `MockNtsApi` and
asserts the log funnel behaviour.

---

## CLI: `bin/nts_cli.dart`

Standalone Dart entry point that drives the same `nts`
surface as the GUI but renders to stdout/stderr. Useful for batched
probing, cron jobs, CI checks, or quick smoke tests in environments
where launching Flutter is overkill.

The CLI does **not** consult the GUI's bundled YAML catalog and has no
built-in server list of its own — every host you want to probe is a
positional argument. Any RFC 8915 NTS-KE endpoint is fair game; the
hosts in the [Default Server Catalog](#default-server-catalog) above
are convenient starting points but in no way special.

### Prerequisite — build the host-arch dylib

Unlike `flutter run`, plain `dart run` does **not** trigger the Native
Assets build hook. The CLI loads the dylib explicitly via
`ExternalLibrary.open(path)`, so the binary must exist on disk before
the first non-mock invocation:

```bash
cd ../rust
cargo build --release
```

The build drops `libnts_rust.{dylib|so|dll}` into
`rust/target/release/`. The CLI auto-locates that path when invoked
either from `example/` or from the repo root; pass `--library
<absolute-path>` to override, or `--mock` to skip dylib loading
entirely.

### Usage

```text
Usage: nts_cli [options] <host> [<host>...]
-p, --port            TCP port for NTS-KE on every host (default: 4460).
-t, --timeout         Per-request timeout in milliseconds. Applied
                      independently to the KE handshake and the UDP recv leg.
                      (default: 5000)
-l, --library         Path to a prebuilt nts_rust dylib. If
                      omitted, falls back to rust/target/release/.
-w, --warm            Run ntsWarmCookies instead of ntsQuery.
    --mock            Use the in-memory mock bridge (no native dylib required).
    --json            Emit NDJSON (one JSON object per line) instead of
                      human log lines. Success goes to stdout, failures
                      to stderr.
    --exit-on-error   Exit with status 1 if any host produced a warn or
                      error result. Default exits 0 regardless of
                      per-host outcomes.
-h, --help            Show this help.
```

### Examples

All examples assume the working directory is `example/` at the repo
root.

Single-host query against the real bridge:

```bash
fvm dart run bin/nts_cli.dart time.cloudflare.com
```

Concurrent query against several hosts — results stream in completion
order (typically reflecting RTT):

```bash
fvm dart run bin/nts_cli.dart nts.netnod.se time.cloudflare.com ptbtime1.ptb.de
```

Cookie-warming pass instead of a time query:

```bash
fvm dart run bin/nts_cli.dart --warm nts.netnod.se
```

Tighter per-leg timeout (default `5000` ms), useful when you want a
fast-fail probe in CI:

```bash
fvm dart run bin/nts_cli.dart --timeout 2000 time.cloudflare.com
```

Non-default port (some operators expose NTS-KE on a non-standard
listener):

```bash
fvm dart run bin/nts_cli.dart --port 4461 nts.example.test
```

Skip dylib loading entirely — useful for CI smoke tests where the
Rust toolchain isn't available:

```bash
fvm dart run bin/nts_cli.dart --mock nts.netnod.se time.cloudflare.com
```

Pin to a custom dylib location (overrides the auto-locator):

```bash
fvm dart run bin/nts_cli.dart \
    --library /opt/nts/libnts_rust.dylib \
    nts.netnod.se
```

CI-friendly probe — NDJSON to stdout, non-zero exit on any host
failure:

```bash
fvm dart run bin/nts_cli.dart --json --exit-on-error \
    nts.netnod.se time.cloudflare.com
```

### Sample output

```text
2026-04-26T11:05:01.626612Z INFO  nts_query [nts.netnod.se]  Starting query
2026-04-26T11:05:01.632162Z INFO  nts_query [time.cloudflare.com]  Starting query
2026-04-26T11:05:01.898646Z INFO  nts_query [time.cloudflare.com]  OK  rtt= 35.65ms  stratum=3  utc=2026-04-26T11:05:01.916207Z
    └─ aead=AES-SIV-CMAC-256(15)  cookies=2
2026-04-26T11:05:02.091473Z INFO  nts_query [nts.netnod.se]  OK  rtt= 68.57ms  stratum=1  utc=2026-04-26T11:05:02.094865Z
    └─ aead=AES-SIV-CMAC-256(15)  cookies=2
```

`INFO` lines go to stdout; `WARN` (network / timeout / spec / no-cookies
errors) and `ERROR` (authentication / KE protocol / NTP protocol /
internal errors) go to stderr.

### Exit codes

| Code | Meaning                                                                  |
| ---- | ------------------------------------------------------------------------ |
| `0`  | Bridge initialised; every host completed (success or failure)            |
| `1`  | `--exit-on-error` was passed and at least one host produced warn / error |
| `64` | Argument error (bad `--port`, `--timeout`, missing hosts)                |
| `70` | Bridge load failure (no dylib found, `RustLib.init` threw)               |

By default the exit code does **not** reflect per-host failures — a
run where every host produced a `WARN` still exits `0` provided the
bridge itself initialised. Pass `--exit-on-error` to opt into the
stricter "any failure is a failure" semantics commonly expected by CI
runners.

### JSON output

`--json` swaps the human log format for newline-delimited JSON
(NDJSON). Every line is a self-contained object with a stable envelope
(`ts`, `level`, `source`, `host`, `event`) plus event-specific
fields. `success` events for `nts_query` carry the parsed sample;
`error` events carry the `error_type` variant tag (`Network`,
`Timeout`, `Authentication`, …), the human `message`, and the
`severity`. The same stdout / stderr split as text mode applies, so
`jq` over stdout still sees only the working hosts.

```text
{"ts":"…","level":"INFO","source":"nts_query","host":"nts.netnod.se","event":"start"}
{"ts":"…","level":"INFO","source":"nts_query","host":"nts.netnod.se","event":"success","utc_unix_micros":…,"utc":"…","rtt_micros":68570,"stratum":1,"aead_id":15,"aead_label":"AES-SIV-CMAC-256(15)","cookies":2}
```

---

## Shared formatting

The terminal-style log line shape — the right-padded `rtt=` column, the
`└─` continuation, the `aead=AES-SIV-CMAC-256(15)` label, the human-
readable `NtsError` rendering — lives in a single dependency-free
module:

```text
lib/src/state/nts_format.dart
  ├─ aeadLabel(int)            → IANA AEAD id → human label
  ├─ formatRtt(int micros)     → auto-selects µs / ms / s units
  ├─ formatQuerySuccess(...)   → two-line OK headline + continuation
  ├─ formatWarmSuccess(int)    → single-line OK + cookie count
  ├─ isErrorSeverity(NtsError) → severity classification (warn vs err)
  └─ describeError(NtsError)   → human-readable error rendering
```

`NtsController` (in the GUI) and `bin/nts_cli.dart` both consume these
helpers, which is why a query result rendered into the on-screen
`LogView` is byte-for-byte identical to the same query rendered to
stdout. The helpers are covered by `test/nts_format_test.dart`.

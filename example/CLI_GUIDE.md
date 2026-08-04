# `nts` example — CLI user manual

A walkthrough of `nts_cli`, the terminal companion to the `nts`
desktop application. The CLI runs the same Network Time Security
exchanges as the GUI but prints results to your shell so you can script
checks, pipe output into other tools, or run probes from a server that
has no display. This guide covers what to type and how to read the
output; for installation and prerequisites see the
[main README](README.md).

## Quick start

From the `example/` directory at the repo root, point the tool at any
RFC 8915 server:

```bash
fvm dart run bin/nts_cli.dart time.cloudflare.com
```

You should see two lines: a `Starting query` notice followed by an `OK`
result with the round-trip time, the server's stratum, and the UTC time
the server reported.

Pass several hostnames at once to probe them concurrently — results land
in completion order, which usually mirrors response time:

```bash
fvm dart run bin/nts_cli.dart nts.netnod.se time.cloudflare.com ptbtime1.ptb.de
```

## Hosts

Hostnames are positional arguments. The CLI does **not** ship with a
built-in server list and does not consult the GUI's catalog — every
host you want to probe is supplied on the command line. Any RFC 8915
NTS-KE endpoint will work; Cloudflare, Netnod, and PTB are convenient
starting points but in no way special.

## Options

| Flag                       | Purpose                                                                                                                                                              | Default |
| -------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------- |
| `-p`, `--port <n>`         | TCP port the key-establishment handshake speaks on. Most public NTS servers use the IANA-assigned 4460; only override when an operator publishes a different port.   | 4460    |
| `-t`, `--timeout <ms>`     | Per-request timeout, in milliseconds. Single global wall-clock budget shared across DNS, NTS-KE, and the AEAD-NTPv4 UDP exchange as one shrinking deadline — worst-case wall time tracks the value, not a multiple.                                                              | 5000    |
| `--dns-cap <n>`            | Ceiling on the engine's process-wide pool of in-flight DNS lookups. Left alone, the tool sizes it to the number of hosts so a multi-host run never queues on name resolution; setting it below the host count makes the excess lookups fail fast instead of waiting.             | auto    |
| `--trust-mode <mode>`      | Which root certificates the TLS handshake is allowed to trust: `platform-with-fallback`, `platform-only`, `bundled-only`, or `custom`. See [Trust modes](#trust-modes).                                                                                                          | platform-with-fallback |
| `--custom-roots <path>`    | A PEM certificate bundle or a single DER-encoded certificate to trust. Required by `--trust-mode=custom`, and rejected with every other mode.                        | —       |
| `--require-trust-backend <b>` | Assert that each handshake actually authenticated through this backend: `platform`, `platform-with-hybrid-fallback`, `webpki-roots`, or `custom`. A host that used a different one is reported as a failure instead of a success.                                              | —       |
| `-w`, `--warm`             | Run the cookie-warming pass instead of a time query. Useful before a burst of subsequent calls so they skip the handshake.                                           | off     |
| `--mock`                   | Skip the real network and run against an in-memory simulator. Handy for trying the tool out, smoke-testing a script, or running where the engine isn't installed.    | off     |
| `--json`                   | Emit one self-contained JSON object per line (NDJSON) instead of the human-readable log format. Successes go to stdout, failures to stderr, same as text mode.       | off     |
| `--exit-on-error`          | Return exit code `1` if any host produced a warn or error result. Default exits `0` once every host has completed, regardless of per-host outcomes.                  | off     |
| `-l`, `--library <path>`   | Point at a specific copy of the native engine. Almost never needed in normal use — the tool finds the standard build automatically.                                  | auto    |
| `-h`, `--help`             | Print the same option list to the terminal and exit.                                                                                                                 | —       |

### Examples

A faster-fail probe (handy in CI checks where you'd rather move on than
wait the default five seconds for an unresponsive host):

```bash
fvm dart run bin/nts_cli.dart --timeout 2000 time.cloudflare.com
```

Cookie warm-up against a single host (no time sample is printed; the
result is just a count of cookies the engine successfully cached):

```bash
fvm dart run bin/nts_cli.dart --warm nts.netnod.se
```

A scripted smoke test that doesn't require network access:

```bash
fvm dart run bin/nts_cli.dart --mock nts.netnod.se time.cloudflare.com
```

A CI-friendly probe that fails the job when any host can't be reached
or returns a bad answer:

```bash
fvm dart run bin/nts_cli.dart --exit-on-error --json \
    nts.netnod.se time.cloudflare.com
```

Check that a host authenticates without leaning on the operating
system's trust store, and fail the run if it silently used something
else:

```bash
fvm dart run bin/nts_cli.dart --exit-on-error \
    --trust-mode bundled-only --require-trust-backend webpki-roots \
    time.cloudflare.com
```

## Trust modes

By default the tool asks the operating system's trust store to vouch
for the server's certificate, and quietly falls back to the engine's
own bundled root list for a few known-awkward certificate shapes. That
is the most permissive setting, and it is what every run does when
`--trust-mode` is omitted.

| Mode | Trusts |
| ---- | ------ |
| `platform-with-fallback` | The OS trust store, falling back to the bundled roots for a narrow set of known chain shapes. |
| `platform-only` | The OS trust store, and nothing else. Fails rather than falling back. |
| `bundled-only` | Only the roots shipped inside the engine. Ignores the OS store entirely, including any corporate CA installed on the machine. |
| `custom` | Only the certificates in the file you pass to `--custom-roots`. |

Two consequences worth knowing before you reach for the stricter
modes:

- `bundled-only` and `custom` will fail against a server whose
  certificate comes from a private or corporate CA, because that CA is
  by definition not in the set you asked for. The failure arrives as a
  `KeProtocol` error naming an unknown issuer — the handshake got far
  enough to check the certificate and rejected it.
- `platform-only` can fail before any network traffic happens, on a
  platform where the OS verifier cannot be constructed at all. That
  case reports `TrustBackendUnavailable`.

`--require-trust-backend` is a separate question: not "what may this
run trust?" but "what did it actually end up trusting?". It is worth
pairing with `platform-with-fallback`, which is the one mode that can
resolve several different ways, so you can detect a silent fallback
rather than assuming it didn't happen.

Contradictory combinations are allowed on purpose — asking for
`--trust-mode bundled-only --require-trust-backend platform` is a
reasonable way to prove to yourself that it cannot succeed, and the
resulting message says exactly what happened.

Both flags work with `--mock`, so a script can be exercised without
network access. The simulator honours the mode you select but does not
read the bytes in `--custom-roots`, so `custom` reports success against
any non-empty file.

## Reading the output

A successful query renders as two lines per host: a headline with the
metrics you scan for, and an indented continuation with the
cryptographic detail. Concurrent runs interleave by host, but each line
carries the host in square brackets so they stay attributable.

```text
2026-04-26T11:05:01.626612Z INFO  nts_query [nts.netnod.se]  Starting query
2026-04-26T11:05:01.632162Z INFO  nts_query [time.cloudflare.com]  Starting query
2026-04-26T11:05:01.898646Z INFO  nts_query [time.cloudflare.com]  OK  rtt= 35.65ms  stratum=3  utc=2026-04-26T11:05:01.916207Z
    └─ aead=AES-SIV-CMAC-256(15)  cookies=2
2026-04-26T11:05:02.091473Z INFO  nts_query [nts.netnod.se]  OK  rtt= 68.57ms  stratum=1  utc=2026-04-26T11:05:02.094865Z
    └─ aead=AES-SIV-CMAC-256(15)  cookies=2
2026-04-26T11:05:02.091902Z INFO  nts_dns_pool [-]  DNS pool  refused=0  spawn-failed=0
    └─ recovered=2  in-flight=0  high-water=2 (process lifetime)
```

### Round-trip time (`rtt=`)

The tool auto-selects units so the column stays compact and comparable:

- `µs` — sub-millisecond, typical for a server on the same local network.
- `ms` — milliseconds, the normal range for a public internet probe.
- `s` — seconds, only seen when something is genuinely slow.

The right-padding keeps the column aligned across consecutive lines so
you can eyeball outliers at a glance.

### Stratum (`stratum=`)

A standard Network Time Protocol concept: a stratum-1 server is directly
attached to a hardware reference clock, stratum-2 derives its time from
a stratum-1 peer, and so on. Lower is closer to the source of truth;
most public NTS servers report stratum 1 or 2.

### Cryptographic line (`aead=`, `cookies=`)

The indented continuation reports two things:

- `aead=` — the authenticated-encryption algorithm the server negotiated
  during the handshake. `AES-SIV-CMAC-256(15)` is the RFC 8915 mandatory
  baseline; the parenthesised number is the algorithm's IANA id.
- `cookies=` — how many fresh single-use authentication cookies the
  server returned for use on subsequent queries.

### DNS pool line (`nts_dns_pool`)

Every run finishes with one extra pair of lines summarising the pool of
DNS lookups the run used. It is not attributed to a host — the pool is
shared across the whole run — so the bracketed field reads `-`.

```text
2026-04-26T11:05:02.091902Z INFO  nts_dns_pool [-]  DNS pool  refused=0  spawn-failed=0
    └─ recovered=2  in-flight=0  high-water=2 (process lifetime)
```

The two numbers on the headline answer a question the timeout messages
cannot. A lookup that never got to run reports the same timeout either
way, but the cause differs:

- **`refused` above zero** — the run hit its own `--dns-cap` ceiling.
  Raise it.
- **`spawn-failed` above zero** — the operating system would not give
  the process another thread. Raising `--dns-cap` here makes things
  worse, not better; the fix is fewer hosts per run, or a process with
  more headroom.

Both at zero is the healthy case, and what you should normally see.

`refused`, `spawn-failed` and `recovered` count only what this run did.
`in-flight` and `high-water` are readings rather than counts, so they
cover the whole process: `in-flight` is how many lookups were still
outstanding at the end (normally zero), and `high-water` is the busiest
the pool ever got.

### Warning and error lines

If something goes wrong, the line carries `WARN` or `ERROR` instead of
`INFO` and is written to standard error rather than standard output.
Common variants:

- `Network` / `Timeout` (warn) — the handshake or time leg didn't
  complete in time, or the network refused the connection.
- `NoCookies` (warn) — the server reported no available cookies for the
  request, often after a cold start.
- `Authentication` / `KeProtocol` / `NtpProtocol` (error) — the server
  responded but the response did not pass the cryptographic or protocol
  checks. These usually indicate a misconfigured or non-conforming
  server.

### Trust backend mismatch

If `--require-trust-backend` was passed and a host authenticated
through a different backend, that host reports a mismatch instead of
its usual success line:

```text
2026-04-26T11:05:02.091473Z ERROR nts_query [nts.netnod.se]  FAIL  trust backend mismatch: required=platform  actual=webpki-fallback
```

The handshake itself worked — this is your own assertion failing, not
the server misbehaving. Exactly one line is printed for the host: the
mismatch replaces the success line rather than following it, so a
per-host count over the output stays accurate. The mismatch counts as a
failure for `--exit-on-error`.

`actual=` uses the same short labels as the `trust=` field on a success
line, so `platform-with-hybrid-fallback` appears as `webpki-fallback`
there. The flag itself takes the longer spelling.

One warning is emitted before any host is contacted and is not about a
server at all:

```text
warning: .../libnts_rust.<ext> is older than the Rust sources
         that produced it (newest: .../rust/src/api/nts.rs).
```

`<ext>` is whatever your platform uses — `.dylib` on macOS, `.so` on
Linux, `.dll` on Windows (without the `lib` prefix).

The CLI loads the native library straight from `rust/target/release/`,
which only changes when you rebuild it. If you have edited anything
under `rust/` since the last build, the library and the Dart bindings
can disagree about how results are laid out, and every host then fails
with an `Unhandled: RangeError` that looks like a protocol fault. Run
`cargo build --release` from the crate directory the warning names
(`rust/` unless you passed `--library`) and try again. The run is not
blocked, because the mismatch is possible rather than certain.

## JSON output

Pass `--json` to swap the human format for newline-delimited JSON
(NDJSON). Every line is a self-contained JSON object with a stable
envelope:

| Field    | Type   | Meaning                                              |
| -------- | ------ | ---------------------------------------------------- |
| `ts`     | string | UTC ISO-8601 timestamp the event was emitted        |
| `level`  | string | `INFO`, `WARN`, or `ERROR`                          |
| `source` | string | `nts_query`, `nts_warm_cookies`, or `nts_dns_pool`  |
| `host`   | string | The hostname this event relates to (`-` when none)  |
| `event`  | string | `start`, `success`, `error`, or `dns_pool_stats`    |

`success` events for `nts_query` carry the parsed sample (`utc`,
`utc_unix_micros`, `rtt_micros`, `stratum`, `aead_id`, `aead_label`,
`cookies`); `success` events for `nts_warm_cookies` carry just the
`cookies` count. `error` events add `error_type` (the variant tag —
`Network`, `Timeout`, `Authentication`, …), `message` (the same
human-readable description text mode prints), and `severity` (`warn`
or `error`).

Two envelope fields are conditional, because they describe the
invocation rather than any one handshake: `trust_mode` appears only
when `--trust-mode` was passed, and `required_trust_backend` only when
`--require-trust-backend` was. A run using neither flag produces
exactly the records it always has. When present they ride every record
in the stream, including the trailing `dns_pool_stats` one, so a
consumer can read the policy off whichever line it happens to hold.

A `--require-trust-backend` mismatch arrives as an `error` event with
`error_type` set to `TrustBackendMismatch`, alongside the negotiated
`trust_backend`. The tag sits in the same namespace as the protocol
error tags and does not collide with any of them, so `jq` can tell a
policy assertion failure from a server-side one:

```bash
… --json --require-trust-backend platform 2>&1 \
  | jq -r 'select(.error_type == "TrustBackendMismatch") | .host'
```

The trailing DNS pool lines cannot appear as a block here without
breaking the one-object-per-line rule, so they arrive as a final
`dns_pool_stats` event carrying the same figures described under
[DNS pool line](#dns-pool-line-nts_dns_pool): `refused`, `spawn_failed`
and `recovered` for the run, `in_flight` and `high_water_mark` for the
process.

```text
{"ts":"…","level":"INFO","source":"nts_query","host":"nts.netnod.se","event":"start"}
{"ts":"…","level":"INFO","source":"nts_query","host":"nts.netnod.se","event":"success","utc_unix_micros":…,"utc":"…","rtt_micros":68570,"stratum":1,"aead_id":15,"aead_label":"AES-SIV-CMAC-256(15)","cookies":2}
{"ts":"…","level":"INFO","source":"nts_dns_pool","host":"-","event":"dns_pool_stats","refused":0,"spawn_failed":0,"recovered":2,"in_flight":0,"high_water_mark":2}
```

Successes still go to stdout, failures still go to stderr — the same
stream split as text mode — so `jq` over stdout sees only the working
hosts and stderr captures the diagnostic stream cleanly.

## Streams and exit codes

`INFO` lines go to **stdout**; `WARN` and `ERROR` go to **stderr**, so
you can pipe a successful run into another tool while still seeing
problem reports separately. The split applies in both text and `--json`
mode.

| Code | Meaning                                                                  |
| ---- | ------------------------------------------------------------------------ |
| `0`  | The engine started and every host completed (success or fail)            |
| `1`  | `--exit-on-error` was passed and at least one host produced warn / error, including a trust-backend mismatch |
| `64` | Argument problem (bad `--port`, `--timeout`, no hosts given, an unreadable `--custom-roots` file, or a `--trust-mode` / `--custom-roots` pairing that cannot be honoured) |
| `70` | The engine itself failed to start                                        |

By default, a run where every host produced a `WARN` still exits `0`
provided the engine itself initialised — the CLI treats per-host
failures as information, not as an overall command failure. Pass
`--exit-on-error` to opt into the stricter "any failure is a failure"
semantics commonly expected by CI runners.

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
| `-t`, `--timeout <ms>`     | Per-request timeout, in milliseconds. Applied independently to the handshake and to the time request, so the worst-case wall time is roughly twice the value passed. | 5000    |
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

## JSON output

Pass `--json` to swap the human format for newline-delimited JSON
(NDJSON). Every line is a self-contained JSON object with a stable
envelope:

| Field    | Type   | Meaning                                              |
| -------- | ------ | ---------------------------------------------------- |
| `ts`     | string | UTC ISO-8601 timestamp the event was emitted        |
| `level`  | string | `INFO`, `WARN`, or `ERROR`                          |
| `source` | string | `nts_query` or `nts_warm_cookies`                   |
| `host`   | string | The hostname this event relates to                  |
| `event`  | string | `start`, `success`, or `error`                      |

`success` events for `nts_query` carry the parsed sample (`utc`,
`utc_unix_micros`, `rtt_micros`, `stratum`, `aead_id`, `aead_label`,
`cookies`); `success` events for `nts_warm_cookies` carry just the
`cookies` count. `error` events add `error_type` (the variant tag —
`Network`, `Timeout`, `Authentication`, …), `message` (the same
human-readable description text mode prints), and `severity` (`warn`
or `error`).

```text
{"ts":"…","level":"INFO","source":"nts_query","host":"nts.netnod.se","event":"start"}
{"ts":"…","level":"INFO","source":"nts_query","host":"nts.netnod.se","event":"success","utc_unix_micros":…,"utc":"…","rtt_micros":68570,"stratum":1,"aead_id":15,"aead_label":"AES-SIV-CMAC-256(15)","cookies":2}
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
| `1`  | `--exit-on-error` was passed and at least one host produced warn / error |
| `64` | Argument problem (bad `--port`, `--timeout`, no hosts given)             |
| `70` | The engine itself failed to start                                        |

By default, a run where every host produced a `WARN` still exits `0`
provided the engine itself initialised — the CLI treats per-host
failures as information, not as an overall command failure. Pass
`--exit-on-error` to opt into the stricter "any failure is a failure"
semantics commonly expected by CI runners.

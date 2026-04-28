# `nts` example — GUI user manual

A walkthrough of the `nts` example desktop / mobile application: what each
panel does, how to drive a query, and what the on-screen feedback means.
This guide assumes the app is already installed and launches successfully;
for setup notes see the [main README](README.md).

## Visual identity

The app uses the indigo brand colour (`#3F51B5`) for the title
bar text, primary action buttons, and selection highlights. The chrome
itself sits on a clean light or dark surface that follows your operating
system's theme — the brand colour is meant to read as an accent, not as a
dominant background. Amber is reserved for two specific things:

- **Favourite stars** in the server list.
- **Warning entries** in the live log (timeouts, network errors,
  no-cookies responses).

These are the only colour codes you need to interpret at a glance.

## Layout

Three stacked panels, top to bottom:

| Panel             | Role                                              |
| ----------------- | ------------------------------------------------- |
| **Server list**   | Browse, filter, and select an NTS server.         |
| **Action strip**  | Trigger a time query or a cookie-warming request. |
| **Live log**      | Read, copy, and share the results of every run.   |

The panel split is fixed at roughly half-and-half between the server list
and the log, with the action strip occupying its natural height in
between.

## Server list

The list is loaded from a curated catalog of public NTS-KE servers
maintained as part of the app. Each row shows the server hostname, the
operator (e.g. Cloudflare, Netnod, PTB), the geographic region, and —
where the operator publishes it — the NTP stratum.

### Searching

Type any substring into the **Search** field at the top of the panel:
hostname, operator name, country, or any free-form note attached to the
server. Matching is case-insensitive and updates as you type.

### Filtering by region

Use the **Region** dropdown to narrow the list to servers physically
located in a particular country or zone. Choosing **All regions** clears
the filter.

### Favourites

Tap the star icon on the left of a row to pin a server. Pinned servers:

- Persist between launches (saved to local app preferences — no account
  or cloud sync involved).
- Always sort to the top of the list, in the order you pinned them.
- Can be the only servers shown by toggling the **Favourites only** chip
  next to the region dropdown.

To unpin, tap the gold star a second time.

### Selecting a server

Tap any row to mark it as the active target. The row is highlighted and
the action buttons become enabled. Only one server is active at a time;
tapping a different row reassigns the selection.

If no server is selected (e.g. immediately after launch, or when filters
hide every row), both action buttons are greyed out.

## Actions

Two buttons sit between the server list and the log:

- **NTS Query** — performs a full RFC 8915 exchange against the selected
  server: a Network Time Security key-establishment handshake followed by
  an authenticated NTP time request. The result is an authoritative time
  sample with round-trip latency and stratum.
- **Warm Cookies** — runs only the key-establishment leg and refreshes the
  pool of single-use authentication cookies the client keeps for the
  selected server. The pool size is set by the server's NTS-KE policy
  (RFC 8915 §4) and is reported in the live log as the
  `recovered N fresh cookie(s)` count. Use this if you plan to make a
  burst of subsequent queries and want to amortise the handshake cost.

Both actions are **re-entrant**: tap them as many times as you like, with
or without changing the selected server in between, and every request
runs concurrently. Results land in the log in the order they complete,
which usually reflects each server's response time.

## Live log

Every action emits one or more log entries, prefixed with a UTC
timestamp, a severity (`INFO`, `WARN`, `ERROR`), the operation name, and
the host in square brackets. A successful query produces a two-line
entry — a headline with the round-trip time and the server's reported
UTC, and an indented continuation with the cryptographic detail
(authenticated-encryption algorithm and remaining cookie count).

### Reading round-trip times

The `rtt=` field auto-selects units so the value stays compact:
microseconds (`µs`) for sub-millisecond responses, milliseconds (`ms`)
for typical internet round trips, seconds (`s`) for the rare slow
response. You can compare values across servers without converting.

### Reading the AEAD label

The `aead=` field names the authenticated-encryption algorithm the
server negotiated during the handshake. `AES-SIV-CMAC-256(15)` is the
RFC 8915 mandatory baseline and what every server in the bundled catalog
uses today; the parenthesised number is the IANA registry id.

### Copying and sharing

The log is rendered as selectable text, so you can drag-select any
substring (a single error line, the cryptographic detail of a successful
query, the whole buffer) and copy with the standard system shortcut. A
share button is available in the log header for handing the entire
buffer off to Mail, Files, AirDrop, or whatever sharing destinations
your platform exposes.

## Status banners

Two banners can appear at the top of the window — both indicate that the
app is in a degraded mode and is telling you why so you don't read the
results as authoritative:

- **mock fallback** — the app could not load the native Network Time
  Security engine on this device and is running against a built-in
  simulator instead. Time samples in this mode are synthesised, not real
  measurements; treat them as UI placeholders only.
- **Server catalog is empty** / **Failed to load servers** — the bundled
  list of servers is missing or could not be parsed. The action buttons
  stay disabled because there is nothing to probe. The header label next
  to the title also reflects the active mode (`real bridge`, `mock`, or
  `mock (load failed)`).

In normal operation, neither banner is visible.

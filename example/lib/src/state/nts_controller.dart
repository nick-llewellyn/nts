// Action dispatcher between the UI and the nts API.
//
// Funnels every invocation through the live log buffer and translates
// `NtsError` variants into severity-tagged log entries. Kept separate
// from `AppState` so the home page widget can wire button presses
// without reaching into signal mutation logic, and so widget tests can
// stub out individual operations without faking the whole state graph.
//
// Operations are intentionally re-entrant: each call is a fire-and-
// forget `Future` that races independently and posts its own start /
// outcome lines into the log. The user can launch overlapping queries
// against the same or different servers; results interleave in the log
// in completion order, tagged by `host` so they can be told apart.
//
// All success / failure detail goes straight into the log buffer
// rather than into separate result signals — the on-screen log is
// the single canonical surface for query outcomes.

import 'dart:developer' as developer;

import 'package:nts/nts.dart'
    show
        NtsClient,
        NtsError,
        NtsErrorAuthentication,
        NtsErrorInternal,
        NtsErrorInvalidSpec,
        NtsErrorKeProtocol,
        NtsErrorNetwork,
        NtsErrorNoCookies,
        NtsErrorNtpProtocol,
        NtsErrorTimeout,
        NtsErrorTrustBackendUnavailable,
        TrustBackend,
        TrustMode;

import '../data/server_entry.dart';
import 'app_state.dart';
import 'nts_format.dart';

/// `dart:developer.log` channel name used for every host-tagged
/// signal-update correlation line. Picked so a console reader can
/// filter on the channel name (matched verbatim against the constant
/// below) and pair the result against the unstructured
/// `[log] signal updated: [...]` lines emitted by `package:signals`
/// in debug mode. Signals' own console output carries no host
/// context, so without these companion lines a console-side reader
/// cannot tell which `runQuery` / `warmCookies` invocation produced
/// a given `lastHandshakeBackend` mutation.
const String _kDeveloperLogName = 'nts.example.controller';

/// Per-request timeout in milliseconds. Single global wall-clock
/// budget that spans DNS, NTS-KE (TCP connect, TLS handshake,
/// record I/O) and the AEAD-NTPv4 UDP exchange as one shrinking
/// deadline — see the `ntsQuery` dartdoc in `package:nts/nts.dart`
/// for the full mechanism. Mirrors the value the original example
/// used.
const int _kTimeoutMs = 5000;

class NtsController {
  NtsController(this.state)
    : _client = NtsClient(trustMode: state.trustMode.value),
      // Initialize from the same source-of-truth that built `_client`
      // so the two cannot diverge if the caller starts the app under
      // a non-default trust mode (e.g. a future deeplink that pre-
      // populates `state.trustMode` to `platformOnly` before the
      // controller is constructed).
      _activeMode = state.trustMode.value {
    // Re-mint the per-instance NtsClient whenever the user toggles
    // the trust-mode signal. TrustMode is a construction-time
    // parameter on the Rust side; replacing the handle is the only
    // way to switch policies without restarting the app. The
    // previous client's cached cookie pool is dropped on the floor
    // intentionally — the demo's whole point is to make the cold-
    // start cost of each policy visible.
    state.trustMode.subscribe((_) => _onTrustModeChanged());
  }

  final AppState state;

  /// Active per-instance NTS client. Owns its own per-host session
  /// table so the demo's trust-mode toggle doesn't bleed cookies /
  /// keys between policies.
  NtsClient _client;

  /// Trust mode the active [_client] was constructed with. Tracked
  /// independently of [AppState.trustMode] so the subscription
  /// callback can short-circuit redundant reconstructions when the
  /// signal fires with the same value (e.g. during initial
  /// listener attachment). Initialized from [AppState.trustMode] so
  /// the two stay in lockstep from construction onward.
  TrustMode _activeMode;

  void _onTrustModeChanged() {
    final next = state.trustMode.value;
    if (next == _activeMode) return;
    _activeMode = next;
    _client = NtsClient(trustMode: next);
    // The previous client's last-handshake backend belongs to a
    // policy that no longer applies; clearing the signal puts the
    // panel back to its "no per-client handshake yet" sentinel
    // until the new client completes a query / warm. Anything else
    // would let the panel display a backend attribution from a
    // session table that has just been dropped. The clear is routed
    // through `_setLastHandshakeBackend` so the console-side
    // correlation log records the reset alongside the new mode,
    // matching the host-tagged trace shape used by query / warm
    // success paths.
    _setLastHandshakeBackend(
      host: null,
      backend: null,
      source: 'trust_mode_toggle',
    );
    state.log.info(
      'system',
      'TrustMode → ${formatTrustMode(next)} '
          '(new NtsClient minted; cached sessions dropped)',
      trustMode: next,
    );
    developer.log(
      'TrustMode toggled → ${next.name} '
      '(new NtsClient minted; cached sessions dropped)',
      name: _kDeveloperLogName,
    );
  }

  /// Single mutation point for `state.lastHandshakeBackend`.
  ///
  /// Pairs every signal write with a `dart:developer.log` line that
  /// carries explicit `host=` / `backend=` context, so a console
  /// reader can correlate the otherwise host-less
  /// `[log] signal updated: [N|null] => TrustBackend.<v>` lines that
  /// `package:signals` emits in debug builds with the per-handshake
  /// invocation that produced them. Without this companion trace it
  /// is not possible from the console alone to attribute, e.g., a
  /// `platformWithHybridFallback` reading to a specific host when
  /// two queries fire back-to-back against different servers.
  ///
  /// `host == null` is reserved for resets (TrustMode toggle); the
  /// emitted log line says `host=(reset)` so the trace is still
  /// grep-friendly.
  void _setLastHandshakeBackend({
    required String? host,
    required TrustBackend? backend,
    required String source,
  }) {
    state.lastHandshakeBackend.value = backend;
    developer.log(
      'lastHandshakeBackend := ${backend?.name ?? '(null)'} '
      '[host=${host ?? '(reset)'}] [source=$source]',
      name: _kDeveloperLogName,
    );
  }

  /// Run a single authenticated NTPv4 query against `entry`.
  ///
  /// ### Cold start (first call for a given host:port)
  ///
  /// The first invocation against a previously-unseen `host:port` pair
  /// triggers a full NTS-KE handshake inside the Rust crate before the
  /// NTPv4 exchange runs. That handshake is, in order: a TCP connect to
  /// port 4460, a TLS 1.3 handshake (no session-ticket resumption — the
  /// crate does not cache tickets), and the NTS-KE record exchange that
  /// negotiates the AEAD algorithm and retrieves the initial cookie
  /// pool. Only after the TLS connection is closed does the
  /// authenticated UDP round-trip fire. End-to-end this is roughly
  /// 4 RTTs (TCP + TLS + KE + NTP) and accounts for the "slight delay"
  /// observed on the first button press for a server.
  ///
  /// ### Steady state (cached session, cookies remaining)
  ///
  /// Subsequent calls reuse the cached AEAD keys and spend one stored
  /// cookie on a single authenticated UDP round-trip — ~1 RTT total,
  /// effectively instantaneous on a healthy path. The pool is replenished
  /// in-band: each successful query asks the server for one fresh cookie
  /// in the encrypted reply, so steady state is self-sustaining until
  /// the keys rotate or the pool drains.
  ///
  /// ### Attribution
  ///
  /// The cold-start cost is a property of the NTS protocol (RFC 8915
  /// §4) — it is the price of mutual authentication and forward secrecy,
  /// not bridge overhead. By the time this method is reachable from the
  /// UI, `RustLib.init()` has already been awaited during bootstrap, the
  /// native library is loaded via the Native Assets pipeline, and the
  /// FRB worker pool is up. Per-call FFI overhead is microseconds, well
  /// below user-perceptible latency. This GUI is a protocol-observation
  /// tool: the delay you see is the protocol working as designed.
  ///
  /// ### Production note
  ///
  /// Real-world clients should amortize the KE leg by calling
  /// [ntsWarmCookies] at app startup or in the background ahead of any
  /// time-critical query, populating the cookie jar so the user-visible
  /// path is always the 1-RTT steady state. The CLI sample in
  /// `example/main.dart` demonstrates the pattern: warm first, then
  /// query. This GUI deliberately exposes warm and query as separate
  /// buttons so the protocol cost remains visible — the contrast
  /// between a cold press and a warm press is part of what the demo is
  /// meant to illustrate.
  Future<void> runQuery(NtsServerEntry entry) async {
    state.log.info('nts_query', 'Starting query', host: entry.hostname);
    // Capture the active client identity at start. If the user flips
    // the trust-mode toggle while this query is in-flight,
    // `_onTrustModeChanged` will mint a new `_client`; the in-flight
    // future then completes against a session that has been dropped.
    // Comparing identity on resume lets the success / state-write
    // path tell stale completions apart from live ones.
    final clientAtStart = _client;
    try {
      final sample = await clientAtStart.query(
        spec: entry.spec,
        timeoutMs: _kTimeoutMs,
      );
      final stale = !identical(clientAtStart, _client);
      state.log.info(
        'nts_query',
        stale
            ? '${formatQuerySuccess(sample)}\n'
                  '    \u2514\u2500 (from previous TrustMode; '
                  'state intentionally not updated)'
            : formatQuerySuccess(sample),
        host: entry.hostname,
        trustBackend: sample.trustBackend,
      );
      // Per-handshake backend goes straight onto AppState so the
      // trust-status panel's "last handshake" row reflects what the
      // currently-active caller-minted client used. Stale completions
      // skip the write so a dropped client cannot overwrite the
      // active client's attribution.
      if (!stale) {
        _setLastHandshakeBackend(
          host: entry.hostname,
          backend: sample.trustBackend,
          source: 'nts_query',
        );
      }
    } on NtsError catch (err) {
      _logError('nts_query', err, entry.hostname);
    } catch (err, stack) {
      // Anything that escapes `NtsError` is unexpected — surface it
      // loudly in the log so the developer can pair it with a
      // platform-side stack trace.
      state.log.error(
        'nts_query',
        'Unhandled: $err\n$stack',
        host: entry.hostname,
      );
    }
  }

  Future<void> warmCookies(NtsServerEntry entry) async {
    state.log.info('nts_warm_cookies', 'Starting warm', host: entry.hostname);
    final clientAtStart = _client;
    try {
      final outcome = await clientAtStart.warmCookies(
        spec: entry.spec,
        timeoutMs: _kTimeoutMs,
      );
      final stale = !identical(clientAtStart, _client);
      state.log.info(
        'nts_warm_cookies',
        stale
            ? '${formatWarmSuccess(outcome)}\n'
                  '    \u2514\u2500 (from previous TrustMode; '
                  'state intentionally not updated)'
            : formatWarmSuccess(outcome),
        host: entry.hostname,
        trustBackend: outcome.trustBackend,
      );
      if (!stale) {
        _setLastHandshakeBackend(
          host: entry.hostname,
          backend: outcome.trustBackend,
          source: 'nts_warm_cookies',
        );
      }
    } on NtsError catch (err) {
      _logError('nts_warm_cookies', err, entry.hostname);
    } catch (err, stack) {
      state.log.error(
        'nts_warm_cookies',
        'Unhandled: $err\n$stack',
        host: entry.hostname,
      );
    }
  }

  void _logError(String source, NtsError err, String host) {
    final message = describeError(err);
    // Variants whose precondition is "TLS handshake reached config-
    // build time" carry the per-handshake trust-backend; thread it
    // into the log entry so the on-screen log can attribute the
    // failure to the same backend the success path would have shown.
    // Variants that pre-date config construction have a `null`
    // backend; the LogEntry just leaves the field unset.
    final backend = switch (err) {
      NtsErrorNetwork(:final trustBackend) => trustBackend,
      NtsErrorKeProtocol(:final trustBackend) => trustBackend,
      NtsErrorNtpProtocol(:final trustBackend) => trustBackend,
      NtsErrorAuthentication(:final trustBackend) => trustBackend,
      NtsErrorTimeout(:final trustBackend) => trustBackend,
      NtsErrorNoCookies(:final trustBackend) => trustBackend,
      NtsErrorInvalidSpec() ||
      NtsErrorTrustBackendUnavailable() ||
      NtsErrorInternal() => null,
    };
    if (isErrorSeverity(err)) {
      state.log.error(source, message, host: host, trustBackend: backend);
    } else {
      state.log.warn(source, message, host: host, trustBackend: backend);
    }
  }
}

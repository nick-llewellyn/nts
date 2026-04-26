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

import 'package:nts/nts.dart' show NtsError, ntsQuery, ntsWarmCookies;

import '../data/server_entry.dart';
import 'app_state.dart';
import 'nts_format.dart';

/// Per-request timeout applied independently to NTS-KE and the UDP
/// recv leg. Mirrors the value the original example used.
const int _kTimeoutMs = 5000;

class NtsController {
  NtsController(this.state);

  final AppState state;

  Future<void> runQuery(NtsServerEntry entry) async {
    state.log.info('nts_query', 'Starting query', host: entry.hostname);
    try {
      final sample = await ntsQuery(spec: entry.spec, timeoutMs: _kTimeoutMs);
      state.log.info(
        'nts_query',
        formatQuerySuccess(sample),
        host: entry.hostname,
      );
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
    try {
      final n = await ntsWarmCookies(spec: entry.spec, timeoutMs: _kTimeoutMs);
      state.log.info(
        'nts_warm_cookies',
        formatWarmSuccess(n),
        host: entry.hostname,
      );
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
    if (isErrorSeverity(err)) {
      state.log.error(source, message, host: host);
    } else {
      state.log.warn(source, message, host: host);
    }
  }
}

// Renderers for a batch of [ServerHealth] verdicts.
//
// Pure and Flutter-free: turns the classifier output into the three
// shapes `bin/nts_health.dart` emits — a human-readable ranked report,
// machine-readable JSON/CSV, and a bare "suggested removals" hostname
// list. Kept separate from the classifier so the decision logic and its
// presentation can be tested independently.

import '../state/nts_format.dart' show aeadLabel, formatRtt;
import 'server_health.dart';

/// Hostnames of every drop candidate (verdict != healthy), sorted.
List<String> dropList(List<ServerHealth> all) =>
    all.where((h) => h.isDropCandidate).map((h) => h.hostname).toList()..sort();

/// One JSON object per host, stable field set. `null` numeric fields
/// mean "no successful sample" (the host is in an error bucket).
List<Map<String, Object?>> jsonReport(List<ServerHealth> all) => [
  for (final h in all)
    {
      'host': h.hostname,
      'verdict': h.verdict.name,
      'probes': h.probes,
      'successes': h.successes,
      'reasons': h.reasons,
      if (h.note != null) 'note': h.note,
      'median_rtt_micros': h.medianRttMicros,
      'stratum': h.stratum,
      'aead_id': h.aeadId,
      'aead_label': h.aeadId == null ? null : aeadLabel(h.aeadId!),
      'offset_micros': h.offsetMicros,
      'error_type': h.dominantErrorType,
    },
];

/// RFC 4180-ish CSV with a fixed header row. `reasons` are joined with
/// `|` so the column stays single-valued.
String csvReport(List<ServerHealth> all) {
  final b = StringBuffer()
    ..writeln(
      'host,verdict,probes,successes,median_rtt_micros,stratum,'
      'aead_id,offset_micros,error_type,reasons',
    );
  for (final h in all) {
    b.writeln(
      [
        _csv(h.hostname),
        h.verdict.name,
        '${h.probes}',
        '${h.successes}',
        '${h.medianRttMicros ?? ''}',
        '${h.stratum ?? ''}',
        '${h.aeadId ?? ''}',
        '${h.offsetMicros ?? ''}',
        h.dominantErrorType ?? '',
        _csv(h.reasons.join('|')),
      ].join(','),
    );
  }
  return b.toString();
}

/// Quote a CSV field iff it contains a comma, quote, or newline,
/// doubling any embedded quotes.
String _csv(String field) {
  if (!field.contains(RegExp('[",\n]'))) return field;
  return '"${field.replaceAll('"', '""')}"';
}

/// Hosts of one verdict, sorted by hostname.
List<ServerHealth> _byHost(List<ServerHealth> all, HealthVerdict v) =>
    all.where((h) => h.verdict == v).toList()
      ..sort((a, b) => a.hostname.compareTo(b.hostname));

/// Human-readable report: a summary line, the healthy hosts ranked by
/// median RTT, one section per error bucket, and the drop-list.
String renderTextReport(
  List<ServerHealth> all, {
  String? source,
  int samples = 1,
}) {
  final healthy = _byHost(all, HealthVerdict.healthy)
    ..sort(
      (a, b) => (a.medianRttMicros ?? 1 << 62).compareTo(
        b.medianRttMicros ?? 1 << 62,
      ),
    );
  final nonStd = _byHost(all, HealthVerdict.nonStandard);
  final noReply = _byHost(all, HealthVerdict.notReplying);
  final nonConf = _byHost(all, HealthVerdict.nonConforming);

  final b = StringBuffer()
    ..writeln('NTS server health report')
    ..writeln('========================')
    ..writeln(
      '${source == null ? '' : 'source: $source   '}'
      'probed: ${all.length} host(s) \u00d7 $samples sample(s)',
    )
    ..writeln();

  b.writeln('Healthy (${healthy.length}), ranked by median RTT:');
  if (healthy.isEmpty) {
    b.writeln('  (none)');
  } else {
    for (final h in healthy) {
      final rtt = formatRtt(h.medianRttMicros ?? 0).padLeft(9);
      final st = 'stratum=${h.stratum}'.padRight(11);
      final aead = aeadLabel(h.aeadId ?? -1).padRight(22);
      final off = (h.offsetMicros == null ? '' : offsetLabel(h.offsetMicros!))
          .padLeft(9);
      final note = h.note == null ? '' : '  (${h.note})';
      b.writeln('  $rtt  $st  $aead  $off  ${h.hostname}$note');
    }
  }
  b.writeln();

  _writeIssueSection(b, 'Non-standard', nonStd, (h) => h.reasons.join('; '));
  _writeIssueSection(
    b,
    'Not replying',
    noReply,
    (h) => h.dominantErrorType ?? 'no reply',
  );
  _writeIssueSection(
    b,
    'Non-conforming',
    nonConf,
    (h) => h.dominantErrorType ?? 'protocol error',
  );

  b.writeln(
    'Summary: ${healthy.length} healthy, ${nonStd.length} non-standard, '
    '${noReply.length} not replying, ${nonConf.length} non-conforming '
    '(${all.length} total)',
  );

  final drops = dropList(all);
  b
    ..writeln()
    ..writeln('Suggested removals (${drops.length}):');
  if (drops.isEmpty) {
    b.writeln('  (none)');
  } else {
    for (final h in drops) {
      b.writeln('  $h');
    }
  }
  return b.toString();
}

/// Render one error bucket: a `title (count):` header followed by a
/// hostname-aligned `host  detail` row per host.
void _writeIssueSection(
  StringBuffer b,
  String title,
  List<ServerHealth> hosts,
  String Function(ServerHealth) detail,
) {
  b.writeln('$title (${hosts.length}):');
  if (hosts.isEmpty) {
    b.writeln('  (none)');
  } else {
    final w = hosts
        .map((h) => h.hostname.length)
        .fold(0, (a, c) => c > a ? c : a);
    for (final h in hosts) {
      b.writeln('  ${h.hostname.padRight(w)}  ${detail(h)}');
    }
  }
  b.writeln();
}

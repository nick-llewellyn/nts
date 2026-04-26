// In-memory representation of one server record from
// `assets/nts-sources.yml`.
//
// The YAML is a publicly-curated list of NTP / NTS-KE endpoints with a
// fixed schema (`hostname`, `stratum`, `location`, `owner`, `notes`,
// `vm`). Two of those fields — `hostname` and `owner` — sometimes
// arrive wrapped in Markdown link syntax (`[label](url)`) because the
// upstream gist renders to HTML. We split that form into a clean
// `hostname` / `owner` plus an optional `*Url` so the UI can render
// either a tappable link or plain text without re-parsing on every
// build.
//
// All entries are addressed on TCP/4460 — the IANA-assigned NTS-KE
// port — because the YAML doesn't carry a `port` column. Hosts in the
// list that don't actually advertise NTS-KE on that port will surface
// as `NtsError.network` / `NtsError.timeout` once the user runs an
// `ntsQuery` against them; that's expected and is part of why the
// example app streams every result into the live log view.

import 'package:nts/nts.dart' show NtsServerSpec;

/// Default NTS-KE port from RFC 8915 §4. The bundled YAML never
/// overrides it.
const int kNtsKePort = 4460;

/// One row from the bundled NTS server catalog.
class NtsServerEntry {
  const NtsServerEntry({
    required this.hostname,
    required this.location,
    required this.owner,
    this.displayUrl,
    this.ownerUrl,
    this.stratum,
    this.notes,
    this.vm = false,
  });

  /// Canonical DNS name used for SNI, certificate validation, and as
  /// the stable identity key for favourites / selection.
  final String hostname;

  /// Optional companion URL extracted from the upstream Markdown link
  /// form on the `hostname` field. Surfaced in the UI when present so
  /// the user can navigate to the operator's about page.
  final String? displayUrl;

  /// Operator name as written in the YAML (Markdown wrapper stripped).
  final String owner;

  /// Optional companion URL extracted from the upstream Markdown link
  /// form on the `owner` field.
  final String? ownerUrl;

  /// Geographic / topological grouping copied verbatim from the YAML
  /// `location` column. Most values are country names ("Brazil",
  /// "US") but two are categorical ("All" for global anycast,
  /// "Distro" for distribution-only NTP pools); the UI surfaces them
  /// as-is rather than trying to second-guess the upstream taxonomy.
  final String location;

  /// NTP stratum reported by the upstream curator. Optional because
  /// the field is sometimes omitted.
  final int? stratum;

  /// Free-form remark from the YAML (e.g. "Anycast", "IPv4 and
  /// IPv6"). Optional.
  final String? notes;

  /// Whether the operator self-identifies as running on a VM.
  final bool vm;

  /// Stable identity for favourites persistence and selection
  /// equality. Keyed off `hostname` because the catalog never
  /// contains duplicates and we always speak the same TCP port.
  String get id => hostname;

  /// FRB-friendly address record consumed by `ntsQuery` and
  /// `ntsWarmCookies`.
  NtsServerSpec get spec => NtsServerSpec(host: hostname, port: kNtsKePort);
}

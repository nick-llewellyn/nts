// Country -> geographic region mapping for the reliable-server manifest.
//
// The bundled catalog (`assets/nts-sources.yml`) carries a free-form
// `location` column that is almost always a country name ("Germany",
// "Brazil", "US") plus one categorical value, "All", used for the
// Cloudflare global anycast endpoint. The manifest generator
// (`bin/nts_manifest.dart`) groups healthy servers by *region* so a
// downstream client can pick a nearby pool without runtime geolocation,
// so we collapse those country names onto a small, fixed set of regions.
//
// Pure and Flutter-free (a plain lookup table) so it is trivially
// unit-testable and usable from the `dart run` CLI. Matching is
// case-insensitive and a few common aliases are folded in; anything
// unrecognised falls back to [kRegionOther] rather than being dropped,
// so a new catalog `location` never silently disappears from the audit.

/// Anycast / globally-distributed endpoints (catalog `location: All`).
const String kRegionGlobal = 'Global';
const String kRegionNorthAmerica = 'North America';
const String kRegionSouthAmerica = 'South America';
const String kRegionEurope = 'Europe';
const String kRegionAsia = 'Asia';

/// Catch-all for unrecognised or non-geographic `location` values
/// (e.g. "Distro", "Unknown", or a continent not yet enumerated such as
/// Oceania/Africa). Kept distinct so these surface in the manifest's
/// `other` bucket instead of being misfiled into a real region.
const String kRegionOther = 'Other';

/// Canonical, deterministic ordering for manifest output. Regions with
/// no selected servers are simply omitted by the builder, but when
/// present they always appear in this order.
const List<String> kRegionOrder = [
  kRegionGlobal,
  kRegionNorthAmerica,
  kRegionSouthAmerica,
  kRegionEurope,
  kRegionAsia,
  kRegionOther,
];

/// Lower-cased catalog `location` -> region. Keys cover every value in
/// the bundled YAML plus common aliases so the mapping is robust to
/// minor upstream spelling drift.
const Map<String, String> _locationToRegion = {
  // Global anycast.
  'all': kRegionGlobal,
  'anycast': kRegionGlobal,
  // North America.
  'us': kRegionNorthAmerica,
  'usa': kRegionNorthAmerica,
  'united states': kRegionNorthAmerica,
  'canada': kRegionNorthAmerica,
  'mexico': kRegionNorthAmerica,
  // South America.
  'brazil': kRegionSouthAmerica,
  'argentina': kRegionSouthAmerica,
  'chile': kRegionSouthAmerica,
  // Europe.
  'belgium': kRegionEurope,
  'croatia': kRegionEurope,
  'czech republic': kRegionEurope,
  'czechia': kRegionEurope,
  'finland': kRegionEurope,
  'france': kRegionEurope,
  'germany': kRegionEurope,
  'netherlands': kRegionEurope,
  'sweden': kRegionEurope,
  'switzerland': kRegionEurope,
  'uk': kRegionEurope,
  'united kingdom': kRegionEurope,
  'gb': kRegionEurope,
  'ireland': kRegionEurope,
  'denmark': kRegionEurope,
  'norway': kRegionEurope,
  'poland': kRegionEurope,
  'spain': kRegionEurope,
  'portugal': kRegionEurope,
  'italy': kRegionEurope,
  'austria': kRegionEurope,
  // Asia.
  'singapore': kRegionAsia,
  'japan': kRegionAsia,
  'india': kRegionAsia,
  'china': kRegionAsia,
  'hong kong': kRegionAsia,
  'south korea': kRegionAsia,
  'taiwan': kRegionAsia,
};

/// Region for a catalog [location] value. Case- and whitespace-
/// insensitive; unrecognised values map to [kRegionOther].
String regionForLocation(String location) {
  final key = location.trim().toLowerCase();
  return _locationToRegion[key] ?? kRegionOther;
}

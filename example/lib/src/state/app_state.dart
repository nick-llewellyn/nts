// Top-level signals graph for the example app.
//
// Owns the loaded server catalog, the user's filter / search /
// favourites inputs, the currently-selected server, and the live log
// buffer. Exposes one computed signal — [filteredServers] — that
// produces the list the UI renders after applying every active filter
// and pulling favourites to the top.
//
// There is no global "busy" signal: NTS operations are re-entrant and
// race independently. Each call posts its own start / outcome lines
// into [log], tagged by host, so overlapping invocations stay
// distinguishable in the on-screen timeline.
//
// The catalog itself is loaded once during bootstrap and never
// mutated. Every other piece of state is a `Signal<…>` whose updates
// propagate through `filteredServers` automatically thanks to the
// signals-core dependency tracking.

import 'package:signals/signals.dart'
    show Computed, ReadonlySignal, Signal, computed, signal;

import '../data/server_entry.dart';
import 'favorites_store.dart';
import 'log_buffer.dart';

/// Sentinel value used by [regionFilter] to represent "no filter".
const String kAllRegions = 'All regions';

/// Catalog-side `location` value marking a server as globally
/// reachable (e.g. anycast). Treated as a wildcard by the region
/// filter: universal servers are always visible, and the value is
/// suppressed from the region dropdown so it can't be selected
/// directly (it would behave identically to [kAllRegions]).
const String kUniversalLocation = 'All';

/// Aggregate state container injected once at startup. Held by the
/// top-level widget tree so children can read individual signals
/// without dragging around a half-dozen parameters.
class AppState {
  AppState({
    required this.bridgeMode,
    required this.bridgeLoadError,
    required this.catalog,
    required this.favorites,
    required this.log,
  }) : selected = signal<NtsServerEntry?>(
         catalog.isEmpty ? null : catalog.first,
       ),
       searchQuery = signal<String>(''),
       regionFilter = signal<String>(kAllRegions),
       favoritesOnly = signal<bool>(false) {
    filteredServers = computed<List<NtsServerEntry>>(_recomputeFiltered);
    regions = _collectRegions(catalog);
  }

  /// Free-form label rendered in the AppBar so the developer can
  /// tell at a glance whether the bridge is real or mocked.
  final String bridgeMode;

  /// Populated when `RustLib.init()` failed and we fell back to mock.
  /// Surfaced by the shell as a banner.
  final String? bridgeLoadError;

  /// Immutable, sorted-by-hostname server catalog loaded from
  /// `assets/nts-sources.yml` during bootstrap.
  final List<NtsServerEntry> catalog;

  /// Distinct location values seen in [catalog], plus [kAllRegions]
  /// at index 0. The [kUniversalLocation] wildcard is excluded — it
  /// is enforced by the filter pipeline rather than offered as a
  /// selectable dropdown entry. Used to populate the region filter.
  late final List<String> regions;

  /// Persistent favourites set, hydrated from `SharedPreferences`.
  final FavoritesStore favorites;

  /// Bounded ring buffer of UI log entries.
  final NtsLogBuffer log;

  /// Currently-selected server. The action buttons run against this
  /// value; tapping a row in the list updates it.
  final Signal<NtsServerEntry?> selected;

  /// Text typed into the search box. Matched against hostname,
  /// owner, and notes (case-insensitive substring).
  final Signal<String> searchQuery;

  /// Currently-selected region filter, or [kAllRegions] for none.
  final Signal<String> regionFilter;

  /// When `true`, hides every non-favourited server.
  final Signal<bool> favoritesOnly;

  /// Computed view: catalog → filtered & sorted with favourites first.
  /// Recomputes lazily whenever any of the input signals changes.
  late final Computed<List<NtsServerEntry>> filteredServers;

  /// Read-only handle suitable for passing to widgets that should
  /// observe but not mutate.
  ReadonlySignal<List<NtsServerEntry>> get filtered => filteredServers;

  List<NtsServerEntry> _recomputeFiltered() {
    final query = searchQuery.value.trim().toLowerCase();
    final region = regionFilter.value;
    final onlyFav = favoritesOnly.value;
    final favs = favorites.favorites.value;

    bool matchesQuery(NtsServerEntry e) {
      if (query.isEmpty) return true;
      return e.hostname.toLowerCase().contains(query) ||
          e.owner.toLowerCase().contains(query) ||
          (e.notes?.toLowerCase().contains(query) ?? false);
    }

    // Universal-location entries (e.g. Cloudflare anycast) bypass
    // the region filter entirely so they remain visible regardless
    // of which specific region the user selected.
    bool matchesRegion(NtsServerEntry e) =>
        region == kAllRegions ||
        e.location == kUniversalLocation ||
        e.location == region;

    bool matchesFavOnly(NtsServerEntry e) =>
        !onlyFav || favs.contains(e.hostname);

    final visible = catalog
        .where(matchesQuery)
        .where(matchesRegion)
        .where(matchesFavOnly)
        .toList(growable: false);

    // Stable sort: favourited rows float to the top, otherwise the
    // catalog's existing alphabetical ordering is preserved.
    visible.sort((a, b) {
      final fa = favs.contains(a.hostname);
      final fb = favs.contains(b.hostname);
      if (fa != fb) return fa ? -1 : 1;
      return a.hostname.compareTo(b.hostname);
    });
    return visible;
  }

  static List<String> _collectRegions(List<NtsServerEntry> catalog) {
    final unique = <String>{};
    for (final e in catalog) {
      // Skip the universal-location wildcard: it isn't a real
      // region, and selecting it from the dropdown would be
      // indistinguishable from the [kAllRegions] sentinel.
      if (e.location == kUniversalLocation) continue;
      unique.add(e.location);
    }
    final sorted = unique.toList()..sort();
    return [kAllRegions, ...sorted];
  }
}

// Persistence layer for the user's favourite servers.
//
// Stored in `SharedPreferences` under [_kPrefsKey] as a flat string
// list of hostnames. We deliberately use a flat list (and not a
// JSON-encoded blob) so the value remains diff-friendly when surfaced
// in adb / Xcode storage browsers during debugging.
//
// The store is one-way reactive: writes go through [add] / [remove],
// each of which schedules an opportunistic write back to disk. The
// signal value is kept fully in memory so reads in `Watch` rebuilds
// stay synchronous and free of `FutureBuilder` plumbing.

import 'package:shared_preferences/shared_preferences.dart';
import 'package:signals/signals.dart' show Signal, signal;

const String _kPrefsKey = 'nts_example.favorites';

/// Reactive `Set<String>` of favourited hostnames, persisted to disk.
class FavoritesStore {
  FavoritesStore._(this._prefs, Set<String> initial)
    : favorites = signal(Set.unmodifiable(initial));

  /// Construct, hydrating the in-memory set from disk. Called once
  /// during app bootstrap before `runApp`.
  static Future<FavoritesStore> load() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getStringList(_kPrefsKey) ?? const <String>[];
    return FavoritesStore._(prefs, stored.toSet());
  }

  final SharedPreferences _prefs;

  /// Live unmodifiable view of the favourite set. Wrapped in a signal
  /// so the server list view rebuilds when the user pins / unpins.
  final Signal<Set<String>> favorites;

  /// Whether the given hostname is currently favourited. Pure
  /// convenience — callers can also peek at `favorites.value` if they
  /// need the whole set.
  bool contains(String hostname) => favorites.value.contains(hostname);

  /// Toggle membership for [hostname]. Emits a new immutable set so
  /// `Watch` observers re-render even though the underlying signal
  /// type is a mutable container.
  void toggle(String hostname) {
    final next = favorites.value.toSet();
    if (!next.add(hostname)) next.remove(hostname);
    favorites.value = Set.unmodifiable(next);
    _persist();
  }

  void _persist() {
    // Fire-and-forget: SharedPreferences serialises writes internally
    // and any failure is non-fatal — the in-memory signal stays
    // authoritative for the rest of the session.
    _prefs.setStringList(_kPrefsKey, favorites.value.toList());
  }
}

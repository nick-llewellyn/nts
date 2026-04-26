// Searchable, filterable, favouritable list of NTS servers.
//
// Composed of three logical stripes stacked vertically:
//
//   1. Filter bar — search field, region dropdown, favourites-only
//      toggle. Each control writes to its own signal in [AppState];
//      the computed `filteredServers` signal recomputes on every
//      change and the list view rebuilds via `Watch`.
//   2. Empty-state hint — surfaced when filters whittle the catalog
//      down to zero rows so the user understands they're not staring
//      at a broken list.
//   3. Result list — `ListView.builder` over `filteredServers.value`.
//      Each tile carries a pin/unpin icon (writes through
//      [FavoritesStore]), a select indicator (compares against
//      `selected` signal), and a tap target that updates `selected`.
//
// The widget is stateless because every reactive bit lives in the
// shared [AppState] passed in.

import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart' show Watch;

import '../data/server_entry.dart';
import '../state/app_state.dart';

class ServerListView extends StatelessWidget {
  const ServerListView({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _FilterBar(state: state),
        const SizedBox(height: 8),
        Expanded(
          child: Watch((context) {
            final visible = state.filtered.value;
            if (visible.isEmpty) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'No servers match the current filters.',
                    style: theme.textTheme.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                ),
              );
            }
            return ListView.builder(
              itemCount: visible.length,
              itemBuilder: (context, index) =>
                  _ServerTile(state: state, entry: visible[index]),
            );
          }),
        ),
      ],
    );
  }
}

class _FilterBar extends StatelessWidget {
  const _FilterBar({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search hostname, owner or notes',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            onChanged: (v) => state.searchQuery.value = v,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Watch((context) {
                  return DropdownButtonFormField<String>(
                    initialValue: state.regionFilter.value,
                    isDense: true,
                    decoration: const InputDecoration(
                      labelText: 'Region',
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      for (final r in state.regions)
                        DropdownMenuItem<String>(value: r, child: Text(r)),
                    ],
                    onChanged: (v) {
                      if (v != null) state.regionFilter.value = v;
                    },
                  );
                }),
              ),
              const SizedBox(width: 8),
              Watch((context) {
                final active = state.favoritesOnly.value;
                return FilterChip(
                  selected: active,
                  onSelected: (v) => state.favoritesOnly.value = v,
                  showCheckmark: false,
                  avatar: Icon(
                    Icons.star,
                    size: 18,
                    color: active ? Colors.amber.shade600 : null,
                  ),
                  label: const Text('Favourites only'),
                );
              }),
            ],
          ),
        ],
      ),
    );
  }
}

class _ServerTile extends StatelessWidget {
  const _ServerTile({required this.state, required this.entry});

  final AppState state;
  final NtsServerEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Watch((context) {
      final isFavorite = state.favorites.favorites.value.contains(
        entry.hostname,
      );
      final isSelected = state.selected.value?.hostname == entry.hostname;
      return ListTile(
        dense: true,
        selected: isSelected,
        leading: IconButton(
          tooltip: isFavorite ? 'Unpin' : 'Pin',
          icon: Icon(
            isFavorite ? Icons.star : Icons.star_border,
            color: isFavorite
                ? Colors.amber.shade600
                : theme.colorScheme.onSurfaceVariant,
          ),
          onPressed: () => state.favorites.toggle(entry.hostname),
        ),
        title: Text(entry.hostname, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '${entry.location} · ${entry.owner}'
          '${entry.stratum == null ? '' : ' · stratum ${entry.stratum}'}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        onTap: () => state.selected.value = entry,
      );
    });
  }
}

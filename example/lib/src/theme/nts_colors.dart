// Semantic colour tokens for the nts example UI.
//
// The default Material 3 colour scheme covers brand surfaces (primary,
// secondary, surface, error) but not the domain-specific severity
// vocabulary the live log needs: an explicit `success` distinct from
// `info`, a `warning` distinct from `error`, and a deliberately dim
// `logTimestamp` token so the metadata column recedes against the
// message body without us having to re-derive the alpha at every call
// site. Hoisting these into a [ThemeExtension] keeps the call sites
// pure (`Theme.of(context).extension<NtsColors>()`) and lets
// downstream consumers retheme the example by overriding the extension
// rather than the `ColorScheme`.

import 'package:flutter/material.dart';

/// Domain-specific colours layered on top of the M3 [ColorScheme].
///
/// Use [NtsColors.of] to read the active values; that helper
/// gracefully falls back to brightness-aware defaults when the
/// extension hasn't been registered (e.g. inside widget tests that
/// build their own bare [MaterialApp]).
@immutable
class NtsColors extends ThemeExtension<NtsColors> {
  const NtsColors({
    required this.ntsSuccess,
    required this.ntsWarning,
    required this.ntsError,
    required this.logTimestamp,
  });

  /// Foreground colour for "OK" lines in the live log and any future
  /// success indicators (e.g. a green dot on the server list once a
  /// server has answered at least once). Mapped to [NtsLogLevel.info]
  /// in `LogView`.
  final Color ntsSuccess;

  /// Foreground colour for warn-level log lines. Held distinct from
  /// the M3 `tertiary` slot because the default seed scheme renders
  /// `tertiary` as coral, which reads too close to `error` at a
  /// glance. An explicit amber that flips shade with brightness gives
  /// a clear warn vs. error split in either light or dark mode.
  final Color ntsWarning;

  /// Foreground colour for error-level log lines. Mirrors
  /// [ColorScheme.error] by default so the live log inherits any
  /// future tweak to the M3 error tone, but is parameterised here so
  /// downstream consumers can pull it apart if the brand demands it.
  final Color ntsError;

  /// Foreground colour for the timestamp + source metadata column in
  /// the live log. A muted on-surface tone so the message body stays
  /// the visual focus.
  final Color logTimestamp;

  /// Light-mode defaults. Tuned alongside the indigo brand palette in
  /// `main.dart::_buildTheme`.
  factory NtsColors.light(ColorScheme scheme) {
    return NtsColors(
      // Material green 700 sits well against a near-white surface
      // without bleeding into the indigo primary.
      ntsSuccess: const Color(0xFF2E7D32),
      // Amber 800: still legible on light backgrounds where the more
      // common amber 400 would wash out.
      ntsWarning: const Color(0xFFFF8F00),
      ntsError: scheme.error,
      logTimestamp: scheme.onSurface.withValues(alpha: 0.55),
    );
  }

  /// Dark-mode defaults. Pairs with [NtsColors.light] so the
  /// `lerp` between brightness modes lands on coherent intermediates.
  factory NtsColors.dark(ColorScheme scheme) {
    return NtsColors(
      // Material green 400: bright enough to read on the dark surface
      // without becoming the loudest thing in the log.
      ntsSuccess: const Color(0xFF66BB6A),
      // Amber 400: matches the previous inline value in `LogView`
      // before the extension landed.
      ntsWarning: const Color(0xFFFFCA28),
      ntsError: scheme.error,
      logTimestamp: scheme.onSurface.withValues(alpha: 0.55),
    );
  }

  /// Convenience accessor used by the widgets. Returns a brightness-
  /// appropriate default when no extension has been registered, so
  /// widget tests that build their own bare `MaterialApp` keep
  /// rendering with sensible colours instead of throwing on a `!`.
  static NtsColors of(BuildContext context) {
    final theme = Theme.of(context);
    final ext = theme.extension<NtsColors>();
    if (ext != null) return ext;
    return theme.brightness == Brightness.dark
        ? NtsColors.dark(theme.colorScheme)
        : NtsColors.light(theme.colorScheme);
  }

  @override
  NtsColors copyWith({
    Color? ntsSuccess,
    Color? ntsWarning,
    Color? ntsError,
    Color? logTimestamp,
  }) {
    return NtsColors(
      ntsSuccess: ntsSuccess ?? this.ntsSuccess,
      ntsWarning: ntsWarning ?? this.ntsWarning,
      ntsError: ntsError ?? this.ntsError,
      logTimestamp: logTimestamp ?? this.logTimestamp,
    );
  }

  @override
  NtsColors lerp(ThemeExtension<NtsColors>? other, double t) {
    if (other is! NtsColors) return this;
    return NtsColors(
      ntsSuccess: Color.lerp(ntsSuccess, other.ntsSuccess, t)!,
      ntsWarning: Color.lerp(ntsWarning, other.ntsWarning, t)!,
      ntsError: Color.lerp(ntsError, other.ntsError, t)!,
      logTimestamp: Color.lerp(logTimestamp, other.logTimestamp, t)!,
    );
  }
}

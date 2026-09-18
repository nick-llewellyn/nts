// Same-boot compatibility boundary. Part of strict_clock.dart.
//
// A `StrictReading` is meaningful only under the generation and bridge
// incarnation that took it, and a generation is a per-process
// lifecycle token — so nothing a `StrictClockContext` produces can be
// compared across processes on its own. Transferring a reference
// between independently initialised engines or processes in the same
// boot additionally requires boot scope: evidence, from an approved
// provider reading current trusted OS state, that both sides are in
// one counter epoch. The types here define that boundary. The package
// ships **no** approved provider: `kApprovedBootScopeProviders` is
// empty, so `StrictClockContext.exportReference` and `bindReference`
// fail closed with `StrictClockBootScopeUnavailable` on every native
// context. That is the delivered capability — explicitly unavailable —
// not a gap to be worked around with a caller-supplied boolean, a
// stored identifier, an uptime comparison or a hashed counter.

part of 'strict_clock.dart';

/// The [BootScopeProvider] instances whose [BootScope] a native
/// [StrictClockContext] accepts as same-boot evidence. **Empty.** No
/// boot-identity source has been evidenced for any supported platform:
/// Android `Settings.Global.BOOT_COUNT` is a candidate pending counter,
/// reset and installation-lineage validation, and no iOS cold-restore
/// identity is available to apps.
///
/// Approval is by instance, not by [BootScopeProvider.providerId]: an
/// approved provider is a `final class` in this library with a private
/// constructor and one package-held instance, and it is that instance
/// that appears here. A caller's own implementation of the public
/// interface is refused whatever `providerId` it claims, so adding an
/// id to an allowlist could not be impersonated even if one existed.
/// Approval is a reviewed addition to this constant, never a runtime
/// registration.
const Set<BootScopeProvider> kApprovedBootScopeProviders =
    <BootScopeProvider>{};

/// Provider id a [StrictClockProvenance.testInjected] context accepts
/// so the transfer path can be exercised hermetically against a mock
/// bridge. A native context never accepts it; whatever a test proves
/// with it is evidence about this package's checks, not about any
/// platform's boot identity.
@visibleForTesting
const String kHermeticBootScopeProviderId = 'nts.hermetic-test';

/// Source of boot-scope evidence for same-boot transfer.
///
/// An implementation reads *current* trusted OS state each time
/// [current] is called: the value must be stable across independently
/// initialised engines and process relaunches within one counter epoch
/// and differ whenever that epoch resets, or [current] must return
/// `null`. It is consulted only by [StrictClockContext.exportReference]
/// and [StrictClockContext.bindReference], never by a strict read, and
/// only after the instance itself has been found in
/// [kApprovedBootScopeProviders] — an unapproved provider is rejected
/// before [current] is called, and [providerId] is a label for the
/// scopes it issues and for error reports, not a credential. The
/// interface is public so the types can be named and a test can script
/// one under [kHermeticBootScopeProviderId]; implementing it outside
/// this library approves nothing. Binding the scope to a non-migrating
/// installation or key lineage, where the provider's guarantee requires
/// it, is the provider's responsibility; an exception thrown by
/// [current] propagates to the caller and nothing is adopted.
abstract interface class BootScopeProvider {
  /// Stable identifier of this provider's guarantee, stored on every
  /// [BootScope] it returns and reported on every refusal. A label,
  /// not a credential: approval is membership of the instance in
  /// [kApprovedBootScopeProviders].
  String get providerId;

  /// The scope the process is currently in, or `null` when it cannot
  /// be established right now.
  Future<BootScope?> current();
}

/// Boot scope as reported by a [BootScopeProvider]: an opaque token
/// under that provider's [providerId]. Equal scopes from an approved
/// provider identify one counter epoch; equal tokens from anything
/// else identify nothing.
final class BootScope {
  /// Construct a scope. [token] is copied; the copy is unmodifiable.
  ///
  /// Every element must be a byte, `0..=255`; anything else throws
  /// [ArgumentError] in every build mode rather than being narrowed to
  /// eight bits. Token equality is the epoch identity check, so `[256]`
  /// must not silently become `[0]`.
  BootScope({required this.providerId, required List<int> token})
    : token = _checkedToken(token);

  /// Provider whose guarantee the token carries.
  final String providerId;

  /// Opaque provider-defined bytes. Compared for equality only, never
  /// interpreted, hashed into an identity or persisted by this package.
  final Uint8List token;

  @override
  bool operator ==(Object other) =>
      other is BootScope &&
      providerId == other.providerId &&
      _bytesEqual(token, other.token);

  @override
  int get hashCode => Object.hash(providerId, Object.hashAll(token));

  @override
  String toString() =>
      'BootScope(providerId: $providerId, token: ${_hex(token)})';

  static Uint8List _checkedToken(List<int> token) {
    for (final byte in token) {
      if (byte < 0 || byte > 255) {
        throw ArgumentError.value(
          byte,
          'token',
          'every element must be a byte in 0..=255',
        );
      }
    }
    return Uint8List.fromList(token).asUnmodifiableView();
  }

  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static String _hex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// A strict receipt made transferable within one boot.
///
/// Produced by [StrictClockContext.exportReference] from a
/// [StrictSyncedTime] the exporting context acquired, and consumed by
/// [StrictClockContext.bindReference] on an independently resolved
/// context. Carries the producer's reference instant
/// ([referenceMicros]) on its
/// [descriptor] together with the [scope] the producer was in; it
/// deliberately carries **no** generation, because a generation is a
/// per-process lifecycle token and serialised metadata never
/// reinstates one. How this value is stored, authenticated and aged
/// is the consumer's; the public constructor exists so a consumer can
/// rebuild one from storage it has already authenticated, and it
/// rejects a value outside the coordinate's domain so that a corrupt
/// record cannot be bound as a reading no clock could have produced.
final class SameBootReference {
  /// Construct a reference from authenticated storage.
  ///
  /// [referenceMicros] must lie in the coordinate's documented domain,
  /// `0..=2^63-1` (see [ClockSourceDescriptor]); a negative value
  /// throws [ArgumentError] in every build mode, not under `assert`.
  SameBootReference({
    required this.referenceMicros,
    required this.descriptor,
    required this.scope,
  }) {
    if (referenceMicros < 0) {
      throw ArgumentError.value(
        referenceMicros,
        'referenceMicros',
        'must be in the coordinate domain 0..=2^63-1',
      );
    }
  }

  /// The producer's reference instant in microseconds on [descriptor]
  /// — for a [StrictSyncedTime] from `getTimeStrict` the physical wire
  /// receipt, never a normalised model reference and never the export
  /// instant. A hand-built [StrictSyncedTime] can bind any reading its
  /// context attributed, so what an export carries is that instance's
  /// reference reading, whatever the producer bound. Never negative.
  final int referenceMicros;

  /// Coordinate the reference is on.
  final ClockSourceDescriptor descriptor;

  /// Scope the producing context was in at export.
  final BootScope scope;

  @override
  bool operator ==(Object other) =>
      other is SameBootReference &&
      referenceMicros == other.referenceMicros &&
      descriptor == other.descriptor &&
      scope == other.scope;

  @override
  int get hashCode => Object.hash(referenceMicros, descriptor, scope);

  @override
  String toString() =>
      'SameBootReference(referenceMicros: $referenceMicros, '
      'descriptor: $descriptor, scope: $scope)';
}

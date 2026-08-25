// Hand-written safe wrapper around the FRB entrypoint's lifecycle.
//
// `NtsRustLib.init()` is rejected while the entrypoint holds state:
// `BaseEntrypoint.initImpl` throws a `StateError`. That state is not
// permanent -- disposal clears it, so a later `init()` succeeds -- but
// nothing short of disposal does. Worse, `initImpl` assigns the state
// *after* awaiting the external library load, so the guard a consumer
// would write by hand --
// `if (!NtsRustLib.instance.initialized) await NtsRustLib.init()` --
// races: two concurrent callers both observe `false`, both enter, and
// the second throws once the first's load resolves. It also has to read
// `instance`, which is `@internal`.
//
// `NtsBridge` closes both gaps: it latches on the in-flight future
// rather than on the `initialized` predicate, and it exposes the
// mock-vs-native distinction consumers need as a plain enum so nothing
// outside this package touches `instance` or `api`.

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show BaseApiImpl, BaseHandler, ExternalLibrary;
import 'package:meta/meta.dart' show visibleForTesting;

import '../ffi/frb_generated.dart' show NtsRustLib;

/// What the `flutter_rust_bridge` entrypoint currently holds on this
/// isolate.
enum NtsBridgeState {
  /// Nothing installed. Every `nts*` entry point, and
  /// `MonotonicClock`, throws until the bridge is initialized.
  uninitialized,

  /// An API that is not a generated FFI dispatch implementation is
  /// installed — in practice a hand-written double passed to
  /// `NtsRustLib.initMock()`, or an `api:` passed to
  /// `NtsRustLib.init()`. No native library is necessarily loaded.
  ///
  /// The split from [native] is structural, not by initialization
  /// route: passing the *generated* implementation to `initMock()`
  /// reads as [native], because that is what such an API dispatches
  /// as.
  mock,

  /// The generated FFI dispatch implementation is installed: calls
  /// cross the FFI boundary into the Rust core.
  native,
}

/// Lifecycle entry points for the Rust bridge.
///
/// Prefer [ensureInitialized] over `NtsRustLib.init()`: the latter
/// throws a [StateError] on any call made while the entrypoint holds
/// state, so it cannot be called from a shared bootstrap path reached
/// by more than one code path. Only [dispose] clears that state, so
/// outside a deliberate teardown the rejection stands for the life of
/// the isolate.
///
/// All state here is per-isolate, like the underlying entrypoint and
/// like `MonotonicClock.instance`: each isolate must initialize the
/// bridge for itself.
abstract final class NtsBridge {
  /// Latches the first initialization attempt so concurrent and
  /// repeated callers converge on one outcome. Cleared again when an
  /// attempt fails without having taken ownership of the entrypoint.
  static Future<void>? _inFlight;

  /// Whether [_inFlight] has finished, either way.
  ///
  /// Needed because a latch over an entrypoint holding nothing is
  /// stale in one case and correct in the other, and the two are
  /// otherwise indistinguishable: an attempt still awaiting its
  /// library load has not installed state yet either.
  static bool _settled = false;

  /// What the bridge currently holds on this isolate.
  ///
  /// The native/mock split is structural, on the installed API's type:
  /// every generated FFI dispatch implementation extends
  /// flutter_rust_bridge's `BaseApiImpl`, so the predicate survives a
  /// regeneration and an entrypoint rename alike.
  static NtsBridgeState get state {
    // ignore: invalid_use_of_internal_member
    final entrypoint = NtsRustLib.instance;
    if (!entrypoint.initialized) return NtsBridgeState.uninitialized;
    // ignore: invalid_use_of_internal_member
    return entrypoint.api is BaseApiImpl
        ? NtsBridgeState.native
        : NtsBridgeState.mock;
  }

  /// Initialize the bridge if it is not already initialized, and
  /// complete once it is.
  ///
  /// Safe to call any number of times, from any number of code paths,
  /// concurrently. Concurrent callers await the same attempt rather
  /// than racing into a second `NtsRustLib.init()`; later callers
  /// return without re-initializing. An initialization performed
  /// directly (`NtsRustLib.init()`, or `NtsRustLib.initMock()` in
  /// tests) is recognised, so this completes without throwing.
  ///
  /// The arguments configure the attempt a call actually starts. A
  /// call that instead joins a latched attempt, or that finds the
  /// bridge already initialized, ignores them — deliberately, since
  /// throwing on a mismatch would defeat the shared-bootstrap use case
  /// this method exists for. Callers that need specific arguments
  /// honoured must be the ones to initialize the bridge.
  ///
  /// Ignoring [externalLibrary] is not the same as not loading it.
  /// `ExternalLibrary.open` is synchronous — it calls
  /// `DynamicLibrary.open` in its constructor — so the library is
  /// already mapped, and its load-time initializers already run, by the
  /// time this method is entered and can decide to discard the object.
  /// Callers must therefore treat the *construction* of the argument,
  /// not this method's use of it, as the point at which a path is
  /// trusted: only a designated owner should construct an
  /// [ExternalLibrary] at all. [state] does not identify that owner —
  /// it rules out a *completed* initialization and nothing more. An
  /// attempt that is latched but still awaiting its library load has
  /// not installed entrypoint state yet, so [state] reads
  /// [NtsBridgeState.uninitialized] throughout that window and a second
  /// caller guarding on it maps its own library before this method
  /// discards the argument.
  ///
  /// On failure the error propagates to every caller awaiting the
  /// attempt. If the entrypoint is left holding the generated API — the
  /// Rust-side initializers threw after FRB installed its state — the
  /// same error is replayed to every later caller, because
  /// `NtsRustLib.init()` can never succeed again from that point.
  /// Otherwise a later call retries: either nothing was installed (a
  /// codegen version mismatch, a library that failed to load), or a
  /// concurrent `NtsRustLib.initMock()` installed a hand-written double
  /// independently, in which case that success is not shadowed by this
  /// attempt's error and the retry completes over it.
  ///
  /// Both of those rest on this method's own attempts being the only
  /// initializations in flight. Driving the raw entrypoint
  /// *concurrently* with this method is unsupported, in either
  /// direction:
  ///
  /// * A concurrent `NtsRustLib.init()` installs the entrypoint state
  ///   before awaiting its Rust initializers, so this method can
  ///   observe that state, complete successfully, and never see the
  ///   failure that call then suffers. Which [state] it observes
  ///   depends on what that call installed: the generated
  ///   implementation reads as [NtsBridgeState.native], while an `api:`
  ///   the caller supplied reads as [NtsBridgeState.mock]. The
  ///   early-completion exposure is the same either way, so callers
  ///   using the `api:` overload are no better protected than the
  ///   default one.
  /// * A concurrent `NtsRustLib.initMock()` that supplies the
  ///   *generated* implementation also reads as
  ///   [NtsBridgeState.native], which is indistinguishable from state
  ///   this method installed itself. Should this method's own attempt
  ///   then fail, its error is replayed to later callers over a bridge
  ///   that is in fact usable. A hand-written double does not have this
  ///   problem: it reads as [NtsBridgeState.mock], which is
  ///   attributable to someone else and is not shadowed.
  ///
  /// FRB exposes neither a way to await someone else's attempt nor the
  /// identity of the API an attempt installed, so neither case can be
  /// detected from here. Either route every initialization through this
  /// method, or complete the direct call before reaching any code path
  /// that uses this one.
  ///
  /// One case survives even a completed direct call. A
  /// `NtsRustLib.init()` that threw from its Rust initializers leaves
  /// the entrypoint installed and permanently unusable, and this method
  /// then reports success over it: the entrypoint records no failure,
  /// and the attempt was never latched here. A caller that drives
  /// `init()` directly owns that error and must keep it — awaiting this
  /// A raw `NtsRustLib.dispose()` is supported once whatever attempt
  /// preceded it has been awaited. It de-initializes the entrypoint
  /// without going through [dispose], so the latch this method keeps
  /// would otherwise be handed back over a bridge holding nothing;
  /// instead the stale latch is dropped and the next call runs a
  /// fresh attempt, as it would after [dispose]. That includes
  /// dropping a latch retained to replay a failure, since the state
  /// the replay was protecting is gone. Disposal *during* an
  /// unawaited attempt remains unsupported, exactly as it is for
  /// [dispose].
  static Future<void> ensureInitialized({
    ExternalLibrary? externalLibrary,
    BaseHandler? handler,
    bool forceSameCodegenVersion = true,
  }) {
    final latched = _inFlight;
    if (latched != null) {
      // A raw `NtsRustLib.dispose()` clears the entrypoint state
      // without going through [dispose], stranding a settled latch
      // over a bridge holding nothing. Start over rather than hand
      // that latch back: reporting success there would be the same
      // defect [dispose] drops the latch to avoid. Only checkable
      // once settled -- an attempt still awaiting its library load
      // reads `uninitialized` too, and must not be restarted.
      if (!_settled || state != NtsBridgeState.uninitialized) return latched;
      _inFlight = null;
      _settled = false;
    }
    // Something is installed and no attempt of ours is outstanding, so
    // there is nothing left to do. This reports success even over an
    // entrypoint a *direct* `NtsRustLib.init()` left installed and
    // half-built: that failure was never latched here, and FRB records
    // nothing about it. Documented above as the caller's to keep.
    if (state != NtsBridgeState.uninitialized) {
      _settled = true;
      return _inFlight = Future<void>.value();
    }
    late final Future<void> attempt;
    attempt =
        NtsRustLib.init(
              externalLibrary: externalLibrary,
              handler: handler,
              forceSameCodegenVersion: forceSameCodegenVersion,
            )
            .onError<Object>((error, stackTrace) {
              // Retain the latch only for a failure that left the generated
              // API installed, so the error is replayed to later callers
              // rather than a doomed second `NtsRustLib.init()` being run.
              // This attempt can only ever install that API, so `native` is
              // the state attributable to it: nothing installed leaves
              // `uninitialized`, and `mock` can only come from an
              // independent `initMock()`, which is an initialization that
              // succeeded and must not be shadowed by this error. A
              // concurrent `initMock()` supplying the *generated* API is
              // indistinguishable from our own install and so is documented
              // as unsupported rather than handled.
              //
              // Either way, only while this attempt is still the latched
              // one -- a `debugReset()` between the throw and this callback
              // has already invalidated it.
              if (identical(_inFlight, attempt) &&
                  state != NtsBridgeState.native) {
                _inFlight = null;
              }
              Error.throwWithStackTrace(error, stackTrace);
            })
            .whenComplete(() {
              // Same guard: once this attempt is no longer the latched
              // one, the flag describes whatever replaced it.
              if (identical(_inFlight, attempt)) _settled = true;
            });
    return _inFlight = attempt;
  }

  /// Release the bridge's Dart-side resources, or do nothing when the
  /// bridge was never initialized.
  ///
  /// Disposal *is* de-initialization: `flutter_rust_bridge` drops the
  /// entrypoint's state as it disposes, so [state] reads
  /// [NtsBridgeState.uninitialized] afterwards. This drops the latch
  /// with it, so a later [ensureInitialized] runs a fresh attempt
  /// rather than reporting success over a bridge that no longer holds
  /// anything. Calling it is optional — the bridge is torn down with
  /// the process.
  ///
  /// That contract changed in `nts` 9.3, which moved to
  /// `flutter_rust_bridge` 2.13.0. Through 2.12.0 the entrypoint
  /// disposed in place and kept its state, so [state] was unchanged
  /// afterwards and a later [ensureInitialized] would not
  /// re-initialize. The early return for an uninitialized bridge is
  /// not part of that change: it has always been here, shielding
  /// callers from the `StateError` the raw `NtsRustLib.dispose()`
  /// throws in that case, and it still does.
  ///
  /// Await any outstanding [ensureInitialized] before calling this.
  /// Disposing while an attempt is in flight is unsupported, and the
  /// two windows fail differently: before the attempt installs
  /// entrypoint state, [state] reads [NtsBridgeState.uninitialized] and
  /// this returns without disposing anything, leaving the bridge
  /// initialized once the attempt lands; after it installs, this clears
  /// the state under the attempt, which then completes successfully
  /// over a bridge holding nothing. Neither is detectable from here —
  /// FRB exposes no way to observe someone else's attempt — which is
  /// the same limitation [ensureInitialized] documents for concurrent
  /// direct `NtsRustLib.init()` calls.
  static void dispose() {
    if (state == NtsBridgeState.uninitialized) return;
    NtsRustLib.dispose();
    _inFlight = null;
    _settled = false;
  }

  /// Drop the latched attempt so a later [ensureInitialized] starts
  /// over.
  ///
  /// For tests only, and only ones that also reset the underlying
  /// entrypoint (`NtsRustLib.instance.resetState()`); the two must be
  /// paired or the latch and the entrypoint disagree about what is
  /// installed. Dropping the latch on its own after a failure that left
  /// the entrypoint installed would let the next [ensureInitialized]
  /// report success from state whose Rust-side initializers never ran.
  @visibleForTesting
  static void debugReset() {
    _inFlight = null;
    _settled = false;
  }
}

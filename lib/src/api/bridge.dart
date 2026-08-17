// Hand-written safe wrapper around the FRB entrypoint's lifecycle.
//
// `NtsRustLib.init()` is single-shot: `BaseEntrypoint.initImpl` throws a
// `StateError` when the entrypoint already holds state, and there is no
// de-init. Worse, it assigns that state *after* awaiting the external
// library load, so the guard a consumer would write by hand --
// `if (!NtsRustLib.instance.initialized) await NtsRustLib.init()` --
// races: two concurrent callers both observe `false`, both enter, and
// the second throws once the first's load resolves. It also has to read
// `instance`, which is `@internal`.
//
// `NtsBridge` closes both gaps: it latches on the in-flight future
// rather than on the `initialized` predicate, and it exposes the
// mock-vs-native distinction consumers need as a plain enum so nothing
// outside this package touches `instance` or `api`.

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show BaseApiImpl, BaseHandler, ExternalLibrary;

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
/// throws a [StateError] on every call after the first, so it cannot be
/// called from a shared bootstrap path reached by more than one code
/// path.
///
/// All state here is per-isolate, like the underlying entrypoint and
/// like `MonotonicClock.instance`: each isolate must initialize the
/// bridge for itself.
abstract final class NtsBridge {
  /// Latches the first initialization attempt so concurrent and
  /// repeated callers converge on one outcome. Cleared again only when
  /// an attempt fails without leaving the bridge initialized.
  static Future<void>? _inFlight;

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
  /// On failure the error propagates to every caller awaiting the
  /// attempt. If the bridge did not become initialized (a codegen
  /// version mismatch, a library that failed to load), a later call
  /// retries. If it did — the Rust-side initializers threw after the
  /// entrypoint took ownership — the same error is replayed to every
  /// later caller, because `NtsRustLib.init()` can never succeed again
  /// from that point.
  ///
  /// That replay only covers attempts this method made. Calling
  /// `NtsRustLib.init()` directly *concurrently* with this method is
  /// unsupported: FRB installs the entrypoint state before awaiting its
  /// Rust initializers, so this method can observe [state] as
  /// [NtsBridgeState.native] and complete successfully while the direct
  /// call is still running, and a failure it then suffers is invisible
  /// here. FRB exposes no way to await someone else's attempt. Either
  /// route every initialization through this method, or await the
  /// direct call before reaching any code path that uses this one.
  static Future<void> ensureInitialized({
    ExternalLibrary? externalLibrary,
    BaseHandler? handler,
    bool forceSameCodegenVersion = true,
  }) {
    final latched = _inFlight;
    if (latched != null) return latched;
    if (state != NtsBridgeState.uninitialized) {
      return _inFlight = Future<void>.value();
    }
    late final Future<void> attempt;
    attempt =
        NtsRustLib.init(
          externalLibrary: externalLibrary,
          handler: handler,
          forceSameCodegenVersion: forceSameCodegenVersion,
        ).onError<Object>((error, stackTrace) {
          // Only unlatch a failure that left nothing installed, and only
          // while this attempt is still the latched one -- a `debugReset()`
          // between the throw and this callback has already invalidated it.
          if (identical(_inFlight, attempt) &&
              state == NtsBridgeState.uninitialized) {
            _inFlight = null;
          }
          Error.throwWithStackTrace(error, stackTrace);
        });
    return _inFlight = attempt;
  }

  /// Release the bridge's Dart-side resources, or do nothing when the
  /// bridge was never initialized.
  ///
  /// `NtsRustLib.dispose()` throws when nothing is installed; this does
  /// not. Disposal is not de-initialization: the entrypoint keeps its
  /// state afterwards, so [state] is unchanged and [ensureInitialized]
  /// will not re-initialize. Calling it is optional — the bridge is
  /// torn down with the process.
  static void dispose() {
    if (state == NtsBridgeState.uninitialized) return;
    NtsRustLib.dispose();
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
  }
}

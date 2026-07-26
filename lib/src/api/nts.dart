// Hand-written stable surface for `package:nts`.
//
// This file is the public contract consumers see when they
// `import 'package:nts/nts.dart'`. It exposes wrapper functions that
// accept and return only the hand-written DTOs in `models.dart` and
// the hand-written error sealed class in `errors.dart`, and converts
// across the FRB-generated boundary in `lib/src/ffi/api/nts.dart`
// internally.
//
// The wrapper exists for two reasons:
//
// 1. Function signatures: FRB v2 codegen marks every Rust argument as
//    a `required` named parameter on the Dart side, with no support
//    for optional / defaulted parameters. The wrapper restores idiomatic
//    Dart signatures with named optional parameters and defaults
//    (`kDefaultTimeout`, `kDefaultDnsConcurrencyCap`).
// 2. Type shape: the FFI DTOs use FRB-specific types like
//    `PlatformInt64` and a freezed-generated `NtsError`. Converting to
//    plain Dart `int` and a hand-written sealed `NtsError` at this
//    boundary means a Rust-side struct rename or reorder no longer
//    becomes a Dart source break for downstream callers.
//
// See `ARCHITECTURE.md`'s "Public API stability layer" section for
// the full rationale.

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show PlatformInt64, PlatformInt64Util;
import '../ffi/api/nts.dart' as ffi;
import 'clock.dart';
import 'errors.dart';
import 'models.dart';

export 'errors.dart';
export 'models.dart';

part 'nts_toplevel.dart';
part 'nts_client.dart';
part 'nts_validation.dart';
part 'nts_get_time.dart';
part 'nts_bridge_gate.dart';
part 'nts_convert.dart';

/// Default per-call wall-clock budget for [ntsQuery] / [ntsWarmCookies]
/// / [NtsClient.query] / [NtsClient.warmCookies].
///
/// Sized to cover one DNS lookup plus the NTS-KE TLS 1.3 handshake plus
/// the NTPv4 UDP round-trip against a public server over a typical
/// consumer network, while still failing fast against an unreachable
/// host. Centralising the constant gives callers a stable name to refer
/// to "the package's tuned default" rather than hardcoding the number.
/// Override per-call by passing an explicit `timeout` argument; values
/// must lie between 1 ms and 4294967295 ms (the FFI encoding range,
/// validated at the wrapper boundary).
const Duration kDefaultTimeout = Duration(milliseconds: 5000);

/// Default per-call ceiling on in-flight DNS resolver workers, applied
/// process-wide by [ntsQuery] / [ntsWarmCookies] / [NtsClient.query] /
/// [NtsClient.warmCookies].
///
/// Sized for mobile devices: each in-flight `getaddrinfo` worker holds
/// an OS thread plus a 512 KB-1 MB pthread stack, and `getaddrinfo`
/// itself is non-cancellable, so a stalled lookup is detached and
/// finishes in the background. The cap bounds how many such workers
/// can accumulate before subsequent calls short-circuit with
/// [NtsError.timeout] ([TimeoutPhase.dnsSaturation]) rather than
/// spawning another. Raise per-call on hosts with more headroom by
/// passing an explicit `dnsConcurrencyCap` argument; values must lie
/// in `1..4294967295` (the FFI encoding range, validated at the
/// wrapper boundary).
const int kDefaultDnsConcurrencyCap = 4;

/// Default per-call ceiling on concurrently dispatched bridge calls,
/// applied isolate-wide by [ntsQuery] / [ntsWarmCookies] /
/// [NtsClient.query] / [NtsClient.warmCookies] (the gate's state is
/// Dart-side and isolate-local; each isolate gates its own calls over
/// the shared process-wide `flutter_rust_bridge` worker pool).
///
/// Each in-flight call pins one `flutter_rust_bridge` worker thread
/// (a fixed pool of one thread per logical CPU by default) for its
/// full duration — up to `timeout` in the worst case — so an
/// unbounded distinct-host fan-out could occupy every worker and
/// stall unrelated bridge calls behind it. The cap bounds how many of
/// this package's calls occupy workers at once; calls beyond it queue
/// on the Dart side (holding no worker thread) and fail with
/// [NtsError.timeout] ([TimeoutPhase.bridgeSaturation]) if the whole
/// `timeout` budget elapses before a slot frees. Sized to the
/// smallest common mobile pool (4 logical CPUs) so even a saturating
/// burst cannot occupy more workers than the smallest pool holds.
/// Raise per-call on hosts with more headroom by passing an explicit
/// `bridgeConcurrencyCap` argument; values must lie in
/// `1..4294967295`, validated at the wrapper boundary for symmetry
/// with `dnsConcurrencyCap` even though this cap never crosses the
/// FFI boundary.
const int kDefaultBridgeConcurrencyCap = 4;

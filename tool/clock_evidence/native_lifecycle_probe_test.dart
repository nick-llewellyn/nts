@Tags(['clock-evidence'])
library;

// Opt-in native probe suite for the strict clock evidence matrix
// (`tool/clock_evidence/evidence_matrix.md`, NTS-180).
//
// Everything here runs against a real native bridge on the machine or
// device executing it. It settles `native-runtime-read` outright, and
// covers the single-engine, single-process portion of
// `descriptor-compatibility` and `bridge-teardown` -- those two rows
// also require a relaunch and a second engine respectively, so a green
// run here narrows them rather than closing them. The remaining
// dimensions -- `multi-engine`, `process-relaunch`, and every physical
// row from `suspend-resume` down -- need a second engine, a relaunch, or
// a device action, and are deliberately absent rather than approximated.
// A thread sleep is not a suspend and an in-process teardown is not a
// process death; recording either as the other is the failure the
// `nts-flr8` delivery policy exists to prevent.
//
// ## Opt-in by design (location + tag)
//
// The file lives under `tool/`, which `flutter test` never globs, and
// carries the `clock-evidence` tag that the root `dart_test.yaml` marks
// `skip:`. The required hermetic gate therefore cannot reach it by
// either route.
//
// To run it:
//
//   1. Build the native release dylib so its FRB content-hash matches
//      the committed bindings:  `cargo build --release -p nts_rust`
//      (from `rust/`).
//   2. `flutter test --run-skipped tool/clock_evidence/`
//
// Each phase prints an `evidence:` line, free of `|` so it pastes
// straight into a Markdown table cell. Paste it into the matching
// `evidence` cell of `evidence_matrix.md` and flip that row to `pass`,
// naming the host or device it ran on.
//
// ## One test, four phases
//
// The teardown phase is terminal: `NtsBridge.dispose()` retires the
// process-wide generation and `NtsRustLib.init()` refuses a second
// call, so nothing can resolve a native context after it. Splitting the
// phases into separate tests would make them depend on declaration
// order, which the runner is free to randomize, so they are one
// sequential test instead.

import 'dart:io' show Platform, stdout;

import 'package:flutter_test/flutter_test.dart';
import 'package:nts/nts.dart';

/// Backend this build must select, from the target platform alone.
/// Mirrors the `cfg` arms in `rust/src/nts/boottime.rs`.
ClockBackend get _expectedBackend {
  if (Platform.isAndroid || Platform.isLinux) return ClockBackend.linuxBoottime;
  if (Platform.isIOS || Platform.isMacOS) return ClockBackend.appleContinuous;
  if (Platform.isWindows) return ClockBackend.windowsInterruptTime;
  throw StateError('unsupported platform: ${Platform.operatingSystem}');
}

String get _host =>
    '${Platform.operatingSystem} '
    '${Platform.operatingSystemVersion}';

/// Emit one matrix-ready line. No `|`: the line is meant to be pasted
/// into a Markdown table cell, and a pipe there would split it into
/// extra columns and be rejected by the validator.
void _record(String dimension, String detail) {
  stdout.writeln('evidence: $dimension :: $_host :: $detail');
}

void main() {
  // The binding must be live before the bridge loads the dylib over the
  // FFI / Native Assets path, as in `test/live/nts_live_test.dart`.
  TestWidgetsFlutterBinding.ensureInitialized();

  // One test, run in phases, rather than four. The teardown phase is
  // terminal -- `NtsBridge.dispose()` retires the process-wide
  // generation and `NtsRustLib.init()` refuses a second call -- so
  // separate tests would depend on declaration order, which the runner
  // is free to randomize.
  test('strict clock native lifecycle probe', () async {
    await NtsBridge.ensureInitialized();
    expect(
      NtsBridge.state,
      NtsBridgeState.native,
      reason:
          'these probes are evidence only over a native bridge; '
          'build the release dylib first',
    );

    // Phase 1 -- native-runtime-read: the bridge resolves a native
    // context on the backend this target must select.
    final ctx = StrictClockContext.resolve();
    expect(ctx.provenance, StrictClockProvenance.native);
    expect(ctx.descriptor.backend, _expectedBackend);
    expect(ctx.descriptor.semanticsVersion, 1);
    expect(ctx.descriptor.conversionVersion, 1);

    final reading = ctx.now();
    expect(reading.micros, greaterThanOrEqualTo(0));
    expect(reading.generation, ctx.generation);
    expect(reading.descriptor, ctx.descriptor);
    _record(
      'native-runtime-read',
      'backend=${reading.descriptor.backend.name} '
          'micros=${reading.micros} generation=${reading.generation}',
    );

    // Phase 2 -- native-runtime-read: the coordinate advances over a
    // measured interval and never goes back. A delay is not a suspend;
    // this settles nothing about the `suspend-resume` row.
    final start = ctx.now();
    await Future<void>.delayed(const Duration(milliseconds: 250));
    final elapsed = ctx.elapsedSince(start);
    expect(elapsed, greaterThanOrEqualTo(const Duration(milliseconds: 200)));
    expect(elapsed, lessThan(const Duration(seconds: 5)));
    _record(
      'native-runtime-read',
      'elapsed over a 250ms delay = ${elapsed.inMicroseconds}us',
    );

    // Phase 3 -- descriptor-compatibility, within one process on one
    // boot. Two independent contexts describe the same coordinate, so a
    // reading from one is a valid earlier bound for the other.
    final second = StrictClockContext.resolve();
    expect(second.descriptor, ctx.descriptor);
    expect(second.descriptor.isCompatibleWith(ctx.descriptor), isTrue);
    expect(second.generation, ctx.generation);
    expect(() => second.elapsedSince(ctx.now()), returnsNormally);
    _record(
      'descriptor-compatibility',
      'two contexts in one process agree on ${ctx.descriptor}',
    );

    // Phase 4 -- bridge-teardown. Terminal: nothing can resolve a
    // native context after this.
    expect(ctx.isValid, isTrue);
    NtsBridge.dispose();
    expect(ctx.now, throwsA(isA<StrictClockInvalidated>()));
    expect(ctx.isValid, isFalse);
    expect(ctx.invalidationReason, StrictClockInvalidationReason.bridgeReset);
    _record(
      'bridge-teardown',
      'dispose() invalidated a live context in the calling engine with '
          '${ctx.invalidationReason?.name}',
    );
  });
}

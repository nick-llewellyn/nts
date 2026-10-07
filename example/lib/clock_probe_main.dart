// On-device probe for the strict clock evidence matrix
// (`tool/clock_evidence/evidence_matrix.md`, nts-flr8.9).
//
// `tool/clock_evidence/native_lifecycle_probe_test.dart` only runs on a
// host. This entrypoint carries the same probes onto a physical Android
// or iOS device, plus the ones a single test run cannot express: every
// launch is persisted, so a relaunch, a process death or a reboot is
// compared against the record the previous process left behind.
//
//   flutter run -t lib/clock_probe_main.dart -d <device>            # debug
//   flutter run -t lib/clock_probe_main.dart -d <device> --profile  # relaunchable
//
// The host app can start a second Flutter engine in the same process
// (`MainActivity.kt` / `AppDelegate.swift`) for the `multi-engine` and
// `bridge-teardown` rows: Android debug builds, and iOS profile builds —
// a second JIT engine faults on code signing on iOS, so iOS debug builds
// hide those rows. iOS debug builds also cannot be relaunched from the
// home screen, so every iOS row other than a first launch uses a profile
// build.
//
// Every `evidence:` line is printed, shown on screen and appended to a
// persisted history that is printed again on the next launch, so a line
// produced while no tool was attached is not lost.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:ffi'
    show
        DynamicLibrary,
        DynamicLibraryExtension,
        IntPtr,
        Pointer,
        Uint64,
        Uint64Pointer,
        Uint8;
import 'dart:io' show Platform, pid;

import 'package:flutter/foundation.dart' show kDebugMode, kProfileMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel;
// Process-wide generation advance: the call a strict fault or regression
// makes, used to show another engine observing it.
// ignore: implementation_imports
import 'package:nts/src/ffi/api/nts.dart' show ntsClockInvalidate;
import 'package:nts/nts.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _channel = MethodChannel('nts_example/clock_probe');
const _kHistory = 'clock_probe.history';
const _kLaunch = 'clock_probe.last_launch';
const _kReference = 'clock_probe.reference';
const _historyCap = 400;

/// Whether the host app serves `_channel` (second engine, and on iOS the
/// background task) in this build.
bool get _probeHosted => Platform.isIOS ? kProfileMode : kDebugMode;

String get _host =>
    '${Platform.operatingSystem} ${Platform.operatingSystemVersion} pid=$pid';

String _wall() => DateTime.now().toUtc().toIso8601String();

/// Consumer-defined provider. Not in `kApprovedBootScopeProviders`, so
/// every export and bind that reaches the provider step is refused.
final class _AppBootScopeProvider implements BootScopeProvider {
  const _AppBootScopeProvider();

  @override
  String get providerId => 'nts-example.clock-probe';

  @override
  Future<BootScope?> current() async =>
      BootScope(providerId: providerId, token: const [1, 2, 3, 4]);
}

Map<String, Object> _descriptorJson(ClockSourceDescriptor d) => {
  'backend': d.backend.name,
  'semanticsVersion': d.semanticsVersion,
  'conversionVersion': d.conversionVersion,
};

ClockSourceDescriptor _descriptorFrom(Map<String, dynamic> j) =>
    ClockSourceDescriptor(
      backend: ClockBackend.values.byName(j['backend'] as String),
      semanticsVersion: j['semanticsVersion'] as int,
      conversionVersion: j['conversionVersion'] as int,
    );

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final probe = _Probe(prefs);
  runApp(_ProbeApp(probe: probe));
  await probe.launch();
}

/// Second engine, started by the host app on `startSecondEngine`. Holds
/// its own context and answers commands relayed from the primary engine.
@pragma('vm:entry-point')
Future<void> clockProbeSecondEngine() async {
  WidgetsFlutterBinding.ensureInitialized();
  StrictClockContext? ctx;
  Future<void> send(String line) =>
      _channel.invokeMethod<void>('toPrimary', line);

  String describe(StrictClockContext c) =>
      'provenance=${c.provenance.name} descriptor=${c.descriptor} '
      'generation=${c.generation}';

  _channel.setMethodCallHandler((call) async {
    if (call.method != 'command') return;
    switch (call.arguments as String) {
      case 'resolve':
        ctx = StrictClockContext.resolve();
        await send('resolved ${describe(ctx!)}');
      case 'read':
        try {
          final r = ctx!.now();
          await send('read ok micros=${r.micros} generation=${r.generation}');
        } on StrictClockInvalidated catch (e) {
          await send('read invalidated reason=${e.reason.name}');
        } on StrictClockError catch (e) {
          await send('read failed $e');
        }
    }
  });

  try {
    await NtsBridge.ensureInitialized();
    ctx = StrictClockContext.resolve();
    await send('ready bridge=${NtsBridge.state.name} ${describe(ctx!)}');
  } catch (e) {
    await send('failed $e');
  }
}

class _Probe extends ChangeNotifier {
  _Probe(this._prefs);

  final SharedPreferences _prefs;
  final List<String> lines = [];
  final _fromSecond = StreamController<String>.broadcast();
  StrictClockContext? _ctx;
  StrictReading? _lastMark;
  DateTime? _lastMarkWall;
  final _sinceMark = Stopwatch();
  Timer? _periodic;
  bool _secondStarted = false;

  bool get periodic => _periodic != null;

  void log(String line) {
    final stamped = '${_wall()} $line';
    print('evidence: $stamped');
    lines.add(stamped);
    final history = [...?_prefs.getStringList(_kHistory), stamped];
    final start = history.length > _historyCap
        ? history.length - _historyCap
        : 0;
    unawaited(_prefs.setStringList(_kHistory, history.sublist(start)));
    notifyListeners();
  }

  /// Runs `body` and logs the outcome; an error is evidence, not a crash.
  Future<void> _step(String name, FutureOr<String> Function() body) async {
    try {
      log('$name: ${await body()}');
    } on StrictClockInvalidated catch (e) {
      log(
        '$name: invalidated reason=${e.reason.name} generation=${e.generation}',
      );
    } on StrictClockBootScopeUnavailable catch (e) {
      log('$name: refused reason=${e.reason.name} provider=${e.providerId}');
    } catch (e) {
      log('$name: ${e.runtimeType} $e');
    }
  }

  StrictClockContext get _context => _ctx ??= StrictClockContext.resolve();

  String _read(String label) {
    final r = _context.now();
    return '$label micros=${r.micros} generation=${r.generation}';
  }

  Future<void> launch() async {
    for (final h in _prefs.getStringList(_kHistory) ?? const <String>[]) {
      print('history: $h');
    }
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'fromSecond':
          final line = call.arguments as String;
          log('engine2: $line');
          _fromSecond.add(line);
        case 'backgroundTaskExpired':
          log('periodic: background task expired');
      }
    });
    log('launch host=$_host debug=$kDebugMode profile=$kProfileMode');
    await _step('bridge', () async {
      await NtsBridge.ensureInitialized();
      return 'state=${NtsBridge.state.name}';
    });
    await _step('native-runtime-read', () {
      final c = _context;
      final a = c.now();
      final b = c.now();
      return 'provenance=${c.provenance.name} descriptor=${c.descriptor} '
          'generation=${c.generation} a=${a.micros} b=${b.micros} '
          'monotonic=${b.micros >= a.micros}';
    });
    await _step('relaunch', _compareLaunch);
    if (_prefs.getString(_kReference) != null) {
      await _step('bind-persisted', _bindPersisted);
    }
  }

  Map<String, Object> _launchRecord() {
    final c = _context;
    final r = c.now();
    return {
      'wallMicros': DateTime.now().microsecondsSinceEpoch,
      'micros': r.micros,
      'generation': r.generation,
      'descriptor': _descriptorJson(c.descriptor),
      'host': _host,
    };
  }

  Future<String> _compareLaunch() async {
    final c = _context;
    final previous = _prefs.getString(_kLaunch);
    final record = _launchRecord();
    await _prefs.setString(_kLaunch, jsonEncode(record));
    final micros = record['micros']! as int;
    if (previous == null) return 'first launch micros=$micros';
    final p = jsonDecode(previous) as Map<String, dynamic>;
    final prior = _descriptorFrom(p['descriptor'] as Map<String, dynamic>);
    final dClock = micros - (p['micros'] as int);
    final dWall = (record['wallMicros']! as int) - (p['wallMicros'] as int);
    return 'previous host=${p['host']} generation=${p['generation']} '
        'descriptor-compatible=${prior.isCompatibleWith(c.descriptor)} '
        'dClockMicros=$dClock dWallMicros=$dWall '
        'skewMicros=${dClock - dWall} clockBackwards=${dClock < 0}';
  }

  /// Strict, wall and `Stopwatch` deltas since the previous mark.
  /// `Stopwatch` does not advance while the device sleeps, so
  /// `strict - stopwatch` is the time spent suspended, and
  /// `wall - strict` is any wall-clock (RTC) change in between.
  Future<void> mark() => _step('mark', () {
    final r = _context.now();
    final wall = DateTime.now();
    final stopwatch = _sinceMark.elapsedMicroseconds;
    _sinceMark
      ..reset()
      ..start();
    final previous = _lastMark;
    final previousWall = _lastMarkWall;
    _lastMark = r;
    _lastMarkWall = wall;
    var since = '';
    if (previous != null && previousWall != null) {
      final strict = _context.elapsedSince(previous).inMicroseconds;
      final dWall = wall.difference(previousWall).inMicroseconds;
      since =
          ' strictMicros=$strict wallMicros=$dWall stopwatchMicros=$stopwatch '
          'suspendedMicros=${strict - stopwatch} '
          'wallMinusStrictMicros=${dWall - strict}';
    }
    return 'micros=${r.micros} generation=${r.generation}$since';
  });

  /// Periodic reads every 5 s. On iOS the host holds a background task
  /// meanwhile, so reads continue for a while after the device locks.
  void togglePeriodic() {
    if (_periodic != null) {
      _periodic!.cancel();
      _periodic = null;
      if (_probeHosted && Platform.isIOS) {
        unawaited(_channel.invokeMethod<void>('endBackgroundTask'));
      }
      log('periodic: stopped');
      return;
    }
    if (_probeHosted && Platform.isIOS) {
      unawaited(_channel.invokeMethod<void>('beginBackgroundTask'));
    }
    _periodic = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(_step('periodic', () => _read('tick'))),
    );
    log('periodic: started interval=5s');
  }

  Future<void> reResolve() => _step('re-resolve', () {
    _ctx = null;
    final c = _context;
    return 'descriptor=${c.descriptor} generation=${c.generation}';
  });

  /// Syncs strictly, attempts an export, and persists the candidate
  /// reference the export would have carried for the next launch to bind.
  Future<void> exportReference() => _step('export', () async {
    final c = _context;
    final synced = await ntsGetTimeStrict(
      spec: const NtsServerSpec(host: 'time.cloudflare.com', port: 4460),
      context: c,
    );
    final descriptor = synced.descriptor;
    await _prefs.setString(
      _kReference,
      jsonEncode({
        'referenceMicros': synced.referenceMicros,
        'descriptor': _descriptorJson(descriptor),
      }),
    );
    log(
      'export: synced utc=${synced.utcUnixMicros} '
      'reference=${synced.referenceMicros} anchor=${synced.anchorMicros} '
      'generation=${synced.generation}; candidate persisted',
    );
    await c.exportReference(synced, provider: const _AppBootScopeProvider());
    return 'UNEXPECTED export accepted';
  });

  Future<void> bindPersisted() => _step('bind-persisted', _bindPersisted);

  Future<String> _bindPersisted() async {
    final raw = _prefs.getString(_kReference);
    if (raw == null) return 'no persisted reference';
    final j = jsonDecode(raw) as Map<String, dynamic>;
    const provider = _AppBootScopeProvider();
    final reference = SameBootReference(
      referenceMicros: j['referenceMicros'] as int,
      descriptor: _descriptorFrom(j['descriptor'] as Map<String, dynamic>),
      scope: (await provider.current())!,
    );
    await _context.bindReference(reference, provider: provider);
    return 'UNEXPECTED bind accepted';
  }

  Future<String> _ask(String command) async {
    final reply = _fromSecond.stream.first.timeout(const Duration(seconds: 5));
    await _channel.invokeMethod<void>('toSecond', command);
    return reply;
  }

  Future<void> _ensureSecond() async {
    if (_secondStarted) return;
    final ready = _fromSecond.stream.first.timeout(const Duration(seconds: 20));
    await _channel.invokeMethod<void>('startSecondEngine');
    _secondStarted = true;
    await ready;
  }

  /// `multi-engine`: a process-wide generation advance made on this
  /// engine fails closed on the other engine's next read; both recover
  /// by re-resolving.
  Future<void> multiEngine() async {
    await _step('multi-engine start', () async {
      await _ensureSecond();
      return 'second engine ready';
    });
    await _step('multi-engine e1 before', () => _read('read'));
    await _step('multi-engine e2 before', () => _ask('read'));
    await _step(
      'multi-engine advance',
      () => 'ntsClockInvalidate -> ${ntsClockInvalidate()}',
    );
    await _step('multi-engine e1 after', () => _read('read'));
    await _step('multi-engine e2 after', () => _ask('read'));
    await reResolve();
    await _step('multi-engine e2 re-resolve', () => _ask('resolve'));
    await _step('multi-engine e2 reread', () => _ask('read'));
  }

  /// `bridge-teardown`: `NtsBridge.dispose()` on this engine; the other
  /// engine's context fails closed and it can re-resolve on its own
  /// still-installed bridge.
  Future<void> bridgeTeardown() async {
    await _step('teardown start', () async {
      await _ensureSecond();
      return 'second engine ready';
    });
    await _step('teardown e1 before', () => _read('read'));
    await _step('teardown e2 before', () => _ask('read'));
    await _step('teardown dispose', () {
      NtsBridge.dispose();
      return 'state=${NtsBridge.state.name}';
    });
    await _step('teardown e1 after', () => _read('read'));
    await _step('teardown e2 after', () => _ask('read'));
    await _step('teardown e2 re-resolve', () => _ask('resolve'));
    await _step('teardown e2 reread', () => _ask('read'));
    await _step('teardown e1 reinit', () async {
      await NtsBridge.ensureInitialized();
      return 'state=${NtsBridge.state.name}';
    });
    await reResolve();
  }

  /// Dirties native memory in 64 MiB chunks of incompressible data until
  /// iOS jetsam kills the process under memory pressure, for the
  /// `process-death` row. Native memory, so the Dart heap limit cannot
  /// end the run with an `OutOfMemoryError` first. The launch record is
  /// rewritten first, so the relaunch compares against the moment of kill.
  Future<void> jetsam() => _step('jetsam', () async {
    final malloc = DynamicLibrary.process()
        .lookupFunction<
          Pointer<Uint8> Function(IntPtr),
          Pointer<Uint8> Function(int)
        >('malloc');
    const chunk = 64 << 20;
    await _prefs.setString(_kLaunch, jsonEncode(_launchRecord()));
    log('jetsam: start; launch record persisted');
    var x = DateTime.now().microsecondsSinceEpoch | 1;
    for (var mib = 64; ; mib += 64) {
      final p = malloc(chunk);
      if (p.address == 0) return 'malloc returned null at ${mib}MiB';
      final words = p.cast<Uint64>().asTypedList(chunk ~/ 8);
      for (var i = 0; i < words.length; i++) {
        x ^= x << 13;
        x ^= x >>> 7;
        x ^= x << 17;
        words[i] = x;
      }
      if (mib % 256 == 0) log('jetsam: dirty=${mib}MiB');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  });

  Future<void> clearHistory() async {
    await _prefs.remove(_kHistory);
    await _prefs.remove(_kLaunch);
    await _prefs.remove(_kReference);
    lines.clear();
    log('history cleared');
  }
}

class _ProbeApp extends StatelessWidget {
  const _ProbeApp({required this.probe});

  final _Probe probe;

  @override
  Widget build(BuildContext context) {
    final actions = <String, VoidCallback>{
      'Mark': () => unawaited(probe.mark()),
      'Re-resolve': () => unawaited(probe.reResolve()),
      'Periodic': probe.togglePeriodic,
      'Export': () => unawaited(probe.exportReference()),
      'Bind persisted': () => unawaited(probe.bindPersisted()),
      'Jetsam': () => unawaited(probe.jetsam()),
      if (_probeHosted) 'Multi-engine': () => unawaited(probe.multiEngine()),
      if (_probeHosted) 'Teardown': () => unawaited(probe.bridgeTeardown()),
      'Clear': () => unawaited(probe.clearHistory()),
    };
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Strict clock probe')),
        body: ListenableBuilder(
          listenable: probe,
          builder: (context, _) => Column(
            children: [
              Wrap(
                spacing: 8,
                children: [
                  for (final e in actions.entries)
                    OutlinedButton(
                      onPressed: e.value,
                      child: Text(
                        e.key == 'Periodic' && probe.periodic
                            ? 'Stop periodic'
                            : e.key,
                      ),
                    ),
                ],
              ),
              Expanded(
                child: ListView(
                  reverse: true,
                  padding: const EdgeInsets.all(8),
                  children: [
                    for (final line in probe.lines.reversed)
                      SelectableText(
                        line,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

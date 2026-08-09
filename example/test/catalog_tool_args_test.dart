// Routing coverage for `loadAndProbeCatalog`, the stage both catalog
// tools share between flag parsing and their own output.
//
// The trust flags only reach a handshake if this function turns them
// into a client and forwards that client — plus `requiredBackend` — to
// `probeAll`. Dropping either argument leaves the tools silently on the
// permissive process-wide default path, which no per-unit test of
// `trustPolicyPairingError` or `probeHost` would notice.
//
// The counting bridge deals in the FFI DTOs `NtsRustLibApi` is defined
// over, the same way `lib/src/mock_api.dart` does.
// ignore_for_file: implementation_imports, invalid_use_of_internal_member

import 'dart:io';
import 'dart:math' show Random;

import 'package:args/args.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nts/nts.dart' as nts show TrustBackend, TrustMode;
import 'package:nts/src/ffi/api/nts.dart'
    as ffi
    show
        NtsClient,
        NtsServerSpec,
        NtsTimeSample,
        TrustMode,
        TrustMode_BundledOnly,
        TrustMode_Custom;
import 'package:nts/src/ffi/frb_generated.dart' show NtsRustLib;
import 'package:nts_example/src/cli/catalog_tool_args.dart';
import 'package:nts_example/src/health/server_health.dart';
import 'package:nts_example/src/mock_api.dart';

/// [MockNtsApi] that records which of the two dispatch paths a run took
/// and, for the per-client one, the mode the client was minted with.
class _CountingApi extends MockNtsApi {
  // Seeded so the mock's synthetic-failure and hybrid-fallback dice are
  // fixed for the run rather than flaking one probe in a few hundred.
  _CountingApi() : super(random: Random(20260809));

  int singletonQueries = 0;
  int clientQueries = 0;
  final List<ffi.TrustMode> mintedModes = [];

  /// Snapshot of the bytes a `TrustMode.custom` arrived with. Taken at
  /// mint time because `NtsClient` wipes its own FFI-side copy in a
  /// `finally`, so the retained mode reads as zeros afterwards.
  final List<List<int>> mintedCustomRoots = [];

  @override
  Future<ffi.NtsTimeSample> crateApiNtsNtsQuery({
    required ffi.NtsServerSpec spec,
    required int timeoutMs,
    required int dnsConcurrencyCap,
    int? verificationTimeMs,
  }) {
    singletonQueries++;
    return super.crateApiNtsNtsQuery(
      spec: spec,
      timeoutMs: timeoutMs,
      dnsConcurrencyCap: dnsConcurrencyCap,
      verificationTimeMs: verificationTimeMs,
    );
  }

  @override
  ffi.NtsClient crateApiNtsNtsClientWithTrustMode({
    required ffi.TrustMode trustMode,
  }) {
    mintedModes.add(trustMode);
    if (trustMode is ffi.TrustMode_Custom) {
      mintedCustomRoots.add(List<int>.of(trustMode.field0));
    }
    return super.crateApiNtsNtsClientWithTrustMode(trustMode: trustMode);
  }

  @override
  Future<ffi.NtsTimeSample> crateApiNtsNtsClientQuery({
    required ffi.NtsClient that,
    required ffi.NtsServerSpec spec,
    required int timeoutMs,
    required int dnsConcurrencyCap,
    int? verificationTimeMs,
  }) {
    clientQueries++;
    return super.crateApiNtsNtsClientQuery(
      that: that,
      spec: spec,
      timeoutMs: timeoutMs,
      dnsConcurrencyCap: dnsConcurrencyCap,
      verificationTimeMs: verificationTimeMs,
    );
  }
}

void main() {
  group('loadAndProbeCatalog — trust-flag routing', () {
    // The bridge refuses a second `initMock`, so one instance serves
    // the whole group; `initBridge(useMock: true)` sees it installed
    // and reuses it.
    final api = _CountingApi();
    setUpAll(() => NtsRustLib.initMock(api: api));

    late Directory dir;
    late String path;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('nts_catalog_tool_args_test');
      path = '${dir.path}/servers.yml';
      File(path).writeAsStringSync(
        'servers:\n'
        '  - hostname: h.example\n'
        '    stratum: 1\n'
        '    location: Test\n'
        '    owner: Test\n'
        '    vm: false\n',
      );
      api.singletonQueries = 0;
      api.clientQueries = 0;
      api.mintedModes.clear();
      api.mintedCustomRoots.clear();
    });

    tearDown(() => dir.deleteSync(recursive: true));

    CommonProbeArgs args({
      nts.TrustMode trustMode = nts.TrustMode.platformWithFallback,
      nts.TrustBackend? requiredBackend,
    }) => CommonProbeArgs(
      port: 4460,
      timeoutMs: 1000,
      samples: 1,
      concurrency: 1,
      offsetThresholdMs: 1000,
      dnsCap: 1,
      useMock: true,
      libraryPath: null,
      path: path,
      trustMode: trustMode,
      requiredBackend: requiredBackend,
    );

    test('default mode routes through the process-wide default client', () {
      // Minting a client for the default policy would give every
      // pre-existing invocation a lifecycle it never had.
      return loadAndProbeCatalog(args()).then((outcome) {
        expect(api.mintedModes, isEmpty);
        expect(api.clientQueries, 0);
        expect(api.singletonQueries, 1);
        expect(outcome.report.single.verdict, HealthVerdict.healthy);
      });
    });

    test('a non-default mode mints one client and probes through it', () async {
      final outcome = await loadAndProbeCatalog(
        args(trustMode: nts.TrustMode.bundledOnly),
      );
      expect(api.mintedModes, hasLength(1));
      expect(api.mintedModes.single, isA<ffi.TrustMode_BundledOnly>());
      expect(api.clientQueries, 1);
      expect(api.singletonQueries, 0);
      expect(outcome.report.single.verdict, HealthVerdict.healthy);
    });

    test(
      '--custom-roots reaches the FFI mode and the buffer is wiped',
      () async {
        // The other cases construct `CommonProbeArgs` directly, which
        // cannot supply roots, so this one starts at the parser: it is the
        // only coverage of the roots-file read, of the bytes arriving at
        // the FFI boundary as `TrustMode.custom`, and of the caller-side
        // buffer being cleared once the client has copied them.
        final rootsPath = '${dir.path}/roots.pem';
        final rootsBytes = List<int>.generate(64, (i) => i + 1);
        File(rootsPath).writeAsBytesSync(rootsBytes);

        final parser = ArgParser();
        addCommonProbeOptions(parser);
        addBridgeAndHelpFlags(parser);
        final parsed = parseCommonProbeArgs(
          parser.parse([
            '--mock',
            '--trust-mode',
            'custom',
            '--custom-roots',
            rootsPath,
            '-c',
            '1',
            '-n',
            '1',
            path,
          ]),
          usage: parser.usage,
        );
        expect(parsed.customRoots, rootsBytes);

        final outcome = await loadAndProbeCatalog(parsed);

        expect(api.mintedModes.single, isA<ffi.TrustMode_Custom>());
        expect(api.mintedCustomRoots.single, rootsBytes);
        expect(api.clientQueries, 1);
        expect(api.singletonQueries, 0);
        expect(outcome.report.single.verdict, HealthVerdict.healthy);

        // Same buffer reachable two ways; both must read as zeros.
        expect(parsed.customRoots, everyElement(0));
        expect(outcome.args.customRoots, everyElement(0));
      },
    );

    test('requiredBackend reaches the probe and can fail the host', () async {
      // A bundled-only client authenticates on webpki-roots under the
      // mock, so demanding `platform` must fail the host. Dropping the
      // argument would report `healthy` instead.
      final outcome = await loadAndProbeCatalog(
        args(
          trustMode: nts.TrustMode.bundledOnly,
          requiredBackend: nts.TrustBackend.platform,
        ),
      );
      final health = outcome.report.single;
      expect(health.verdict, HealthVerdict.nonConforming);
      expect(health.isDropCandidate, isTrue);
      expect(health.dominantErrorType, 'ke:TrustBackendMismatch');
      // The mismatch is caught on the warm, so no sample is dispatched.
      expect(api.clientQueries, 0);
    });
  });
}

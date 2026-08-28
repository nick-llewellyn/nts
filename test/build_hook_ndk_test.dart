// Unit tests for the Android NDK floor check in `hook/build.dart`.
//
// The hook refuses to build `libnts_rust.so` against an NDK below r28,
// because the 16 KB page alignment Android 15+ requires comes entirely
// from the NDK clang driver's default `-z max-page-size` (4 KB through
// r27, 16 KB from r28). The two halves are tested separately: locating
// the NDK root behind the compiler path the SDK hands the hook, and
// deciding on the `Pkg.Revision` found there.
//
// `@TestOn('vm')` matches the hook itself, which uses `dart:io`.
@TestOn('vm')
library;

import 'package:flutter_test/flutter_test.dart';

import '../hook/build.dart';

// A `source.properties` in the shape the NDK ships, so the parser is
// exercised against the real key ordering rather than a bare line.
String sourceProperties(String revision) =>
    'Pkg.Desc = Android NDK\n'
    'Pkg.Revision = $revision\n'
    'Pkg.BaseRevision = $revision\n';

void main() {
  group('androidNdkRoot', () {
    test('resolves the root from an NDK clang path', () {
      expect(
        androidNdkRoot(
          Uri.file(
            '/opt/sdk/ndk/28.2.13676358/toolchains/llvm/prebuilt/'
            'darwin-x86_64/bin/aarch64-linux-android35-clang',
          ),
        ),
        Uri.file('/opt/sdk/ndk/28.2.13676358/'),
      );
    });

    test('resolves the root from a Windows-suffixed clang path', () {
      expect(
        androidNdkRoot(
          Uri.file(
            '/c/sdk/ndk/28.2.13676358/toolchains/llvm/prebuilt/'
            'windows-x86_64/bin/armv7a-linux-androideabi35-clang.cmd',
          ),
        ),
        Uri.file('/c/sdk/ndk/28.2.13676358/'),
      );
    });

    // Every one of these must fail open rather than guess: a compiler
    // that is not an NDK clang has no revision to read, and breaking
    // the build over an unrecognised layout is worse than skipping the
    // check.
    test('returns null for a compiler outside the NDK layout', () {
      expect(androidNdkRoot(null), isNull);
      expect(androidNdkRoot(Uri.file('/usr/bin/clang')), isNull);
      expect(
        androidNdkRoot(Uri.file('/opt/toolchains/llvm/prebuilt/host/clang')),
        isNull,
        reason: 'no bin/ segment',
      );
      expect(
        androidNdkRoot(
          Uri.file('/opt/ndk/28/toolchains/gcc/prebuilt/host/bin/clang'),
        ),
        isNull,
        reason: 'not the llvm toolchain',
      );
    });
  });

  group('androidNdkFloorFailure', () {
    test('accepts the revision every supported Flutter resolves to', () {
      expect(androidNdkFloorFailure(sourceProperties('28.2.13676358')), isNull);
    });

    test('accepts revisions above the floor', () {
      expect(androidNdkFloorFailure(sourceProperties('30.0.14904198')), isNull);
    });

    test('rejects r27, naming the revision and the page-size requirement', () {
      final failure = androidNdkFloorFailure(sourceProperties('27.0.12077973'));
      expect(failure, isNotNull);
      expect(failure, contains('27.0.12077973'));
      expect(failure, contains('16 KB'));
      expect(failure, contains('r$minimumAndroidNdkMajor'));
    });

    test('rejects a beta revision below the floor', () {
      expect(
        androidNdkFloorFailure(sourceProperties('27.1.12297006-beta1')),
        isNotNull,
      );
    });

    // Fail-open cases: an unreadable revision is indistinguishable from
    // a toolchain we do not understand, and the floor is only enforced
    // when the answer is known.
    test('accepts source.properties without a parseable revision', () {
      expect(androidNdkFloorFailure('Pkg.Desc = Android NDK\n'), isNull);
      expect(androidNdkFloorFailure(''), isNull);
      expect(androidNdkFloorFailure(sourceProperties('r27')), isNull);
    });
  });
}

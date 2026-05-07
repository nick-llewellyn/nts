# R8 / ProGuard keep rules contributed by the `nts` Flutter plugin.
#
# These are auto-merged into the consuming application's shrinker config
# via `consumerProguardFiles("consumer-rules.pro")` declared in
# `android/build.gradle.kts`. Host apps need do nothing.
#
# `nts` delegates X.509 chain validation on Android to the
# `rustls-platform-verifier` Kotlin glue published in the companion AAR
# `rustls:rustls-platform-verifier`. The Rust crate reaches that glue
# exclusively via JNI lookups
# (`JNIEnv::find_class("org/rustls/platformverifier/CertificateVerifier")`
# in `rustls-platform-verifier-0.5.3/src/android.rs`), so R8 sees no static
# reference to it and would otherwise dead-code-eliminate the whole package.
#
# When that happens the verifier path fails on the first NTS-KE TLS 1.3
# handshake (RFC 8915 §4) with a `ClassNotFoundException` for
# `org/rustls/platformverifier/CertificateVerifier`, surfaced through
# `tracing` as the opaque `Network: unexpected error: failed to call native
# verifier: Error` (the unit-struct `Error` masks the underlying `JNIError`,
# see `hybrid_verifier.rs` notes for context).
#
# Keeping the package and its members is sufficient: the AAR ships only
# `CertificateVerifier`, `StatusCode`, `VerificationResult`, and the inner
# class `CertificateVerifier$makeLazyTrustManager$1`, all reflectively
# loaded from native code.
-keep class org.rustls.platformverifier.** { *; }
-keepclassmembers class org.rustls.platformverifier.** { *; }

# Our own JNI shim. `com.nllewellyn.nts.PlatformInit.nativeInit` is matched
# at JVM load time to the Rust symbol
# `Java_com_nllewellyn_nts_PlatformInit_nativeInit` exported from
# `packages/nts/rust/src/android_init.rs`. Keep the class and its
# `nativeInit` member so neither the JVM-side `external fun` nor the
# Rust-side `#[no_mangle]` symbol gets renamed or stripped under
# aggressive shrinking.
-keep class com.nllewellyn.nts.PlatformInit {
    private static native boolean nativeInit(android.content.Context);
}

# Our `FlutterPlugin` is loaded reflectively by the host app's
# `GeneratedPluginRegistrant` based on the `pluginClass` declared in
# `pubspec.yaml`. Keep the class so R8 does not eliminate it; the
# `keepclasseswithmembers` rule covering native methods on
# `com.nllewellyn.nts.**` is intentionally narrow to avoid masking
# unrelated dead code.
-keep class com.nllewellyn.nts.NtsPlugin { *; }

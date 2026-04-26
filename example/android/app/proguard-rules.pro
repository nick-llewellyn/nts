# R8 / ProGuard keep rules for the `nts` example.
#
# The `nts` package delegates X.509 chain validation on Android to the
# `rustls-platform-verifier` Kotlin glue published in the companion AAR
# `rustls:rustls-platform-verifier` (see
# `app/build.gradle.kts::findRustlsPlatformVerifierMaven`). The Rust crate
# reaches that glue exclusively via JNI lookups
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

# Our own JNI shim is loaded by name from `RustlsBootstrap.kt` and exposes
# the JNI symbol `Java_com_nts_example_RustlsBootstrap_nativeInit`
# implemented in `packages/nts/rust/src/android_init.rs`. Keep the class
# and its `nativeInit` member so neither the JVM-side `external fun` nor
# the Rust-side `#[no_mangle]` symbol gets renamed or stripped under
# aggressive shrinking.
-keep class com.nts.example.RustlsBootstrap {
    private static native boolean nativeInit(android.content.Context);
}

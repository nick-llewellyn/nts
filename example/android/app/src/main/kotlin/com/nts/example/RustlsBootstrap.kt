package com.nts.example

import android.content.Context
import android.util.Log

/**
 * Android-side bootstrap for `rustls-platform-verifier`.
 *
 * The Rust crate cannot reach the system `X509TrustManager` until it has
 * captured a `JavaVM` handle and an `android.content.Context`. The Rust
 * counterpart (`packages/nts/rust/src/android_init.rs`) exports a single
 * JNI symbol — mangled for `com.nts.example.RustlsBootstrap` — that
 * takes the application context and feeds it to
 * `rustls_platform_verifier::android::init_with_env`. Once that call
 * returns, the platform verifier is wired up for the rest of the process'
 * lifetime and `nts_query` can complete its TLS 1.3 handshake on TCP/4460
 * against `time.cloudflare.com`, `nts.netnod.se`, etc.
 *
 * The companion AAR is supplied by `rustls-platform-verifier-android` and
 * pulled in by `app/build.gradle.kts` via a cargo-metadata-driven Maven
 * repository.
 *
 * This is the contract every host application must satisfy: declare a class
 * with this exact fully-qualified name (`com.nts.example.RustlsBootstrap`)
 * and call [init] from `Activity.onCreate` (or `Application.onCreate`)
 * before any FRB call. The fixed FQDN is what lets the `nts` Rust crate
 * ship a stable JNI symbol; rename either side and the JVM will fail to
 * bind the native method at runtime.
 *
 * # ProGuard / R8 keep rules (mandatory for release builds)
 *
 * The Rust crate reaches the AAR's verifier exclusively through reflective
 * JNI lookups (`JNIEnv::find_class("org/rustls/platformverifier/CertificateVerifier")`
 * in `rustls-platform-verifier-0.5.3/src/android.rs`). R8 sees no static
 * reference to those classes from the Kotlin/Java side and will dead-code-
 * eliminate the entire `org.rustls.platformverifier` package on any release
 * build with `isMinifyEnabled = true` — which is the Flutter default.
 *
 * When that happens, [init] still succeeds (the underlying
 * `init_with_env` call only captures a class loader), but the first
 * NTS-KE TLS 1.3 handshake fails with the opaque
 * `Network: unexpected error: failed to call native verifier: Error`,
 * masking an underlying `ClassNotFoundException`.
 *
 * Host applications consuming this bootstrap **must** add the following
 * keep rules to their `proguard-rules.pro` (or equivalent) and reference
 * that file from `app/build.gradle.kts` via `proguardFiles(...)`:
 *
 * ```proguard
 * -keep class org.rustls.platformverifier.** { *; }
 * -keepclassmembers class org.rustls.platformverifier.** { *; }
 * -keep class com.nts.example.RustlsBootstrap {
 *     private static native boolean nativeInit(android.content.Context);
 * }
 * ```
 *
 * See `packages/nts/example/android/app/proguard-rules.pro` for the
 * canonical, fully-commented copy.
 */
internal object RustlsBootstrap {
    private const val TAG = "RustlsBootstrap"

    /**
     * Whether the Rust dylib has been loaded and `nativeInit` invoked. The
     * underlying Rust initializer is itself idempotent (guarded by a
     * `OnceCell`), but tracking this flag here lets us skip a redundant
     * `System.loadLibrary` round-trip when the activity is recreated.
     */
    @Volatile private var initialized = false

    /**
     * Loads the bundled `libnts_rust.so` (placed in the APK by Flutter's
     * Native Assets pipeline) and hands the application context to the
     * Rust verifier bootstrap.
     *
     * Called once from `MainActivity.onCreate`. Failures are logged and
     * swallowed: when initialization fails the `nts` Rust code falls
     * back to the `webpki-roots` static trust bundle (see
     * `nts/ke.rs::build_tls_config`), which still produces a working
     * NTS-KE handshake against the major public NTS providers but loses
     * enterprise/MDM-managed root visibility.
     */
    fun init(context: Context) {
        if (initialized) return
        synchronized(this) {
            if (initialized) return
            try {
                System.loadLibrary("nts_rust")
            } catch (t: UnsatisfiedLinkError) {
                Log.e(
                    TAG,
                    "Could not load libnts_rust.so; " +
                        "rustls-platform-verifier will not be initialized. " +
                        "TLS will fall back to webpki-roots in the Rust crate.",
                    t,
                )
                return
            }
            val ok = nativeInit(context.applicationContext)
            if (!ok) {
                Log.w(
                    TAG,
                    "rustls-platform-verifier nativeInit returned false; " +
                        "verifier may be unusable. Falling back to " +
                        "webpki-roots inside the Rust crate.",
                )
            }
            initialized = true
        }
    }

    /**
     * JNI counterpart of `Java_com_nts_example_RustlsBootstrap_nativeInit`
     * defined in `packages/nts/rust/src/android_init.rs`. Returns `true`
     * on success, `false` when the Rust initializer reports a JNI error
     * (e.g. the supplied object did not implement `getClassLoader`).
     */
    @JvmStatic
    private external fun nativeInit(context: Context): Boolean
}

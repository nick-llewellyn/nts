package com.nllewellyn.nts

import android.content.Context
import android.util.Log

/**
 * Android-side bootstrap for `rustls-platform-verifier`.
 *
 * The Rust crate cannot reach the system `X509TrustManager` until it has
 * captured a `JavaVM` handle and an `android.content.Context`. The Rust
 * counterpart (`rust/src/android_init.rs`) exports a single
 * JNI symbol — mangled for `com.nllewellyn.nts.PlatformInit` — that
 * takes the application context and feeds it to
 * `rustls_platform_verifier::android::init_with_env`. Once that call
 * returns, the platform verifier is wired up for the rest of the process'
 * lifetime and `nts_query` can complete its TLS 1.3 handshake on TCP/4460
 * against `time.cloudflare.com`, `nts.netnod.se`, etc.
 *
 * In the standard Flutter integration path consumers do not need to call
 * [init] themselves: [NtsPlugin.onAttachedToEngine] does it
 * automatically when `GeneratedPluginRegistrant.registerWith` runs, which
 * happens before Dart `main()` in any host using `FlutterActivity`,
 * `FlutterFragmentActivity`, or the Flutter add-to-app `FlutterEngine`
 * lifecycle.
 *
 * [init] is exposed as a public entry point for hosts that bypass that
 * lifecycle (custom embeddings, isolates spawned ahead of plugin
 * registration, integration tests that drive the dylib directly).
 */
object PlatformInit {
    private const val TAG = "nts.PlatformInit"

    /**
     * Whether the Rust dylib has been loaded and `nativeInit` invoked. The
     * underlying Rust initializer is itself idempotent (guarded by a
     * `OnceCell`), but tracking this flag here lets us skip a redundant
     * `System.loadLibrary` round-trip when the activity is recreated or
     * when the plugin is re-attached after a configuration change.
     */
    @Volatile private var initialized = false

    /**
     * Loads the bundled `libnts_rust.so` (placed in the APK by Flutter's
     * Native Assets pipeline) and hands the application context to the
     * Rust verifier bootstrap.
     *
     * Idempotent: subsequent calls are no-ops. Safe to call from any
     * thread; a `synchronized` block guards the one-shot initialization.
     *
     * Failures are logged and swallowed: when initialization fails the
     * `nts` Rust code falls back to the `webpki-roots` static trust
     * bundle (see `nts/ke.rs::build_tls_config`), which still produces a
     * working NTS-KE handshake against the major public NTS providers
     * but loses enterprise/MDM-managed root visibility.
     */
    @JvmStatic
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
     * JNI counterpart of `Java_com_nllewellyn_nts_PlatformInit_nativeInit`
     * defined in `rust/src/android_init.rs`. Returns `true`
     * on success, `false` when the Rust initializer reports a JNI error
     * (e.g. the supplied object did not implement `getClassLoader`).
     */
    @JvmStatic
    private external fun nativeInit(context: Context): Boolean
}

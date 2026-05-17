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
     * Whether the Rust dylib has been loaded and `nativeInit` returned
     * success. The underlying Rust initializer is itself idempotent
     * (guarded by a `OnceCell`), but tracking this flag here lets us
     * skip a redundant `System.loadLibrary` round-trip and re-entry
     * into the JNI bootstrap when the activity is recreated or when
     * the plugin is re-attached after a configuration change.
     *
     * Set only on the success path: a `nativeInit` failure (e.g. the
     * supplied `Context` did not implement `getClassLoader`) leaves
     * the flag false so a later [init] call with a valid context can
     * retry. `System.loadLibrary` is itself idempotent at the JVM
     * level, so the retry path re-runs cheaply.
     */
    @Volatile private var initialized = false

    /**
     * Loads the bundled `libnts_rust.so` (placed in the APK by Flutter's
     * Native Assets pipeline) and hands the application context to the
     * Rust verifier bootstrap.
     *
     * Idempotent on success: once `nativeInit` has reported success
     * subsequent calls are no-ops. Safe to call from any thread; a
     * `synchronized` block guards the one-shot initialization.
     *
     * Failures are logged and swallowed: the handshake-time consequence
     * then depends on the caller's `TrustMode`. With the default
     * `TrustMode.platformWithFallback`, the `nts` Rust code falls back to
     * the `webpki-roots` static trust bundle (see
     * `nts/ke.rs::build_tls_config`), which still produces a working
     * NTS-KE handshake against the major public NTS providers but loses
     * enterprise/MDM-managed root visibility. With the strict
     * `TrustMode.platformOnly` (added in 4.0.0), the same failure
     * surfaces at handshake time as `NtsError.trustBackendUnavailable`
     * instead of falling back. Failed attempts do not latch the no-op
     * gate, so a later call with a valid application `Context` will
     * retry the JNI bootstrap.
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
                        "Handshake behaviour then depends on TrustMode: " +
                        "platformWithFallback falls back to webpki-roots, " +
                        "platformOnly surfaces NtsError.trustBackendUnavailable.",
                    t,
                )
                return
            }
            val ok = nativeInit(context.applicationContext)
            if (!ok) {
                Log.w(
                    TAG,
                    "rustls-platform-verifier nativeInit returned false; " +
                        "verifier may be unusable on this attempt. " +
                        "Handshake behaviour then depends on TrustMode: " +
                        "platformWithFallback falls back to webpki-roots, " +
                        "platformOnly surfaces NtsError.trustBackendUnavailable. " +
                        "A later init(context) call with a valid Context will retry.",
                )
                return
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

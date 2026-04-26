//! Android-only JNI bootstrap for `rustls-platform-verifier`.
//!
//! The platform verifier delegates X.509 chain validation to the Android
//! system's `X509TrustManager`. To do that it has to call into the JVM, so
//! the crate requires a one-time initialization step from a JNI entry
//! point that hands it a [`jni::JNIEnv`] and an [`android.content.Context`]
//! reference. If that step is skipped, the first TLS handshake panics with
//! `Expect rustls-platform-verifier to be initialized…` (RFC 8915 §4 NTS-KE
//! over TLS 1.3 in our case).
//!
//! # Wire contract
//!
//! This module exports a single JNI symbol mangled for the Kotlin class
//! `com.nts.example.RustlsBootstrap` declaring
//!
//! ```kotlin
//! external fun nativeInit(context: Context)
//! ```
//!
//! The example app's [`RustlsBootstrap.kt`] declares that class and calls
//! `nativeInit(applicationContext)` from `MainActivity.onCreate()` before
//! Flutter loads. Downstream consumers must replicate the same FQDN and
//! ensure the dylib is loaded (via `System.loadLibrary("nts_rust")`) before
//! invoking it.
//!
//! [`RustlsBootstrap.kt`]: ../../example/android/app/src/main/kotlin/com/nts/example/RustlsBootstrap.kt

use jni::objects::{JClass, JObject};
use jni::sys::jboolean;
use jni::JNIEnv;

/// JNI entry point invoked by `com.nts.example.RustlsBootstrap.nativeInit`.
///
/// Returns `JNI_TRUE` (1) when the verifier was initialized successfully or
/// was already initialized by a previous call, and `JNI_FALSE` (0) when the
/// underlying call to `rustls_platform_verifier::android::init_with_env`
/// returned an error (e.g. the supplied object did not implement
/// `getClassLoader`). The Kotlin side surfaces the boolean to the host app
/// as a non-fatal warning so a failed bootstrap downgrades to the
/// `webpki-roots` fallback in `nts/ke.rs::build_tls_config` rather than
/// crashing the process.
///
/// # Safety
///
/// Called by the JVM with a valid `JNIEnv*` and a non-null `Context`. The
/// `JNIEnv` is bound to the calling thread; we do not retain it past return.
/// `rustls_platform_verifier::android::init_with_env` upgrades the supplied
/// `JObject` to a `GlobalRef` internally before the function returns, so the
/// local reference passed in is safe to drop on return.
#[no_mangle]
pub extern "system" fn Java_com_nts_example_RustlsBootstrap_nativeInit<'local>(
    mut env: JNIEnv<'local>,
    _class: JClass<'local>,
    context: JObject<'local>,
) -> jboolean {
    match rustls_platform_verifier::android::init_with_env(&mut env, context) {
        Ok(()) => 1,
        Err(_) => 0,
    }
}

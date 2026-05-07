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
//! `com.nllewellyn.nts.PlatformInit` declaring
//!
//! ```kotlin
//! external fun nativeInit(context: Context): Boolean
//! ```
//!
//! The Kotlin counterpart ships inside the `nts` Flutter plugin's own
//! Android library module (`android/src/main/kotlin/com/nllewellyn/nts/PlatformInit.kt`)
//! and is registered on the host app automatically via the plugin's
//! `NtsPlugin.onAttachedToEngine` hook. Consumers do not have to declare or
//! call anything themselves — adding `nts` to `pubspec.yaml` is sufficient.
//!
//! The FQDN is intentionally neutral (under the maintainer's reverse-DNS
//! rather than the example app's package) so the Rust crate ships a stable
//! ABI that does not change when the example app is rebranded.
//!
//! [`PlatformInit.kt`]: ../../android/src/main/kotlin/com/nllewellyn/nts/PlatformInit.kt

use jni::objects::{JClass, JObject};
use jni::sys::jboolean;
use jni::JNIEnv;

/// JNI entry point invoked by `com.nllewellyn.nts.PlatformInit.nativeInit`.
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
pub extern "system" fn Java_com_nllewellyn_nts_PlatformInit_nativeInit<'local>(
    mut env: JNIEnv<'local>,
    _class: JClass<'local>,
    context: JObject<'local>,
) -> jboolean {
    match rustls_platform_verifier::android::init_with_env(&mut env, context) {
        Ok(()) => 1,
        Err(_) => 0,
    }
}

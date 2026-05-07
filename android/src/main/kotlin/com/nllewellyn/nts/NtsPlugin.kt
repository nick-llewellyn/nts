package com.nllewellyn.nts

import io.flutter.embedding.engine.plugins.FlutterPlugin

/**
 * `FlutterPlugin` entry point for the `nts` package on Android.
 *
 * The plugin's only job is to invoke [PlatformInit.init] with the host
 * application's `Context` as soon as the plugin is registered. That happens
 * inside `GeneratedPluginRegistrant.registerWith(...)` -- which the
 * Flutter embedding calls before the Dart isolate's `main()` runs --
 * meaning consumers see `rustls-platform-verifier` already wired up by the
 * time their first `nts_query` call lands.
 *
 * This plugin contributes no `MethodChannel`, `EventChannel`, or other
 * runtime surface: all NTS protocol I/O happens via the FRB-generated
 * dylib loaded out-of-band by [PlatformInit] itself.
 *
 * If the host suppresses or replaces `GeneratedPluginRegistrant` (rare;
 * applies mainly to bespoke add-to-app embeddings and pre-3.0 plugin
 * registries), the host **must** call [PlatformInit.init] manually before
 * any `nts` Dart API is exercised. See the public KDoc on [PlatformInit]
 * for the manual contract.
 */
class NtsPlugin : FlutterPlugin {
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        // `applicationContext` is preferred over the `Activity` context: the
        // Rust verifier captures a `GlobalRef` that outlives any single
        // activity, and using the application context avoids leaking an
        // activity reference into native state across configuration
        // changes.
        PlatformInit.init(binding.applicationContext)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        // No-op. `rustls-platform-verifier` has no teardown API; the
        // captured `GlobalRef` is released when the process exits. The
        // initialized flag inside `PlatformInit` is intentionally not
        // reset here so subsequent engine attaches (e.g. plugin
        // re-registration during hot restart) skip the redundant
        // `System.loadLibrary` round-trip.
    }
}

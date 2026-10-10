package com.nts.example

import android.content.pm.ApplicationInfo
import io.flutter.FlutterInjector
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

// `rustls-platform-verifier` is initialised automatically before this
// activity starts by `com.nllewellyn.nts.NtsPlugin.onAttachedToEngine`,
// invoked from `GeneratedPluginRegistrant.registerWith` ahead of Dart
// `main()`. No manual bootstrap is needed in the host app.
//
// Debuggable builds also host the second engine that
// `lib/clock_probe_main.dart` starts for its multi-engine rows, relaying
// its method calls between the two engines.
class MainActivity : FlutterActivity() {
    private var primaryChannel: MethodChannel? = null
    private var secondEngine: FlutterEngine? = null
    private var secondChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        if (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE == 0) return
        val primary = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CLOCK_PROBE)
        primary.setMethodCallHandler { call, result ->
            when (call.method) {
                "startSecondEngine" -> {
                    startSecondEngine()
                    result.success(null)
                }
                "toSecond" -> {
                    secondChannel?.invokeMethod("command", call.arguments)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        primaryChannel = primary
    }

    private fun startSecondEngine() {
        if (secondEngine != null) return
        val engine = FlutterEngine(applicationContext)
        val channel = MethodChannel(engine.dartExecutor.binaryMessenger, CLOCK_PROBE)
        channel.setMethodCallHandler { call, result ->
            if (call.method == "toPrimary") {
                primaryChannel?.invokeMethod("fromSecond", call.arguments)
                result.success(null)
            } else {
                result.notImplemented()
            }
        }
        engine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint(
                FlutterInjector.instance().flutterLoader().findAppBundlePath(),
                "clockProbeSecondEngine",
            ),
        )
        secondEngine = engine
        secondChannel = channel
    }

    override fun onDestroy() {
        secondEngine?.destroy()
        secondEngine = null
        secondChannel = null
        super.onDestroy()
    }

    private companion object {
        const val CLOCK_PROBE = "nts_example/clock_probe"
    }
}

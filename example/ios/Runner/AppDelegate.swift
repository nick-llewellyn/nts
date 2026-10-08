import Flutter
import UIKit

// Debug and profile builds also install host support for
// `lib/clock_probe_main.dart`: the second engine it starts for its
// multi-engine rows, relaying its method calls between the two engines,
// and a background task held while its periodic reads run so they
// continue after a lock. On iOS the probe uses both only in profile
// builds, because a second JIT engine faults on code signing.
@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private static let clockProbe = "nts_example/clock_probe"
  private var primaryChannel: FlutterMethodChannel?
  private var secondEngine: FlutterEngine?
  private var secondChannel: FlutterMethodChannel?
  private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    #if DEBUG || PROFILE
      let primary = FlutterMethodChannel(
        name: Self.clockProbe, binaryMessenger: engineBridge.applicationRegistrar.messenger())
      primary.setMethodCallHandler { [weak self] call, result in
        switch call.method {
        case "startSecondEngine":
          self?.startSecondEngine()
          result(nil)
        case "toSecond":
          self?.secondChannel?.invokeMethod("command", arguments: call.arguments)
          result(nil)
        case "beginBackgroundTask":
          self?.beginBackgroundTask()
          result(nil)
        case "endBackgroundTask":
          self?.endBackgroundTask()
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
      primaryChannel = primary
    #endif
  }

  #if DEBUG || PROFILE
    private func beginBackgroundTask() {
      guard backgroundTask == .invalid else { return }
      backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "clock_probe") {
        [weak self] in
        self?.primaryChannel?.invokeMethod("backgroundTaskExpired", arguments: nil)
        self?.endBackgroundTask()
      }
    }

    private func endBackgroundTask() {
      guard backgroundTask != .invalid else { return }
      UIApplication.shared.endBackgroundTask(backgroundTask)
      backgroundTask = .invalid
    }

    private func startSecondEngine() {
      guard secondEngine == nil else { return }
      let engine = FlutterEngine(name: "clock_probe_second", project: nil)
      engine.run(withEntrypoint: "clockProbeSecondEngine")
      GeneratedPluginRegistrant.register(with: engine)
      let channel = FlutterMethodChannel(
        name: Self.clockProbe, binaryMessenger: engine.binaryMessenger)
      channel.setMethodCallHandler { [weak self] call, result in
        guard call.method == "toPrimary" else {
          result(FlutterMethodNotImplemented)
          return
        }
        self?.primaryChannel?.invokeMethod("fromSecond", arguments: call.arguments)
        result(nil)
      }
      secondEngine = engine
      secondChannel = channel
    }
  #endif
}

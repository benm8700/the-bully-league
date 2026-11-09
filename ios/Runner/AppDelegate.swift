import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Ask iOS for the APNs token ourselves. With the implicit-engine /
    // UIScene setup, plugins register AFTER didFinishLaunching, so
    // firebase_messaging's own launch-time registerForRemoteNotifications
    // never runs and the APNs token never arrives (seen 2026-11-08/09).
    // The token callback still reaches the plugin via super / FCM swizzling.
    application.registerForRemoteNotifications()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}

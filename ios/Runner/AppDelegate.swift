import FirebaseCore
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {

  private static func configureFirebaseIfNeeded() {
    if FirebaseApp.app() == nil {
      FirebaseApp.configure()
    }
  }

  override init() {
    super.init()
    Self.configureFirebaseIfNeeded()
  }

  /// Runs before `didFinishLaunchingWithOptions` — reduces races with FCM / AppDelegate swizzling.
  override func application(
    _ application: UIApplication,
    willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    Self.configureFirebaseIfNeeded()
    return super.application(application, willFinishLaunchingWithOptions: launchOptions)
  }

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    Self.configureFirebaseIfNeeded()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}

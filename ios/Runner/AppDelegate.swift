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
    // Configure before `super.init()` so FlutterAppDelegate’s setup cannot touch
    // Firebase Messaging / Core before a default `FirebaseApp` exists (avoids
    // I-COR000003 and often I-SWZ001014 during early swizzling).
    Self.configureFirebaseIfNeeded()
    super.init()
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

import Flutter
import UIKit
import Firebase

@main
@objc class AppDelegate: FlutterAppDelegate {

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {

    FirebaseApp.configure()

    if #available(iOS 10.0, *) {
      UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate
    }

    GeneratedPluginRegistrant.register(with: self)

    if let controller = window?.rootViewController as? FlutterViewController {
      let proximityChannel = FlutterMethodChannel(
        name: "telemedicine/proximity",
        binaryMessenger: controller.binaryMessenger
      )
      proximityChannel.setMethodCallHandler { (call: FlutterMethodCall, result: @escaping FlutterResult) in
        switch call.method {
        case "enableProximitySensor":
          DispatchQueue.main.async {
            UIDevice.current.isProximityMonitoringEnabled = true
            result(UIDevice.current.isProximityMonitoringEnabled)
          }
        case "disableProximitySensor":
          DispatchQueue.main.async {
            UIDevice.current.isProximityMonitoringEnabled = false
            result(true)
          }
        case "isProximitySensorSupported":
          DispatchQueue.main.async {
            let previous = UIDevice.current.isProximityMonitoringEnabled
            UIDevice.current.isProximityMonitoringEnabled = true
            let supported = UIDevice.current.isProximityMonitoringEnabled
            UIDevice.current.isProximityMonitoringEnabled = previous
            result(supported)
          }
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }

    return super.application(
      application,
      didFinishLaunchingWithOptions: launchOptions
    )
  }
}

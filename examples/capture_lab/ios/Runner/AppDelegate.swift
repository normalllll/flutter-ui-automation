import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var nativeChannel: FlutterMethodChannel?
  private let instanceToken = UUID().uuidString
  private var orientationMask: UIInterfaceOrientationMask = .all
  private var savedOrientation: UIInterfaceOrientation?
  private var savedOrientationMask: UIInterfaceOrientationMask?
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    nativeChannel = FlutterMethodChannel(name: "capture_lab/native", binaryMessenger: engineBridge.applicationRegistrar.messenger())
    nativeChannel?.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(FlutterMethodNotImplemented); return }
      let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
      let window = scene?.windows.first { $0.isKeyWindow }
      if call.method == "status" {
        if let original = self.savedOrientation, let mask = self.savedOrientationMask,
           self.orientationMask == mask, scene?.interfaceOrientation == original {
          self.savedOrientation = nil
          self.savedOrientationMask = nil
        }
        guard let window else { result(FlutterError(code: "not_ready", message: "No active window", details: nil)); return }
        let view = window.rootViewController?.view ?? window
        let bounds = view.convert(view.bounds, to: window)
        let scale = window.screen.scale
        result([
          "platform": "ios", "pid": ProcessInfo.processInfo.processIdentifier,
          "bundleId": Bundle.main.bundleIdentifier ?? "", "instanceToken": self.instanceToken,
          "visible": !window.isHidden, "isForeground": scene?.activationState == .foregroundActive,
          "hasNativeFocus": window.isKeyWindow,
          "interfaceOrientation": scene?.interfaceOrientation.rawValue ?? 0,
          "viewBounds": ["x": bounds.minX * scale, "y": bounds.minY * scale,
                         "width": bounds.width * scale, "height": bounds.height * scale]
        ])
      } else if call.method == "orientation" {
        guard let value = call.arguments as? String, ["portrait", "landscape", "restore"].contains(value), let scene else {
          result(FlutterError(code: "invalid_orientation", message: "Use portrait, landscape or restore", details: nil)); return
        }
        if #available(iOS 16.0, *) {
          let requested: UIInterfaceOrientationMask
          var restoredOrientation: UIInterfaceOrientation?
          if value == "restore" {
            guard let original = self.savedOrientation else { result(nil); return }
            self.orientationMask = self.savedOrientationMask ?? .all
            restoredOrientation = original
            switch original {
            case .portraitUpsideDown: requested = .portraitUpsideDown
            case .landscapeLeft: requested = .landscapeLeft
            case .landscapeRight: requested = .landscapeRight
            default: requested = .portrait
            }
          } else {
            if self.savedOrientation == nil {
              self.savedOrientation = scene.interfaceOrientation
              self.savedOrientationMask = self.orientationMask
            }
            requested = value == "portrait" ? .portrait : .landscape
            self.orientationMask = requested
          }
          window?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
          scene.requestGeometryUpdate(.iOS(interfaceOrientations: requested))
          result(restoredOrientation.map { ["restoredInterfaceOrientation": $0.rawValue] })
        } else {
          result(FlutterError(code: "unsupported_orientation", message: "Scene geometry updates require iOS 16 or newer", details: nil))
        }
      } else { result(FlutterMethodNotImplemented) }
    }
  }

  override func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
    orientationMask
  }
}

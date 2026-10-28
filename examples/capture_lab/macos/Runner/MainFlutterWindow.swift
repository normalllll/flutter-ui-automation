import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSPanel {
  private var nativeChannel: FlutterMethodChannel?
  private let instanceToken = UUID().uuidString
  private var automation: Bool { ProcessInfo.processInfo.environment["CAPTURE_LAB_AUTOMATION"] == "1" }
  override var canBecomeKey: Bool { !automation }
  override var canBecomeMain: Bool { !automation }

  override func awakeFromNib() {
    if automation {
      styleMask.insert(.nonactivatingPanel)
      hidesOnDeactivate = false
      becomesKeyOnlyIfNeeded = true
    }
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    nativeChannel = FlutterMethodChannel(name: "capture_lab/native", binaryMessenger: flutterViewController.engine.binaryMessenger)
    nativeChannel?.setMethodCallHandler { [weak self, weak flutterViewController] call, result in
      guard call.method == "status" else { result(FlutterMethodNotImplemented); return }
      guard let self, let view = flutterViewController?.view else { result(FlutterError(code: "unavailable", message: "Window unavailable", details: nil)); return }
      let scale = self.backingScaleFactor
      let screenRect = self.convertToScreen(view.convert(view.bounds, to: nil))
      result([
        "platform": "macos", "pid": ProcessInfo.processInfo.processIdentifier,
        "windowId": self.windowNumber, "instanceToken": self.instanceToken,
        "visible": self.isVisible, "minimized": self.isMiniaturized,
        "isForeground": NSApp.isActive, "hasNativeFocus": self.isKeyWindow,
        "foregroundPid": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0,
        "viewBounds": ["x": (screenRect.minX - self.frame.minX) * scale,
                       "y": (self.frame.maxY - screenRect.maxY) * scale,
                       "width": view.bounds.width * scale, "height": view.bounds.height * scale]
      ])
    }

    super.awakeFromNib()
  }
}

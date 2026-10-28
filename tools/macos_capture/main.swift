import AppKit
import Foundation
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers

@main
struct Capture {
  static func main() async {
    do {
      let args = CommandLine.arguments
      if args.contains("--authorize") {
        print("{\"screenRecordingAuthorized\":\(CGRequestScreenCaptureAccess())}")
        return
      }
      if args.contains("--preflight") {
        print("{\"screenRecordingAuthorized\":\(CGPreflightScreenCaptureAccess())}")
        return
      }
      func option(_ name: String) throws -> String {
        guard let index = args.firstIndex(of: name), index + 1 < args.count else {
          throw NSError(domain: "capture", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing \(name)"])
        }
        return args[index + 1]
      }
      guard CGPreflightScreenCaptureAccess() else {
        throw NSError(domain: "screen_recording_permission_required", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "Grant Screen Recording to this capture helper before retrying"])
      }
      guard #available(macOS 14.0, *) else {
        throw NSError(domain: "capture", code: 4, userInfo: [NSLocalizedDescriptionKey: "Window screenshots require macOS 14 or newer"])
      }
      let pid = try option("--pid"), identifier = try option("--window"), output = try option("--output")
      let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
      guard let window = content.windows.first(where: { String($0.windowID) == identifier && String($0.owningApplication?.processID ?? 0) == pid }) else {
        throw NSError(domain: "target_changed", code: 5, userInfo: [NSLocalizedDescriptionKey: "Window does not belong to selected process"])
      }
      let filter = SCContentFilter(desktopIndependentWindow: window)
      let configuration = SCStreamConfiguration()
      configuration.width = Int(filter.contentRect.width * Double(filter.pointPixelScale))
      configuration.height = Int(filter.contentRect.height * Double(filter.pointPixelScale))
      configuration.showsCursor = false
      if #available(macOS 14.2, *) { configuration.ignoreShadowsSingleWindow = true }
      let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
      guard let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: output) as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "capture", code: 6)
      }
      CGImageDestinationAddImage(destination, image, nil)
      guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "capture", code: 7) }
      let metadata: [String: Any] = ["source": "ScreenCaptureKit window", "pid": Int(pid)!, "windowId": window.windowID, "width": image.width, "height": image.height]
      print(String(data: try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]), encoding: .utf8)!)
    } catch {
      FileHandle.standardError.write(Data("\(error)\n".utf8))
      exit(1)
    }
  }
}

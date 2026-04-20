import AVFoundation
import Cocoa
import FlutterMacOS
import desktop_multi_window
import flutter_secure_storage_macos
import path_provider_foundation
import screen_retriever
import url_launcher_macos
import window_manager

@main
class AppDelegate: FlutterAppDelegate {
  // Tracks windows we've already restyled so we only apply chrome once per
  // window. Using ObjectIdentifier avoids retaining the NSWindow.
  private var styledWindows = Set<ObjectIdentifier>()

  override func applicationDidFinishLaunching(_ notification: Notification) {
    AVCaptureDevice.requestAccess(for: .audio) { granted in
      print("[AppDelegate] Microphone permission: \(granted)")
    }

    // desktop_multi_window 0.2.1 ships a dead setOnWindowCreatedCallback API
    // (the callback is stored but never invoked), so sub-windows keep the
    // default titled/closable/miniaturizable chrome. Observe the global
    // didBecomeKey notification instead — it fires reliably when any window
    // (including multi_window sub-windows) is first shown.
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(windowDidBecomeKey(_:)),
      name: NSWindow.didBecomeKeyNotification,
      object: nil
    )

    super.applicationDidFinishLaunching(notification)
  }

  @objc private func windowDidBecomeKey(_ notification: Notification) {
    guard let window = notification.object as? NSWindow else { return }
    // Skip the main Flutter window — it already gets chrome via MainFlutterWindow.
    if window === mainFlutterWindow { return }
    let id = ObjectIdentifier(window)
    if styledWindows.contains(id) { return }
    styledWindows.insert(id)

    NSLog("[AppDelegate] ✅ Styling sub-window: \(window.title)")
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = false
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.styleMask.insert(.fullSizeContentView)
    window.standardWindowButton(.closeButton)?.isHidden = true
    window.standardWindowButton(.miniaturizeButton)?.isHidden = true
    window.standardWindowButton(.zoomButton)?.isHidden = true
    window.isMovableByWindowBackground = true
    window.level = .floating

    // Force the content view layer to be transparent so Flutter's translucent
    // gradient actually shows through — setting backgroundColor on NSWindow
    // alone isn't enough when the contentView is layer-backed with an opaque
    // backing layer.
    if let contentView = window.contentView {
      contentView.wantsLayer = true
      contentView.layer?.backgroundColor = NSColor.clear.cgColor
      contentView.layer?.isOpaque = false
      // Also clear any Metal sublayers from FlutterView.
      contentView.layer?.sublayers?.forEach { sub in
        sub.backgroundColor = NSColor.clear.cgColor
        sub.isOpaque = false
      }
    }

    // desktop_multi_window sub-windows don't register window_manager's
    // MethodChannel on macOS, so DragToMoveArea/minimize calls silently fail.
    // Register our own channel on the sub-window's FlutterEngine and forward
    // to native NSWindow APIs.
    if let controller = window.contentViewController as? FlutterViewController {
      // Flutter 3.22+ exposes FlutterViewController.backgroundColor which sets
      // the FlutterView's layer to transparent. Without this the CAMetalLayer
      // under FlutterView stays opaque regardless of the NSWindow config.
      controller.backgroundColor = NSColor.clear

      let channel = FlutterMethodChannel(
        name: "easyexpert/window_drag",
        binaryMessenger: controller.engine.binaryMessenger
      )
      channel.setMethodCallHandler { [weak window] call, result in
        guard let window = window else { result(nil); return }
        switch call.method {
        case "startDragging":
          if let event = NSApp.currentEvent {
            window.performDrag(with: event)
          }
          result(nil)
        case "minimize":
          window.miniaturize(nil)
          result(nil)
        case "close":
          window.close()
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}

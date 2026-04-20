import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Configurar propiedades de la ventana para macOS
    self.isOpaque = false
    self.backgroundColor = NSColor.clear
    self.level = .normal
    
    super.awakeFromNib()
  }
}

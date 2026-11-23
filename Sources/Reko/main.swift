import AppKit

// Menu-bar app (no Dock icon); LSUIElement in Info.plist makes this stick when launched as Reko.app.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

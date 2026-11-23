import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = Settings()
    private lazy var controller = PrompterController(settings: settings)
    private lazy var remote = RemoteServer(
        token: settings.remoteToken,
        onCommand: { [weak self] in self?.controller.perform($0) },
        onCue: { [weak self] in self?.controller.show(); self?.controller.jump(toSection: $0) },
        state: { [weak self] in self?.controller.remoteState ?? [:] })
    private var hotKeys: HotKeys?
    private var statusItem: NSStatusItem?
    private var editorWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        hotKeys = HotKeys { [weak self] in self?.controller.perform($0) }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "Reko")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item

        settings.$remoteEnabled
            .sink { [weak self] on in on ? self?.remote.start() : self?.remote.stop() }
            .store(in: &cancellables)

        controller.$isPlaying.combineLatest(controller.$countdownRemaining)
            .map { playing, countdown in playing || countdown != nil }
            .sink { [weak self] playing in
                self?.statusItem?.button?.image = NSImage(systemSymbolName: playing ? "text.bubble.fill" : "text.bubble",
                                                          accessibilityDescription: "Reko")
            }
            .store(in: &cancellables)

        openEditor()
        controller.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.flushPendingSave()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openEditor()
        return true
    }

    // MARK: Menu bar

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let c = controller

        menu.addItem(item(c.isVisible ? "Hide Prompter" : "Show Prompter", .toggleVisible))
        menu.addItem(item(c.isPlaying || c.countdownRemaining != nil ? "Pause" : "Play", .togglePlay))
        menu.addItem(item("Back to Top", .restart))
        menu.addItem(.separator())

        let modeHeader = NSMenuItem(title: "Scrolling", action: nil, keyEquivalent: "")
        modeHeader.isEnabled = false
        menu.addItem(modeHeader)
        for mode in ScrollMode.allCases {
            let mi = NSMenuItem(title: mode.title, action: #selector(selectMode(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = mode.rawValue
            mi.state = settings.scrollMode == mode ? .on : .off
            mi.indentationLevel = 1
            menu.addItem(mi)
        }

        let display = NSMenuItem(title: "Position", action: nil, keyEquivalent: "")
        let displayMenu = NSMenu()
        for mode in DisplayMode.allCases {
            let mi = NSMenuItem(title: mode.title, action: #selector(selectDisplay(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = mode.rawValue
            mi.state = settings.displayMode == mode ? .on : .off
            displayMenu.addItem(mi)
        }
        display.submenu = displayMenu
        menu.addItem(display)

        if !c.script.sections.isEmpty {
            let cues = NSMenuItem(title: "Jump to Cue", action: nil, keyEquivalent: "")
            let cueMenu = NSMenu()
            for (i, section) in c.script.sections.enumerated() {
                let mi = NSMenuItem(title: section.title, action: #selector(jumpToCue(_:)), keyEquivalent: "")
                mi.target = self
                mi.tag = i
                mi.state = c.currentSection == i ? .on : .off
                cueMenu.addItem(mi)
            }
            cues.submenu = cueMenu
            menu.addItem(cues)
        }

        menu.addItem(.separator())
        let editor = NSMenuItem(title: "Script & Settings…", action: #selector(openEditorAction), keyEquivalent: ",")
        editor.target = self
        menu.addItem(editor)
        remote.refreshURL()
        if settings.remoteEnabled, remote.url != nil {
            let copy = NSMenuItem(title: "Copy Phone Remote Link", action: #selector(copyRemoteURL), keyEquivalent: "")
            copy.target = self
            menu.addItem(copy)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Reko", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func item(_ title: String, _ command: Command) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: #selector(runCommand(_:)), keyEquivalent: "")
        mi.target = self
        mi.representedObject = command.rawValue
        if let shortcut = HotKeys.display(for: command) { mi.toolTip = shortcut; mi.title += "    \(shortcut)" }
        return mi
    }

    @objc private func runCommand(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let command = Command(rawValue: raw) { controller.perform(command) }
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let mode = ScrollMode(rawValue: raw) { settings.scrollMode = mode }
    }

    @objc private func selectDisplay(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let mode = DisplayMode(rawValue: raw) { settings.displayMode = mode }
    }

    @objc private func jumpToCue(_ sender: NSMenuItem) {
        controller.show()
        controller.jump(toSection: sender.tag)
    }

    @objc private func copyRemoteURL() {
        if let url = remote.url { copyToPasteboard(url) }
    }

    @objc private func openEditorAction() { openEditor() }

    // MARK: Editor window

    private func openEditor() {
        if editorWindow == nil {
            let view = EditorView(controller: controller, settings: settings, remote: remote)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Reko"
            window.contentViewController = NSHostingController(rootView: view)
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("RekoEditor")
            if !window.setFrameUsingName("RekoEditor") { window.center() }
            editorWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        editorWindow?.makeKeyAndOrderFront(nil)
    }
}

import SwiftUI
import Speech
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers

/// Script editor on the left, all settings on the right.
struct EditorView: View {
    @ObservedObject var controller: PrompterController
    @ObservedObject var settings: Settings
    @ObservedObject var remote: RemoteServer

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                TextEditor(text: $controller.scriptText)
                    .font(.system(size: 14, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(12)
                Divider()
                HStack {
                    Text(summary).foregroundStyle(.secondary)
                    Spacer()
                    Text("# Heading = cue · [text] = direction (not read aloud)").foregroundStyle(.tertiary)
                }
                .font(.caption)
                .padding(.horizontal, 12).padding(.vertical, 6)
            }
            .frame(minWidth: 380)

            SettingsPane(controller: controller, settings: settings, remote: remote)
                .frame(minWidth: 300, idealWidth: 330, maxWidth: 380)
        }
        .toolbar {
            ToolbarItemGroup {
                Button("Open…", systemImage: "folder", action: openFile)
                Button("Save As…", systemImage: "square.and.arrow.down", action: saveFile)
                Button(controller.isVisible ? "Hide Prompter" : "Show Prompter",
                       systemImage: controller.isVisible ? "eye.slash" : "eye") { controller.perform(.toggleVisible) }
                let running = controller.isPlaying || controller.countdownRemaining != nil
                Button(running ? "Pause" : "Play",
                       systemImage: running ? "pause.fill" : "play.fill") { controller.perform(.togglePlay) }
            }
        }
    }

    private var summary: String {
        let s = controller.script
        let minutes = s.estimatedDuration() / 60
        return "\(s.words.count) words · ~\(minutes < 1 ? "<1" : String(Int(minutes.rounded()))) min at 150 wpm · \(s.sections.count) cues"
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "md") ?? .plainText]
        if panel.runModal() == .OK, let url = panel.url { controller.open(url: url) }
    }

    private func saveFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "script.md"
        if panel.runModal() == .OK, let url = panel.url { controller.save(to: url) }
    }
}

private struct SettingsPane: View {
    @ObservedObject var controller: PrompterController
    @ObservedObject var settings: Settings
    @ObservedObject var remote: RemoteServer

    var body: some View {
        Form {
            Section("Scrolling") {
                Picker("Mode", selection: $settings.scrollMode) {
                    ForEach(ScrollMode.allCases) { Text($0.title).tag($0) }
                }
                Text(modeHelp).font(.caption).foregroundStyle(.secondary)

                if settings.scrollMode != .speech {
                    LabeledContent("Speed") {
                        Slider(value: $settings.speed, in: Settings.speedRange)
                        Text(String(format: "%.2f×", settings.speed)).monospacedDigit().frame(width: 44)
                    }
                }
                if settings.scrollMode.usesMic {
                    LabeledContent("Mic") { LevelMeter(level: controller.micLevel, speaking: controller.isSpeaking) }
                }
                if settings.scrollMode.usesMic {
                    LabeledContent("Sensitivity") { Slider(value: $settings.micSensitivity, in: 0...1) }
                }
                if settings.scrollMode == .speech {
                    Picker("Language", selection: $settings.speechLocale) {
                        ForEach(Self.locales, id: \.self) { id in
                            Text(Locale.current.localizedString(forIdentifier: id) ?? id).tag(id)
                        }
                    }
                }
                if !controller.micStatus.isEmpty && settings.scrollMode.usesMic {
                    Text(controller.micStatus).font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Pause while hovering", isOn: $settings.pauseOnHover)
                Picker("Countdown", selection: $settings.countdown) {
                    Text("Off").tag(0)
                    ForEach([3, 5, 10], id: \.self) { Text("\($0) seconds").tag($0) }
                }
            }

            Section("Display") {
                Picker("Position", selection: $settings.displayMode) {
                    ForEach(DisplayMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if settings.displayMode == .notch && NotchGeometry.notchScreen == nil {
                    Text("No notch found on this Mac — showing as a free window.").font(.caption).foregroundStyle(.orange)
                }
                LabeledContent("Text size") { Slider(value: $settings.fontSize, in: 14...56) }
                LabeledContent("Width") { Slider(value: $settings.width, in: 300...1000) }
                LabeledContent("Height") { Slider(value: $settings.height, in: 60...500) }
                ColorPicker("Text colour", selection: Binding(
                    get: { Color(nsColor: settings.textColor) },
                    set: { settings.textColor = NSColor($0) }), supportsOpacity: false)
                LabeledContent("Background") {
                    Slider(value: $settings.backgroundOpacity, in: 0...1)
                    Text(settings.backgroundOpacity < 0.01 ? "Clear" : "\(Int(settings.backgroundOpacity * 100))%")
                        .monospacedDigit().frame(width: 44)
                }
                Toggle("Mirror text (beam-splitter rigs)", isOn: $settings.mirror)
                Text("Drag the prompter anywhere, on any screen. Drop it back under the notch to re-attach it.")
                    .font(.caption).foregroundStyle(.secondary)
                if settings.displayMode == .floating {
                    Button("Reset free position") { settings.floatingOrigin = nil }
                }
            }

            if !controller.script.sections.isEmpty {
                Section("Cues") {
                    ForEach(Array(controller.script.sections.enumerated()), id: \.offset) { i, section in
                        Button { controller.show(); controller.jump(toSection: i) } label: {
                            HStack {
                                Image(systemName: controller.currentSection == i ? "arrowtriangle.right.fill" : "arrowtriangle.right")
                                    .foregroundStyle(controller.currentSection == i ? Color.yellow : Color.secondary)
                                Text(section.title)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Section("Phone remote") {
                Toggle("Enable on local network", isOn: $settings.remoteEnabled)
                if settings.remoteEnabled {
                    if let url = remote.url {
                        HStack(alignment: .top, spacing: 12) {
                            if let qr = Self.qrCode(for: url) {
                                Image(nsImage: qr).interpolation(.none).resizable().frame(width: 120, height: 120)
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Scan with your phone's camera (same Wi-Fi).").font(.caption)
                                Text(url).font(.caption.monospaced()).textSelection(.enabled).foregroundStyle(.secondary)
                                Button("Copy link") { copyToPasteboard(url) }
                            }
                        }
                    } else {
                        Text("Starting… (needs Wi-Fi and Local Network permission)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section("Shortcuts") {
                ForEach(HotKeys.bindings, id: \.display) { b in
                    LabeledContent(b.command.title) {
                        if HotKeys.unavailable.contains(b.command) {
                            Text("\(b.display) — used by another app").foregroundStyle(.orange)
                        } else {
                            Text(b.display).monospaced()
                        }
                    }
                }
                LabeledContent("Click prompter") { Text("play / pause") }
                LabeledContent("Scroll on prompter") { Text("move text") }
            }
        }
        .formStyle(.grouped)
        .onAppear { remote.refreshURL() } // the Mac may have changed networks since
    }

    private var modeHelp: String {
        switch settings.scrollMode {
        case .manual: "Scrolls at a steady speed."
        case .voice: "Scrolls at your speed setting only while you're talking; stops when you pause."
        case .speech: "Listens (on-device when your Mac supports the language) and keeps the line you're reading on the marker. Skips and ad-libs are fine."
        }
    }

    /// Thai, Lao, Khmer and Burmese don't separate words with spaces, which word tracking can't handle yet.
    private static let locales: [String] = SFSpeechRecognizer.supportedLocales().map(\.identifier)
        .filter { !["th", "lo", "km", "my"].contains(Locale(identifier: $0).language.languageCode?.identifier ?? "") }
        .sorted()

    private static func qrCode(for string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

private struct LevelMeter: View {
    let level: Float
    let speaking: Bool
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(speaking ? Color.green : Color.secondary)
                    .frame(width: geo.size.width * CGFloat(level))
                    .animation(.linear(duration: 0.08), value: level)
            }
        }
        .frame(height: 6)
    }
}

extension Command {
    var title: String {
        switch self {
        case .togglePlay: "Play / pause"
        case .toggleVisible: "Show / hide prompter"
        case .faster: "Faster"
        case .slower: "Slower"
        case .nextCue: "Next cue"
        case .previousCue: "Previous cue"
        case .restart: "Back to top"
        case .scrollUp: "Scroll back"
        case .scrollDown: "Scroll ahead"
        }
    }
}

func copyToPasteboard(_ string: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
}

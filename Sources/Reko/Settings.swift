import AppKit
import Combine

enum ScrollMode: String, CaseIterable, Identifiable {
    case manual, voice, speech
    var id: String { rawValue }
    var title: String {
        switch self {
        case .manual: "Constant"
        case .voice: "While talking"
        case .speech: "Follow my words"
        }
    }
    var usesMic: Bool { self != .manual }
}

enum DisplayMode: String, CaseIterable, Identifiable {
    case notch, floating
    var id: String { rawValue }
    var title: String { self == .notch ? "Notch" : "Free" }
}

/// Persisted user preferences. Every property writes through to UserDefaults.
@MainActor
final class Settings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var scrollMode: ScrollMode { didSet { store(scrollMode.rawValue, "scrollMode") } }
    @Published var displayMode: DisplayMode { didSet { store(displayMode.rawValue, "displayMode") } }
    /// Multiplier on the base scroll speed (manual / voice modes).
    @Published var speed: Double { didSet { store(speed, "speed") } }
    @Published var fontSize: Double { didSet { store(fontSize, "fontSize") } }
    @Published var width: Double { didSet { store(width, "width") } }
    /// Height of the text area (excludes the notch strip).
    @Published var height: Double { didSet { store(height, "height") } }
    @Published var mirror: Bool { didSet { store(mirror, "mirror") } }
    @Published var pauseOnHover: Bool { didSet { store(pauseOnHover, "pauseOnHover") } }
    /// 0...1 – higher means quieter speech counts as talking.
    @Published var micSensitivity: Double { didSet { store(micSensitivity, "micSensitivity") } }
    @Published var speechLocale: String { didSet { store(speechLocale, "speechLocale") } }
    @Published var remoteEnabled: Bool { didSet { store(remoteEnabled, "remoteEnabled") } }
    @Published var textColor: NSColor { didSet { store(textColor.hexString, "textColor") } }
    /// 0 = fully clear, 1 = solid black. Default is translucent; below 0.6 the text also gets a shadow.
    @Published var backgroundOpacity: Double { didSet { store(backgroundOpacity, "backgroundOpacity") } }
    /// Seconds to count down before scrolling starts (0 = off).
    @Published var countdown: Int { didSet { store(countdown, "countdown") } }
    /// Floating-mode window origin (screen coordinates); nil until the user moves it.
    @Published var floatingOrigin: CGPoint? {
        didSet { defaults.set(floatingOrigin.map { NSStringFromPoint($0) }, forKey: "floatingOrigin") }
    }

    let remoteToken: String

    static let speedRange = 0.25...4.0

    init() {
        let d = defaults
        scrollMode = ScrollMode(rawValue: d.string(forKey: "scrollMode") ?? "") ?? .manual
        displayMode = DisplayMode(rawValue: d.string(forKey: "displayMode") ?? "") ?? .notch
        speed = d.object(forKey: "speed") as? Double ?? 1.0
        fontSize = d.object(forKey: "fontSize") as? Double ?? 26
        width = d.object(forKey: "width") as? Double ?? 520
        height = d.object(forKey: "height") as? Double ?? 140
        mirror = d.bool(forKey: "mirror")
        pauseOnHover = d.object(forKey: "pauseOnHover") as? Bool ?? true
        micSensitivity = d.object(forKey: "micSensitivity") as? Double ?? 0.5
        speechLocale = d.string(forKey: "speechLocale") ?? Locale.current.identifier
        remoteEnabled = d.object(forKey: "remoteEnabled") as? Bool ?? false // plain HTTP on the LAN: opt-in
        floatingOrigin = d.string(forKey: "floatingOrigin").map { NSPointFromString($0) }
        textColor = d.string(forKey: "textColor").flatMap(NSColor.init(hexString:)) ?? .white
        backgroundOpacity = d.object(forKey: "backgroundOpacity") as? Double ?? 0.55 // see-through, but readable
        countdown = d.object(forKey: "countdown") as? Int ?? 3

        if let token = d.string(forKey: "remoteToken") {
            remoteToken = token
        } else {
            let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
            remoteToken = String((0..<10).map { _ in alphabet.randomElement()! })
            d.set(remoteToken, forKey: "remoteToken")
        }
    }

    private func store(_ value: Any, _ key: String) { defaults.set(value, forKey: key) }


    /// Everything that changes how the text wraps or looks. Other settings (speed, sensitivity…) skip the
    /// expensive re-layout.
    struct LayoutKey: Equatable {
        var fontSize, width, height: Double
        var mirror: Bool
        var displayMode: DisplayMode
    }

    /// Looks-only settings: applied by restyling, never by re-wrapping the text.
    struct AppearanceKey: Equatable {
        var textColor: String
        var backgroundOpacity: Double
    }

    var appearanceKey: AppearanceKey {
        AppearanceKey(textColor: textColor.hexString, backgroundOpacity: backgroundOpacity)
    }

    var layoutKey: LayoutKey {
        LayoutKey(fontSize: fontSize, width: width, height: height, mirror: mirror, displayMode: displayMode)
    }

    /// Base scroll speed in points/second, scaled with font size so the reading pace stays constant.
    var pointsPerSecond: Double { speed * fontSize * 0.55 }
}

extension NSColor {
    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "#FFFFFF" } // e.g. pattern colours have no RGB
        return String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }

    convenience init?(hexString: String) {
        let hex = hexString.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

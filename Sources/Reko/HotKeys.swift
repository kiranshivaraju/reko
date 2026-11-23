import Carbon.HIToolbox

/// System-wide shortcuts via Carbon's RegisterEventHotKey (works without Accessibility permission).
final class HotKeys {
    struct Binding {
        let keyCode: Int
        let display: String
        let command: Command
    }

    /// All shortcuts use ⌃⌥ so they don't collide with recording/meeting apps.
    static let bindings: [Binding] = [
        .init(keyCode: kVK_Space, display: "⌃⌥Space", command: .togglePlay),
        .init(keyCode: kVK_ANSI_P, display: "⌃⌥P", command: .toggleVisible),
        .init(keyCode: kVK_UpArrow, display: "⌃⌥↑", command: .faster),
        .init(keyCode: kVK_DownArrow, display: "⌃⌥↓", command: .slower),
        .init(keyCode: kVK_RightArrow, display: "⌃⌥→", command: .nextCue),
        .init(keyCode: kVK_LeftArrow, display: "⌃⌥←", command: .previousCue),
        .init(keyCode: kVK_ANSI_R, display: "⌃⌥R", command: .restart),
    ]

    /// Shortcuts another app already owns; shown as unavailable instead of silently doing nothing.
    private(set) static var unavailable: Set<Command> = []

    static func display(for command: Command) -> String? {
        guard !unavailable.contains(command) else { return nil }
        return bindings.first { $0.command == command }?.display
    }

    static let signature = OSType(0x52454B4F) // 'REKO'
    private static var handler: ((Command) -> Void)?
    private var refs: [EventHotKeyRef] = []

    init(handler: @escaping (Command) -> Void) {
        Self.handler = handler
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let index = Int(id.id)
            if status == noErr, id.signature == HotKeys.signature, HotKeys.bindings.indices.contains(index) {
                let command = HotKeys.bindings[index].command
                DispatchQueue.main.async { HotKeys.handler?(command) }
            }
            return noErr
        }, 1, &spec, nil, nil)

        let modifiers = UInt32(controlKey | optionKey)
        for (i, b) in Self.bindings.enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: UInt32(i))
            if RegisterEventHotKey(UInt32(b.keyCode), modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                refs.append(ref)
            } else {
                Self.unavailable.insert(b.command)
            }
        }
    }

    deinit { refs.forEach { UnregisterEventHotKey($0) } }
}

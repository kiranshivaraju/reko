import AppKit
import Combine
import RekoCore

/// Every user-triggerable action. Hotkeys, the menu bar, the editor and the phone remote all go through `perform`.
enum Command: String, CaseIterable {
    case togglePlay, toggleVisible, faster, slower, nextCue, previousCue, restart, scrollUp, scrollDown
}

/// The hub: owns the script, playback state, scroll position, mic and the notch panel.
@MainActor
final class PrompterController: ObservableObject {
    let settings: Settings

    @Published var scriptText: String { didSet { scriptTextChanged() } }
    @Published private(set) var script: Script
    @Published private(set) var isPlaying = false
    @Published private(set) var isVisible = false
    /// Seconds left in the pre-roll countdown, nil when not counting down.
    @Published private(set) var countdownRemaining: Int?
    @Published private(set) var currentSection: Int?
    @Published private(set) var progress: Double = 0
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var isSpeaking = false
    @Published private(set) var micStatus = ""

    var isHovering = false { didSet { if isHovering != oldValue { panel.refreshStatus() } } }

    /// Scroll position in points (0 = first line on the reading line). Not @Published: changes at 60 Hz.
    private(set) var offset: CGFloat = 0
    // Targets are character indices, not points: text re-wraps when size/width change, so points go stale.
    private var glideTarget: Int?   // cue jumps / restart: ease here, then resume normal scrolling
    private var tracker: ScriptTracker
    private var pacer = SpeechPacer() // follow-speech mode: smooth, latency-compensated reading position
    private var lastSpeechAt: TimeInterval = 0

    /// What the mic is currently set up for; a change (mode or language) restarts it.
    private struct MicConfig: Equatable {
        let mode: ScrollMode
        let locale: String
    }
    private var activeMic: MicConfig?
    private var lastScrollMode: ScrollMode
    private var lastLayout: Settings.LayoutKey
    private var lastAppearance: Settings.AppearanceKey
    private var lastOrigin: CGPoint?
    private var countdownTimer: Timer?
    private var micRetry: DispatchWorkItem?
    private var parseWork: DispatchWorkItem?
    private var saveWork: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()

    private lazy var panel = PrompterPanelController(controller: self)
    private let mic = MicListener()

    static let scriptURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Reko", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("script.md")
    }()

    init(settings: Settings) {
        self.settings = settings
        let text = (try? String(contentsOf: Self.scriptURL, encoding: .utf8)) ?? Self.sampleScript
        let parsed = Script(markdown: text)
        scriptText = text
        script = parsed
        tracker = ScriptTracker(words: parsed.words.map(\.normalized))
        lastScrollMode = settings.scrollMode
        lastLayout = settings.layoutKey
        lastAppearance = settings.appearanceKey
        lastOrigin = settings.floatingOrigin

        mic.onLevel = { [weak self] level in self?.micLevelChanged(level) }
        mic.onWords = { [weak self] words in self?.spokenWordsChanged(words) }
        mic.onStatus = { [weak self] status in self?.micStatus = status }
        mic.onFailure = { [weak self] in self?.micFailed() }

        // objectWillChange fires *before* the value changes, so apply on the next runloop turn.
        settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.settingsChanged() }
            .store(in: &cancellables)

        panel.setScript(script)
        updatePositionState()
    }

    // MARK: Commands

    func perform(_ command: Command) {
        switch command {
        case .togglePlay: isPlaying || countdownRemaining != nil ? pause() : play()
        case .toggleVisible: isVisible ? hide() : show()
        case .faster: settings.speed = min(settings.speed * 1.15, Settings.speedRange.upperBound)
        case .slower: settings.speed = max(settings.speed / 1.15, Settings.speedRange.lowerBound)
        case .nextCue: jumpToNextCue()
        case .previousCue: jumpToPreviousCue()
        case .restart: jump(toCharacter: 0, wordIndex: -1)
        case .scrollUp: nudge(by: -CGFloat(settings.fontSize) * 2.5)
        case .scrollDown: nudge(by: CGFloat(settings.fontSize) * 2.5)
        }
    }

    func show() {
        guard !isVisible else { return }
        isVisible = true
        panel.show()
    }

    func hide() {
        guard isVisible else { return }
        pause()
        isVisible = false
        isHovering = false // the mouse-exited event never arrives once the panel is gone
        panel.hide()
    }

    /// Starts playback, after the countdown if one is configured.
    func play() {
        show()
        if offset >= panel.maxOffset - 1 { jump(toCharacter: 0, wordIndex: -1) }
        guard settings.countdown > 0 else { return startPlaying() }
        cancelCountdown()
        countdownRemaining = settings.countdown
        panel.setCountdown(countdownRemaining)
        panel.refreshStatus()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.countdownTick() }
        }
    }

    private func countdownTick() {
        guard let remaining = countdownRemaining else { return }
        if remaining <= 1 {
            cancelCountdown()
            startPlaying()
        } else {
            countdownRemaining = remaining - 1
            panel.setCountdown(countdownRemaining)
        }
    }

    private func cancelCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdownRemaining = nil
        panel.setCountdown(nil)
        panel.refreshStatus()
    }

    private func startPlaying() {
        // Other modes scroll without telling the tracker; start following from what's on the reading line.
        if settings.scrollMode == .speech { reanchorSpeechTracking() }
        isPlaying = true
        syncMic()
        panel.refreshStatus()
    }

    func pause() {
        cancelCountdown()
        isPlaying = false
        isSpeaking = false
        syncMic()
        panel.refreshStatus()
    }

    func jump(toSection index: Int) {
        guard script.sections.indices.contains(index) else { return }
        let section = script.sections[index]
        jump(toCharacter: section.range.location, wordIndex: section.firstWordIndex - 1)
    }

    /// Manual scroll (trackpad / remote). In follow-speech mode, re-anchor the tracker where the user scrolled to.
    func nudge(by delta: CGFloat) {
        guard countdownRemaining == nil else { return } // the text is hidden during the countdown
        glideTarget = nil
        setOffset(offset + delta)
        reanchorSpeechTracking()
    }

    private func jump(toCharacter target: Int, wordIndex: Int) {
        glideTarget = target
        tracker.reset(to: wordIndex)
        pacer.reset(to: wordIndex) // keeps the learned speaking rate
        panel.highlightSpoken(through: nil)
    }

    /// Point speech tracking at whatever is on the reading line now.
    private func reanchorSpeechTracking() {
        let word = script.wordIndex(atOrAfterCharacter: readingCharacter) - 1
        tracker.reset(to: word)
        pacer.reset(to: word)
        panel.highlightSpoken(through: nil)
    }

    private var readingCharacter: Int { panel.characterIndex(atOffset: offset) }

    private func jumpToNextCue() {
        let ch = readingCharacter
        if let i = script.sections.firstIndex(where: { $0.range.location > ch }) { jump(toSection: i) }
    }

    private func jumpToPreviousCue() {
        let ch = readingCharacter
        if let i = script.sections.lastIndex(where: { $0.range.location < ch }) {
            jump(toSection: i)
        } else {
            jump(toCharacter: 0, wordIndex: -1)
        }
    }

    // MARK: Frame loop (driven by the panel's display link)

    func tick(dt: CFTimeInterval) {
        let dt = CGFloat(min(dt, 0.1))
        var next = offset

        if let character = glideTarget {
            let target = min(panel.offset(forCharacter: character), panel.maxOffset) // always reachable
            next += (target - next) * min(1, dt * 8)
            if abs(target - next) < 0.5 { next = target; glideTarget = nil }
        } else if isPlaying {
            let hoverPaused = settings.pauseOnHover && isHovering
            switch settings.scrollMode {
            case .manual where !hoverPaused, .voice where !hoverPaused && isSpeaking:
                next += CGFloat(settings.pointsPerSecond) * dt
            case .speech:
                let now = ProcessInfo.processInfo.systemUptime
                if let position = pacer.position(at: now, speaking: isSpeaking) {
                    let target = panel.offset(forCharacterPosition: characterPosition(forWordPosition: position))
                    next += (target - next) * min(1, dt * 6)
                }
            default: break
            }
        }

        setOffset(next)

        if isPlaying, settings.scrollMode != .speech, offset >= panel.maxOffset - 0.5 { pause() }
    }

    private func setOffset(_ value: CGFloat) {
        let clamped = min(max(0, value), panel.maxOffset)
        guard clamped != offset else { return }
        offset = clamped
        panel.setOffset(clamped)
        updatePositionState()
    }

    private func updatePositionState() {
        let section = script.sectionIndex(atCharacter: readingCharacter)
        if section != currentSection { currentSection = section }
        let p = panel.maxOffset > 0 ? (Double(offset / panel.maxOffset) * 100).rounded() / 100 : 0
        if p != progress { progress = p }
    }

    // MARK: Mic

    private func syncMic() {
        let wanted = isPlaying && settings.scrollMode.usesMic
            ? MicConfig(mode: settings.scrollMode, locale: settings.speechLocale) : nil
        guard wanted != activeMic else { return }
        activeMic = wanted
        micRetry?.cancel()
        mic.stop()
        micLevel = 0
        if let config = wanted {
            mic.start(recognizeSpeech: config.mode == .speech,
                      localeIdentifier: config.locale,
                      contextualStrings: Self.contextualStrings(for: script))
        }
        panel.refreshStatus()
    }

    /// Permission denied / no mic: keep retrying while the user still wants the mic, so granting access
    /// in System Settings or plugging in a mic starts listening without pausing and playing again.
    private func micFailed() {
        activeMic = nil
        let retry = DispatchWorkItem { [weak self] in self?.syncMic() }
        micRetry = retry
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: retry)
    }

    private func micLevelChanged(_ level: Float) {
        micLevel = level
        let threshold = Float(0.55 - 0.4 * settings.micSensitivity)
        let now = ProcessInfo.processInfo.systemUptime
        if level > threshold { lastSpeechAt = now }
        let speaking = now - lastSpeechAt < 0.6 // hang-over so pauses between words don't stutter
        if speaking != isSpeaking {
            isSpeaking = speaking
            panel.refreshStatus()
        } else {
            panel.refreshLevel()
        }
    }

    private func spokenWordsChanged(_ words: [String]) {
        guard settings.scrollMode == .speech, isPlaying, tracker.update(spoken: words) else { return }
        glideTarget = nil
        pacer.recognized(tracker.position, at: ProcessInfo.processInfo.systemUptime)
        panel.highlightSpoken(through: tracker.position)
    }

    /// Fractional word index -> fractional character offset (3.5 = halfway between the starts of words 3 and 4).
    private func characterPosition(forWordPosition position: Double) -> Double {
        let words = script.words
        guard !words.isEmpty else { return 0 }
        let i = min(max(0, Int(position)), words.count - 1)
        let start = Double(words[i].range.location)
        let end = Double(i + 1 < words.count ? words[i + 1].range.location : NSMaxRange(words[i].range))
        return start + (end - start) * min(max(0, position - Double(i)), 1)
    }

    /// Unusual words (names, jargon) help the recognizer; it accepts up to ~100 phrases.
    private static func contextualStrings(for script: Script) -> [String] {
        let ns = script.displayText as NSString
        var seen = Set<String>()
        return script.words.compactMap { w -> String? in
            let original = ns.substring(with: w.range)
            guard original.count >= 6 || original.first?.isUppercase == true, seen.insert(w.normalized).inserted else { return nil }
            return original
        }.prefix(100).map { $0 }
    }

    // MARK: Script & settings

    /// Typing in the editor: re-parse after a short pause rather than on every keystroke.
    private func scriptTextChanged() {
        parseWork?.cancel()
        let parse = DispatchWorkItem { [weak self] in self?.applyScriptText() }
        parseWork = parse
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: parse)

        saveWork?.cancel()
        let text = scriptText
        let save = DispatchWorkItem { try? text.write(to: Self.scriptURL, atomically: true, encoding: .utf8) }
        saveWork = save
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: save)
    }

    private func applyScriptText() {
        let old = script.displayText.utf16
        let new = Script(markdown: scriptText)
        // Keep the same text on the reading line: if the edit starts above it, shift by the length change.
        var anchor = readingCharacter
        let editStart = zip(old, new.displayText.utf16).prefix(while: { $0 == $1 }).count
        if editStart < anchor { anchor = max(editStart, anchor + new.displayText.utf16.count - old.count) }
        glideTarget = nil
        script = new
        tracker = ScriptTracker(words: script.words.map(\.normalized))
        panel.setScript(script)
        setOffset(panel.offset(forCharacter: anchor))
        updatePositionState()
        // Editing mid-take: resume tracking from the reading line, not from the top of the script.
        reanchorSpeechTracking()
        mic.updateContextualStrings(Self.contextualStrings(for: script))
    }

    private func settingsChanged() {
        if settings.layoutKey != lastLayout {
            lastLayout = settings.layoutKey
            lastOrigin = settings.floatingOrigin
            relayoutKeepingReadingLine()
        } else if settings.floatingOrigin != lastOrigin {
            lastOrigin = settings.floatingOrigin
            panel.applyPosition() // moving the window never needs a re-wrap
        } else {
            panel.refreshStatus()
        }
        if settings.appearanceKey != lastAppearance {
            lastAppearance = settings.appearanceKey
            panel.applyAppearance() // restyle only: dragging a colour/opacity control must not re-wrap the script
        }
        if settings.scrollMode != lastScrollMode {
            lastScrollMode = settings.scrollMode
            pacer = SpeechPacer()
            reanchorSpeechTracking()
        }
        syncMic()
    }

    /// Mid-drag out of the notch: switch to a free window right now (not on the next runloop turn), so the
    /// queued settings update finds nothing left to do and doesn't yank the window back.
    func detachFromNotch(origin: CGPoint) {
        settings.floatingOrigin = origin
        settings.displayMode = .floating
        settingsChanged()
    }

    /// Re-wraps the text (font size, width, display change…) keeping the same line on the reading marker.
    func relayoutKeepingReadingLine() {
        let anchor = readingCharacter
        panel.applyLayout()
        setOffset(panel.offset(forCharacter: anchor))
    }

    func open(url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        scriptText = text
        parseWork?.cancel()
        applyScriptText()
        jump(toCharacter: 0, wordIndex: -1)
    }

    /// Write any pending edit now (called on quit, so the last half-second of typing isn't lost).
    func flushPendingSave() {
        guard let work = saveWork, !work.isCancelled else { return }
        work.perform()
        work.cancel()
    }

    func save(to url: URL) {
        try? scriptText.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Snapshot for the phone remote.
    var remoteState: [String: Any] {
        [
            "playing": isPlaying,
            "countdown": countdownRemaining ?? 0,
            "visible": isVisible,
            "mode": settings.scrollMode.rawValue,
            "modeTitle": settings.scrollMode.title,
            "speed": (settings.speed * 100).rounded() / 100,
            "progress": progress,
            "section": currentSection ?? -1,
            "sections": script.sections.map(\.title),
        ]
    }

    static let sampleScript = """
    # Welcome
    Hi! This is Reko, your notch teleprompter. Your words sit right under the camera, so it looks like you are talking straight to your audience.
    [pause]

    # How it works
    Press Control Option Space to start and stop. Use Control Option up and down arrows to change speed.
    Pick "Follow my words" in settings and the script will move as you speak, and wait for you when you stop.

    # Cues
    Every line that starts with a hash sign becomes a cue. Jump between cues with Control Option left and right arrows, or tap them on your phone.

    # Wrap up
    Replace this text with your own script in the editor. Good luck with your recording!
    """
}

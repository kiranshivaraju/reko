import AppKit
import QuartzCore
import RekoCore

/// Where the notch is, if this Mac has one.
enum NotchGeometry {
    static var notchScreen: NSScreen? { NSScreen.screens.first { $0.safeAreaInsets.top > 0 } }

    /// Notch size in points, measured from the unobscured menu-bar areas either side of it.
    static func notchSize(on screen: NSScreen) -> CGSize? {
        guard screen.safeAreaInsets.top > 0,
              let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { return nil }
        return CGSize(width: screen.frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
    }
}

/// Borderless, non-activating, above the menu bar, on every Space (incl. full-screen apps), hidden from screen capture.
final class PrompterPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        // Set explicitly: left at its default, AppKit lets clicks on see-through pixels fall through to the
        // window behind, so a transparent prompter couldn't be clicked or dragged between lines of text.
        ignoresMouseEvents = false
        // Keep the script out of screen shares/recordings. REKO_CAPTURABLE=1 opts out (for demos/screenshots).
        sharingType = ProcessInfo.processInfo.environment["REKO_CAPTURABLE"] == "1" ? .readOnly : .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    // Borderless windows may sit over the menu bar / notch area.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Owns the panel and translates between script positions and scroll offsets.
@MainActor
final class PrompterPanelController {
    private unowned let controller: PrompterController
    private var settings: Settings { controller.settings }
    private let panel = PrompterPanel()
    private let view: PrompterView
    private var script: Script?
    private var displayLink: CADisplayLink?
    /// Floating mode without a saved position opens on the screen the pointer was on when shown.
    private var placementScreenID: CGDirectDisplayID?
    private var lastTimestamp: CFTimeInterval?
    private var spokenThrough: Int?

    init(controller: PrompterController) {
        self.controller = controller
        view = PrompterView()
        view.controller = controller
        view.onDrag = { [weak self] delta in self?.drag(by: delta) }
        view.onDragEnd = { [weak self] in self?.endDrag() }
        panel.contentView = view
        applyLayout()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            // Displays attached/removed: re-wrap, but keep the same line on the reading marker.
            MainActor.assumeIsolated { self?.controller.relayoutKeepingReadingLine() }
        }
    }

    // MARK: Geometry

    private var isNotchMode: Bool { settings.displayMode == .notch && NotchGeometry.notchScreen != nil }

    private var stripHeight: CGFloat {
        if isNotchMode, let screen = NotchGeometry.notchScreen, let size = NotchGeometry.notchSize(on: screen) {
            return size.height
        }
        return 24
    }

    private func targetFrame() -> NSRect {
        let width = CGFloat(settings.width)
        let height = stripHeight + CGFloat(settings.height)
        if isNotchMode, let screen = NotchGeometry.notchScreen {
            let notchWidth = NotchGeometry.notchSize(on: screen)?.width ?? 200
            let w = max(width, notchWidth + 80)
            return NSRect(x: screen.frame.midX - w / 2, y: screen.frame.maxY - height, width: w, height: height)
        }
        let size = CGSize(width: width, height: height)
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return NSRect(origin: panel.frame.origin, size: size) } // mid-reconfiguration
        // A saved position only counts if a good part of the panel is still on an attached screen.
        if let origin = settings.floatingOrigin,
           screens.contains(where: { $0.visibleFrame.intersects(NSRect(origin: origin, size: size).insetBy(dx: 40, dy: 20)) }) {
            return NSRect(origin: origin, size: size)
        }
        // Matched by display ID: NSScreen objects are recreated when displays are reconfigured.
        let screen = screens.first { $0.displayID == placementScreenID } ?? NSScreen.main ?? screens[0]
        return NSRect(x: screen.visibleFrame.midX - width / 2, y: screen.visibleFrame.maxY - height - 12,
                      width: width, height: height)
    }

    /// The collapsed frame the panel grows out of: the notch itself (or a sliver of the floating frame).
    private func collapsedFrame() -> NSRect {
        let full = targetFrame()
        if isNotchMode, let screen = NotchGeometry.notchScreen, let size = NotchGeometry.notchSize(on: screen) {
            return NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                          width: size.width, height: size.height)
        }
        return NSRect(x: full.minX, y: full.maxY - stripHeight, width: full.width, height: stripHeight)
    }

    // MARK: Dragging: pull it out of the notch, drop it anywhere, drop it back under the notch to re-attach

    private func drag(by delta: CGPoint) {
        if isNotchMode {
            // Detach, keeping the top-left corner where it is so the panel stays under the cursor.
            let floatingHeight = 24 + CGFloat(settings.height)
            controller.detachFromNotch(origin: CGPoint(x: panel.frame.minX, y: panel.frame.maxY - floatingHeight))
        }
        panel.setFrameOrigin(NSPoint(x: panel.frame.minX + delta.x, y: panel.frame.minY + delta.y))
    }

    private func endDrag() {
        if let screen = NotchGeometry.notchScreen, Self.isNearNotch(panel.frame, on: screen) {
            settings.displayMode = .notch
        } else {
            settings.floatingOrigin = panel.frame.origin
        }
    }

    /// Dropped with its top edge near the top of the notched screen, roughly centred: snap back in.
    static func isNearNotch(_ frame: NSRect, on screen: NSScreen) -> Bool {
        screen.frame.maxY - frame.maxY < 60 && abs(frame.midX - screen.frame.midX) < 150
    }

    /// Moves the window to the saved position without re-wrapping the text.
    func applyPosition() {
        if panel.isVisible { panel.setFrame(targetFrame(), display: true) }
    }

    /// Re-wraps the text (expensive): only for changes that affect layout (size, font, colour, position, mirror).
    func applyLayout() {
        view.configure(notchMode: isNotchMode, stripHeight: stripHeight, settings: settings, fullSize: targetFrame().size,
                       notchWidth: NotchGeometry.notchScreen.flatMap { NotchGeometry.notchSize(on: $0)?.width } ?? 0)
        if let script { view.setScript(script, fontSize: CGFloat(settings.fontSize)) }
        if panel.isVisible { panel.setFrame(targetFrame(), display: true) }
        view.highlightSpoken(through: spokenThrough, in: script)
        refreshStatus()
    }

    // MARK: Show / hide

    func show() {
        let mouse = NSEvent.mouseLocation
        placementScreenID = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }?.displayID
        if !isNotchMode { applyLayout() } // the placement screen may differ in size
        panel.setFrame(collapsedFrame(), display: false)
        panel.orderFrontRegardless()
        view.layoutSubtreeIfNeeded()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(targetFrame(), display: true)
        }
        startDisplayLink()
    }

    func hide() {
        stopDisplayLink()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(collapsedFrame(), display: true)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.controller.isVisible else { return }
                self.panel.orderOut(nil)
            }
        })
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        lastTimestamp = nil
        let link = view.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        let dt = lastTimestamp.map { link.timestamp - $0 } ?? 0
        lastTimestamp = link.timestamp
        controller.tick(dt: dt)
    }

    // MARK: Script <-> offset

    func setScript(_ script: Script) {
        self.script = script
        spokenThrough = nil
        view.setScript(script, fontSize: CGFloat(settings.fontSize))
    }

    func setOffset(_ offset: CGFloat) { view.scroll(to: offset) }
    var maxOffset: CGFloat { view.maxOffset }
    func offset(forCharacter index: Int) -> CGFloat { view.offset(forCharacter: index) }
    func offset(forCharacterPosition position: Double) -> CGFloat { view.offset(forCharacterPosition: position) }
    func characterIndex(atOffset offset: CGFloat) -> Int { view.characterIndex(atOffset: offset) }

    func highlightSpoken(through wordIndex: Int?) {
        guard wordIndex != spokenThrough else { return }
        spokenThrough = wordIndex
        view.highlightSpoken(through: wordIndex, in: script)
    }

    func refreshStatus() {
        let c = controller
        let symbol: String
        if c.countdownRemaining != nil {
            symbol = "timer"
        } else if !c.isPlaying {
            symbol = "pause.fill"
        } else if c.settings.scrollMode == .manual {
            symbol = c.isHovering && c.settings.pauseOnHover ? "hand.raised.fill" : "play.fill"
        } else {
            symbol = c.isSpeaking ? "waveform" : "mic.fill"
        }
        let label = c.settings.scrollMode == .speech ? "follow" : String(format: "%.2g×", c.settings.speed)
        view.setStatus(symbol: symbol, active: c.isPlaying || c.countdownRemaining != nil, label: label)
        refreshLevel()
    }

    /// Cheap path for the ~30 Hz mic level updates.
    func refreshLevel() {
        let c = controller
        view.setLevel(c.micLevel, speaking: c.isSpeaking, visible: c.isPlaying && c.settings.scrollMode.usesMic)
    }

    func setCountdown(_ value: Int?) { view.setCountdown(value) }

    func applyAppearance() {
        view.applyAppearance(textColor: settings.textColor, backgroundOpacity: CGFloat(settings.backgroundOpacity))
    }
}

/// The notch-extension: status strip on top, fading script text below, reading-line marker.
/// Background is transparent-to-black (user setting); text gets a shadow when the background is see-through.
final class PrompterView: NSView {
    weak var controller: PrompterController?

    private let textContainer = NSView()     // mirrored + fade-masked
    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private let fadeMask = CAGradientLayer()
    private let marker = CAShapeLayer()
    private let statusIcon = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let beam = CALayer()             // voice-reactive glow along the bottom edge
    private let countdownLabel = NSTextField(labelWithString: "")

    /// The expanded panel size. Text is laid out for this, not the live bounds, so the show/hide
    /// animation reveals the text instead of re-wrapping it (which would invalidate scroll offsets).
    private var fullSize = CGSize(width: 520, height: 170)
    private var notchMode = true
    private var stripHeight: CGFloat = 32
    private var notchWidth: CGFloat = 0
    private var mirror = false
    private var fontSize: CGFloat = 26
    private var dragStart: NSPoint?
    private var dragged = false
    /// Drag deltas (screen points) and drag end; the panel controller decides how the window moves.
    var onDrag: ((CGPoint) -> Void)?
    var onDragEnd: (() -> Void)?

    private let horizontalPadding: CGFloat = 22
    private var bodyColor = NSColor.white
    private var spokenColor: NSColor { bodyColor.withAlphaComponent(0.35) }
    private let cueColor = NSColor.systemYellow
    private let directionColor = NSColor.systemTeal

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true

        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = false
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.documentView = textView

        textContainer.wantsLayer = true
        textContainer.addSubview(scrollView)
        textContainer.layer?.mask = fadeMask
        fadeMask.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        fadeMask.locations = [0, 0.14, 0.86, 1]
        addSubview(textContainer)

        marker.fillColor = NSColor.systemYellow.withAlphaComponent(0.85).cgColor
        layer?.addSublayer(marker)

        statusIcon.contentTintColor = .white
        statusIcon.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        statusLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        statusLabel.textColor = NSColor.white.withAlphaComponent(0.6)
        addSubview(statusIcon)
        addSubview(statusLabel)

        beam.cornerRadius = 1.5
        beam.shadowOpacity = 1
        beam.shadowRadius = 6
        beam.shadowOffset = .zero
        beam.opacity = 0
        layer?.addSublayer(beam)

        countdownLabel.font = .monospacedDigitSystemFont(ofSize: 64, weight: .bold)
        countdownLabel.textColor = .white
        countdownLabel.alignment = .center
        countdownLabel.isHidden = true
        addSubview(countdownLabel)

        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func configure(notchMode: Bool, stripHeight: CGFloat, settings: Settings, fullSize: CGSize, notchWidth: CGFloat) {
        self.fullSize = fullSize
        self.notchMode = notchMode
        self.stripHeight = stripHeight
        self.notchWidth = notchWidth
        self.mirror = settings.mirror
        applyAppearance(textColor: settings.textColor, backgroundOpacity: CGFloat(settings.backgroundOpacity))
        layer?.cornerRadius = notchMode ? 18 : 14
        // Flipped view => min-Y corners are the top ones. Notch mode rounds only the bottom.
        layer?.maskedCorners = notchMode
            ? [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            : [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        needsLayout = true
    }

    /// Text area height; the reading line sits 30% of the way down it.
    private var textAreaHeight: CGFloat { max(0, fullSize.height - stripHeight - 6) }
    private var readingLineY: CGFloat { (textAreaHeight * 0.3).rounded() }

    override func layout() {
        super.layout()
        // Status sits in the strip; in notch mode, to the left/right of the camera housing.
        let stripCenterY = stripHeight / 2
        let leftEdge = notchMode ? max(14, (bounds.width - notchWidth) / 2 - 64) : 12
        statusIcon.frame = NSRect(x: leftEdge, y: stripCenterY - 7, width: 14, height: 14)
        statusLabel.sizeToFit()
        let rightEdge = notchMode ? min(bounds.width - 14, (bounds.width + notchWidth) / 2 + 64) : bounds.width - 12
        statusLabel.frame.origin = NSPoint(x: rightEdge - statusLabel.frame.width, y: stripCenterY - statusLabel.frame.height / 2)

        let wasOffset = scrollView.contentView.bounds.origin.y
        textContainer.frame = NSRect(x: ((bounds.width - fullSize.width) / 2).rounded(), y: stripHeight,
                                     width: fullSize.width, height: textAreaHeight)
        scrollView.frame = textContainer.bounds.insetBy(dx: horizontalPadding, dy: 0)
        fadeMask.frame = textContainer.bounds
        resizeTextView()
        scroll(to: wasOffset)

        if let containerLayer = textContainer.layer {
            let w = containerLayer.bounds.width
            let pivot = w * (0.5 - containerLayer.anchorPoint.x) // mirror around the visual centre, whatever the anchor
            containerLayer.sublayerTransform = mirror
                ? CATransform3DScale(CATransform3DMakeTranslation(2 * pivot, 0, 0), -1, 1, 1)
                : CATransform3DIdentity
        }

        // Small triangle pointing at the reading line.
        let y = stripHeight + readingLineY + fontSize * 0.62
        let path = CGMutablePath()
        let x: CGFloat = textContainer.frame.minX + (mirror ? fullSize.width - 8 : 8)
        let dir: CGFloat = mirror ? -1 : 1
        path.move(to: CGPoint(x: x, y: y - 5))
        path.addLine(to: CGPoint(x: x + 7 * dir, y: y))
        path.addLine(to: CGPoint(x: x, y: y + 5))
        path.closeSubpath()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        marker.path = path
        CATransaction.commit()

        let countdownSize = min(64, textAreaHeight * 0.6)
        countdownLabel.font = .monospacedDigitSystemFont(ofSize: countdownSize, weight: .bold)
        let labelHeight = countdownSize * 1.25
        countdownLabel.frame = NSRect(x: 0, y: (stripHeight + (bounds.height - stripHeight - labelHeight) / 2).rounded(),
                                      width: bounds.width, height: labelHeight)
        layoutBeam()
    }

    // MARK: Voice beam & countdown

    private var beamLevel: CGFloat = 0

    /// A glow along the bottom edge whose width follows mic loudness (green while you're talking).
    func setLevel(_ level: Float, speaking: Bool, visible: Bool) {
        beamLevel = visible ? CGFloat(level) : 0
        let color = (speaking ? NSColor.systemGreen : NSColor.white.withAlphaComponent(0.5)).cgColor
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.08)
        beam.backgroundColor = color
        beam.shadowColor = color
        beam.opacity = visible ? 1 : 0
        layoutBeam()
        CATransaction.commit()
    }

    private func layoutBeam() {
        let w = max(6, (bounds.width - 60) * beamLevel)
        beam.frame = CGRect(x: (bounds.width - w) / 2, y: bounds.height - 5, width: w, height: 3)
    }

    // MARK: Appearance (no re-layout)

    private var backgroundOpacity: CGFloat = 0
    private var script: Script?
    /// Below this the desktop shows through enough that text needs a shadow to stay readable.
    private var needsLegibilityShadow: Bool { backgroundOpacity < 0.6 }
    private static let legibilityShadow: NSShadow = {
        let s = NSShadow()
        s.shadowColor = NSColor.black.withAlphaComponent(0.95)
        s.shadowBlurRadius = 4
        s.shadowOffset = .zero
        return s
    }()

    func applyAppearance(textColor: NSColor, backgroundOpacity: CGFloat) {
        bodyColor = textColor
        self.backgroundOpacity = backgroundOpacity
        layer?.backgroundColor = NSColor.black.withAlphaComponent(backgroundOpacity).cgColor
        let shadow = needsLegibilityShadow ? Self.legibilityShadow : nil
        [statusIcon, statusLabel, countdownLabel].forEach { $0.shadow = shadow }
        marker.shadowOpacity = needsLegibilityShadow ? 1 : 0
        marker.shadowRadius = 3
        marker.shadowOffset = .zero
        applyTextStyle()
    }

    /// Colours (body / cues / directions) and the legibility shadow, applied to the laid-out text.
    private func applyTextStyle() {
        guard let script, let storage = textView.textStorage, storage.length > 0 else { return }
        let all = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: bodyColor, range: all)
        for section in script.sections { storage.addAttribute(.foregroundColor, value: cueColor, range: section.range) }
        for range in script.directionRanges { storage.addAttribute(.foregroundColor, value: directionColor, range: range) }
        if needsLegibilityShadow {
            storage.addAttribute(.shadow, value: Self.legibilityShadow, range: all)
        } else {
            storage.removeAttribute(.shadow, range: all)
        }
        storage.endEditing()
    }

    func setCountdown(_ value: Int?) {
        countdownLabel.isHidden = value == nil
        textContainer.isHidden = value != nil
        marker.isHidden = value != nil
        countdownLabel.stringValue = value.map(String.init) ?? ""
    }

    func setScript(_ script: Script, fontSize: CGFloat) {
        self.fontSize = fontSize
        let para = NSMutableParagraphStyle()
        para.lineHeightMultiple = 1.12
        para.paragraphSpacing = fontSize * 0.25

        let text = NSMutableAttributedString(string: script.displayText, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
            .paragraphStyle: para,
        ])
        let cuePara = para.mutableCopy() as! NSMutableParagraphStyle
        cuePara.paragraphSpacingBefore = fontSize * 0.4
        for section in script.sections {
            text.addAttributes([
                .font: NSFont.systemFont(ofSize: fontSize * 0.55, weight: .bold),
                .paragraphStyle: cuePara,
                .kern: 1.2,
            ], range: section.range)
        }
        for range in script.directionRanges {
            text.addAttributes([
                .font: NSFont.systemFont(ofSize: fontSize * 0.7, weight: .semibold).italic(),
            ], range: range)
        }
        textView.textStorage?.setAttributedString(text)
        self.script = script
        applyTextStyle()
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    /// Height = top inset (reading line) + text + a full screen of runway so the last line can reach the reading line.
    private func resizeTextView() {
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return }
        textView.textContainerInset = NSSize(width: 0, height: readingLineY)
        textView.frame.size.width = scrollView.bounds.width
        tc.size = NSSize(width: scrollView.bounds.width, height: .greatestFiniteMagnitude)
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc).height
        textView.frame.size.height = readingLineY + used + scrollView.bounds.height
    }

    /// Scroll offset that puts the line containing `index` on the reading line.
    func offset(forCharacter index: Int) -> CGFloat {
        guard let lm = textView.layoutManager, let tc = textView.textContainer, lm.numberOfGlyphs > 0 else { return 0 }
        lm.ensureLayout(for: tc)
        let length = textView.textStorage?.length ?? 0
        let glyph = lm.glyphIndexForCharacter(at: min(max(0, index), max(0, length - 1)))
        return lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
    }

    /// Continuous version for follow-speech: the line glides through the reading line as it's read,
    /// with its middle on the marker halfway through the line (instead of jumping line by line).
    func offset(forCharacterPosition position: Double) -> CGFloat {
        guard let lm = textView.layoutManager, let tc = textView.textContainer, lm.numberOfGlyphs > 0 else { return 0 }
        lm.ensureLayout(for: tc)
        let length = textView.textStorage?.length ?? 0
        let glyph = lm.glyphIndexForCharacter(at: min(max(0, Int(position)), max(0, length - 1)))
        var glyphRange = NSRange()
        let line = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &glyphRange)
        let chars = lm.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let fraction = (position - Double(chars.location)) / Double(max(1, chars.length))
        return line.minY + line.height * CGFloat(min(max(fraction, 0), 1) - 0.5)
    }

    func characterIndex(atOffset offset: CGFloat) -> Int {
        guard let lm = textView.layoutManager, let tc = textView.textContainer, lm.numberOfGlyphs > 0 else { return 0 }
        let glyph = lm.glyphIndex(for: NSPoint(x: 1, y: offset + 1), in: tc)
        return lm.characterIndexForGlyph(at: glyph)
    }

    var maxOffset: CGFloat {
        offset(forCharacter: max(0, (textView.textStorage?.length ?? 1) - 1))
    }

    func scroll(to offset: CGFloat) {
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Follow-speech mode: dim what has been said, so the eye lands on the next word.
    func highlightSpoken(through wordIndex: Int?, in script: Script?) {
        guard let lm = textView.layoutManager, let length = textView.textStorage?.length, length > 0 else { return }
        let full = NSRange(location: 0, length: length)
        lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
        guard let script, let wordIndex, script.words.indices.contains(wordIndex) else { return }
        let end = NSMaxRange(script.words[wordIndex].range)
        lm.addTemporaryAttribute(.foregroundColor, value: spokenColor, forCharacterRange: NSRange(location: 0, length: end))
    }

    func setStatus(symbol: String, active: Bool, label: String) {
        statusIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        statusIcon.contentTintColor = active ? .systemGreen : NSColor.white.withAlphaComponent(0.6)
        statusLabel.stringValue = label
        needsLayout = true
    }

    // MARK: Mouse: hover pauses, click toggles play, drag moves (floating mode)

    /// The whole panel is one control: clicks, drags and scrolls must reach this view, not the text view
    /// inside it (which would swallow them). This also keeps the controller the only thing that scrolls.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func scrollWheel(with event: NSEvent) {
        guard countdownLabel.isHidden else { return }
        let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 12
        controller?.nudge(by: -dy)
    }

    override func mouseEntered(with event: NSEvent) { controller?.isHovering = true }
    override func mouseExited(with event: NSEvent) { controller?.isHovering = false }

    override func mouseDown(with event: NSEvent) {
        dragStart = NSEvent.mouseLocation
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let now = NSEvent.mouseLocation
        let delta = CGPoint(x: now.x - start.x, y: now.y - start.y)
        if !dragged && hypot(delta.x, delta.y) < 3 { return }
        dragged = true
        dragStart = now
        onDrag?(delta)
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil }
        if dragged {
            onDragEnd?()
        } else {
            controller?.perform(.togglePlay)
        }
    }
}

private extension NSFont {
    func italic() -> NSFont {
        NSFont(descriptor: fontDescriptor.withSymbolicTraits(.italic), size: pointSize) ?? self
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

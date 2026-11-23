import Foundation

/// Turns sparse, delayed "the speaker just said word N" events into a smooth, current reading position.
///
/// Speech recognition reports a word ~0.4 s after it was spoken, and only in bursts. Scrolling straight to
/// the last recognized word therefore always lags. The pacer learns the speaker's words-per-second and
/// extrapolates past the last recognized word, but only while they're audibly talking and never more than
/// `maxLead` words ahead, so it stops when they stop.
///
/// Positions are fractional word indices: 3.0 = start of word 3, 3.5 = halfway through it.
public struct SpeechPacer: Sendable {
    /// Typical recognizer delay (measured ~0.42 s median for on-device en-US).
    public var latency: Double = 0.45
    /// Never run further than this many words past the last recognized word.
    public var maxLead: Double = 2 // tuned on real recognizer output: ~0.2 s median lag, <2 words overshoot
    public private(set) var wordsPerSecond: Double = 2.5

    private var anchor: Int?
    private var anchorTime: Double = 0
    private var shown: Double = 0

    public init() {}

    /// Discontinuity (cue jump, manual scroll, restart): `index` is the last word considered read.
    public mutating func reset(to index: Int) {
        anchor = nil
        shown = Double(index + 1)
    }

    /// The tracker matched word `index` at `time` (seconds, monotonic).
    public mutating func recognized(_ index: Int, at time: Double) {
        if let a = anchor, index > a {
            let dt = time - anchorTime
            if dt > 0.15, dt < 3, index - a <= 8 {
                let instant = min(max(Double(index - a) / dt, 1), 6)
                wordsPerSecond += (instant - wordsPerSecond) * 0.3
            }
        }
        // First word after a reset, or the speaker went back: allow moving up (forward is handled by max()).
        if anchor.map({ index < $0 }) ?? true { shown = Double(index + 1) }
        anchor = index
        anchorTime = time
    }

    /// Where the speaker probably is now, or nil before anything was recognized.
    /// Never moves backwards on its own (only `recognized` going back or `reset` can do that).
    public mutating func position(at time: Double, speaking: Bool) -> Double? {
        guard let a = anchor else { return shown > 0 ? shown : nil } // after a reset, hold there
        let base = Double(a + 1) // the recognized word has been fully said
        let lead = speaking ? min(wordsPerSecond * (latency + max(0, time - anchorTime)), maxLead) : 0
        shown = max(shown, base + lead)
        return shown
    }
}

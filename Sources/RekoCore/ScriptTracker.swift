import Foundation

/// Follows a speaker through a script by aligning the most recent recognized words
/// against a window of script words around the current position.
///
/// Designed for streaming partial results: feeding the same transcript tail repeatedly
/// is idempotent, recognition errors and ad-libs are tolerated, skipping ahead is
/// allowed with enough evidence, and moving backwards needs stronger evidence still.
public struct ScriptTracker: Sendable {
    public let words: [String]
    /// Index of the last script word the speaker has said (-1 = not started).
    public private(set) var position: Int = -1

    public var lookBehind = 30
    public var lookAhead = 60
    /// How many trailing spoken words are used as context.
    public var contextSize = 6

    public init(words: [String]) {
        self.words = words
    }

    public mutating func reset(to index: Int) {
        position = min(max(index, -1), words.count - 1)
    }

    /// Feed the latest recognized words (normalized, oldest first).
    /// Returns true if `position` moved.
    @discardableResult
    public mutating func update(spoken: [String]) -> Bool {
        let tail = Array(spoken.suffix(contextSize))
        guard let last = tail.last, !words.isEmpty else { return false }

        let lo = max(0, position - lookBehind)
        let hi = min(words.count - 1, position + lookAhead)
        guard lo <= hi else { return false }

        var best: (index: Int, score: Double, adjusted: Double)?
        for j in lo...hi where Self.matches(words[j], last) {
            let s = score(tail, endingAt: j)
            let distance = j - (position + 1) // 0 == the natural next word, -1 == staying put
            // Staying on the current word is free, so a repeated partial result (or a doubled word
            // like "really really") doesn't push us forward; only real backward moves pay extra.
            let penalty = j == position ? 0 : Double(abs(distance)) * 0.03 + (j < position ? 0.5 : 0)
            let adjusted = s - penalty
            if best.map({ adjusted > $0.adjusted }) ?? true { best = (j, s, adjusted) }
        }

        guard let b = best, b.index != position else { return false }
        let distance = b.index - (position + 1)
        let required: Double = distance < 0 ? 2.5 : (distance <= 3 ? 1.0 : 2.0)
        guard b.score >= required else { return false }
        position = b.index
        return true
    }

    /// Weighted count of spoken words that line up with the script ending at `end`.
    private func score(_ tail: [String], endingAt end: Int) -> Double {
        var total = Self.weight(words[end])
        var k = end - 1
        var misses = 0
        for spoken in tail.dropLast().reversed() {
            guard k >= 0, k >= end - 2 * contextSize else { break }
            // Allow one skipped/misrecognized script word between matches.
            if let skip = (0...1).first(where: { k - $0 >= 0 && Self.matches(words[k - $0], spoken) }) {
                total += Self.weight(words[k - skip]) - Double(skip) * 0.25 // a skipped script word is weaker evidence
                k -= skip + 1
                misses = 0
            } else {
                // Treat as an ad-lib ("uh"), but it weakens the evidence;
                // two in a row means the context no longer lines up here.
                total -= 0.5
                misses += 1
                if misses == 2 { break }
            }
        }
        return total
    }

    /// Short words ("a", "the", "to") are weak evidence on their own.
    static func weight(_ w: String) -> Double { w.count >= 4 ? 1.0 : 0.5 }

    /// Tolerant equality for recognizer quirks: small typos and truncated partial words.
    public static func matches(_ script: String, _ spoken: String) -> Bool {
        if script == spoken { return true }
        let shorter = min(script.count, spoken.count)
        guard shorter >= 4 else { return false }
        if script.hasPrefix(spoken) { return true } // partial result cut mid-word
        let allowed = shorter >= 8 ? 2 : 1
        return levenshtein(script, spoken, limit: allowed) <= allowed
    }

    /// Edit distance, short-circuiting once it is known to exceed `limit`.
    static func levenshtein(_ a: String, _ b: String, limit: Int) -> Int {
        let a = Array(a), b = Array(b)
        if abs(a.count - b.count) > limit { return limit + 1 }
        if a.isEmpty || b.isEmpty { return max(a.count, b.count) }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            var rowMin = cur[0]
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                rowMin = min(rowMin, cur[j])
            }
            if rowMin > limit { return limit + 1 }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
}

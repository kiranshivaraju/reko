import Foundation

/// A spoken word in the script, located in `Script.displayText` (UTF-16 offsets).
public struct ScriptWord: Equatable, Sendable {
    public let normalized: String
    public let range: NSRange
}

/// A cue: a `# Heading` line that splits the script into jumpable sections.
public struct ScriptSection: Equatable, Sendable {
    public let title: String
    /// Range of the heading line in `displayText`.
    public let range: NSRange
    /// Index into `words` of the first spoken word after the heading (== words.count if none).
    public let firstWordIndex: Int
}

/// A parsed teleprompter script.
///
/// Markdown-ish input:
/// - `# Title` lines (any number of `#`) become cues; shown on screen, never "spoken".
/// - `[stage directions]` are shown but excluded from speech tracking.
/// - Everything else is spoken text.
public struct Script: Sendable {
    public let source: String
    public let displayText: String
    public let words: [ScriptWord]
    public let sections: [ScriptSection]
    public let directionRanges: [NSRange]

    public init(markdown: String) {
        source = markdown
        var display = ""
        var headings: [(title: String, range: NSRange)] = []

        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            let start = (display as NSString).length
            if let title = Script.headingTitle(line) {
                display += title
                headings.append((title, NSRange(location: start, length: (title as NSString).length)))
            } else {
                display += line
            }
            if i < lines.count - 1 { display += "\n" }
        }
        displayText = display

        let ns = display as NSString
        let full = NSRange(location: 0, length: ns.length)
        directionRanges = Script.directionRegex.matches(in: display, range: full).map(\.range)

        let excluded = headings.map(\.range) + directionRanges
        words = TextNormalizer.tokenRanges(in: display).compactMap { range in
            guard !excluded.contains(where: { NSIntersectionRange($0, range).length > 0 }) else { return nil }
            let norm = TextNormalizer.normalize(ns.substring(with: range))
            return norm.isEmpty ? nil : ScriptWord(normalized: norm, range: range)
        }

        let words = self.words
        sections = headings.map { h in
            let first = words.firstIndex { $0.range.location >= NSMaxRange(h.range) } ?? words.count
            return ScriptSection(title: h.title, range: h.range, firstWordIndex: first)
        }
    }

    /// Index of the spoken word at or after a character offset (clamped to the last word).
    public func wordIndex(atOrAfterCharacter location: Int) -> Int {
        guard !words.isEmpty else { return 0 }
        var lo = 0, hi = words.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if NSMaxRange(words[mid].range) <= location { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Index of the section containing a character offset, or nil if before the first cue.
    public func sectionIndex(atCharacter location: Int) -> Int? {
        sections.lastIndex { $0.range.location <= location }
    }

    /// Rough reading time at a given words-per-minute pace.
    public func estimatedDuration(wordsPerMinute: Double = 150) -> TimeInterval {
        Double(words.count) / wordsPerMinute * 60
    }

    static func headingTitle(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else { return nil }
        let title = trimmed.drop { $0 == "#" }
        guard title.first == " " else { return nil }
        let t = title.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    private static let directionRegex = try! NSRegularExpression(pattern: "\\[[^\\]\\n]*\\]")
}

public enum TextNormalizer {
    /// Lowercased, diacritic-folded, letters and digits only ("Don't" -> "dont", "Café" -> "cafe").
    public static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return String(String.UnicodeScalarView(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }

    /// Splits recognized speech into normalized words, exactly like script text is split.
    public static func words(in s: String) -> [String] {
        let ns = s as NSString
        return tokenRanges(in: s).map { normalize(ns.substring(with: $0)) }.filter { !$0.isEmpty }
    }

    /// The one tokenizer for both script and speech: runs of letters/digits (with inner apostrophes),
    /// except Chinese/Japanese characters, which become one token each since those languages don't use spaces.
    public static func tokenRanges(in s: String) -> [NSRange] {
        tokenRegex.matches(in: s, range: NSRange(location: 0, length: (s as NSString).length)).map(\.range)
    }

    private static let cjk = "\\p{Han}\\p{Hiragana}\\p{Katakana}"
    private static let tokenRegex = try! NSRegularExpression(
        pattern: "[\(cjk)]|[[\\p{L}\\p{N}]--[\(cjk)]]+(?:['’][[\\p{L}\\p{N}]--[\(cjk)]]+)*")
}

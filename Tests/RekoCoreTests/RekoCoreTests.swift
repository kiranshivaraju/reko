import XCTest
@testable import RekoCore

final class ScriptTests: XCTestCase {
    func testParsesCuesDirectionsAndWords() {
        let s = Script(markdown: """
        # Intro
        Hello there, I'm Kay. [smile]
        ## Main point
        Teleprompters are great.
        """)
        XCTAssertEqual(s.sections.map(\.title), ["Intro", "Main point"])
        XCTAssertEqual(s.words.map(\.normalized), ["hello", "there", "im", "kay", "teleprompters", "are", "great"])
        XCTAssertEqual(s.sections[0].firstWordIndex, 0)
        XCTAssertEqual(s.sections[1].firstWordIndex, 4)
        XCTAssertEqual(s.directionRanges.count, 1)
        // Headings are shown without their # markers.
        XCTAssertTrue(s.displayText.hasPrefix("Intro\nHello"))
    }

    func testHashWithoutSpaceIsNotACue() {
        let s = Script(markdown: "#hashtag is text")
        XCTAssertTrue(s.sections.isEmpty)
        XCTAssertEqual(s.words.first?.normalized, "hashtag")
    }

    func testWordIndexLookup() {
        let s = Script(markdown: "one two three")
        XCTAssertEqual(s.wordIndex(atOrAfterCharacter: 0), 0)
        XCTAssertEqual(s.wordIndex(atOrAfterCharacter: 4), 1)
        XCTAssertEqual(s.wordIndex(atOrAfterCharacter: 3), 1) // the space before "two"
        XCTAssertEqual(s.wordIndex(atOrAfterCharacter: 999), 2)
    }

    func testNormalizer() {
        XCTAssertEqual(TextNormalizer.normalize("Don't"), "dont")
        XCTAssertEqual(TextNormalizer.normalize("Café!"), "cafe")
        XCTAssertEqual(TextNormalizer.words(in: "well-known  Café, 2024"), ["well", "known", "cafe", "2024"])
    }
}

final class ScriptTrackerTests: XCTestCase {
    let text = """
    Today I want to show you how our new product saves teams hours every week.
    First we will look at the dashboard. Then we will look at the reports.
    Finally I will answer the most common questions from customers.
    """
    lazy var tracker = ScriptTracker(words: Script(markdown: text).words.map(\.normalized))

    /// Simulates streaming partial results: the transcript grows one word at a time.
    func speak(_ phrase: String, into t: inout ScriptTracker, history: inout [String]) {
        for w in TextNormalizer.words(in: phrase) {
            history.append(w)
            t.update(spoken: history)
        }
    }

    func testFollowsSequentialReading() {
        var t = tracker, h: [String] = []
        speak("today I want to show you", into: &t, history: &h)
        XCTAssertEqual(t.words[t.position], "you")
        speak("how our new product saves teams", into: &t, history: &h)
        XCTAssertEqual(t.position, t.words.firstIndex(of: "teams"))
    }

    func testRepeatedTailIsIdempotent() {
        var t = tracker
        t.update(spoken: ["today", "i", "want"])
        let p = t.position
        XCTAssertFalse(t.update(spoken: ["today", "i", "want"]))
        XCTAssertEqual(t.position, p)
    }

    func testToleratesAdLibsAndMisrecognition() {
        var t = tracker, h: [String] = []
        speak("today I want to uh show you how our knew product", into: &t, history: &h)
        XCTAssertEqual(t.words[t.position], "product")
    }

    func testIgnoresUnrelatedChatter() {
        var t = tracker, h: [String] = []
        speak("today I want", into: &t, history: &h)
        let p = t.position
        speak("sorry can someone close the window", into: &t, history: &h)
        XCTAssertEqual(t.position, p)
    }

    func testSkipsAheadWithEnoughContext() {
        var t = tracker, h: [String] = []
        speak("today I want", into: &t, history: &h)
        speak("first we will look at the dashboard", into: &t, history: &h)
        XCTAssertEqual(t.words[t.position], "dashboard")
    }

    func testRepeatedPhraseResolvesToNearestOccurrence() {
        var t = tracker, h: [String] = []
        speak("first we will look at the dashboard then", into: &t, history: &h)
        speak("we will look at the", into: &t, history: &h)
        // "we will look at the" occurs twice; we're past the first, so pick the second.
        let theBeforeReports = t.words[..<t.words.firstIndex(of: "reports")!].lastIndex(of: "the")
        XCTAssertEqual(t.position, theBeforeReports)
    }

    func testGoesBackOnlyWithStrongEvidence() {
        var t = tracker, h: [String] = []
        speak("first we will look at the dashboard then we will look at the reports", into: &t, history: &h)
        let p = t.position
        speak("the", into: &t, history: &h)
        XCTAssertEqual(t.position, p, "a lone short word must not jump backwards")
        speak("show you how our new product", into: &t, history: &h)
        XCTAssertEqual(t.words[t.position], "product")
    }

    func testFuzzyMatching() {
        XCTAssertTrue(ScriptTracker.matches("dashboard", "dashbored"))
        XCTAssertTrue(ScriptTracker.matches("customers", "custom")) // truncated partial
        XCTAssertFalse(ScriptTracker.matches("the", "he"))
        XCTAssertFalse(ScriptTracker.matches("reports", "imports"))
    }
}

final class SpeechPacerTests: XCTestCase {
    func testNothingBeforeFirstRecognition() {
        var p = SpeechPacer()
        XCTAssertNil(p.position(at: 0, speaking: true))
    }

    func testRunsAheadOfRecognizerWhileSpeaking() {
        var p = SpeechPacer()
        p.recognized(10, at: 100)
        let pos = p.position(at: 100.2, speaking: true)!
        // Past the recognized word, compensating for recognizer latency.
        XCTAssertGreaterThan(pos, 11.5)
        XCTAssertLessThanOrEqual(pos, 11 + p.maxLead)
    }

    func testStopsWhenSpeakerStops() {
        var p = SpeechPacer()
        p.recognized(10, at: 100)
        let atSilence = p.position(at: 100.1, speaking: false)!
        XCTAssertEqual(atSilence, 11, accuracy: 0.001)
        XCTAssertEqual(p.position(at: 105, speaking: false)!, 11, accuracy: 0.001, "no drift during a pause")
    }

    func testLeadIsCapped() {
        var p = SpeechPacer()
        p.recognized(10, at: 100)
        XCTAssertEqual(p.position(at: 110, speaking: true)!, 11 + p.maxLead, accuracy: 0.001)
    }

    func testNeverMovesBackwardsOnItsOwn() {
        var p = SpeechPacer()
        p.recognized(10, at: 100)
        let ahead = p.position(at: 101, speaking: true)!
        p.recognized(11, at: 101.1) // recognizer catches up to less than we predicted
        XCTAssertGreaterThanOrEqual(p.position(at: 101.1, speaking: false)!, ahead)
    }

    func testFollowsSpeakerGoingBack() {
        var p = SpeechPacer()
        p.recognized(30, at: 100)
        _ = p.position(at: 100.5, speaking: true)
        p.recognized(12, at: 101)
        XCTAssertEqual(p.position(at: 101, speaking: false)!, 13, accuracy: 0.001)
    }

    func testLearnsSpeakingRate() {
        var p = SpeechPacer()
        for i in 0..<20 { p.recognized(i, at: 100 + Double(i) / 4) } // 4 words/sec
        XCTAssertEqual(p.wordsPerSecond, 4, accuracy: 0.2)
    }

    func testResetHoldsPositionUntilNextWord() {
        var p = SpeechPacer()
        p.recognized(30, at: 100)
        p.reset(to: 4)
        XCTAssertEqual(p.position(at: 100.5, speaking: true)!, 5, accuracy: 0.001)
        p.recognized(5, at: 101)
        XCTAssertGreaterThan(p.position(at: 101, speaking: true)!, 6)
    }
}

final class ReviewRegressionTests: XCTestCase {
    func testDoubledWordDoesNotSkipOnRepeatedPartial() {
        var t = ScriptTracker(words: Script(markdown: "i said really really good").words.map(\.normalized))
        t.update(spoken: ["i", "said", "really"])
        XCTAssertEqual(t.position, 2)
        t.update(spoken: ["i", "said", "really"])
        XCTAssertEqual(t.position, 2, "same partial twice must not advance")
        t.update(spoken: ["i", "said", "really", "really"])
        XCTAssertEqual(t.position, 3, "saying the word again does advance")
    }

    func testEmptyAndHeadingOnlyScripts() {
        for text in ["", "# Only\n## Headings", "[just a direction]"] {
            let s = Script(markdown: text)
            XCTAssertTrue(s.words.isEmpty)
            var t = ScriptTracker(words: [])
            XCTAssertFalse(t.update(spoken: ["hello"]))
            XCTAssertEqual(s.wordIndex(atOrAfterCharacter: 5), 0)
        }
    }

    func testCRLFAndHeadingWithBrackets() {
        let s = Script(markdown: "# Intro [a]\r\nHello world\r\n")
        XCTAssertEqual(s.sections.map(\.title), ["Intro [a]"])
        XCTAssertEqual(s.words.map(\.normalized), ["hello", "world"])
    }

    func testChineseAndJapaneseAreSplitPerCharacter() {
        XCTAssertEqual(TextNormalizer.words(in: "这是测试"), ["这", "是", "测", "试"])
        XCTAssertEqual(TextNormalizer.words(in: "テスト OK"), ["テ", "ス", "ト", "ok"])
        let s = Script(markdown: "这是一个测试句子")
        var t = ScriptTracker(words: s.words.map(\.normalized))
        t.update(spoken: TextNormalizer.words(in: "这是一个"))
        XCTAssertEqual(t.position, 3)
    }

    func testPacerGoesBackAfterResetWhenSpeakerIsEarlier() {
        var p = SpeechPacer()
        p.recognized(30, at: 100)
        p.reset(to: 10)
        p.recognized(5, at: 101)
        XCTAssertEqual(p.position(at: 101, speaking: false)!, 6, accuracy: 0.001)
    }
}

final class RemoteRouterTests: XCTestCase {
    func req(_ line: String) -> Data { Data("\(line)\r\nHost: x\r\n\r\n".utf8) }

    func testRoutes() {
        XCTAssertEqual(RemoteRouter.route(req("GET /?t=abc HTTP/1.1"), token: "abc"), .page)
        XCTAssertEqual(RemoteRouter.route(req("GET /api/state?t=abc HTTP/1.1"), token: "abc"), .state)
        XCTAssertEqual(RemoteRouter.route(req("POST /api/cmd/togglePlay?t=abc HTTP/1.1"), token: "abc"), .command("togglePlay"))
        XCTAssertEqual(RemoteRouter.route(req("POST /api/cue/2?t=abc HTTP/1.1"), token: "abc"), .cue(2))
    }

    func testRejectsMissingOrWrongToken() {
        XCTAssertEqual(RemoteRouter.route(req("GET / HTTP/1.1"), token: "abc"), .forbidden)
        XCTAssertEqual(RemoteRouter.route(req("GET /?t=abd HTTP/1.1"), token: "abc"), .forbidden)
        XCTAssertEqual(RemoteRouter.route(req("GET /?t=abcd HTTP/1.1"), token: "abc"), .forbidden)
        XCTAssertEqual(RemoteRouter.route(req("GET /?t= HTTP/1.1"), token: ""), .forbidden, "empty token never matches")
    }

    func testRejectsMalformedAndUnknown() {
        XCTAssertEqual(RemoteRouter.route(Data("garbage".utf8), token: "abc"), .badRequest)
        XCTAssertEqual(RemoteRouter.route(req("GET http://evil/?t=abc HTTP/1.1"), token: "abc"), .badRequest)
        XCTAssertEqual(RemoteRouter.route(req("POST /api/cue/-1?t=abc HTTP/1.1"), token: "abc"), .notFound)
        XCTAssertEqual(RemoteRouter.route(req("POST /api/cue/x?t=abc HTTP/1.1"), token: "abc"), .notFound)
        XCTAssertEqual(RemoteRouter.route(req("POST /api/cmd/?t=abc HTTP/1.1"), token: "abc"), .notFound)
        XCTAssertEqual(RemoteRouter.route(req("DELETE /?t=abc HTTP/1.1"), token: "abc"), .notFound)
        XCTAssertEqual(RemoteRouter.route(req("GET /api/cmd/togglePlay?t=abc HTTP/1.1"), token: "abc"), .notFound, "commands need POST")
    }
}

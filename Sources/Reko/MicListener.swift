import AVFoundation
import Speech
import RekoCore

/// Microphone input: a 0...1 loudness level (for "scroll while talking") and, optionally,
/// a stream of recognized words (for "follow my words"). All callbacks arrive on the main queue.
final class MicListener {
    var onLevel: ((Float) -> Void)?
    var onWords: (([String]) -> Void)?
    var onStatus: ((String) -> Void)?
    /// Listening could not start (permission denied, no mic…); the owner may retry later.
    var onFailure: (() -> Void)?

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var task: SFSpeechRecognitionTask?
    private var contextualStrings: [String] = []
    /// What the caller asked for, so a device change can restart exactly that (even mid-authorization).
    private var requested: (speech: Bool, locale: String)?
    private var running = false
    private var generation = 0 // invalidates callbacks from stopped sessions

    /// Touched from the audio thread, so guarded by a lock.
    private let lock = NSLock()
    private var _request: SFSpeechAudioBufferRecognitionRequest?
    private var request: SFSpeechAudioBufferRecognitionRequest? {
        get { lock.withLock { _request } }
        set { lock.withLock { _request = newValue } }
    }

    init() {
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            // Mic changed (AirPods connected, etc.): restart with the new input format.
            guard let self, self.running, let req = self.requested else { return }
            self.start(recognizeSpeech: req.speech, localeIdentifier: req.locale, contextualStrings: self.contextualStrings)
        }
    }

    func start(recognizeSpeech: Bool, localeIdentifier: String, contextualStrings: [String]) {
        stop()
        running = true
        generation += 1
        let gen = generation
        self.contextualStrings = contextualStrings
        requested = (recognizeSpeech, localeIdentifier)

        Self.requestMicAccess { [weak self] granted in
            guard let self, self.running, gen == self.generation else { return }
            guard granted else { return self.fail("Microphone access denied — enable Reko in System Settings › Privacy › Microphone") }
            guard recognizeSpeech else { return self.startEngine(gen: gen) }

            SFSpeechRecognizer.requestAuthorization { status in
                DispatchQueue.main.async {
                    guard self.running, gen == self.generation else { return }
                    guard status == .authorized else {
                        return self.fail("Speech recognition not allowed — enable Reko in System Settings › Privacy › Speech Recognition")
                    }
                    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)) ?? SFSpeechRecognizer(),
                          recognizer.isAvailable else {
                        return self.fail("Speech recognition unavailable for \(localeIdentifier)")
                    }
                    self.recognizer = recognizer
                    self.startRecognitionTask(gen: gen)
                    self.startEngine(gen: gen)
                }
            }
        }
    }

    /// New hint words after a script edit; picked up by the next recognition task (they restart every few
    /// seconds of silence), so listening isn't interrupted.
    func updateContextualStrings(_ strings: [String]) {
        contextualStrings = strings
    }

    func stop() {
        running = false
        generation += 1
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil
        recognizer = nil
    }

    private func startEngine(gen: Int) {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return fail("No microphone found") }

        var lastReport: TimeInterval = 0
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.request?.append(buffer)

            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastReport > 0.03, let level = Self.level(of: buffer) else { return }
            lastReport = now
            DispatchQueue.main.async {
                guard self.running, gen == self.generation else { return }
                self.onLevel?(level)
            }
        }

        do {
            engine.prepare()
            try engine.start()
            onStatus?(recognizer.map { "Listening (\($0.supportsOnDeviceRecognition ? "on-device" : "via Apple's servers")) …" } ?? "Listening …")
        } catch {
            fail("Could not start microphone: \(error.localizedDescription)")
        }
    }

    /// Recognition tasks end on long silences or time limits, so we chain a fresh one whenever one finishes.
    private func startRecognitionTask(gen: Int) {
        guard let recognizer, running, gen == generation else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = false
        request.contextualStrings = contextualStrings
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request
        var finished = false // a task can report isFinal and then an error; restart only once

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.running, gen == self.generation, !finished else { return }
                if let result {
                    let words = result.bestTranscription.segments.suffix(12).flatMap { TextNormalizer.words(in: $0.substring) }
                    if !words.isEmpty { self.onWords?(words) }
                }
                if error != nil || result?.isFinal == true {
                    finished = true
                    request.endAudio()
                    // Back off a little after errors (e.g. "no speech detected") to avoid a tight restart loop.
                    DispatchQueue.main.asyncAfter(deadline: .now() + (error != nil ? 0.5 : 0)) {
                        self.startRecognitionTask(gen: gen)
                    }
                }
            }
        }
    }

    private func fail(_ message: String) {
        onStatus?(message)
        stop()
        onFailure?()
    }

    /// RMS loudness mapped from -60…0 dBFS to 0…1.
    private static func level(of buffer: AVAudioPCMBuffer) -> Float? {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return nil }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += data[i] * data[i] }
        let db = 20 * log10(max(sqrt(sum / Float(n)), 1e-7))
        return min(max((db + 60) / 60, 0), 1)
    }

    private static func requestMicAccess(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: done(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in DispatchQueue.main.async { done(ok) } }
        default: done(false)
        }
    }
}

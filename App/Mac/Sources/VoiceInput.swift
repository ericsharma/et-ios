import AVFoundation
import Observation
import Speech

/// Dictation with the Mac's on-device speech recognition, as on iOS: audio
/// never leaves the Mac. Partial text is published live; `stop()` returns
/// the final text.
///
/// Apple's recognizer ends a recognition after a pause or roughly 30–60 s
/// of speech; finished stretches are kept in `committed` and a new
/// recognition is started on the same audio while the user still dictates.
@MainActor @Observable
final class VoiceInput {
    enum State: Equatable {
        case idle
        case listening
        case stopping
    }

    private(set) var state: State = .idle
    /// Everything heard so far, updated as the user speaks.
    private(set) var text = ""
    /// Set when dictation can't start (permissions, no on-device model).
    var error: String?

    @ObservationIgnored private var committed = ""
    @ObservationIgnored private var current = ""
    @ObservationIgnored private var recognizer: SFSpeechRecognizer?
    @ObservationIgnored private var contextualStrings: [String] = []
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private let sink = RequestSink()
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    /// Bumped per recognition task, so late callbacks from an old task are ignored.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var finalResult: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var safetyStop: Task<Void, Never>?

    static var locale: Locale {
        SFSpeechRecognizer(locale: Locale.current) != nil ? Locale.current : Locale(identifier: "en-US")
    }

    /// `contextualStrings`: names the recognizer should prefer (sessions, machines).
    func start(contextualStrings: [String]) async {
        guard state == .idle else { return }
        error = nil
        text = ""
        committed = ""
        current = ""
        guard await Self.requestPermissions() else {
            error = "E.T. needs Microphone and Speech Recognition access: System Settings → Privacy & Security."
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: Self.locale), recognizer.supportsOnDeviceRecognition else {
            error = "On-device dictation isn't available for this language."
            return
        }
        self.recognizer = recognizer
        self.contextualStrings = contextualStrings

        let engine = AVAudioEngine()
        do {
            let input = engine.inputNode
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0),
                             block: Self.tapBlock(sink))
            engine.prepare()
            try engine.start()
        } catch {
            self.error = "Couldn't start the microphone: \(error.localizedDescription)"
            cleanUp()
            return
        }
        self.engine = engine
        state = .listening
        startRecognition()

        // Cap a forgotten mic.
        safetyStop = Task {
            try? await Task.sleep(for: .seconds(600))
            guard !Task.isCancelled else { return }
            _ = await self.stop()
        }
    }

    private func startRecognition() {
        guard let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.contextualStrings = contextualStrings
        sink.set(request)
        generation += 1
        let generation = generation
        task = recognizer.recognitionTask(with: request, resultHandler: Self.resultHandler { [weak self] transcript, isFinal, ended in
            Task { @MainActor in
                self?.update(generation: generation, transcript: transcript, isFinal: isFinal, ended: ended)
            }
        })
    }

    private func update(generation: Int, transcript: String?, isFinal: Bool, ended: Bool) {
        guard generation == self.generation else { return }
        if let transcript {
            // The recognizer sometimes starts over within one task after a
            // pause; keep what it had instead of letting it vanish.
            if !current.isEmpty, transcript.count < current.count / 2,
               !transcript.lowercased().hasPrefix(current.lowercased().prefix(transcript.count)) {
                commit()
            }
            current = transcript
        }
        if isFinal { commit() }
        text = [committed, current].filter { !$0.isEmpty }.joined(separator: " ")

        guard ended else { return }
        switch state {
        case .listening:
            commit()
            startRecognition()
        case .stopping:
            finalResult?.resume()
            finalResult = nil
        case .idle:
            break
        }
    }

    private func commit() {
        let piece = current.trimmingCharacters(in: .whitespaces)
        if !piece.isEmpty { committed = committed.isEmpty ? piece : committed + " " + piece }
        current = ""
    }

    /// Stops listening and returns the final text (empty if nothing heard).
    func stop() async -> String {
        guard state == .listening else { return "" }
        state = .stopping
        safetyStop?.cancel()
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        sink.endAudio()
        // Wait briefly for the recognizer's final pass over the last words.
        await withCheckedContinuation { continuation in
            finalResult = continuation
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                self.finalResult?.resume()
                self.finalResult = nil
            }
        }
        commit()
        let result = committed
        cleanUp()
        return result
    }

    private func cleanUp() {
        task?.cancel()
        task = nil
        sink.set(nil)
        engine = nil
        recognizer = nil
        generation += 1
        state = .idle
    }

    // The audio tap and recognizer callbacks run on background threads, so
    // their closures are built in nonisolated helpers (see the iOS version).

    nonisolated private static func tapBlock(_ sink: RequestSink) -> AVAudioNodeTapBlock {
        { buffer, _ in sink.append(buffer) }
    }

    nonisolated private static func resultHandler(
        _ update: @escaping @Sendable (_ transcript: String?, _ isFinal: Bool, _ ended: Bool) -> Void
    ) -> (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        { result, error in
            let isFinal = result?.isFinal == true
            update(result?.bestTranscription.formattedString, isFinal, isFinal || error != nil)
        }
    }

    nonisolated private static func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }
}

/// Holds the current recognition request for the audio thread.
private final class RequestSink: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func set(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        let old = lock.withLock { () -> SFSpeechAudioBufferRecognitionRequest? in
            defer { self.request = request }
            return self.request
        }
        old?.endAudio()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock { request }?.append(buffer)
    }

    func endAudio() {
        lock.withLock { request }?.endAudio()
    }
}

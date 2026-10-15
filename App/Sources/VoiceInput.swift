import AVFoundation
import Observation
import Speech

/// One-tap dictation with on-device speech recognition (SPEC §6.3). Audio
/// never leaves the device. Partial text is published live; `stop()`
/// returns the final text.
@MainActor @Observable
final class VoiceInput {
    enum State: Equatable {
        case idle
        case listening
        case stopping
    }

    private(set) var state: State = .idle
    /// The transcription so far, updated as the user speaks.
    private(set) var text = ""
    /// Set when dictation can't start (permissions, no on-device model).
    var error: String?

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var finalResult: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var safetyStop: Task<Void, Never>?

    func start(contextualStrings: [String]) async {
        guard state == .idle else { return }
        error = nil
        text = ""
        guard await Self.requestPermissions() else {
            error = "E.T. needs Microphone and Speech Recognition access. Turn them on in Settings → E.T."
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.supportsOnDeviceRecognition else {
            error = "On-device dictation isn't available for this language. Use the keyboard's mic instead."
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.contextualStrings = contextualStrings
        self.request = request

        let engine = AVAudioEngine()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let input = engine.inputNode
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0),
                             block: Self.tapBlock(appendingTo: request))
            engine.prepare()
            try engine.start()
        } catch {
            self.error = "Couldn't start the microphone: \(error.localizedDescription)"
            cleanUp()
            return
        }
        self.engine = engine
        state = .listening

        task = recognizer.recognitionTask(with: request, resultHandler: Self.resultHandler { [weak self] transcript, done in
            Task { @MainActor in
                guard let self else { return }
                if let transcript { self.text = transcript }
                if done { self.finalResult?.resume(); self.finalResult = nil }
            }
        })
        // On-device recognition doesn't stop by itself; cap a forgotten mic.
        safetyStop = Task {
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled else { return }
            _ = await self.stop()
        }
    }

    /// Stops listening and returns the final text (empty if nothing heard).
    func stop() async -> String {
        guard state == .listening else { return "" }
        state = .stopping
        safetyStop?.cancel()
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        // Wait briefly for the recognizer's final pass over the last words.
        await withCheckedContinuation { continuation in
            finalResult = continuation
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                self.finalResult?.resume()
                self.finalResult = nil
            }
        }
        let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        cleanUp()
        return result
    }

    private func cleanUp() {
        task?.cancel()
        task = nil
        request = nil
        engine = nil
        state = .idle
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // The audio tap and recognizer callbacks run on background threads.
    // Closures written inside this @MainActor class would inherit main-actor
    // isolation and trap there, so they are built in nonisolated helpers.

    nonisolated private static func tapBlock(appendingTo request: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
        nonisolated(unsafe) let request = request
        return { buffer, _ in request.append(buffer) }
    }

    nonisolated private static func resultHandler(
        _ update: @escaping @Sendable (String?, Bool) -> Void
    ) -> (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        { result, error in
            update(result?.bestTranscription.formattedString, result?.isFinal == true || error != nil)
        }
    }

    nonisolated private static func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }
}

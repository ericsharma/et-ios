import AVFoundation
import Observation

/// Finds what Claude asks of the user: the last paragraph starting with
/// "Next:" in a window's text. Pure, so it can be tested off-device.
enum NextStep {
    static func extract(from text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.lastIndex(where: { isNextLine($0) }) else { return nil }
        var parts = [stripped(lines[start])]
        // Claude Code wraps its own output into indented lines; the
        // paragraph runs until a blank line or the next block.
        for line in lines[(start + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || !line.hasPrefix(" ") || startsBlock(trimmed) { break }
            parts.append(trimmed)
        }
        let paragraph = parts.joined(separator: " ")
        return spoken(paragraph)
    }

    private static func isNextLine(_ line: String) -> Bool {
        stripped(line).hasPrefix("Next:")
    }

    /// Without Claude's "⏺" marker, indentation and markdown bold.
    private static func stripped(_ line: String) -> String {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("⏺") { s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces) }
        return s.replacingOccurrences(of: "**", with: "")
    }

    /// Lines that begin something else: Claude's markers, boxes, the prompt.
    private static func startsBlock(_ trimmed: String) -> Bool {
        guard let c = trimmed.first else { return true }
        return "⏺⎿╭╰│─>❯✻✶✳✢·".contains(c)
    }

    /// Text that reads well aloud.
    private static func spoken(_ text: String) -> String {
        var s = text
        for (a, b) in [("`", ""), ("**", ""), (" → ", " then "), ("->", " then ")] {
            s = s.replacingOccurrences(of: a, with: b)
        }
        return s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// Reads text aloud with the on-device voice: the best installed English
/// voice (Premium, then Enhanced, then the default).
@MainActor @Observable
final class Speaker: NSObject {
    static let shared = Speaker()

    private(set) var isSpeaking = false
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) {
        stop()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: .duckOthers)
        try? AVAudioSession.sharedInstance().setActive(true)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.bestVoice()
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    func stop() {
        guard synthesizer.isSpeaking else { return }
        synthesizer.stopSpeaking(at: .immediate)
    }

    private func finished() {
        isSpeaking = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private static func bestVoice() -> AVSpeechSynthesisVoice? {
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        let region = Locale.current.region?.identifier
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(language) }
        let ranked = voices.sorted { a, b in
            if a.quality != b.quality { return a.quality.rawValue > b.quality.rawValue }
            // Prefer the user's own region (en-US over en-IE).
            return (region.map { a.language.hasSuffix($0) } ?? false) && !(region.map { b.language.hasSuffix($0) } ?? false)
        }
        return ranked.first ?? AVSpeechSynthesisVoice(language: nil)
    }
}

extension Speaker: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finished() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finished() }
    }
}

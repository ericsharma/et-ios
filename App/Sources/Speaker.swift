import AVFoundation
import Observation
import SwiftUI

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

    /// Lines that begin something else: Claude's markers, boxes, the
    /// prompt, and Grok's (◆) and agy's (●) tool lines. Grok and agy have
    /// no reply marker: their reply is indented text.
    private static func startsBlock(_ trimmed: String) -> Bool {
        guard let c = trimmed.first else { return true }
        return "⏺⎿╭╰│─>❯✻✶✳✢·◆●".contains(c)
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

/// Claude Code's latest reply in a window: everything after the user's
/// last message, without the input box, spinners and status lines. Pure,
/// so it can be tested off-device.
enum ClaudeReply {
    static func extract(from text: String, maxCharacters: Int = 8000) -> String? {
        var lines = text.components(separatedBy: "\n")
        // Drop the input box at the bottom: from the second-to-last
        // horizontal rule down.
        let rules = lines.indices.filter { isRule(lines[$0]) }
        if rules.count >= 2 {
            lines = Array(lines[..<rules[rules.count - 2]])
        } else if let top = composerBox(lines) {
            // Grok's input box is a ╭─╮ … ╰─╯ box, not two rules.
            lines = Array(lines[..<top])
        }
        // The user's last message starts with "❯ " or "> " at column 0.
        if let lastPrompt = lines.lastIndex(where: { $0.hasPrefix("❯ ") || $0.hasPrefix("> ") }) {
            var end = lastPrompt + 1
            // The message itself may wrap onto indented lines.
            while end < lines.count, lines[end].hasPrefix("  "), !lines[end].trimmingCharacters(in: .whitespaces).isEmpty { end += 1 }
            lines = Array(lines[end...])
        }
        let kept = lines.filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard let c = t.first else { return true }
            // Spinners, "Cogitated for 2s", mode hints.
            return !"✻✶✳✢·⏵".contains(c)
        }
        var reply = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else { return nil }
        // Long replies: the end matters most (results and what's next).
        if reply.count > maxCharacters { reply = "…" + reply.suffix(maxCharacters) }
        return reply
    }

    /// The user's last prompt above the input box: the last "❯ " line at
    /// column 0 and its indented continuation lines.
    static func lastPrompt(from text: String) -> String? {
        var lines = text.components(separatedBy: "\n")
        let rules = lines.indices.filter { isRule(lines[$0]) }
        if rules.count >= 2 { lines = Array(lines[..<rules[rules.count - 2]]) }
        guard let start = lines.lastIndex(where: { $0.hasPrefix("❯ ") || $0.hasPrefix("> ") }) else { return nil }
        var parts = [String(lines[start].dropFirst(2))]
        var i = start + 1
        while i < lines.count, lines[i].hasPrefix("  "), !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
            parts.append(lines[i].trimmingCharacters(in: .whitespaces))
            i += 1
        }
        let prompt = parts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return prompt.isEmpty ? nil : prompt
    }

    /// The top line of a ╭ … ╰ box in the last 6 lines: Grok's composer.
    private static func composerBox(_ lines: [String]) -> Int? {
        let tail = lines.indices.suffix(6)
        guard let bottom = tail.last(where: { lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("╰") }) else { return nil }
        return tail.last { $0 < bottom && lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("╭") }
    }

    private static func isRule(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.count >= 10 && t.allSatisfy { $0 == "─" }
    }
}

/// Reads text aloud: audio from the server's voice model (VoiceSettings),
/// or the on-device voice, the best installed English one (Premium, then
/// Enhanced, then the default).
@MainActor @Observable
final class Speaker: NSObject {
    static let shared = Speaker()

    private(set) var isSpeaking = false
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var player: AVAudioPlayer?

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) {
        stop()
        activate()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.bestVoice()
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    /// Plays speech the server made (mp3). False if it can't be played.
    func play(_ audio: Data) -> Bool {
        stop()
        guard let player = try? AVAudioPlayer(data: audio) else { return false }
        activate()
        player.delegate = self
        self.player = player
        isSpeaking = player.play()
        if !isSpeaking { finished() }
        return isSpeaking
    }

    func stop() {
        if let player {
            player.stop()
            finished()
        }
        guard synthesizer.isSpeaking else { return }
        synthesizer.stopSpeaking(at: .immediate)
    }

    private func activate() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: .duckOthers)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func finished() {
        player = nil
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

extension Speaker: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let finishedPlayer = ObjectIdentifier(player)
        Task { @MainActor in
            if let current = self.player, ObjectIdentifier(current) == finishedPlayer { self.finished() }
        }
    }
}

/// The server's voice model: Kokoro (or any OpenAI-compatible
/// /v1/audio/speech) at ET_TTS_URL in the tmux server's summary.env,
/// called with curl there like the summary model.
enum VoiceSettings {
    static let naturalKey = "naturalVoice"
    static let voiceKey = "naturalVoiceName"

    static var natural: Bool { UserDefaults.standard.object(forKey: naturalKey) as? Bool ?? true }
    static var voice: String { UserDefaults.standard.string(forKey: voiceKey) ?? "af_heart" }

    /// Kokoro's best-rated English voices.
    static let voices: [(id: String, name: String)] = [
        ("af_heart", "Heart (US, female)"),
        ("af_bella", "Bella (US, female)"),
        ("af_nicole", "Nicole (US, female, soft)"),
        ("am_michael", "Michael (US, male)"),
        ("am_fenrir", "Fenrir (US, male)"),
        ("bf_emma", "Emma (UK, female)"),
        ("bm_george", "George (UK, male)"),
        ("bm_fable", "Fable (UK, male)"),
    ]
}

// MARK: - Summaries ("hold the speaker")

/// Where summaries come from: an OpenAI-compatible chat endpoint, called
/// with curl on the tmux server (so the key stays there and the endpoint
/// only has to be reachable from the server).
enum SummarySettings {
    static let endpointKey = "summaryEndpoint"
    static let keyFileKey = "summaryKeyFile"
    static let modelKey = "summaryModel"
    static let providerKey = "summaryProvider"

    /// Which model summarizes. Mac mini and Grok come from the tmux
    /// server's summary.env (ET_SUMMARY_* and ET_GROK_*), so no key is
    /// typed on the phone; Custom is the endpoint typed here.
    enum Provider: String, CaseIterable, Identifiable {
        case local, grok, custom
        var id: String { rawValue }
        var title: String {
            switch self {
            case .local: "Mac mini (local)"
            case .grok: "Grok (xAI subscription)"
            case .custom: "Custom endpoint"
            }
        }
        var label: String {
            switch self {
            case .local: "Mac mini"
            case .grok: "Grok"
            case .custom: "custom endpoint"
            }
        }
        /// Variable prefix in summary.env.
        var envPrefix: String { self == .grok ? "ET_GROK" : "ET_SUMMARY" }
    }

    static var endpoint: String { value(endpointKey) }
    static var keyFile: String { value(keyFileKey) }
    static var model: String { value(modelKey) }
    /// Before the picker existed, a typed endpoint meant Custom.
    static var provider: Provider {
        Provider(rawValue: value(providerKey)) ?? (endpoint.isEmpty ? .local : .custom)
    }
    static var isConfigured: Bool { provider == .custom && !endpoint.isEmpty }

    /// The full URL: a bare host:port gets /v1/chat/completions.
    static var url: String {
        var url = endpoint
        if !url.contains("://") { url = "http://" + url }
        if !url.hasSuffix("/chat/completions") {
            url = url.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            url += url.hasSuffix("/v1") ? "/chat/completions" : "/v1/chat/completions"
        }
        return url
    }

    private static func value(_ key: String) -> String {
        (UserDefaults.standard.string(forKey: key) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let prompt = """
    You read a coding assistant's latest reply aloud to its user, who is listening, not reading. \
    Summarize it in 2 to 4 short spoken sentences: what was done or found, any problem, and what the \
    user should do next. Plain speech only: no code, no markdown, no lists, no file paths unless \
    essential (say them naturally, like "key row dot swift"). Don't start with "The assistant".
    """
}

enum SummaryError: LocalizedError {
    case notConfigured, notConnected, noReply
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: SummarySettings.provider == .grok
            ? "Grok isn't set up on the server (ET_GROK_URL in summary.env)"
            : "No summary model set up: see ⋯ → Read aloud"
        case .notConnected: "Not connected"
        case .noReply: "No Claude reply found in this window"
        case .failed(let message): message
        }
    }
}

struct ReadAloudSettingsView: View {
    /// The live session, for "Try it".
    let session: SessionController?
    @AppStorage(SummarySettings.endpointKey) private var endpoint = ""
    @AppStorage(SummarySettings.keyFileKey) private var keyFile = ""
    @AppStorage(SummarySettings.modelKey) private var model = ""
    @AppStorage(SummarySettings.providerKey) private var provider = SummarySettings.provider.rawValue
    @AppStorage(VoiceSettings.naturalKey) private var natural = true
    @AppStorage(VoiceSettings.voiceKey) private var voice = "af_heart"
    @State private var trial: String?
    @State private var trying = false

    var body: some View {
        Form {
            Section {
                Label("Tap the speaker: reads Claude's last \u{201C}Next:\u{201D} line.", systemImage: "hand.tap")
                Label("Hold the speaker: summarizes Claude's whole last reply, then reads the summary.", systemImage: "hand.point.up.left")
            }
            Section {
                Picker("Model", selection: $provider) {
                    ForEach(SummarySettings.Provider.allCases) { Text($0.title).tag($0.rawValue) }
                }
            } header: {
                Text("Summary model")
            } footer: {
                Text("Mac mini and Grok use the tmux server's own settings: ~/.config/et/summary.env or /run/secrets/rendered/et-summary.env, with ET_SUMMARY_URL/ET_SUMMARY_KEY and ET_GROK_URL/ET_GROK_MODEL/ET_GROK_KEY_CMD lines. E.T. calls the model with curl on the tmux server, so keys never leave it.")
            }
            if provider == SummarySettings.Provider.custom.rawValue {
                Section {
                    TextField("Endpoint, e.g. 192.168.0.5:8223", text: $endpoint)
                    TextField("API key file on the server (optional)", text: $keyFile)
                    TextField("Model (optional)", text: $model)
                } header: {
                    Text("Custom endpoint")
                } footer: {
                    Text("Any OpenAI-compatible chat endpoint (llama-server, Ollama, LM Studio…). A key file can hold just the key or a line like LLM_API_KEY=….")
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.body.monospaced())
            }
            Section {
                Toggle("Natural voice", isOn: $natural)
                if natural {
                    Picker("Voice", selection: $voice) {
                        ForEach(VoiceSettings.voices, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    if let session {
                        Button("Hear this voice") {
                            Task { await session.say("Build 2061 is on TestFlight. Next, open E.T. and hold the speaker.") }
                        }
                    }
                }
            } header: {
                Text("Voice")
            } footer: {
                Text("Natural voice uses the speech model at ET_TTS_URL in the tmux server's summary.env (Kokoro on the Mac mini; the key is ET_TTS_KEY, else ET_SUMMARY_KEY). Without one, or if it fails, E.T. uses the phone's best installed voice.")
            }
            if let session {
                Section {
                    Button(trying ? "Summarizing…" : "Try it") {
                        trying = true
                        trial = nil
                        Task {
                            let start = Date()
                            do {
                                let summary = try await session.summarize("""
                                ⏺ Fixed the iPad crash. The speech model call only exists on iOS 26, so iOS 18 crashed right after connecting. \
                                E.T. now uses the older call there. Verified on iOS 18.4 and 26.5 simulators.
                                  Next: install build 2059 on the iPad and open E.T.
                                """)
                                trial = "\(summary)\n\n(\(Int(Date().timeIntervalSince(start))) s)"
                                await session.say(summary)
                            } catch {
                                trial = error.localizedDescription
                            }
                            trying = false
                        }
                    }
                    .disabled(trying)
                    if let trial { Text(trial).font(.callout) }
                }
            }
        }
        .navigationTitle("Read aloud")
    }
}

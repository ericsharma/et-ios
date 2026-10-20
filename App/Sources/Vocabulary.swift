import CryptoKit
import Foundation
import Observation
import Speech
import SwiftUI
import UIKit

/// A name the user added so dictation spells it right.
struct VocabTerm: Codable, Hashable, Identifiable {
    var text: String
    /// How the user says it, when that's far from the spelling ("tea mux").
    var soundsLike: [String] = []
    var id: String { text }
}

/// A git repository found on a host, with its tracked files.
struct DiscoveredRepo: Codable, Hashable {
    var host: String
    var name: String
    var files: [String]
}

/// Names dictation should get right (SPEC §6.3): the user's own list,
/// repos and files found on the servers, window names, and odd words on
/// screen. Feeds three things: a custom on-device language model (so the
/// recognizer hears the names), the recognizer's contextual hints, and
/// `VocabMatcher`, which fixes spellings after recording.
@MainActor @Observable
final class Vocabulary {
    static let shared = Vocabulary()

    private(set) var custom: [VocabTerm] = []
    private(set) var repos: [DiscoveredRepo] = []
    private(set) var discoveryStatus = "Not searched yet"
    private(set) var modelStatus = "Not built yet"
    /// The compiled language model, once ready.
    @ObservationIgnored private(set) var languageModel: SFSpeechLanguageModel.Configuration?

    @ObservationIgnored private var windowNames: [String] = []
    @ObservationIgnored private var screenWords: [String] = []
    @ObservationIgnored private var cachedMatcher: VocabMatcher?
    @ObservationIgnored private var buildTask: Task<Void, Never>?
    @ObservationIgnored private var commonWords: [String: Bool] = [:]
    @ObservationIgnored private let checker = UITextChecker()

    private static let supportDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    private static let customURL = supportDir.appendingPathComponent("vocabulary.json")
    private static let reposURL = supportDir.appendingPathComponent("discovered-repos.json")
    private static let modelDir: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SpeechModel", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Set while a model build runs. Still set at launch means the last
    /// build crashed the app; that model version is then skipped.
    private static let buildingKey = "speechModelBuilding"
    private static let crashedKey = "speechModelCrashed"

    private init() {
        if let crashed = UserDefaults.standard.string(forKey: Self.buildingKey) {
            UserDefaults.standard.set(crashed, forKey: Self.crashedKey)
            UserDefaults.standard.removeObject(forKey: Self.buildingKey)
        }
        if let data = try? Data(contentsOf: Self.customURL),
           let saved = try? JSONDecoder().decode([VocabTerm].self, from: data) {
            custom = saved
        }
        if let data = try? Data(contentsOf: Self.reposURL),
           let saved = try? JSONDecoder().decode([DiscoveredRepo].self, from: data) {
            repos = saved
            discoveryStatus = "\(saved.count) repos from the last search"
        }
        scheduleModelBuild(after: 0)
    }

    // MARK: - The user's list

    func add(_ text: String, soundsLike: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let alikes = soundsLike.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        custom.removeAll { $0.text == text }
        custom.insert(VocabTerm(text: text, soundsLike: alikes), at: 0)
        saveCustom()
    }

    /// Names to offer after the user edited dictated text: replacements
    /// that look like names (not plain rewording) and aren't saved yet.
    func suggestions(original: String, edited: String) -> [VocabTerm] {
        VocabMatcher.replacements(from: original, to: edited).compactMap { heard, spelling in
            guard spelling.split(separator: " ").contains(where: { isUnusual(String($0)) }) else { return nil }
            if let saved = custom.first(where: { $0.text == spelling }), saved.soundsLike.contains(heard) { return nil }
            return VocabTerm(text: spelling, soundsLike: [heard])
        }
    }

    /// Saves a name, merging its sounds-like with an existing entry.
    func learn(_ term: VocabTerm) {
        let previous = custom.first(where: { $0.text == term.text })?.soundsLike ?? []
        add(term.text, soundsLike: (previous + term.soundsLike.filter { !previous.contains($0) }).joined(separator: ", "))
    }

    func remove(_ term: VocabTerm) {
        custom.removeAll { $0 == term }
        saveCustom()
    }

    private func saveCustom() {
        try? JSONEncoder().encode(custom).write(to: Self.customURL, options: .atomic)
        changed(rebuildModel: true)
    }

    // MARK: - Found names

    /// Repos found on one host replace that host's earlier results.
    func setRepos(_ found: [DiscoveredRepo], hosts: [String]) {
        let fresh = repos.filter { !hosts.contains($0.host) } + found
        let total = found.reduce(0) { $0 + $1.files.count }
        discoveryStatus = "\(found.count) repos, \(total) files on \(hosts.joined(separator: ", "))"
        guard fresh != repos else { return }
        repos = fresh
        try? JSONEncoder().encode(repos).write(to: Self.reposURL, options: .atomic)
        changed(rebuildModel: true)
    }

    func setDiscoveryStatus(_ text: String) { discoveryStatus = text }

    /// Called as the mic starts: window names, and unusual words in the
    /// recent output of each window (paths, flags, identifiers).
    func refreshFromScreens(windowNames: [String], screens: [String]) {
        self.windowNames = windowNames
        screenWords = scrapeScreens(screens)
        changed(rebuildModel: false)
    }

    private func changed(rebuildModel: Bool) {
        cachedMatcher = nil
        if rebuildModel { scheduleModelBuild(after: 2) }
    }

    // MARK: - Using it

    /// Fixes names in finished dictation. `tagFiles`: "at <file>" becomes
    /// an "@path" mention (Claude windows).
    func correct(_ text: String, tagFiles: Bool) -> String {
        matcher.correct(text, tagFiles: tagFiles)
    }

    /// Hints for the recognizer (it reads at most about 100).
    var contextualStrings: [String] {
        var seen = Set<String>()
        let all = custom.map(\.text) + windowNames + repos.map(\.name) + screenWords
            + ["tmux", "ssh", "sudo", "git", "grep", "claude", "systemctl", "journalctl", "docker", "vim"]
        return all.filter { seen.insert($0).inserted }.prefix(100).map { $0 }
    }

    var fileCount: Int { repos.reduce(0) { $0 + $1.files.count } }

    private var matcher: VocabMatcher {
        if let cachedMatcher { return cachedMatcher }
        var terms: [VocabMatcher.Term] = custom.map { .init(text: $0.text, soundsLike: $0.soundsLike, source: .custom) }
        terms += windowNames.map { .init(text: $0, source: .window) }
        terms += Set(repos.map(\.name)).map { .init(text: $0, source: .repo) }
        terms += fileTerms()
        terms += screenWords.map { .init(text: $0, source: .screen) }
        let built = VocabMatcher(terms: terms, isCommonWord: { [weak self] in self?.isCommon($0) ?? false })
        cachedMatcher = built
        return built
    }

    /// File names (and their unique paths), plus unusual directory names.
    private func fileTerms() -> [VocabMatcher.Term] {
        var pathsByName: [String: Set<String>] = [:]
        var dirs = Set<String>()
        for repo in repos {
            for path in repo.files {
                let parts = path.split(separator: "/").map(String.init)
                guard let name = parts.last else { continue }
                pathsByName[name, default: []].insert(path)
                dirs.formUnion(parts.dropLast())
            }
        }
        var terms = pathsByName.map { name, paths in
            VocabMatcher.Term(text: name, source: .file, path: paths.count == 1 ? paths.first : nil)
        }
        terms += dirs.filter { isUnusual($0) }.map { .init(text: $0, source: .file) }
        return terms
    }

    // MARK: - Screen words

    private func scrapeScreens(_ screens: [String]) -> [String] {
        var counts: [String: Int] = [:]
        let pattern = try! Regex("[A-Za-z0-9_@./~+-]{3,80}")
        for screen in screens {
            for match in screen.matches(of: pattern) {
                var word = String(screen[match.range])
                if word.contains("://") || word.hasPrefix("http") { continue }
                while let c = word.last, ".,:;-".contains(c) { word.removeLast() }
                while let c = word.first, "@~./-".contains(c) { word.removeFirst() }
                if let colon = word.firstIndex(of: ":") { word = String(word[..<colon]) }
                guard word.count >= 3, word.count <= 60, word.contains(where: \.isLetter) else { continue }
                if word.contains("/") {
                    if let name = word.split(separator: "/").last.map(String.init), name.count >= 3 {
                        counts[name, default: 0] += 1
                    }
                    if word.split(separator: "/").count > 4 { continue }
                }
                counts[word, default: 0] += 1
            }
        }
        return counts
            .filter { word, n in isUnusual(word) && (n >= 2 || word.contains(where: { "-_./".contains($0) })) }
            .sorted { $0.value > $1.value }
            .prefix(300)
            .map(\.key)
    }

    /// Worth teaching: has separators, camelCase or digits, or isn't an
    /// English word. Plain words are already heard fine.
    private func isUnusual(_ word: String) -> Bool {
        if word.contains(where: { "-_./".contains($0) }) { return true }
        if word.contains(where: \.isNumber) { return true }
        if word.dropFirst().contains(where: \.isUppercase) { return true }
        return word.count >= 4 && !isCommon(word.lowercased())
    }

    private func isCommon(_ word: String) -> Bool {
        if let known = commonWords[word] { return known }
        let range = checker.rangeOfMisspelledWord(in: word, range: NSRange(location: 0, length: (word as NSString).length),
                                                  startingAt: 0, wrap: false, language: "en")
        let known = range.location == NSNotFound
        commonWords[word] = known
        return known
    }

    // MARK: - Custom language model

    /// Names a rewrite must keep spelled exactly: the user's list, window
    /// names and repos (file names are too many to list).
    var keepNames: [String] {
        var seen = Set<String>()
        return (custom.map(\.text) + windowNames + repos.map(\.name))
            .filter { seen.insert($0).inserted }
            .prefix(120).map { $0 }
    }

    /// The phrases the model learns: each name as it is said ("nam shub",
    /// "key row dot swift"), most trusted first.
    private func modelPhrases() -> [String] {
        var names = custom.map(\.text) + repos.map(\.name)
        var files: [String] = []
        var seenFiles = Set<String>()
        for repo in repos {
            for path in repo.files.sorted(by: { $0.count < $1.count }).prefix(150) {
                let name = String(path.split(separator: "/").last ?? "")
                if seenFiles.insert(name).inserted { files.append(name) }
            }
        }
        names += files
        var seen = Set<String>()
        var phrases: [String] = []
        for name in names {
            let plain = name.allSatisfy { $0.isLetter || $0.isNumber }
            let phrase = plain ? name.lowercased() : VocabMatcher.words(name).joined(separator: " ")
            guard phrase.count >= 3, phrase.allSatisfy({ $0.isLetter || $0.isNumber || $0 == " " }),
                  seen.insert(phrase).inserted else { continue }
            phrases.append(phrase)
            if phrases.count >= 600 { break }
        }
        return phrases
    }

    private func scheduleModelBuild(after seconds: Double) {
        buildTask?.cancel()
        buildTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await buildModel()
        }
    }

    /// Builds the model if the names changed; reuses the last one otherwise.
    func buildModel() async {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            modelStatus = "Waits for speech permission (use the mic once)"
            return
        }
        let phrases = modelPhrases()
        guard !phrases.isEmpty else {
            languageModel = nil
            modelStatus = "No names yet"
            return
        }
        let locale = VoiceInput.locale
        let digest = SHA256.hash(data: Data((locale.identifier + "\n" + phrases.joined(separator: "\n")).utf8))
        let version = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        let lm = Self.modelDir.appendingPathComponent("lm-\(version)")
        let vocab = Self.modelDir.appendingPathComponent("vocab-\(version)")
        let config = SFSpeechLanguageModel.Configuration(languageModel: lm, vocabulary: vocab)
        if FileManager.default.fileExists(atPath: lm.path) {
            languageModel = config
            modelStatus = "Ready · \(phrases.count) names"
            return
        }
        // Keyed by app build too, so a fixed build tries again.
        let attempt = version + "@" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")
        if UserDefaults.standard.string(forKey: Self.crashedKey) == attempt {
            modelStatus = "Skipped: building it crashed E.T. last time"
            return
        }
        modelStatus = "Building (\(phrases.count) names)…"
        UserDefaults.standard.set(attempt, forKey: Self.buildingKey)
        defer { UserDefaults.standard.removeObject(forKey: Self.buildingKey) }
        let asset = Self.modelDir.appendingPathComponent("data-\(version).bin")
        do {
            try await Self.exportModelData(phrases: phrases, locale: locale, version: version, to: asset)
            guard !Task.isCancelled else { return }
            try await Self.prepare(asset: asset, configuration: config)
            try? FileManager.default.removeItem(at: asset)
            // Drop older models.
            for file in (try? FileManager.default.contentsOfDirectory(at: Self.modelDir, includingPropertiesForKeys: nil)) ?? []
            where !file.lastPathComponent.hasSuffix(version) && !file.lastPathComponent.contains("data-") {
                try? FileManager.default.removeItem(at: file)
            }
            languageModel = config
            modelStatus = "Ready · \(phrases.count) names"
        } catch {
            modelStatus = "Couldn't build: \(error.localizedDescription)"
        }
    }

    /// Built and exported off the main actor (the data object isn't Sendable).
    nonisolated private static func exportModelData(phrases: [String], locale: Locale, version: String, to asset: URL) async throws {
        let data = SFCustomLanguageModelData(locale: locale, identifier: "xyz.ericsharma.et.names", version: version) {
            SFCustomLanguageModelData.PhraseCountsFromTemplates(classes: ["name": phrases]) {
                SFCustomLanguageModelData.TemplatePhraseCountGenerator.Template("<name>", count: 2000)
                SFCustomLanguageModelData.TemplatePhraseCountGenerator.Template("look at <name>", count: 500)
                SFCustomLanguageModelData.TemplatePhraseCountGenerator.Template("open <name>", count: 500)
                SFCustomLanguageModelData.TemplatePhraseCountGenerator.Template("in <name>", count: 500)
                SFCustomLanguageModelData.TemplatePhraseCountGenerator.Template("the <name> repo", count: 300)
                SFCustomLanguageModelData.TemplatePhraseCountGenerator.Template("at <name>", count: 300)
            }
        }
        try await data.export(to: asset)
    }

    /// The call without a client identifier only exists from iOS 26 (the
    /// SDK header doesn't say so); on iOS 18 it's an unknown selector and
    /// crashes. Older systems use the original, now-deprecated call.
    private static func prepare(asset: URL, configuration: SFSpeechLanguageModel.Configuration) async throws {
        if #available(iOS 26, *) {
            try await SFSpeechLanguageModel.prepareCustomLanguageModel(for: asset, configuration: configuration)
        } else {
            try await SFSpeechLanguageModel.prepareCustomLanguageModel(
                for: asset, clientIdentifier: "xyz.ericsharma.et", configuration: configuration)
        }
    }

    /// After the first speech permission grant.
    func permissionGranted() {
        if languageModel == nil { scheduleModelBuild(after: 0) }
    }
}

// MARK: - Finding repos on the server

/// Shell for finding repos: git repos one or two levels under $HOME plus
/// the repos of the given directories, those first; up to 800 tracked
/// files each. Prints "R name" then "F path" lines.
enum VocabDiscovery {
    static let listFunction = """
    etrepos() { { for p in "$@"; do git -C "$p" rev-parse --show-toplevel 2>/dev/null; done; \
    for r in "$HOME"/* "$HOME"/*/*; do [ -e "$r/.git" ] && echo "$r"; done; } | awk '!s[$0]++' | head -30 | \
    while IFS= read -r r; do echo "R ${r##*/}"; git -C "$r" ls-files 2>/dev/null | head -800 | sed 's/^/F /'; done; }
    """

    /// Finds the `ssh` commands running in the given panes (windows that
    /// hop to another host). Prints "S <args>" lines.
    static func sshScript(pids: [Int]) -> String {
        "for p in \(pids.map(String.init).joined(separator: " ")); do for c in $p $(pgrep -P $p 2>/dev/null); do " +
            "a=$(ps -o args= -p $c 2>/dev/null); case \"$a\" in ssh\\ *|*/ssh\\ *) echo \"S $a\";; esac; done; done"
    }

    /// The local search, and one search per ssh destination run from the
    /// tmux host (BatchMode: never prompts; skipped if keys aren't set up).
    static func searchScript(localDirs: [String], destinations: [(label: String, args: [String])]) -> String {
        var script = listFunction + "\n"
        script += "T=; command -v timeout >/dev/null && T='timeout 15'\n"
        script += "D=$(mktemp -d)\n"
        for (i, dest) in destinations.enumerated() {
            let args = dest.args.map(shQuote).joined(separator: " ")
            script += "$T ssh -o BatchMode=yes -o ConnectTimeout=5 \(args) sh -s > \"$D/\(i)\" 2>/dev/null <<'ET_EOF' &\n"
            script += listFunction + "\netrepos\nET_EOF\n"
        }
        script += "echo 'H .'\netrepos \(localDirs.map(shQuote).joined(separator: " "))\nwait\n"
        for (i, dest) in destinations.enumerated() {
            script += "echo \(shQuote("H " + dest.label)); cat \"$D/\(i)\"\n"
        }
        script += "rm -rf \"$D\""
        return script
    }

    /// "ssh -p 2222 -t user@host tmux attach" → label "user@host", args
    /// to reach it (options that matter for connecting, then the host).
    static func destination(fromSSH command: String) -> (label: String, args: [String])? {
        var parts = command.split(separator: " ").map(String.init)
        guard !parts.isEmpty else { return nil }
        parts.removeFirst()
        let takesValue = Set("BbcDEeFIiJLlmOoPpQRSWw")
        let keep = Set("pliJoF")
        var args: [String] = []
        var i = 0
        while i < parts.count {
            let part = parts[i]
            if part.hasPrefix("-"), part.count >= 2 {
                let flag = part.last!
                if takesValue.contains(flag), part.count == 2, i + 1 < parts.count {
                    if keep.contains(flag) { args += [part, parts[i + 1]] }
                    i += 2
                } else {
                    i += 1
                }
                continue
            }
            guard part.allSatisfy({ $0.isLetter || $0.isNumber || "@.-_:".contains($0) }) else { return nil }
            return (part, args + [part])
        }
        return nil
    }

    /// Parses the search output into repos per host label.
    static func parse(_ output: String, localLabel: String) -> [DiscoveredRepo] {
        var repos: [DiscoveredRepo] = []
        var host = localLabel
        for line in output.split(separator: "\n") {
            if line.hasPrefix("H ") {
                let name = String(line.dropFirst(2))
                host = name == "." ? localLabel : name
            } else if line.hasPrefix("R ") {
                repos.append(DiscoveredRepo(host: host, name: String(line.dropFirst(2)), files: []))
            } else if line.hasPrefix("F "), !repos.isEmpty, repos[repos.count - 1].host == host {
                repos[repos.count - 1].files.append(String(line.dropFirst(2)))
            }
        }
        return repos
    }

    static func shQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}

// MARK: - Screen

/// "Dictation words": the user's own names, what was found on the servers,
/// the speech model's state, and a box to try a correction.
struct VocabularyView: View {
    /// The live session, for "Search again".
    let session: SessionController?
    @State private var vocabulary = Vocabulary.shared
    @State private var newText = ""
    @State private var newSoundsLike = ""
    @State private var trial = ""
    @State private var searching = false
    /// Mic for "say it the way you do".
    @State private var voice = VoiceInput()
    @State private var lastHeard: String?

    var body: some View {
        List {
            Section {
                TextField("Exact spelling, e.g. nam-shub", text: $newText)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                HStack {
                    TextField("Sounds like (optional), e.g. nom shub", text: $newSoundsLike)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button { Task { await toggleMic() } } label: {
                        Image(systemName: voice.state == .listening ? "stop.fill" : "mic.fill")
                            .foregroundStyle(voice.state == .listening ? .white : Color(Theme.background))
                            .frame(width: 34, height: 34)
                            .background(voice.state == .listening ? Color.red : Theme.accent, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(voice.state == .stopping)
                    .accessibilityLabel("Say the name")
                }
                if voice.state == .listening {
                    Text(voice.text.isEmpty ? "Say the name, then tap stop" : voice.text)
                        .font(.callout).foregroundStyle(.secondary)
                } else if let lastHeard {
                    Text(lastHeard).font(.caption).foregroundStyle(.secondary)
                }
                if let error = voice.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Button("Add") {
                    vocabulary.add(newText, soundsLike: newSoundsLike)
                    newText = ""
                    newSoundsLike = ""
                }
                .disabled(newText.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: {
                Text("Add a name")
            } footer: {
                Text("Tap the mic and say the name the way you normally would; what dictation hears becomes \"sounds like\". Say it a few times for more variants.")
            }
            if !vocabulary.custom.isEmpty {
                Section("Your names") {
                    ForEach(vocabulary.custom) { term in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(term.text).font(.body.monospaced())
                            if !term.soundsLike.isEmpty {
                                Text("sounds like: " + term.soundsLike.joined(separator: ", "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        offsets.map { vocabulary.custom[$0] }.forEach(vocabulary.remove)
                    }
                }
            }
            Section {
                TextField("Type what dictation heard", text: $trial, axis: .vertical)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                if !trial.isEmpty {
                    Text(vocabulary.correct(trial, tagFiles: true)).font(.callout.monospaced())
                }
            } header: {
                Text("Try it")
            } footer: {
                Text("Shows how a transcript is fixed after recording. In Claude windows, \"at <file>\" becomes an @path mention.")
            }
            Section {
                LabeledContent("Speech model", value: vocabulary.modelStatus)
                LabeledContent("Found", value: vocabulary.discoveryStatus)
                if let session {
                    Button(searching ? "Searching…" : "Search again") {
                        searching = true
                        Task {
                            await session.discoverVocabulary()
                            searching = false
                        }
                    }
                    .disabled(searching)
                }
                ForEach(Array(Set(vocabulary.repos.map { "\($0.name) · \($0.host)" })).sorted(), id: \.self) { repo in
                    Text(repo).font(.caption.monospaced())
                }
            } header: {
                Text("Found automatically")
            } footer: {
                Text("Git repos and their files on the tmux server and on hosts your windows ssh into, plus window names and unusual words on screen.")
            }
        }
        .navigationTitle("Dictation words")
        .onDisappear { if voice.state == .listening { Task { _ = await voice.stop() } } }
    }

    /// Records one saying of the name. What was heard is added to "sounds
    /// like" (and fills the spelling if it's still empty, to edit).
    private func toggleMic() async {
        switch voice.state {
        case .idle:
            lastHeard = nil
            await voice.start(contextualStrings: vocabulary.contextualStrings, languageModel: vocabulary.languageModel)
        case .listening:
            var heard = await voice.stop().lowercased()
            while let c = heard.last, ".,!?".contains(c) { heard.removeLast() }
            heard = heard.trimmingCharacters(in: .whitespaces)
            guard !heard.isEmpty else {
                lastHeard = "Didn't catch anything; try again."
                return
            }
            let spelling = newText.trimmingCharacters(in: .whitespaces)
            if spelling.isEmpty { newText = heard }
            if !spelling.isEmpty, heard == spelling.lowercased() {
                lastHeard = "Heard \"\(heard)\": already right."
                return
            }
            var alikes = newSoundsLike.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if !alikes.contains(heard) { alikes.append(heard) }
            newSoundsLike = alikes.filter { !$0.isEmpty }.joined(separator: ", ")
            lastHeard = "Heard \"\(heard)\""
        case .stopping:
            break
        }
    }
}

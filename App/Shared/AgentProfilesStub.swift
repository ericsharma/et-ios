import Foundation

// STUB (PLAN-multi-agent M1-B): et-link's §4.1 API, until A ships it in
// Vendor/etd. The names are §4.1's in uniffi's Swift spelling; once the
// generated et_link.swift has them, this file stops compiling
// (redeclarations) and is deleted. Iroh.swift then maps `host.agents()`.
//
// `agents()` runs `command -v` and the version command through
// `IrohHost.run`, as AG1's Agents script does. Transcript, state and
// alerts are what the apps can do today: Claude only.

/// One agent E.T. knows (D1, D2): how to find it, start it and type to it.
struct AgentProfile: Equatable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    var mark: String
    /// A Catppuccin Mocha color name (D8).
    var accent: String
    var launch: [String]
    /// Program names that mean "this agent runs".
    var processes: [String]
    var versionArgs: [String]
    /// The key wheel set, as titles ("esc", "⇧tab", "1", "↑", "^C", …).
    var keys: [String]
    /// "bracketed-paste" or "line-by-line".
    var multiline: String
    /// Dictation "at <file>" becomes this + path.
    var mention: String?
    /// Speaker's screen fallback for the start of a reply.
    var replyMarker: String?
    /// The command for one prompt without the TUI (watcher, digests).
    var headless: [String]
}

/// One agent on one machine (the Agents page's What works section).
struct AgentOnMachine: Equatable, Sendable, Identifiable {
    var id: String
    /// nil: not installed.
    var version: String?
    /// A Reader exists and found its files.
    var transcript: Bool
    /// "own", "hooks", "transcript" or "none".
    var state: String
    /// needs-you reaches etd (state "own" or "hooks").
    var alerts: Bool
    /// What to do for a missing part.
    var setupHint: String?
}

private let claudeKeys = ["esc", "⇧tab", "1", "2", "3", "↑", "↓", "enter", "^C"]

/// The built-ins (D1, D8), in this order everywhere.
func agentProfiles() -> [AgentProfile] {
    [
        AgentProfile(id: "claude", name: "Claude Code", mark: "C", accent: "peach",
                     launch: ["claude"], processes: ["claude"], versionArgs: ["--version"],
                     keys: claudeKeys, multiline: "bracketed-paste", mention: "@", replyMarker: "⏺",
                     headless: ["claude", "-p"]),
        // M0: check the keys, multi-line paste, mention and reply marker.
        AgentProfile(id: "codex", name: "Codex", mark: "X", accent: "green",
                     launch: ["codex"], processes: ["codex"], versionArgs: ["--version"],
                     keys: claudeKeys, multiline: "bracketed-paste", mention: "@", replyMarker: nil,
                     headless: ["codex", "exec"]),
        // M0: check the keys, multi-line paste, mention and reply marker.
        AgentProfile(id: "gemini", name: "Gemini CLI", mark: "G", accent: "blue",
                     launch: ["gemini"], processes: ["gemini"], versionArgs: ["--version"],
                     keys: claudeKeys, multiline: "bracketed-paste", mention: "@", replyMarker: nil,
                     headless: ["gemini", "-p"]),
        // M0: check the keys, multi-line paste, mention and reply marker.
        AgentProfile(id: "grok", name: "Grok Build", mark: "K", accent: "mauve",
                     launch: ["grok"], processes: ["grok"], versionArgs: ["--version"],
                     keys: claudeKeys, multiline: "bracketed-paste", mention: "@", replyMarker: nil,
                     headless: ["grok", "-p"]),
        // Owner's ask (2026-10-29), not in D1: Google's Antigravity CLI.
        // M0: check the keys, multi-line paste, mention and reply marker.
        AgentProfile(id: "antigravity", name: "Antigravity CLI", mark: "A", accent: "teal",
                     launch: ["agy"], processes: ["agy"], versionArgs: ["--version"],
                     keys: claudeKeys, multiline: "bracketed-paste", mention: "@", replyMarker: nil,
                     headless: ["agy", "-p"]),
    ]
}

extension IrohHost {
    /// The built-ins on this machine. Until `Request::Agents` (33): a script.
    func agents() async throws -> [AgentOnMachine] {
        let profiles = agentProfiles()
        let answer = try await run(Self.agentsScript(profiles))
        var found: [String: String] = [:]
        for line in answer.output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0].hasPrefix("agent:") else { continue }
            found[String(parts[0].dropFirst(6))] = String(parts[1])
        }
        let claudeFiles = answer.output.contains("claude-projects:yes")
        return profiles.map { profile in
            let version = found[profile.id].map(Self.versionNumber)
            let isClaude = profile.id == "claude"
            // Antigravity CLI and Grok Build: running sessions and usage on the Agents page.
            let isAgy = profile.id == "antigravity" || profile.id == "grok"
            let transcript = isClaude && claudeFiles
            let hint: String? = if version == nil {
                "\(profile.name) is not installed here, or not on etd's PATH."
            } else if isAgy {
                "E.T. shows \(profile.name) sessions and usage; it can't read its transcripts or state yet (PLAN-multi-agent M2, M3)."
            } else if !isClaude {
                "E.T. can't read \(profile.name) transcripts or state yet (PLAN-multi-agent M2, M3)."
            } else if !transcript {
                "No Claude transcripts here yet (~/.claude/projects)."
            } else {
                nil
            }
            return AgentOnMachine(id: profile.id, version: version, transcript: transcript,
                                  state: isClaude && version != nil ? "own" : "none",
                                  alerts: isClaude && version != nil, setupHint: hint)
        }
    }

    /// One `agent:<id>\t<version line>` per installed agent.
    nonisolated static func agentsScript(_ profiles: [AgentProfile]) -> String {
        var script = ""
        for profile in profiles {
            guard let exe = profile.launch.first else { continue }
            let args = profile.versionArgs.joined(separator: " ")
            script += "if command -v \(exe) >/dev/null 2>&1; then printf 'agent:\(profile.id)\\t%s\\n' \"$(\(exe) \(args) 2>/dev/null </dev/null | head -1)\"; fi\n"
        }
        script += "[ -d ~/.claude/projects ] && echo claude-projects:yes\n"
        return script
    }

    /// "2.1.4" from "2.1.4 (Claude Code)", "codex-cli 0.166.0", "grok 0.2.11 (3247ce8f833)".
    nonisolated static func versionNumber(_ line: String) -> String {
        let match = line.firstMatch(of: /\d+(\.\d+)+/)
        return match.map { String($0.output.0) } ?? line.trimmingCharacters(in: .whitespaces)
    }
}

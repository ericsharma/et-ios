#if os(macOS)
import Darwin
import Foundation

/// The `etd` CLI next to the app (or a test's build), run as a subprocess
/// (docs/PLAN-macos.md §4.2). `environment` adds to this process's own:
/// a test sets ETD_HOME, ETD_SOCKET and HOME there.
public struct EtdCLI: Sendable {
    public let executable: URL
    public let environment: [String: String]

    public init(executable: URL, environment: [String: String] = [:]) {
        self.executable = executable
        self.environment = environment
    }

    /// `etd-ssh`, installed next to `etd`.
    public var sshExecutable: URL {
        executable.deletingLastPathComponent().appendingPathComponent("etd-ssh")
    }

    public struct Failure: Error, CustomStringConvertible, Sendable {
        public let command: String
        public let status: Int32
        public let output: String

        public init(command: String, status: Int32, output: String) {
            self.command = command
            self.status = status
            self.output = output
        }

        public var description: String {
            let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "\(command) exited with \(status)" : text
        }
    }

    /// Runs `etd <arguments>`; stdout and stderr together. Throws on a
    /// non-zero exit, with etd's own words.
    @discardableResult
    public func run(_ arguments: [String], timeout: TimeInterval = 60) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        // An etd started from inside a tmux pane would talk to that tmux.
        env["TMUX"] = nil
        env["TMUX_PANE"] = nil
        env.merge(environment) { _, new in new }
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        // Read while it runs: a full pipe would block etd.
        let collected = OutputBuffer()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            collected.append(handle.availableData)
        }
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() > deadline {
                process.terminate()
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        process.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        collected.append(pipe.fileHandleForReading.readDataToEndOfFile())
        let output = collected.text
        guard process.terminationStatus == 0 else {
            throw Failure(command: "etd " + arguments.joined(separator: " "), status: process.terminationStatus, output: output)
        }
        return output
    }

    /// `etd status --json`.
    public func status() throws -> EtdStatus {
        let output = try run(["status", "--json"], timeout: 15)
        // etd may log a line before the JSON.
        guard let start = output.firstIndex(of: "{") else {
            throw Failure(command: "etd status --json", status: 0, output: output)
        }
        return try JSONDecoder().decode(EtdStatus.self, from: Data(output[start...].utf8))
    }

    /// An `et://pair` link, one use, valid 10 minutes.
    public func invite(machine: Bool) throws -> String {
        let output = try run(["invite"] + (machine ? ["--machine"] : []) + ["--url"], timeout: 15)
        guard let link = output.split(whereSeparator: \.isWhitespace).map(String.init).last(where: { $0.hasPrefix("et://") }) else {
            throw Failure(command: "etd invite --url", status: 0, output: output)
        }
        return link
    }

    /// `etd join <link> --name <name>`; returns etd's report (the member list).
    public func join(_ link: String, name: String) throws -> String {
        try run(["join", link, "--name", name], timeout: 60)
    }

    /// mm, the manymux node's LaunchAgent and MM_SSH, without etd's own service.
    public func installManymux() throws -> String {
        try run(["install", "--no-service"], timeout: 300)
    }

    /// Stops an `etd install` etd and removes its LaunchAgents (not the node).
    public func uninstall() throws -> String {
        try run(["uninstall"], timeout: 60)
    }
}

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.withLock { data.append(chunk) }
    }

    var text: String {
        lock.withLock { String(decoding: data, as: UTF8.self) }
    }
}

/// `etd status --json` (etd v0.0.2).
public struct EtdStatus: Decodable, Sendable, Equatable {
    public var running: Bool
    public var pid: Int?
    public var version: String?
    /// This machine's endpoint id.
    public var id: String?
    public var host: String?
    public var exe: String?
    public var manager: Manager?
    public var network: Network?

    public enum Manager: String, Decodable, Sendable {
        case nix, cli, app, manual, unknown

        public init(from decoder: any Decoder) throws {
            self = Manager(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }

        /// For the onboarding screen: "etd is managed by Nix".
        public var label: String {
            switch self {
            case .nix: "Nix"
            case .cli: "`etd install`"
            case .app: "E.T."
            case .manual, .unknown: "something else (started by hand?)"
            }
        }
    }

    public struct Network: Decodable, Sendable, Equatable {
        public var name: String
        public var members: [Member]
    }

    public struct Member: Decodable, Sendable, Equatable {
        public var name: String
        public var kind: String
        public var id: String
        public var isMachine: Bool { kind == "machine" }
    }

    /// Who manages the running etd. An etd older than v0.0.2 doesn't report
    /// its program, so its pid's program path is checked, with etd's rules
    /// (`service::manager`): the Nix store, an app bundle, a plist from
    /// `etd install`, else by hand.
    public var resolvedManager: Manager {
        if let manager, manager != .unknown { return manager }
        guard running, let path = exe ?? pid.flatMap(Self.programPath) else { return .unknown }
        if path.hasPrefix("/nix/store/") { return .nix }
        if path.contains(".app/Contents/") { return .app }
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/xyz.ericsharma.etd.plist")
        if let text = try? String(contentsOf: plist, encoding: .utf8),
           text.contains("Installed by etd install"), text.contains(path) {
            return .cli
        }
        return .manual
    }

    private static func programPath(_ pid: Int) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        let length = proc_pidpath(Int32(pid), &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    /// This machine's name in its network.
    public var machineName: String? {
        guard let id else { return nil }
        return network?.members.first { $0.id == id }?.name
    }

    /// The network has no other machine or device: show the network choice.
    public var isAlone: Bool {
        (network?.members.filter { $0.id != id }.isEmpty) ?? true
    }
}

/// The pieces of onboarding that aren't UI (docs/PLAN-macos.md §4.2–4.3).
public enum Onboarding {
    /// What to do about etd on this Mac (D4).
    public enum Plan: Equatable, Sendable {
        /// No etd: register the app's login item, then `etd install --no-service`.
        case install
        /// The app's own etd runs: make sure manymux is set up (idempotent).
        case ownEtd
        /// Another manager's etd runs (Nix, `etd install`, by hand): use it,
        /// install nothing. `canTakeOver`: an `etd install` setup E.T. may manage.
        case useExisting(EtdStatus.Manager, canTakeOver: Bool)
    }

    public static func plan(for status: EtdStatus) -> Plan {
        guard status.running else { return .install }
        let manager = status.resolvedManager
        switch manager {
        case .app: return .ownEtd
        case .cli: return .useExisting(.cli, canTakeOver: true)
        default: return .useExisting(manager, canTakeOver: false)
        }
    }

    /// A machine name from the host name: letters, digits, `.`, `_`, `-`
    /// ("Eric's MacBook Air.local" → "Erics-MacBook-Air").
    public static func machineName(fromHost host: String) -> String {
        var base = host
        if base.hasSuffix(".local") { base.removeLast(6) }
        var out = ""
        for c in base {
            if c.isASCII && (c.isLetter || c.isNumber || c == "." || c == "_" || c == "-") {
                out.append(c)
            } else if c == " " && !out.hasSuffix("-") {
                out.append("-")
            }
        }
        while out.hasSuffix("-") || out.hasSuffix(".") { out.removeLast() }
        return out.isEmpty ? "mac" : out
    }

    public static func isValidMachineName(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-") }
    }

    /// The app's own device name in the network: "m1-air app".
    public static func deviceName(machine: String) -> String {
        "\(machine) app"
    }

    /// etd's error from a failed join, in plain words (§4.3).
    public static func explainJoinFailure(_ output: String) -> String {
        let text = output.lowercased()
        if text.contains("phone or tablet") {
            return "This link is for a phone. Make one with `etd invite --machine`."
        }
        if text.contains("expired") {
            return "The link expired (links last 10 minutes). Make a new one."
        }
        if text.contains("used") || text.contains("unknown invite") || text.contains("refused") {
            return "The link was already used. Make a new one."
        }
        if text.contains("unreachable") || text.contains("timed out") || text.contains("connect") {
            return "The machine that made the link didn't answer. Is it on?"
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif

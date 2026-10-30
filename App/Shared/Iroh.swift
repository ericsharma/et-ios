import ETCore
import ETSSH
import EtLink
import Foundation
import Security

// The only file that imports EtLink: its `Link`, `SessionInfo`,
// `TmuxInstall` and `ControlEvent` clash with SwiftUI, ETSSH and ETCore.

/// A pairing link, read before the user confirms it.
struct PairingTicket: Sendable, Equatable {
    var hostName: String
    var endpointId: String
    var relayURL: String?
}

/// The app's one iroh endpoint, shared by all servers (PLAN-iroh §8.4).
/// Starting it takes seconds, so it starts at launch, in the background.
final class IrohLink: @unchecked Sendable {
    static let shared = IrohLink()

    private let lock = NSLock()
    private var startTask: Task<Link, any Error>?
    private var link: Link?

    var isStarted: Bool { lock.withLock { link != nil } }

    /// Starts the endpoint if it isn't started or starting. `done` gets a
    /// line for the debug log.
    func start(done: (@Sendable (String) -> Void)? = nil) {
        let task = startIfNeeded()
        Task {
            let began = Date()
            do {
                let link = try await task.value
                done?(String(format: "iroh endpoint %@… started in %.1f s", String(link.endpointId().prefix(8)), Date().timeIntervalSince(began)))
            } catch {
                done?("iroh endpoint failed to start: \(error)")
            }
        }
    }

    private func startIfNeeded() -> Task<Link, any Error> {
        lock.withLock {
            if let startTask { return startTask }
            let task = Task { try await Link.start(secretKey: try DeviceKey.loadOrCreate()) }
            startTask = task
            return task
        }
    }

    private func started() async throws -> Link {
        let task = startIfNeeded()
        do {
            let link = try await task.value
            lock.withLock { self.link = link }
            return link
        } catch {
            // Let the next connect try again.
            lock.withLock { if startTask == task { startTask = nil } }
            throw Self.map(error)
        }
    }

    static func ticket(from url: String) throws -> PairingTicket {
        do {
            let info = try parseTicket(url: url)
            return PairingTicket(hostName: info.hostName, endpointId: info.endpointId, relayURL: info.relayUrl)
        } catch {
            throw map(error)
        }
    }

    /// Sends the pairing secret. One use: a second try with the same link fails.
    func pair(url: String, deviceName: String) async throws -> PairingTicket {
        let link = try await started()
        do {
            let paired = try await link.pair(url: url, deviceName: deviceName)
            return PairingTicket(hostName: paired.hostName, endpointId: paired.endpointId, relayURL: paired.relayUrl)
        } catch {
            throw Self.map(error)
        }
    }

    func connect(endpointId: String, relayURL: String?) async throws -> IrohHost {
        let link = try await started()
        do {
            return IrohHost(try await link.connect(endpointId: endpointId, relayUrl: relayURL))
        } catch {
            throw Self.map(error)
        }
    }

    /// LinkError → HostError, so SessionController doesn't see EtLink types.
    static func map(_ error: any Error) -> any Error {
        guard let error = error as? LinkError else { return error }
        return switch error {
        case .NotPaired: HostError.notPaired
        case .Unreachable(let message): HostError.unreachable(message)
        case .Closed(let message): HostError.closed("Connection closed: \(message)")
        case .PairingRefused(let message): HostError.other("Pairing refused: \(message)")
        case .Remote(let message): HostError.other("etd: \(message)")
        case .Invalid(let message): HostError.other("Invalid: \(message)")
        case .Protocol(let message): HostError.other("Protocol error (update etd or E.T.?): \(message)")
        }
    }
}

/// A machine reached through etd over iroh.
final class IrohHost: HostConnection, @unchecked Sendable {
    private let host: RemoteHost

    init(_ host: RemoteHost) {
        self.host = host
    }

    /// "direct", "relay", or nil while there is no path.
    var pathLabel: String? {
        switch host.path().kind {
        case .direct: "direct"
        case .relay: "relay"
        case .none: nil
        }
    }

    func findTmux() async throws -> ETSSH.TmuxInstall {
        let info = try await mapped { try await host.hello(app: AppInfo.buildLabel) }
        guard let tmux = info.tmux else {
            throw SSHConnectionError.tmuxNotFound(output: info.tmuxError ?? "")
        }
        return ETSSH.TmuxInstall(path: tmux.path, version: tmux.version, tmpDir: tmux.tmpdir)
    }

    func listSessions(tmux: ETSSH.TmuxInstall) async throws -> [ETSSH.SessionInfo] {
        try await mapped { try await host.listSessions() }.compactMap { info in
            guard let id = SessionID(token: info.id) else { return nil }
            return ETSSH.SessionInfo(id: id, name: info.name, windowCount: Int(info.windows), attachedClients: Int(info.attached))
        }
    }

    func openControlChannel(tmux: ETSSH.TmuxInstall, target: ETSSH.ControlTarget) async throws -> OpenedControl {
        let target: EtLink.ControlTarget = switch target {
        case .attach(let name): .attach(name: name)
        case .attachOrCreate(let name): .attachOrCreate(name: name)
        }
        let channel = IrohControlChannel(try await mapped { try await host.openControl(target: target) })
        return OpenedControl(channel: channel, stderr: channel.stderr)
    }

    func run(_ command: String) async throws -> (output: String, exitCode: Int) {
        let result = try await mapped { try await host.exec(script: command) }
        return (String(decoding: result.output, as: UTF8.self), Int(result.exitCode ?? -1))
    }

    func upload(_ data: Data, to path: String) async throws {
        _ = try await mapped { try await host.upload(path: path, data: data) }
    }

    /// Sends local files and folders to ~/etd-downloads on this machine
    /// (PLAN-files F3). `session`: the manymux session the paths are for.
    func sendFiles(_ paths: [String], session: String?,
                   progress: @escaping @Sendable (UInt64, UInt64) -> Void) async throws -> SentFiles {
        let delivered = try await mapped {
            try await host.sendFiles(paths: paths, session: session, progress: ProgressRelay(progress))
        }
        return SentFiles(paths: delivered.paths, typed: delivered.typed)
    }

    // MARK: - Agents (PLAN-multi-agent §4.1)

    /// The built-ins on this machine: `Request::Agents` (33). An etd older
    /// than f98347b does not know the request; then a script finds them.
    func agents() async throws -> [AgentOnMachine] {
        do {
            return try await host.agents()
        } catch LinkError.Protocol {
            return try await scriptedAgents()
        } catch LinkError.Remote(let message) where message.contains("does not know this request") {
            return try await scriptedAgents()
        } catch {
            throw IrohLink.map(error)
        }
    }

    /// `command -v` and the version command for each profile, as AG1's
    /// Agents script does. Only Claude's transcript and state are known.
    private func scriptedAgents() async throws -> [AgentOnMachine] {
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
            let transcript = isClaude && claudeFiles
            let hint: String? = if version == nil {
                "\(profile.name) is not installed here, or not on etd's PATH."
            } else if !isClaude {
                "E.T. can't read \(profile.name) transcripts or state yet (PLAN-multi-agent M2, M3)."
            } else if !transcript {
                "No Claude transcripts here yet (~/.claude/projects)."
            } else {
                nil
            }
            return AgentOnMachine(id: profile.id, version: version, path: nil, transcript: transcript,
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

    // MARK: - Shared files (PLAN-files §4.7)

    /// The files sent to this machine that are still there, newest first.
    func sharedFiles() async throws -> [SharedItem] {
        try await mapped { try await host.sharedFiles() }.map {
            SharedItem(machine: $0.machine, path: $0.path, name: $0.name, size: $0.size, isDir: $0.isDir,
                       from: $0.from, received: Date(timeIntervalSince1970: TimeInterval($0.received)), session: $0.session)
        }
    }

    /// Copies a shared file from this machine into the local folder `into`;
    /// returns its local path.
    func fetchFile(_ path: String, into folder: String,
                   progress: @escaping @Sendable (UInt64, UInt64) -> Void) async throws -> String {
        try await mapped { try await host.fetchFile(path: path, into: folder, progress: ProgressRelay(progress)) }
    }

    /// A shared file again: typed into `session` here (`to` = this
    /// machine), or sent from here to `to` and typed there.
    func shareFile(_ path: String, to machine: String, session: String?,
                   progress: @escaping @Sendable (UInt64, UInt64) -> Void) async throws -> SentFiles {
        let delivered = try await mapped {
            try await host.shareFile(path: path, to: machine, session: session, progress: ProgressRelay(progress))
        }
        return SentFiles(paths: delivered.paths, typed: delivered.typed)
    }

    func unshareFile(_ path: String) async throws {
        try await mapped { try await host.unshareFile(path: path) }
    }

    func close() async {
        host.close()
    }

    /// Returns when the connection closes, with the reason.
    func waitClosed() async -> any Error {
        IrohLink.map(await host.closed())
    }

    // MARK: - manymux (PLAN-manymux §3; `machine: nil` = the hub)

    /// The hub's own host name, as etd reports it.
    func hostName() async throws -> String {
        try await mapped { try await host.hello(app: AppInfo.buildLabel) }.hostName
    }

    /// The other machines the hub watches.
    func machines() async throws -> [String] {
        try await mapped { try await host.machines() }
    }

    func mmList(machine: String?) async throws -> [MmSessionInfo] {
        try await mapped { try await host.mmList(machine: machine) }.map {
            MmSessionInfo(name: $0.name, title: $0.title, command: $0.command, attached: Int($0.attached),
                          idleSecs: Int($0.idleSecs), bells: Int($0.bells), started: Int($0.started),
                          cols: Int($0.cols), rows: Int($0.rows))
        }
    }

    /// Starts a session; returns the name it got. `command` empty = login shell.
    func mmSpawn(machine: String?, name: String?, command: [String], cols: Int, rows: Int) async throws -> String {
        let spec = MmSpawn(name: name, command: command, cwd: nil, cols: UInt16(clamping: cols), rows: UInt16(clamping: rows))
        return try await mapped { try await host.mmSpawn(machine: machine, spec: spec) }
    }

    func mmKill(machine: String?, name: String) async throws {
        try await mapped { try await host.mmKill(machine: machine, name: name) }
    }

    func mmRename(machine: String?, name: String, to newName: String) async throws {
        try await mapped { try await host.mmRename(machine: machine, name: name, to: newName) }
    }

    func mmAttach(machine: String?, name: String, cols: Int, rows: Int, history: Int, readOnly: Bool) async throws -> MmAttachHandle {
        let attachment = try await mapped {
            try await host.mmAttach(machine: machine, name: name, cols: UInt16(clamping: cols), rows: UInt16(clamping: rows),
                                    history: UInt32(clamping: history), readOnly: readOnly)
        }
        return MmAttachHandle(attachment)
    }

    /// Screens for thumbnails and instant paints; `names` empty = all.
    func mmPeek(machine: String?, names: [String]) async throws -> [MmScreen] {
        try await mapped { try await host.mmPeek(machine: machine, names: names) }.map {
            MmScreen(name: $0.name, cols: Int($0.cols), rows: Int($0.rows), bytes: Array($0.screen.utf8))
        }
    }

    /// `run`, on another machine (through ssh from the hub).
    func run(_ script: String, on machine: String) async throws -> (output: String, exitCode: Int) {
        let result = try await mapped { try await host.execOn(machine: machine, script: script) }
        return (String(decoding: result.output, as: UTF8.self), Int(result.exitCode ?? -1))
    }

    func mmEvents() async throws -> MmEventFeed {
        MmEventFeed(try await mapped { try await host.mmEvents() })
    }

    // MARK: - The etd network (PLAN-network §4.7)

    /// Every machine and device; the network key's signature is checked in EtLink.
    func network() async throws -> NetInfo {
        let info = try await mapped { try await host.network() }
        return NetInfo(name: info.name, key: info.key, members: info.members.map {
            NetMember(endpointId: $0.endpointId, name: $0.name, isMachine: $0.isMachine)
        }, archive: info.archive)
    }

    /// An `et://pair` link, valid 10 minutes, one use. `machine`: for
    /// `etd join <link>` on a new machine; else a phone or tablet.
    func invite(machine: Bool) async throws -> String {
        try await mapped { try await host.invite(machine: machine) }
    }

    /// "E.T. is open" for `seconds` (at most 120): no pushes from this machine until then.
    func foreground(seconds: Int) async throws {
        try await mapped { try await host.foreground(seconds: UInt32(clamping: seconds)) }
    }

    // MARK: - Logbook (PLAN-logbook §4.5; on the archive machine)

    /// Every recorded Claude session; `since`: changed after (unix seconds, 0 = all).
    func logbookSessions(since: UInt64) async throws -> [LogbookSession] {
        try await mapped { try await host.logbookSessions(since: since) }.map {
            LogbookSession(key: LogbookKey($0.key), mmSession: $0.mmSession, cwd: $0.cwd, repo: $0.repo, branch: $0.branch,
                           status: $0.status, first: Date(timeIntervalSince1970: TimeInterval($0.first)),
                           last: Date(timeIntervalSince1970: TimeInterval($0.last)), bytes: $0.bytes,
                           previous: $0.previous, paused: $0.paused, title: $0.title)
        }
    }

    /// A transcript's lines from byte `from`: the stored ones, then live.
    func logbookFollow(_ key: LogbookKey, from: UInt64) async throws -> LogbookFeed {
        LogbookFeed(try await mapped { try await host.logbookFollow(key: key.link, from: from) })
    }

    /// Do not record (D2): the session's machine stops sending its transcript.
    func logbookPause(machine: String, mmSession: String, paused: Bool) async throws {
        try await mapped { try await host.logbookPause(machine: machine, mmSession: mmSession, paused: paused) }
    }

    /// The report JSON (§4.4 + "id", "taken"). `refresh`: make a new one
    /// (1–3 min), with progress (stage, done, total).
    func logbookReport(refresh: Bool, progress: @escaping @Sendable (String, Int, Int) -> Void) async throws -> String {
        try await mapped { try await host.report(refresh: refresh, progress: ReportRelay(progress)) }
    }

    /// The owner accepts or edits a grouping (one §4.4 proposal, as JSON).
    func logbookGrouping(_ changeJSON: String) async throws {
        try await mapped { try await host.grouping(changeJson: changeJSON) }
    }

    /// Writes the selection as Markdown on the archive, sends it to
    /// `machine` and types its path into `session`.
    func logbookSend(_ selection: LogbookSelection, to machine: String, session: String) async throws -> SentFiles {
        let selection: LogSelection = switch selection {
        case .turns(let key, let ids): .turns(key: key.link, turnIds: ids)
        case .reportSection(let report, let project): .reportSection(reportId: report, projectId: project)
        }
        let delivered = try await mapped {
            try await host.logbookSend(selection: selection, to: machine, session: session, progress: ProgressRelay { _, _ in })
        }
        return SentFiles(paths: delivered.paths, typed: delivered.typed)
    }
}

extension LogbookKey {
    fileprivate init(_ key: LogKey) {
        self.init(machine: key.machine, sessionId: key.sessionId)
    }

    fileprivate var link: LogKey { LogKey(machine: machine, sessionId: sessionId) }
}

/// A followed transcript (EtLink's `LogStream`).
final class LogbookFeed: @unchecked Sendable {
    private let stream: LogStream

    init(_ stream: LogStream) {
        self.stream = stream
    }

    /// The next whole lines and the byte offset after them; `live`: the
    /// stored part is all read. Waits for new lines.
    func next() async throws -> (offset: UInt64, lines: [String], live: Bool) {
        let chunk = try await mapped { try await stream.next() }
        return (chunk.offset, chunk.lines, chunk.live)
    }

    /// Stops the follow on the archive.
    func close() {
        stream.close()
    }
}

struct NetMember: Sendable, Equatable, Identifiable {
    var endpointId: String
    var name: String
    /// A machine runs etd and has sessions; otherwise a phone or tablet.
    var isMachine: Bool
    var id: String { endpointId }
}

struct NetInfo: Sendable, Equatable {
    var name: String
    var key: String
    var members: [NetMember]
    /// The machines that keep the Logbook, first = the one to use (PLAN-logbook D6).
    var archive: [String] = []
}

/// A manymux session, as `mmList` reports it.
struct MmSessionInfo: Sendable, Equatable, Identifiable {
    var name: String
    /// What the program says it is doing (its terminal title).
    var title: String
    var command: String
    var attached: Int
    var idleSecs: Int
    var bells: Int
    var started: Int
    var cols: Int
    var rows: Int
    var id: String { name }
}

/// A session's screen from `mmPeek`: bytes that paint `cols` x `rows`.
struct MmScreen: Sendable {
    var name: String
    var cols: Int
    var rows: Int
    var bytes: [UInt8]
}

/// What a manymux event says happened.
enum MmEventKindInfo: Sendable, Equatable {
    case bell, notify(title: String, body: String), titleChanged(String), exited(Int), started
}

struct MmEventInfo: Sendable, Equatable {
    /// A host name; the hub's own name for the hub.
    var machine: String
    var session: String
    var title: String
    var kind: MmEventKindInfo
    var attached: Int

    init(_ event: MmEvent) {
        machine = event.machine
        session = event.session
        title = event.title
        attached = Int(event.attached)
        kind = switch event.kind {
        case .bell: .bell
        case .notify(let title, let body): .notify(title: title, body: body)
        case .titleChanged(let title): .titleChanged(title)
        case .exited(let code): .exited(Int(code))
        case .started: .started
        }
    }
}

/// Output of an attached manymux session.
enum MmOut: Sendable {
    /// Terminal bytes; the first after attaching repaints the screen.
    case data([UInt8])
    /// Scrollback, before the first `data`.
    case history([UInt8])
    /// The whole screen again: reset, then feed.
    case resync([UInt8])
    /// The size the session took.
    case size(cols: Int, rows: Int)
    case event(MmEventInfo)
    case renamed(name: String?, refused: String?)
    case exit(Int)
}

/// One attached manymux session (its own stream).
final class MmAttachHandle: @unchecked Sendable {
    private let attachment: MmAttachment

    init(_ attachment: MmAttachment) {
        self.attachment = attachment
    }

    var cols: Int { Int(attachment.cols()) }
    var rows: Int { Int(attachment.rows()) }

    func next() async throws -> MmOut {
        switch try await mapped({ try await attachment.next() }) {
        case .data(let bytes): .data(Array(bytes))
        case .history(let bytes): .history(Array(bytes))
        case .resync(let bytes): .resync(Array(bytes))
        case .size(let cols, let rows): .size(cols: Int(cols), rows: Int(rows))
        case .event(let event): .event(MmEventInfo(event))
        case .renamed(let name, let refused): .renamed(name: name, refused: refused)
        case .exit(let code): .exit(Int(code))
        }
    }

    func write(_ bytes: [UInt8]) async throws {
        try await mapped { try await attachment.write(bytes: Data(bytes)) }
    }

    func resize(cols: Int, rows: Int) async throws {
        try await mapped { try await attachment.resize(cols: UInt16(clamping: cols), rows: UInt16(clamping: rows)) }
    }

    func rename(to name: String) async throws {
        try await mapped { try await attachment.rename(to: name) }
    }

    /// `kind`: the file extension (png, jpg, gif, webp).
    func paste(kind: String, bytes: Data) async throws {
        try await mapped { try await attachment.paste(kind: kind, bytes: bytes) }
    }

    /// Leaves the session running.
    func detach() async {
        await attachment.detach()
    }
}

/// The hub's manymux event feed (all machines).
final class MmEventFeed: @unchecked Sendable {
    private let events: MmEvents

    init(_ events: MmEvents) {
        self.events = events
    }

    func next() async throws -> MmEventInfo {
        MmEventInfo(try await mapped { try await events.next() })
    }

    func close() async {
        await events.close()
    }
}

/// `tmux -C` on an etd control stream.
final class IrohControlChannel: ControlChannel, @unchecked Sendable {
    private let control: ControlStream
    private let stream: AsyncThrowingStream<[UInt8], any Error>
    let stderr: AsyncStream<String>

    init(_ control: ControlStream) {
        self.control = control
        let (stream, continuation) = AsyncThrowingStream<[UInt8], any Error>.makeStream(bufferingPolicy: .unbounded)
        let (stderr, stderrContinuation) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(200))
        self.stream = stream
        self.stderr = stderr
        Task {
            do {
                loop: while true {
                    switch try await control.next() {
                    case .stdout(let bytes): continuation.yield(Array(bytes))
                    case .stderr(let line): stderrContinuation.yield(line)
                    case .exit: break loop
                    }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: IrohLink.map(error))
            }
            stderrContinuation.finish()
        }
    }

    func incoming() -> AsyncThrowingStream<[UInt8], any Error> {
        stream
    }

    func write(_ bytes: [UInt8]) async throws {
        try await mapped { try await control.write(bytes: Data(bytes)) }
    }

    /// Closes tmux's stdin. tmux detaches; the session keeps running.
    func close() async {
        await control.finish()
    }
}

/// EtLink's `SharedFile`: a file or folder sent to a machine.
struct SharedItem: Sendable, Hashable, Identifiable {
    /// The network's name for the machine it is on.
    var machine: String
    var path: String
    var name: String
    var size: UInt64
    var isDir: Bool
    /// Who sent it (member name).
    var from: String
    var received: Date
    /// The session it was typed into, if any.
    var session: String?
    var id: String { machine + ":" + path }
}

/// EtLink's `Delivered`: the top-level paths in ~/etd-downloads on the
/// machine, and whether etd typed them into the session.
struct SentFiles: Sendable {
    var paths: [String]
    var typed: Bool
}

/// `SendProgress` as a closure.
private final class ProgressRelay: SendProgress {
    private let update: @Sendable (UInt64, UInt64) -> Void

    init(_ update: @escaping @Sendable (UInt64, UInt64) -> Void) {
        self.update = update
    }

    func onProgress(done: UInt64, total: UInt64) {
        update(done, total)
    }
}

/// `ReportProgress` as a closure.
private final class ReportRelay: ReportProgress {
    private let update: @Sendable (String, Int, Int) -> Void

    init(_ update: @escaping @Sendable (String, Int, Int) -> Void) {
        self.update = update
    }

    func onProgress(stage: String, done: UInt32, total: UInt32) {
        update(stage, Int(done), Int(total))
    }
}

private func mapped<T>(_ body: () async throws -> T) async throws -> T {
    do {
        return try await body()
    } catch {
        throw IrohLink.map(error)
    }
}

/// The device's iroh key: 32 bytes in the Keychain, this device only,
/// readable after the first unlock (PLAN-iroh §6.2). One key for all machines.
///
/// macOS: the data-protection keychain (the file-based login keychain asks
/// "allow access?" after every update). It needs a provisioning profile,
/// which a Developer ID build doesn't have: then the key is a 0600 file
/// in the app's own Application Support folder.
enum DeviceKey {
    private static let service = "xyz.ericsharma.et.iroh-key"
    private static let account = "default"

    /// iOS: the app and its share extension use one key, in the Keychain
    /// group `<team>.xyz.ericsharma.et` (the app's own default group, so the
    /// key made before the extension existed is found). Unsigned builds
    /// have no team prefix: then the default group.
    private static var accessGroup: String? {
        #if os(iOS)
        guard let group = Bundle.main.infoDictionary?["ETKeychainGroup"] as? String,
              !group.hasPrefix("xyz.") else { return nil }
        return group
        #else
        return nil
        #endif
    }

    static func loadOrCreate() throws -> Data {
        #if os(macOS)
        do {
            return try keychainLoadOrCreate()
        } catch let error as KeychainError where error.status == errSecMissingEntitlement {
            return try fileLoadOrCreate()
        }
        #else
        return try keychainLoadOrCreate()
        #endif
    }

    #if os(macOS)
    private static func fileLoadOrCreate() throws -> Data {
        let url = AppDirectory.url.appendingPathComponent("iroh-key")
        if let data = try? Data(contentsOf: url), data.count == 32 { return data }
        let key = generateSecretKey()
        try key.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return key
    }
    #endif

    private static func keychainLoadOrCreate() throws -> Data {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, data.count == 32 { return data }
        guard status == errSecItemNotFound else { throw KeychainError(status: status) }
        let key = generateSecretKey()
        var add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: key,
        ]
        #if os(macOS)
        add[kSecUseDataProtectionKeychain as String] = true
        #endif
        if let accessGroup { add[kSecAttrAccessGroup as String] = accessGroup }
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainError(status: added) }
        return key
    }

    struct KeychainError: Error, CustomStringConvertible {
        let status: OSStatus
        var description: String { "Keychain error \(status)" }
    }
}

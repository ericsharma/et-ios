import AppKit
import ETOnboarding
import ETSSH
import Foundation
import Observation
import ServiceManagement

/// First start and every start after (docs/PLAN-macos.md §4.2): this Mac as
/// a machine (etd + manymux), its network, and the app paired with its own
/// etd. Each step is idempotent.
@MainActor @Observable
final class Setup {
    enum Stage: Equatable {
        /// Running `etd status`.
        case looking
        /// The login item waits for the user in System Settings → Login Items.
        case needsApproval
        /// Registering the login item, installing manymux, pairing…
        case working(String)
        /// This Mac's network has only itself: Start a new network / Join (§4.3).
        case chooseNetwork
        /// After Start a new network: the QR code for the phone, or Skip.
        case addPhone
        /// The Machines screen.
        case done
        case failed(String)
    }

    private(set) var stage: Stage = .looking
    /// Who runs etd here (D4), for the onboarding and Settings.
    private(set) var manager: EtdStatus.Manager?
    private(set) var status: EtdStatus?
    /// Steps already done, with a check mark on the onboarding screen.
    private(set) var steps: [String] = []
    /// An etd from `etd install` runs: offer "Let E.T. manage etd".
    private(set) var canTakeOver = false
    /// Join a network: filled by an opened `et://pair` link.
    var joinLink = ""
    var joinName = ""
    private(set) var joinError: String?
    private(set) var isJoining = false
    private(set) var phoneInvite: String?

    @ObservationIgnored private let fleet: Fleet
    @ObservationIgnored private var approvalTask: Task<Void, Never>?

    static let agent = SMAppService.agent(plistName: "xyz.ericsharma.et.etd.plist")

    /// The bundled CLI; nil in a build without it.
    let cli: EtdCLI? = Bundle.main.url(forAuxiliaryExecutable: "etd").map { EtdCLI(executable: $0) }

    /// The bundled etd's version, written by scripts/bundle-etd-mac.sh.
    static let bundledEtdVersion: String? = Bundle.main.url(forResource: "etd-version", withExtension: nil)
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .flatMap { $0.isEmpty ? nil : $0 }

    init(fleet: Fleet) {
        self.fleet = fleet
        joinName = Onboarding.machineName(fromHost: Host.current().localizedName ?? ProcessInfo.processInfo.hostName)
    }

    // MARK: - The steps

    func start() {
        #if DEBUG
        // --stage <name>: show one onboarding screen, run nothing (layout checks).
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--stage"), args.indices.contains(i + 1) {
            steps = ["etd runs as E.T.'s login item", "manymux is set up"]
            switch args[i + 1] {
            case "approval": stage = .needsApproval
            case "join": joinLink = "et://pair?t=EXAMPLE"; stage = .chooseNetwork
            case "phone": phoneInvite = "et://pair?t=EXAMPLE-QR"; stage = .addPhone
            case "takeover": canTakeOver = true; stage = .working("Connecting…")
            default: stage = .chooseNetwork
            }
            return
        }
        #endif
        Task { await look() }
    }

    private func look() async {
        guard let cli else {
            stage = .failed("This build of E.T. has no etd inside it.")
            return
        }
        stage = .looking
        do {
            let status = try await Self.offMain { try cli.status() }
            self.status = status
            manager = status.running ? status.resolvedManager : nil
            fleet.log.add("etd: \(status.running ? "runs, managed by \(status.resolvedManager.rawValue), version \(status.version ?? "?")" : "not running")")
            switch Onboarding.plan(for: status) {
            case .install:
                await install(cli)
            case .ownEtd:
                await ensureAgent()
                await restartIfOld(cli, running: status.version)
                await setUpManymux(cli)
                await afterEtd(cli)
            case .useExisting(let manager, let takeOver):
                canTakeOver = takeOver
                steps.append("etd runs here, managed by \(manager.label). E.T. uses it and installs nothing.")
                await afterEtd(cli)
            }
        } catch {
            stage = .failed("Couldn't ask etd: \(error)")
        }
    }

    /// No etd: the login item, then manymux.
    private func install(_ cli: EtdCLI) async {
        stage = .working("Making this Mac a machine…")
        await ensureAgent()
        guard Self.agent.status == .enabled else { return }
        guard await waitForEtd(cli) else {
            stage = .failed("etd didn't start. See ~/Library/Logs/etd.log.")
            return
        }
        steps.append("etd runs as E.T.'s login item")
        await setUpManymux(cli)
        await afterEtd(cli)
    }

    /// Registers the login item; asks for approval when macOS wants it.
    private func ensureAgent() async {
        let agent = Self.agent
        if agent.status != .enabled {
            do {
                try agent.register()
                fleet.log.add("Login item registered: \(Self.describe(agent.status))")
            } catch {
                fleet.log.add("Login item: \(error) (\(Self.describe(agent.status)))")
            }
        }
        if agent.status == .requiresApproval {
            stage = .needsApproval
            waitForApproval()
        }
    }

    /// After an app update the login item still runs the etd it started
    /// with; launchd restarts it on the new binary (KeepAlive). Only E.T.'s
    /// own login item: an etd from Nix, brew or the CLI is left alone.
    private func restartIfOld(_ cli: EtdCLI, running old: String?) async {
        guard let new = Self.bundledEtdVersion, old != new, Self.agent.status == .enabled else { return }
        stage = .working("Updating etd…")
        do {
            try await Self.offMain { try Self.kickstartAgent() }
        } catch {
            fleet.log.add("etd restart failed: \(error)")
            return
        }
        guard await waitForEtd(cli, version: new) else {
            fleet.log.add("etd restart: etd \(new) didn't come up. See ~/Library/Logs/etd.log.")
            return
        }
        fleet.log.add("etd restarted: \(old ?? "?") -> \(status?.version ?? "?")")
    }

    /// `launchctl kickstart -k gui/<uid>/xyz.ericsharma.et.etd`.
    nonisolated private static func kickstartAgent() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["kickstart", "-k", "gui/\(getuid())/xyz.ericsharma.et.etd"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw EtdCLI.Failure(command: "launchctl kickstart", status: process.terminationStatus, output: output)
        }
    }

    /// Polls until the user turns E.T. on in Login Items.
    private func waitForApproval() {
        approvalTask?.cancel()
        approvalTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Self.agent.status == .enabled {
                    fleet.log.add("Login item approved")
                    await look()
                    return
                }
            }
        }
    }

    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// `version`: also until that etd answers, not the one before it.
    private func waitForEtd(_ cli: EtdCLI, version: String? = nil) async -> Bool {
        for _ in 0..<60 {
            if let status = try? await Self.offMain({ try cli.status() }), status.running,
               version == nil || status.version == version {
                self.status = status
                manager = status.resolvedManager
                return true
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    /// mm, the node's LaunchAgent and MM_SSH (`etd install --no-service`).
    /// Again at each start: an app that moved needs a new MM_SSH path.
    private func setUpManymux(_ cli: EtdCLI) async {
        stage = .working("Setting up manymux…")
        do {
            let output = try await Self.offMain { try cli.installManymux() }
            fleet.log.add("etd install --no-service: \(output.split(separator: "\n").joined(separator: " | "))")
            steps.append("manymux is set up")
        } catch {
            fleet.log.add("etd install --no-service failed: \(error)")
            steps.append("manymux: \(error)")
        }
    }

    /// The network, then the app's own pairing.
    private func afterEtd(_ cli: EtdCLI) async {
        guard let status = try? await Self.offMain({ try cli.status() }) else { return }
        self.status = status
        if status.isAlone && manager == .app {
            stage = .chooseNetwork
            return
        }
        await pairApp(cli, status: status)
        if stage != .addPhone, case .working = stage { stage = .done }
    }

    /// `etd invite --url` → `Link.pair(url, "<machine> app")`. Skipped when
    /// the app is already paired with this Mac's etd.
    private func pairApp(_ cli: EtdCLI, status: EtdStatus) async {
        guard let id = status.id else { return }
        if fleet.hub?.irohEndpointId == id {
            if fleet.phase == .unpaired { fleet.connect() }
            if case .working = stage {} else { stage = .working("Connecting…") }
            return
        }
        stage = .working("Pairing E.T. with this Mac…")
        let machine = status.machineName ?? Onboarding.machineName(fromHost: status.host ?? "mac")
        do {
            let url = try await Self.offMain { try cli.invite(machine: false) }
            let paired = try await IrohLink.shared.pair(url: url, deviceName: Onboarding.deviceName(machine: machine))
            fleet.log.add("Paired with \(machine) (\(paired.endpointId.prefix(8)))")
            fleet.adopt(name: machine, endpointId: paired.endpointId, relayURL: paired.relayURL)
            steps.append("E.T. is paired with \(machine)")
        } catch {
            stage = .failed("Pairing E.T. with this Mac failed: \(Fleet.describe(error))")
        }
    }

    // MARK: - Network choice (§4.3)

    /// Start a new network: this Mac's etd made one at its first start.
    func startNewNetwork() {
        guard let cli else { return }
        Task {
            stage = .working("Creating the network…")
            guard let status = try? await Self.offMain({ try cli.status() }) else { return }
            await pairApp(cli, status: status)
            if case .failed = stage { return }
            phoneInvite = try? await Self.offMain { try cli.invite(machine: false) }
            stage = .addPhone
        }
    }

    /// A new phone link (they last 10 minutes).
    func refreshPhoneInvite() {
        guard let cli else { return }
        Task { phoneInvite = try? await Self.offMain { try cli.invite(machine: false) } }
    }

    func finishAddPhone() {
        stage = .done
    }

    /// An `et://pair` link opened from elsewhere: the Join field.
    func receive(link: String) {
        joinLink = link.trimmingCharacters(in: .whitespacesAndNewlines)
        joinError = nil
    }

    /// The clipboard holds an `et://pair` link: offer Paste.
    var clipboardLink: String? {
        guard let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              text.hasPrefix("et://pair") else { return nil }
        return text
    }

    func join() {
        guard let cli, !isJoining else { return }
        let link = joinLink.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = joinName.trimmingCharacters(in: .whitespaces)
        guard Onboarding.isValidMachineName(name) else {
            joinError = "A machine name has only letters, digits, “.”, “_” and “-”."
            return
        }
        isJoining = true
        joinError = nil
        Task {
            defer { isJoining = false }
            do {
                let output = try await Self.offMain { try cli.join(link, name: name) }
                fleet.log.add("etd join: \(output.split(separator: "\n").joined(separator: " | "))")
                steps.append(output.split(separator: "\n").first.map(String.init) ?? "Joined")
                // etd takes the new network; wait until its status shows it.
                var status = try await Self.offMain { try cli.status() }
                for _ in 0..<50 where status.isAlone {
                    try? await Task.sleep(for: .milliseconds(200))
                    status = try await Self.offMain { try cli.status() }
                }
                self.status = status
                await pairApp(cli, status: status)
                if case .working = stage { stage = .done }
            } catch let error as EtdCLI.Failure {
                joinError = Onboarding.explainJoinFailure(error.output)
            } catch {
                joinError = "\(error)"
            }
        }
    }

    // MARK: - Let E.T. manage etd (D4, an `etd install` setup)

    /// Stops the CLI's etd (`etd uninstall`: its LaunchAgents, not the node)
    /// and runs the same etd home as E.T.'s login item: same key, same network.
    func takeOver() {
        guard let cli, canTakeOver else { return }
        Task {
            stage = .working("Moving etd to E.T.…")
            do {
                let output = try await Self.offMain { try cli.uninstall() }
                fleet.log.add("etd uninstall: \(output.split(separator: "\n").joined(separator: " | "))")
            } catch {
                stage = .failed("etd uninstall failed: \(error)")
                return
            }
            canTakeOver = false
            steps = []
            await look()
        }
    }

    // MARK: - Helpers

    nonisolated private static func offMain<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try body() }.value
    }

    static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: "not registered"
        case .enabled: "enabled"
        case .requiresApproval: "waiting for approval in Login Items"
        case .notFound: "not found"
        @unknown default: "unknown"
        }
    }
}

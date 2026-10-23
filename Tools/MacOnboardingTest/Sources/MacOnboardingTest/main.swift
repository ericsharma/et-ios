// docs/PLAN-macos.md §6: onboarding (§4.2) without the UI, against
// temporary etds. scripts/mac-onboarding-test makes the directories and the
// wrappers, and passes them in the environment:
//   T          the temporary root
//   ETD_BIN    the directory with the freshly built etd and etd-ssh
//   LOGIN_SH   a login shell whose PATH starts with the wrapper `mm`
//              (`mm … --socket $T/mm.sock`): no etd here reaches the real node
import ETOnboarding
import EtLink
import Foundation

let env = ProcessInfo.processInfo.environment
let root = URL(fileURLWithPath: env["T"]!)
let etdBin = URL(fileURLWithPath: env["ETD_BIN"]!)
let loginShell = env["LOGIN_SH"]!
let etd = etdBin.appendingPathComponent("etd")

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print(ok ? "  ok    \(what)" : "  FAIL  \(what)")
    if !ok { failures += 1 }
}

/// One temporary etd: its ETD_HOME, socket, HOME and log.
struct Place {
    let name: String
    var dir: URL { root.appendingPathComponent(name) }
    var environment: [String: String] {
        [
            "ETD_HOME": dir.appendingPathComponent("etd").path,
            "ETD_SOCKET": root.appendingPathComponent("\(name).sock").path,
            "HOME": dir.appendingPathComponent("home").path,
            "SHELL": loginShell,
            "MM_CONFIG_DIR": dir.appendingPathComponent("mm-config").path,
            "ETD_LOG_FILE": dir.appendingPathComponent("etd.log").path,
        ]
    }
    var cli: EtdCLI { EtdCLI(executable: etd, environment: environment) }
}

/// etds this test started; the shell kills them too if the test dies.
var started: [Process] = []
func startEtd(_ place: Place) throws {
    for sub in ["etd", "home"] {
        try FileManager.default.createDirectory(at: place.dir.appendingPathComponent(sub), withIntermediateDirectories: true)
    }
    let process = Process()
    process.executableURL = etd
    var e = ProcessInfo.processInfo.environment
    e["TMUX"] = nil
    e["TMUX_PANE"] = nil
    e.merge(place.environment) { _, new in new }
    process.environment = e
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    started.append(process)
    try "\(process.processIdentifier)\n".appendLine(to: root.appendingPathComponent("pids"))
    for _ in 0..<100 {
        if (try? place.cli.status())?.running == true { return }
        Thread.sleep(forTimeInterval: 0.2)
    }
    throw EtdCLI.Failure(command: "start etd (\(place.name))", status: -1, output: "not running after 20 s; see \(place.dir.path)/etd.log")
}

func stopEtd(_ place: Place) {
    for p in started where p.isRunning && p.environment?["ETD_HOME"] == place.environment["ETD_HOME"] {
        p.terminate()
        p.waitUntilExit()
    }
}

extension String {
    func appendLine(to url: URL) throws {
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(utf8))
        } else {
            try write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

func run() async throws {
    let hub = Place(name: "hub")
    let mac = Place(name: "mac")
    let hostName = ProcessInfo.processInfo.hostName

    print("1. The hub (an existing network)")
    try startEtd(hub)
    let hubStatus = try hub.cli.status()
    check(hubStatus.running && hubStatus.id != nil, "hub etd runs, id \(hubStatus.id?.prefix(8) ?? "?")")

    print("2. Look (§4.2 step 1): no etd on the new Mac")
    let before = try mac.cli.status()
    check(!before.running, "status says not running")
    check(Onboarding.plan(for: before) == .install, "plan: install")

    print("3. Make this Mac a machine (step 2): etd, then `etd install --no-service`")
    // The app registers its SMAppService agent here; the test starts etd itself.
    try startEtd(mac)
    let running = try mac.cli.status()
    check(running.running, "etd runs (pid \(running.pid ?? 0))")
    check(running.isAlone, "its network has only itself")
    // etd picks the startup file from $SHELL (zsh: ~/.zshenv, in the temporary HOME).
    var installEnv = mac.environment
    installEnv["SHELL"] = "/bin/zsh"
    let install = try EtdCLI(executable: etd, environment: installEnv).installManymux()
    let zshenv = (try? String(contentsOf: mac.dir.appendingPathComponent("home/.zshenv"), encoding: .utf8)) ?? ""
    check(zshenv.contains("MM_SSH='\(etdBin.appendingPathComponent("etd-ssh").path)'"), "MM_SSH points at the bundled etd-ssh")
    check(install.contains("--no-service"), "install --no-service: \(install.split(separator: "\n").last ?? "")")
    let plists = (try? FileManager.default.contentsOfDirectory(atPath: mac.dir.appendingPathComponent("home/Library/LaunchAgents").path)) ?? []
    check(!plists.contains { $0.hasPrefix("xyz.ericsharma.etd.plist") }, "no etd LaunchAgent written (the app's agent runs etd)")

    print("4. Join a network (§4.3) with a phone link: refused with a reason")
    let phoneLink = try hub.cli.invite(machine: false)
    do {
        _ = try mac.cli.join(phoneLink, name: "test-mac")
        check(false, "joining with a phone link fails")
    } catch let error as EtdCLI.Failure {
        let words = Onboarding.explainJoinFailure(error.output)
        check(words.contains("for a phone"), "explained: \(words)")
    }

    print("5. Join a network with a machine link")
    let machineLink = try hub.cli.invite(machine: true)
    let joined = try mac.cli.join(machineLink, name: "test-mac")
    check(joined.contains("joined the network"), joined.split(separator: "\n").first.map(String.init) ?? "")
    var afterJoin = try mac.cli.status()
    for _ in 0..<50 where afterJoin.isAlone {
        try await Task.sleep(for: .milliseconds(200))
        afterJoin = try mac.cli.status()
    }
    check(!afterJoin.isAlone, "the new Mac's network has the hub")
    check(afterJoin.machineName == "test-mac", "this machine's name: \(afterJoin.machineName ?? "?")")

    print("6. Pair the app (step 4)")
    let link = try await Link.start(secretKey: generateSecretKey())
    let deviceLink = try mac.cli.invite(machine: false)
    let deviceName = Onboarding.deviceName(machine: afterJoin.machineName ?? "test-mac")
    let paired = try await link.pair(url: deviceLink, deviceName: deviceName)
    check(paired.endpointId == afterJoin.id, "paired with the new Mac's etd as \"\(deviceName)\"")
    let own = try await link.connect(endpointId: paired.endpointId, relayUrl: paired.relayUrl)
    var names: [String] = []
    for _ in 0..<50 {
        names = try await own.network().members.map(\.name).sorted()
        if names.contains(deviceName) && names.count >= 3 { break }
        try await Task.sleep(for: .milliseconds(200))
    }
    let hubName = hubStatus.machineName ?? hostName
    check(names.contains(hubName) && names.contains("test-mac") && names.contains(deviceName),
          "Link.network(): \(names.joined(separator: ", "))")

    print("7. ExecOn from the hub to the new Mac")
    // The new member reaches the hub when the two machines sync the network.
    let began = Date()
    var hubKnows = false
    for _ in 0..<150 {
        if let members = try? hub.cli.status().network?.members.map(\.name), members.contains(deviceName) {
            hubKnows = true
            break
        }
        try await Task.sleep(for: .milliseconds(200))
    }
    check(hubKnows, String(format: "the hub lists \"\(deviceName)\" (after %.1f s)", Date().timeIntervalSince(began)))
    let hubHost = try await link.connect(endpointId: hubStatus.id!, relayUrl: nil)
    var output = ""
    var lastError = ""
    for _ in 0..<20 {
        do {
            let result = try await hubHost.execOn(machine: "test-mac", script: "hostname")
            output = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            lastError = "exit \(result.exitCode.map(String.init) ?? "?")"
            if !output.isEmpty { break }
        } catch {
            lastError = "\(error)"
        }
        try await Task.sleep(for: .milliseconds(500))
    }
    if output.isEmpty { print("        last: \(lastError)") }
    check(!output.isEmpty, "hostname on test-mac: \(output)")
    hubHost.close()
    own.close()

    print("8. A CLI-style setup (`etd install`): detected, then taken over")
    let cliPlace = Place(name: "cli")
    try startEtd(cliPlace)
    let agents = cliPlace.dir.appendingPathComponent("home/Library/LaunchAgents")
    try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
    // The plist `etd install` writes, by its marker and program path.
    try """
    <?xml version="1.0" encoding="UTF-8"?>
    <!-- Installed by etd install -->
    <plist version="1.0"><dict><key>Label</key><string>xyz.ericsharma.etd</string>
    <key>ProgramArguments</key><array><string>\(etd.resolvingSymlinksInPath().path)</string></array></dict></plist>
    """.write(to: agents.appendingPathComponent("xyz.ericsharma.etd.plist"), atomically: true, encoding: .utf8)
    let cliStatus = try cliPlace.cli.status()
    check(Onboarding.plan(for: cliStatus) == .useExisting(.cli, canTakeOver: true), "plan: use it, offer the takeover (manager \(cliStatus.resolvedManager.rawValue))")
    // Takeover: the app runs `etd uninstall` (launchctl, so not here: stop it
    // and remove its plist), then starts etd as its own agent, same ETD_HOME.
    stopEtd(cliPlace)
    try FileManager.default.removeItem(at: agents.appendingPathComponent("xyz.ericsharma.etd.plist"))
    try startEtd(cliPlace)
    let taken = try cliPlace.cli.status()
    check(taken.id == cliStatus.id, "same id after the takeover")
    check(taken.network?.name == cliStatus.network?.name, "same network (\(taken.network?.name ?? "?"))")

    print("9. The machine name rules")
    check(Onboarding.machineName(fromHost: "Eric's MacBook Air.local") == "Erics-MacBook-Air", "host name → Erics-MacBook-Air")
    check(!Onboarding.isValidMachineName("m1 air") && Onboarding.isValidMachineName("m1-air"), "names with spaces are refused")
}

do {
    try await run()
} catch {
    print("  FAIL  \(error)")
    failures += 1
}
for p in started where p.isRunning {
    p.terminate()
    p.waitUntilExit()
}
print(failures == 0 ? "PASS" : "FAILED: \(failures)")
exit(failures == 0 ? 0 : 1)

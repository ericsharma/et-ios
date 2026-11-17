import AppKit
import SwiftUI
import UserNotifications

@main
struct ETMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var fleet: Fleet
    @State private var setup: Setup
    @State private var files: SharedFiles
    @State private var logbook: Logbook
    @State private var agents: Agents

    init() {
        let fleet = Fleet()
        _fleet = State(initialValue: fleet)
        let setup = Setup(fleet: fleet)
        _setup = State(initialValue: setup)
        // Before application(_:open:) on a launch by Open With.
        AppDelegate.fleet = fleet
        AppDelegate.setup = setup
        let files = SharedFiles(hosts: { fleet.directHosts() }, log: { fleet.log.add($0) })
        _files = State(initialValue: files)
        let logbook = Logbook(archive: { fleet.archiveHost() }, hosts: { fleet.directHosts() }, log: { fleet.log.add($0) })
        _logbook = State(initialValue: logbook)
        let agents = Agents(hosts: { fleet.directHosts() }, log: { fleet.log.add($0) })
        _agents = State(initialValue: agents)
        #if DEBUG
        DebugHooks.logbook = logbook
        #endif
        #if DEBUG
        if CommandLine.arguments.contains("--offscreen") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                DebugHooks.offscreen(MainWindow(initial: nil).environment(fleet).environment(setup).environment(files).environment(logbook).environment(agents), fleet: fleet, setup: setup)
            }
        }
        #endif
    }

    var body: some Scene {
        // ⌘N: a new window; "Open in New Window" passes the session.
        WindowGroup("E.T.", for: SessionRef.self) { $ref in
            MainWindow(initial: ref)
                .environment(fleet)
                .environment(setup)
                .environment(files)
                .environment(logbook)
                .environment(agents)
                .onAppear {
                    started()
                    #if DEBUG
                    DebugHooks.run(fleet)
                    #endif
                }
        }
        .defaultSize(width: 1100, height: 700)
        // AppDelegate.application(_:open:) takes the URLs; each scene only
        // names the ones it opens for, or SwiftUI opens a window here per file.
        .handlesExternalEvents(matching: ["et:"])
        .commands { ETCommands(fleet: fleet) }

        Settings {
            SettingsView()
                .environment(fleet)
                .environment(setup)
        }

        // Files dropped on the Dock icon or opened with E.T. in Finder (all of
        // them in this one window); a cold launch may show only this window.
        Window("Send Files", id: "send") {
            SendFilesWindow()
                .environment(fleet)
                .onAppear { started() }
        }
        .windowResizability(.contentSize)
        .handlesExternalEvents(matching: ["file:"])

        // PLAN-logbook-v2 D2: beside the terminals, not in place of them.
        Window("Logbook", id: "logbook") {
            LogbookScene()
                .environment(fleet)
                .environment(logbook)
        }
        .defaultSize(width: 1200, height: 760)
        .keyboardShortcut("l", modifiers: [.command, .shift])
        .handlesExternalEvents(matching: [])

        Window("Debug Log", id: "log") {
            LogView()
                .environment(fleet)
        }
        .defaultSize(width: 800, height: 500)
        .handlesExternalEvents(matching: [])
    }

    private func started() {
        AppDelegate.fleet = fleet
        if !AppDelegate.setupStarted {
            AppDelegate.setupStarted = true
            setup.start()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor static weak var fleet: Fleet?
    @MainActor static var setupStarted = false
    @MainActor static weak var setup: Setup?

    /// Dock drops, Finder Open With and et:// links. Several files come in
    /// one call (onOpenURL would see only the first).
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls where url.scheme == "et" { AppDelegate.setup?.receive(link: url.absoluteString) }
            let files = urls.filter(\.isFileURL)
            guard let fleet = AppDelegate.fleet, !files.isEmpty else { return }
            fleet.log.add("Opened \(files.count) file(s) to send")
            fleet.queueSend(files)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            NSLog("ETMAC windows: %@", "\(NSApp.windows.map { "\(type(of: $0)) visible=\($0.isVisible) frame=\($0.frame)" })")
        }
    }

    /// A tapped bell notification: show its session.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let machine = info["machine"] as? String, let session = info["session"] as? String else { return }
        let ref = SessionRef(machine: machine, name: session)
        await MainActor.run {
            NSApp.activate()
            AppDelegate.fleet?.requestedRef = ref
        }
    }
}

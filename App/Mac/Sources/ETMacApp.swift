import AppKit
import SwiftUI
import UserNotifications

@main
struct ETMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var fleet: Fleet
    @State private var setup: Setup
    @State private var files: SharedFiles

    init() {
        let fleet = Fleet()
        _fleet = State(initialValue: fleet)
        _setup = State(initialValue: Setup(fleet: fleet))
        _files = State(initialValue: SharedFiles(hosts: { fleet.directHosts() }, log: { fleet.log.add($0) }))
    }

    var body: some Scene {
        // ⌘N: a new window; "Open in New Window" passes the session.
        WindowGroup("E.T.", for: SessionRef.self) { $ref in
            MainWindow(initial: ref)
                .environment(fleet)
                .environment(setup)
                .environment(files)
                .onAppear {
                    AppDelegate.fleet = fleet
                    if !AppDelegate.setupStarted {
                        AppDelegate.setupStarted = true
                        setup.start()
                    }
                    #if DEBUG
                    DebugHooks.run(fleet)
                    #endif
                }
                .onOpenURL { url in
                    if url.scheme == "et" { setup.receive(link: url.absoluteString) }
                }
        }
        .defaultSize(width: 1100, height: 700)
        .commands { ETCommands(fleet: fleet) }

        Settings {
            SettingsView()
                .environment(fleet)
                .environment(setup)
        }

        Window("Send Files", id: "send") {
            SendFilesWindow()
                .environment(fleet)
        }
        .windowResizability(.contentSize)

        Window("Debug Log", id: "log") {
            LogView()
                .environment(fleet)
        }
        .defaultSize(width: 800, height: 500)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor static weak var fleet: Fleet?
    @MainActor static var setupStarted = false

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

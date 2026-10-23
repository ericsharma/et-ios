import AppKit
import SwiftUI
import UserNotifications

@main
struct ETMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var fleet = Fleet()

    var body: some Scene {
        // ⌘N: a new window; "Open in New Window" passes the session.
        WindowGroup("E.T.", for: SessionRef.self) { $ref in
            MainWindow(initial: ref)
                .environment(fleet)
                .onAppear {
                    AppDelegate.fleet = fleet
                    #if DEBUG
                    DebugHooks.run(fleet)
                    #endif
                }
                .onOpenURL { url in
                    if url.scheme == "et" { fleet.receivePairingLink(url.absoluteString) }
                }
        }
        .defaultSize(width: 1100, height: 700)
        .commands { ETCommands(fleet: fleet) }

        Settings {
            SettingsView()
                .environment(fleet)
        }

        Window("Debug Log", id: "log") {
            LogView()
                .environment(fleet)
        }
        .defaultSize(width: 800, height: 500)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor static weak var fleet: Fleet?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
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

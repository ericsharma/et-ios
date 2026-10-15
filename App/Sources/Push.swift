import UIKit
import UserNotifications

/// Push notifications (bells from trigkey's tmux, see nixos-config
/// et-notify). The device token is written to the server over SSH by
/// `SessionController`; there is no other backend.
@MainActor @Observable
final class Push: NSObject {
    static let shared = Push()

    /// Hex APNs token, once iOS hands it out.
    private(set) var token: String?
    /// Window name from a tapped notification; the session opens it.
    var pendingWindowName: String?

    /// What a tapped notification points at (sent by et-notify).
    struct OpenRequest {
        var server: UUID?
        var session: String?
        var window: String?
    }

    /// Set by AppModel; until then a tap is kept in `pendingOpen`.
    var onOpen: ((OpenRequest) -> Void)? {
        didSet {
            if let onOpen, let request = pendingOpen {
                pendingOpen = nil
                onOpen(request)
            }
        }
    }
    private var pendingOpen: OpenRequest?

    fileprivate func open(_ request: OpenRequest) {
        if let onOpen { onOpen(request) } else { pendingOpen = request }
    }

    /// Sandbox for Xcode builds, production for TestFlight / App Store.
    static var environment: String {
        #if DEBUG
        "development"
        #else
        "production"
        #endif
    }

    func register() {
        UNUserNotificationCenter.current().delegate = self
        Task {
            let granted = (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            if granted { UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    func didRegister(token data: Data) {
        token = data.map { String(format: "%02x", $0) }.joined()
    }
}

extension Push: UNUserNotificationCenterDelegate {
    /// E.T. is open: trigkey normally skips the push then; if one arrives
    /// anyway, show it.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let request = Push.OpenRequest(
            server: (info["server"] as? String).flatMap(UUID.init(uuidString:)),
            session: info["session"] as? String,
            window: info["window"] as? String)
        await MainActor.run { Push.shared.open(request) }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        MainActor.assumeIsolated { Push.shared.register() }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        MainActor.assumeIsolated { Push.shared.didRegister(token: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("push registration failed: \(error)")
    }
}

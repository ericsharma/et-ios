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

    func open(_ request: OpenRequest) {
        Push.trace("open window=\(request.window ?? "nil") session=\(request.session ?? "nil") handler=\(onOpen != nil)")
        if let onOpen { onOpen(request) } else { pendingOpen = request }
    }

    /// The notification payload → what to open.
    nonisolated static func request(from info: [AnyHashable: Any]) -> OpenRequest {
        OpenRequest(
            server: (info["server"] as? String).flatMap(UUID.init(uuidString:)),
            session: info["session"] as? String,
            window: info["window"] as? String)
    }

    /// Sandbox for Xcode builds, production for TestFlight / App Store.
    static var environment: String {
        #if DEBUG
        "development"
        #else
        "production"
        #endif
    }

    /// Notification steps, kept across launches (the tap that launches the
    /// app happens before anything else can log). Shown in the debug log.
    static func trace(_ line: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        var lines = UserDefaults.standard.stringArray(forKey: "pushTrace") ?? []
        lines.append("\(stamp) \(line)")
        UserDefaults.standard.set(Array(lines.suffix(30)), forKey: "pushTrace")
    }

    static var traceLines: [String] { UserDefaults.standard.stringArray(forKey: "pushTrace") ?? [] }

    /// Must run before launch finishes, or a tap that launches the app is
    /// not delivered to us.
    func becomeDelegate() {
        UNUserNotificationCenter.current().delegate = self
    }

    func register() {
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
    // Completion-handler versions on purpose: with the `async` versions the
    // completion runs on a Swift concurrency thread, and UIKit aborts
    // (main-thread assertion) when the user taps a notification.

    /// E.T. is open: trigkey normally skips the push then; if one arrives
    /// anyway, show it.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let request = Push.request(from: response.notification.request.content.userInfo)
        nonisolated(unsafe) let done = completionHandler
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                Push.trace("didReceive tap")
                Push.shared.open(request)
            }
            done()
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let fromPush = launchOptions?[.remoteNotification] as? [AnyHashable: Any]
        MainActor.assumeIsolated {
            Push.trace("launch fromNotification=\(fromPush != nil)")
            Push.shared.becomeDelegate()
            // Backup: some launches carry the tapped push only here.
            if let fromPush { Push.shared.open(Push.request(from: fromPush)) }
        }
        return true
    }

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

import Foundation

enum AppInfo {
    /// The git commit the build was made from, e.g. "673d1e7", for the
    /// header ("dev" for local builds).
    static var shortBuild: String {
        Bundle.main.infoDictionary?["ETGitCommit"] as? String ?? "dev"
    }

    /// "E.T. 0.1 (202610151757) · 673d1e7", shown in the ⋯ menu (iOS) and
    /// About (Mac). etd logs it for each connection.
    static var buildLabel: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        #if os(macOS)
        let name = "E.T. for Mac"
        #else
        let name = "E.T."
        #endif
        return "\(name) \(version) (\(build)) · \(shortBuild)"
    }
}

#if os(macOS)
/// ~/Library/Application Support/xyz.ericsharma.et.mac: the Mac app is not
/// sandboxed, so its files get a folder of their own.
enum AppDirectory {
    static let url: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "xyz.ericsharma.et.mac")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
}
#endif

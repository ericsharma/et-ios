import CryptoKit
import Foundation
import NIOSSH

/// A saved server (SPEC.md §8). Stored as JSON by the app.
public struct ServerConfig: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    /// Shown in the UI. Empty means "use the host".
    public var name: String
    public var host: String
    public var port: Int
    public var user: String
    /// nil: find tmux on the server (`SSHConnection.findTmux`).
    public var tmuxPath: String?
    /// tmux `-L` socket name. nil: the default socket.
    public var socketName: String?
    /// The session attached last; attached again on the next launch.
    public var lastSession: String?
    /// The host key trusted on first connect. A different key stops the connection.
    public var hostKey: HostKey?

    public init(id: UUID = UUID(), name: String = "", host: String, port: Int = 22, user: String,
                tmuxPath: String? = nil, socketName: String? = nil, lastSession: String? = nil,
                hostKey: HostKey? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.user = user
        self.tmuxPath = tmuxPath
        self.socketName = socketName
        self.lastSession = lastSession
        self.hostKey = hostKey
    }

    public var displayName: String { name.isEmpty ? host : name }
}

/// A server's public host key, as pinned in `ServerConfig.hostKey`.
public struct HostKey: Codable, Sendable, Hashable {
    /// `<algorithm> <base64>`, as in `known_hosts`.
    public let openSSH: String

    public init(openSSH: String) {
        self.openSSH = openSSH
    }

    init(_ key: NIOSSHPublicKey) {
        openSSH = String(openSSHPublicKey: key)
    }

    public var algorithm: String {
        String(openSSH.split(separator: " ").first ?? "")
    }

    /// `SHA256:<base64>`, the format `ssh-keygen -l` prints.
    public var fingerprint: String {
        let parts = openSSH.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return "?" }
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.replacingOccurrences(of: "=", with: "")
    }
}

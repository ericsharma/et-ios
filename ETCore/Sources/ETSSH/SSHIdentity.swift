import CryptoKit
import Foundation
import NIOSSH
import Security

/// The app's SSH client key: one P-256 key for all servers (SPEC.md §9).
/// On a device it lives in the Secure Enclave and cannot be exported.
public struct SSHIdentity: @unchecked Sendable {
    enum Backing {
        #if canImport(CryptoKit)
        case secureEnclave(SecureEnclave.P256.Signing.PrivateKey)
        #endif
        case software(P256.Signing.PrivateKey)
    }

    let backing: Backing

    /// A key held in memory. Used in the Simulator and in tests.
    public static func software(_ key: P256.Signing.PrivateKey = .init()) -> SSHIdentity {
        SSHIdentity(backing: .software(key))
    }

    public var isHardwareBacked: Bool {
        if case .software = backing { return false }
        return true
    }

    var privateKey: NIOSSHPrivateKey {
        switch backing {
        #if canImport(CryptoKit)
        case .secureEnclave(let key): NIOSSHPrivateKey(secureEnclaveP256Key: key)
        #endif
        case .software(let key): NIOSSHPrivateKey(p256Key: key)
        }
    }

    private var publicKeyX963: Data {
        switch backing {
        #if canImport(CryptoKit)
        case .secureEnclave(let key): key.publicKey.x963Representation
        #endif
        case .software(let key): key.publicKey.x963Representation
        }
    }

    /// The public key as one `authorized_keys` line.
    public func openSSHPublicKey(comment: String = "E.T.") -> String {
        var blob = Data()
        blob.appendSSHString(Data("ecdsa-sha2-nistp256".utf8))
        blob.appendSSHString(Data("nistp256".utf8))
        blob.appendSSHString(publicKeyX963)
        return "ecdsa-sha2-nistp256 \(blob.base64EncodedString()) \(comment)"
    }
}

/// Stores the client key in the Keychain, this device only.
public enum KeyStore {
    static let service = "xyz.ericsharma.et.client-key"
    static let account = "default"

    private enum Kind: UInt8 { case secureEnclave = 1, software = 2 }

    /// Loads the key, or creates one on first launch. Uses the Secure Enclave
    /// when the device has one, otherwise a software key (Simulator).
    public static func loadOrCreate() throws -> SSHIdentity {
        if let data = try read(), let identity = decode(data) { return identity }
        let identity = try create()
        try save(encode(identity))
        return identity
    }

    private static func create() throws -> SSHIdentity {
        #if canImport(CryptoKit) && !targetEnvironment(simulator)
        if SecureEnclave.isAvailable {
            var error: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(
                nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .privateKeyUsage, &error)
            else { throw error!.takeRetainedValue() as Error }
            return SSHIdentity(backing: .secureEnclave(try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)))
        }
        #endif
        return .software()
    }

    private static func encode(_ identity: SSHIdentity) -> Data {
        switch identity.backing {
        #if canImport(CryptoKit)
        // An encrypted handle that only this device's Secure Enclave can use.
        case .secureEnclave(let key): Data([Kind.secureEnclave.rawValue]) + key.dataRepresentation
        #endif
        case .software(let key): Data([Kind.software.rawValue]) + key.rawRepresentation
        }
    }

    private static func decode(_ data: Data) -> SSHIdentity? {
        guard let first = data.first, let kind = Kind(rawValue: first) else { return nil }
        let body = data.dropFirst()
        switch kind {
        case .secureEnclave:
            #if canImport(CryptoKit)
            return (try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: body)).map { SSHIdentity(backing: .secureEnclave($0)) }
            #else
            return nil
            #endif
        case .software:
            return (try? P256.Signing.PrivateKey(rawRepresentation: body)).map { .software($0) }
        }
    }

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecUseDataProtectionKeychain as String: true]
    }

    private static func read() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return result as? Data
    }

    private static func save(_ data: Data) throws {
        var query = baseQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }
}

public struct KeychainError: Error, Sendable {
    public let status: OSStatus
}

extension Data {
    /// Appends an SSH wire-format string: 4-byte big-endian length, then bytes.
    mutating func appendSSHString(_ bytes: Data) {
        var length = UInt32(bytes.count).bigEndian
        append(Data(bytes: &length, count: 4))
        append(bytes)
    }
}

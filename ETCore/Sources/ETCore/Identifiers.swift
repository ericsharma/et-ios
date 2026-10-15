/// tmux object IDs. They are stable for the life of the tmux server, but change
/// after a server restart, so never persist them (store window names instead).

public struct PaneID: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: Int
    public init(_ rawValue: Int) { self.rawValue = rawValue }
    /// Parses `%12`.
    public init?(token: some StringProtocol) {
        guard let v = parseID(token, prefix: "%") else { return nil }
        rawValue = v
    }
    public var description: String { "%\(rawValue)" }
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

public struct WindowID: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: Int
    public init(_ rawValue: Int) { self.rawValue = rawValue }
    /// Parses `@3`.
    public init?(token: some StringProtocol) {
        guard let v = parseID(token, prefix: "@") else { return nil }
        rawValue = v
    }
    public var description: String { "@\(rawValue)" }
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

public struct SessionID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: Int
    public init(_ rawValue: Int) { self.rawValue = rawValue }
    /// Parses `$0`.
    public init?(token: some StringProtocol) {
        guard let v = parseID(token, prefix: "$") else { return nil }
        rawValue = v
    }
    public var description: String { "$\(rawValue)" }
}

private func parseID(_ token: some StringProtocol, prefix: Character) -> Int? {
    guard token.first == prefix else { return nil }
    return Int(token.dropFirst())
}

import Foundation
import Observation
import SwiftUI

/// What a nickname is for: a machine, or one session on it.
enum NicknameTarget: Hashable, Identifiable {
    case machine(String)
    case session(machine: String, name: String)

    var id: String {
        switch self {
        case .machine(let name): name
        case .session(let machine, let name): machine + "/" + name
        }
    }

    /// The name the machine or manymux knows it by.
    var realName: String {
        switch self {
        case .machine(let name): name
        case .session(_, let name): name
        }
    }
}

/// Names this device shows instead of a machine's or a session's real one.
/// Local only: kept in UserDefaults, never sent to a machine or synced to
/// other devices. Renaming on the machine (manymux) is separate.
@MainActor @Observable
final class Nicknames {
    static let shared = Nicknames()

    private(set) var machines: [String: String]
    /// Keyed "machine/name".
    private(set) var sessions: [String: String]

    private static let machinesKey = "nicknames.machines"
    private static let sessionsKey = "nicknames.sessions"

    private init() {
        let defaults = UserDefaults.standard
        machines = defaults.dictionary(forKey: Self.machinesKey) as? [String: String] ?? [:]
        sessions = defaults.dictionary(forKey: Self.sessionsKey) as? [String: String] ?? [:]
    }

    /// The machine's nickname, or its real name.
    func machine(_ name: String) -> String { machines[name] ?? name }

    /// The session's nickname, or its real name.
    func session(machine: String, name: String) -> String { sessions[machine + "/" + name] ?? name }

    /// The nickname, if one is set.
    func nickname(for target: NicknameTarget) -> String? {
        switch target {
        case .machine(let name): machines[name]
        case .session: sessions[target.id]
        }
    }

    /// Empty, or the real name, clears it.
    func set(_ target: NicknameTarget, to nickname: String) {
        let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.isEmpty || trimmed == target.realName ? nil : trimmed
        switch target {
        case .machine(let name):
            machines[name] = value
            UserDefaults.standard.set(machines, forKey: Self.machinesKey)
        case .session:
            sessions[target.id] = value
            UserDefaults.standard.set(sessions, forKey: Self.sessionsKey)
        }
    }
}

extension View {
    /// The "Rename on this device" alert for `target`.
    func nicknameAlert(_ target: Binding<NicknameTarget?>) -> some View {
        modifier(NicknameAlert(target: target))
    }
}

private struct NicknameAlert: ViewModifier {
    @Binding var target: NicknameTarget?
    @State private var text = ""

    func body(content: Content) -> some View {
        content
            .onChange(of: target) { _, target in
                if let target { text = Nicknames.shared.nickname(for: target) ?? target.realName }
            }
            .alert(title, isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } })) {
                field
                Button("Rename") { if let target { Nicknames.shared.set(target, to: text) } }
                if let target, Nicknames.shared.nickname(for: target) != nil {
                    Button("Use Real Name") { Nicknames.shared.set(target, to: "") }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Only this device shows the new name. Real name: \(target?.realName ?? "").")
            }
    }

    private var title: String {
        if case .machine = target { "Rename machine" } else { "Rename session" }
    }

    @ViewBuilder private var field: some View {
        #if os(iOS)
        TextField(target?.realName ?? "Name", text: $text)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        TextField(target?.realName ?? "Name", text: $text)
        #endif
    }
}

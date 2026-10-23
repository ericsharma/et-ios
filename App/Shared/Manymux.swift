/// One machine on the Machines screen: its manymux sessions, or why they
/// couldn't be listed.
struct MmMachine: Identifiable, Equatable, Sendable {
    var name: String
    var sessions: [MmSessionInfo]
    var error: String?
    var id: String { name }
}

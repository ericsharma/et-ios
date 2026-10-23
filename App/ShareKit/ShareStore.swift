import Foundation

/// What the iOS app and its share extension exchange through the App Group
/// (PLAN-files F7): the machines to send to (from the app's last manymux
/// refresh) and large files left for the app to send.
///
///   share/machines.json          [Machine]
///   outbox/<id>/job.json         Job
///   outbox/<id>/files/…          the files, as shared
enum ShareStore {
    static let group = "group.xyz.ericsharma.et"

    /// Shared files at most this big are sent by the extension itself;
    /// bigger ones go through the outbox, so iOS can't kill the send.
    static let extensionLimit: Int64 = 25 * 1024 * 1024

    struct Machine: Codable, Identifiable, Hashable, Sendable {
        var name: String
        /// The machine's own etd: the extension connects to it directly.
        var endpointId: String
        var relayURL: String?
        var sessions: [Session]
        var id: String { name }
    }

    struct Session: Codable, Hashable, Sendable {
        var name: String
        var title: String
    }

    struct Job: Codable, Sendable {
        var machine: String
        var session: String?
        var created: Date
    }

    static var folder: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    }

    // MARK: - Machines

    static func saveMachines(_ machines: [Machine]) {
        guard let url = folder?.appendingPathComponent("share/machines.json") else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(machines).write(to: url, options: .atomic)
    }

    static func loadMachines() -> [Machine] {
        guard let url = folder?.appendingPathComponent("share/machines.json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Machine].self, from: data)) ?? []
    }

    // MARK: - Outbox

    /// Moves `files` into a new outbox job for the app to send.
    static func addJob(_ files: [URL], machine: String, session: String?) throws {
        guard let outbox = folder?.appendingPathComponent("outbox") else { throw CocoaError(.fileNoSuchFile) }
        let job = outbox.appendingPathComponent(UUID().uuidString)
        let filesFolder = job.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: filesFolder, withIntermediateDirectories: true)
        for file in files {
            try FileManager.default.moveItem(at: file, to: filesFolder.appendingPathComponent(file.lastPathComponent))
        }
        let data = try JSONEncoder().encode(Job(machine: machine, session: session, created: Date()))
        // job.json last: a job without it is still being written.
        try data.write(to: job.appendingPathComponent("job.json"), options: .atomic)
    }

    /// Complete jobs, oldest first.
    static func jobs() -> [(folder: URL, job: Job, files: [URL])] {
        guard let outbox = folder?.appendingPathComponent("outbox"),
              let entries = try? FileManager.default.contentsOfDirectory(at: outbox, includingPropertiesForKeys: nil) else { return [] }
        return entries.compactMap { entry in
            guard let data = try? Data(contentsOf: entry.appendingPathComponent("job.json")),
                  let job = try? JSONDecoder().decode(Job.self, from: data) else { return nil }
            let files = (try? FileManager.default.contentsOfDirectory(
                at: entry.appendingPathComponent("files"), includingPropertiesForKeys: nil)) ?? []
            return (entry, job, files)
        }
        .sorted { $0.job.created < $1.job.created }
    }

    static func removeJob(_ folder: URL) {
        try? FileManager.default.removeItem(at: folder)
    }
}

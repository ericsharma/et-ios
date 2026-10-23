import EtLink
import Foundation

// STUB (PLAN-files F5): et-link's F3 API, until it lands in Vendor/etd.
// The names and signature are F3's; once the generated et_link.swift has
// them this file stops compiling (redeclarations), and it is deleted.
//
// It sends with today's `upload`: one request per file, each file read
// whole into memory, into ~/etd-downloads on the target. It never types
// into the session (`typed` is false), and cancelling stops between files.

/// Progress of `sendFiles`, in bytes.
public protocol SendProgress: AnyObject, Sendable {
    func onProgress(done: UInt64, total: UInt64)
}

/// What `sendFiles` delivered: the top-level paths in ~/etd-downloads on the
/// target, and whether etd typed them into the session.
public struct Delivered: Equatable, Hashable, Sendable {
    public var paths: [String]
    public var typed: Bool

    public init(paths: [String], typed: Bool) {
        self.paths = paths
        self.typed = typed
    }
}

extension RemoteHost {
    /// Sends files and folders (local paths) to ~/etd-downloads. A name that
    /// is taken there gets " 2", " 3"… before its extension.
    public func sendFiles(paths: [String], session: String?, progress: SendProgress) async throws -> Delivered {
        let manager = FileManager.default
        let listing = try await exec(script: #"mkdir -p "$HOME/etd-downloads" && printf '%s\n' "$HOME" && ls -1A "$HOME/etd-downloads""#)
        guard listing.exitCode == 0 else {
            throw LinkError.Remote(message: "Couldn't make ~/etd-downloads: " + String(decoding: listing.output, as: UTF8.self))
        }
        var lines = String(decoding: listing.output, as: UTF8.self).split(separator: "\n").map(String.init)
        let home = lines.isEmpty ? "~" : lines.removeFirst()
        var taken = Set(lines)

        // Every folder to make and file to write, relative to ~/etd-downloads.
        var tops: [String] = []
        var folders: [String] = []
        var files: [(local: URL, relative: String, size: UInt64)] = []
        for path in paths {
            let url = URL(fileURLWithPath: path)
            let name = Self.freeName(url.lastPathComponent, taken: taken)
            taken.insert(name)
            tops.append(name)
            var isFolder: ObjCBool = false
            guard manager.fileExists(atPath: path, isDirectory: &isFolder) else {
                throw LinkError.Invalid(message: "No such file: \(path)")
            }
            guard isFolder.boolValue else {
                files.append((url, name, Self.size(of: url)))
                continue
            }
            folders.append(name)
            let inside = Self.walk(url, as: name)
            folders += inside.folders
            files += inside.files
        }

        if !folders.isEmpty {
            let made = try await exec(script: "cd \"$HOME/etd-downloads\" && mkdir -p " + folders.map(Self.quote).joined(separator: " "))
            guard made.exitCode == 0 else {
                throw LinkError.Remote(message: "mkdir failed: " + String(decoding: made.output, as: UTF8.self))
            }
        }
        let total = files.reduce(0) { $0 + $1.size }
        var done: UInt64 = 0
        progress.onProgress(done: 0, total: total)
        for file in files {
            try Task.checkCancellation()
            let data = try Data(contentsOf: file.local)
            _ = try await upload(path: "~/etd-downloads/" + file.relative, data: data)
            done += file.size
            progress.onProgress(done: done, total: total)
        }
        return Delivered(paths: tops.map { home + "/etd-downloads/" + $0 }, typed: false)
    }

    /// A folder's subfolders and files (symlinks skipped), named under `name`.
    private static func walk(_ url: URL, as name: String)
        -> (folders: [String], files: [(local: URL, relative: String, size: UInt64)]) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        let base = url.standardizedFileURL.path
        var folders: [String] = []
        var files: [(local: URL, relative: String, size: UInt64)] = []
        let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys)?.allObjects ?? []
        for case let item as URL in items {
            let values = try? item.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true { continue }
            let relative = name + item.standardizedFileURL.path.dropFirst(base.count)
            if values?.isDirectory == true {
                folders.append(relative)
            } else {
                files.append((item, relative, UInt64(values?.fileSize ?? 0)))
            }
        }
        return (folders, files)
    }

    private static func freeName(_ name: String, taken: Set<String>) -> String {
        guard taken.contains(name) else { return name }
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            if !taken.contains(candidate) { return candidate }
            n += 1
        }
    }

    private static func size(of url: URL) -> UInt64 {
        UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    private static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}

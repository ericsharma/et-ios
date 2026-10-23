import QuickLook
import SwiftUI

/// ⋯ → Files (PLAN-files §4.7): every file sent to any machine, newest
/// first. Tap for Quick Look; the menu types it into a session, sends it on,
/// copies its path or deletes it.
struct FilesView: View {
    let session: SessionController
    @State private var files: SharedFiles
    @State private var picking: SharedFilePick?

    init(session: SessionController) {
        self.session = session
        _files = State(initialValue: SharedFiles(hosts: { session.directHosts() }, log: { session.log.add($0) }))
    }

    var body: some View {
        List {
            if files.items.isEmpty {
                Text(files.loading ? "Loading…" : "No files yet. Send one with the paperclip, or from the share sheet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(files.items) { item in
                Button { if !item.isDir { files.open(item) } } label: {
                    SharedFileRow(item: item, progress: files.busy[item.id])
                }
                .buttonStyle(.plain)
                .contextMenu {
                    SharedFileActions(item: item, files: files, machines: session.machines, picking: $picking)
                }
                .swipeActions {
                    Button("Delete", role: .destructive) { files.delete(item) }
                    Button("Send to…") { picking = SharedFilePick(item: item, kind: .machine) }
                    Button("Type…") { picking = SharedFilePick(item: item, kind: .session) }.tint(Theme.accent)
                }
            }
            if !files.unanswered.isEmpty {
                Section {
                    Text("Not answering: \(files.unanswered.joined(separator: ", "))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Files")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if files.loading { ProgressView() }
            }
        }
        .refreshable { files.reload() }
        .quickLookPreview(Binding(get: { files.preview }, set: { files.preview = $0 }))
        .sheet(item: $picking) { pick in
            SharedFilePicker(pick: pick, files: files, machines: session.machines)
        }
        .overlay(alignment: .bottom) {
            if let notice = files.notice {
                Text(notice)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 16)
                    .task(id: notice) {
                        try? await Task.sleep(for: .seconds(3))
                        if files.notice == notice { files.notice = nil }
                    }
            }
        }
        .task { files.reload() }
    }
}

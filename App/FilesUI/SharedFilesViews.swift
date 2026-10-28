import SwiftUI

/// One shared file: name, from → machine, when, size; progress while an
/// action runs.
struct SharedFileRow: View {
    let item: SharedItem
    let progress: Double??

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.isDir ? "folder.fill" : "doc.fill")
                .foregroundStyle(item.isDir ? Color.blue : Color.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 4) {
                    Text("\(item.from) → \(item.machine)")
                    Text("·")
                    Text(item.received, format: .relative(presentation: .named))
                    Text("·")
                    Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: item.size), countStyle: .file))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                if let progress {
                    if let fraction = progress {
                        ProgressView(value: fraction).controlSize(.small)
                    } else {
                        ProgressView().progressViewStyle(.linear).controlSize(.small)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// What a row's menu needs: the machines and their sessions, for the pickers.
struct SharedFileActions: View {
    let item: SharedItem
    let files: SharedFiles
    let machines: [MmMachine]
    @Binding var picking: SharedFilePick?

    var body: some View {
        Button(item.isDir ? "Open" : "Quick Look", systemImage: "eye") { files.open(item) }
        Button("Type into a session…", systemImage: "keyboard") { picking = SharedFilePick(item: item, kind: .session) }
        Button("Send to…", systemImage: "paperplane") { picking = SharedFilePick(item: item, kind: .machine) }
            .disabled(machines.filter { $0.name != item.machine }.isEmpty)
        Button("Copy Path", systemImage: "doc.on.doc") { copy(item.path) }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) { files.delete(item) }
    }

    private func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
        files.notice = "Path copied"
    }
}

/// A picker open for a file: a session (any machine) or a machine.
struct SharedFilePick: Identifiable {
    enum Kind { case session, machine }
    let item: SharedItem
    let kind: Kind
    var id: String { item.id + "\(kind)" }
}

/// Picks a session on any machine, or a machine other than the file's.
struct SharedFilePicker: View {
    let pick: SharedFilePick
    let files: SharedFiles
    let machines: [MmMachine]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                switch pick.kind {
                case .session:
                    SessionPickerRows(machines: machines) { machine, session in
                        files.type(pick.item, into: machine, session: session)
                        dismiss()
                    }
                case .machine:
                    ForEach(machines.filter { $0.name != pick.item.machine }) { machine in
                        Button(machine.name) {
                            files.send(pick.item, to: machine.name)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(pick.kind == .session ? "Type \(pick.item.name) into…" : "Send \(pick.item.name) to…")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 420)
        #endif
    }
}

/// Every machine's manymux sessions as picker rows, a section per machine.
/// Shared Files and the Logbook's "Send to session…" use it.
struct SessionPickerRows: View {
    let machines: [MmMachine]
    let pick: (_ machine: String, _ session: String) -> Void

    var body: some View {
        ForEach(machines.filter { !$0.sessions.isEmpty }) { machine in
            Section(machine.name) {
                ForEach(machine.sessions) { session in
                    Button {
                        pick(machine.name, session.name)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.name).font(.body.monospaced())
                            if !session.title.isEmpty {
                                Text(session.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
    }
}
